-- ============================================================
-- Bline Venture ERP — Supabase setup (run ONCE)
-- Supabase → SQL Editor → New query → paste all of this → Run
-- ============================================================

create extension if not exists pgcrypto;

-- login buttons
create table if not exists app_users (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  role text not null default 'staff',
  sort int not null default 0
);

insert into app_users (name, role, sort) values
  ('Fazeem', 'admin', 1),
  ('Cashier', 'staff', 2);

create table if not exists products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text default '',
  unit text default 'pcs',
  cost numeric not null default 0,
  price numeric not null default 0,
  stock numeric not null default 0,
  low_level numeric not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text default '',
  address text default '',
  balance numeric not null default 0,   -- they owe us
  created_at timestamptz not null default now()
);

create table if not exists suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text default '',
  address text default '',
  balance numeric not null default 0,   -- we owe them
  created_at timestamptz not null default now()
);

create table if not exists movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references products(id) on delete cascade,
  type text not null check (type in ('IN','OUT','ADJUST')),
  qty numeric not null check (qty > 0),
  reason text default '',
  date date not null default current_date,
  user_name text default '',
  created_at timestamptz not null default now()
);

-- open access for the shop app (tap login, no passwords)
alter table app_users enable row level security;
alter table products  enable row level security;
alter table customers enable row level security;
alter table suppliers enable row level security;
alter table movements enable row level security;

create policy "open" on app_users for all using (true) with check (true);
create policy "open" on products  for all using (true) with check (true);
create policy "open" on customers for all using (true) with check (true);
create policy "open" on suppliers for all using (true) with check (true);
create policy "open" on movements for all using (true) with check (true);

-- stock changes happen HERE, in one transaction:
-- update the level + write the history line together,
-- and refuse to go below zero.
create or replace function adjust_stock(
  p_product uuid,
  p_type text,
  p_qty numeric,
  p_reason text,
  p_user text
) returns void
language plpgsql
as $$
declare
  new_stock numeric;
begin
  if p_type = 'IN' then
    update products set stock = stock + p_qty
      where id = p_product
      returning stock into new_stock;
  else
    update products set stock = stock - p_qty
      where id = p_product
      returning stock into new_stock;
    if new_stock < 0 then
      raise exception 'Not enough stock — only % left', new_stock + p_qty;
    end if;
  end if;

  insert into movements (product_id, type, qty, reason, user_name)
  values (p_product, p_type, p_qty, p_reason, p_user);
end;
$$;
