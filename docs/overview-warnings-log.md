# Nextcloud Administration Overview — Warnings Log

Tracks every warning shown under Administration settings → Overview,
what caused it, and how it was resolved (or why it wasn't).

## Resolved

### JavaScript modules support
**Cause:** nginx's default `mime.types` doesn't map `.mjs` to a JS MIME
type, so `.mjs` files (used by some Nextcloud frontend modules) were
served as `application/octet-stream`. Browsers enforce strict MIME
checking for `type="module"` scripts and refuse to execute them.
**Fix:** Added an explicit `types` block in `nginx.conf`, including the
default `mime.types` first, then overriding `.mjs` to
`application/javascript`.

### WebDAV endpoint / OCS provider resolving / Font file loading / HTTP headers
**Cause:** All four traced back to one root issue — Nextcloud couldn't
make an HTTP(S) request to itself using its own trusted hostname
(`nc.local.test`). The `app` container had no way to resolve that
hostname (it only existed in the Mac's `/etc/hosts`, not inside any
container's network namespace), so every self-check that depends on
a successful self-request failed, even ones that look unrelated on
the surface (font/header checks piggyback on the same internal
request mechanism).
**Fix:**
1. Added `trusted_proxies`, `overwriteprotocol`, `overwrite.cli.url`,
   `overwritehost` to `nextcloud-overrides.config.php` so Nextcloud
   correctly understands it's behind a reverse proxy (Caddy) and
   knows its canonical external identity.
2. Added `extra_hosts` entry to the `app` service in
   `docker-compose.yml`, mapping `nc.local.test` to Caddy's container
   IP, so the `app` container can resolve and reach itself via the
   trusted hostname.
**Known fragility:** the Caddy container IP is currently hardcoded
and not guaranteed stable across rebuilds. This goes away entirely
once the real domain + public DNS are in place (Day 2), since
`nc.local.test`-style internal-only resolution won't be needed.

### Forwarded for headers
**Cause:** `trusted_proxies` wasn't configured, so Nextcloud ignored
`X-Forwarded-For` headers from Caddy as a security default (anti
IP-spoofing measure).
**Fix:** Same override-file change as above —
`trusted_proxies => 172.16.0.0/12` (Docker's default bridge network
range).

### Maintenance window start
**Cause:** No time configured for background jobs to prefer running,
so heavy jobs could run during peak usage hours.
**Fix:** `maintenance_window_start` set in override file.

### Default phone region
**Cause:** No ISO 3166-1 region set, so phone numbers without a
country code can't be validated.
**Fix:** `default_phone_region => 'LV'` in override file.

### Mimetype migrations available
**Cause:** New mimetypes added in recent Nextcloud versions weren't
migrated yet (not automatic, since it can be expensive on large
instances).
**Fix:** Ran `occ maintenance:repair --include-expensive`.

### Configuration server ID
**Cause:** `serverid` unset (distinct from `instanceid`, which is
auto-generated at install and should never be manually changed).
Intended to distinguish multiple physical servers in a cluster.
**Fix:** `serverid => 0` in override file. Verified via community
docs before applying, since an earlier draft of this fix nearly set
the wrong config key (`instanceid`) — caught before running.

## Still open — to investigate

### .well-known URLs (webfinger)
Only `/.well-known/webfinger` still failing; carddav/caldav redirects
already handled in nginx config. Likely a route Nextcloud added in a
newer version that our nginx config (adapted from older docs) doesn't
yet cover.

## Open — judgment calls / accepted gaps

### AppAPI deploy daemon
Optional feature for installing external apps (Ex-Apps). No deploy
daemon registered. Likely to document as an intentional scope
decision rather than fix, unless time allows.

### Second factor configuration
2FA providers available but not enforced. Policy decision, not a
bug — need to decide whether to enforce for the demo.

### Email test
SMTP not configured/verified. Requires real mail credentials.
Likely to document as an accepted gap unless a throwaway SMTP
account is available.

### Errors in the log
**Cause:** Not a bug — two `level:2` (warning) log entries, both
simply "Login failed: admin (Remote IP: ...)" from earlier manual
testing (mistyped password before credentials were finalized).
Nextcloud logs failed logins as warnings by design.
**Resolution:** No fix needed. Will age out of the Overview warning
naturally as no new failed logins occur; documenting as expected
behavior, not a defect.

### Cron last run
**Cause:** Background jobs mode defaulted to AJAX (triggered only by
browser page loads), and nothing was actually invoking `cron.php` on
a schedule.
**Fix:** Added a dedicated `cron` service in `docker-compose.yml` —
same `nextcloud:fpm` image, sharing the `nc_data` volume, running the
image's built-in `/cron.sh` entrypoint (loops `occ system:cron` every
5 minutes). Set `backgroundjobs_mode` to `cron` via occ.
**Note on persistence:** `backgroundjobs_mode` is an *app config*
value (stored in the database, `oc_appconfig` table), not a *system
config* value — it cannot be set via `nextcloud-overrides.config.php`
the same way as system settings. It survives normal restarts (DB
volume persists) but needs to be re-applied via `occ` after any full
`make destroy` that resets the database to zero. This belongs in the
Ansible post-install task list, not the PHP override file.

**Update:** A third log warning appeared after the cron job started
running — also benign: "Skipping updater backup clean-up - could not
find updater backup folder..." This is cron correctly reporting there
is nothing to clean up on a fresh install with no update history yet.
Not a defect.

## Accepted gaps — intentional, documented for the interview

### AppAPI deploy daemon
Not configured. This feature supports installing "Ex-Apps" (external
apps run as separate containers/daemons) — not required by any task
deliverable. Left unconfigured as an intentional scope decision.

### Second factor configuration
2FA providers are available (shipped with Nextcloud by default) but
not enforced. This is a policy decision, not a technical gap — left
unenforced for the demo since forcing 2FA setup would complicate the
live walkthrough without adding to what's being evaluated. Would be
enabled and enforced org-wide in a production deployment.

### Email test
SMTP not configured. Requires real, working mail credentials
(sending domain, auth) which weren't available/practical to set up
for a local demo instance. In production, this would be a required
piece (password resets, notifications) via a proper transactional
email provider.

## Follow-up improvement — WebDAV self-connect fix hardening

**Original fix** used a hardcoded Caddy container IP in `extra_hosts`
on the `app` service. This was flagged as fragile at the time — IPs
on Docker's default bridge network are assigned dynamically and can
change across rebuilds, meaning the fix could silently break after
any full teardown/recreate.

**Improved fix:** replaced with a named Docker network
(`nextcloud_net`) shared by all services, with Caddy given an
explicit network alias of `nc.local.test`. Any container on the
network now resolves that hostname via Docker's built-in DNS,
automatically following whatever IP Caddy currently has — no
hardcoding, no fragility across rebuilds. Verified working via
`curl` self-connection test after full recreation.

## Lessons from testing full destroy/rebuild ("atkārtoti izvietojama no nulles")

Running `make destroy` followed by `make deploy` against a truly
empty state (no volumes, no containers) surfaced two real bugs that
manual testing never exposed, because manual testing always happened
against an already-installed instance:

### Bug 1 — Ansible readiness check passed before Nextcloud finished installing
**Cause:** The original "wait for app ready" task only checked that
`occ status` exited successfully — but that just means PHP-FPM is
responding, not that Nextcloud's first-run install (schema creation,
admin user, etc.) has completed. On a truly fresh database, the
playbook proceeded to run `occ config:app:set` before install had
finished, and failed with "Nextcloud is not installed."
**Fix:** Changed the wait condition to explicitly check for
`"installed: true"` in the `occ status` output, not just exit code,
with more retries to comfortably cover install time.

