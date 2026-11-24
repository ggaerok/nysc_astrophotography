# 채팅 웹서비스 (Vercel + Supabase, 무료 플랜 기준)

운영자 1명 + 사용자 150명, 주 2회, 사진 5장·메시지 10개/인 기준으로 설계했습니다.

```
chat-app/
├─ public/            ← Vercel 이 배포하는 폴더 (정적 파일만, 서버 함수 없음)
│  ├─ user.html       사용자 페이지 (모바일 최적화)   → /c/<토큰>
│  ├─ admin.html      운영자 페이지 (1920×1080)       → /admin
│  ├─ qrcode.js       QR 생성 라이브러리 (MIT, 'QR 보이기' 누를 때만 로드)
│  ├─ config.js       Supabase 주소/키 입력
│  └─ index.html
├─ supabase/schema.sql  DB·보안규칙·스토리지 설정 (SQL Editor 에 1회 실행)
├─ tools/budget.mjs     무료 한도 계산기  →  node tools/budget.mjs
└─ vercel.json
```

## 설치 순서

1. **Supabase 프로젝트 생성** → SQL Editor 에 `supabase/schema.sql` 전체를 붙여넣고 실행
2. **Authentication 설정**
   - Users → *Add user* 로 운영자 계정(이메일/비밀번호) 1개 생성
   - Sign In / Providers → **"Allow new users to sign up" 끄기**, **Anonymous sign-ins 끄기(기본값)**
3. `public/config.js` 에 Project URL 과 anon(publishable) 키 입력 (`service_role` 키는 절대 넣지 않기)
4. GitHub 에 올리고 Vercel 에서 Import (Framework: Other, 설정은 `vercel.json` 이 처리)
5. `https://<도메인>/admin` 에서 로그인 → 단체 이름 입력 → 채팅방 열기 → 링크 복사해 공유

## Vercel CDN 을 쓰지 않는 방법

- 사용자는 페이지 접속 시 `user.html`(gzip 약 7KB) + `config.js` 2건만 Vercel 에서 받음
- 채팅(WebSocket)·사진 업로드·사진 조회는 모두 브라우저 ↔ Supabase 직통
- CSS/JS 인라인, 이미지·폰트 없음, 서버 함수 없음, supabase-js 는 jsDelivr(Vercel 아님)에서 로드

## 동작 규칙

- **입장**: 소속·이름을 모두 입력해야 입장 가능 (서버가 검증, 입장하지 않은 사람은 채팅·사진 불가)
- **접속자 목록**: 운영자 화면 가운데 오른쪽에 접속중/연결끊김/나감/내보냄 표시 (8초마다 갱신)
- **내보내기**: 운영자가 접속자를 내보내면 즉시 퇴장, 같은 기기·같은 소속+이름은 재입장 불가
- **왼쪽 메뉴 접기**: ◀ ▶ 버튼 (상태는 브라우저에 저장)
- **QR 보이기**: 접속 링크를 전체화면 QR 로 표시 (클릭 또는 Esc 로 닫기)
- 방은 한 번에 1개만 열림. 열 때마다 새 토큰(접속 경로)이 생성됨
- 채팅 종료 → 방이 닫히고 **그 방의 모든 채팅 삭제**, 접속 중인 사용자에게 종료 안내 (사진 동시 삭제 체크박스)
- 사용자는 사진을 **볼 수 없음** (스토리지 비공개 + SELECT 정책 없음). 업로드만 가능
- 사진은 브라우저에서 **1MB 미만 JPEG** 로 자동 축소 + 320px 썸네일 별도 업로드
- 운영자 화면은 썸네일만 로드(화면에 보이는 것만 지연 로딩), 클릭 시 원본 로드

## 한도 가드

| 항목 | 값 | 위치 |
|---|---|---|
| 사용자당 메시지 | 10개 | `app_settings.max_msgs_per_user` + `user.html` 의 `MAX_MSG` |
| 사용자당 사진 | 5장 | `app_settings.max_photos_per_user` + `MAX_PHOTO` |
| 월 Realtime 메시지 | 한도(200만)의 95% 도달 시 사용자 메시지 차단 | `rt_guard_ratio` |
| 파일 | 1MB 초과·JPEG 외 업로드 서버에서 거부 | Storage 버킷 설정 |

값을 바꾸면 `tools/budget.mjs --msgs=...` 로 다시 계산해 보세요.

## 사용량 표시에 대해

운영자 화면의 **전송량(5GB=100%)·실시간 메시지**는 앱이 직접 계산한 **추정치**입니다
(운영자가 내려받은 이미지 용량 + 채팅 전달량 추정). 저장 용량은 실제 스토리지 값입니다.
정확한 값은 Supabase 대시보드 → Usage 에서 확인하세요.
