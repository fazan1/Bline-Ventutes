-- ============================================================
-- Bline Venture ERP — PHASE 2 migration (run ONCE, after setup)
-- Supabase → SQL Editor → New query → paste all → Run
-- Adds: sales, sale items, returns, cheques + invoice numbering
-- ============================================================

create sequence if not exists invoice_seq start 1001;

create table if not exists sales (
  id uuid primary key default gen_random_uuid(),
  invoice_no bigint not null default nextval('invoice_seq'),
  customer_id uuid references customers(id) on delete set null,
  customer_name text not null default 'Walk-in',
  date date not null default current_date,
  total numeric not null default 0,
  paid_cash numeric not null default 0,
  paid_cheque numeric not null default 0,
  credit numeric not null default 0,      -- amount added to customer's balance
  user_name text default '',
  created_at timestamptz not null default now()
);

create table if not exists sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references sales(id) on delete cascade,
  product_id uuid references products(id) on delete set null,
  product_name text not null,
  qty numeric not null check (qty > 0),
  price numeric not null default 0,       -- selling price at time of sale
  cost numeric not null default 0         -- cost at time of sale (for profit reports)
);

create table if not exists sale_returns (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid references sales(id) on delete set null,
  invoice_no bigint,
  customer_id uuid references customers(id) on delete set null,
  customer_name text default '',
  amount numeric not null default 0,
  refund_mode text not null check (refund_mode in ('cash', 'credit')),
  date date not null default current_date,
  user_name text default '',
  created_at timestamptz not null default now()
);

create table if not exists sale_return_items (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references sale_returns(id) on delete cascade,
  product_id uuid references products(id) on delete set null,
  product_name text not null,
  qty numeric not null check (qty > 0),
  price numeric not null default 0
);

-- cheques live here from POS onward; full PDC screen comes in Phase 4
create table if not exists cheques (
  id uuid primary key default gen_random_uuid(),
  direction text not null check (direction in ('received', 'issued')),
  party_type text not null check (party_type in ('customer', 'supplier')),
  party_id uuid,
  party_name text default '',
  amount numeric not null check (amount > 0),
  cheque_no text default '',
  bank text default '',
  due_date date,
  status text not null default 'pending'
    check (status in ('pending', 'deposited', 'cleared', 'bounced')),
  sale_id uuid references sales(id) on delete set null,
  notes text default '',
  created_at timestamptz not null default now()
);

alter table sales enable row level security;
alter table sale_items enable row level security;
alter table sale_returns enable row level security;
alter table sale_return_items enable row level security;
alter table cheques enable row level security;

create policy "open" on sales for all using (true) with check (true);
create policy "open" on sale_items for all using (true) with check (true);
create policy "open" on sale_returns for all using (true) with check (true);
create policy "open" on sale_return_items for all using (true) with check (true);
create policy "open" on cheques for all using (true) with check (true);

-- ============================================================
-- ONE transaction per sale: invoice + items + stock deduction +
-- movements + customer credit + cheque record. If anything fails
-- (e.g. not enough stock), NOTHING is saved.
-- ============================================================
create or replace function create_sale(p jsonb)
returns bigint
language plpgsql
as $$
declare
  v_sale_id uuid;
  v_inv bigint;
  v_cust uuid;
  item jsonb;
  v_stock numeric;
begin
  v_cust := nullif(p->>'customer_id', '')::uuid;

  insert into sales (customer_id, customer_name, total, paid_cash, paid_cheque, credit, user_name)
  values (
    v_cust,
    coalesce(p->>'customer_name', 'Walk-in'),
    (p->>'total')::numeric,
    coalesce((p->>'paid_cash')::numeric, 0),
    coalesce((p->>'paid_cheque')::numeric, 0),
    coalesce((p->>'credit')::numeric, 0),
    coalesce(p->>'user_name', '')
  )
  returning id, invoice_no into v_sale_id, v_inv;

  for item in select * from jsonb_array_elements(p->'items') loop
    update products
      set stock = stock - (item->>'qty')::numeric
      where id = (item->>'product_id')::uuid
      returning stock into v_stock;

    if v_stock is null then
      raise exception 'Product not found: %', item->>'product_name';
    end if;
    if v_stock < 0 then
      raise exception 'Not enough stock for % — only % left',
        item->>'product_name', v_stock + (item->>'qty')::numeric;
    end if;

    insert into sale_items (sale_id, product_id, product_name, qty, price, cost)
    values (
      v_sale_id,
      (item->>'product_id')::uuid,
      item->>'product_name',
      (item->>'qty')::numeric,
      (item->>'price')::numeric,
      coalesce((item->>'cost')::numeric, 0)
    );

    insert into movements (product_id, type, qty, reason, user_name)
    values (
      (item->>'product_id')::uuid, 'OUT', (item->>'qty')::numeric,
      'Sale #' || v_inv, coalesce(p->>'user_name', '')
    );
  end loop;

  if coalesce((p->>'credit')::numeric, 0) > 0 then
    if v_cust is null then
      raise exception 'Credit sale needs a customer selected';
    end if;
    update customers set balance = balance + (p->>'credit')::numeric where id = v_cust;
  end if;

  if coalesce((p->>'paid_cheque')::numeric, 0) > 0 then
    insert into cheques (direction, party_type, party_id, party_name, amount,
                         cheque_no, bank, due_date, sale_id)
    values (
      'received', 'customer', v_cust,
      coalesce(p->>'customer_name', 'Walk-in'),
      (p->>'paid_cheque')::numeric,
      coalesce(p->>'cheque_no', ''),
      coalesce(p->>'cheque_bank', ''),
      nullif(p->>'cheque_due', '')::date,
      v_sale_id
    );
  end if;

  return v_inv;
end;
$$;

-- ============================================================
-- ONE transaction per return: return record + items + stock back
-- in + movements + (optionally) cut the customer's credit balance.
-- ============================================================
create or replace function create_sale_return(p jsonb)
returns void
language plpgsql
as $$
declare
  v_ret_id uuid;
  v_cust uuid;
  item jsonb;
begin
  v_cust := nullif(p->>'customer_id', '')::uuid;

  insert into sale_returns (sale_id, invoice_no, customer_id, customer_name,
                            amount, refund_mode, user_name)
  values (
    nullif(p->>'sale_id', '')::uuid,
    (p->>'invoice_no')::bigint,
    v_cust,
    coalesce(p->>'customer_name', ''),
    (p->>'amount')::numeric,
    p->>'refund_mode',
    coalesce(p->>'user_name', '')
  )
  returning id into v_ret_id;

  for item in select * from jsonb_array_elements(p->'items') loop
    insert into sale_return_items (return_id, product_id, product_name, qty, price)
    values (
      v_ret_id,
      (item->>'product_id')::uuid,
      item->>'product_name',
      (item->>'qty')::numeric,
      (item->>'price')::numeric
    );

    update products
      set stock = stock + (item->>'qty')::numeric
      where id = (item->>'product_id')::uuid;

    insert into movements (product_id, type, qty, reason, user_name)
    values (
      (item->>'product_id')::uuid, 'IN', (item->>'qty')::numeric,
      'Return inv #' || (p->>'invoice_no'), coalesce(p->>'user_name', '')
    );
  end loop;

  if p->>'refund_mode' = 'credit' then
    if v_cust is null then
      raise exception 'Cut-from-credit needs a customer on the invoice';
    end if;
    update customers set balance = balance - (p->>'amount')::numeric where id = v_cust;
  end if;
end;
$$;
