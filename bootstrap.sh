#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/homeserver-backup.env"
RESTORE_SCRIPT="/usr/local/sbin/homeserver-restore.sh"
BOOTSTRAP_RESTORE_SCRIPT="/usr/local/sbin/homeserver-bootstrap-restore.sh"
EXCLUDES_FILE="/etc/homeserver-backup.exclude"
RCLONE_CONF="/root/.config/rclone/rclone.conf"
RUNBOOK_FILE="/root/HOMESERVER_BACKUP_RESTORE.md"

BUNDLE_URL=""
ENCRYPTED_BUNDLE_URL=""
ENCRYPTED_BUNDLE_PATH=""
MODE="disaster"
SNAPSHOT_ID=""
ENV_URL=""
RESTORE_URL=""
BOOTSTRAP_RESTORE_URL=""
EXCLUDES_URL=""
RUNBOOK_URL=""
RCLONE_CONF_URL=""
TEST_IP=""
PRIMARY_IP=""
BUNDLE_PASSPHRASE="${BUNDLE_PASSPHRASE:-}"
BUNDLE_PASSPHRASE_FILE=""
BUNDLE_TMP_DIR=""

log(){
  echo "[$(date '+%F %T')] $*"
}

normalize_text_file(){
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed -i 's/\r$//' "$file"
}

usage(){
  cat <<'EOF'
Usage:
  sudo bash bootstrap.sh --bundle-url https://example.com/recovery [options]
  sudo bash bootstrap.sh --encrypted-bundle-url https://example.com/recovery-bundle.tar.gz.gpg [options]

One of:
  --bundle-url URL              Base URL where recovery files are hosted.
  --encrypted-bundle-url URL    URL to encrypted recovery bundle (.tar.gz.gpg)
  --encrypted-bundle-path PATH  Path to file inside a Yandex public folder link

Optional:
  --mode disaster|test          Restore mode. Default: disaster
  --snapshot-id ID              Specific snapshot ID. Default: read LATEST
  --test-ip IP                  Required for mode=test if env does not already set it
  --primary-ip IP               Override PRIMARY_SERVICE_IP in env
  --bundle-passphrase VALUE     Passphrase for encrypted bundle (less safe in shell history)
  --bundle-passphrase-file PATH File containing passphrase for encrypted bundle
  --env-url URL                 Override env URL. Default: <bundle-url>/homeserver-backup.env
  --restore-url URL             Override restore script URL. Default: <bundle-url>/homeserver-restore.sh
  --bootstrap-restore-url URL   Override bootstrap restore URL. Default: <bundle-url>/homeserver-bootstrap-restore.sh
  --excludes-url URL            Optional exclude file URL. Default: <bundle-url>/homeserver-backup.exclude
  --runbook-url URL             Optional runbook URL. Default: <bundle-url>/HOMESERVER_BACKUP_RESTORE.md
  --rclone-conf-url URL         Optional rclone.conf URL. If omitted, existing local rclone.conf is used
  --help                        Show this help

Examples:
  curl -fsSL https://example.com/recovery/bootstrap.sh | sudo bash -s -- \
    --bundle-url https://example.com/recovery \
    --mode disaster

  curl -fsSL https://example.com/recovery/bootstrap.sh | sudo bash -s -- \
    --encrypted-bundle-url https://yandex.example/recovery-bundle.tar.gz.gpg \
    --mode disaster

  curl -fsSL https://example.com/recovery/bootstrap.sh | sudo bash -s -- \
    --bundle-url https://example.com/recovery \
    --mode test \
    --test-ip 10.1.1.96
EOF
}

require_root(){
  if [[ $EUID -ne 0 ]]; then
    echo "run as root"
    exit 1
  fi
}

