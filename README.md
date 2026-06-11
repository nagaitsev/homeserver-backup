# homeserver-backup

Public recovery toolkit for the homeserver backup/restore flow.

Included:

- `bootstrap.sh`: downloads the encrypted recovery bundle and launches restore
- `build-encrypted-recovery-bundle.sh`: builds and verifies the encrypted bundle
- `publish-recovery-bundle.sh`: builds, verifies, uploads to Yandex Disk, and prints final restore commands
- `WEB_BOOTSTRAP_USAGE.md`: end-user usage notes
- `AGENT_MANUAL_RECOVERY.md`: manual fallback recovery instructions
- `CURRENT_STATUS.md`: current validated operational state and retention model
- `homeserver-backup.env.example`: sanitized configuration example

Operational model:

- backup is snapshot-based and content-addressed
- local retention is count-based and currently keeps `1` snapshot
- remote retention is count-based and currently keeps `30` snapshots
- old snapshots are pruned only after a successful backup run
- the recovery flow has been validated by full `test restore`

Security model:

- Safe to publish: scripts, docs, sanitized examples
- Never publish: real `homeserver-backup.env`, real `rclone.conf`, bundle passphrases, OAuth or Telegram or SMTP secrets