### Bug 2 — single-file bind mount into a fresh named volume failed
**Cause:** `nextcloud-overrides.config.php` was bind-mounted directly
as a single file into `/var/www/html/config/`. On a brand new, empty
named volume, Docker attempts to create that exact file path as a
mountpoint before the volume has any contents — this is a known,
widely-reported Docker bind-mount limitation (confirmed via multiple
long-standing nextcloud/docker GitHub issues), not unique to this
setup. It only ever worked in earlier manual testing because the
volume already had a populated `config/` directory from a prior
install.
**Fix:** Switched to the pattern the nextcloud/docker maintainers
themselves document for this exact case — copy the file in via
`docker compose cp` as an Ansible task, run *after* confirming
Nextcloud's install has completed, followed by a `chown` to
`www-data:www-data` since files copied in this way land owned by
root by default.

### Takeaway
Both bugs were invisible until testing genuinely started from zero.
This is the practical justification for treating "redeployable from
scratch" as something to actually test, not just something the
tooling nominally supports — manual, incremental testing on an
already-running stack systematically hides exactly this class of bug.

## Follow-up bug — stale config after switching from bind-mount to copy-in

**Context:** After the earlier bind-mount race-condition fix, the
config override file is copied into the container once via
`docker compose cp` during Ansible's deploy run, rather than being
continuously bind-mounted.

