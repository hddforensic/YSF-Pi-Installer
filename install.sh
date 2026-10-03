#!/usr/bin/env bash
#
# YSF-Pi-Installer
#
# Sets up READ-ONLY log access to a YSFReflector (G4KLX / nostar DVReflectors)
# for the "YSF Sysop" iOS app, on a Raspberry Pi / Debian machine.
#
# What it does (nothing is changed with --dry-run):
#   - finds your reflector config and log folder
#   - creates a dedicated account (default: ysfmonitor) that can ONLY run a small
#     read-only helper (ysf-sysop-log): no shell, no terminal, no forwarding
#   - lets that account log in with an SSH key, a generated password, or both
#   - optionally adds a daily cleanup of old log files (default: keep 180 days)
#
# It never touches your reflector, its configuration, or its service.
# Undo everything with:  sudo bash install.sh --uninstall
#
# Run it:   curl -fsSLO <URL>/install.sh ; less install.sh ; sudo bash install.sh
#
set -Eeuo pipefail
PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin"
umask 022

INSTALLER_VERSION="0.1.0"
HELPER_VERSION="1"

HELPER_PATH="/usr/local/bin/ysf-sysop-log"
CONF_DIR="/etc/ysf-sysop"
CONF_FILE="$CONF_DIR/ysf-sysop.conf"
AUTH_KEYS="$CONF_DIR/authorized_keys"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-ysf-sysop.conf"
CRON_FILE="/etc/cron.d/ysf-sysop-retention"
SVC_HOME="/var/lib/ysf-sysop"
ACCOUNT_MARKER="YSF Sysop app - read-only log access (YSF-Pi-Installer)"
REFLECTOR_PROC="YSFReflector"

DRY=0
YES=0
UNINSTALL=0
RESET_PASSWORD=0
NO_RETENTION=0
RETENTION_DAYS=180
SVC_USER="ysfmonitor"
AUTH_MODE=""
INI_PATH=""
PUBKEYS=""        # newline-separated "type base64" entries (validated)
PUBKEY_ARGS_PENDING=""   # raw --pubkey / --pubkey-file values, validated after the environment check
NEW_PASSWORD=""   # filled in only when a password is generated during this run
IS_ROOT=0
BASELINE=""
BASELINE_ADMIN=""
ADMIN_USER=""
ROLLBACK_MIN=0
ROLLBACK_UNIT="ysf-sysop-rollback"

if [ -t 1 ]; then BOLD=$'\033[1m'; YEL=$'\033[33m'; RED=$'\033[31m'; OFF=$'\033[0m'; else BOLD=""; YEL=""; RED=""; OFF=""; fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$YEL" "$OFF" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }
act()  { if [ "$DRY" = 1 ]; then say "  [dry-run] would: $*"; else say "  $*"; fi; }

usage() {
  cat <<EOF
YSF-Pi-Installer $INSTALLER_VERSION  -  read-only log access for the YSF Sysop app

Usage: sudo bash install.sh [options]

  --dry-run              Show what would be done; change nothing (works without sudo,
                         with a few checks skipped)
  --uninstall            Remove everything this installer added (logs and the
                         reflector are never touched)
  --auth key|password|both
                         How the app logs in (default: asked; "key" is recommended)
  --pubkey "ssh-ed25519 AAAA..."
                         Public key shown by the app (can be repeated)
  --pubkey-file FILE     File containing one public key
  --reset-password       Generate a new password for the account (password/both)
  --user NAME            Service account name (default: ysfmonitor)
  --ini PATH             Path to YSFReflector.ini (default: detected, else
                         /etc/YSFReflector.ini)
  --retention-days N     Delete log files older than N days (default: 180, min 7)
  --no-retention         Do not install the log cleanup job
  --rollback-timer MIN   Safety net: if you do not cancel it, the SSH settings are removed
                         automatically after MIN minutes (cancel after you checked that
                         the new login works: systemctl stop ysf-sysop-rollback.timer)
  -y, --yes              Do not ask for confirmation (answers must be given by options)
  --print-helper         Print the embedded read-only helper script and exit
  --version              Print the installer version
  -h, --help             This help
EOF
}

