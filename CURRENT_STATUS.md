# Current Backup Status

As of `2026-06-11`.

## Current State

- Backup model: entity-based snapshots + content-addressed object storage
- Latest snapshot:
  - `2026-06-09_20-00-31`
- Remote latest pointer:
  - `yadisk:server_backup/LATEST`
- Remote snapshots retained:
  - `30`
- Local snapshots retained:
  - `1`
- Old snapshot pruning:
  - runs only after a successful backup
- Object garbage collection:
  - local and remote enabled

## Schedule

- `homeserver-backup.timer`
  - `OnCalendar=*-*-* 03:40:00`
  - `RandomizedDelaySec=15m`
- `homeserver-backup-selfcheck.timer`
  - `OnCalendar=*-*-* 06:10:00`
  - `RandomizedDelaySec=10m`

## Verified Restore Status

Last full verified test restore:

- Date: `2026-06-10`
- Snapshot: `2026-06-09_20-00-31`
- Target type: separate Ubuntu 22.04 test machine
- Result: success

Verified services after restore:

- `x-ui`
- `Apache`
- `pure-ftpd`
- `mtg`
- `aaPanel`

Verified listening ports after restore:

- `21`
- `22`
- `80`
- `443`
- `2053`
- `8443`
- `10808`
- `22334`
- `30001`

## Recovery Bundle Notes

- Public bootstrap entrypoint:
  - `bootstrap.sh` from the `homeserver-backup` GitHub repo
- Stable encrypted bundle alias on Yandex:
  - `recovery-bundle-latest.tar.gz.gpg`
- Bundle now includes recovery helpers for:
  - CRLF normalization in `homeserver-backup.env`
  - auto-disable broken `NodeSource` apt source during bootstrap
  - bundled `libssl.so.1.1` and `libcrypto.so.1.1`
  - auto-create `/www/wwwlogs`
  - auto-install `liblua5.1-0`
  - stop/start for `x-ui`, `Apache`, `pure-ftpd`, `aaPanel`, `mtg`