**Bug:** When migrating from the placeholder hostname
(`nc.local.test`) to the real domain (`nikolajs-nextcloud.lat`), the
*local* override file on disk was updated correctly, but the
*already-running* app/cron containers still had the old copied-in
version from their last deploy. Result: Nextcloud correctly served
HTTPS on the new domain at the web-server layer, but its own
application-level redirects (`overwritehost`) still pointed at the
dead old hostname — a redirect loop to a domain that no longer
resolved to anything.

**Cause, precisely:** copy-in is a one-time snapshot, not a live
sync. Editing the source file after deploy has no effect until the
next full `make deploy`/`make redeploy` cycle re-triggers the copy.

**Immediate fix:** manually re-ran `docker compose cp` for both `app`
and `cron` containers, then reset ownership to `www-data:www-data`.

**Process takeaway:** any time the override file's content changes
(e.g., hostname migration), a `make redeploy` (or at minimum
re-running the copy + ownership Ansible tasks) is required — simply
editing the file is not sufficient with the current design. This is
a known, documented tradeoff of the copy-in approach chosen to avoid
the earlier bind-mount bug; the alternative would be re-introducing
a bind mount but only after ensuring the config directory already
exists in the volume (e.g. via an init container), which was judged
not worth the added complexity for this project's scope.

## Monitoring — Prometheus + Grafana

Set up node_exporter (host metrics) and mysqld_exporter (MariaDB
metrics), scraped by Prometheus, visualized via two imported
community Grafana dashboards (IDs 1860, 7362). Both exporters
confirmed healthy via Prometheus's targets API. Some dashboard
panels show "No data" — expected, since these dashboards cover
configurations (multi-disk, replication, systemd services) not
present in this single-node Docker Desktop setup; all core panels
(CPU, memory, disk, DB connections, query throughput) are populated
correctly.

Bug hit along the way: mysqld_exporter's newer version dropped
support for the DATA_SOURCE_NAME environment variable in favor of a
mounted .my.cnf-style config file — fixed by switching to the
documented config-file approach.

## Log aggregation — Loki + Grafana Alloy (corrected from Promtail)

Initial setup used Promtail (Loki's traditional log-shipping agent).
Caught before finalizing that Promtail reached end-of-life on
March 2, 2026 — no further security patches, bug fixes, or updates.
Grafana's officially recommended replacement is Grafana Alloy (their
unified OpenTelemetry-based collector), which absorbed Promtail's
functionality.

Switched to Alloy using its component-based config syntax
(discovery.docker → discovery.relabel → loki.source.docker →
loki.write), functionally equivalent to the Promtail config it
replaced. Verified working: Alloy discovers all running containers,
tags logs with their container name, ships to Loki; confirmed via
Loki's labels API and direct querying in Grafana's Explore view,
showing real-time Nextcloud request logs (WebDAV PROPFIND, OCS API
calls from the desktop client).

