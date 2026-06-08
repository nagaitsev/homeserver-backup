#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_DIR=""
OUTPUT_DIR="$SCRIPT_DIR/dist"
BUNDLE_NAME="recovery-bundle-$(date +%F_%H-%M-%S)"
RCLONE_CONF_SOURCE="/root/.config/rclone/rclone.conf"
REMOTE_DIR="yadisk:server_backup/recovery"
PUBLIC_BOOTSTRAP_URL=""
STABLE_BUNDLE_BASENAME="recovery-bundle-latest"
PASSPHRASE_FILE=""
PASSPHRASE_VALUE="${BUNDLE_PASSPHRASE:-}"
MODE_EXAMPLE="disaster"
TEST_IP_EXAMPLE="10.1.1.96"

LIVE_STAGE_DIR=""

usage(){
  cat <<'EOF'
Usage:
  sudo bash publish-recovery-bundle.sh --public-bootstrap-url https://raw.githubusercontent.com/<owner>/<repo>/<ref>/bootstrap.sh [options]

Recommended:
  Run this on the live server. The script will collect the current recovery files,
  ask for the bundle passphrase, build and verify the encrypted bundle, upload it
  to Yandex Disk, create a public link, and print the final restore commands.

Optional:
  --source-dir DIR              Directory with prepared recovery files. If omitted, use live system files.
  --output-dir DIR              Local artifact directory. Default: ./dist next to script
  --bundle-name NAME            Artifact base name. Default: recovery-bundle-YYYY-MM-DD_HH-MM-SS
  --rclone-conf PATH            rclone.conf to include in the encrypted bundle. Default: /root/.config/rclone/rclone.conf
  --remote-dir REMOTE           Remote directory. Default: yadisk:server_backup/recovery
  --public-bootstrap-url URL    Public URL to bootstrap.sh on GitHub or your web server
  --stable-bundle-basename NAME Stable alias base name. Default: recovery-bundle-latest
  --passphrase-file PATH        File containing gpg passphrase
  --passphrase VALUE            Passphrase directly (less safe in shell history)
  --mode-example MODE           Mode shown in the printed example command. Default: disaster
  --test-ip-example IP          Test IP shown in printed example command. Default: 10.1.1.96
  --help                        Show help
EOF
}

cleanup(){
  [[ -n "$LIVE_STAGE_DIR" && -d "$LIVE_STAGE_DIR" ]] && rm -rf "$LIVE_STAGE_DIR"
}

trap cleanup EXIT

require_root(){
  if [[ $EUID -ne 0 ]]; then
    echo "run as root"
    exit 1
  fi
}

require_command(){
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1"; exit 1; }
}

parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-dir) SOURCE_DIR="$2"; shift 2 ;;
      --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
      --bundle-name) BUNDLE_NAME="$2"; shift 2 ;;
      --rclone-conf) RCLONE_CONF_SOURCE="$2"; shift 2 ;;
      --remote-dir) REMOTE_DIR="$2"; shift 2 ;;
      --public-bootstrap-url) PUBLIC_BOOTSTRAP_URL="$2"; shift 2 ;;
      --stable-bundle-basename) STABLE_BUNDLE_BASENAME="$2"; shift 2 ;;
      --passphrase-file) PASSPHRASE_FILE="$2"; shift 2 ;;
      --passphrase) PASSPHRASE_VALUE="$2"; shift 2 ;;
      --mode-example) MODE_EXAMPLE="$2"; shift 2 ;;
      --test-ip-example) TEST_IP_EXAMPLE="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *)
        echo "unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

stage_live_files(){
  LIVE_STAGE_DIR="$(mktemp -d)"

  install -m 600 /etc/homeserver-backup.env "$LIVE_STAGE_DIR/homeserver-backup.env"
  install -m 700 /usr/local/sbin/homeserver-restore.sh "$LIVE_STAGE_DIR/homeserver-restore.sh"
  install -m 700 /usr/local/sbin/homeserver-bootstrap-restore.sh "$LIVE_STAGE_DIR/homeserver-bootstrap-restore.sh"

  if [[ -f /etc/homeserver-backup.exclude ]]; then
    install -m 600 /etc/homeserver-backup.exclude "$LIVE_STAGE_DIR/homeserver-backup.exclude"
  fi

  if [[ -f /root/HOMESERVER_BACKUP_RESTORE.md ]]; then
    install -m 600 /root/HOMESERVER_BACKUP_RESTORE.md "$LIVE_STAGE_DIR/HOMESERVER_BACKUP_RESTORE.md"
  fi

  SOURCE_DIR="$LIVE_STAGE_DIR"
}

prepare_source(){
  if [[ -n "$SOURCE_DIR" ]]; then
    [[ -d "$SOURCE_DIR" ]] || { echo "missing source dir: $SOURCE_DIR"; exit 1; }
    return 0
  fi

  [[ -f /etc/homeserver-backup.env ]] || { echo "missing /etc/homeserver-backup.env"; exit 1; }
  [[ -f /usr/local/sbin/homeserver-restore.sh ]] || { echo "missing /usr/local/sbin/homeserver-restore.sh"; exit 1; }
  [[ -f /usr/local/sbin/homeserver-bootstrap-restore.sh ]] || { echo "missing /usr/local/sbin/homeserver-bootstrap-restore.sh"; exit 1; }
  stage_live_files
}

