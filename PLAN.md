# InquiryFlow plan

Build a portfolio demo for a sample web agency. A visitor submits an inquiry; the system saves it, emails the owner, reminds them after 24 hours, and sends a weekly report.

## Stack and runtime

- n8n workflows and forms, JavaScript validation, Supabase PostgreSQL, and Resend HTTPS email.
- Docker Compose runs a pinned n8n service and its matching external JavaScript runner. Persist data in a named volume outside source files.
- Encrypt service credentials inside n8n. Deny all browser access to database tables with row-level security.
- Use free plans and notify only the owner's registered Resend account email.

## Workflows

- Normalize and validate name, email, service, and message. Match duplicate open inquiries by normalized email, service, and message. Save a new inquiry and email job in one transaction.
- Require Basic Auth to record contacted or closed status; preserve status history.
- Every five minutes, enqueue due reminders and weekly reports. Remind once after 24 hours; report Monday at 9 AM Asia/Singapore.
- Every minute, atomically claim email work, recheck recipient and reminder eligibility, send with a stable Resend idempotency key, and record outcome.
- Retry temporary errors up to five times. Move uncertain or permanent errors to manual review. Document guarded replay.

## Deliverables and verification

- Compose files, PowerShell setup scripts, four importable n8n workflows, SQL migration, fictional sample inquiries, JavaScript and PostgreSQL tests, and a beginner-friendly README.
- Check validation, simultaneous duplicates, transactional queueing, Basic Auth, denied browser access, reminder qualification/cancellation, weekly reports, retries, and restart recovery.
- Confirm API acceptance and inbox receipt separately.

## Defaults

- One owner and agency; Website, E-commerce, and Maintenance services.
- A person manually marks contacted or closed. AI, inbox reply detection, public hosting, and dashboards are deferred.
- All times use Asia/Singapore. Enable mail only after credentials are saved.
- Supabase Free may pause when inactive. Account setup, keys, and any Windows restart remain user-controlled.
