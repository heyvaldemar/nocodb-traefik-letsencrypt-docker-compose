# NocoDB + Traefik + Let's Encrypt on Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/nocodb-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/nocodb-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Contents

- [What this is](#what-this-is)
- [What the defaults decide for you](#what-the-defaults-decide-for-you)
- [Prerequisites](#prerequisites)
- [Getting started](#getting-started)
- [Supply chain trust](#supply-chain-trust)
- [Production checklist](#production-checklist)
- [Unattended updates](#unattended-updates)
- [Backups](#backups)
- [Redis](#redis)
- [Container hardening](#container-hardening)
- [Testing](#testing)
- [Security notes](#security-notes)
- [About the maintainer](#about-the-maintainer)

## What this is

[NocoDB](https://github.com/nocodb/nocodb) puts a spreadsheet interface and a REST API on top of a database: tables, views, forms and permissions for people who would otherwise share a spreadsheet, and connections to databases you already run. This repository runs it on one host behind Traefik with automatic Let's Encrypt TLS, on PostgreSQL 17, with Redis available as an option, daily backups of the database and the attachments that are read back before they count, and two restore scripts CI runs on every change.

NocoDB holds two kinds of secret: the accounts of the people who use it, and the credentials of every database it is connected to. The defaults below are about keeping both where they belong, and each one is measured against the real stack in CI, most of them both ways.

**Licence.** NocoDB is published under the [Sustainable Use License 1.0](https://github.com/nocodb/nocodb/blob/develop/LICENSE.md), which is not an open-source licence in the OSI sense: it allows use for your own internal business purposes and for non-commercial or personal use, and it does not allow offering NocoDB to others as a paid service. Read it before you deploy for an organisation. This template is MIT, pulls NocoDB's own image and copies none of its code.

## What the defaults decide for you

**The super admin exists before the site does.** Without `NC_ADMIN_EMAIL` and `NC_ADMIN_PASSWORD`, NocoDB makes super admin of whoever signs up first, and on a public hostname that is a race against everyone who finds it. Here both are required: `docker compose up` stops and names the missing one. The account is created on the first start and its email and password are set again from `.env` on every start, so `.env` is where they change. CI checks that NocoDB reports no first user waiting, that the admin from `.env` signs in as super admin, and that a stranger who signs up gets a viewer account that cannot create a base. Signup stays open for invitations; to refuse strangers outright, turn on invite-only signup in NocoDB's account settings (CI does, and the next stranger is refused).

**The secrets stay out of the backups.** NocoDB signs sessions with a secret it makes and stores in its own database when none is given, which puts the key to every session into every database backup. Here `NOCODB_JWT_SECRET` comes from `.env`, and CI checks the database holds none. The databases you connect NocoDB to are a larger secret: their connections, passwords included, are kept in NocoDB's database, and without an encryption key they are plain JSON. Measured on 2026.10.0, with no key, a backup held a connected database's password in clear text; with `NOCODB_CONNECTION_ENCRYPT_KEY` set, NocoDB encrypted the stored connection on its next start ("Encrypted source external"), the backup held the password nowhere, and the connection still read its table. Both are required here. Under any other key the connection does not open, so the key belongs with the `.env`, not with the backups, and a restore needs the key the backup was made under.

**No connections into private networks.** A data source on a private address is refused unless `NOCODB_ALLOW_LOCAL_EXTERNAL_DBS=true`. That includes the PostgreSQL in this stack, which holds every account's password hash: CI asks NocoDB to connect to it and gets "Connection to internal hosts is not allowed". The refusal is also applied when a connection is used, not only when it is made: a connection added while private networks were allowed is refused once they are not. Turn it on only to connect a database on your own network, knowing that anyone who may add a data source can then reach that network from this host.

**Attachments answer only to signed, expiring links.** With `NC_SECURE_ATTACHMENTS` on, an attachment's plain URL is a 404 and the signed URL NocoDB hands its users is a 200 until it expires; a forged signature is a 404. CI fetches the same file with the setting off, and the plain URL is served to anyone who has it.

**The health check reads the database.** NocoDB's `/api/v1/health` answers 200 from the process alone: measured with PostgreSQL stopped, it still said 200. The check here asks `/api/v2/meta/nocodb/info`, which reads the database and answers 400 when it cannot; CI stops PostgreSQL, sees both answers, and watches Docker mark NocoDB unhealthy and then healthy again.

**The audit log keeps the client's address.** NocoDB trusts no `X-Forwarded-For` by default, so behind a proxy it logs the proxy as the address of every change. Measured: every record anyone added was logged from Traefik's container address. Here `NC_TRUST_PROXY=1` trusts exactly the one hop this topology has (NocoDB is published nowhere, so every request comes through Traefik), and CI adds a record with a forged `X-Forwarded-For: 203.0.113.77` and reads back the address Traefik saw, not the forged one.

**Telemetry is off.** `NC_DISABLE_TELE=true`; NocoDB's own info endpoint reports `teleEnabled: false`, and CI reads it.

## Prerequisites

- Docker Engine with Compose v2.5 or newer.
- A host with at least 2 GB of RAM free for the stack (NocoDB's ceiling is 2 GB; see [Container hardening](#container-hardening)).
- A DNS record for `NOCODB_HOSTNAME` pointing at the host, and ports 80 and 443 reachable for Let's Encrypt's TLS challenge.

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/nocodb-traefik-letsencrypt-docker-compose
cd nocodb-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create nocodb-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
$EDITOR .env
# ^ Required: NOCODB_HOSTNAME, NOCODB_ADMIN_EMAIL, NOCODB_ADMIN_PASSWORD,
#   NOCODB_DB_PASSWORD, NOCODB_JWT_SECRET, NOCODB_CONNECTION_ENCRYPT_KEY,
#   TRAEFIK_HOSTNAME, TRAEFIK_ACME_EMAIL, TRAEFIK_BASIC_AUTH.
#   .env.example has a generation command for each secret.

# 4. Deploy
docker compose -f nocodb-traefik-letsencrypt-docker-compose.yml -p nocodb up -d
```

NocoDB runs its migrations on the first start; within a minute or two `https://${NOCODB_HOSTNAME}` serves the sign-in page. Sign in with the admin from `.env`.

### What success looks like

```bash
# Every service healthy or up, and nocodb-init exited 0:
docker compose -f nocodb-traefik-letsencrypt-docker-compose.yml -p nocodb ps -a

# NocoDB answers through Traefik, from its database:
curl -fs -o /dev/null -w "%{http_code}\n" "https://${NOCODB_HOSTNAME}/api/v2/meta/nocodb/info"
# Expected: 200
```

### Common first-deploy issues

- **NocoDB exits at once, "Missing admin password" or "Invalid admin password".** NocoDB wants 8 or more characters with an upper-case letter, a digit and a special character; `.env.example` has a command that makes one.
- **Cert issuance fails.** DNS has not propagated, or port 80 is not reachable from the internet.
- **Networks not found.** Step 2 was skipped.
- **Invites are not mailed.** SMTP is unset by default. Set the `NOCODB_SMTP_*` variables, or copy invite links from the UI.

## Supply chain trust

Four images ([`nocodb/nocodb`](https://hub.docker.com/r/nocodb/nocodb), [`postgres`](https://hub.docker.com/_/postgres), [`redis`](https://hub.docker.com/_/redis), [`traefik`](https://hub.docker.com/_/traefik)) pinned to `tag@sha256:<digest>` as interpolation defaults in the compose `x-images` block. `git pull` alone delivers the tested combination; an `*_IMAGE_TAG` variable in `.env` overrides deliberately.

| Image | Source | Pinned |
|---|---|---|
| `nocodb/nocodb` | [github.com/nocodb/nocodb](https://github.com/nocodb/nocodb), Sustainable Use License 1.0, published by NocoDB | tag and digest, in the compose file |
| `postgres` | Docker Official Image | tag and digest |
| `redis` | Docker Official Image | tag and digest, used only with the `redis` profile |
| `traefik` | Docker Official Image | tag and digest |

NocoDB's image ships its server as an obfuscated bundle, so what runs is NocoDB's build, not something reproducible from its public repository; this template's claims are about the image's behaviour, measured.

Two override levels exist per image. `<PREFIX>_IMAGE_VERSION` in `.env` swaps only the version of that image (Compose then pulls the tag, without a digest) and leaves every other pin as tested; `<PREFIX>_IMAGE_TAG` replaces the whole reference, digest included. The variable names are listed in `.env.example`. Nested defaults need Docker Compose v2.5 or newer (2022); v2.0 to v2.4 leave the inner `${...}` unexpanded and `docker compose up` fails with an invalid reference instead of deploying something unexpected.

The daily Pin Freshness workflow re-resolves each pin against its registry and compares the pinned NocoDB and Traefik versions against their latest releases. GitHub Actions are pinned by commit SHA; Dependabot keeps those fresh.

### Verify what you deploy

Every release carries three files made on GitHub's runner with a short-lived identity and no stored key: `nocodb-traefik-letsencrypt-docker-compose-<tag>.tar.gz`, a `git archive` of exactly the tree the tag points at; `nocodb-traefik-letsencrypt-docker-compose-<tag>.tar.gz.sigstore.json`, a keyless [Sigstore](https://www.sigstore.dev/) signature over it; and `nocodb-traefik-letsencrypt-docker-compose-<tag>.intoto.jsonl`, [SLSA](https://slsa.dev/) build provenance from the SLSA generator. To check them with nothing from this repository trusted:

```bash
cosign verify-blob nocodb-traefik-letsencrypt-docker-compose-<tag>.tar.gz \
  --bundle nocodb-traefik-letsencrypt-docker-compose-<tag>.tar.gz.sigstore.json \
  --certificate-identity-regexp '^https://github.com/heyvaldemar/nocodb-traefik-letsencrypt-docker-compose/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

slsa-verifier verify-artifact nocodb-traefik-letsencrypt-docker-compose-<tag>.tar.gz \
  --provenance-path nocodb-traefik-letsencrypt-docker-compose-<tag>.intoto.jsonl \
  --source-uri github.com/heyvaldemar/nocodb-traefik-letsencrypt-docker-compose \
  --source-tag <tag>
```

The workflow that makes them is [`release-assets.yml`](.github/workflows/release-assets.yml).

## Production checklist

- [ ] **Generate every secret** with the commands in `.env.example`; regenerate the Traefik dashboard hash.
- [ ] **Keep `.env` and the backups apart.** The backups hold every record and every account's password hash; `.env` holds the two keys that are deliberately not in them.
- [ ] **Decide on signup.** Strangers can sign up as viewers who see nothing they are not invited to; turn on invite-only signup if nobody should.
- [ ] **Configure SMTP** for invites and password resets.
- [ ] **Leave `NOCODB_ALLOW_LOCAL_EXTERNAL_DBS` off** unless a database on your own network is the point.
- [ ] **Host-mount or replicate the backup volumes** for disaster recovery.
- [ ] **Read NocoDB's release notes before a major move**; `update.sh` will not cross a template major on its own.

## Unattended updates

Releases are the update channel: a tag is cut only after CI has booted the pinned images, upgraded from the previous release on the same volumes, run every check below through Traefik and restored a backup. `update.sh` moves a deployment to the newest tag and nothing else:

```bash
./update.sh --dry-run   # show what would be applied
./update.sh             # update within the current major and redeploy
```

Put it on a timer for hands-off minor and patch updates:

```bash
# crontab -e
17 5 * * *  /opt/nocodb-traefik-letsencrypt-docker-compose/update.sh >> /var/log/nocodb-update.log 2>&1
```

The script refuses to cross a major template version on its own, refuses to touch a checkout with local modifications, and names any new required variable before anything moves. It is a host-side script on purpose: an in-stack updater needs the Docker socket, which is root on the host.

## Backups

The `backups` container runs on a loop: an initial delay (`NOCODB_BACKUP_INIT_SLEEP`, default 30m), then every `NOCODB_BACKUP_INTERVAL` (default 24h) a `pg_dump` of NocoDB's database and a `tar.gz` of `/usr/app/data`, each written under a `.partial` name, read back whole (`gzip -t` for the dump, `tar -tzf` for the archive), and only then renamed into place. Files older than `NOCODB_POSTGRES_BACKUP_PRUNE_DAYS` and `NOCODB_DATA_BACKUP_PRUNE_DAYS` (default 7) are pruned. Each artefact logs `... backup OK: <file> (<bytes> bytes)` or `FAILED` (kept as `<file>.failed`). Grep the log for `FAILED` from your monitoring.

**What a backup set holds:** the database is everything but the attachments: every base, table, row, view, comment and setting, every account with its password hash, and the connections to other databases, encrypted with `NOCODB_CONNECTION_ENCRYPT_KEY`. The archive holds the attachments (`nc/uploads`). It does not hold the session-signing secret or the encryption key; those are in `.env`.

```bash
docker compose -p nocodb logs backups | tail -5
docker compose -p nocodb exec backups ls -la /srv/nocodb-postgres/backups/ /srv/nocodb-application-data/backups/
```

**Restore** with the two scripts (`chmod +x *.sh` once), from the same cycle:

```bash
./nocodb-restore-database.sh                    # list the dumps and ask
./nocodb-restore-application-data.sh            # list the archives and ask
```

Each takes a file name as its argument too. The database script stops NocoDB, replaces the database and starts NocoDB again; the admin from `.env` signs in afterwards, because NocoDB sets it again on start. The data script unpacks the archive into a staging directory first, so a bad archive changes nothing, then replaces what was there, keeping the owner NocoDB runs as, and starts NocoDB again. Both read every path and name from the running backups container, and CI runs both on every change: the record and the attachment made before the backup come back, the ones made after it are gone, and NocoDB writes a new record and a new attachment afterwards. Restore onto a host whose `.env` has the same `NOCODB_CONNECTION_ENCRYPT_KEY`, or the connections to other databases will not open.

**Off-host replication.** Backups live in named volumes on the same host. Bind-mount `NOCODB_POSTGRES_BACKUPS_PATH` and `NOCODB_DATA_BACKUPS_PATH` to directories covered by your off-host backup (restic, rclone, Borg, S3 sync).

## Redis

Off unless asked for. Without Redis, NocoDB keeps its cache in the process, which is enough for one instance on one host. Redis matters once several NocoDB processes share one database. To run it, set both lines in `.env`:

```bash
COMPOSE_PROFILES=redis
NOCODB_REDIS_URL=redis://redis:6379
```

CI runs the default stack and checks that no Redis is running and NocoDB is pointed at none, and runs a second stack with these two lines and checks that NocoDB writes its cache to Redis.

## Container hardening

Every service runs with `security_opt: no-new-privileges:true` and resource limits. NocoDB runs as its image's own `node` user (uid 1000) with every Linux capability dropped; its image runs as root, and declares no volume, so a one-shot `nocodb-init` container gives the data volume to uid 1000 with `CHOWN` alone, on no network, before NocoDB starts. CI reads the running NocoDB process's uid and effective capabilities (`0000000000000000`). Traefik, PostgreSQL, Redis and the backups container drop every capability and add back only what their entrypoints need: `NET_BIND_SERVICE` for Traefik, ownership and user switching for the database images, reading and writing other users' files for the backups. PostgreSQL and Redis listen on the internal network only; NocoDB is published nowhere but through Traefik.

NocoDB's memory ceiling is 2 GB. Its peak under this repository's tests is printed on every CI run ("Peak memory of each service"), and on a workstation it was 890 MiB; NocoDB's own start script keeps V8 from optimising its SQL parser because that step alone takes about 1 GB, and large imports grow from there. Raise `NOCODB_MEMORY_LIMIT` if `docker inspect` reports `OOMKilled=true`.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/nocodb-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every day at 06:00 UTC:

1. **Lint**: ShellCheck on every script, actionlint on the workflows.
2. **Trivy scans** of the four pinned images (CRITICAL/HIGH, SARIF to the Security tab).
3. **Deploy**: the full stack with credentials new on every run, the previous release first when there is one, then the upgrade on its volumes; no anonymous volume; no Redis without the profile.
4. **Access and secrets** (`tests/e2e-security.sh`): uid 1000 with no capabilities; no first user waiting, the admin from `.env` signing in as super admin, a stranger who is a viewer and cannot make a base, and refused once signup is invite-only; `/api/v1/health` answering 200 with PostgreSQL stopped while the shipped check's endpoint answers 400 and Docker marks NocoDB unhealthy; the stack's own PostgreSQL refused as a data source; an attachment's plain, signed and forged URLs, and the plain one served with secure attachments off; no signing secret in the database; a connected database's password in a backup without the encryption key and gone with it, the connection still reading, and not under another key; a connection made while private networks were allowed refused when used on the shipped settings; a change logged from the client's address despite a forged `X-Forwarded-For`, and from Traefik's without `NC_TRUST_PROXY`. The "without" cases use test-only files in `tests/overrides/`.
5. **Backup and restore** (`tests/e2e-backup-restore.sh`): `docker compose config` refusing to run without `.env`; a dump that opens and holds NocoDB's tables and an archive that lists the attachment made before it; a failed cycle logged and kept as `.failed`; both restore scripts, judged through NocoDB as above; pruning.
6. **With Redis**: a second stack with the `redis` profile, where NocoDB writes its cache to Redis.

The Pin Freshness workflow runs separately, daily: digest drift against the registries, and release lag for NocoDB and Traefik.

To run the tests yourself, on a staging copy and never on production (they stop PostgreSQL, recreate NocoDB with test-only settings and replace its data), set short intervals in `.env` (`NOCODB_BACKUP_INIT_SLEEP=15s`, `NOCODB_BACKUP_INTERVAL=60s`), bring the stack up, then:

```bash
./tests/e2e-security.sh
./tests/e2e-backup-restore.sh
```

## Security notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored, and the compose file stops on any missing one.
- The tests pass credentials to `curl` and `psql` through files and standard input, never on a command line, and print none of them.
- The backups hold every account's password hash and every record. They do not hold `NOCODB_JWT_SECRET` or `NOCODB_CONNECTION_ENCRYPT_KEY`.
- Upstream image digests are pinned; the daily freshness job flags drift.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · CNCF Ambassador · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
