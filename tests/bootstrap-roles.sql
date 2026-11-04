do $$ begin create role anon nologin;
exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin;
exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin bypassrls;
exception when duplicate_object then alter role service_role bypassrls; end $$;
