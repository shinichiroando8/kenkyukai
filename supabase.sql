-- 糖尿病心理行動研究会 お知らせ・お支払いアプリ用 (kenkyukai-app-demo.html)
-- 掲示板と同じプロジェクトに追加するため、テーブル名は kenkyukai_ で始める

-- ---------------------------------------------------------------
-- 管理者 (ここに登録された auth ユーザーだけが申込者一覧を見られる)
-- ---------------------------------------------------------------
create table public.kenkyukai_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.kenkyukai_admins enable row level security;
-- ポリシーなし = 画面(API)からは読み書きできない。下の関数経由でのみ判定する

create function public.kenkyukai_is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.kenkyukai_admins where user_id = auth.uid());
$$;

-- ---------------------------------------------------------------
-- お知らせ (誰でも読める / 作成・変更・削除は管理者だけ)
-- ---------------------------------------------------------------
create table public.kenkyukai_notices (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 100),
  subtitle text not null check (char_length(subtitle) between 1 and 200),
  event_date date not null,
  event_time text not null check (char_length(event_time) <= 30),
  deadline date not null,
  fee integer not null check (fee >= 0),
  body text not null check (char_length(body) between 1 and 3000),
  status text not null default 'open' check (status in ('open', 'closed')),
  created_at timestamptz not null default now()
);
alter table public.kenkyukai_notices enable row level security;

create policy "notices read"   on public.kenkyukai_notices for select to anon, authenticated using (true);
create policy "notices insert" on public.kenkyukai_notices for insert to authenticated with check (public.kenkyukai_is_admin());
create policy "notices update" on public.kenkyukai_notices for update to authenticated using (public.kenkyukai_is_admin()) with check (public.kenkyukai_is_admin());
create policy "notices delete" on public.kenkyukai_notices for delete to authenticated using (public.kenkyukai_is_admin());

-- ---------------------------------------------------------------
-- 申込み (個人情報を含むので、読み書きは管理者だけ。一般の人は下の関数経由)
-- ---------------------------------------------------------------
create table public.kenkyukai_registrations (
  id uuid primary key default gen_random_uuid(),
  notice_id uuid not null references public.kenkyukai_notices(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 50),
  org text not null check (char_length(org) between 1 and 100),
  email text not null check (char_length(email) between 3 and 200),
  qualification text not null check (char_length(qualification) <= 50),
  fee integer not null check (fee >= 0),
  status text not null default 'unpaid' check (status in ('unpaid', 'paid')),
  cert_status text,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
alter table public.kenkyukai_registrations enable row level security;

create policy "registrations admin read"   on public.kenkyukai_registrations for select to authenticated using (public.kenkyukai_is_admin());
create policy "registrations admin update" on public.kenkyukai_registrations for update to authenticated using (public.kenkyukai_is_admin()) with check (public.kenkyukai_is_admin());
create policy "registrations admin delete" on public.kenkyukai_registrations for delete to authenticated using (public.kenkyukai_is_admin());

-- 資格 → 証明書の手続き状況
create function public.kenkyukai_cert_status(q text)
returns text
language sql immutable
as $$
  select case
    when q like '%糖尿病療養指導士' then '単位証明書発行手続き中(事務局が認定組織へ単位申請を行います)'
    when q = '日本心身医学会専門医' then '受講証明書発行手続き中'
    else null
  end;
$$;

-- 参加登録 (参加費はお知らせの金額をサーバー側で決める。支払状況は必ず未払いで始まる)
create function public.kenkyukai_register(
  p_notice_id uuid, p_name text, p_org text, p_email text, p_qualification text
)
returns public.kenkyukai_registrations
language plpgsql security definer
set search_path = public
as $$
declare
  n public.kenkyukai_notices;
  r public.kenkyukai_registrations;
begin
  select * into n from public.kenkyukai_notices where id = p_notice_id;
  if not found then raise exception 'お知らせが見つかりません'; end if;
  if n.status <> 'open' then raise exception 'この回の参加登録は受付を終了しています'; end if;

  insert into public.kenkyukai_registrations (notice_id, name, org, email, qualification, fee)
  values (p_notice_id, btrim(p_name), btrim(p_org), btrim(p_email), p_qualification, n.fee)
  returning * into r;
  return r;
end;
$$;

-- 自分の申込みの確認 (受付番号 = 推測できないランダムな UUID を知っている人だけ)
create function public.kenkyukai_get_registrations(p_ids uuid[])
returns setof public.kenkyukai_registrations
language sql stable security definer
set search_path = public
as $$
  select * from public.kenkyukai_registrations where id = any(p_ids) limit 50;
$$;

-- お支払いの模擬 (デモ用。piatix の本番連携では、決済完了の通知を受けて更新する形に置き換える)
create function public.kenkyukai_mock_pay(p_id uuid)
returns public.kenkyukai_registrations
language plpgsql security definer
set search_path = public
as $$
declare
  r public.kenkyukai_registrations;
begin
  update public.kenkyukai_registrations
     set status = 'paid', paid_at = now(), cert_status = public.kenkyukai_cert_status(qualification)
   where id = p_id and status = 'unpaid'
  returning * into r;
  if not found then
    select * into r from public.kenkyukai_registrations where id = p_id;
    if not found then raise exception '申込みが見つかりません'; end if;
  end if;
  return r;
end;
$$;

-- 最初のお知らせ (デモに入っていたもの)
insert into public.kenkyukai_notices (title, subtitle, event_date, event_time, deadline, fee, body)
values (
  'オンライン研修会 参加登録',
  '第1回糖尿病心理行動研究会 オンライン研修会',
  '2027-03-14', '13:00〜', '2027-02-26', 2000,
  '第1回糖尿病心理行動研究会が開催するオンライン研修会のご案内です。参加費のお支払いは piatix によるオンライン決済でその場に完了します。糖尿病療養指導士・都道府県糖尿病療養指導士(岡山県・大阪府・京都府・北九州・兵庫県・神奈川県・東京都)については、受講後に事務局が単位証明書を発行し、各認定組織へ単位として認められるよう申請まで行います。日本心身医学会専門医については受講証明書を発行します。'
);
