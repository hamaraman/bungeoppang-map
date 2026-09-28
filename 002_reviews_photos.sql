-- 리뷰·사진·신고. schema.sql 적용 후 Supabase SQL Editor에서 한 번 실행.

-- 노점별 리뷰 요약 (트리거가 갱신)
alter table stands
  add column rating_sum   int not null default 0,
  add column review_count int not null default 0;
grant select (rating_sum, review_count) on stands to anon, authenticated;

-- 같은 IP가 최근 1시간에 이 테이블에 몇 건 넣었는지
create or replace function recent_count(tbl regclass, who inet) returns int
language plpgsql stable security definer set search_path = public as $$
declare n int;
begin
  execute format('select count(*) from %s where ip = $1 and created_at > now() - interval ''1 hour''', tbl)
    into n using who;
  return n;
end $$;
revoke all on function recent_count from public, anon, authenticated;

-- 리뷰 ------------------------------------------------------------
create table reviews (
  id           bigint generated always as identity primary key,
  stand_id     bigint not null references stands on delete cascade,
  rating       smallint not null check (rating between 1 and 5),
  body         text check (char_length(body) <= 100),
  report_count int not null default 0,
  ip           inet,
  day          date not null default (now() at time zone 'Asia/Seoul')::date,
  created_at   timestamptz not null default now(),
  unique (stand_id, ip, day)   -- 같은 IP는 노점당 하루 1개
);
create index on reviews (stand_id, created_at desc);

create or replace function reviews_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.ip := request_ip();
  if new.ip is not null and recent_count('reviews', new.ip) >= 10 then
    raise exception '리뷰는 1시간에 10개까지 쓸 수 있어요';
  end if;
  return new;
end $$;
create trigger reviews_before_insert before insert on reviews
for each row execute function reviews_before_insert();

create or replace function reviews_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update stands set rating_sum = rating_sum + new.rating, review_count = review_count + 1
  where id = new.stand_id;
  return null;
end $$;
create trigger reviews_after_insert after insert on reviews
for each row execute function reviews_after_insert();

-- 사진 ------------------------------------------------------------
-- 파일 이름은 서버가 정함. 이 행이 있어야만 Storage에 그 이름으로 올릴 수 있음 (아래 storage 정책)
create table photos (
  id           bigint generated always as identity primary key,
  stand_id     bigint not null references stands on delete cascade,
  path         text not null unique,   -- 트리거가 채움
  report_count int not null default 0,
  ip           inet,
  created_at   timestamptz not null default now()
);
create index on photos (stand_id, created_at desc);

create or replace function photos_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.ip := request_ip();
  new.path := gen_random_uuid() || '.jpg';   -- 클라이언트가 보낸 값은 무시
  if new.ip is not null and recent_count('photos', new.ip) >= 10 then
    raise exception '사진은 1시간에 10장까지 올릴 수 있어요';
  end if;
  return new;
end $$;
create trigger photos_before_insert before insert on photos
for each row execute function photos_before_insert();

-- 신고 (리뷰·사진 공용). 같은 IP는 대상당 1번, 3번 쌓이면 목록에서 숨김 ----------
create table flags (
  id         bigint generated always as identity primary key,
  target     text not null check (target in ('review', 'photo')),
  target_id  bigint not null,
  ip         inet,
  created_at timestamptz not null default now(),
  unique (target, target_id, ip)
);

create or replace function flags_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.ip := request_ip();
  if new.ip is not null and recent_count('flags', new.ip) >= 20 then
    raise exception '신고는 1시간에 20번까지 할 수 있어요';
  end if;
  return new;
end $$;
create trigger flags_before_insert before insert on flags
for each row execute function flags_before_insert();

create or replace function flags_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.target = 'review' then
    update reviews set report_count = report_count + 1 where id = new.target_id;
  else
    update photos set report_count = report_count + 1 where id = new.target_id;
  end if;
  return null;
end $$;
create trigger flags_after_insert after insert on flags
for each row execute function flags_after_insert();

-- 숨겨진 리뷰는 노점 평균 별점에서도 뺌
create or replace function reviews_after_hide() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.report_count < 3 and new.report_count >= 3 then
    update stands set rating_sum = rating_sum - new.rating, review_count = review_count - 1
    where id = new.stand_id;
  end if;
  return null;
end $$;
create trigger reviews_after_hide after update of report_count on reviews
for each row execute function reviews_after_hide();

-- 권한 ------------------------------------------------------------
alter table reviews enable row level security;
alter table photos  enable row level security;
alter table flags   enable row level security;

create policy "숨기지 않은 리뷰 조회" on reviews for select using (report_count < 3);
create policy "누구나 리뷰"          on reviews for insert with check (true);
create policy "숨기지 않은 사진 조회" on photos  for select using (report_count < 3);
create policy "누구나 사진"          on photos  for insert with check (true);
create policy "누구나 신고"          on flags   for insert with check (true);

revoke all on reviews, photos, flags from anon, authenticated;
grant select (id, stand_id, rating, body, created_at, report_count) on reviews to anon, authenticated;
grant insert (stand_id, rating, body)                               on reviews to anon, authenticated;
grant select (id, stand_id, path, created_at, report_count)         on photos  to anon, authenticated;
grant insert (stand_id)                                             on photos  to anon, authenticated;
grant insert (target, target_id)                                    on flags   to anon, authenticated;

-- Storage ---------------------------------------------------------
-- 공개 버킷, JPEG만, 1MB까지 (브라우저에서 1280px로 줄여서 올림)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 1048576, array['image/jpeg']);

-- 10분 안에 만든 photos 행의 이름으로만 업로드 가능. 덮어쓰기·삭제 정책은 없음
create or replace function photo_slot_open(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from photos where path = object_name and created_at > now() - interval '10 minutes')
$$;
grant execute on function photo_slot_open to anon, authenticated;

create policy "예약된 이름으로만 사진 업로드" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'photos' and photo_slot_open(name));