emit_helper() {
cat <<'YSF_HELPER_EOF'
#!/bin/bash
# ysf-sysop-log - read-only log access for the YSF Sysop app.
# Installed and managed by YSF-Pi-Installer. Do not edit.
#
# Runs as the ForceCommand of a restricted SSH account. The client's requested
# command arrives in SSH_ORIGINAL_COMMAND and must be one of a closed list:
#   version                     print the helper version
#   status                      key=value lines about the reflector and the log
#   list                        "YYYY-MM-DD size-in-bytes" for each daily log file
#   read   YYYY-MM-DD OFFSET    raw bytes of that day's log from byte OFFSET to the end
#   follow YYYY-MM-DD OFFSET    like read, then keeps streaming new bytes; ends by
#                               itself (exit 0) shortly after UTC midnight
# Log files are named with the UTC date (that is how YSFReflector rotates them).
# Errors: one line "ERR <message>" on stdout and a non-zero exit status.
set -u
export LC_ALL=C
PATH=/usr/local/bin:/usr/bin:/bin
CONF=/etc/ysf-sysop/ysf-sysop.conf
HELPER_VERSION=1

LOG_DIR=""; LOG_ROOT=""; INI_PATH=""; PROC_NAME="YSFReflector"
if [ -r "$CONF" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      LOG_DIR)   LOG_DIR=$v ;;
      LOG_ROOT)  LOG_ROOT=$v ;;
      INI_PATH)  INI_PATH=$v ;;
      PROC_NAME) PROC_NAME=$v ;;
    esac
  done < "$CONF"
fi

fail() { printf 'ERR %s\n' "$1"; exit "$2"; }

usage() {
  cat <<EOF
ysf-sysop-log helper v$HELPER_VERSION (YSF-Pi-Installer)
Read-only access to the YSFReflector log for the YSF Sysop app.
Commands (sent as the SSH command):
  version
  status
  list
  read   YYYY-MM-DD OFFSET
  follow YYYY-MM-DD OFFSET
EOF
}

