// 무료 플랜 한도 계산기
// 사용법: node tools/budget.mjs [--users=150] [--photos=3] [--msgs=8] [--spw=2] [--photoTyp=400000]
import fs from 'node:fs';
import zlib from 'node:zlib';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const arg = (k, d) => { const a = process.argv.find((x) => x.startsWith(`--${k}=`)); return a ? Number(a.split('=')[1]) : d; };
const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');
const gz = (f) => zlib.gzipSync(fs.readFileSync(path.join(root, f)), { level: 9 }).length;

// ---------- 가정 ----------
const P = {
  users: arg('users', 150),
  admins: 1,
  spw: arg('spw', 2),                  // 주당 운영 횟수
  photos: arg('photos', 3),            // 사용자 1명당 사진 수
  photoMax: arg('photoMax', 1_000_000),// 사진 최대 크기(자동 축소 상한)
  photoTyp: arg('photoTyp', 400_000),  // 사진 평균 크기(휴대폰 사진 1920px 기준 추정)
  thumb: arg('thumb', 25_000),         // 썸네일 평균(상한 30KB)
  msgs: arg('msgs', 8),                // 사용자 1명당 메시지 수(상한 = max_msgs_per_user)
  adminMsgs: arg('adminMsgs', 100),    // 운영자 메시지 수/회
  loads: arg('loads', 2),              // 사용자 1명이 페이지를 여는 횟수/회
  adminLoads: 5,
  openWorst: 1.0,                      // 최악: 운영자가 모든 원본을 연다
  openTyp: 0.2,                        // 일반: 원본의 20%만 연다
  sessionMin: 60, pollSec: 8, partRowBytes: 110, hbSec: 25, hbBytes: 250,
  avgBody: 80, nickBytes: 12, overhead: 200, historyMsgs: 60, histBytes: 300
};
const sessions = Math.ceil((P.spw * 52) / 12);       // 월 운영 횟수 (8.67 → 9)
const recipients = P.users + P.admins - 1;            // 메시지 1건의 수신자 수(보낸 사람 제외)
const photosPerSession = P.users * P.photos;

// ---------- 한도 (무료 플랜) ----------
const L = {
  vercelReq: 1_000_000, vercelFdt: 100e9, vercelFn: 1_000_000,
  sbEgress: 5e9, sbStorage: 1e9, sbRt: 2_000_000, sbConn: 200
};

const rows = [];
const add = (svc, item, used, limit, unit, note = '') => rows.push({ svc, item, used, limit, unit, note });
const f = (n, u) => u === 'B' ? (n >= 1e9 ? (n / 1e9).toFixed(2) + ' GB' : n >= 1e6 ? (n / 1e6).toFixed(1) + ' MB' : (n / 1e3).toFixed(1) + ' KB')
  : Math.round(n).toLocaleString('ko-KR');

// ---------- Vercel ----------
const htmlUser = gz('user.html'), htmlAdmin = gz('admin.html'), cfg = gz('config.js');
const reqPerSession = P.users * P.loads * 2 + P.adminLoads * 2;                      // html + config.js
const bytesPerSession = P.users * P.loads * (htmlUser + cfg) + P.adminLoads * (htmlAdmin + cfg);
add('Vercel', 'CDN 요청 수', reqPerSession * sessions, L.vercelReq, '건', `user.html ${htmlUser}B(gzip) + config.js ${cfg}B`);
add('Vercel', 'Fast Data Transfer', bytesPerSession * sessions, L.vercelFdt, 'B', '캐시 미사용 최악 가정');
add('Vercel', 'Function 호출', 0, L.vercelFn, '건', '서버 함수 없음');

// ---------- Supabase ----------
const storagePeak = photosPerSession * (P.photoMax + P.thumb);
const storagePeakTyp = photosPerSession * (P.photoTyp + P.thumb);
add('Supabase', '저장 용량 (회차 종료 후 삭제, 최악 1회분)', storagePeak, L.sbStorage, 'B', `일반 ${f(storagePeakTyp, 'B')}`);
add('Supabase', '저장 용량 (삭제 안 하고 2회 누적, 최악)', storagePeak * 2, L.sbStorage, 'B', '→ 반드시 회차마다 삭제');

