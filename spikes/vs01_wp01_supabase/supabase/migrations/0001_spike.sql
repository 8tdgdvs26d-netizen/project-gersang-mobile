-- VS-01 WP01 disposable feasibility schema. This is not the production Save schema.
create table if not exists public.spike_player_progress (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision bigint not null default 0 check (revision >= 0),
  money bigint not null default 1000 check (money >= 0),
  inventory jsonb not null default '{}'::jsonb check (jsonb_typeof(inventory) = 'object'),
  updated_at timestamptz not null default now()
);

create table if not exists public.spike_active_sessions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  session_id uuid not null,
  lease_expires_at timestamptz not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.spike_command_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key text not null check (char_length(idempotency_key) between 1 and 128),
  response jsonb not null,
  created_at timestamptz not null default now(),
  primary key (user_id, idempotency_key)
);

create table if not exists public.spike_audit_log (
  audit_id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid not null,
  idempotency_key text not null,
  event_type text not null,
  payload jsonb not null,
  created_at timestamptz not null default now()
);

alter table public.spike_player_progress enable row level security;
alter table public.spike_active_sessions enable row level security;
alter table public.spike_command_receipts enable row level security;
alter table public.spike_audit_log enable row level security;

drop policy if exists spike_progress_select_own on public.spike_player_progress;
create policy spike_progress_select_own on public.spike_player_progress
  for select to authenticated using ((select auth.uid()) = user_id);

-- No client INSERT/UPDATE/DELETE policies exist. Commands go through the Edge Function.
revoke all on public.spike_player_progress from anon, authenticated;
revoke all on public.spike_active_sessions from anon, authenticated;
revoke all on public.spike_command_receipts from anon, authenticated;
revoke all on public.spike_audit_log from anon, authenticated;
grant select on public.spike_player_progress to authenticated;

create or replace function public.spike_start_session(
  p_user_id uuid,
  p_session_id uuid,
  p_lease_seconds integer default 90
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_session public.spike_active_sessions%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  if p_lease_seconds < 30 or p_lease_seconds > 300 then
    raise exception 'ERR_LEASE_RANGE';
  end if;
  -- A row lock cannot serialize two first-time inserts because neither row exists yet.
  -- The per-user transaction lock closes that race without locking unrelated accounts.
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));
  insert into public.spike_player_progress(user_id) values (p_user_id) on conflict do nothing;
  select * into v_session from public.spike_active_sessions where user_id = p_user_id for update;
  if found and v_session.session_id <> p_session_id and v_session.lease_expires_at > v_now then
    raise exception 'ERR_SESSION_ACTIVE';
  end if;
  insert into public.spike_active_sessions(user_id, session_id, lease_expires_at, updated_at)
    values (p_user_id, p_session_id, v_now + make_interval(secs => p_lease_seconds), v_now)
  on conflict (user_id) do update set
    session_id = excluded.session_id,
    lease_expires_at = excluded.lease_expires_at,
    updated_at = excluded.updated_at;
  return jsonb_build_object('ok', true, 'session_id', p_session_id,
    'lease_expires_at', v_now + make_interval(secs => p_lease_seconds));
end;
$$;

create or replace function public.spike_apply_command(
  p_user_id uuid,
  p_session_id uuid,
  p_idempotency_key text,
  p_money_delta integer,
  p_item_id text,
  p_quantity_delta integer
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_session public.spike_active_sessions%rowtype;
  v_progress public.spike_player_progress%rowtype;
  v_receipt jsonb;
  v_old_quantity integer;
  v_next_quantity integer;
  v_next_money bigint;
  v_response jsonb;
begin
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 1 and 128 then
    raise exception 'ERR_IDEMPOTENCY_KEY';
  end if;
  if p_item_id <> 'spike_item' then raise exception 'ERR_ITEM'; end if;
  if p_money_delta not between -100 and 100 then raise exception 'ERR_MONEY_DELTA'; end if;
  if p_quantity_delta = 0 or p_quantity_delta not between -10 and 10 then
    raise exception 'ERR_QUANTITY_DELTA';
  end if;

  select * into v_session from public.spike_active_sessions where user_id = p_user_id for update;
  if not found or v_session.session_id <> p_session_id or v_session.lease_expires_at <= clock_timestamp() then
    raise exception 'ERR_SESSION_STALE';
  end if;

  select response into v_receipt from public.spike_command_receipts
    where user_id = p_user_id and idempotency_key = p_idempotency_key;
  if found then return v_receipt || jsonb_build_object('replayed', true); end if;

  select * into v_progress from public.spike_player_progress where user_id = p_user_id for update;
  if not found then raise exception 'ERR_PROGRESS_MISSING'; end if;
  v_old_quantity := coalesce((v_progress.inventory ->> p_item_id)::integer, 0);
  v_next_quantity := v_old_quantity + p_quantity_delta;
  v_next_money := v_progress.money + p_money_delta;
  if v_next_money < 0 then raise exception 'ERR_INSUFFICIENT_MONEY'; end if;
  if v_next_quantity < 0 then raise exception 'ERR_INSUFFICIENT_ITEM'; end if;

  update public.spike_player_progress set
    revision = revision + 1,
    money = v_next_money,
    inventory = jsonb_set(inventory, array[p_item_id], to_jsonb(v_next_quantity), true),
    updated_at = clock_timestamp()
  where user_id = p_user_id
  returning * into v_progress;

  v_response := jsonb_build_object('ok', true, 'replayed', false, 'state', jsonb_build_object(
    'revision', v_progress.revision, 'money', v_progress.money, 'inventory', v_progress.inventory));
  insert into public.spike_command_receipts(user_id, idempotency_key, response)
    values (p_user_id, p_idempotency_key, v_response);
  insert into public.spike_audit_log(user_id, session_id, idempotency_key, event_type, payload)
    values (p_user_id, p_session_id, p_idempotency_key, 'SPIKE_TEST_COMMAND', jsonb_build_object(
      'money_delta', p_money_delta, 'item_id', p_item_id, 'quantity_delta', p_quantity_delta,
      'revision', v_progress.revision));
  return v_response;
end;
$$;

revoke all on function public.spike_start_session(uuid, uuid, integer) from public, anon, authenticated;
revoke all on function public.spike_apply_command(uuid, uuid, text, integer, text, integer) from public, anon, authenticated;
grant execute on function public.spike_start_session(uuid, uuid, integer) to service_role;
grant execute on function public.spike_apply_command(uuid, uuid, text, integer, text, integer) to service_role;
