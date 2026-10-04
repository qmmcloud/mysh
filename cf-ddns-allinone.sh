#!/bin/sh

# 1. POSIX 严格单例文件锁（防止并发读写及争抢 API）
LOCK_FILE="/var/run/cf-ddns-allinone.lock"
exec 200>"$LOCK_FILE"
flock -n 200 2>/dev/null || exit 0

# 2. 参数解析与持久化配置（无参调用时自动读取已有配置）
CF_TOKEN="${1}"
ZONE_ID="${2}"
RECORD_NAME="${3}"
CONF_FILE="/etc/cf-ddns-allinone.conf"

if [ -n "$CF_TOKEN" ] && [ -n "$ZONE_ID" ] && [ -n "$RECORD_NAME" ]; then
    cat << EOF > "$CONF_FILE"
CF_TOKEN="${CF_TOKEN}"
ZONE_ID="${ZONE_ID}"
RECORD_NAME="${RECORD_NAME}"
EOF
    chmod 600 "$CONF_FILE"
elif [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
fi

if [ -z "$CF_TOKEN" ] || [ -z "$ZONE_ID" ] || [ -z "$RECORD_NAME" ]; then
    echo "[CF-DDNS] Error: Missing required credentials." >&2
    exit 1
fi

# 3. 规范化自安装与自愈路径
TARGET_PATH="/usr/local/bin/cf-ddns-allinone.sh"
CURRENT_EXEC=$(readlink -f "$0" 2>/dev/null || echo "$0")

if [ "$CURRENT_EXEC" != "$TARGET_PATH" ] && [ -f "$CURRENT_EXEC" ]; then
    cp -f "$CURRENT_EXEC" "$TARGET_PATH"
    chmod 755 "$TARGET_PATH"
fi

CRON_CMD="$TARGET_PATH >/dev/null 2>&1"

# 4. 系统环境探测与定时守护自愈（Alpine / Debian）
if command -v apk >/dev/null 2>&1; then
    # === Alpine Linux ===
    command -v curl >/dev/null 2>&1 || apk add --no-cache curl

    # 确保 BusyBox crond 进程常驻（优先 OpenRC，失效则直接后台派生）
    if ! pgrep -x crond >/dev/null 2>&1; then
        rc-service crond start >/dev/null 2>&1 || crond -b -l 8 >/dev/null 2>&1 || true
        rc-update add crond default >/dev/null 2>&1 || true
    fi

    # 幂等写入 Alpine crontab (BusyBox 规范路径)
    CRON_DIR="/var/spool/cron/crontabs"
    mkdir -p "$CRON_DIR"
    [ ! -f "${CRON_DIR}/root" ] && touch "${CRON_DIR}/root"
    if ! grep -qF "$TARGET_PATH" "${CRON_DIR}/root"; then
        echo "* * * * * $CRON_CMD" >> "${CRON_DIR}/root"
    fi
    chmod 600 "${CRON_DIR}/root"

elif command -v apt-get >/dev/null 2>&1; then
    # === Debian / Ubuntu ===
    command -v curl >/dev/null 2>&1 || (apt-get update -y && apt-get install -y curl)
    command -v cron >/dev/null 2>&1 || (apt-get update -y && apt-get install -y cron)

    # 启动 cron
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now cron >/dev/null 2>&1 || true
    else
        service cron start >/dev/null 2>&1 || true
    fi

    # 写入系统级定时配置
    CRON_FILE="/etc/cron.d/cf-ddns-allinone"
    if [ ! -f "$CRON_FILE" ] || ! grep -qF "$TARGET_PATH" "$CRON_FILE"; then
        echo "* * * * * root $CRON_CMD" > "$CRON_FILE"
        chmod 644 "$CRON_FILE"
    fi
fi

# 5. DDNS 解析同步核心逻辑
IP_CACHE="/tmp/cf_ddns_allinone_last_ip"

# 获取外网 IPv4（限制 8 秒超时，防网络阻塞）
CURRENT_IP=$(curl -4 -s -m 8 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E "^ip=" | cut -d= -f2)
[ -z "$CURRENT_IP" ] && exit 0

# IP 幂等校验：本机缓存未变则直接静默退出，保护 Cloudflare API 频率
if [ -f "$IP_CACHE" ] && [ "$CURRENT_IP" = "$(cat "$IP_CACHE" 2>/dev/null)" ]; then
    exit 0
fi

# 拉取 Cloudflare 现存解析记录
RECORDS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=${RECORD_NAME}" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json")

SUCCESS=$(echo "$RECORDS" | grep -o '"success":true')
[ -z "$SUCCESS" ] && exit 1

RECORD_IDS=$(echo "$RECORDS" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
PRIMARY_ID=$(echo "$RECORD_IDS" | head -n 1)

if [ -n "$PRIMARY_ID" ]; then
    # 更新已有主解析记录
    UPDATE_RES=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${PRIMARY_ID}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"${RECORD_NAME}\",\"content\":\"${CURRENT_IP}\",\"ttl\":60,\"proxied\":false}")

    # 清理多余同名记录（避免脏数据）
    EXTRA_IDS=$(echo "$RECORD_IDS" | tail -n +2)
    for extra_id in $EXTRA_IDS; do
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${extra_id}" \
            -H "Authorization: Bearer ${CF_TOKEN}" >/dev/null
    done
else
    # 不存在时新建
    UPDATE_RES=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"${RECORD_NAME}\",\"content\":\"${CURRENT_IP}\",\"ttl\":60,\"proxied\":false}")
fi

# API 确认生效后再更新本地缓存
if echo "$UPDATE_RES" | grep -q '"success":true'; then
    echo "$CURRENT_IP" > "$IP_CACHE"
fi
