-- 붕어빵 지도 스키마. Supabase SQL Editor에 통째로 붙여넣고 실행.

-- 요청한 사람의 IP. SQL Editor에서 직접 실행하면 null (관리자 취급, 제한 없음)
create or replace function request_ip() returns inet
language sql stable as $$
  select nullif(split_part(coalesce(
    current_setting('request.headers', true)::json->>'cf-connecting-ip',
    current_setting('request.headers', true)::json->>'x-forwarded-for'
  ), ',', 1), '')::inet
$$;

-- 노점 ------------------------------------------------------------
create table stands (
  id             bigint generated always as identity primary key,
  lat            double precision not null check (lat between 33 and 38.7),   -- 한국 범위
  lng            double precision not null check (lng between 124.5 and 132),
  name           text check (char_length(name) <= 30),
  menus          text[] not null default '{}'
                 check (cardinality(menus) <= 10 and char_length(array_to_string(menus, '')) <= 100),
  price          int check (price between 0 and 100000),
  hours          text check (char_length(hours) <= 50),
  payment        text[] not null default '{}' check (payment <@ array['현금', '계좌이체', '카드']),
  last_report    text check (last_report in ('exists', 'gone')),
  last_report_at timestamptz,
  ip             inet,
  created_at     timestamptz not null default now()
);
create index on stands (lat, lng);
create index on stands (ip, created_at);

create or replace function stands_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.ip := request_ip();
  -- ponytail: 동시 요청 몇 건은 제한을 통과할 수 있음. 도배가 심해지면 advisory lock 추가
  if new.ip is not null and (
    select count(*) from stands where ip = new.ip and created_at > now() - interval '1 hour'
  ) >= 5 then
    raise exception '등록은 1시간에 5건까지 가능해요';
  end if;
  return new;
end $$;
create trigger stands_before_insert before insert on stands
for each row execute function stands_before_insert();

-- 제보 ------------------------------------------------------------
create table reports (
  id         bigint generated always as identity primary key,
  stand_id   bigint not null references stands on delete cascade,
  type       text not null check (type in ('exists', 'gone')),
  ip         inet,
  day        date not null default (now() at time zone 'Asia/Seoul')::date,
  created_at timestamptz not null default now(),
  unique (stand_id, ip, day)   -- 같은 IP는 노점당 하루 1번
);

create or replace function reports_before_insert() returns trigger
language plpgsql as $$
begin
  new.ip := request_ip();
  return new;
end $$;
create trigger reports_before_insert before insert on reports
for each row execute function reports_before_insert();

-- 제보가 들어오면 노점의 최근 상태 갱신
create or replace function reports_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update stands set last_report = new.type, last_report_at = new.created_at
  where id = new.stand_id;
  return null;
end $$;
create trigger reports_after_insert after insert on reports
for each row execute function reports_after_insert();

-- 권한: 익명 사용자는 조회와 추가만. ip 등 서버가 채우는 컬럼은 건드릴 수 없음
alter table stands  enable row level security;
alter table reports enable row level security;

create policy "누구나 조회" on stands  for select using (true);
create policy "누구나 등록" on stands  for insert with check (true);
create policy "누구나 제보" on reports for insert with check (true);

revoke all on stands, reports from anon, authenticated;
grant select (id, lat, lng, name, menus, price, hours, payment, last_report, last_report_at, created_at)
  on stands to anon, authenticated;
grant insert (lat, lng, name, menus, price, hours, payment) on stands  to anon, authenticated;
grant insert (stand_id, type)                               on reports to anon, authenticated;
