# Jefferson Alumni

A dependency-free, locally runnable Jefferson High School alumni community app. The public landing page at `/` advertises the Eagle community and includes a read-only upcoming-events calendar. Member sign-in and the private community are at `/community`. The app includes member registration and sign-in, password hashing, email verification and password recovery, member profiles and directory, community posts, events and RSVPs, event invitations, private messages, admin permissions, and CSV member import/export. The school logo is used in the page header and favicon; the site theme uses maroon, gold, and white.

## Run locally

Open Windows PowerShell in this folder and run:

```powershell
.\server.ps1
```

Then open http://localhost. Stop the server with Ctrl+C. If the server does not stop, open a second PowerShell window in this folder and run `.\stop-server.ps1`. The first run creates `data/alumni.json`; this file stores member and community records on the server machine. Back it up and restrict access to it.

## Current scope

Anyone can register as an alum, teacher, or staff member. After initial setup, self-registered accounts must be approved by a user with the separate **Approve new members** permission and verify their email before signing in. The first account on a new installation is the bootstrap site administrator (approved immediately so setup can proceed); all later self-registrations require approval. Administrators can grant separate permissions for profile and event management, community posts, homepage announcements, member approvals, public-content moderation, activity-log access, site customization, and permission management. Profile managers can create accounts, reset member passwords, set profile visibility for each member, and import/export CSV files. Members can also choose which individual profile fields signed-in members can see. Profiles include phone, occupation, employer, interests, and website in addition to the existing details. Imports accept up to 1,000 rows and skip invalid or duplicate email addresses. Imported members receive a seven-day link to set their password and verify their email. Events support categories, start/end time, capacity, and registration links. The public homepage and signed-in events page offer an iCalendar (`.ics`) download. Members can invite other members to an event by email and RSVP; invited members see the invitation when signed in. Event organizers receive an email when a member changes their RSVP. Members can upload a PNG, JPEG, or WebP profile photo (up to 2 MB), browse the directory, update their own profile, post community notes, suggest events, and send private one-to-one messages. Signed-in members can report public homepage announcements; moderators can dismiss reports or move an announcement to member-only visibility. Selected administrative actions are recorded in the activity log. Before every database save, the previous database file is copied into `data/backups`; the app keeps the 30 newest snapshots. Site access administrators can download a current full JSON backup from Administration. Profile photos are in `data/uploads`; messages are stored in `data/alumni.json` and returned only to their sender and recipient. The member home page also shows an in-app reminder for events a member is attending within the next week.

Members can start discussions visible to all members, a class year, a saved group, or selected individuals. Group creators and profile administrators can manage group membership; discussion creators and profile administrators can update selected-member audiences. Administrators can grant **Send bulk email** separately. Bulk messages can target all verified members, one class, a saved group, or selected members; recipients receive separate messages (their addresses are not exposed), and one send is limited to 500 people. SMTP must be configured before using bulk email.

### Email configuration

Email is optional for local development. To send account verification, password recovery, RSVP notifications, and event reminders, configure these environment variables before starting the server:

```powershell
$env:JH_SMTP_HOST = 'smtp.example.com'
$env:JH_SMTP_PORT = '587'
$env:JH_SMTP_FROM = 'alumni@example.com'
$env:JH_SMTP_USERNAME = 'smtp-user'
$env:JH_SMTP_PASSWORD = 'smtp-password'
$env:JH_PUBLIC_URL = 'https://alumni.example.org'
```

SMTP uses TLS by default. Set `JH_SMTP_SSL` to `false` only if your provider requires unencrypted SMTP. `JH_PUBLIC_URL` must be the public HTTPS address members use so links in email resolve correctly. Keep SMTP credentials out of the JSON database and source control. These PowerShell variables apply to that shell session; configure persistent user or machine environment variables on the server before using Task Scheduler.

### Scheduled event reminders

Run `send-reminders.ps1` once a day through Windows Task Scheduler. It emails verified members with a “going” RSVP seven days and one day before an event. It records sent reminder keys in `data/event-reminders.json` to avoid sending the same reminder more than once. Create a daily task with this action (update the folder path for your installation):

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\Jefferson High School Alumni Management System\send-reminders.ps1"
```

The task must run under an account that can read the app's SMTP environment variables and write to its `data` folder.

For HostGator/cPanel deployment, including the PHP/MySQL staging site, cPanel Git setup, HTTPS, private storage, SMTP, and importing the current JSON records, follow [DEPLOYMENT-HOSTGATOR.md](DEPLOYMENT-HOSTGATOR.md). The Windows PowerShell server remains the local development option; cPanel uses the PHP/MySQL deployment files.
