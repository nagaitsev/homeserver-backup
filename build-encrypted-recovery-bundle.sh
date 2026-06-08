#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR=""
OUTPUT_DIR="."
BUNDLE_NAME="recovery-bundle"
RCLONE_CONF_SOURCE=""
PASSPHRASE_FILE=""
PASSPHRASE_VALUE="${BUNDLE_PASSPHRASE:-}"

STAGING_DIR=""
VERIFY_TMP_DIR=""

usage(){
  cat <<'EOF'
Usage:
  bash build-encrypted-recovery-bundle.sh --source-dir ./oldserver [options]

Required:
  --source-dir DIR              Directory with recovery files

Optional:
  --output-dir DIR              Where to write artifacts. Default: current dir
  --bundle-name NAME            Base artifact name. Default: recovery-bundle
  --rclone-conf PATH            Include rclone.conf in bundle
  --passphrase-file PATH        File containing gpg symmetric passphrase
  --passphrase VALUE            Passphrase directly (less safe in shell history)
  --help                        Show help
EOF
}

cleanup(){
  [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]] && rm -rf "$STAGING_DIR"
  [[ -n "$VERIFY_TMP_DIR" && -d "$VERIFY_TMP_DIR" ]] && rm -rf "$VERIFY_TMP_DIR"
}

trap cleanup EXIT

load_passphrase(){
  if [[ -n "$PASSPHRASE_FILE" ]]; then
    PASSPHRASE_VALUE="$(tr -d '\r\n' < "$PASSPHRASE_FILE")"
  fi
  if [[ -n "$PASSPHRASE_VALUE" ]]; then
    return 0
  fi
  if [[ -t 0 ]]; then
    read -r -s -p "Bundle passphrase: " PASSPHRASE_VALUE
    echo
    return 0
  fi
  echo "passphrase required"
  exit 1
}

parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-dir) SOURCE_DIR="$2"; shift 2 ;;
      --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
      --bundle-name) BUNDLE_NAME="$2"; shift 2 ;;
      --rclone-conf) RCLONE_CONF_SOURCE="$2"; shift 2 ;;
      --passphrase-file) PASSPHRASE_FILE="$2"; shift 2 ;;
      --passphrase) PASSPHRASE_VALUE="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *)
        echo "unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

assert_source_files(){
  [[ -f "$SOURCE_DIR/homeserver-backup.env" ]] || { echo "missing $SOURCE_DIR/homeserver-backup.env"; exit 1; }
  [[ -f "$SOURCE_DIR/homeserver-restore.sh" ]] || { echo "missing $SOURCE_DIR/homeserver-restore.sh"; exit 1; }
  [[ -f "$SOURCE_DIR/homeserver-bootstrap-restore.sh" ]] || { echo "missing $SOURCE_DIR/homeserver-bootstrap-restore.sh"; exit 1; }
  if [[ -n "$RCLONE_CONF_SOURCE" ]]; then
    [[ -f "$RCLONE_CONF_SOURCE" ]] || { echo "missing $RCLONE_CONF_SOURCE"; exit 1; }
  fi
}

stage_bundle_files(){
  STAGING_DIR="$(mktemp -d)"

  install -m 600 "$SOURCE_DIR/homeserver-backup.env" "$STAGING_DIR/homeserver-backup.env"
  install -m 700 "$SOURCE_DIR/homeserver-restore.sh" "$STAGING_DIR/homeserver-restore.sh"
  install -m 700 "$SOURCE_DIR/homeserver-bootstrap-restore.sh" "$STAGING_DIR/homeserver-bootstrap-restore.sh"

  if [[ -f "$SOURCE_DIR/homeserver-backup.exclude" ]]; then
    install -m 600 "$SOURCE_DIR/homeserver-backup.exclude" "$STAGING_DIR/homeserver-backup.exclude"
  fi

  if [[ -f "$SOURCE_DIR/HOMESERVER_BACKUP_RESTORE.md" ]]; then
    install -m 600 "$SOURCE_DIR/HOMESERVER_BACKUP_RESTORE.md" "$STAGING_DIR/HOMESERVER_BACKUP_RESTORE.md"
  fi

  if [[ -n "$RCLONE_CONF_SOURCE" ]]; then
    install -m 600 "$RCLONE_CONF_SOURCE" "$STAGING_DIR/rclone.conf"
  fi
}

build_bundle(){
  local tarball="$1"
  local manifest="$2"

  (
    cd "$STAGING_DIR"
    sha256sum * > bundle.manifest.txt
    tar -czf "$tarball" .
  )

  cp -f "$STAGING_DIR/bundle.manifest.txt" "$manifest"
}

encrypt_bundle(){
  local tarball="$1"
  local encrypted="$2"

  printf '%s' "$PASSPHRASE_VALUE" | gpg \
    --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
    --symmetric --cipher-algo AES256 \
    --output "$encrypted" "$tarball"
}

verify_required_file(){
  local unpacked_dir="$1"
  local file_name="$2"
  local report_file="$3"

  if [[ ! -f "$unpacked_dir/$file_name" ]]; then
    echo "required file missing: $file_name" >> "$report_file"
    return 1
  fi
  echo "required file ok: $file_name" >> "$report_file"
}

