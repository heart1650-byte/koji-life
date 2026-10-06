begin;
create schema if not exists koji_private;
revoke all on schema koji_private from public, anon, authenticated;
create table public.koji_admins(user_id uuid primary key references auth.users(id) on delete cascade);
alter table public.koji_admins enable row level security;
revoke all on public.koji_admins from anon, authenticated;
create function public.koji_is_admin() returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.koji_admins where user_id=auth.uid())$$;
revoke all on function public.koji_is_admin() from public;
grant execute on function public.koji_is_admin() to authenticated;
create table public.koji_profiles(
 user_id uuid primary key references auth.users(id) on delete cascade,
 name text not null default '' check(length(name)<=100),
 recipient text not null default '' check(length(recipient)<=100),
 postal_code text not null default '' check(postal_code='' or postal_code~'^[0-9]{7}$'),
 prefecture text not null default '' check(length(prefecture)<=20),
 address text not null default '' check(length(address)<=300),
 phone text not null default '' check(phone='' or phone~'^[0-9]{9,11}$'),
 marketing_opt_in boolean not null default false,
 privacy_version text not null check(privacy_version='2026-10-07'),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table public.koji_products(
 id text primary key check(id~'^[0-9]{1,8}$'), name text not null check(length(name) between 1 and 150),
 price integer not null check(price between 1 and 1000000), stock integer not null default 0 check(stock between 0 and 100000),
 state text not null default '準備中' check(state in('準備中','販売中','販売休止')),
 visible boolean not null default true, sort_order integer not null default 10,
 food_kind text not null default 'food' check(food_kind in('food','set','nonfood')),
 food_label jsonb not null default '{}'::jsonb check(jsonb_typeof(food_label)='object'),
 label_confirmed boolean not null default false, external_url text not null default '',
 updated_at timestamptz not null default now()
);
create table public.koji_settings(
 id integer primary key check(id=1), shipping_fee integer not null default 1000 check(shipping_fee=1000),
 bank_enabled boolean not null default false, orders_enabled boolean not null default false
);
insert into public.koji_settings(id) values(1);
create table public.koji_orders(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id),
 request_key uuid not null, status text not null default '受付済み' check(status in('受付済み','承諾・入金待ち','入金確認済み','発送済み','キャンセル')),
 subtotal integer not null check(subtotal>0),shipping_fee integer not null check(shipping_fee=1000),total integer not null check(total=subtotal+shipping_fee),
 address_snapshot jsonb not null, email text not null,payment_method text not null check(payment_method='銀行振込'),
 terms_version text not null check(terms_version='2026-10-07'),accepted_at timestamptz,payment_due_at timestamptz,
 paid_at timestamptz, shipped_at timestamptz,tracking_number text not null default '',
 created_at timestamptz not null default now(),unique(user_id,request_key)
);
create index koji_orders_user_created on public.koji_orders(user_id,created_at desc);
create table public.koji_order_items(
 order_id uuid not null references public.koji_orders(id),product_id text not null references public.koji_products(id),
 name text not null,unit_price integer not null check(unit_price>0),quantity integer not null check(quantity between 1 and 99),
 food_label_snapshot jsonb not null,primary key(order_id,product_id)
);
create table public.koji_admin_events(id bigint generated always as identity primary key,actor uuid not null, action text not null,target text not null,created_at timestamptz not null default now());
create function koji_private.label_ready(p public.koji_products) returns boolean language plpgsql stable security definer set search_path='' as $$
declare k text;c text;component public.koji_products;
begin
 if p.food_kind='nonfood' then return true;end if;
 if not p.label_confirmed then return false;end if;
 if p.food_kind='set' then
  if jsonb_typeof(p.food_label->'components') is distinct from 'array' or jsonb_array_length(p.food_label->'components')<>3 then return false;end if;
  if (select count(distinct value) from jsonb_array_elements_text(p.food_label->'components'))<>3 then return false;end if;
  for c in select jsonb_array_elements_text(p.food_label->'components') loop
   select * into component from public.koji_products where id=c and food_kind='food';
   if not found then return false;end if;
   if not koji_private.label_ready(component) then return false;end if;
  end loop;return true;
 end if;
 foreach k in array array['name','ingredients','additives','origin','allergens','content','expiry','storage','manufacturer','manufacturer_address','nutrition','temperature'] loop
  if length(trim(coalesce(p.food_label->>k,'')))=0 then return false;end if;
 end loop;return true;
