# homeserver-backup

Public bootstrap entrypoint for restoring a private encrypted recovery bundle.

This repository intentionally contains only the minimal public launcher:

- `bootstrap.sh`

Usage pattern:

```bash
curl -fsSL https://raw.githubusercontent.com/nagaitsev/homeserver-backup/main/bootstrap.sh | sudo bash -s -- --encrypted-bundle-url "PUBLIC_BUNDLE_URL" --encrypted-bundle-path "/recovery-bundle-latest.tar.gz.gpg" --mode disaster
```

The encrypted bundle, passphrase, private recovery instructions, and infrastructure-specific configuration are stored outside this public repository.
