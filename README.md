# 🐟 붕어빵 지도

**https://bungeoppang.pages.dev**

내 주변 붕어빵 노점을 지도에서 찾고, 누구나 등록하고 제보하는 공개 서비스.

## 핵심 기능 (MVP)

1. **지도 보기**: 내 주변 노점을 핀으로 표시
2. **노점 등록**: 지도를 탭해서 위치를 찍고 정보 입력
   - 이름(선택), 메뉴(팥/슈크림/피자 등), 가격, 영업 요일과 시간, 결제수단(현금/계좌이체)
3. **노점 상세**: 핀을 누르면 정보를 보여 주고 "아직 있어요 / 없어졌어요" 제보
4. **내 위치로 이동** 버튼

## 스택

| 영역 | 선택 |
|---|---|
| 프론트 | `public/index.html` 파일 1개 + 바닐라 JS (배포되는 건 `public/`뿐) |
| 지도 | 네이버 지도 Web Dynamic Map |
| DB/API | Supabase (Postgres + 자동 REST, `supabase-js`는 CDN으로 불러옴) |
| 배포 | Cloudflare Pages 또는 Vercel (정적 파일) |

### 지도를 네이버로 정한 이유
- 카카오는 계정당 첫 앱 하나에만 무료 쿼터를 주는데, 이미 만든 앱이 있음
- 네이버는 지도 로딩 1회만 과금하고 줌·마커는 과금하지 않아서 비용을 예측하기 쉬움

## 데이터 구조

```
stands:  id, lat, lng, name, menus[], price, hours, payment, ip, created_at
reports: id, stand_id, type('exists'|'gone'), ip, created_at
```

- IP는 도배 방지용으로만 저장하고 화면에는 노출하지 않음
- 최근 제보가 '없어졌어요'인 노점은 흐리게 표시 (삭제하지 않음)
- 지도에는 현재 화면 범위(bounds) 안의 노점만 불러옴

## 보안 (공개 서비스)

별도 서버 없이 DB 설정만으로 막는다.

| 위험 | 대응 |
|---|---|
| 남의 노점 수정·삭제 | RLS로 익명 사용자는 조회와 추가만 허용 |
| 도배 등록 | DB 트리거로 같은 IP는 1시간에 등록 5건까지 |
| 제보 조작 | 같은 IP가 같은 노점에 하루 1번만 제보 |
| 이상한 값 입력 | DB 제약: 좌표는 한국 범위 안, 텍스트 길이 제한, 가격은 0 이상 |
| XSS | 화면 출력은 `textContent`만 사용 (innerHTML 사용 안 함) |

## 사진·리뷰

- 리뷰: 별점 1~5 + 한 줄 후기(100자). 같은 IP는 노점당 하루 1개, 1시간에 10개까지
- 사진: 브라우저에서 1280px JPEG로 줄여 Supabase Storage `photos` 버킷에 올림 (EXIF·위치정보 제거). 1시간에 10장까지
  - 파일 이름은 서버가 `photos` 행을 만들며 정하고, 그 이름으로 10분 안에만 업로드 가능 (덮어쓰기·삭제 불가)
- 신고: 리뷰·사진 모두 신고 3번이면 목록에서 숨김. 숨긴 리뷰는 평균 별점에서도 빠짐
  - ⚠️ 숨긴 사진도 파일 주소를 아는 사람은 볼 수 있음 → 부적절한 사진은 Supabase Storage에서 직접 삭제

## 진행 순서

- [x] 1. 네이버 지도를 띄우고 내 위치 표시
- [x] 2. Supabase 테이블, RLS, 제약 조건 (`schema.sql`, 이후 `002_reviews_photos.sql`)
- [x] 3. 화면 범위 안의 노점을 핀으로 표시
- [x] 4. 등록 폼
- [x] 5. 상세 보기와 제보 버튼
- [x] 6. 배포 (Cloudflare Pages + GitHub 연결)

## 일단 뺀 것

| 기능 | 추가할 때 |
|---|---|
| 로그인 | IP 제한으로 도배를 못 막을 때 |
| 검색·필터 | 노점이 수백 개를 넘을 때 |
| 서버 측 클러스터 집계 | 화면당 500개 제한에 걸릴 때 (지금은 브라우저에서 60px 격자로 묶음) |
| 신고/관리자 페이지 | 그전까지는 Supabase 대시보드에서 직접 삭제 |
| 네이티브 앱 | 모바일 웹으로 부족할 때 |

## 준비물

1. **네이버 클라우드 플랫폼**
   - Maps → Application 등록 → `Dynamic Map` 선택
   - 웹 서비스 URL에 `http://localhost` 추가 (배포 도메인은 나중에 추가)
   - **Client ID** 발급 (브라우저에 노출되는 게 정상)
2. **Supabase**
   - Project Settings → API에서 **Project URL**, **anon key** 확인
   - anon key는 공개되는 키이고, 보안은 RLS가 담당
   - ⚠️ **service_role key는 절대 프론트에 넣지 않는다** (RLS를 무시하는 관리자 키)

## 실행 / 배포

```bash
python -m http.server 8000 -d public   # 로컬: http://localhost:8000
```

`main`에 push하면 Cloudflare Pages가 `public/`을 자동 배포한다 (빌드 없음). PR마다 미리보기 주소도 생긴다.
새 도메인을 붙이면 네이버 클라우드 콘솔 Maps Application의 Web 서비스 URL에 추가해야 지도가 뜬다.