ini_get() { # $1 section, $2 key
  awk -v sec="$1" -v key="$2" '
    /^#/ { next }
    /^\[/ { cur = (index($0, "[" sec "]") == 1) ? 1 : 0; next }
    cur {
      line = $0; sub(/\r$/, "", line)
      k = line; sub(/[ \t=].*$/, "", k)
      if (k != key) next
      v = line; sub(/^[^ \t=]+[ \t]*=?[ \t]*/, "", v)
      if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2) }
      else { sub(/#.*$/, "", v); sub(/[ \t]+$/, "", v) }
      val = v
    }
    END { print val }
  ' "$INI_PATH"
}

valid_date() {
  local re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  [[ $1 =~ $re ]] && [ "$(date -u -d "$1" +%F 2>/dev/null)" = "$1" ]
}
valid_offset() {
  local re='^[0-9]{1,12}$'
  [[ $1 =~ $re ]]
}
log_file() { printf '%s/%s-%s.log' "$LOG_DIR" "$LOG_ROOT" "$1"; }

do_status() {
  local today f n p
  today=$(date -u +%F)
  echo "helper_version=$HELPER_VERSION"
  echo "utc_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "utc_date=$today"
  f=$(log_file "$today")
  if [ -r "$f" ]; then echo "today_file_size=$(stat -c %s -- "$f")"; else echo "today_file_size=none"; fi
  if pgrep -x "$PROC_NAME" >/dev/null 2>&1; then echo "reflector_running=yes"; else echo "reflector_running=no"; fi
  if [ -n "$INI_PATH" ] && [ -r "$INI_PATH" ]; then
    n=$(ini_get Info Name | tr -d '\000-\037')
    p=$(ini_get Network Port | tr -d '\000-\037')
    echo "reflector_name=$n"
    echo "reflector_port=$p"
  fi
}

do_list() {
  local f d
  for f in "$LOG_DIR/$LOG_ROOT"-????-??-??.log; do
    [ -f "$f" ] || continue
    d=${f##*/}; d=${d#"$LOG_ROOT"-}; d=${d%.log}
    echo "$d $(stat -c %s -- "$f")"
  done
}

do_read() {
  local f size off today
  valid_date "$1" || fail "bad date" 2
  valid_offset "$2" || fail "bad offset" 2
  f=$(log_file "$1")
  if [ ! -r "$f" ]; then
    today=$(date -u +%F)
    # The reflector creates a new day's file only when it writes its first line.
    if [ "$1" = "$today" ]; then exit 0; fi
    fail "no such log file" 3
  fi
  size=$(stat -c %s -- "$f")
  off=$((10#$2))
  [ "$off" -le "$size" ] || fail "offset beyond end of file (size $size)" 4
  exec tail -c +"$((off + 1))" -- "$f"
}

do_follow() {
  local f size off today now next remaining rc
  valid_date "$1" || fail "bad date" 2
  valid_offset "$2" || fail "bad offset" 2
  today=$(date -u +%F)
  [ "$1" = "$today" ] || fail "follow supports only the current UTC date ($today)" 5
  f=$(log_file "$1")
  now=$(date -u +%s)
  next=$(( $(date -u -d "$today 00:00:00" +%s) + 86400 ))
  remaining=$(( next - now + 2 ))
  [ "$remaining" -ge 3 ] || remaining=3
  while [ ! -r "$f" ]; do
    sleep 1
    [ "$(date -u +%F)" = "$today" ] || exit 0
  done
  size=$(stat -c %s -- "$f")
  off=$((10#$2))
  [ "$off" -le "$size" ] || fail "offset beyond end of file (size $size)" 4
  timeout "$remaining" tail --pid="$PPID" -c +"$((off + 1))" -f -- "$f"
  rc=$?
  [ "$rc" -eq 124 ] && rc=0
  exit "$rc"
}

cmd=${SSH_ORIGINAL_COMMAND:-}
if [ -z "$cmd" ]; then usage; exit 0; fi
re_cmd='^[A-Za-z0-9 ._-]{1,64}$'
[[ $cmd =~ $re_cmd ]] || fail "invalid command" 2
[ -n "$LOG_DIR" ] && [ -n "$LOG_ROOT" ] || fail "helper is not configured" 10
[ -d "$LOG_DIR" ] || fail "log directory not found" 11

# shellcheck disable=SC2086  # intentional word splitting of the validated command
set -- $cmd
case "$1" in
  version) [ $# -eq 1 ] || fail "usage: version" 2; echo "$HELPER_VERSION" ;;
  status)  [ $# -eq 1 ] || fail "usage: status" 2;  do_status ;;
  list)    [ $# -eq 1 ] || fail "usage: list" 2;    do_list ;;
  read)    [ $# -eq 3 ] || fail "usage: read YYYY-MM-DD OFFSET" 2;   do_read "$2" "$3" ;;
  follow)  [ $# -eq 3 ] || fail "usage: follow YYYY-MM-DD OFFSET" 2; do_follow "$2" "$3" ;;
  *)       fail "unknown command" 2 ;;
esac
YSF_HELPER_EOF
}

# ----------------------------------------------------------------- arguments
need_value() { [ "$#" -ge 2 ] || die "option $1 needs a value"; }

valid_pubkey() { # prints "type base64" if the line is one plain public key
  local line type b64 tmp
  local re='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]]+([A-Za-z0-9+/]+=*)([[:space:]].*)?$'
  line=$(printf '%s' "$1" | tr -d '\r')
  case "$line" in *$'\n'*) return 1 ;; esac
  if [[ $line =~ $re ]]; then type=${BASH_REMATCH[1]}; b64=${BASH_REMATCH[2]}; else return 1; fi
  tmp=$(mktemp)
  printf '%s %s\n' "$type" "$b64" > "$tmp"
  if ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; printf '%s %s' "$type" "$b64"; return 0
  fi
  rm -f "$tmp"; return 1
}

add_pubkey_arg() {
  local k
  k=$(valid_pubkey "$1") || die "that does not look like a valid single-line public key (ssh-ed25519, ssh-rsa or ecdsa-sha2-*)"
  PUBKEYS="${PUBKEYS}${k}"$'\n'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes|-y) YES=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --reset-password) RESET_PASSWORD=1 ;;
    --no-retention) NO_RETENTION=1 ;;
    --auth) need_value "$@"; AUTH_MODE=$2; shift ;;
    --user) need_value "$@"; SVC_USER=$2; shift ;;
    --ini) need_value "$@"; INI_PATH=$2; shift ;;
    --retention-days) need_value "$@"; RETENTION_DAYS=$2; shift ;;
    --rollback-timer) need_value "$@"; ROLLBACK_MIN=$2; shift ;;
    --pubkey) need_value "$@"; PUBKEY_ARGS_PENDING="${PUBKEY_ARGS_PENDING}${2}"$'\n'; shift ;;
    --pubkey-file) need_value "$@"; [ -r "$2" ] || die "cannot read $2"; PUBKEY_ARGS_PENDING="${PUBKEY_ARGS_PENDING}$(head -n1 "$2")"$'\n'; shift ;;
    --print-helper) emit_helper; exit 0 ;;
    --version) say "YSF-Pi-Installer $INSTALLER_VERSION (helper v$HELPER_VERSION)"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

# --------------------------------------------------------------- interaction
have_tty() { { : </dev/tty; } 2>/dev/null; }

ask() { # $1 prompt  -> sets REPLY ; reads from the terminal even when piped (curl | bash)
  if ! have_tty; then die "no terminal available for a question; use --yes and the command-line options (see --help)"; fi
  printf '%s' "$1" >/dev/tty
  IFS= read -r REPLY </dev/tty || die "no answer received"
}

