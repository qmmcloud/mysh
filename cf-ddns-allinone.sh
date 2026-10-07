#!/usr/bin/env bash
# Cloudflare IPv4 DDNS bootstrap + updater for Debian and Alpine Linux.
# First run as root; installs required packages, installs this script, and
# ensures exactly one tagged one-minute cron entry exists.
# Config file (/etc/cf-ddns.conf): CF_TOKEN, ZONE_ID, RECORD_NAME

set -Eeuo pipefail
IFS=$'\n\t'

CONF_FILE=${CONF_FILE:-/etc/cf-ddns.conf}
LOCK_FILE=${LOCK_FILE:-/run/lock/cf-ddns.lock}
STATE_DIR=${STATE_DIR:-/var/lib/cf-ddns}
SELF_PATH=/usr/local/bin/cf-ddns.sh
CRON_MARKER='# cf-ddns managed entry'
API_BASE=https://api.cloudflare.com/client/v4

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

(( ${EUID:-$(id -u)} == 0 )) || die "Run this bootstrap script as root"

[[ -r /etc/os-release ]] || die "Cannot identify Linux distribution"
# shellcheck disable=SC1091
source /etc/os-release

# Install dependencies and cron using the native package manager. Repeated installs are safe.
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || \
   ! command -v flock >/dev/null 2>&1 || ! command -v crontab >/dev/null 2>&1; then
  case "${ID:-}" in
    debian|ubuntu)
      command -v apt-get >/dev/null 2>&1 || die "apt-get is required on ${ID}"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y bash curl jq util-linux cron
      ;;
    alpine)
      command -v apk >/dev/null 2>&1 || die "apk is required on Alpine"
      apk add --no-cache bash curl jq util-linux busybox-cron
      ;;
    *) die "Unsupported distribution: ${ID:-unknown} (supported: Debian/Ubuntu, Alpine)" ;;
  esac
fi

for cmd in bash curl jq flock awk stat crontab; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

