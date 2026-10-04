# Move Jefferson Alumni to GitHub and HostGator

This is a step-by-step release guide for `https://www.jeffersonalumni.com` on HostGator at the IP you supplied, `192.185.186.184`. The Windows PowerShell server is for local use. cPanel serves the PHP/MySQL version using the included Apache deployment files.

Your account is running PHP 8.5, as you confirmed. The PHP app requires PHP 8.1+ and the `pdo_mysql`, `mbstring`, `fileinfo`, and OpenSSL extensions. In cPanel, confirm the domain is assigned PHP 8.5 in **MultiPHP Manager** and that those extensions are enabled.

## Part A — Put the project in a private GitHub repository

1. Sign in to GitHub and create a **private** repository named `jefferson-alumni`. Leave the options to add a README, `.gitignore`, or license unchecked so GitHub creates an empty repository.
2. Install Git for Windows if it is not already installed.
3. Open **Git Bash** and go to the project folder:

   ```bash
   cd "/c/Users/MikeDunn/OneDrive - Patriotic Solutions, LLC/Documents/ChatGPT/Jefferson High School Alumni Management System"
   ```

4. Initialize the local repository, review the files Git will include, then commit the app:

   ```bash
   git init -b main
   git add .
   git status --short
   ```

   Check the status carefully. It must not list `data/`, private configuration, database exports, passwords, or private uploads. The supplied `.gitignore` excludes local `data/`, configuration files, and storage; it also excludes the damaged `server - Copy.ps1` file.

   If the status is clean of private data, commit and connect GitHub:

   ```bash
   git commit -m "Prepare Jefferson Alumni for HostGator"
   git remote add origin https://github.com/GITHUB_ACCOUNT/jefferson-alumni.git
   git push -u origin main
   ```

   Replace `GITHUB_ACCOUNT` with your GitHub username or organization. GitHub may open a browser to authorize Git; do not put a password or access token directly in the remote URL.

## Part B — Set up a safe staging site in cPanel

1. In cPanel, open **Domains** and add `staging.jeffersonalumni.com` with document root `public_html/alumni-test`.
2. At your DNS provider, point the `staging` hostname to `192.185.186.184` if it does not already resolve to HostGator. In cPanel, issue/enable SSL for the staging hostname before testing sign-in.
3. In cPanel File Manager, create these folders outside `public_html`:

   ```text
   /home/CPANELUSER/jefferson-private
   /home/CPANELUSER/jefferson-private/storage-staging
   /home/CPANELUSER/jefferson-private/storage-production
   ```

   Replace `CPANELUSER` with the cPanel account username. The app creates the image subfolders under the selected storage path. Keep these folders private to your cPanel account (typically directories `750`, config files `640`).

4. In **MySQL Database Wizard**, create a staging database and database user. Grant the app user SELECT, INSERT, and UPDATE access to that database. In **phpMyAdmin**, select the staging database and import the project's `schema.sql` file to create `jh_app_state`.
5. Copy `config.example.php` to `/home/CPANELUSER/jefferson-private/staging-config.php`. Edit that copy with the staging DB name, user, password, storage path `/home/CPANELUSER/jefferson-private/storage-staging`, public URL `https://staging.jeffersonalumni.com`, and the admin email if the database will be empty. Do not put real credentials in GitHub or under `public_html`.
6. In cPanel **Files → Git Version Control**, choose **Create** and clone the private GitHub repository into a repository outside the web directory, for example:

   ```text
   /home/CPANELUSER/repositories/jefferson-alumni-stage
   ```

   Choose the `main` branch. If cPanel asks for a clone URL, use `git@github.com:GITHUB_ACCOUNT/jefferson-alumni.git`.