end$$;
revoke all on function koji_private.label_ready(public.koji_products) from public;
create function public.koji_save_profile(p_name text,p_recipient text,p_postal text,p_prefecture text,p_address text,p_phone text,p_marketing boolean,p_privacy_version text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'ログインしてください';end if;
 if p_privacy_version<>'2026-10-07' or length(trim(p_name))=0 then raise exception '氏名と個人情報の利用目的への同意を確認してください';end if;
 if p_prefecture<>'' and p_prefecture not in ('北海道','青森県','岩手県','宮城県','秋田県','山形県','福島県','茨城県','栃木県','群馬県','埼玉県','千葉県','東京都','神奈川県','新潟県','富山県','石川県','福井県','山梨県','長野県','岐阜県','静岡県','愛知県','三重県','滋賀県','京都府','大阪府','兵庫県','奈良県','和歌山県','鳥取県','島根県','岡山県','広島県','山口県','徳島県','香川県','愛媛県','高知県','福岡県','佐賀県','長崎県','熊本県','大分県','宮崎県','鹿児島県','沖縄県') then raise exception '国内の都道府県を選択してください';end if;
 insert into public.koji_profiles(user_id,name,recipient,postal_code,prefecture,address,phone,marketing_opt_in,privacy_version)
 values(auth.uid(),trim(p_name),trim(p_recipient),p_postal,p_prefecture,trim(p_address),p_phone,coalesce(p_marketing,false),p_privacy_version)
 on conflict(user_id) do update set name=excluded.name,recipient=excluded.recipient,postal_code=excluded.postal_code,prefecture=excluded.prefecture,address=excluded.address,phone=excluded.phone,marketing_opt_in=excluded.marketing_opt_in,privacy_version=excluded.privacy_version,updated_at=now();
end$$;
create function public.koji_place_order(p_items jsonb,p_request_key uuid,p_terms_version text,p_expected_total integer)
returns uuid language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();profile public.koji_profiles;cfg public.koji_settings;line jsonb;p public.koji_products;n integer;amount integer:=0;oid uuid;mail text;snapshot jsonb;item_snapshot jsonb:='[]';
begin
 if uid is null then raise exception '会員登録・ログインが必要です';end if;
 if p_request_key is null or p_terms_version<>'2026-10-07' then raise exception '販売条件への同意を確認してください';end if;
 perform pg_advisory_xact_lock(hashtextextended(uid::text||p_request_key::text,0));
 select id into oid from public.koji_orders where user_id=uid and request_key=p_request_key;
 if found then return oid;end if;
 select * into cfg from public.koji_settings where id=1;
 if not cfg.orders_enabled or not cfg.bank_enabled then raise exception '現在、直接注文は準備中です';end if;
 if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) not between 1 and 10 then raise exception 'カートを確認してください';end if;
 if exists(select 1 from jsonb_array_elements(p_items)x group by x->>'id' having count(*)>1) then raise exception '商品が重複しています';end if;
 select * into profile from public.koji_profiles where user_id=uid;
 if not found or profile.recipient='' or profile.postal_code='' or profile.prefecture='' or profile.address='' or profile.phone='' then raise exception 'マイページで国内の配送先を登録してください';end if;
 select email into mail from auth.users where id=uid and email_confirmed_at is not null;
 if mail is null then raise exception 'メールアドレスの確認が必要です';end if;
 snapshot=jsonb_build_object('recipient',profile.recipient,'postal_code',profile.postal_code,'prefecture',profile.prefecture,'address',profile.address,'phone',profile.phone);
 for line in select value from jsonb_array_elements(p_items) order by value->>'id' loop
  if jsonb_typeof(line->'quantity') is distinct from 'number' or coalesce(line->>'quantity','')!~'^[0-9]{1,2}$' then raise exception '数量が正しくありません';end if;
  n=(line->>'quantity')::integer;if n not between 1 and 99 then raise exception '数量は1〜99です';end if;
  select * into p from public.koji_products where id=line->>'id' for update;
  if not found then raise exception '商品が見つかりません';end if;
  if not p.visible or p.state<>'販売中' or p.stock<n then raise exception '在庫不足または販売準備中の商品があります：%',p.name;end if;
  if not koji_private.label_ready(p) then raise exception '食品表示を確認中です：%',p.name;end if;
  amount=amount+p.price*n;
  item_snapshot=item_snapshot||jsonb_build_array(jsonb_build_object('id',p.id,'name',p.name,'price',p.price,'quantity',n,'label',case when p.food_kind='set' then p.food_label||jsonb_build_object('component_labels',(select jsonb_agg(jsonb_build_object('id',cp.id,'name',cp.name,'label',cp.food_label)) from public.koji_products cp where cp.id in(select jsonb_array_elements_text(p.food_label->'components')))) else p.food_label end));
  update public.koji_products set stock=stock-n,updated_at=now() where id=p.id;
 end loop;
 if p_expected_total is null or p_expected_total<>amount+cfg.shipping_fee then raise exception '価格が更新されました。注文内容を再確認してください';end if;
 insert into public.koji_orders(user_id,request_key,subtotal,shipping_fee,total,address_snapshot,email,payment_method,terms_version)
 values(uid,p_request_key,amount,cfg.shipping_fee,amount+cfg.shipping_fee,snapshot,mail,'銀行振込',p_terms_version) returning id into oid;
 for line in select value from jsonb_array_elements(item_snapshot) loop
  insert into public.koji_order_items(order_id,product_id,name,unit_price,quantity,food_label_snapshot)
  values(oid,line->>'id',line->>'name',(line->>'price')::integer,(line->>'quantity')::integer,line->'label');
 end loop;return oid;