apt_update_resilient(){
  if apt-get update -y; then
    return 0
  fi

  local disabled=0
  local file
  for file in /etc/apt/sources.list.d/*nodesource*.list; do
    [[ -f "$file" ]] || continue
    mv "$file" "${file}.disabled"
    disabled=1
    log "disabled broken apt source: $file"
  done

  (( disabled == 1 )) || return 1
  apt-get update -y
}

install_dependencies(){
  apt_update_resilient
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq zstd tar rclone docker.io python3 gnupg
}

download_file(){
  local url="$1"
  local dst="$2"
  local mode="${3:-}"
  mkdir -p "$(dirname "$dst")"
  curl -fsSL "$url" -o "$dst"
  if [[ -n "$mode" ]]; then
    chmod "$mode" "$dst"
  fi
}

urlencode(){
  python3 - "$1" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

resolve_download_url(){
  local url="$1"
  local public_path="${2:-}"
  local encoded api_url resolved

  case "$url" in
    https://yadi.sk/*|https://disk.yandex.*/*|https://yandex.ru/d/*|https://disk.yandex.ru/*)
      encoded="$(urlencode "$url")"
      api_url="https://cloud-api.yandex.net/v1/disk/public/resources/download?public_key=${encoded}"
      if [[ -n "$public_path" ]]; then
        api_url="${api_url}&path=$(urlencode "$public_path")"
      fi
      resolved="$(curl -fsSL "$api_url" | jq -r '.href // empty')"
      if [[ -z "$resolved" ]]; then
        echo "failed to resolve Yandex public link to direct download URL"
        exit 1
      fi
      printf '%s\n' "$resolved"
      return 0
      ;;
    *)
      if [[ -n "$public_path" ]]; then
        echo "--encrypted-bundle-path is supported only with Yandex public links"
        exit 1
      fi
      printf '%s\n' "$url"
      return 0
      ;;
  esac
}

set_env_value(){
  local key="$1"
  local value="$2"
  python3 - "$ENV_FILE" "$key" "$value" <<'PY'
from pathlib import Path
import re
import sys

env_path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
line = f'{key}="{value}"'
text = env_path.read_text()
pattern = re.compile(rf'^{re.escape(key)}=.*$', re.M)
if pattern.search(text):
    text = pattern.sub(line, text)
else:
    if not text.endswith("\n"):
        text += "\n"
    text += line + "\n"
env_path.write_text(text)
PY
}

prepare_defaults(){
  if [[ -z "$BUNDLE_URL" && -z "$ENCRYPTED_BUNDLE_URL" ]]; then
    usage
    exit 1
  fi
  if [[ -n "$BUNDLE_URL" && -n "$ENCRYPTED_BUNDLE_URL" ]]; then
    echo "use either --bundle-url or --encrypted-bundle-url, not both"
    exit 1
  fi
  [[ -n "$BUNDLE_URL" ]] || return 0
  ENV_URL="${ENV_URL:-$BUNDLE_URL/homeserver-backup.env}"
  RESTORE_URL="${RESTORE_URL:-$BUNDLE_URL/homeserver-restore.sh}"
  BOOTSTRAP_RESTORE_URL="${BOOTSTRAP_RESTORE_URL:-$BUNDLE_URL/homeserver-bootstrap-restore.sh}"
  EXCLUDES_URL="${EXCLUDES_URL:-$BUNDLE_URL/homeserver-backup.exclude}"
  RUNBOOK_URL="${RUNBOOK_URL:-$BUNDLE_URL/HOMESERVER_BACKUP_RESTORE.md}"
}

download_bundle_from_urls(){
  log "downloading recovery bundle from $BUNDLE_URL"
  download_file "$ENV_URL" "$ENV_FILE" 600
  download_file "$RESTORE_URL" "$RESTORE_SCRIPT" 700
  download_file "$BOOTSTRAP_RESTORE_URL" "$BOOTSTRAP_RESTORE_SCRIPT" 700
  normalize_text_file "$ENV_FILE"

  if curl -fsSI "$EXCLUDES_URL" >/dev/null 2>&1; then
    download_file "$EXCLUDES_URL" "$EXCLUDES_FILE" 600
  fi

  if curl -fsSI "$RUNBOOK_URL" >/dev/null 2>&1; then
    download_file "$RUNBOOK_URL" "$RUNBOOK_FILE" 600
  fi

  if [[ -n "$RCLONE_CONF_URL" ]]; then
    download_file "$RCLONE_CONF_URL" "$RCLONE_CONF" 600
  fi
}

