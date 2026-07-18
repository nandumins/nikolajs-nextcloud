# Nextcloud + MariaDB - Technical Summary

## Overview

Nextcloud + MariaDB, deployed via Docker Compose and Ansible on an
M1 MacBook Pro. Caddy fronts everything with HTTPS using a real,
publicly-trusted Let's Encrypt certificate (DNS-01 via Cloudflare,
on a real purchased domain). Includes monitoring (Prometheus +
Grafana) and log aggregation (Loki + Grafana Alloy).

See `architecture.mmd` for the full diagram.

## Key technical decisions

- **Caddy, not nginx+certbot** - automatic HTTPS, built-in DNS-01
  support via a plugin, far less configuration.
- **DNS-01 via Cloudflare, not HTTP-01** - the certificate can be
  obtained without the laptop being publicly reachable. Cloudflare
  is used ONLY for DNS + the ACME challenge, NOT for routing traffic.
- **Domain points at 127.0.0.1** - a deliberate choice. The task
  requires a real, trusted certificate and a working desktop client
  - not public internet exposure, which would add real risk (port
  forwarding, network dependency) with no actual requirement behind it.
- **nginx + php-fpm, not Apache** - precise control over upload
  limits and `.well-known` routing.
- **Config override file copied in, not bind-mounted** - a Docker
  limitation was found (a single-file mount into a fresh, empty
  volume fails). Solved by copying the file in as an Ansible step.

## Verified working (not assumed)

- ✅ Real, publicly-trusted certificate - verified with `curl`
  WITHOUT the `-k` flag, and with macOS's own certificate inspector
- ✅ Desktop client syncs with zero certificate warnings
- ✅ 2GB file uploaded and verified on the server (exact byte count)
- ✅ Full environment rebuilt from zero multiple times, including
  from a genuinely fresh `git clone` - proven, not just claimed
- ✅ Monitoring, log aggregation, AND automated certificate renewal
  - all three, though the task only required one

## Administration → Overview

10 warnings resolved (WebDAV, MIME types, reverse proxy headers,
cron configuration, etc.). 3 deliberately left, with reasoning:

- **AppAPI deploy daemon** - not required for this task
- **2FA** - available but not enforced (a deliberate choice, not a
  technical gap)
- **Email configuration** - would need real SMTP credentials, not
  practical for a local demo environment

## Interesting findings along the way

- **Let's Encrypt rate limit** - several full rebuild cycles used up
  the 5-certificates-per-week limit. Diagnosed, verified against the
  staging CA, and permanently fixed - `make destroy` now preserves
  certificate storage.
- **Promtail end-of-life** - the originally chosen log agent
  (Promtail) was found to be unsupported (EOL 2026-03-02) before
  finishing the build; switched to Grafana Alloy.
- 12 real technical issues were found and fixed during testing in
  total - full list in `overview-warnings-log.md`.

## What's missing for production

No high availability (single host), no public exposure (deliberate),
secrets stored in a `.env` file rather than a vault, no tested
backup/restore process, no SSO, no WAF/antivirus, no CI/CD deployment
pipeline (lint checks only), 2FA and email not configured.