end$$;
create function public.koji_admin_order(p_order_id uuid,p_status text,p_tracking text default '') returns void language plpgsql security definer set search_path='' as $$
declare o public.koji_orders;it public.koji_order_items;
begin
 if not public.koji_is_admin() then raise exception '管理者権限が必要です';end if;
 select * into o from public.koji_orders where id=p_order_id for update;
 if not found then raise exception '注文が見つかりません';end if;
 if p_status=o.status then return;end if;
 if not((o.status='受付済み' and p_status in('承諾・入金待ち','キャンセル'))or(o.status='承諾・入金待ち' and p_status in('入金確認済み','キャンセル'))or(o.status='入金確認済み' and p_status in('発送済み','キャンセル')))then raise exception '注文状態の変更順序を確認してください';end if;
 if p_status='キャンセル' then
  for it in select * from public.koji_order_items where order_id=o.id order by product_id loop
   update public.koji_products set stock=stock+it.quantity,updated_at=now() where id=it.product_id;
  end loop;
 end if;
 update public.koji_orders set status=p_status,accepted_at=case when p_status='承諾・入金待ち' then now() else accepted_at end,payment_due_at=case when p_status='承諾・入金待ち' then now()+interval '7 days' else payment_due_at end,paid_at=case when p_status='入金確認済み' then now() else paid_at end,shipped_at=case when p_status='発送済み' then now() else shipped_at end,tracking_number=case when p_status='発送済み' then left(coalesce(p_tracking,''),100) else tracking_number end where id=o.id;
 insert into public.koji_admin_events(actor,action,target)values(auth.uid(),'注文：'||p_status,o.id::text);
end$$;
-- All records containing personal data are private. Writes only use authenticated RPCs.
alter table public.koji_profiles enable row level security;
alter table public.koji_products enable row level security;
alter table public.koji_settings enable row level security;
alter table public.koji_orders enable row level security;
alter table public.koji_order_items enable row level security;
alter table public.koji_admin_events enable row level security;
create policy profiles_read on public.koji_profiles for select to authenticated using(user_id=auth.uid() or public.koji_is_admin());
create policy products_public on public.koji_products for select to anon,authenticated using(visible);
create policy products_admin on public.koji_products for all to authenticated using(public.koji_is_admin()) with check(public.koji_is_admin());
create policy settings_read on public.koji_settings for select to anon,authenticated using(true);
create policy settings_admin on public.koji_settings for update to authenticated using(public.koji_is_admin()) with check(public.koji_is_admin());
create policy orders_read on public.koji_orders for select to authenticated using(user_id=auth.uid() or public.koji_is_admin());
create policy items_read on public.koji_order_items for select to authenticated using(exists(select 1 from public.koji_orders o where o.id=order_id and(o.user_id=auth.uid() or public.koji_is_admin())));
create policy audit_read on public.koji_admin_events for select to authenticated using(public.koji_is_admin());
revoke all on public.koji_profiles,public.koji_products,public.koji_settings,public.koji_orders,public.koji_order_items,public.koji_admin_events from anon,authenticated;
grant select on public.koji_products,public.koji_settings to anon,authenticated;
grant insert,update on public.koji_products to authenticated;
grant update on public.koji_settings to authenticated;
grant select on public.koji_profiles,public.koji_orders,public.koji_order_items,public.koji_admin_events to authenticated;
revoke all on function public.koji_save_profile(text,text,text,text,text,text,boolean,text),public.koji_place_order(jsonb,uuid,text,integer),public.koji_admin_order(uuid,text,text) from public,anon;
grant execute on function public.koji_save_profile(text,text,text,text,text,text,boolean,text),public.koji_place_order(jsonb,uuid,text,integer),public.koji_admin_order(uuid,text,text) to authenticated;
insert into public.koji_products(id,name,price,sort_order,food_kind)values
('9','おまかせ発酵調味料3点セット',4000,0,'set'),('1','納豆糀',1200,10,'food'),('2','ひしお糀',1200,20,'food'),('3','ゆず糀',1200,30,'food'),('4','レモン糀',1200,40,'food'),('5','カレー糀',1200,50,'food'),('6','コンソメ糀',1200,60,'food'),('7','中華麹',1200,70,'food'),('8','くるみ味噌',1200,80,'food'),('10','マジックリング',4500,90,'nonfood');
update public.koji_products set external_url='https://u-word.com/teppan/store/storeDetail/131067' where id in('9','10');
commit;
