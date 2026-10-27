# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.0] - 2026-10-27

### Added

- **NocoDB 2026.10.0 on PostgreSQL 17, behind Traefik with Let's Encrypt**, every image pinned by tag and digest in the compose file's `x-images` block, with Redis as an opt-in compose profile.
- **The super admin from `.env`, before the site answers.** `NOCODB_ADMIN_EMAIL` and `NOCODB_ADMIN_PASSWORD` are required, so the first stranger to sign up is not made super admin, which is what NocoDB does without them. A stranger who signs up is a viewer who cannot make a base.
- **The secrets that would otherwise sit in every backup live in `.env`.** `NOCODB_JWT_SECRET` keeps the session-signing secret out of NocoDB's database, where NocoDB stores one it makes when none is given. `NOCODB_CONNECTION_ENCRYPT_KEY` encrypts the stored connections to the databases NocoDB fronts; without it, a backup held a connected database's password in clear text, and with it the password was nowhere in the backup and the connection still read. Both are required.
- **No data sources on private addresses** (`NOCODB_ALLOW_LOCAL_EXTERNAL_DBS=false`), which includes the stack's own PostgreSQL; signed, expiring attachment links only (`NC_SECURE_ATTACHMENTS`); `NC_TRUST_PROXY=1`, so the audit log records the client's address and not Traefik's; telemetry off.
- **A health check that reads the database.** NocoDB's `/api/v1/health` answered 200 with PostgreSQL stopped; the check here uses `/api/v2/meta/nocodb/info`, which answers 400 when the database cannot be read.
- **NocoDB as uid 1000 with no capabilities.** Its image runs as root and declares no volume; a one-shot `nocodb-init` container gives the data volume to uid 1000 with `CHOWN` alone, on no network.
- **Backups read back before they count**: a `pg_dump` checked with `gzip -t` and a `tar.gz` of the attachments checked with `tar -tzf`, each written as `.partial` and renamed only once it opens, with `OK`/`FAILED` log lines and pruning. `nocodb-restore-database.sh` and `nocodb-restore-application-data.sh`, the second unpacking into a staging directory first so a bad archive changes nothing.
- **Tests against the real stack, through Traefik**: `tests/e2e-security.sh` for every claim above, the "without this" ones both ways through test-only files in `tests/overrides/`; `tests/e2e-backup-restore.sh` for both restore scripts, judged through NocoDB: what was made before the backup comes back, what was made after it is gone, and NocoDB writes again. A second job runs the `redis` profile.
- `update.sh`, an upgrade drill from the previous release on the same volumes, Trivy scans, daily pin freshness, signed release assets with SLSA provenance, Dependabot with auto-merge after verification, OpenSSF Scorecard, LICENSE and SECURITY.md.

[Unreleased]: https://github.com/heyvaldemar/nocodb-traefik-letsencrypt-docker-compose/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/nocodb-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
