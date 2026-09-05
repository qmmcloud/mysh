#!/usr/bin/env bash

# 1. 严格单例锁（防止 Cron 与开机并发碰撞）
LOCK_FILE="/var/run/cf-ddns.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || exit 0

# 2. 读取参数（优先入参，次优读取自存配置）
CF_TOKEN="${1}"
ZONE_ID="${2}"
RECORD_NAME="${3}"
CONF_FILE="/etc/cf-ddns.conf"

if [ -n "$CF_TOKEN" ] && [ -n "$ZONE_ID" ] && [ -n "$RECORD_NAME" ]; then
    # 只要外部传了参，就自动覆写本地持久化配置（保证幂等更新）
    cat << EOF > "$CONF_FILE"
CF_TOKEN="${CF_TOKEN}"
ZONE_ID="${ZONE_ID}"
RECORD_NAME="${RECORD_NAME}"
EOF
    chmod 600 "$CONF_FILE"
elif [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

if [ -z "$CF_TOKEN" ] || [ -z "$ZONE_ID" ] || [ -z "$RECORD_NAME" ]; then
    exit 1
fi

# 3. 宿主机环境自动巡检与自愈（依赖、持久化二进制、Cron）
which curl >/dev/null 2>&1 || (apt-get update -y && apt-get install -y curl)
which cron >/dev/null 2>&1 || (apt-get update -y && apt-get install -y cron)
systemctl enable --now cron >/dev/null 2>&1 || true

# 自安装到系统路径（如果当前不是通过该路径执行的）
SELF_PATH="/usr/local/bin/cf-ddns.sh"
if [ "$0" != "$SELF_PATH" ] && [ -f "$0" ]; then
    cp -f "$0" "$SELF_PATH"
    chmod +x "$SELF_PATH"
fi

# 自注册 1 分钟定时任务（原子性覆写，绝不重复生成）
CRON_FILE="/etc/cron.d/cf-ddns"
if [ ! -f "$CRON_FILE" ]; then
    cat << 'EOF' > "$CRON_FILE"
* * * * * root /usr/local/bin/cf-ddns.sh >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
fi

# 4. 核心 DDNS 逻辑
IP_CACHE="/tmp/cf_last_ip"

# 获取 IPv4（带超时防阻塞）
CURRENT_IP=$(curl -4 -s -m 8 https://cloudflare.com/cdn-cgi/trace | grep -E "^ip=" | cut -d= -f2)
[ -z "$CURRENT_IP" ] && exit 0

# IP 未变直接退出
[ -f "$IP_CACHE" ] && [ "$CURRENT_IP" = "$(cat "$IP_CACHE" 2>/dev/null)" ] && exit 0

# 查询当前所有记录
RECORDS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=${RECORD_NAME}" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json")

SUCCESS=$(echo "$RECORDS" | grep -o '"success":true')
[ -z "$SUCCESS" ] && exit 1

RECORD_IDS=$(echo "$RECORDS" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
PRIMARY_ID=$(echo "$RECORD_IDS" | head -n 1)

if [ -n "$PRIMARY_ID" ]; then
    # 覆盖第一条记录
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${PRIMARY_ID}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"${RECORD_NAME}\",\"content\":\"${CURRENT_IP}\",\"ttl\":60,\"proxied\":false}" >/dev/null

    # 彻底清理多余同名记录
    EXTRA_IDS=$(echo "$RECORD_IDS" | tail -n +2)
    for extra_id in $EXTRA_IDS; do
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${extra_id}" \
            -H "Authorization: Bearer ${CF_TOKEN}" >/dev/null
    done
else
    # 记录不存在时新增
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"A\",\"name\":\"${RECORD_NAME}\",\"content\":\"${CURRENT_IP}\",\"ttl\":60,\"proxied\":false}" >/dev/null
fi

# 更新缓存
echo "$CURRENT_IP" > "$IP_CACHE"
