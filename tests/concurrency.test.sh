#!/bin/sh
set -eu
i=0
while [ "$i" -lt 12 ]; do
 i=$((i+1))
 psql -v ON_ERROR_STOP=1 -Atqc "select public.iflow_submit('{\"name\":\"Race Test\",\"email\":\"race@example.test\",\"service\":\"Website\",\"message\":\"One inquiry, many simultaneous submissions.\"}'::jsonb)->>'ok'" > "/tmp/inquiryflow-$i" &
done
wait
psql -v ON_ERROR_STOP=1 <<'SQL'
do $$ declare inquiries integer;histories integer;notifications integer;
begin
 select count(*) into inquiries from public.iflow_inquiries where email='race@example.test' and status='new';
 select count(*) into histories from public.iflow_history h join public.iflow_inquiries i on i.id=h.inquiry_id where i.email='race@example.test' and h.to_status='new';
 select count(*) into notifications from public.iflow_notifications n join public.iflow_inquiries i on i.id=n.inquiry_id where i.email='race@example.test' and n.kind='new_inquiry';
 if inquiries<>1 or histories<>1 or notifications<>1 then raise exception 'Concurrent invariant failed: inquiries %, history %, notices %',inquiries,histories,notifications;end if;
 raise notice 'PASS: 12 simultaneous submissions create one inquiry, history record, and email job';
end $$;
SQL
rm -f /tmp/inquiryflow-*