load_passphrase(){
  if [[ -n "$BUNDLE_PASSPHRASE_FILE" ]]; then
    BUNDLE_PASSPHRASE="$(tr -d '\r\n' < "$BUNDLE_PASSPHRASE_FILE")"
  fi

  if [[ -n "$BUNDLE_PASSPHRASE" ]]; then
    return 0
  fi

  if [[ -r /dev/tty ]]; then
    read -r -s -p "Encrypted bundle passphrase: " BUNDLE_PASSPHRASE < /dev/tty
    echo > /dev/tty
    return 0
  fi

  echo "encrypted bundle requires passphrase"
  echo "use --bundle-passphrase, --bundle-passphrase-file, or run from an interactive terminal with /dev/tty"
  exit 1
}

install_from_bundle_dir(){
  local src_dir="$1"
  [[ -f "$src_dir/homeserver-backup.env" ]] || { echo "bundle missing homeserver-backup.env"; exit 1; }
  [[ -f "$src_dir/homeserver-restore.sh" ]] || { echo "bundle missing homeserver-restore.sh"; exit 1; }
  [[ -f "$src_dir/homeserver-bootstrap-restore.sh" ]] || { echo "bundle missing homeserver-bootstrap-restore.sh"; exit 1; }

  install -m 600 "$src_dir/homeserver-backup.env" "$ENV_FILE"
  install -m 700 "$src_dir/homeserver-restore.sh" "$RESTORE_SCRIPT"
  install -m 700 "$src_dir/homeserver-bootstrap-restore.sh" "$BOOTSTRAP_RESTORE_SCRIPT"
  normalize_text_file "$ENV_FILE"

  if [[ -f "$src_dir/homeserver-backup.exclude" ]]; then
    install -m 600 "$src_dir/homeserver-backup.exclude" "$EXCLUDES_FILE"
  fi

  if [[ -f "$src_dir/HOMESERVER_BACKUP_RESTORE.md" ]]; then
    install -m 600 "$src_dir/HOMESERVER_BACKUP_RESTORE.md" "$RUNBOOK_FILE"
  fi

  if [[ -f "$src_dir/rclone.conf" ]]; then
    mkdir -p "$(dirname "$RCLONE_CONF")"
    install -m 600 "$src_dir/rclone.conf" "$RCLONE_CONF"
  fi

  if [[ -f "$src_dir/legacy-libssl.so.1.1" || -f "$src_dir/legacy-libcrypto.so.1.1" ]]; then
    mkdir -p /opt/homeserver-recovery/lib
  fi
  if [[ -f "$src_dir/legacy-libssl.so.1.1" ]]; then
    install -m 644 "$src_dir/legacy-libssl.so.1.1" /opt/homeserver-recovery/lib/legacy-libssl.so.1.1
  fi
  if [[ -f "$src_dir/legacy-libcrypto.so.1.1" ]]; then
    install -m 644 "$src_dir/legacy-libcrypto.so.1.1" /opt/homeserver-recovery/lib/legacy-libcrypto.so.1.1
  fi
}

