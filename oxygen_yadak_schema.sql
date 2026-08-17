-- OXYGEN YADAK
-- Production-ready starter schema for Supabase / PostgreSQL
-- IMPORTANT:
-- 1) Run this in Supabase SQL Editor.
-- 2) Do NOT put a service_role/secret key in the Android app.
-- 3) Admin users are managed through Supabase Auth.

create extension if not exists pgcrypto;

-- =========================
-- ENUMS
-- =========================
do $$ begin
  create type public.order_status as enum (
    'pending',
    'confirmed',
    'preparing',
    'ready',
    'completed',
    'cancelled'
  );
exception when duplicate_object then null; end $$;

-- =========================
-- COMMON UPDATED_AT TRIGGER
-- =========================
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =========================
-- VEHICLES
-- =========================
create table if not exists public.vehicles (
  id uuid primary key default gen_random_uuid(),
  brand text not null,
  model text not null,
  year_from integer,
  year_to integer,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint vehicles_year_check check (
    (year_from is null or year_from between 1900 and 2200)
    and (year_to is null or year_to between 1900 and 2200)
    and (year_from is null or year_to is null or year_to >= year_from)
  )
);

create unique index if not exists vehicles_unique_model
on public.vehicles (lower(brand), lower(model), coalesce(year_from, 0), coalesce(year_to, 0));

create index if not exists vehicles_brand_idx
on public.vehicles (lower(brand));

-- =========================
-- CATEGORIES
-- =========================
create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  slug text not null unique,
  description text,
  image_url text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =========================
-- PRODUCTS
-- =========================
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  sku text unique,
  name text not null,
  slug text not null unique,
  description text,
  brand text,
  category_id uuid references public.categories(id) on delete set null,
  price numeric(14,2) not null default 0,
  compare_at_price numeric(14,2),
  stock integer not null default 0,
  min_stock integer not null default 0,
  is_active boolean not null default true,
  is_featured boolean not null default false,
  is_tuning_part boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint products_price_check check (price >= 0),
  constraint products_compare_price_check check (
    compare_at_price is null or compare_at_price >= 0
  ),
  constraint products_stock_check check (stock >= 0),
  constraint products_min_stock_check check (min_stock >= 0)
);

create index if not exists products_category_idx on public.products(category_id);
create index if not exists products_active_idx on public.products(is_active);
create index if not exists products_featured_idx on public.products(is_featured);
create index if not exists products_tuning_idx on public.products(is_tuning_part);
create index if not exists products_name_idx on public.products using gin (to_tsvector('simple', name));
create index if not exists products_sku_idx on public.products(sku);

-- =========================
-- PRODUCT <-> VEHICLE
-- =========================
create table if not exists public.product_vehicles (
  product_id uuid not null references public.products(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  primary key (product_id, vehicle_id)
);

create index if not exists product_vehicles_vehicle_idx
on public.product_vehicles(vehicle_id);

-- =========================
-- PRODUCT IMAGES
-- =========================
create table if not exists public.product_images (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  storage_path text not null,
  public_url text,
  alt_text text,
  sort_order integer not null default 0,
  is_primary boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists product_images_product_idx
on public.product_images(product_id);

-- =========================
-- CUSTOMER PROFILES
-- Supabase Auth user id is the primary key.
-- =========================
create table if not exists public.customer_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  address text,
  city text,
  postal_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists customer_profiles_phone_idx
on public.customer_profiles(phone);

-- =========================
-- ADMIN PROFILES
-- Auth users listed here have admin access.
-- Add an auth user's UUID after creating that user in Supabase Auth.
-- =========================
create table if not exists public.admin_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- =========================
-- ORDERS
-- =========================
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number bigint generated always as identity unique,
  customer_id uuid references auth.users(id) on delete set null,
  customer_name text not null,
  customer_phone text not null,
  delivery_address text,
  notes text,
  status public.order_status not null default 'pending',
  subtotal numeric(14,2) not null default 0,
  delivery_fee numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint orders_amounts_check check (
    subtotal >= 0 and delivery_fee >= 0 and total >= 0
  )
);

create index if not exists orders_customer_idx on public.orders(customer_id);
create index if not exists orders_status_idx on public.orders(status);
create index if not exists orders_created_idx on public.orders(created_at desc);

-- =========================
-- ORDER ITEMS
-- Product name and price are snapshotted so old orders remain correct
-- even if the product is later edited.
-- =========================
create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  unit_price numeric(14,2) not null,
  quantity integer not null,
  line_total numeric(14,2) not null,
  created_at timestamptz not null default now(),
  constraint order_items_price_check check (unit_price >= 0),
  constraint order_items_quantity_check check (quantity > 0),
  constraint order_items_total_check check (line_total >= 0)
);

