# InquiryFlow

A portfolio demo for a sample web agency: capture a project inquiry, alert the owner, remind them after 24 hours, and send a Monday report.

Keep it local and use fictional inquiry data. Do not collect real client data until you deploy behind HTTPS and review access and privacy controls.

## Architecture

~~~mermaid
flowchart LR
  Visitor["Customer form"] --> n8n["Local n8n"]
  n8n --> Check["Validate and normalize"]
  Check --> DB["Supabase PostgreSQL"]
  DB --> Atomic["Save inquiry and email job in one transaction"]
  Atomic --> Queue["Durable notification queue"]
  Queue --> Send["n8n email worker"]
  Send --> Resend["Resend HTTPS API"]
  Resend --> Inbox["Owner's account email"]
  Schedule["5-minute scheduler"] --> Reminder["Reminders and weekly report"]
  Reminder --> Queue
  Staff["Basic Auth staff form"] --> Update["Record contacted or closed"]
  Update --> DB
~~~

n8n keeps service credentials server-side. Supabase denies browser table access with row-level security. Email goes only to the owner's configured account.

## Free tools

- **n8n** visual workflows and forms, self-hosted on your PC with Docker.
- **Supabase** managed PostgreSQL. The [Free plan includes 500 MB](https://supabase.com/pricing); free projects may pause after a week with low activity ([recovery details](https://supabase.com/docs/guides/platform/free-project-pausing)).
- **Resend** transactional email. Its [Free plan](https://resend.com/pricing) has usage limits, and the test sender delivers only to the address on the Resend account ([sender restriction](https://resend.com/docs/knowledge-base/403-error-resend-dev-domain)).

Plan limits can change. The demo uses free-tier plans and needs internet. This is a local demo, not a public web service.

## Requirements

Windows 11, hardware virtualization enabled, at least 8 GB RAM, Docker Desktop with WSL 2, and free [Supabase](https://supabase.com/dashboard) and [Resend](https://resend.com/signup) accounts.

Node.js and npm do not need to be installed on the host. The test container supplies its own Node.js.

Docker Desktop may need Windows administrator approval to install or update WSL. Approve the Windows prompt and restart when convenient. I will not restart Windows automatically.

## Setup

1. In PowerShell from the project folder, generate private n8n encryption and runner keys:

   ~~~powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Initialize-Project.ps1
   ~~~

   This writes the ignored **.env**. Back it up with the **n8n_data** Docker volume. Losing the encryption key makes saved credentials unreadable.

2. Start Docker Desktop from the Start menu. Wait until Docker says it is running, then check **docker compose version**.

3. Create a new Supabase project. Paste and run [the database migration](supabase/migrations/001_inquiryflow.sql) in its SQL Editor.

4. In the SQL Editor, configure the owner address and leave delivery off until Resend is set up:

   ~~~sql
   update public.iflow_settings
   set owner_email='YOUR_RESEND_ACCOUNT_EMAIL',
       delivery_enabled=false,
       reminder_after_minutes=1440,
       staff_form_url='http://localhost:5678/form/inquiryflow-staff'
   where id=1;
   ~~~

5. In Supabase, copy the **Project URL** from **Connect** or **Integrations → Data API**. It looks like `https://your-project-ref.supabase.co`. In **Settings → API Keys**, open **Publishable and secret API keys** and copy the server-side **Secret key** (`sb_secret_...`), not the Publishable key. Keep it private. In PowerShell, paste the URL only:

   ~~~powershell
   $projectUrl=Read-Host 'Paste the Supabase project URL'
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Configure-Workflows.ps1 -SupabaseUrl $projectUrl
   ~~~

   This writes private imports under ignored **.local\workflows**. Never paste an API key into the command.

6. Start n8n and its JavaScript runner:

   ~~~powershell
   docker compose up -d
   docker compose ps
   ~~~

   Wait until both containers run. Open **http://localhost:5678** and create your local n8n owner account.

7. In n8n, create these credentials:

   - Create a **Custom Auth** credential named **InquiryFlow Supabase**. Search for the credential type **Custom Auth**; there is no app named HTTP. Replace the value with the server-side Secret key:

     ~~~json
     {"headers":{"apikey":"sb_secret_YOUR_SECRET_KEY"}}
     ~~~

     Use the new Secret key only in the `apikey` header. Do not put it in `Authorization: Bearer`; it is not a JWT. If your project only has legacy keys, create the new keys from this tab first.

   - Create a **Custom Auth** credential named **InquiryFlow Resend**:

     ~~~json
     {"headers":{"Authorization":"Bearer re_YOUR_RESEND_API_KEY"}}
     ~~~

   - Create a **Basic Auth** credential named **InquiryFlow Staff Form**. Choose your own strong username and password.

   n8n encrypts credentials in its persistent Docker volume. Never commit credentials or add them to an export.

8. Import four JSON files from **.local\workflows** using **Workflows → Add workflow → Import from File**. Do not import directly from **workflows**; those source exports still have a placeholder Supabase URL. n8n keeps its own copy after import, so later edits to local files do not update an already imported workflow. If you imported the source exports earlier, update their HTTP Request URLs or import the configured files and publish only those copies. For each node below, click it and choose the saved credential in the Parameters panel under Authentication. If the right credential name is already shown, it is assigned.

   - **InquiryFlow Supabase:** `Save inquiry and queue alert`; `Save status change`; `Queue eligible reminders`; `Queue weekly summaries`; `Claim queued emails`; `Authorize email send`; `Record email result`.
   - **InquiryFlow Resend:** `Send email via Resend`.
   - **InquiryFlow Staff Form:** `Agency staff update`.

   Save each workflow after checking its credential selections.

9. **Publish all four workflows** after assigning their credentials. For the staff form, open the **Agency staff update** Form Trigger node, switch to its **Production URL**, and use the URL shown there. It should be **http://localhost:5678/form/inquiryflow-staff**. Authenticate with your staff username and password. Test URLs only work while the workflow is in test mode.

10. After verifying credentials, enable sending in Supabase SQL Editor:

    ~~~sql
    update public.iflow_settings set delivery_enabled=true where id=1;
    ~~~

## Demo

1. Open **http://localhost:5678/form/inquiryflow-intake** and submit a fictional inquiry using your own email. This is the customer intake form.
2. Before changing its status, submit the exact same email, service, and message again. It should reuse the existing **new** inquiry and not send a second alert.
3. Confirm actual receipt in the email inbox for the address set as **owner_email** in Supabase (for this demo, use your Resend account email). Resend's dashboard **Logs** shows the send and delivery status; API acceptance alone does not prove delivery. Find the inquiry reference in the alert email.
4. Open **http://localhost:5678/form/inquiryflow-staff**, enter the inquiry reference, choose **contacted**, and submit. This staff form is the page shown in the screenshot. Contacted inquiries no longer receive reminders.

For a quick reminder test, turn off sending first. Change **reminder_after_minutes** to **1**, submit a fictional inquiry, and let the five-minute scheduler run. Restore **1440**, then mark the test record contacted or closed. Never send demo messages to prospective customers.

## Tests

Run JavaScript and workflow tests:

~~~powershell
docker compose -f compose.test.yaml run --rm javascript-tests
~~~

Run PostgreSQL migration, access-control, and simultaneous-duplicate tests in a disposable database:

~~~powershell
docker compose -f compose.test.yaml up -d postgres
docker compose -f compose.test.yaml run --rm database-tests
docker compose -f compose.test.yaml down -v
~~~

The test records use fake **.test** email addresses. The last command removes only the test database volume. Tests cannot verify your accounts, credentials, or inbox delivery.

## Delivery failures

Jobs have a unique event key, frozen message, and atomic claim. Before sending, n8n checks that the recipient is still the configured owner and cancels ineligible reminders. Resend receives the stable idempotency key. Temporary errors retry up to five times; ambiguous sends near the provider's [24-hour idempotency window](https://resend.com/changelog/idempotency-keys) move to manual review.

Inspect them in Supabase:

~~~sql
select id,kind,event_key,state,attempts,first_attempt_at,last_error
from public.iflow_notifications
where state in ('failed','review')
order by created_at desc;
~~~

A timeout may mean Resend already accepted the message. Check Resend's logs before replay. Only if the provider did **not** accept it, manually call **public.iflow_replay** with the notification UUID and a clear explanation of at least 10 characters. Replays retain the message and event key. Never change the key to work around an uncertain send.

## Portfolio walkthrough

Show validation, submit one fictional inquiry, demonstrate duplicate reuse while it is still new, confirm the email, then mark the inquiry contacted. Explain how the unique index, worker claim, and Resend idempotency protect retries. Say that **contacted** is manually recorded; this demo does not read replies.
