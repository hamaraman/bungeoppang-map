// schema.sql + 002_reviews_photos.sql 보안 규칙 검증. 실행: npm i -D @electric-sql/pglite && node schema.test.mjs
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'fs';
const db = new PGlite();
await db.exec(`create role anon; create role authenticated;`);
await db.exec(readFileSync(new URL('./schema.sql', import.meta.url), 'utf8'));
// Supabase Storage 흉내 (PGlite엔 없음)
await db.exec(`create schema storage;
  create table storage.buckets (id text primary key, name text, public bool, file_size_limit bigint, allowed_mime_types text[]);
  create table storage.objects (id serial primary key, bucket_id text, name text, unique (bucket_id, name));
  alter table storage.objects enable row level security;
  grant usage on schema storage to anon; grant insert, select on storage.objects to anon; grant usage on sequence storage.objects_id_seq to anon;`);
await db.exec(readFileSync(new URL('./002_reviews_photos.sql', import.meta.url), 'utf8'));
await db.exec(`grant usage on schema public to anon;`);
const as = async (ip, sql) => {
  await db.exec(`set role anon; select set_config('request.headers', '{"x-forwarded-for":"${ip}, 10.0.0.1"}', false);`);
  try { await db.exec(sql); return 'ok'; } catch (e) { return e.message; } finally { await db.exec('reset role'); }
};
const ins = `insert into stands (lat,lng,name,menus,price,payment) values (37.5,127,'테스트','{팥,슈크림}',1000,'{현금}')`;
const r = []; for (let i = 0; i < 6; i++) r.push(await as('1.1.1.1', ins));
console.log('6번째 등록 차단:', r[5]); console.assert(r.slice(0,5).every(x=>x==='ok') && r[5].includes('5건'));
console.log('다른 IP 등록:', await as('2.2.2.2', ins));
console.log('범위 밖 좌표:', await as('3.3.3.3', `insert into stands (lat,lng) values (0,0)`));
console.log('ip 위조:', await as('3.3.3.3', `insert into stands (lat,lng,ip) values (37,127,'9.9.9.9')`));
console.log('수정 시도:', await as('3.3.3.3', `update stands set name='x'`));
console.log('삭제 시도:', await as('3.3.3.3', `delete from stands`));
console.log('ip 조회 시도:', await as('3.3.3.3', `select ip from stands`));
console.log('제보1:', await as('4.4.4.4', `insert into reports (stand_id,type) values (1,'gone')`));
console.log('제보 중복:', await as('4.4.4.4', `insert into reports (stand_id,type) values (1,'exists')`));
console.log((await db.query(`select id, ip, last_report from stands where id in (1,6)`)).rows);

// ---- 002: 리뷰·사진·신고
const sel = async (sql) => { await db.exec('set role anon'); try { return (await db.query(sql)).rows; } catch (e) { return e.message; } finally { await db.exec('reset role'); } };
const check = (name, got, ok) => { console.log(name + ':', got); console.assert(ok, name); };
check('리뷰', await as('5.5.5.5', `insert into reviews (stand_id,rating,body) values (1,5,'맛있어요')`), true);
check('같은 날 리뷰 중복', await as('5.5.5.5', `insert into reviews (stand_id,rating) values (1,3)`), true);
check('별점 범위 밖', await as('6.6.6.6', `insert into reviews (stand_id,rating) values (1,9)`), true);
await as('7.7.7.7', `insert into reviews (stand_id,rating,body) values (1,1,'욕설')`);
const bad = (await db.query(`select id from reviews where body='욕설'`)).rows[0].id; // 실패한 insert도 번호를 쓰므로 직접 조회
check('평균 반영', (await sel(`select rating_sum, review_count from stands where id=1`))[0], true);
for (const ip of ['8.0.0.1', '8.0.0.2', '8.0.0.3']) await as(ip, `insert into flags (target,target_id) values ('review',${bad})`);
check('신고 중복', await as('8.0.0.1', `insert into flags (target,target_id) values ('review',${bad})`), true);
const rv = await sel(`select id from reviews`);
check('신고 3회 리뷰 숨김', rv, rv.length === 1 && rv[0].id === 1);
const st = (await sel(`select rating_sum, review_count from stands where id=1`))[0];
check('숨긴 리뷰 평균 제외', st, st.rating_sum === 5 && st.review_count === 1);
check('리뷰 ip 조회', await sel(`select ip from reviews`), true);

check('사진 path 위조', await as('9.9.9.9', `insert into photos (stand_id,path) values (1,'x.jpg')`), true);
await as('9.9.9.9', `insert into photos (stand_id) values (1)`);
const [ph] = await sel(`select id, path from photos`);
check('사진 행', ph, /^[0-9a-f-]{36}\.jpg$/.test(ph.path));
check('예약된 이름 업로드', await as('9.9.9.9', `insert into storage.objects (bucket_id,name) values ('photos','${ph.path}')`), true);
check('예약 안 된 이름 업로드', await as('9.9.9.9', `insert into storage.objects (bucket_id,name) values ('photos','evil.jpg')`), true);
check('덮어쓰기(같은 이름 재업로드)', await as('9.9.9.9', `insert into storage.objects (bucket_id,name) values ('photos','${ph.path}')`), true);
for (const ip of ['8.0.0.1', '8.0.0.2', '8.0.0.3']) await as(ip, `insert into flags (target,target_id) values ('photo',${ph.id})`);
check('신고 3회 사진 숨김', await sel(`select id from photos`), true);