const chatMsgs = P.users * P.msgs + P.adminMsgs;
const chatEg = chatMsgs * (P.avgBody + P.nickBytes + P.overhead) * recipients;
const histEg = P.users * P.loads * P.historyMsgs * P.histBytes;
const thumbEg = photosPerSession * P.thumb;
const pollEg = (P.sessionMin * 60 / P.pollSec) * P.users * P.partRowBytes;           // 운영자 접속자 목록 갱신
const hbEg = P.users * (P.sessionMin * 60 / P.hbSec) * P.hbBytes;                    // 사용자 접속 유지 신호 응답
const egWorst = thumbEg + photosPerSession * P.photoMax * P.openWorst + chatEg + histEg + pollEg + hbEg;
const egTyp = thumbEg + photosPerSession * P.photoTyp * P.openTyp + chatEg + histEg + pollEg + hbEg;
add('Supabase', '전송량 egress/월 — 최악(원본 100% 열람)', egWorst * sessions, L.sbEgress, 'B', `채팅 ${f(chatEg * sessions, 'B')} + 접속자목록·신호 ${f((pollEg + hbEg) * sessions, 'B')} 포함`);
add('Supabase', '전송량 egress/월 — 일반(원본 20% 열람)', egTyp * sessions, L.sbEgress, 'B');

const rtPerSession = chatMsgs * (recipients + 1) + photosPerSession + (recipients + 1);  // 채팅 + 사진 알림 + 종료 알림
add('Supabase', 'Realtime 메시지/월 (수신자 포함)', rtPerSession * sessions, L.sbRt, '건', `메시지 ${chatMsgs}건 × ${recipients + 1}`);
add('Supabase', 'API 요청(접속 유지 신호 등, 무제한 항목)', Math.round(P.users * (P.sessionMin * 60 / P.hbSec) * sessions), Infinity, '건', '무료 플랜은 API 요청 무제한')
add('Supabase', 'Realtime 동시 접속', P.users + P.admins, L.sbConn, '명');

// ---------- 출력 ----------
console.log(`\n가정: 사용자 ${P.users}명 + 운영자 ${P.admins}명, 주 ${P.spw}회 → 월 ${sessions}회, 사진 ${P.photos}장/인(${photosPerSession}장/회), 메시지 ${P.msgs}개/인\n`);
const w = (s, n) => s + ' '.repeat(Math.max(0, n - [...s].reduce((a, c) => a + (c.charCodeAt(0) > 255 ? 2 : 1), 0)));
for (const r of rows) {
  const p = (r.used / r.limit) * 100;
  if (!isFinite(r.limit)) { console.log(`${w(r.svc, 9)}${w(r.item, 52)}${w(f(r.used, ''), 12)}/ 무제한     -       ${r.note}`); continue; }
  const st = p >= 100 ? '초과' : p >= 90 ? '위험' : p >= 70 ? '주의' : '여유';
  const isB = r.unit === 'B';
  console.log(`${w(r.svc, 9)}${w(r.item, 52)}${w(f(r.used, isB ? 'B' : ''), 12)}/ ${w(isB ? f(r.limit, 'B') : r.limit.toLocaleString('ko-KR'), 11)}${w(p.toFixed(1) + '%', 8)}${st}  ${r.note}`);
}
console.log('');
// 메시지 상한 역산
const maxPerUser = Math.floor((L.sbRt * 0.95 / sessions / (recipients + 1) - P.adminMsgs - 0) / P.users);
console.log(`→ Realtime 한도의 95% 안에서 사용자 1명이 보낼 수 있는 메시지 수 ≈ ${maxPerUser}개/회 (현재 상한 ${P.msgs})`);
