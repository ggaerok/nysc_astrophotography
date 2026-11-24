-- =====================================================================
-- 채팅 웹서비스 Supabase 스키마 (v2: 소속·이름 입장, 접속자 목록, 내보내기)
-- Supabase 대시보드 > SQL Editor 에 전체를 붙여넣고 한 번 실행하세요.
-- 여러 번 실행해도 안전하며, v1 이 설치된 프로젝트에 다시 실행하면 v2 로 갱신됩니다.
-- 사용자(anon)는 테이블에 직접 접근할 수 없고, 아래 함수(RPC)로만 참여합니다.
-- =====================================================================

-- ---------- 설정 (한도 가드 값) ----------
create table if not exists public.app_settings (
  id                  int primary key default 1 check (id = 1),
  max_msgs_per_user   int     not null default 10,
  max_photos_per_user int     not null default 5,
  assumed_recipients  int     not null default 150,
  rt_message_limit    bigint  not null default 2000000,
  rt_guard_ratio      numeric not null default 0.95
);
alter table public.app_settings add column if not exists max_online int not null default 199; -- 동시 접속 상한(운영자 1명 제외)
insert into public.app_settings (id) values (1) on conflict (id) do nothing;

-- ---------- 채팅방 ----------
create table if not exists public.rooms (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 1 and 50),
  token      text not null unique check (token ~ '^[a-z0-9]{10,32}$'),
  status     text not null default 'open' check (status in ('open', 'closed')),
  created_at timestamptz not null default now(),
  closed_at  timestamptz
);
create unique index if not exists rooms_one_open on public.rooms ((true)) where status = 'open';

-- ---------- 참여자 (소속 + 이름) ----------
create table if not exists public.participants (
  room_id     uuid not null references public.rooms(id) on delete cascade,
  client_id   uuid not null,                       -- 브라우저가 가진 비밀 값 (다른 사용자에게 노출하지 않음)
  affiliation text not null check (char_length(affiliation) between 1 and 20),
  name        text not null check (char_length(name) between 1 and 20),
  status      text not null default 'in' check (status in ('in', 'left', 'kicked')),
  joined_at   timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  primary key (room_id, client_id)
);

-- ---------- 메시지 ----------
create table if not exists public.messages (
  id         bigint generated always as identity primary key,
  room_id    uuid not null references public.rooms(id) on delete cascade,
  client_id  uuid,
  sender     text not null check (sender in ('user', 'admin')),
  nickname   text not null,
  body       text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now()
);
alter table public.messages drop constraint if exists messages_nickname_check;
alter table public.messages add  constraint messages_nickname_check check (char_length(nickname) between 1 and 50);
create index if not exists messages_room_idx   on public.messages (room_id, id);
create index if not exists messages_client_idx on public.messages (room_id, client_id);

-- ---------- 사진 메타데이터 ----------
create table if not exists public.photos (
  id          bigint generated always as identity primary key,
  room_id     uuid not null references public.rooms(id) on delete cascade,
  client_id   uuid not null,
  nickname    text not null,
  path        text not null unique,
  thumb_path  text not null,
  size_bytes  int  not null check (size_bytes > 0 and size_bytes <= 1048576),
  thumb_bytes int  not null check (thumb_bytes > 0 and thumb_bytes <= 102400),
  created_at  timestamptz not null default now()
);
alter table public.photos drop constraint if exists photos_nickname_check;
alter table public.photos add  constraint photos_nickname_check check (char_length(nickname) between 1 and 50);
create index if not exists photos_room_idx   on public.photos (room_id, id);
create index if not exists photos_client_idx on public.photos (room_id, client_id);

-- ---------- 월별 사용량 추정 카운터 ----------
create table if not exists public.usage_monthly (
  month        text primary key,
  egress_bytes bigint not null default 0,
  rt_messages  bigint not null default 0
);

-- ---------- 헬퍼 ----------
create or replace function public.is_admin() returns boolean
language sql stable as $$
  select coalesce(auth.role(), '') = 'authenticated'
     and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false;
$$;

create or replace function public.is_room_open(p_room uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.rooms where id = p_room and status = 'open');
$$;

-- 스토리지 업로드 권한 확인: 폴더 경로 = <방id>/<참여자id>/ 이고, 열린 방의 입장 완료 참여자여야 함
create or replace function public.can_upload(p_room text, p_client text) returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  if p_room is null or p_client is null
     or p_room   !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or p_client !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  return exists (
    select 1 from public.participants pa join public.rooms r on r.id = pa.room_id
    where pa.room_id = p_room::uuid and pa.client_id = p_client::uuid
      and pa.status = 'in' and r.status = 'open'
  );
end;
$$;
drop function if exists public.is_room_open_text(text);

