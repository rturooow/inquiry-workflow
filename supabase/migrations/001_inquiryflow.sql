-- Run once in a NEW Supabase project. All application access goes through n8n.
begin;

create table public.iflow_settings (
  id integer primary key default 1 check (id = 1),
  owner_email text not null default 'owner@example.test',
  sender_email text not null default 'onboarding@resend.dev',
  staff_form_url text not null default 'http://localhost:5678/form/inquiryflow-staff',
  delivery_enabled boolean not null default false,
  reminder_after_minutes integer not null default 1440 check (reminder_after_minutes between 1 and 43200),
  next_report_week date not null default date_trunc('week', now() at time zone 'Asia/Singapore')::date,
  created_at timestamptz not null default now()
);
insert into public.iflow_settings default values;

create table public.iflow_inquiries (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(name) between 2 and 100),
  email text not null check (length(email) <= 254 and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  service text not null check (service in ('Website', 'E-commerce', 'Maintenance')),
  message text not null check (length(message) between 10 and 4000),
  owner_email text not null,
  status text not null default 'new' check (status in ('new', 'contacted', 'closed')),
  created_at timestamptz not null default now(),
  contacted_at timestamptz,
  closed_at timestamptz,
  fingerprint text generated always as (md5(email || chr(31) || lower(service) || chr(31) || lower(message))) stored
);
create unique index iflow_one_open_duplicate on public.iflow_inquiries (fingerprint) where status = 'new';
create index iflow_due_inquiries on public.iflow_inquiries (created_at) where status = 'new';

create table public.iflow_history (
  id bigint generated always as identity primary key,
  inquiry_id uuid not null references public.iflow_inquiries(id),
  from_status text,
  to_status text not null,
  actor text not null default 'owner',
  changed_at timestamptz not null default now()
);