build_bundle(){
  local builder_args=(
    --source-dir "$SOURCE_DIR"
    --output-dir "$OUTPUT_DIR"
    --bundle-name "$BUNDLE_NAME"
    --rclone-conf "$RCLONE_CONF_SOURCE"
  )

  if [[ -n "$PASSPHRASE_FILE" ]]; then
    builder_args+=( --passphrase-file "$PASSPHRASE_FILE" )
  elif [[ -n "$PASSPHRASE_VALUE" ]]; then
    builder_args+=( --passphrase "$PASSPHRASE_VALUE" )
  fi

  bash "$SCRIPT_DIR/build-encrypted-recovery-bundle.sh" "${builder_args[@]}"
}

upload_artifacts(){
  local encrypted="$OUTPUT_DIR/${BUNDLE_NAME}.tar.gz.gpg"
  local manifest="$OUTPUT_DIR/${BUNDLE_NAME}.manifest.txt"
  local verify="$OUTPUT_DIR/${BUNDLE_NAME}.verify.txt"
  local stable_encrypted="$REMOTE_DIR/${STABLE_BUNDLE_BASENAME}.tar.gz.gpg"
  local stable_manifest="$REMOTE_DIR/${STABLE_BUNDLE_BASENAME}.manifest.txt"
  local stable_verify="$REMOTE_DIR/${STABLE_BUNDLE_BASENAME}.verify.txt"

  [[ -f "$encrypted" ]] || { echo "missing $encrypted"; exit 1; }
  [[ -f "$manifest" ]] || { echo "missing $manifest"; exit 1; }
  [[ -f "$verify" ]] || { echo "missing $verify"; exit 1; }

  rclone mkdir "$REMOTE_DIR"
  rclone copyto "$encrypted" "$REMOTE_DIR/${BUNDLE_NAME}.tar.gz.gpg"
  rclone copyto "$manifest" "$REMOTE_DIR/${BUNDLE_NAME}.manifest.txt"
  rclone copyto "$verify" "$REMOTE_DIR/${BUNDLE_NAME}.verify.txt"
  rclone copyto "$encrypted" "$stable_encrypted"
  rclone copyto "$manifest" "$stable_manifest"
  rclone copyto "$verify" "$stable_verify"
}

make_public_folder_link(){
  rclone link "$REMOTE_DIR" | tail -n 1
}

make_public_file_link(){
  local remote_file="$REMOTE_DIR/${STABLE_BUNDLE_BASENAME}.tar.gz.gpg"
  rclone link "$remote_file" | tail -n 1
}

print_result(){
  local public_folder_link="$1"
  local public_file_link="$2"

  cat <<EOF

Publish complete.

Local artifacts:
  $OUTPUT_DIR/${BUNDLE_NAME}.tar.gz
  $OUTPUT_DIR/${BUNDLE_NAME}.tar.gz.gpg
  $OUTPUT_DIR/${BUNDLE_NAME}.manifest.txt
  $OUTPUT_DIR/${BUNDLE_NAME}.verify.txt

Yandex stable public folder link:
  $public_folder_link

Yandex stable public file link:
  $public_file_link

Stable bundle path inside public folder:
  /${STABLE_BUNDLE_BASENAME}.tar.gz.gpg

Restore command (${MODE_EXAMPLE}):
  curl -fsSL $PUBLIC_BOOTSTRAP_URL | sudo bash -s -- --encrypted-bundle-url \"$public_folder_link\" --encrypted-bundle-path \"/${STABLE_BUNDLE_BASENAME}.tar.gz.gpg\" --mode $MODE_EXAMPLE

Restore command (test):
  curl -fsSL $PUBLIC_BOOTSTRAP_URL | sudo bash -s -- --encrypted-bundle-url \"$public_folder_link\" --encrypted-bundle-path \"/${STABLE_BUNDLE_BASENAME}.tar.gz.gpg\" --mode test --test-ip $TEST_IP_EXAMPLE

Verification report:
  cat $OUTPUT_DIR/${BUNDLE_NAME}.verify.txt
EOF
}

main(){
  parse_args "$@"
  require_root
  require_command bash
  require_command python3
  require_command gpg
  require_command rclone
  require_command tar
  require_command sha256sum

  [[ -n "$PUBLIC_BOOTSTRAP_URL" ]] || { echo "--public-bootstrap-url is required"; exit 1; }
  [[ -f "$RCLONE_CONF_SOURCE" ]] || { echo "missing rclone conf: $RCLONE_CONF_SOURCE"; exit 1; }
  mkdir -p "$OUTPUT_DIR"

  prepare_source
  build_bundle
  upload_artifacts
  print_result "$(make_public_folder_link)" "$(make_public_file_link)"
}

main "$@"
