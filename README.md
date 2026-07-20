# Bline Venture ERP — Phase 2 (POS + Sales + Returns)

Full shop system for Bline Venture. Working now: POS counter billing,
Sales history, Returns, Master (products, customers, suppliers) and Stock —
all shared live across devices via Supabase. Purchases, PDC screen and
Reports come in the next phases.

If you already ran `supabase-setup.sql`: also run `supabase-phase2.sql`
(SQL Editor -> paste -> Run) before deploying this version.
If this is a fresh start: run `supabase-setup.sql` first, then
`supabase-phase2.sql`.

## One-time setup

1. supabase.com → New project → name it `bline-venture`
2. SQL Editor → New query → paste ALL of `supabase-setup.sql` → Run
3. Settings → API → copy the Project URL and the anon public key
4. Open `src/db.js` and paste both at the top
5. `npm install` then `npm run dev` to test locally

## Deploy (no GitHub needed)

```
npx vercel --prod
```

## Editing

- Login users: Supabase → Table Editor → app_users (add/edit rows)
- Menu items: `src/App.jsx` → `MENU`
- Colours: `src/index.css` → `:root` variables
- Stock rule: stock levels only change through the Stock page / adjust_stock
  function, so there is always a complete history of every change.
