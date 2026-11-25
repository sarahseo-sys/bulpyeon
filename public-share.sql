-- 공개 기록용 SQL (Supabase → SQL Editor에 붙여 넣고, Run은 직접 누르세요)
-- 기존 reorder_records 테이블과 정책은 건드리지 않아요. 새 테이블 1개와 트리거 1개를 추가해요.
-- 여러 번 실행해도 안전해요.

-- (이전에 취소한 버전을 실행했다면 남은 표를 정리해요. 처음이면 아무 일도 안 일어나요)
drop table if exists public.public_owner;

-- 1) 누구나 볼 '공개 기록'만 담는 새 테이블 (가게/메뉴 이름, 맛 점수, 메뉴평만)
create table if not exists public.public_reviews (
  source_id  text primary key,                      -- 어느 기록에서 왔는지 (화면엔 안 보임)
  store_name text not null check (char_length(store_name) between 1 and 60),
  menus      jsonb not null default '[]'::jsonb,    -- [{m: 메뉴, t: 맛 점수 1~5, c: 메뉴평}]
  is_public  boolean not null default true,
  shared_at  timestamptz not null default now()
);

-- 만들자마자 RLS 켜기
alter table public.public_reviews enable row level security;

-- 로그인 없는 사용자(anon)는 '읽기'만, 그것도 필요한 칸만 (source_id는 못 읽음)
revoke all on public.public_reviews from anon, authenticated;
grant select (store_name, menus, shared_at, is_public) on public.public_reviews to anon;

-- ★ 이번에 추가하는 RLS 정책 딱 하나: 공개로 표시된 행만 누구나 읽기
drop policy if exists "public rows readable by anyone" on public.public_reviews;
create policy "public rows readable by anyone"
  on public.public_reviews for select to anon
  using (is_public = true);

-- 2) 기록이 저장될 때 '공개로 표시한 기록'만, 안전한 칸만 골라 복사하는 트리거
--    · 먹은 날, 같이 먹은 사람, 닉네임, 방 열쇠는 복사하지 않아요
--    · 공개를 끄거나 기록을 지우면 공개 목록에서도 사라져요
--    · 오류가 나도 원래 기록 저장은 절대 막지 않도록 감쌌어요
create or replace function public.sync_public_review()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_menus jsonb;
  v_name  text;
  v_id    text;
begin
  begin
    if tg_op = 'DELETE' then
      delete from public.public_reviews where source_id = old.id::text;
      return old;
    end if;

    v_id   := new.id::text;
    v_name := left(btrim(coalesce(new.record->>'name', '')), 60);

    -- 삭제 표시, 공개 아님, 이름 없음 → 공개 목록에서 제거
    if coalesce(new.record->>'deleted', '') = 'true'
       or coalesce(new.record->>'public', '') <> 'true'
       or v_name = '' then
      delete from public.public_reviews where source_id = v_id;
      return new;
    end if;

    -- 메뉴 이름·맛 점수(1~5)·메뉴평만 복사 (최대 30개, 글자 수 제한)
    select coalesce(jsonb_agg(jsonb_build_object(
             'm', left(e.x->>'m', 60),
             't', ((e.x->>'t')::numeric)::int,
             'c', left(coalesce(e.x->>'c', ''), 300)) order by e.n), '[]'::jsonb)
      into v_menus
      from jsonb_array_elements(
             case when jsonb_typeof(new.record->'menus') = 'array'
                  then new.record->'menus' else '[]'::jsonb end) with ordinality as e(x, n)
     where e.n <= 30
       and coalesce(e.x->>'m', '') <> ''
       and (e.x->>'t') ~ '^[1-5](\.0+)?$';

    -- 보여 줄 메뉴가 하나도 없으면 올리지 않음
    if jsonb_array_length(v_menus) = 0 then
      delete from public.public_reviews where source_id = v_id;
      return new;
    end if;

    insert into public.public_reviews (source_id, store_name, menus, is_public, shared_at)
    values (v_id, v_name, v_menus, true, now())
    on conflict (source_id) do update
      set store_name = excluded.store_name,
          menus      = excluded.menus,
          is_public  = true,
          shared_at  = now();
  exception when others then
    raise warning 'sync_public_review 건너뜀: %', sqlerrm;
  end;
  return coalesce(new, old);
end;
$$;

revoke all on function public.sync_public_review() from public, anon, authenticated;

drop trigger if exists trg_sync_public_review on public.reorder_records;
create trigger trg_sync_public_review
  after insert or update or delete on public.reorder_records
  for each row execute function public.sync_public_review();