create table public.iflow_notifications (
  id uuid primary key default gen_random_uuid(),
  inquiry_id uuid references public.iflow_inquiries(id),
  kind text not null check (kind in ('new_inquiry', 'reminder', 'weekly_report')),
  event_key text not null unique,
  payload jsonb not null,
  state text not null default 'pending' check (state in ('pending', 'sending', 'sent', 'cancelled', 'failed', 'review')),
  attempts integer not null default 0,
  first_attempt_at timestamptz,
  next_attempt_at timestamptz not null default now(),
  lease_token uuid,
  lease_until timestamptz,
  authorized_token uuid,
  provider_id text,
  last_error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index iflow_notification_queue on public.iflow_notifications (next_attempt_at, created_at) where state in ('pending', 'sending');

create function public.iflow_normalize(p_value text) returns text
language sql immutable set search_path = ''
as $$ select regexp_replace(btrim(coalesce(p_value, '')), '[[:space:]]+', ' ', 'g') $$;

create function public.iflow_message(p_inquiry public.iflow_inquiries, p_kind text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare s public.iflow_settings;
begin
  select * into strict s from public.iflow_settings where id = 1;
  return jsonb_build_object(
    'from', s.sender_email,
    'to', jsonb_build_array(p_inquiry.owner_email),
    'subject', case when p_kind = 'reminder' then 'Reminder: unanswered inquiry' else 'New agency inquiry' end,
    'text', format(
      E'%s\n\nReference: %s\nName: %s\nEmail: %s\nService: %s\nMessage: %s\n\nMark contacted or closed:\n%s?inquiry_id=%s\n\nThis is an internal agency notification.',
      case when p_kind = 'reminder' then 'This inquiry still needs your response.' else 'A new inquiry has been saved.' end,
      p_inquiry.id, p_inquiry.name, p_inquiry.email, p_inquiry.service, p_inquiry.message,
      s.staff_form_url, p_inquiry.id
    )
  );
end $$;

create function public.iflow_submit(p_input jsonb) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_name text := public.iflow_normalize(p_input->>'name');
  v_email text := lower(public.iflow_normalize(p_input->>'email'));
  v_service text := public.iflow_normalize(p_input->>'service');
  v_message text := public.iflow_normalize(p_input->>'message');
  v_fingerprint text;
  r public.iflow_inquiries;
  s public.iflow_settings;
begin
  if jsonb_typeof(p_input->'name') is distinct from 'string'
    or jsonb_typeof(p_input->'email') is distinct from 'string'
    or jsonb_typeof(p_input->'service') is distinct from 'string'
    or jsonb_typeof(p_input->'message') is distinct from 'string'
    or length(v_name) not between 2 and 100 or length(v_email) > 254
    or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or v_service not in ('Website', 'E-commerce', 'Maintenance')
    or length(v_message) not between 10 and 4000 then
    return jsonb_build_object('ok', false, 'error', 'Check the name, email, service, and message.');
  end if;
  select * into strict s from public.iflow_settings where id = 1;
  if s.owner_email = 'owner@example.test' then
    return jsonb_build_object('ok', false, 'error', 'The agency has not finished setup. Please try again later.');
  end if;
  v_fingerprint := md5(v_email || chr(31) || lower(v_service) || chr(31) || lower(v_message));
  -- Serialize identical submissions; the partial unique index is the final guard.
  perform pg_advisory_xact_lock(hashtextextended(v_fingerprint, 0));
  select * into r from public.iflow_inquiries where fingerprint = v_fingerprint and status = 'new';
  if found then return jsonb_build_object('ok', true, 'duplicate', true, 'inquiry_id', r.id); end if;
  insert into public.iflow_inquiries (name, email, service, message, owner_email)
    values (v_name, v_email, v_service, v_message, s.owner_email) returning * into r;
  insert into public.iflow_history (inquiry_id, to_status, actor) values (r.id, 'new', 'intake');
  insert into public.iflow_notifications (inquiry_id, kind, event_key, payload)
    values (r.id, 'new_inquiry', 'new/' || r.id, public.iflow_message(r, 'new_inquiry'));
  return jsonb_build_object('ok', true, 'duplicate', false, 'inquiry_id', r.id);
end $$;

create function public.iflow_update_status(p_inquiry_id uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r public.iflow_inquiries;
begin
  if p_status is null or p_status not in ('contacted', 'closed') then
    return jsonb_build_object('ok', false, 'error', 'Choose contacted or closed.');
  end if;
  select * into r from public.iflow_inquiries where id = p_inquiry_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Inquiry not found.'); end if;
  if r.status = p_status then return jsonb_build_object('ok', true, 'inquiry_id', r.id, 'status', r.status); end if;
  if r.status = 'closed' then return jsonb_build_object('ok', false, 'error', 'A closed inquiry cannot be reopened in this demo.'); end if;
  update public.iflow_inquiries set
    status = p_status,
    contacted_at = case when p_status = 'contacted' then now() else contacted_at end,
    closed_at = case when p_status = 'closed' then now() else closed_at end
    where id = r.id;
  insert into public.iflow_history (inquiry_id, from_status, to_status) values (r.id, r.status, p_status);
  update public.iflow_notifications set state = 'cancelled', lease_until = null, last_error = 'Inquiry is no longer new'
    where inquiry_id = r.id and kind = 'reminder' and state in ('pending', 'sending', 'failed', 'review');
  return jsonb_build_object('ok', true, 'inquiry_id', r.id, 'status', p_status);
end $$;

create function public.iflow_schedule_reminders() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare s public.iflow_settings; v_count integer;
begin
  select * into strict s from public.iflow_settings where id = 1;
  insert into public.iflow_notifications (inquiry_id, kind, event_key, payload)
    select i.id, 'reminder', 'reminder/' || i.id, public.iflow_message(i, 'reminder')
    from public.iflow_inquiries i
    where i.status = 'new' and i.created_at <= now() - make_interval(mins => s.reminder_after_minutes)
    on conflict (event_key) do nothing;
  get diagnostics v_count = row_count;
  return jsonb_build_object('queued', v_count);
end $$;

create function public.iflow_schedule_reports() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  s public.iflow_settings;
  v_start timestamptz;
  v_end timestamptz;
  v_created integer;
  v_contacted integer;
  v_closed integer;
  v_pending integer;
  v_queued integer := 0;
  v_body text;
begin
  select * into strict s from public.iflow_settings where id = 1 for update;
  -- Catch up missed weeks, at most twelve per tick. Periods are Mon 00:00 to Mon 00:00 SGT.
  while ((s.next_report_week + 7)::timestamp + interval '9 hours') at time zone 'Asia/Singapore' <= now()
    and v_queued < 12 loop
    v_start := s.next_report_week::timestamp at time zone 'Asia/Singapore';
    v_end := (s.next_report_week + 7)::timestamp at time zone 'Asia/Singapore';
    select count(*) into v_created from public.iflow_inquiries where created_at >= v_start and created_at < v_end;
    select count(distinct inquiry_id) into v_contacted from public.iflow_history
      where to_status = 'contacted' and changed_at >= v_start and changed_at < v_end;
    select count(distinct inquiry_id) into v_closed from public.iflow_history
      where to_status = 'closed' and changed_at >= v_start and changed_at < v_end;
    select count(*) into v_pending from public.iflow_inquiries where status = 'new';
    v_body := format(
      E'Agency report: %s to %s (Asia/Singapore)\n\nNew inquiries: %s\nMarked contacted: %s\nClosed: %s\nStill unanswered now: %s\n\nContacted means manually marked contacted, not detected email replies.\nBacklog is measured when this report is generated.',
      s.next_report_week, s.next_report_week + 7, v_created, v_contacted, v_closed, v_pending);
    insert into public.iflow_notifications (kind, event_key, payload)
      values ('weekly_report', 'weekly/' || s.next_report_week,
        jsonb_build_object('from', s.sender_email, 'to', jsonb_build_array(s.owner_email),
          'subject', 'Agency weekly report: ' || s.next_report_week, 'text', v_body))
      on conflict (event_key) do nothing;
    s.next_report_week := s.next_report_week + 7;
    v_queued := v_queued + 1;
  end loop;
  update public.iflow_settings set next_report_week = s.next_report_week where id = 1;
  return jsonb_build_object('weeks_processed', v_queued);
end $$;

create function public.iflow_claim() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_jobs jsonb;
begin
  if not (select delivery_enabled from public.iflow_settings where id = 1) then
    return jsonb_build_object('jobs', '[]'::jsonb);
  end if;
  -- Never automatically replay an uncertain send outside Resend's 24h retention.
  update public.iflow_notifications set state = 'review', last_error = 'Retry window or attempt limit reached; inspect provider before replay'
    where state in ('pending', 'sending')
      and (state = 'pending' or lease_until <= now())
      and (first_attempt_at <= now() - interval '23 hours' or attempts >= 5);
  with candidates as (
    select id from public.iflow_notifications
    where (state = 'pending' and next_attempt_at <= now())
       or (state = 'sending' and lease_until <= now())
    order by created_at, id
    for update skip locked limit 5
  ), claimed as (
    update public.iflow_notifications n set state = 'sending',
      lease_token = gen_random_uuid(), lease_until = now() + interval '5 minutes'
    from candidates c where n.id = c.id
    returning n.id, n.lease_token
  )
  select coalesce(jsonb_agg(to_jsonb(claimed)), '[]'::jsonb) into v_jobs from claimed;
  return jsonb_build_object('jobs', v_jobs);
end $$;

create function public.iflow_authorize_send(p_id uuid, p_lease_token uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare n public.iflow_notifications; i public.iflow_inquiries; v_inquiry uuid; s public.iflow_settings;
begin
  select inquiry_id into v_inquiry from public.iflow_notifications where id = p_id;
  -- Always lock inquiry before notification, matching the status update's lock order.
  if v_inquiry is not null then
    select * into i from public.iflow_inquiries where id = v_inquiry for update;
  end if;
  select * into n from public.iflow_notifications where id = p_id for update;
  if not found or n.state <> 'sending' or n.lease_token is distinct from p_lease_token or n.lease_until <= now() then
    return jsonb_build_object('allowed', false);
  end if;
  if n.kind = 'reminder' and i.status is distinct from 'new' then
    update public.iflow_notifications set state = 'cancelled', last_error = 'Inquiry is no longer new' where id = n.id;
    return jsonb_build_object('allowed', false);
  end if;
  select * into strict s from public.iflow_settings where id = 1;
  if not s.delivery_enabled then
    update public.iflow_notifications set state = 'pending', lease_until = null where id = n.id;
    return jsonb_build_object('allowed', false);
  end if;
  -- Freeze recipients at queue time, but do not send stale jobs to a different configured owner.
  if n.payload->'to' is distinct from jsonb_build_array(s.owner_email) then
    update public.iflow_notifications set state = 'review', last_error = 'Recipient differs from the configured owner' where id = n.id;
    return jsonb_build_object('allowed', false);
  end if;
  if n.first_attempt_at <= now() - interval '23 hours' or (n.attempts >= 5 and n.authorized_token is distinct from p_lease_token) then
    update public.iflow_notifications set state = 'review', last_error = 'Retry window or attempt limit reached' where id = n.id;
    return jsonb_build_object('allowed', false);
  end if;
  if n.authorized_token is distinct from p_lease_token then
    update public.iflow_notifications set attempts = attempts + 1,
      first_attempt_at = coalesce(first_attempt_at, now()), authorized_token = p_lease_token
      where id = n.id;
  end if;
  return jsonb_build_object('allowed', true, 'id', n.id, 'lease_token', p_lease_token,
    'event_key', n.event_key, 'payload', n.payload);
end $$;

create function public.iflow_finish(
  p_id uuid, p_lease_token uuid, p_success boolean, p_provider_id text,
  p_transient boolean, p_error text, p_retry_after_seconds integer default 0
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare n public.iflow_notifications; v_next timestamptz;
begin
  select * into n from public.iflow_notifications where id = p_id for update;
  if not found then return jsonb_build_object('updated', false); end if;
  if n.lease_token is distinct from p_lease_token or n.authorized_token is distinct from p_lease_token then
    return jsonb_build_object('updated', false);
  end if;
  -- A status update may cancel an in-flight reminder. Still record a confirmed provider acceptance.
  if p_success and nullif(p_provider_id, '') is not null and n.state in ('sending', 'cancelled') then
    update public.iflow_notifications set state = 'sent', sent_at = now(), provider_id = p_provider_id,
      last_error = null, lease_until = null where id = n.id;
  elsif n.state = 'sending' then
    v_next := now() + make_interval(secs => greatest(60 * power(2, greatest(0, n.attempts - 1))::integer,
      least(86400, greatest(0, coalesce(p_retry_after_seconds, 0)))));
    update public.iflow_notifications set
      state = case when not coalesce(p_transient, false) then 'failed'
        when n.attempts >= 5 or v_next >= n.first_attempt_at + interval '23 hours' then 'review'
        else 'pending' end,
      next_attempt_at = v_next, lease_until = null, last_error = left(coalesce(p_error, 'Unknown send failure'), 500)
      where id = n.id;
  end if;
  return jsonb_build_object('updated', true);
end $$;

create function public.iflow_replay(p_id uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare n public.iflow_notifications; i public.iflow_inquiries; v_inquiry uuid;
begin
  if length(btrim(coalesce(p_note, ''))) < 10 then
    raise exception 'Record how you confirmed this message was NOT accepted by Resend (at least 10 characters)';
  end if;
  select inquiry_id into v_inquiry from public.iflow_notifications where id = p_id;
  if v_inquiry is not null then select * into i from public.iflow_inquiries where id = v_inquiry for update; end if;
  select * into n from public.iflow_notifications where id = p_id for update;
  if not found or n.state not in ('failed', 'review') then
    raise exception 'Only failed or review jobs can be replayed';
  end if;
  if n.kind = 'reminder' and i.status is distinct from 'new' then raise exception 'This reminder is no longer eligible'; end if;
  -- Keep the immutable body and idempotency key; the operator must check old uncertain sends.
  update public.iflow_notifications set state = 'pending', attempts = 0, first_attempt_at = null,
    next_attempt_at = now(), lease_until = null, lease_token = null, authorized_token = null,
    last_error = 'Manual replay: ' || left(p_note, 450) where id = n.id;
  if n.inquiry_id is not null then
    insert into public.iflow_history (inquiry_id, from_status, to_status, actor)
      values (i.id, i.status, i.status, 'replay: ' || left(p_note, 450));
  end if;
  return jsonb_build_object('queued', true);
end $$;

alter table public.iflow_settings enable row level security;
alter table public.iflow_inquiries enable row level security;
alter table public.iflow_history enable row level security;
alter table public.iflow_notifications enable row level security;
revoke all on public.iflow_settings, public.iflow_inquiries, public.iflow_history, public.iflow_notifications from anon, authenticated;
grant all on public.iflow_settings, public.iflow_inquiries, public.iflow_history, public.iflow_notifications to service_role;
grant usage, select on sequence public.iflow_history_id_seq to service_role;
-- SECURITY DEFINER functions must never retain PostgreSQL's default PUBLIC EXECUTE.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as signature from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname like 'iflow\_%' escape '\'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.signature);
    execute format('grant execute on function %s to service_role', f.signature);
  end loop;
end $$;
commit;