This is a good example of why current tooling knowledge matters even
for infrastructure that "just works" — Promtail would have functioned
identically today, but shipping something already unsupported would
be a real, avoidable technical debt item in an actual production
deployment.

## Ansible coverage gap — MySQL exporter user

**Finding:** After adding Prometheus/Grafana/exporters/Loki/Alloy via
direct docker-compose.yml edits, a full `make redeploy` test revealed
that while all 11 containers came up correctly (Ansible's
`docker compose up -d` picks up the entire compose file automatically,
no extra tasks needed for that part), `mysqld_exporter` failed to
authenticate — because the dedicated `exporter` MySQL user had only
ever been created manually, once, and was never captured in Ansible.
A fresh database (from a full volume wipe) simply didn't have it.

**Fix:** Added an idempotent Ansible task (`exporter_user.yml`) that
waits for MariaDB's healthcheck, reads both the root and exporter
passwords from `.env`, and creates the user with `CREATE USER IF NOT
EXISTS` + the required grants. Verified via full destroy/redeploy
cycle — mysqld_exporter now connects successfully with zero manual
steps.

**Process note:** also hit a regression during this fix where an
earlier `.bak` restore (used to undo an unrelated botched edit)
accidentally reverted a previously-fixed bug (the `../` vs `./` path
issue from the config-copy tasks) because it rolled back further
than intended. This is a direct, concrete illustration of why ad-hoc
`.bak` files are a weak substitute for real version control — a
motivating reason to move this project into git sooner rather than
later.

## Operational note — desktop client after a full rebuild

A full `make destroy` + `make deploy` (or `make redeploy`) wipes the
database, which recreates the admin account from scratch. If the
Nextcloud desktop client on the same Mac was already connected
before the rebuild, it will keep retrying its old, now-invalid
session token — this produces repeated 401s on WebDAV PROPFIND
requests, which can escalate into Nextcloud's brute-force/rate-limit
protection (429 Too Many Requests) if left retrying for a while.

This is a testing artifact specific to repeatedly destroying and
recreating the entire server out from under an already-connected
client — not a realistic production scenario, since a real server
isn't normally rebuilt from zero while live users are connected.

**Practical fix:** after any full rebuild, remove and re-add the
account in the desktop client to force a fresh session token. If the
rate limiter has already triggered, also run:
`docker compose exec app php occ security:bruteforce:reset <ip>`
using the IP shown in nginx's access log (`docker compose logs web`).

## Full clean-clone verification test

To verify the "redeployable from scratch" requirement beyond doubt,
the entire project directory was moved aside, and the repository was
freshly cloned from GitHub into a clean location. Only the two
intentionally-gitignored secret files were recreated
(`compose/.env`, `compose/mysqld_exporter.cnf`) using their
`.example` templates, as any new deployer would have to. `make
deploy` was run against this clean clone with no other manual steps.

**Result:** all 11 containers started correctly. Caddy's DNS-01
challenge flow, the config-override copy-in mechanism, and every
other piece worked exactly as they had in the original working
directory — genuine confirmation that nothing was accidentally
relied upon that wasn't actually committed to the repository.

**Finding:** hit Let's Encrypt's duplicate-certificate rate limit
(5 real certificates per exact domain set per 168 hours) — a direct
consequence of the number of full rebuilds performed during today's
development and testing. This is a real, expected operational
constraint, not a bug. Verified the full mechanism was still correct
by temporarily pointing Caddy at Let's Encrypt's staging CA
(`ca https://acme-staging-v02.api.letsencrypt.org/directory` in the
Caddyfile) — obtained a staging certificate successfully with no
errors, confirming the entire DNS-01 flow, Cloudflare API
integration, and Caddy configuration are correct. Reverted to the
production CA config (the default, already committed) afterward;
production certificate issuance will resume automatically once the
rate-limit window clears, with no code changes needed.