-- ---------- 사용자용 RPC ----------
-- 방 확인 (토큰)
create or replace function public.get_open_room(p_token text)
returns table (id uuid, name text)
language sql stable security definer set search_path = public as $$
  select r.id, r.name from public.rooms r where r.token = p_token and r.status = 'open' limit 1;
$$;

-- 입장: 소속·이름을 모두 입력해야 참여 가능. 반환: ok | closed | invalid | kicked | full
create or replace function public.join_room(p_room uuid, p_client uuid, p_affil text, p_name text)
returns text language plpgsql security definer set search_path = public as $$
declare
  a text := btrim(coalesce(p_affil, ''));
  n text := btrim(coalesce(p_name, ''));
  s public.app_settings;
  online int;
begin
  if not public.is_room_open(p_room) then return 'closed'; end if;
  if char_length(a) < 1 or char_length(a) > 20 or char_length(n) < 1 or char_length(n) > 20 then return 'invalid'; end if;
  if p_client is null then return 'invalid'; end if;

  -- 내보내진 사람은 같은 기기 또는 같은 소속·이름으로 재입장 불가
  if exists (
    select 1 from public.participants
    where room_id = p_room and status = 'kicked'
      and (client_id = p_client or (lower(affiliation) = lower(a) and lower(name) = lower(n)))
  ) then return 'kicked'; end if;

  select * into s from public.app_settings where id = 1;
  select count(*) into online from public.participants
    where room_id = p_room and status = 'in' and last_seen > now() - interval '60 seconds' and client_id <> p_client;
  if online >= s.max_online then return 'full'; end if;

  insert into public.participants (room_id, client_id, affiliation, name)
  values (p_room, p_client, a, n)
  on conflict (room_id, client_id) do update
    set affiliation = excluded.affiliation, name = excluded.name, status = 'in', last_seen = now()
    where public.participants.status <> 'kicked';
  return 'ok';
end;
$$;

-- 접속 유지 신호(약 25초마다). 반환: ok | closed | kicked | unknown
create or replace function public.heartbeat(p_room uuid, p_client uuid) returns text
language plpgsql security definer set search_path = public as $$
declare st text;
begin
  if not public.is_room_open(p_room) then return 'closed'; end if;
  select status into st from public.participants where room_id = p_room and client_id = p_client;
  if st is null then return 'unknown'; end if;
  if st = 'kicked' then return 'kicked'; end if;
  update public.participants set last_seen = now(), status = 'in' where room_id = p_room and client_id = p_client;
  return 'ok';
end;
$$;

create or replace function public.leave_room(p_room uuid, p_client uuid) returns void
language sql security definer set search_path = public as $$
  update public.participants set status = 'left', last_seen = now()
  where room_id = p_room and client_id = p_client and status = 'in';
$$;

-- 메시지 전송 (입장 완료 + 한도 검사는 트리거에서)
create or replace function public.send_message(p_room uuid, p_client uuid, p_body text) returns json
language plpgsql security definer set search_path = public as $$
declare mid bigint; nick text;
begin
  if not public.is_room_open(p_room) then raise exception 'room_closed'; end if;
  insert into public.messages (room_id, client_id, sender, nickname, body)
  values (p_room, p_client, 'user', '-', btrim(coalesce(p_body, '')))
  returning id, nickname into mid, nick;
  return json_build_object('id', mid, 'nick', nick);
end;
$$;

-- 최근 대화 60건 (입장 완료 참여자만). client_id 는 노출하지 않고 mine 만 반환
create or replace function public.get_history(p_room uuid, p_client uuid) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.participants where room_id = p_room and client_id = p_client and status = 'in')
     or not public.is_room_open(p_room) then
    return '[]'::json;
  end if;
  return (
    select coalesce(json_agg(t order by t.id), '[]'::json) from (
      select id, sender, nickname, body, (client_id = p_client) as mine
      from public.messages where room_id = p_room order by id desc limit 60
    ) t
  );
end;
$$;

-- 사진 등록 (파일 업로드 후 호출). 경로는 반드시 <방id>/<참여자id>/ 로 시작
create or replace function public.register_photo(
  p_room uuid, p_client uuid, p_path text, p_thumb text, p_size int, p_tsize int
) returns void language plpgsql security definer set search_path = public as $$
declare prefix text := p_room::text || '/' || p_client::text || '/';
begin
  if not public.is_room_open(p_room) then raise exception 'room_closed'; end if;
  if left(p_path, length(prefix)) <> prefix or left(p_thumb, length(prefix)) <> prefix then
    raise exception 'bad_path';
  end if;
  insert into public.photos (room_id, client_id, nickname, path, thumb_path, size_bytes, thumb_bytes)
  values (p_room, p_client, '-', p_path, p_thumb, p_size, p_tsize);