confirm() { # $1 question, default No
  if [ "$YES" = 1 ]; then return 0; fi
  ask "$1 [y/N] "
  case "$REPLY" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------------ checks
check_environment() {
  [ "$(uname -s)" = "Linux" ] || die "this installer is for Linux (Raspberry Pi OS / Debian)."
  if [ "$(id -u)" -eq 0 ]; then
    IS_ROOT=1
  else
    if [ "$DRY" = 1 ]; then
      warn "not running as root: --dry-run will skip the checks that need root."
    else
      die "please run as root:  sudo bash install.sh   (use --dry-run to preview without sudo)"
    fi
  fi
  local c missing=""
  for c in awk tail timeout date stat sshd systemctl useradd usermod chpasswd runuser getent install ssh-keygen pgrep mktemp; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  [ -z "$missing" ] || die "missing required commands:$missing"
  if [ "$UNINSTALL" != 1 ]; then
    case "$SVC_USER" in
      [a-z_][a-z0-9_-][a-z0-9_-]*) ;;
      *) die "invalid account name: $SVC_USER" ;;
    esac
    case "$RETENTION_DAYS" in ''|*[!0-9]*) die "--retention-days must be a number" ;; esac
    [ "$RETENTION_DAYS" -ge 7 ] || die "--retention-days must be at least 7"
    case "$AUTH_MODE" in ''|key|password|both) ;; *) die "--auth must be key, password or both" ;; esac
    case "$ROLLBACK_MIN" in ''|*[!0-9]*) die "--rollback-timer must be a number of minutes" ;; esac
    if [ "$ROLLBACK_MIN" -gt 0 ]; then
      [ "$ROLLBACK_MIN" -le 240 ] || die "--rollback-timer must be at most 240 minutes"
      command -v systemd-run >/dev/null 2>&1 || die "--rollback-timer needs systemd-run"
    fi
  fi
}