7. To let cPanel read the private GitHub repository, enable SSH access in cPanel, create an SSH key there, and add its **public** key in GitHub under the repository's **Settings → Deploy keys**. Keep the private key on HostGator. Follow [cPanel's private repository setup guide](https://docs.cpanel.net/knowledge-base/web-services/guide-to-git-set-up-access-to-private-repositories/).
8. The checked-in `.cpanel.yml` deploys `main` to `$HOME/public_html/alumni-test`. In the cPanel Git repository, open **Manage → Pull or Deploy**, select **Update from Remote**, then **Deploy HEAD Commit**. cPanel requires a checked-in `.cpanel.yml` and a clean repository before it offers deployment. See [cPanel's Git deployment guide](https://docs.cpanel.net/knowledge-base/web-services/guide-to-git-deployment/).
9. In cPanel Terminal, go to the staging repository and lint the PHP files before opening the site:

   ```bash
   cd /home/CPANELUSER/repositories/jefferson-alumni-stage
   php -l api.php
   php -l media.php
   php -l tools/import-json.php
   ```

   `php -l` should report no syntax errors for each file. If you plan to import your existing JSON data in Part C, do not register or create any accounts yet; the importer requires an empty database. If you are starting with empty staging data, the configured `bootstrap_admin_email` must be the first registration. The staging config is selected by the staging hostname; the production config is separate.

## Part C — Move the current member records to staging

1. Make a backup of the current local `data` folder. In particular, keep a separate copy of `data/alumni.json` and its `uploads`, `event-uploads`, `home-post-uploads`, and `site-assets` folders.
2. Using cPanel File Manager, upload `alumni.json` and those four image folders to a temporary folder outside the public website, for example `/home/CPANELUSER/jefferson-private/import/`. Do not put member data in GitHub or `public_html`.
3. Confirm the staging database table exists and is empty. From cPanel Terminal, check the CLI PHP version with `php -v`. If `php` is not PHP 8.5, use the PHP 8.5 command path HostGator provides for your account.
4. From the checked-out staging repository, run:

   ```bash
   JH_CONFIG_PATH=/home/CPANELUSER/jefferson-private/staging-config.php php tools/import-json.php /home/CPANELUSER/jefferson-private/import/alumni.json --confirm-import --media-dir=/home/CPANELUSER/jefferson-private/import
   ```

   The importer refuses to overwrite an existing app row. It preserves member password hashes and copies the supported images to staging's private storage. Now open `https://staging.jeffersonalumni.com` and test sign-in and the migrated records. Keep the temporary copy until those checks pass, then remove it from the private import folder. Use test email recipients so staging actions do not contact real alumni.

## Part D — Prepare the production URL, DNS, and SSL

Do this after staging is reviewed, so the production domain points to a working deployment.

1. In cPanel **Domains**, add `jeffersonalumni.com` if it is not already assigned to the account. Set its document root to `public_html/jeffersonalumni` if cPanel permits that; otherwise record the exact document root cPanel assigns. The production Git deployment path must match it.
2. At the provider that hosts DNS, point the apex/root A record (`@`) to `192.185.186.184`. Point `www` to the same IP with an A record, or set `www` as a CNAME to the apex if your DNS provider permits it and there is no conflicting record. First compare the supplied IP to the account's **Shared/Dedicated IP Address** shown in cPanel; if they differ, use the cPanel IP.
3. Leave existing MX and email authentication records (SPF, DKIM, DMARC) unchanged unless you are intentionally moving email hosting. HostGator explains that A records route a hostname to an IP and that AutoSSL validation requires the domain to point to HostGator. DNS may take up to 24–48 hours to propagate. [HostGator DNS guidance](https://www.hostgator.com/help/article/how-to-change-dns-records) · [HostGator SSL setup](https://www.hostgator.com/help/article/hostgator-free-ssl)
4. Once both `jeffersonalumni.com` and `www.jeffersonalumni.com` resolve to this HostGator account, enable AutoSSL/SSL and confirm the certificate covers both names. Only after the certificate is active, enable **Force HTTPS Redirect** in cPanel Domains. To make the `www` URL canonical, add a permanent redirect from `jeffersonalumni.com` to `https://www.jeffersonalumni.com` in cPanel's **Redirects** page. Verify the homepage, sign-in page, and image uploads all load through HTTPS.

## Part E — Create the production Git deployment

Keep `main` as staging. The production branch will contain the same tested app plus its own `.cpanel.yml` destination.

1. In GitHub, create a branch named `production` from the tested `main` branch.
2. On the `production` branch, replace the root `.cpanel.yml` with the contents of [`deployment/production.cpanel.yml`](deployment/production.cpanel.yml). This production template points at the recommended custom document root. If cPanel assigned a different document root, change its first task to match that exact path. The staging `.cpanel.yml` in `main` must remain unchanged.

   The line in the production template is:

   ```yaml
   - export DEPLOYPATH="$HOME/public_html/alumni-test"
   ```

   Set it to the production document root from cPanel. If you selected the suggested custom root, use:

   ```yaml
   - export DEPLOYPATH="$HOME/public_html/jeffersonalumni"
   ```

   Commit this edit on the `production` branch. Leave `main` pointing at `alumni-test`.

3. In **MySQL Database Wizard**, create a separate production database and user. Import `schema.sql` into that database using phpMyAdmin.
4. Copy `config.example.php` to `/home/CPANELUSER/jefferson-private/config.php`. Set production DB credentials, storage path `/home/CPANELUSER/jefferson-private/storage-production`, `public_url` to `https://www.jeffersonalumni.com`, and the SMTP settings. Keep `bootstrap_admin_email` set to the trusted administrator's actual address if this database starts empty. The app uses `staging-config.php` only for `staging.jeffersonalumni.com`; the production URL uses `config.php`.
5. In cPanel **Git Version Control**, clone the same private GitHub repository a second time outside `public_html`, for example `/home/CPANELUSER/repositories/jefferson-alumni-production`. After cloning, open **Manage → Basic Information**, select the `production` branch in **Checked-Out Branch**, and click **Update**. Give this repository read access to GitHub with a Deploy Key as you did for staging. cPanel's branch selector checks out the selected branch and pulls its changes.
6. Before importing production records, take a fresh backup. Upload the JSON file and media folders to a private import folder, then run the importer from the production checkout with the production config:

   ```bash
   JH_CONFIG_PATH=/home/CPANELUSER/jefferson-private/config.php php tools/import-json.php /home/CPANELUSER/jefferson-private/import/alumni.json --confirm-import --media-dir=/home/CPANELUSER/jefferson-private/import
   ```

   If production will use empty/new data instead, omit this import. Do not import over an existing app row.

7. In the production repository's cPanel **Manage → Pull or Deploy** page, select **Update from Remote**, then **Deploy HEAD Commit**. Confirm the production branch's `.cpanel.yml` path exactly matches the production document root.
8. Check `https://www.jeffersonalumni.com` and `https://jeffersonalumni.com`, sign in with an existing admin account, and verify registration/approval, profile privacy, event images, posts, messaging, discussions, calendar, email delivery, and mobile layouts. After the certificate is active, confirm HTTP redirects to HTTPS.

## Releasing future changes

1. Make changes locally and commit/push them to GitHub `main`.
2. In the staging cPanel repository, run **Update from Remote → Deploy HEAD Commit** and review the staging site.
3. When approved, open a GitHub pull request from `main` into `production`. Check that the production branch's `.cpanel.yml` still targets the live document root. Merge the pull request.
4. In the production cPanel repository, run **Update from Remote → Deploy HEAD Commit**. Keep the previous production commit available so you can redeploy it if needed.

## Important notes

- GitHub, cPanel, DNS, and SSL changes must be performed while signed in to those accounts. This workspace does not have access to your HostGator or GitHub account, so it cannot create the repositories, set DNS, or deploy the site on your behalf.
- PHP lint commands to run in cPanel Terminal before launch: `php -l api.php`, `php -l media.php`, and `php -l tools/import-json.php`. I could not run those here because PHP is not installed in this workspace.
- Scheduled 7-day and 1-day event reminder emails still use `send-reminders.ps1`, which will not run on Linux. A PHP cron-job version is needed before relying on those reminders on HostGator. Other transactional and bulk email features use the SMTP settings in the private PHP config.
- This port stores the app's records in one MySQL state row to preserve the current features during migration. Writes are serialized. For an initial modest community this is a workable first deployment; for substantial growth, plan a normalized MySQL schema, rate limiting, monitoring, and tested off-server backups.
