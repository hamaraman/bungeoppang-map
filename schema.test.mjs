// schema.sql 보안 규칙 검증. 실행: npm i -D @electric-sql/pglite && node schema.test.mjs
import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'fs';
const db = new PGlite();
await db.exec(`create role anon; create role authenticated;`);
await db.exec(readFileSync(new URL('./schema.sql', import.meta.url), 'utf8'));
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