verify_tar_mode(){
  local tarball="$1"
  local file_name="$2"
  local expected_kind="$3"
  local report_file="$4"
  local symbolic_mode=""

  case "$expected_kind" in
    non-executable) symbolic_mode="-rw-" ;;
    executable) symbolic_mode="-rwx" ;;
    *)
      echo "unsupported expected kind: $expected_kind for $file_name" >> "$report_file"
      return 1
      ;;
  esac

  if tar -tzvf "$tarball" "./$file_name" 2>/dev/null | awk '{print $1}' | grep -q -- "^${symbolic_mode}"; then
    echo "archive mode ok: $file_name=$expected_kind" >> "$report_file"
    return 0
  fi

  echo "archive mode mismatch: $file_name expected=$expected_kind" >> "$report_file"
  return 1
}

verify_bundle(){
  local tarball="$1"
  local encrypted="$2"
  local manifest="$3"
  local verify_report="$4"
  local decrypted unpacked_dir tarball_sha decrypted_sha

  VERIFY_TMP_DIR="$(mktemp -d)"
  decrypted="$VERIFY_TMP_DIR/${BUNDLE_NAME}.tar.gz"
  unpacked_dir="$VERIFY_TMP_DIR/unpacked"

  : > "$verify_report"
  echo "bundle verify report" >> "$verify_report"
  echo "bundle: ${BUNDLE_NAME}" >> "$verify_report"

  printf '%s' "$PASSPHRASE_VALUE" | gpg \
    --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
    --decrypt "$encrypted" > "$decrypted"
  echo "decrypt: ok" >> "$verify_report"

  tarball_sha="$(sha256sum "$tarball" | awk '{print $1}')"
  decrypted_sha="$(sha256sum "$decrypted" | awk '{print $1}')"
  if [[ "$tarball_sha" != "$decrypted_sha" ]]; then
    echo "tarball sha mismatch: built=$tarball_sha decrypted=$decrypted_sha" >> "$verify_report"
    return 1
  fi
  echo "tarball sha256: ok ($tarball_sha)" >> "$verify_report"

  mkdir -p "$unpacked_dir"
  tar -xzf "$decrypted" -C "$unpacked_dir"
  echo "extract: ok" >> "$verify_report"

  if [[ ! -f "$unpacked_dir/bundle.manifest.txt" ]]; then
    echo "bundle.manifest.txt missing after extract" >> "$verify_report"
    return 1
  fi

  if ! cmp -s "$manifest" "$unpacked_dir/bundle.manifest.txt"; then
    echo "manifest mismatch: output manifest differs from bundle.manifest.txt" >> "$verify_report"
    return 1
  fi
  echo "manifest copy: ok" >> "$verify_report"

  (
    cd "$unpacked_dir"
    sha256sum -c bundle.manifest.txt
  ) >> "$verify_report" 2>&1

  verify_required_file "$unpacked_dir" "homeserver-backup.env" "$verify_report"
  verify_tar_mode "$decrypted" "homeserver-backup.env" "non-executable" "$verify_report"
  verify_required_file "$unpacked_dir" "homeserver-restore.sh" "$verify_report"
  verify_tar_mode "$decrypted" "homeserver-restore.sh" "executable" "$verify_report"
  verify_required_file "$unpacked_dir" "homeserver-bootstrap-restore.sh" "$verify_report"
  verify_tar_mode "$decrypted" "homeserver-bootstrap-restore.sh" "executable" "$verify_report"

  if [[ -f "$unpacked_dir/homeserver-backup.exclude" ]]; then
    verify_required_file "$unpacked_dir" "homeserver-backup.exclude" "$verify_report"
    verify_tar_mode "$decrypted" "homeserver-backup.exclude" "non-executable" "$verify_report"
  fi
  if [[ -f "$unpacked_dir/HOMESERVER_BACKUP_RESTORE.md" ]]; then
    verify_required_file "$unpacked_dir" "HOMESERVER_BACKUP_RESTORE.md" "$verify_report"
    verify_tar_mode "$decrypted" "HOMESERVER_BACKUP_RESTORE.md" "non-executable" "$verify_report"
  fi
  if [[ -f "$unpacked_dir/rclone.conf" ]]; then
    verify_required_file "$unpacked_dir" "rclone.conf" "$verify_report"
    verify_tar_mode "$decrypted" "rclone.conf" "non-executable" "$verify_report"
  fi

  echo "verification: ok" >> "$verify_report"
}

main(){
  parse_args "$@"
  [[ -n "$SOURCE_DIR" ]] || { usage; exit 1; }
  assert_source_files
  mkdir -p "$OUTPUT_DIR"
  load_passphrase

  local tarball encrypted manifest verify_report
  tarball="$OUTPUT_DIR/${BUNDLE_NAME}.tar.gz"
  encrypted="$OUTPUT_DIR/${BUNDLE_NAME}.tar.gz.gpg"
  manifest="$OUTPUT_DIR/${BUNDLE_NAME}.manifest.txt"
  verify_report="$OUTPUT_DIR/${BUNDLE_NAME}.verify.txt"

  stage_bundle_files
  build_bundle "$tarball" "$manifest"
  encrypt_bundle "$tarball" "$encrypted"
  verify_bundle "$tarball" "$encrypted" "$manifest" "$verify_report"

  echo "created:"
  echo "  $tarball"
  echo "  $encrypted"
  echo "  $manifest"
  echo "  $verify_report"
  echo "verification: ok"
}

main "$@"