download_encrypted_bundle(){
  local encrypted_file decrypted_file fetch_url
  BUNDLE_TMP_DIR="$(mktemp -d /tmp/homeserver-web-bootstrap.XXXXXX)"
  encrypted_file="$BUNDLE_TMP_DIR/recovery-bundle.tar.gz.gpg"
  decrypted_file="$BUNDLE_TMP_DIR/recovery-bundle.tar.gz"

  fetch_url="$(resolve_download_url "$ENCRYPTED_BUNDLE_URL" "$ENCRYPTED_BUNDLE_PATH")"
  log "downloading encrypted recovery bundle from $ENCRYPTED_BUNDLE_URL"
  curl -fsSL "$fetch_url" -o "$encrypted_file"
  load_passphrase
  printf '%s' "$BUNDLE_PASSPHRASE" | gpg \
    --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
    --decrypt "$encrypted_file" > "$decrypted_file"

  mkdir -p "$BUNDLE_TMP_DIR/unpacked"
  tar -xzf "$decrypted_file" -C "$BUNDLE_TMP_DIR/unpacked"
  install_from_bundle_dir "$BUNDLE_TMP_DIR/unpacked"
}

download_bundle(){
  if [[ -n "$ENCRYPTED_BUNDLE_URL" ]]; then
    download_encrypted_bundle
  else
    download_bundle_from_urls
  fi
}

prepare_rclone(){
  if [[ -f "$RCLONE_CONF" ]]; then
    chmod 600 "$RCLONE_CONF"
    return 0
  fi
  echo "rclone.conf not found."
  echo "Provide --rclone-conf-url or place config manually at $RCLONE_CONF"
  exit 1
}

configure_mode(){
  case "$MODE" in
    disaster|test) ;;
    *)
      echo "unknown mode: $MODE"
      exit 1
      ;;
  esac

  set_env_value "ALLOW_RESTORE" "YES"
  set_env_value "RESTORE_MODE" "$MODE"

  if [[ -n "$PRIMARY_IP" ]]; then
    set_env_value "PRIMARY_SERVICE_IP" "$PRIMARY_IP"
  fi

  if [[ "$MODE" == "test" ]]; then
    if [[ -z "$TEST_IP" ]]; then
      TEST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    [[ -n "$TEST_IP" ]] || { echo "test mode requires --test-ip or detectable host IP"; exit 1; }
    set_env_value "RESTORE_TEST_TARGET_IP" "$TEST_IP"
  else
    set_env_value "RESTORE_TEST_TARGET_IP" ""
  fi
}

run_restore(){
  log "starting restore: mode=$MODE snapshot=${SNAPSHOT_ID:-latest}"
  "$BOOTSTRAP_RESTORE_SCRIPT" "$SNAPSHOT_ID" "$MODE"
}

parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bundle-url) BUNDLE_URL="$2"; shift 2 ;;
      --mode) MODE="$2"; shift 2 ;;
      --encrypted-bundle-url) ENCRYPTED_BUNDLE_URL="$2"; shift 2 ;;
      --encrypted-bundle-path) ENCRYPTED_BUNDLE_PATH="$2"; shift 2 ;;
      --snapshot-id) SNAPSHOT_ID="$2"; shift 2 ;;
      --bundle-passphrase) BUNDLE_PASSPHRASE="$2"; shift 2 ;;
      --bundle-passphrase-file) BUNDLE_PASSPHRASE_FILE="$2"; shift 2 ;;
      --env-url) ENV_URL="$2"; shift 2 ;;
      --restore-url) RESTORE_URL="$2"; shift 2 ;;
      --bootstrap-restore-url) BOOTSTRAP_RESTORE_URL="$2"; shift 2 ;;
      --excludes-url) EXCLUDES_URL="$2"; shift 2 ;;
      --runbook-url) RUNBOOK_URL="$2"; shift 2 ;;
      --rclone-conf-url) RCLONE_CONF_URL="$2"; shift 2 ;;
      --test-ip) TEST_IP="$2"; shift 2 ;;
      --primary-ip) PRIMARY_IP="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *)
        echo "unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

main(){
  require_root
  parse_args "$@"
  prepare_defaults
  install_dependencies
  download_bundle
  prepare_rclone
  configure_mode
  run_restore
}

main "$@"