# Persist supplied credentials/config values without evaluating them as shell code.
if (($# >= 3)); then
  umask 077
  tmp_conf=$(mktemp "${CONF_FILE}.XXXXXX") || die "Cannot create config file"
  printf 'CF_TOKEN=%q\nZONE_ID=%q\nRECORD_NAME=%q\n' "$1" "$2" "$3" >"$tmp_conf"
  chmod 600 "$tmp_conf"
  mv -f "$tmp_conf" "$CONF_FILE"
elif (($# != 0)); then
  die "Usage: $0 [CF_TOKEN ZONE_ID RECORD_NAME]"
fi
[[ -r "$CONF_FILE" ]] || die "Configuration file not readable: $CONF_FILE"

# Config is Bash syntax. When run as root, only source a root-owned private file.
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  config_owner=$(stat -c '%u' "$CONF_FILE" 2>/dev/null || stat -f '%u' "$CONF_FILE") \
    || die "Cannot determine config owner"
  [[ "$config_owner" == 0 ]] || die "Config must be owned by root"
  config_mode=$(stat -c '%a' "$CONF_FILE" 2>/dev/null || stat -f '%Lp' "$CONF_FILE") \
    || die "Cannot determine config permissions"
  # Accept only octal permission strings with no group/other access.
  [[ "$config_mode" =~ ^[0-7]{3,4}$ ]] || die "Cannot parse config permissions: $config_mode"
  config_mode=$((8#$config_mode))
  (( (config_mode & 077) == 0 )) || die "Config permissions must be 600 or stricter"
fi
# shellcheck disable=SC1090
source "$CONF_FILE"

: "${CF_TOKEN:?CF_TOKEN is required in config}"
: "${ZONE_ID:?ZONE_ID is required in config}"
: "${RECORD_NAME:?RECORD_NAME is required in config}"
[[ "$ZONE_ID" =~ ^[A-Fa-f0-9]{32}$ ]] || die "ZONE_ID must be a 32-character hex ID"
[[ "$RECORD_NAME" =~ ^[A-Za-z0-9.-]+$ ]] || die "RECORD_NAME contains unsupported characters"

# Install the running script at a stable path. Cron always calls this copy.
script_path=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
target_path=$(readlink -f "$SELF_PATH" 2>/dev/null || printf '%s' "$SELF_PATH")
if [[ "$script_path" != "$target_path" ]]; then
  install -D -m 0755 "$0" "$SELF_PATH" 2>/dev/null || {
    mkdir -p "$(dirname "$SELF_PATH")"
    cp -f "$0" "$SELF_PATH"
    chmod 0755 "$SELF_PATH"
  }
fi

# Start/enable the platform cron daemon idempotently.
if [[ "${ID:-}" == alpine ]]; then
  if command -v rc-update >/dev/null 2>&1; then
    rc-update add crond default >/dev/null 2>&1 || true
  fi
  if command -v rc-service >/dev/null 2>&1; then
    rc-service crond start >/dev/null 2>&1 || true
  else
    crond 2>/dev/null || true
  fi
else
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service cron start >/dev/null 2>&1 || service crond start >/dev/null 2>&1 || true
  fi
fi

# Replace only entries carrying our marker, then append one canonical job.
# This works with Debian cron and Alpine BusyBox crond via root's crontab.
current_cron=$(crontab -l 2>/dev/null || true)
filtered_cron=$(printf '%s\n' "$current_cron" | sed "\\|$CRON_MARKER|d")
printf '%s\n%s\n' "$filtered_cron" "* * * * * $SELF_PATH # cf-ddns managed entry" \
  | sed '/^[[:space:]]*$/d' | crontab - || die "Could not install crontab entry"

mkdir -p "$STATE_DIR" "$(dirname "$LOCK_FILE")" || die "Cannot create state/lock directories"
chmod 0750 "$STATE_DIR" 2>/dev/null || true
exec 9>"$LOCK_FILE" || die "Cannot open lock file: $LOCK_FILE"
flock -n 9 || exit 0

api() {
  curl --silent --show-error --fail --connect-timeout 5 --max-time 20 \
    --retry 2 --retry-delay 1 \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H 'Content-Type: application/json' "$@"
}

CURRENT_IP=$(curl --silent --show-error --fail --connect-timeout 5 --max-time 10 \
  --retry 2 -4 https://cloudflare.com/cdn-cgi/trace \
  | awk -F= '$1 == "ip" {print $2; exit}') || die "Could not detect public IPv4"
[[ "$CURRENT_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Invalid IPv4 result: $CURRENT_IP"
awk -F. 'NF != 4 || $1 > 255 || $2 > 255 || $3 > 255 || $4 > 255 { exit 1 }' \
  <<<"$CURRENT_IP" || die "Invalid IPv4 octet in result: $CURRENT_IP"

STATE_KEY=$(printf '%s' "${ZONE_ID}_${RECORD_NAME}" | tr -c 'A-Za-z0-9._-' '_')
STATE_FILE="$STATE_DIR/$STATE_KEY.ip"
if [[ -r "$STATE_FILE" ]] && [[ "$(<"$STATE_FILE")" == "$CURRENT_IP" ]]; then
  exit 0
fi

RECORDS=$(api --get "$API_BASE/zones/$ZONE_ID/dns_records" \
  --data-urlencode 'type=A' --data-urlencode "name=$RECORD_NAME" \
  --data-urlencode 'per_page=100') || die "Cloudflare record lookup failed"
jq -e '.success == true' >/dev/null <<<"$RECORDS" \
  || die "Cloudflare rejected record lookup: $(jq -c '.errors' <<<"$RECORDS")"
mapfile -t RECORD_IDS < <(jq -r '.result[].id' <<<"$RECORDS")

BODY=$(jq -cn --arg name "$RECORD_NAME" --arg ip "$CURRENT_IP" \
  '{type:"A", name:$name, content:$ip, ttl:60, proxied:false}')

if ((${#RECORD_IDS[@]} > 0)); then
  PRIMARY_ID=${RECORD_IDS[0]}
  RESPONSE=$(api -X PUT "$API_BASE/zones/$ZONE_ID/dns_records/$PRIMARY_ID" -d "$BODY") \
    || die "Cloudflare record update failed"
  jq -e '.success == true' >/dev/null <<<"$RESPONSE" \
    || die "Cloudflare rejected record update: $(jq -c '.errors' <<<"$RESPONSE")"

  # By design, remove every additional matching A record after the primary update succeeds.
  for ((i=1; i<${#RECORD_IDS[@]}; i++)); do
    RESPONSE=$(api -X DELETE "$API_BASE/zones/$ZONE_ID/dns_records/${RECORD_IDS[$i]}") \
      || die "Failed to delete duplicate record ${RECORD_IDS[$i]}"
    jq -e '.success == true' >/dev/null <<<"$RESPONSE" \
      || die "Cloudflare rejected duplicate deletion: $(jq -c '.errors' <<<"$RESPONSE")"
  done
else
  RESPONSE=$(api -X POST "$API_BASE/zones/$ZONE_ID/dns_records" -d "$BODY") \
    || die "Cloudflare record creation failed"
  jq -e '.success == true' >/dev/null <<<"$RESPONSE" \
    || die "Cloudflare rejected record creation: $(jq -c '.errors' <<<"$RESPONSE")"
fi

# Write cache only after the update and all requested duplicate removals succeeded.
TMP_STATE=$(mktemp "$STATE_DIR/.last-ip.XXXXXX") || die "Cannot create temporary state file"
printf '%s\n' "$CURRENT_IP" >"$TMP_STATE"
chmod 0640 "$TMP_STATE"
mv -f "$TMP_STATE" "$STATE_FILE"
log "Updated $RECORD_NAME to $CURRENT_IP; removed $(( ${#RECORD_IDS[@]} > 0 ? ${#RECORD_IDS[@]} - 1 : 0 )) duplicate record(s)"