create index if not exists order_items_order_idx on public.order_items(order_id);
create index if not exists order_items_product_idx on public.order_items(product_id);

-- =========================
-- TRIGGERS
-- =========================
drop trigger if exists vehicles_updated_at on public.vehicles;
create trigger vehicles_updated_at
before update on public.vehicles
for each row execute function public.set_updated_at();

drop trigger if exists categories_updated_at on public.categories;
create trigger categories_updated_at
before update on public.categories
for each row execute function public.set_updated_at();

drop trigger if exists products_updated_at on public.products;
create trigger products_updated_at
before update on public.products
for each row execute function public.set_updated_at();

drop trigger if exists customer_profiles_updated_at on public.customer_profiles;
create trigger customer_profiles_updated_at
before update on public.customer_profiles
for each row execute function public.set_updated_at();

drop trigger if exists orders_updated_at on public.orders;
create trigger orders_updated_at
before update on public.orders
for each row execute function public.set_updated_at();

-- =========================
-- HELPER: ADMIN CHECK
-- =========================
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.admin_profiles
    where user_id = auth.uid()
      and is_active = true
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- =========================
-- ROW LEVEL SECURITY
-- =========================
alter table public.vehicles enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.product_vehicles enable row level security;
alter table public.product_images enable row level security;
alter table public.customer_profiles enable row level security;
alter table public.admin_profiles enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

-- Remove policies if this script is re-run.
do $$
declare
  p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in (
        'vehicles','categories','products','product_vehicles',
        'product_images','customer_profiles','admin_profiles',
        'orders','order_items'
      )
  loop
    execute format(
      'drop policy if exists %I on %I.%I',
      p.policyname, p.schemaname, p.tablename
    );
  end loop;
end $$;

-- Public/customer read access for catalog.
create policy "catalog vehicles readable"
on public.vehicles for select
to anon, authenticated
using (is_active = true or public.is_admin());

create policy "catalog categories readable"
on public.categories for select
to anon, authenticated
using (is_active = true or public.is_admin());

create policy "catalog products readable"
on public.products for select
to anon, authenticated
using (is_active = true or public.is_admin());

create policy "catalog product vehicles readable"
on public.product_vehicles for select
to anon, authenticated
using (
  exists (
    select 1 from public.products p
    where p.id = product_id
      and p.is_active = true
  )
  or public.is_admin()
);

create policy "catalog product images readable"
on public.product_images for select
to anon, authenticated
using (
  exists (
    select 1 from public.products p
    where p.id = product_id
      and p.is_active = true
  )
  or public.is_admin()
);

-- Admin management.
create policy "admins manage vehicles"
on public.vehicles for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "admins manage categories"
on public.categories for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "admins manage products"
on public.products for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "admins manage product vehicles"
on public.product_vehicles for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "admins manage product images"
on public.product_images for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

-- Customer profile: owner or admin.
create policy "customers read own profile"
on public.customer_profiles for select
to authenticated
using (id = auth.uid() or public.is_admin());

create policy "customers insert own profile"
on public.customer_profiles for insert
to authenticated
with check (id = auth.uid() or public.is_admin());

create policy "customers update own profile"
on public.customer_profiles for update
to authenticated
using (id = auth.uid() or public.is_admin())
with check (id = auth.uid() or public.is_admin());

create policy "admins manage admin profiles"
on public.admin_profiles for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

-- Orders: customer sees own orders; admin sees everything.
create policy "customers read own orders"
on public.orders for select
to authenticated
using (customer_id = auth.uid() or public.is_admin());

create policy "customers create own orders"
on public.orders for insert
to authenticated
with check (customer_id = auth.uid() or customer_id is null);

create policy "admins manage orders"
on public.orders for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "admins delete orders"
on public.orders for delete
to authenticated
using (public.is_admin());

create policy "customers read own order items"
on public.order_items for select
to authenticated
using (
  public.is_admin()
  or exists (
    select 1 from public.orders o
    where o.id = order_id
      and o.customer_id = auth.uid()
  )
);