end;
$$;

-- ---------- 트리거: 메시지 ----------
create or replace function public.messages_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  s    public.app_settings;
  p    public.participants;
  cnt  int;
  used bigint;
  m    text := to_char(now() at time zone 'utc', 'YYYY-MM');
begin
  select * into s from public.app_settings where id = 1;

  if new.sender = 'user' then
    select * into p from public.participants where room_id = new.room_id and client_id = new.client_id;
    if not found or p.status <> 'in' then raise exception 'not_participant'; end if;
    new.nickname := left(p.affiliation || ' · ' || p.name, 50);   -- 표시 이름은 서버가 확정

    select count(*) into cnt from public.messages
      where room_id = new.room_id and client_id = new.client_id and sender = 'user';
    if cnt >= s.max_msgs_per_user then raise exception 'message_limit_user'; end if;

    select coalesce(rt_messages, 0) into used from public.usage_monthly where month = m;
    if coalesce(used, 0) + s.assumed_recipients + 1 > s.rt_message_limit * s.rt_guard_ratio then
      raise exception 'message_limit_month';
    end if;
  end if;

  insert into public.usage_monthly (month, egress_bytes, rt_messages)
  values (
    m,
    (octet_length(new.body) + octet_length(new.nickname) + 200)::bigint * s.assumed_recipients,
    s.assumed_recipients + 1
  )
  on conflict (month) do update
    set egress_bytes = public.usage_monthly.egress_bytes + excluded.egress_bytes,
        rt_messages  = public.usage_monthly.rt_messages  + excluded.rt_messages;
  return new;
end;
$$;
drop trigger if exists trg_messages_guard on public.messages;
create trigger trg_messages_guard before insert on public.messages
  for each row execute function public.messages_guard();

-- ---------- 트리거: 사진 ----------
create or replace function public.photos_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  s   public.app_settings;
  p   public.participants;
  cnt int;
  m   text := to_char(now() at time zone 'utc', 'YYYY-MM');
begin
  select * into s from public.app_settings where id = 1;
  select * into p from public.participants where room_id = new.room_id and client_id = new.client_id;
  if not found or p.status <> 'in' then raise exception 'not_participant'; end if;
  new.nickname := left(p.affiliation || ' · ' || p.name, 50);

  select count(*) into cnt from public.photos where room_id = new.room_id and client_id = new.client_id;
  if cnt >= s.max_photos_per_user then raise exception 'photo_limit'; end if;

  insert into public.usage_monthly (month, rt_messages) values (m, 1)
  on conflict (month) do update set rt_messages = public.usage_monthly.rt_messages + 1;
  return new;
end;
$$;
drop trigger if exists trg_photos_guard on public.photos;
create trigger trg_photos_guard before insert on public.photos
  for each row execute function public.photos_guard();

-- ---------- 운영자 전용 RPC ----------
create or replace function public.add_egress(p_bytes bigint) returns void
language plpgsql security definer set search_path = public as $$
declare m text := to_char(now() at time zone 'utc', 'YYYY-MM');
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_bytes is null or p_bytes <= 0 or p_bytes > 5000000000 then return; end if;
  insert into public.usage_monthly (month, egress_bytes) values (m, p_bytes)
  on conflict (month) do update set egress_bytes = public.usage_monthly.egress_bytes + excluded.egress_bytes;
end;
$$;

create or replace function public.get_usage() returns json
language plpgsql security definer set search_path = public, storage as $$
declare
  m  text := to_char(now() at time zone 'utc', 'YYYY-MM');
  u  public.usage_monthly;
  s  public.app_settings;
  st bigint;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select * into u from public.usage_monthly where month = m;
  select * into s from public.app_settings where id = 1;
  select coalesce(sum((metadata ->> 'size')::bigint), 0) into st
    from storage.objects where bucket_id = 'photos';
  return json_build_object(
    'month', m,
    'egress_bytes', coalesce(u.egress_bytes, 0),
    'rt_messages', coalesce(u.rt_messages, 0),
    'storage_bytes', st,
    'rt_limit', s.rt_message_limit,
    'max_msgs', s.max_msgs_per_user,
    'max_photos', s.max_photos_per_user
  );
end;
$$;

create or replace function public.reset_usage() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  delete from public.usage_monthly where month = to_char(now() at time zone 'utc', 'YYYY-MM');
end;
$$;

-- 접속자 목록 (최근 60초 이내 신호가 있으면 '접속중')
create or replace function public.get_participants(p_room uuid) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return (
    select coalesce(json_agg(json_build_object(
        'client_id', client_id, 'affiliation', affiliation, 'name', name, 'status', status,
        'online', (status = 'in' and last_seen > now() - interval '60 seconds')
      ) order by (status = 'in' and last_seen > now() - interval '60 seconds') desc, joined_at), '[]'::json)
    from public.participants where room_id = p_room
  );