This is a genuine, non-hypothetical illustration of why the earlier
design decision to preserve Caddy's cert storage volume across
`make destroy` matters in practice — and a real, honest thing to
discuss if asked about rate limits or certificate management in the
interview.

## Restart policy — always vs unless-stopped

Initially used `restart: unless-stopped` on all services. After a
full Mac restart, containers did not come back up automatically.

**Cause:** `unless-stopped` deliberately does not restart a container
if it was last stopped manually (e.g. via `docker compose stop`,
which was used for clean shutdowns earlier in this project) — Docker
persists that "manually stopped" intent across daemon/host restarts.

**Fix:** changed to `restart: always`, which restarts containers
unconditionally after any Docker daemon restart, including after a
manual stop. This matches the actual goal (stack is running whenever
the laptop is on, no manual intervention needed) more precisely than
`unless-stopped` did.

## Background job error - MigrateBackgroundImages NotFoundException

**Observed:** An Error-level log entry (not just Warning) for
`OCA\Theming\Jobs\MigrateBackgroundImages`, failing with
`NotFoundException: /appdata_<instanceid>/theming/global`.

**Cause:** This background job (queued automatically by
`occ maintenance:repair --include-expensive`) migrates legacy
dashboard background images into the theming app's storage - a
migration path intended for instances upgrading from an older
Nextcloud version that already had custom background images set.
This instance is a fresh install with no theming customization ever
configured (confirmed by the repair command's own earlier output:
"Theming is not used to provide a logo") - the source folder the job
expects simply doesn't exist, and the job throws instead of no-op'ing
gracefully for that case.

**Assessment:** benign - an edge case in Nextcloud's own migration
job when run against a fresh install with nothing to migrate, not a
defect in this deployment. No action taken; expected to stop
recurring once the job's internal retry logic exhausts.

## Log warning - "Value type is set to zero (0) in database"

Confirmed benign via Nextcloud's own source
(lib/private/AppConfig.php): this is a hardcoded, generic warning
logged whenever an app config value is stored with an untyped/mixed
type - the "fine only during upgrade from 28 to 29" text is stale,
leftover wording from whenever this check was written, and fires on
fresh installs unrelated to any actual upgrade (confirmed via a
matching community bug report showing the identical message on an
unrelated version/context). Not indicative of a problem with this
deployment.

## Why "Errors in the log" reappears after every fresh deploy

This warning is expected to resurface after any `make deploy`/
`make redeploy`, and that is not a regression - it's a structural
property of what the check does and what a fresh install produces.

**What triggers it, every time, on a brand-new install:**
1. `Skipping updater backup clean-up - could not find updater backup
   folder` - cron correctly reports there's nothing to clean up,
   since a fresh install has no update history yet.
2. `Value type is set to zero (0) in database. This is fine only
   during the upgrade process from 28 to 29.` - confirmed via
   Nextcloud's own source (lib/private/AppConfig.php) to be a
   hardcoded, generic warning with stale wording, logged whenever an
   app config value is stored with an untyped/mixed type. Fires
   regardless of actual version; unrelated to any real upgrade.

Both are level-2 (warning), not level-3 (error) severity, confirmed
by reading the raw log entries directly each time this recurred.
Neither indicates a defect in this deployment - they are Nextcloud's
own internal bookkeeping being logged at a level the setup check
surfaces, on a system that (by design, per the from-zero testing in
this project) gets freshly reinstalled repeatedly.

**Why this is not truncated away permanently:** doing so would only
hide it until the next `make redeploy`, at which point the exact same
two entries reappear from the exact same fresh-install conditions.
Truncating the log is a cosmetic reset, not a fix, and re-hiding it
every time would misrepresent the deployment's actual state rather
than explain it. This section exists so that reappearance is expected
and explained, not something to chase away each time.