create policy "customers create order items"
on public.order_items for insert
to authenticated
with check (
  public.is_admin()
  or exists (
    select 1 from public.orders o
    where o.id = order_id
      and o.customer_id = auth.uid()
  )
);

create policy "admins manage order items"
on public.order_items for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "admins delete order items"
on public.order_items for delete
to authenticated
using (public.is_admin());

-- =========================
-- STORAGE BUCKET FOR PRODUCT IMAGES
-- =========================
insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do update set public = true;

drop policy if exists "public read product images" on storage.objects;
create policy "public read product images"
on storage.objects for select
to public
using (bucket_id = 'product-images');

drop policy if exists "admins upload product images" on storage.objects;
create policy "admins upload product images"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'product-images'
  and public.is_admin()
);

drop policy if exists "admins update product images" on storage.objects;
create policy "admins update product images"
on storage.objects for update
to authenticated
using (
  bucket_id = 'product-images'
  and public.is_admin()
)
with check (
  bucket_id = 'product-images'
  and public.is_admin()
);

drop policy if exists "admins delete product images" on storage.objects;
create policy "admins delete product images"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'product-images'
  and public.is_admin()
);

-- =========================
-- SEED: MAIN CATEGORIES
-- =========================
insert into public.categories (name, slug, sort_order)
values
  ('موتور و قطعات موتور', 'engine', 1),
  ('سیستم ترمز', 'brakes', 2),
  ('جلو بندی و تعلیق', 'suspension', 3),
  ('برق و الکترونیک', 'electrical', 4),
  ('فیلترها', 'filters', 5),
  ('سیستم سوخت و انژکتور', 'fuel-injection', 6),
  ('خنک‌کاری', 'cooling', 7),
  ('بدنه و چراغ', 'body-lights', 8),
  ('قطعات تقویتی', 'tuning', 9),
  ('لوازم مصرفی', 'consumables', 10)
on conflict (name) do nothing;

-- =========================
-- SEED: COMMON IRANIAN VEHICLES
-- =========================
insert into public.vehicles (brand, model, year_from, year_to)
values
  ('ایران خودرو', 'پژو 405', 1990, 2026),
  ('ایران خودرو', 'پژو پارس', 1997, 2026),
  ('ایران خودرو', 'پژو 206', 2001, 2026),
  ('ایران خودرو', 'پژو 207', 2009, 2026),
  ('ایران خودرو', 'سمند', 2001, 2026),
  ('ایران خودرو', 'سمند سورن', 2007, 2026),
  ('ایران خودرو', 'دنا', 2011, 2026),
  ('ایران خودرو', 'دنا پلاس', 2016, 2026),
  ('ایران خودرو', 'رانا', 2012, 2026),
  ('ایران خودرو', 'تارا', 2021, 2026),
  ('سایپا', 'پراید', 1990, 2026),
  ('سایپا', 'تیبا', 2010, 2026),
  ('سایپا', 'تیبا 2', 2013, 2026),
  ('سایپا', 'ساینا', 2016, 2026),
  ('سایپا', 'کوییک', 2017, 2026),
  ('سایپا', 'شاهین', 2020, 2026),
  ('سایپا', 'ریو', 2005, 2013)
on conflict do nothing;

-- =========================
-- OPTIONAL VIEW FOR PRODUCT LISTING
-- =========================
create or replace view public.product_catalog as
select
  p.id,
  p.sku,
  p.name,
  p.slug,
  p.description,
  p.brand,
  p.price,
  p.compare_at_price,
  p.stock,
  p.is_featured,
  p.is_tuning_part,
  p.category_id,
  c.name as category_name,
  coalesce(
    (
      select pi.public_url
      from public.product_images pi
      where pi.product_id = p.id
      order by pi.is_primary desc, pi.sort_order asc, pi.created_at asc
      limit 1
    ),
    ''
  ) as primary_image_url
from public.products p
left join public.categories c on c.id = p.category_id
where p.is_active = true;

-- Grant view access to catalog users.
grant select on public.product_catalog to anon, authenticated;

-- =========================
-- NOTES
-- =========================
-- To make a user an admin after creating them in Supabase Auth:
--
-- insert into public.admin_profiles (user_id, display_name)
-- values ('AUTH-USER-UUID-HERE', 'مدیر OXYGEN YADAK');
--
-- For production, prefer creating admin rows through a controlled
-- server-side/admin workflow rather than exposing admin creation to clients.
