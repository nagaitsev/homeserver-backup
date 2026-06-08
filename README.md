# homeserver-backup

Public recovery toolkit for the homeserver backup/restore flow.

Included:

- `bootstrap.sh`: downloads the encrypted recovery bundle and launches restore
- `build-encrypted-recovery-bundle.sh`: builds and verifies the encrypted bundle
- `publish-recovery-bundle.sh`: builds, verifies, uploads to Yandex Disk, and prints final restore commands
- `WEB_BOOTSTRAP_USAGE.md`: end-user usage notes
- `AGENT_MANUAL_RECOVERY.md`: manual fallback recovery instructions
- `homeserver-backup.env.example`: sanitized configuration example

Security model:

- Safe to publish: scripts, docs, sanitized examples
- Never publish: real `homeserver-backup.env`, real `rclone.conf`, bundle passphrases, OAuth or Telegram or SMTP secrets