ini_get() { # $1 section, $2 key  (same rules as the reflector's own parser)
  awk -v sec="$1" -v key="$2" '
    /^#/ { next }
    /^\[/ { cur = (index($0, "[" sec "]") == 1) ? 1 : 0; next }
    cur {
      line = $0; sub(/\r$/, "", line)
      k = line; sub(/[ \t=].*$/, "", k)
      if (k != key) next
      v = line; sub(/^[^ \t=]+[ \t]*=?[ \t]*/, "", v)
      if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2) }
      else { sub(/#.*$/, "", v); sub(/[ \t]+$/, "", v) }
      val = v
    }
    END { print val }
  ' "$INI_PATH"
}

detect_reflector() {
  info "Looking for your YSFReflector"
  local pid cwd
  if [ -z "$INI_PATH" ]; then
    pid=$(pgrep -x "$REFLECTOR_PROC" | head -n1 || true)
    if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
      INI_PATH=$(tr '\0' '\n' < "/proc/$pid/cmdline" | tail -n +2 | tail -n 1 || true)
      case "$INI_PATH" in
        ''|-*) INI_PATH="" ;;
        /*) ;;
        *) cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
           if [ -n "$cwd" ]; then INI_PATH="$cwd/${INI_PATH#./}"; else INI_PATH=""; fi ;;
      esac
    fi
    [ -n "$INI_PATH" ] || INI_PATH="/etc/YSFReflector.ini"
  fi
  [ -r "$INI_PATH" ] || die "cannot read the reflector configuration: $INI_PATH (use --ini PATH)"
  say "  configuration : $INI_PATH"

  LOG_DIR=$(ini_get Log FilePath)
  LOG_ROOT=$(ini_get Log FileRoot)
  local file_level rotate
  file_level=$(ini_get Log FileLevel)
  rotate=$(ini_get Log FileRotate)
  REFLECTOR_NAME=$(ini_get Info Name | tr -d '\000-\037')
  UDP_PORT=$(ini_get Network Port)

  [ -n "$LOG_DIR" ] && [ -n "$LOG_ROOT" ] || die "the [Log] section of $INI_PATH needs FilePath and FileRoot."
  case "$LOG_DIR" in
    /*) ;;
    *) die "FilePath in $INI_PATH must be an absolute path (found: $LOG_DIR)" ;;
  esac
  local re_dir='^/[A-Za-z0-9._/+-]+$' re_root='^[A-Za-z0-9._-]+$'
  [[ $LOG_DIR =~ $re_dir ]] || die "FilePath contains characters this installer does not support yet: $LOG_DIR"
  [[ $LOG_ROOT =~ $re_root ]] || die "FileRoot contains characters this installer does not support yet: $LOG_ROOT"
  LOG_DIR=${LOG_DIR%/}
  [ -d "$LOG_DIR" ] || die "log folder not found: $LOG_DIR"

  case "${file_level:-0}" in
    1|2) ;;
    *) die "FileLevel in $INI_PATH is '${file_level:-not set}'. The events the app shows are written at level 2, so FileLevel must be 1 or 2 (0 = no log file). Edit the [Log] section, restart the reflector, and run this again." ;;
  esac
  if [ -n "$rotate" ] && [ "$rotate" != "1" ]; then
    die "FileRotate in $INI_PATH is '$rotate'. This version needs daily log files: set FileRotate=1."
  fi

  say "  log folder    : $LOG_DIR  (files: $LOG_ROOT-YYYY-MM-DD.log, dates in UTC)"
  say "  reflector name: ${REFLECTOR_NAME:-unknown}   UDP port: ${UDP_PORT:-unknown}"

  local latest="" f
  for f in "$LOG_DIR/$LOG_ROOT"-????-??-??.log; do [ -f "$f" ] && latest=$f; done
  if [ -z "$latest" ]; then
    warn "no log file found yet in $LOG_DIR - is the reflector running?"
  else
    check_log_readable "$latest"
  fi
}

check_log_readable() { # the service account is neither the owner nor in the group: it counts as "other"
  local probe=()
  if [ "$IS_ROOT" = 1 ] && command -v runuser >/dev/null 2>&1 && getent passwd nobody >/dev/null; then
    probe=(runuser -u nobody --)
  fi
  if ! "${probe[@]}" test -x "$LOG_DIR" || ! "${probe[@]}" test -r "$1"; then
    die "the log files are not readable by ordinary accounts ($1).
       Make the folder and files world-readable (for example: chmod o+rx '$LOG_DIR' and chmod o+r on the log files)
       or tell the reflector to create them that way, then run this installer again."
  fi
  say "  log access    : OK (readable without sudo)"
}

# ------------------------------------------------------------- choices
account_exists() { getent passwd "$SVC_USER" >/dev/null 2>&1; }
account_is_ours() { getent passwd "$SVC_USER" | grep -F "$ACCOUNT_MARKER" >/dev/null; }

choose_auth() {
  if [ -n "$AUTH_MODE" ]; then return; fi
  if [ "$YES" = 1 ]; then AUTH_MODE="key"; return; fi
  say ""
  say "How will the app log in to this Pi?"
  say "  1) SSH key (recommended: the key is created on your iPhone and never leaves it)"
  say "  2) Password (a long random one is generated for you)"
  say "  3) Both"
  ask "Choice [1]: "
  case "$REPLY" in
    ''|1) AUTH_MODE="key" ;;
    2) AUTH_MODE="password" ;;
    3) AUTH_MODE="both" ;;
    *) die "invalid choice" ;;
  esac
}

collect_keys() {
  local p
  if [ -n "$PUBKEY_ARGS_PENDING" ]; then
    while IFS= read -r p; do
      if [ -n "$p" ]; then add_pubkey_arg "$p"; fi
    done <<< "$PUBKEY_ARGS_PENDING"
  fi
  case "$AUTH_MODE" in key|both) ;; *) return ;; esac
  if [ -n "$PUBKEYS" ] || { [ -s "$AUTH_KEYS" ] && grep -q '^restrict ' "$AUTH_KEYS" 2>/dev/null; } ; then
    return
  fi
  if [ "$YES" = 1 ] || [ "$DRY" = 1 ]; then
    [ "$DRY" = 1 ] && return
    die "key login needs the app's public key: pass it with --pubkey 'ssh-ed25519 AAAA...'"
  fi
  say ""
  say "Open the YSF Sysop app, create the key, and copy its PUBLIC key (one line starting with ssh-ed25519)."
  ask "Paste it here: "
  add_pubkey_arg "$REPLY"
}

show_plan() {
  say ""
  info "Plan"
  say "  account            : $SVC_USER $(account_exists && echo '(already exists)' || echo '(will be created)')"
  say "  login method       : $AUTH_MODE"
  say "  read-only helper   : $HELPER_PATH (v$HELPER_VERSION)"
  say "  SSH settings file  : $SSHD_DROPIN (applies to $SVC_USER only; sshd is reloaded, not restarted)"
  say "  settings/keys      : $CONF_DIR"
  if [ "$ROLLBACK_MIN" -gt 0 ]; then say "  safety timer       : SSH settings removed automatically after $ROLLBACK_MIN min unless you cancel it"; fi
  if [ "$NO_RETENTION" = 1 ]; then
    say "  log cleanup        : not installed (--no-retention)"
  elif [ "$IS_ROOT" != 1 ]; then
    say "  log cleanup        : $RETENTION_DAYS days unless you already have one (cannot check root's cron jobs without sudo)"
  elif existing_retention >/dev/null; then
    say "  log cleanup        : you already have one ($(existing_retention)) - left as is"
  else
    say "  log cleanup        : delete log files older than $RETENTION_DAYS days, daily ($CRON_FILE)"
  fi
  say "  not touched        : the reflector, its configuration, its service, your other accounts"
}

# ----------------------------------------------------------------- retention
existing_retention() { # prints where a cleanup of this log folder already exists
  local where=""
  if [ "$IS_ROOT" = 1 ] && command -v crontab >/dev/null 2>&1; then
    if crontab -l -u root 2>/dev/null | grep -F "$LOG_DIR" | grep -E 'find.*-delete' >/dev/null; then where="root crontab"; fi
  fi
  if [ -z "$where" ]; then
    local hits
    hits=$(grep -rFl "$LOG_DIR" /etc/cron.d /etc/cron.daily /etc/cron.weekly 2>/dev/null | grep -v 'ysf-sysop-retention' || true)
    if [ -n "$hits" ]; then where="/etc/cron.*"; fi
  fi
  [ -n "$where" ] && printf '%s' "$where"
  [ -n "$where" ]
}

install_retention() {
  [ "$NO_RETENTION" = 1 ] && return 0
  if existing_retention >/dev/null; then return 0; fi
  if [ "$DRY" != 1 ] && ! systemctl is-active --quiet cron 2>/dev/null; then
    warn "the cron service is not running, so the log cleanup was not installed."
    return 0
  fi
  act "write $CRON_FILE (delete $LOG_ROOT-*.log older than $RETENTION_DAYS days, every day at 03:17)"
  [ "$DRY" = 1 ] && return 0
  printf '%s\n' \
    "# Managed by YSF-Pi-Installer. Removes old reflector log files." \
    "17 3 * * * root find '$LOG_DIR' -maxdepth 1 -name '$LOG_ROOT-????-??-??.log' -type f -mtime +$RETENTION_DAYS -delete" \
    > "$CRON_FILE.new"
  chmod 0644 "$CRON_FILE.new"
  mv "$CRON_FILE.new" "$CRON_FILE"
}

# ------------------------------------------------------------------- apply
write_atomic() { # $1 destination, $2 mode ; content on stdin
  local tmp
  tmp=$(mktemp "$1.XXXXXX")
  cat > "$tmp"
  chmod "$2" "$tmp"
  chown root:root "$tmp"
  mv "$tmp" "$1"
}

gen_password() {
  local pw
  pw=$( (set +o pipefail; LC_ALL=C tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789' </dev/urandom | head -c 24) )
  [ "${#pw}" -eq 24 ] || die "could not generate a password"
  printf '%s' "$pw"
}

ensure_account() {
  if account_exists; then
    account_is_ours || die "an account named '$SVC_USER' already exists and was not created by this installer. Choose another name with --user."
    act "account $SVC_USER already exists: kept"
    return
  fi
  act "create the account $SVC_USER (system account, no sudo, no home you can write to)"
  [ "$DRY" = 1 ] && return 0
  install -d -m 0755 -o root -g root "$SVC_HOME"
  useradd --system --user-group --home-dir "$SVC_HOME" --no-create-home \
          --shell /bin/bash --comment "$ACCOUNT_MARKER" "$SVC_USER"
}

write_helper_and_conf() {
  act "install the read-only helper $HELPER_PATH and its settings in $CONF_DIR"
  [ "$DRY" = 1 ] && return 0
  install -d -m 0755 -o root -g root "$CONF_DIR"
  emit_helper | write_atomic "$HELPER_PATH" 0755
  printf '%s\n' "LOG_DIR=$LOG_DIR" "LOG_ROOT=$LOG_ROOT" "INI_PATH=$INI_PATH" "PROC_NAME=$REFLECTOR_PROC" \
    | write_atomic "$CONF_FILE" 0644
}

update_keys() {
  local line existing="" new=""
  [ -f "$AUTH_KEYS" ] && existing=$(grep '^restrict ' "$AUTH_KEYS" 2>/dev/null || true)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$existing" in *" $line "*) continue ;; esac
    new="${new}restrict $line ysf-sysop-app"$'\n'
  done <<< "$PUBKEYS"
  if [ -n "$new" ]; then act "authorize $(printf '%s' "$new" | grep -c .) public key(s) in $AUTH_KEYS (restricted: no forwarding, no terminal)"; fi
  [ "$DRY" = 1 ] && return 0
  if [ "$AUTH_MODE" = "password" ]; then existing=""; new=""; fi
  { [ -n "$existing" ] && printf '%s\n' "$existing"; [ -n "$new" ] && printf '%s' "$new"; true; } | write_atomic "$AUTH_KEYS" 0644
}

update_password() {
  local hash=""
  if [ "$IS_ROOT" = 1 ]; then hash=$(getent shadow "$SVC_USER" 2>/dev/null | cut -d: -f2 || true); fi
  case "$AUTH_MODE" in
    key)
      act "password login disabled for $SVC_USER"
      [ "$DRY" = 1 ] && return 0
      usermod -p '*' "$SVC_USER"
      ;;
    password|both)
      if [[ $hash == \$* ]] && [ "$RESET_PASSWORD" != 1 ]; then
        act "keep the existing password (use --reset-password to generate a new one)"
        return 0
      fi
      act "generate a long random password for $SVC_USER (shown once at the end)"
      [ "$DRY" = 1 ] && return 0
      NEW_PASSWORD=$(gen_password)
      printf '%s:%s\n' "$SVC_USER" "$NEW_PASSWORD" | chpasswd
      ;;
  esac
}

dropin_content() {
  local pw="no" pk="no"
  case "$AUTH_MODE" in key) pk="yes" ;; password) pw="yes" ;; both) pw="yes"; pk="yes" ;; esac
  cat <<EOF
# Managed by YSF-Pi-Installer. Applies ONLY to the account $SVC_USER.
Match User $SVC_USER
    AuthorizedKeysFile $AUTH_KEYS
    ForceCommand $HELPER_PATH
    PasswordAuthentication $pw
    PubkeyAuthentication $pk
    PermitTTY no
    DisableForwarding yes
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
    PermitUserRC no
    MaxAuthTries 3
    MaxSessions 4
EOF
}

sshd_effective() { sshd -T -C "user=$1,host=localhost,addr=127.0.0.1" 2>&1; }

reload_sshd() {
  if systemctl reload ssh 2>/dev/null; then return 0; fi
  if systemctl reload sshd 2>/dev/null; then return 0; fi
  return 1
}

arm_rollback() {
  [ "$ROLLBACK_MIN" -gt 0 ] || return 0
  act "arm a safety timer: in $ROLLBACK_MIN min the SSH settings are removed automatically unless you cancel it"
  [ "$DRY" = 1 ] && return 0
  systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
  systemctl reset-failed "$ROLLBACK_UNIT.service" 2>/dev/null || true
  systemd-run --quiet --unit="$ROLLBACK_UNIT" --collect --on-active="$((ROLLBACK_MIN * 60))" \
    --description="YSF-Pi-Installer safety rollback" \
    /bin/sh -c "rm -f '$SSHD_DROPIN'; usermod -p '*' '$SVC_USER'; systemctl reload ssh || systemctl reload sshd" \
    || die "could not arm the safety timer; nothing was changed in SSH."
  say "  safety timer armed (cancel with: systemctl stop $ROLLBACK_UNIT.timer)"
}

apply_sshd() {
  act "write $SSHD_DROPIN, check it with 'sshd -t', then reload the SSH service (your current sessions stay open)"
  [ "$DRY" = 1 ] && return 0
  local backup="" after check after_admin
  arm_rollback
  if [ -f "$SSHD_DROPIN" ]; then backup=$(mktemp); cp -p "$SSHD_DROPIN" "$backup"; fi
  dropin_content | write_atomic "$SSHD_DROPIN" 0644

  rollback_sshd() {
    if [ -n "$backup" ]; then mv "$backup" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
  }

  if ! sshd -t 2>&1; then rollback_sshd; die "sshd rejected the new settings; they were removed. Nothing was reloaded."; fi

  check=$(sshd_effective "$SVC_USER" || true)
  local want
  for want in "forcecommand $HELPER_PATH" "authorizedkeysfile $AUTH_KEYS" "permittty no"; do
    if ! printf '%s\n' "$check" | grep -xF "$want" >/dev/null; then
      rollback_sshd; die "sshd's effective settings for $SVC_USER do not contain '$want' (another SSH setting may take priority). Settings removed; nothing was reloaded."
    fi
  done
  after=$(sshd_effective root || true)
  if [ "$BASELINE" != "$after" ]; then
    rollback_sshd; die "the new settings would also change SSH behaviour for other accounts. They were removed; nothing was reloaded."
  fi
  if [ -n "$ADMIN_USER" ]; then
    after_admin=$(sshd_effective "$ADMIN_USER" || true)
    if [ "$BASELINE_ADMIN" != "$after_admin" ]; then
      rollback_sshd; die "the new settings would change SSH behaviour for your own account ($ADMIN_USER). They were removed; nothing was reloaded."
    fi
  fi
  if printf '%s\n' "$check" | grep -Ei '^(allowusers|allowgroups) ' >/dev/null; then
    warn "your SSH configuration restricts who may log in (AllowUsers/AllowGroups). Make sure '$SVC_USER' is allowed."
  fi
  reload_sshd || { rollback_sshd; die "could not reload the SSH service; settings removed."; }
  [ -n "$backup" ] && rm -f "$backup"
  systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null || warn "could not confirm that the SSH service is active - check it before closing this session."
  say "  SSH settings active."
}

self_test() {
  act "test the helper as $SVC_USER"
  [ "$DRY" = 1 ] && return 0
  local out
  out=$(runuser -u "$SVC_USER" -- env SSH_ORIGINAL_COMMAND=status "$HELPER_PATH" 2>&1 || true)
  printf '%s\n' "$out" | grep '^helper_version=' >/dev/null || die "self-test failed. Output was: $out"
  say "  helper answers correctly:"
  printf '%s\n' "$out" | sed 's/^/    /'
  out=$(runuser -u "$SVC_USER" -- env SSH_ORIGINAL_COMMAND=list "$HELPER_PATH" 2>&1 || true)
  say "  log files visible to $SVC_USER: $(printf '%s\n' "$out" | grep -c '^[0-9]')"
}

json_escape() { printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

summary() {
  local port auth_json
  port=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}' || true)
  port=${port:-22}
  case "$AUTH_MODE" in key) auth_json='["key"]' ;; password) auth_json='["password"]' ;; both) auth_json='["key","password"]' ;; esac
  say ""
  info "Done."
  say "  account        : $SVC_USER"
  say "  login method   : $AUTH_MODE"
  say "  SSH port       : $port   (to use the app away from home, forward this TCP port on your router to this Pi)"
  if [ -n "$NEW_PASSWORD" ]; then
    say ""
    say "  ${BOLD}Password for $SVC_USER (shown ONCE - copy it into the app now):${OFF}"
    say "      $NEW_PASSWORD"
  fi
  if [ "$ROLLBACK_MIN" -gt 0 ]; then
    say ""
    say "  ${BOLD}SAFETY TIMER ARMED:${OFF} in $ROLLBACK_MIN minutes the new SSH access is removed automatically."
    say "  After you checked that the new login works, cancel it with:"
    say "      sudo systemctl stop $ROLLBACK_UNIT.timer"
  fi
  say ""
  say "  Pairing info for the app (no secrets):"
  say "  {\"v\":1,\"app\":\"ysf-sysop\",\"user\":\"$SVC_USER\",\"port\":$port,\"auth\":$auth_json,\"reflector\":\"$(json_escape "$REFLECTOR_NAME")\",\"udp_port\":${UDP_PORT:-0}}"
  say ""
  say "  Remove everything later with:  sudo bash install.sh --uninstall"
}

# --------------------------------------------------------------- uninstall
do_uninstall() {
  info "Uninstall"
  say "This removes: the account $SVC_USER, $SSHD_DROPIN, $CONF_DIR, $HELPER_PATH, $CRON_FILE."
  say "It does NOT touch your reflector, its configuration, or any log file."
  if [ "$DRY" != 1 ]; then confirm "Continue?" || die "cancelled"; fi
  act "remove $SSHD_DROPIN, check sshd, reload the SSH service"
  if [ "$DRY" != 1 ]; then
    systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
    rm -f "$SSHD_DROPIN"
    sshd -t 2>&1 || die "sshd reports a problem with the remaining SSH settings; please check them before closing this session."
    reload_sshd || warn "could not reload the SSH service."
  fi
  act "remove $HELPER_PATH, $CONF_DIR and $CRON_FILE"
  if [ "$DRY" != 1 ]; then rm -rf "$CONF_DIR" "$HELPER_PATH" "$CRON_FILE"; fi
  if account_exists; then
    if account_is_ours; then
      act "delete the account $SVC_USER"
      if [ "$DRY" != 1 ]; then
        pkill -u "$SVC_USER" 2>/dev/null || true
        userdel "$SVC_USER" 2>/dev/null || warn "could not delete the account $SVC_USER"
        rm -rf "$SVC_HOME"
      fi
    else
      warn "the account '$SVC_USER' was not created by this installer: left untouched."
    fi
  fi
  [ "$DRY" = 1 ] || say "Uninstall finished."
}

# -------------------------------------------------------------------- main
check_environment
if [ "$UNINSTALL" = 1 ]; then do_uninstall; exit 0; fi

say "YSF-Pi-Installer $INSTALLER_VERSION$( [ "$DRY" = 1 ] && printf '  (dry run: nothing will be changed)' )"
detect_reflector
choose_auth
collect_keys

if [ "$IS_ROOT" = 1 ]; then
  BASELINE=$(sshd_effective root || true)
  ADMIN_USER=${SUDO_USER:-}
  if [ -n "$ADMIN_USER" ] && [ "$ADMIN_USER" != "root" ] && getent passwd "$ADMIN_USER" >/dev/null 2>&1; then
    BASELINE_ADMIN=$(sshd_effective "$ADMIN_USER" || true)
  else
    ADMIN_USER=""
  fi
fi
show_plan
if [ "$DRY" != 1 ]; then confirm "Proceed?" || die "cancelled"; fi

say ""
info "Applying"
ensure_account
write_helper_and_conf
update_keys
apply_sshd
update_password
self_test
install_retention
if [ "$DRY" = 1 ]; then
  say ""
  say "Dry run finished: nothing was changed."
else
  summary
fi