end;
$$;

-- 내보내기 (같은 기기·같은 소속+이름은 재입장 불가)
create or replace function public.kick_participant(p_room uuid, p_client uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  s public.app_settings;
  m text := to_char(now() at time zone 'utc', 'YYYY-MM');
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select * into s from public.app_settings where id = 1;
  update public.participants set status = 'kicked' where room_id = p_room and client_id = p_client;
  -- 내보내기 알림 방송 1건(수신자 포함) 추정치 반영
  insert into public.usage_monthly (month, rt_messages) values (m, s.assumed_recipients + 1)
  on conflict (month) do update set rt_messages = public.usage_monthly.rt_messages + excluded.rt_messages;
end;
$$;

-- 채팅 종료: 방을 닫고 채팅·접속자 기록 삭제
create or replace function public.close_room(p_room uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  update public.rooms set status = 'closed', closed_at = now() where id = p_room;
  delete from public.messages     where room_id = p_room;
  delete from public.participants where room_id = p_room;
end;
$$;

-- ---------- 권한 ----------
revoke all on function public.add_egress(bigint)           from public, anon;
revoke all on function public.get_usage()                  from public, anon;
revoke all on function public.reset_usage()                from public, anon;
revoke all on function public.close_room(uuid)             from public, anon;
revoke all on function public.get_participants(uuid)       from public, anon;
revoke all on function public.kick_participant(uuid, uuid) from public, anon;
grant execute on function public.add_egress(bigint)           to authenticated;
grant execute on function public.get_usage()                  to authenticated;
grant execute on function public.reset_usage()                to authenticated;
grant execute on function public.close_room(uuid)             to authenticated;
grant execute on function public.get_participants(uuid)       to authenticated;
grant execute on function public.kick_participant(uuid, uuid) to authenticated;

grant execute on function public.get_open_room(text)                          to anon, authenticated;
grant execute on function public.join_room(uuid, uuid, text, text)            to anon, authenticated;
grant execute on function public.heartbeat(uuid, uuid)                        to anon, authenticated;
grant execute on function public.leave_room(uuid, uuid)                       to anon, authenticated;
grant execute on function public.send_message(uuid, uuid, text)               to anon, authenticated;
grant execute on function public.get_history(uuid, uuid)                      to anon, authenticated;
grant execute on function public.register_photo(uuid, uuid, text, text, int, int) to anon, authenticated;
grant execute on function public.is_room_open(uuid)                           to anon, authenticated;
grant execute on function public.can_upload(text, text)                       to anon, authenticated;
grant execute on function public.is_admin()                                   to anon, authenticated;

grant usage on schema public to anon, authenticated;
-- v1 에서 열어 둔 사용자(anon) 직접 접근 권한 회수 → 사용자는 함수로만 참여
revoke all on public.messages from anon;
revoke all on public.photos   from anon;
grant usage, select on all sequences in schema public to authenticated;
grant select, insert, update, delete on public.rooms, public.messages, public.photos, public.participants to authenticated;

-- ---------- RLS ----------
alter table public.rooms         enable row level security;
alter table public.participants  enable row level security;
alter table public.messages      enable row level security;
alter table public.photos        enable row level security;
alter table public.app_settings  enable row level security;
alter table public.usage_monthly enable row level security;

drop policy if exists rooms_admin on public.rooms;
create policy rooms_admin on public.rooms for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists participants_admin on public.participants;
create policy participants_admin on public.participants for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists msg_admin on public.messages;
create policy msg_admin on public.messages for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists msg_anon_select on public.messages;
drop policy if exists msg_anon_insert on public.messages;

drop policy if exists photos_admin on public.photos;
create policy photos_admin on public.photos for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists photos_anon_insert on public.photos;

-- ---------- Storage: 비공개 버킷 'photos' ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', false, 1048576, array['image/jpeg'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "photos anon upload" on storage.objects;
create policy "photos anon upload" on storage.objects for insert to anon
  with check (
    bucket_id = 'photos'
    and public.can_upload((storage.foldername(name))[1], (storage.foldername(name))[2])
  );

drop policy if exists "photos admin all" on storage.objects;
create policy "photos admin all" on storage.objects for all to authenticated
  using (bucket_id = 'photos' and public.is_admin())
  with check (bucket_id = 'photos' and public.is_admin());
-- anon 에는 SELECT 정책이 없으므로 업로드만 가능하고 읽을 수 없다.

-- ---------- Realtime ----------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'photos'
  ) then
    alter publication supabase_realtime add table public.photos;
  end if;
end $$;
