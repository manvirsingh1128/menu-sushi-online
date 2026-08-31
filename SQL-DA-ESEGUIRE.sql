-- ============================================================================
--  JUN RESTAURANT — Migrazioni + RLS (blindatura)
--  Esegui questo file nel SQL Editor di Supabase (progetto "Jun",
--  ref mtjsxtdubfsqtyvwgdrt) TUTTO IN UNA VOLTA.
--  È idempotente: puoi rieseguirlo senza rompere nulla.
--  Dopo l'esecuzione: 86ing (piatti esauriti) e Sala condivisa funzioneranno.
-- ============================================================================


-- ────────────────────────────────────────────────────────────────────────────
--  1) TABELLA sold_out  (86ing: piatti esauriti)
-- ────────────────────────────────────────────────────────────────────────────
-- I piatti segnati esauriti tornano disponibili DA SOLI ogni mattina (reset giornaliero,
-- vedi sezione 5). Si possono comunque ripristinare a mano dallo staff in qualsiasi momento.
create table if not exists public.sold_out (
  dish_id    integer primary key,          -- numero del piatto (come sul menu)
  name       text,                         -- nome facoltativo (solo per lo staff)
  created_at timestamptz not null default now()
);

alter table public.sold_out enable row level security;

-- Policy: con la chiave anon (usata sia dal menu clienti sia dallo staff)
-- servono lettura + inserimento + cancellazione. NB: con una sola chiave anon
-- non si può distinguere staff da cliente; la protezione vera richiederebbe login.
drop policy if exists "sold_out_select" on public.sold_out;
drop policy if exists "sold_out_insert" on public.sold_out;
drop policy if exists "sold_out_delete" on public.sold_out;
drop policy if exists "sold_out_update" on public.sold_out;
create policy "sold_out_select" on public.sold_out for select using (true);
create policy "sold_out_insert" on public.sold_out for insert with check (true);
create policy "sold_out_update" on public.sold_out for update using (true) with check (true);
create policy "sold_out_delete" on public.sold_out for delete using (true);


-- ────────────────────────────────────────────────────────────────────────────
--  2) TABELLA sala_state  (Sala/Conti condivisa tra i tablet)
-- ────────────────────────────────────────────────────────────────────────────
create table if not exists public.sala_state (
  table_number integer primary key,        -- numero tavolo (1..10)
  adults       integer,                    -- null = usa la stima dagli ordini
  kids         integer not null default 0, -- bambini 4-8
  paid         boolean not null default false,
  paid_at      bigint,                      -- confine di saldatura (orario ultimo ordine, ms)
  prev_paid_at bigint,                      -- confine precedente (per l'annulla/Riapri)
  bill         jsonb,                       -- conto CONGELATO al pagamento {total,adults,kids,drinks,...}
  extras       jsonb   not null default '[]'::jsonb, -- [{label, amount}]
  updated_at   timestamptz not null default now()
);
-- colonne aggiunte dopo la prima versione (idempotente per progetti già creati)
alter table public.sala_state add column if not exists prev_paid_at bigint;
alter table public.sala_state add column if not exists bill jsonb;

alter table public.sala_state enable row level security;

-- Solo lo staff (cameriere/owner) apre questa vista, ma usa la chiave anon.
drop policy if exists "sala_select" on public.sala_state;
drop policy if exists "sala_insert" on public.sala_state;
drop policy if exists "sala_update" on public.sala_state;
drop policy if exists "sala_delete" on public.sala_state;
create policy "sala_select" on public.sala_state for select using (true);
create policy "sala_insert" on public.sala_state for insert with check (true);
create policy "sala_update" on public.sala_state for update using (true) with check (true);
create policy "sala_delete" on public.sala_state for delete using (true);


-- ────────────────────────────────────────────────────────────────────────────
--  3) REALTIME  (perché menu clienti + tablet ricevano gli aggiornamenti)
-- ────────────────────────────────────────────────────────────────────────────
-- Aggiunge le due tabelle alla publication realtime (ignora l'errore se già presenti).
do $$
begin
  begin execute 'alter publication supabase_realtime add table public.sold_out';   exception when duplicate_object then null; end;
  begin execute 'alter publication supabase_realtime add table public.sala_state';  exception when duplicate_object then null; end;
end $$;

-- REPLICA IDENTITY FULL: necessario perché gli eventi realtime di DELETE/UPDATE
-- (es. ripristino di un piatto, reset conti) arrivino ai client con i dati completi.
alter table public.sold_out   replica identity full;
alter table public.sala_state replica identity full;


-- ────────────────────────────────────────────────────────────────────────────
--  4) RLS PIÙ STRETTA su orders  (blindatura)
--     Rimuove le policy larghe attuali e le sostituisce con:
--       - INSERT consentito SOLO con status = 'pending'
--       - SELECT consentito (il KDS deve leggere)
--       - UPDATE consentito solo verso status validi (pending/ready/handled)
--       - NIENTE DELETE (gli ordini si chiudono con status='handled')
-- ────────────────────────────────────────────────────────────────────────────
-- Rimuove TUTTE le policy esistenti su orders (qualunque sia il loro nome)
do $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='orders' loop
    execute format('drop policy if exists %I on public.orders', p.policyname);
  end loop;
end $$;

alter table public.orders enable row level security;

create policy "orders_insert_pending" on public.orders
  for insert with check (status = 'pending');

create policy "orders_select_all" on public.orders
  for select using (true);

create policy "orders_update_valid" on public.orders
  for update using (true)
  with check (status in ('pending','ready','handled'));

-- NB: nessuna policy DELETE = l'anon NON può cancellare ordini (voluto).


-- ────────────────────────────────────────────────────────────────────────────
--  5) AUTO-RESET GIORNALIERO piatti esauriti
--     Ogni mattina alle 04:00 UTC (≈ 06:00 in Italia, prima dell'apertura) la
--     lista degli esauriti si svuota → tutti i piatti tornano disponibili.
--     Lo staff può comunque ripristinare un piatto a mano quando vuole.
-- ────────────────────────────────────────────────────────────────────────────
do $$
begin
  -- rimuove un'eventuale schedulazione precedente con lo stesso nome (idempotente)
  begin perform cron.unschedule('jun-reset-esauriti-giornaliero'); exception when others then null; end;
  perform cron.schedule('jun-reset-esauriti-giornaliero', '0 4 * * *', 'delete from public.sold_out');
exception when others then
  raise notice 'pg_cron non disponibile (crea il job a mano dal dashboard): %', sqlerrm;
end $$;


-- ────────────────────────────────────────────────────────────────────────────
--  6) VERIFICA (facoltativo) — esegui per controllare che sia tutto a posto
-- ────────────────────────────────────────────────────────────────────────────
-- select tablename, policyname, cmd from pg_policies
--   where schemaname='public' and tablename in ('orders','sold_out','sala_state')
--   order by tablename, cmd;
-- select jobname, schedule, command from cron.job where jobname like 'jun-%';
