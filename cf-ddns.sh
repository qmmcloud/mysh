#!/bin/sh
# Cloudflare IPv4 DDNS: POSIX sh, systemd/OpenRC, single-instance reconciliation.
# Existing boot command: /usr/local/bin/cf-ddns.sh TOKEN ZONE_ID FQDN
# No eval/source of configuration; no tokens in curl arguments; no blind POST retries.
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

# The caller downloads into ENTRY in-place. Services use a different, atomically
# installed path, so the next boot's curl -o never truncates a live service script.
ENTRY=/usr/local/bin/cf-ddns.sh
SELF=/usr/local/lib/cf-ddns/runner.sh
VERSION=2026.10.14-wildcard
CONF=/etc/cf-ddns.json
RUN=/var/run/cf-ddns
STATE=/var/lib/cf-ddns
LOG=/var/log/cf-ddns.log
API=https://api.cloudflare.com/client/v4
WORK=
CHILD=

log() {
    level=$1; shift
    line="$(date '+%Y-%m-%d %H:%M:%S%z') [$level] $*"
    printf '%s\n' "$line" >&2
    # Bounded persistent log, independent of whether Alpine syslog is enabled.
    if command -v flock >/dev/null 2>&1 && [ -d "$RUN" ]; then
        (
            exec 3>"$RUN/log.lock"
            flock -x 3 || exit 0
            if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 1048576 ]; then
                mv -f "$LOG" "$LOG.1" || exit 0
            fi
            printf '%s\n' "$line" >>"$LOG"
            chmod 600 "$LOG"
        ) 2>/dev/null || :
    else
        # First install can fail before flock exists; retain those errors too.
        printf '%s\n' "$line" >>"$LOG" 2>/dev/null || :
        chmod 600 "$LOG" 2>/dev/null || :
    fi
    if command -v logger >/dev/null 2>&1; then
        case "$level" in ERROR) pri=daemon.err;; WARN) pri=daemon.warning;; *) pri=daemon.info;; esac
        logger -t cf-ddns -p "$pri" -- "$*" 2>/dev/null || :
    fi
}
die() { log ERROR "$*"; exit 1; }
cleanup() {
    [ -z "$WORK" ] || rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

root_check() { [ "$(id -u)" = 0 ] || die '请使用 root 运行。'; }
dirs() {
    mkdir -p "$RUN" "$STATE" || die '无法创建运行目录。'
    chmod 700 "$RUN" "$STATE" || die '无法设置目录权限。'
}
runtime_deps() {
    for cmd in curl jq flock mktemp awk sed tr grep cut head sort date sleep cp mv chmod rm mkdir rmdir cat id wc tail env; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖 $cmd，请重新运行 --install。"
    done
    [ -s /etc/ssl/certs/ca-certificates.crt ] || die '缺少 CA 证书，请重新运行 --install。'
}
manager() {
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        printf '%s\n' systemd
    elif [ -d /run/openrc ] && command -v rc-service >/dev/null 2>&1; then
        printf '%s\n' openrc
    else
        return 1
    fi
}
package_step() {
    # Package output would otherwise vanish in the caller's >/dev/null 2>&1.
    if "$@" >"$RUN/package-step.log" 2>&1; then
        return 0
    else
        step_rc=$?
        log ERROR '依赖安装步骤失败；软件包管理器最近输出：'
        tail -n 15 "$RUN/package-step.log" | while IFS= read -r pkg_line; do log ERROR "$pkg_line"; done
        return "$step_rc"
    fi
}
deps_ready() {
    for cmd in curl jq flock mktemp awk sed tr grep cut head sort date sleep cp mv chmod rm mkdir rmdir cat id wc tail env logger crontab update-ca-certificates; do
        command -v "$cmd" >/dev/null 2>&1 || return 1
    done
    [ -s /etc/ssl/certs/ca-certificates.crt ] || return 1
    if [ -f /etc/alpine-release ]; then
        [ -x /etc/init.d/crond ] || return 1
        for cmd in rc-service rc-update start-stop-daemon crond; do command -v "$cmd" >/dev/null 2>&1 || return 1; done
    elif [ -f /etc/debian_version ]; then
        command -v cron >/dev/null 2>&1 || return 1
    else
        return 1
    fi
}
install_deps() {
    log INFO '检查依赖……'
    if deps_ready; then
        log INFO '依赖已齐全，跳过软件源更新和安装。'
        manager >/dev/null || die '未检测到运行中的 systemd/OpenRC。'
        return 0
    fi
    log INFO '安装缺少的依赖（全程非交互）……'
    if [ -f /etc/alpine-release ]; then
        command -v apk >/dev/null 2>&1 || die '未找到 apk。'
        package_step apk update || die 'apk 软件源更新失败；请检查源、网络和系统时间。'
        package_step apk add curl jq ca-certificates openrc busybox || die 'Alpine 依赖安装失败。'
        if ! command -v flock >/dev/null 2>&1; then
            # Modern Alpine has a standalone flock package; old versions use util-linux.
            package_step apk add flock || package_step apk add util-linux || die '无法安装 flock。'
        fi
        if [ ! -x /etc/init.d/crond ]; then
            package_step apk add busybox-initscripts || die '缺少 crond 服务，无法安装 busybox-initscripts。'
        fi
        case "$(cat /etc/alpine-release)" in
            3.2.*) log WARN '检测到旧版 Alpine 3.2.x；软件源、CA/TLS 可用性需实机确认。';;
        esac
    elif [ -f /etc/debian_version ]; then
        command -v apt-get >/dev/null 2>&1 || die '未找到 apt-get。'
        # Package operations occur only during install/repair, never every DDNS cycle.
        package_step apt-get -o Acquire::Retries=3 update || die 'apt 软件源更新失败。'
        package_step env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get \
          -o DPkg::Lock::Timeout=120 -o Acquire::Retries=3 -o Dpkg::Options::=--force-confold \
          install -y curl jq ca-certificates util-linux coreutils cron || die 'Debian 依赖安装失败。'
    else
        die '本安装器支持 Debian 和 Alpine。'
    fi
    package_step update-ca-certificates || die 'CA 证书更新失败。'
    runtime_deps
    for cmd in logger crontab; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖 $cmd。"
    done
    if [ -f /etc/alpine-release ]; then
        for cmd in rc-service rc-update start-stop-daemon crond; do
            command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖 $cmd。"
        done
    fi
    manager >/dev/null || die '未检测到运行中的 systemd/OpenRC；裸容器不能直接使用此开机服务方案。'
}

load_config() {
    [ -r "$CONF" ] || die "未找到配置 $CONF，请先运行 --install。"
    # Select one object only. Malformed/multiple JSON values cannot silently pass.
    jq -e -s 'length == 1 and (.[0] | type == "object")' "$CONF" >/dev/null 2>&1 || die '配置必须是一个 JSON 对象。'
    jq -e '
      (.token | type == "string") and (.zone_id | type == "string") and
      (.record_name | type == "string") and
      (.interval | type == "number") and (.interval == (.interval|floor)) and
      (.interval >= 30 and .interval <= 86400) and
      (.ttl | type == "number") and (.ttl == (.ttl|floor)) and
      (.ttl == 1 or (.ttl >= 60 and .ttl <= 86400)) and
      (.proxied | type == "boolean") and (.cleanup_duplicates | type == "boolean")
    ' "$CONF" >/dev/null 2>&1 || die '配置字段无效：interval 至少 30 秒；ttl 为 1 或 60–86400；开关必须为布尔值。'
    TOKEN=$(jq -r .token "$CONF")
    ZONE=$(jq -r .zone_id "$CONF")
    NAME=$(jq -r .record_name "$CONF" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')
    INTERVAL=$(jq -r .interval "$CONF")
    TTL=$(jq -r .ttl "$CONF")
    PROXIED=$(jq -r .proxied "$CONF")
    CLEAN_DUP=$(jq -r .cleanup_duplicates "$CONF")
    case "$TOKEN" in ''|*[!A-Za-z0-9_-]*) die 'Token 格式无效，请填写 API Token，而不是 Global API Key。';; esac
    [ "${#TOKEN}" -ge 10 ] && [ "${#TOKEN}" -le 256 ] || die 'Token 长度无效。'
    case "$ZONE" in *[!A-Fa-f0-9]*|'') die 'Zone ID 必须是 32 位十六进制字符串。';; esac
    [ "${#ZONE}" = 32 ] || die 'Zone ID 长度不是 32。'
    [ "${#NAME}" -le 253 ] || die '完整记录域名长度不能超过 253。'
    # A wildcard is exactly the first label, e.g. *.example.com or *.sub.example.com.
    # Keep NAME intact for JSON and exact-match filtering; validate its suffix only.
    case "$NAME" in
        \*.*) base_name=${NAME#\*.};;
        *) base_name=$NAME;;
    esac
    printf '%s\n' "$base_name" | awk '
      NR!=1 || length($0)>253 || index($0,".")==0 {exit 1}
      {n=split($0,a,"."); for(i=1;i<=n;i++) {
        if(length(a[i])<1 || length(a[i])>63 || a[i] !~ /^[a-z0-9-]+$/ ||
           substr(a[i],1,1)=="-" || substr(a[i],length(a[i]),1)=="-") exit 1
      }}' || die '域名格式无效；支持完整域名及 *.example.com，* 只能作为最左侧独立标签；国际化域名使用 Punycode。'
    QUERY_NAME=$(jq -rn --arg n "$NAME" '$n | @uri') || die '域名查询参数编码失败。'
    if [ "$PROXIED" = true ] && [ "$TTL" != 1 ]; then
        TTL=1 # Cloudflare proxied records use automatic TTL.
    fi
}

write_config() {
    if [ "$#" = 3 ]; then
        token_in=$1; zone_in=$2; name_in=$3
    else
        die '需要三个非空参数：TOKEN ZONE_ID 完整域名；不会进行交互输入。'
    fi
    tmp_conf=$(mktemp /etc/cf-ddns.json.XXXXXX) || die '无法创建配置临时文件。'
    # Preserve tuning fields on repeated installations; replace the three credentials.
    if [ -f "$CONF" ]; then
        jq --arg t "$token_in" --arg z "$zone_in" --arg n "$name_in" \
          '. + {token:$t,zone_id:$z,record_name:$n}' "$CONF" >"$tmp_conf" || { rm -f "$tmp_conf"; die '现有 JSON 配置损坏，请先修复。'; }
    else
        jq -n --arg t "$token_in" --arg z "$zone_in" --arg n "$name_in" \
          '{token:$t,zone_id:$z,record_name:$n,interval:60,ttl:60,proxied:false,cleanup_duplicates:true}' >"$tmp_conf" || die '生成配置失败。'
    fi
    saved_conf=$CONF; CONF=$tmp_conf
    # Validate in a subprocess before replacing the good configuration.
    if ! (load_config); then
        CONF=$saved_conf; rm -f "$tmp_conf"; die '新配置未保存，请检查输入。'
    fi
    CONF=$saved_conf
    chmod 600 "$tmp_conf" && mv -f "$tmp_conf" "$CONF" || die '保存配置失败。'
    unset token_in
    log INFO "配置已保存：$CONF（权限 600）"
}

valid_ipv4() {
    printf '%s\n' "$1" | awk -F. '
      NR!=1 || NF!=4 {exit 1}
      {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || length($i)>3 || $i+0>255 ||
         (length($i)>1 && substr($i,1,1)=="0")) exit 1;
       if($1==0 || $1==10 || $1==127 || $1>=224 ||
         ($1==169 && $2==254) || ($1==172 && $2>=16 && $2<=31) ||
         ($1==192 && $2==168) || ($1==100 && $2>=64 && $2<=127) ||
         ($1==192 && $2==0 && ($3==0 || $3==2)) ||
         ($1==198 && ($2==18 || $2==19 || ($2==51 && $3==100))) ||
         ($1==203 && $2==0 && $3==113)) exit 1}'
}
public_ipv4() {
    for endpoint in https://www.cloudflare.com/cdn-cgi/trace https://api.ipify.org https://ipv4.icanhazip.com; do
        if answer=$(curl -q -4 --noproxy '*' -fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>"$WORK/ip-error"); then
            case "$endpoint" in
                *cdn-cgi/trace) candidate=$(printf '%s\n' "$answer" | sed -n 's/^ip=//p' | tr -d '\r');;
                *) candidate=$(printf '%s' "$answer" | tr -d '\r\n');;
            esac
            if valid_ipv4 "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
        fi
    done
    log ERROR '所有公网 IPv4 检测源均失败或返回无效地址；保留现有 DNS，下一轮重试。'
    return 1
}

# API response lives at $WORK/response. Never retry a mutation blindly.
cf_api() {
    method=$1; route=$2; body=${3:-}
    set -- -q -4 --noproxy '*' -sS --connect-timeout 5 --max-time 20 \
      --config "$WORK/auth" -X "$method" -o "$WORK/response" -w '%{http_code}'
    [ -z "$body" ] || set -- "$@" --data-binary "@$body"
    if ! code=$(curl "$@" "$API$route" 2>"$WORK/api-error"); then
        log ERROR "Cloudflare $method 网络失败/超时；下轮先重新查询，不盲目重试写入。"
        return 1
    fi
    case "$code" in 2??) :;; *)
        # Do not print full remote data or credentials.
        errors=$(jq -r '.errors[]? | ((.code|tostring) + ": " + .message)' "$WORK/response" 2>/dev/null | head -n 3)
        log ERROR "Cloudflare $method HTTP $code ${errors:-响应未提供可解析错误}"
        return 1;;
    esac
    if ! jq -e '.success == true' "$WORK/response" >/dev/null 2>&1; then
        errors=$(jq -r '.errors[]? | ((.code|tostring) + ": " + .message)' "$WORK/response" 2>/dev/null | head -n 3)
        log ERROR "Cloudflare $method API 未成功：${errors:-非 JSON 或 success 不为 true}"
        return 1
    fi
}
list_records() {
    cf_api GET "/zones/$ZONE/dns_records?type=A&name.exact=$QUERY_NAME&match=all&per_page=100&page=1" || return 1
    jq -e '(.result|type)=="array" and ((.result_info.total_pages // 1)<=1)' "$WORK/response" >/dev/null || {
        log ERROR '记录列表无效或超过一页；停止修改，避免遗漏/误删。'; return 1;
    }
    # Also filter exact type/name locally; use only result[].id.
    jq --arg n "$NAME" '[.result[] | select(.type=="A" and .name==$n)]' "$WORK/response" >"$WORK/records" || return 1
}
result_matches() {
    jq -e --arg n "$NAME" --arg ip "$IP" --arg t "$TTL" --arg p "$PROXIED" \
      '.result.type=="A" and .result.name==$n and .result.content==$ip and .result.ttl==($t|tonumber) and .result.proxied==($p=="true")' \
      "$WORK/response" >/dev/null 2>&1
}
sync_once() {
    quiet=${1:-no}
    runtime_deps
    dirs
    exec 8>"$RUN/update.lock"
    if [ "$quiet" != yes ]; then
        # BusyBox flock does not consistently support util-linux's -w option.
        lock_wait=0
        until flock -n 8; do
            [ "$lock_wait" -lt 120 ] || { log ERROR '等待更新锁超时。'; return 1; }
            sleep 1
            lock_wait=$((lock_wait + 1))
        done
    elif ! flock -n 8; then
        [ "$quiet" = yes ] || log INFO '已有更新任务运行，本次跳过。'
        return 0
    fi
    load_config
    WORK=$(mktemp -d "$RUN/work.XXXXXX") || die '无法创建工作目录。'
    printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$TOKEN" >"$WORK/auth"
    IP=$(public_ipv4) || return 1
    list_records || return 1
    count=$(jq length "$WORK/records")
    if [ "$count" -gt 1 ] && [ "$CLEAN_DUP" != true ]; then
        log ERROR "发现 $count 条同名 A 记录；cleanup_duplicates=false，已停止修改。"
        return 1
    fi
    jq -n --arg n "$NAME" --arg ip "$IP" --arg t "$TTL" --arg p "$PROXIED" \
      '{type:"A",name:$n,content:$ip,ttl:($t|tonumber),proxied:($p=="true")}' >"$WORK/body" || return 1
    action=无需修改
    if [ "$count" = 0 ]; then
        cf_api POST "/zones/$ZONE/dns_records" "$WORK/body" || return 1
        result_matches || { log ERROR '创建返回的记录与预期不符，稍后重新核对。'; return 1; }
        action=已创建
    else
        # Stable choice across runs, independent of API order.
        jq 'sort_by(.id)' "$WORK/records" >"$WORK/sorted" || return 1
        record_id=$(jq -r '.[0].id' "$WORK/sorted")
        case "$record_id" in ''|*[!A-Fa-f0-9]*) log ERROR 'Cloudflare 返回无效记录 ID。'; return 1;; esac
        [ "${#record_id}" = 32 ] || return 1
        if ! jq -e --arg ip "$IP" --arg t "$TTL" --arg p "$PROXIED" \
          '.[0].content==$ip and .[0].ttl==($t|tonumber) and .[0].proxied==($p=="true")' "$WORK/sorted" >/dev/null; then
            # PATCH preserves unrelated comment/tags/metadata.
            cf_api PATCH "/zones/$ZONE/dns_records/$record_id" "$WORK/body" || return 1
            result_matches || { log ERROR '更新响应与预期不符，停止清理重复记录。'; return 1; }
            action=已更新
        fi
        if [ "$count" -gt 1 ]; then
            jq -r '.[1:][].id' "$WORK/sorted" >"$WORK/extras"
            while IFS= read -r extra_id; do
                case "$extra_id" in ''|*[!A-Fa-f0-9]*) return 1;; esac
                [ "${#extra_id}" = 32 ] || return 1
                cf_api DELETE "/zones/$ZONE/dns_records/$extra_id" || return 1
                log WARN "已删除指定域名 $NAME 的重复 A 记录：$extra_id"
            done <"$WORK/extras"
        fi
    fi
    # Re-read after ANY mutation. Also catches a concurrent external writer.
    if [ "$action" != 无需修改 ] || [ "$count" -gt 1 ]; then
        list_records || return 1
        jq -e --arg ip "$IP" --arg t "$TTL" --arg p "$PROXIED" \
          'length==1 and .[0].content==$ip and .[0].ttl==($t|tonumber) and .[0].proxied==($p=="true")' "$WORK/records" >/dev/null || {
            log ERROR '写入后的核对失败：未形成唯一且正确的 A 记录；下一轮重试。'; return 1;
        }
    fi
    # State is informational only: never skip Cloudflare based on a cached IP.
    jq -n --arg ip "$IP" --arg n "$NAME" --arg at "$(date '+%Y-%m-%d %H:%M:%S%z')" \
      '{record_name:$n,ipv4:$ip,last_success:$at}' >"$WORK/state" && \
      mv -f "$WORK/state" "$STATE/status.json" || return 1
    if [ "$quiet" != yes ] || [ "$action" != 无需修改 ] || [ "$count" -gt 1 ]; then
        log INFO "$action：$NAME → $IP；TTL=$TTL，代理=$PROXIED，A 记录数=1。"
    fi
}

stop_child() {
    if [ -n "$CHILD" ]; then
        kill -TERM "$CHILD" 2>/dev/null || :
        wait "$CHILD" 2>/dev/null || :
    fi
    exit 0
}
daemon_loop() {
    runtime_deps; dirs
    exec 9>"$RUN/daemon.lock"
    flock -n 9 || { log INFO '常驻进程已存在，本次退出。'; exit 0; }
    trap stop_child TERM INT HUP
    load_config
    log INFO "常驻进程启动：$NAME，每轮完成后等待 $INTERVAL 秒。"
    while :; do
        "$SELF" --run 9>&- & CHILD=$!
        wait "$CHILD" || :
        CHILD=
        # Read updated interval; bad config exits and supervisor restarts after delay.
        load_config
        sleep "$INTERVAL" 9>&- & CHILD=$!
        wait "$CHILD" || :
        CHILD=
    done
}
legacy_supervisor() {
    runtime_deps; dirs
    exec 7>"$RUN/supervisor.lock"
    flock -n 7 || exit 0
    trap stop_child TERM INT HUP
    while :; do
        "$SELF" --daemon 7>&- & CHILD=$!
        wait "$CHILD" || :
        CHILD=
        log WARN '常驻进程退出，5 秒后重新启动。'
        sleep 5 7>&- & CHILD=$!
        wait "$CHILD" || :
        CHILD=
    done
}
watchdog() {
    runtime_deps; dirs
    exec 6>"$RUN/install.lock"
    flock -n 6 || exit 0 # Installation may be replacing config/service atomically.
    exec 5>"$RUN/watchdog.lock"
    flock -n 5 || exit 0
    exec 4>"$RUN/daemon.lock"
    if flock -n 4; then
        flock -u 4
        log WARN '定时巡检：常驻进程未运行，尝试恢复服务。'
        case "$(manager)" in
            systemd) systemctl start cf-ddns.service || log ERROR '服务恢复失败。';;
            openrc)
                if ! rc-service cf-ddns restart; then
                    # A killed OpenRC supervisor can leave stale service state.
                    if flock -n 4; then
                        flock -u 4
                        rc-service cf-ddns zap && rc-service cf-ddns start || log ERROR '服务恢复失败。'
                    else
                        log WARN '服务重启返回失败，但常驻进程已运行；保留该进程。'
                    fi
                fi;;
            *) log ERROR '服务管理器不可用。';;
        esac
    fi
    # Cron provides a second execution path; update.lock serializes both paths.
    "$SELF" --run 4>&- 5>&- 6>&-
}

install_service() {
    mgr=$(manager) || die '没有运行中的服务管理器。'
    if [ "$mgr" = systemd ]; then
        cat >"$WORK/cf-ddns.service" <<'UNIT'
[Unit]
Description=Cloudflare IPv4 DDNS
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/lib/cf-ddns/runner.sh --daemon
Restart=always
RestartSec=5
TimeoutStopSec=45
KillMode=control-group
UMask=0077
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
        chmod 644 "$WORK/cf-ddns.service"
        mv -f "$WORK/cf-ddns.service" /etc/systemd/system/cf-ddns.service || die '安装 systemd 服务失败。'
        systemctl daemon-reload && systemctl enable cf-ddns.service && systemctl restart cf-ddns.service || die '启动 systemd 服务失败。'
        cat >"$WORK/cron" <<'CRON'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root /usr/local/lib/cf-ddns/runner.sh --watchdog >/dev/null 2>&1
CRON
        chmod 644 "$WORK/cron"
        mkdir -p /etc/cron.d
        mv -f "$WORK/cron" /etc/cron.d/cf-ddns || die '安装 Cron 失败。'
        systemctl enable --now cron.service || die '启用 cron 失败。'
    else
        interpreter=/sbin/openrc-run
        [ -x "$interpreter" ] || interpreter=/sbin/runscript
        [ -x "$interpreter" ] || die '未找到 OpenRC 服务脚本解释器。'
        printf '#!%s\n' "$interpreter" >"$WORK/service"
        if command -v supervise-daemon >/dev/null 2>&1; then
            cat >>"$WORK/service" <<'RC'
description="Cloudflare IPv4 DDNS"
supervisor="supervise-daemon"
command="/usr/local/lib/cf-ddns/runner.sh"
command_args="--daemon"
pidfile="/var/run/cf-ddns-supervisor.pid"
respawn_delay=5
respawn_max=0
retry="TERM/45/KILL/5"
depend() { need net; use dns logger; }
RC
        else
            cat >>"$WORK/service" <<'RC'
description="Cloudflare IPv4 DDNS (legacy OpenRC)"
command="/usr/local/lib/cf-ddns/runner.sh"
command_args="--supervise"
command_background=true
pidfile="/var/run/cf-ddns-supervisor.pid"
retry="TERM/45/KILL/5"
depend() { need net; use dns logger; }
RC
        fi
        chmod 755 "$WORK/service"
        mv -f "$WORK/service" /etc/init.d/cf-ddns || die '安装 OpenRC 服务失败。'
        rc-update add cf-ddns default && rc-service cf-ddns restart || die '启动 OpenRC 服务失败。'
        # BusyBox crond reads root's crontab, not Debian's /etc/cron.d format.
        crontab -l >"$WORK/old-cron" 2>/dev/null || :
        awk 'index($0,"# cf-ddns-managed")==0' "$WORK/old-cron" >"$WORK/cron"
        printf '%s\n' '* * * * * /usr/local/lib/cf-ddns/runner.sh --watchdog >/dev/null 2>&1 # cf-ddns-managed' >>"$WORK/cron"
        crontab "$WORK/cron" || die '写入 root crontab 失败。'
        # Remove the exact legacy cron.d artifact from the supplied original script.
        rm -f /etc/cron.d/cf-ddns
        rc-update add crond default && rc-service crond start || die '启动 crond 失败。'
    fi
    log INFO '已注册开机启动、进程守护和每分钟定时巡检；重复安装覆盖同一份服务/任务。'
}
install_main() {
    dirs
    log INFO "cf-ddns $VERSION：自动安装/修复。"
    # mkdir is a bootstrap lock because flock may not yet be installed.
    if ! mkdir "$RUN/bootstrap-install" 2>/dev/null; then
        die "已有安装正在运行；若上次被强制断电，请确认无安装进程后删除 $RUN/bootstrap-install。"
    fi
    trap 'cleanup; rmdir "$RUN/bootstrap-install" 2>/dev/null || :' EXIT
    install_deps
    exec 6>"$RUN/install.lock"
    flock -x 6 || die '获取安装锁失败。'
    exec 8>"$RUN/update.lock"
    flock -x 8 || die '获取更新锁失败。'
    WORK=$(mktemp -d "$RUN/install.XXXXXX") || die '创建安装目录失败。'
    if [ "$#" -gt 0 ] || [ ! -f "$CONF" ]; then write_config "$@"; fi
    load_config
    [ -f "$0" ] || die '请保存为文件后运行，不支持 curl | sh。'
    mkdir -p /usr/local/lib/cf-ddns || die '创建常驻程序目录失败。'
    tmp_self=$(mktemp /usr/local/lib/cf-ddns/runner.sh.XXXXXX) || die '无法创建脚本临时文件。'
    cp "$0" "$tmp_self" && chmod 755 "$tmp_self" && mv -f "$tmp_self" "$SELF" || die '安装脚本失败。'
    # Release update lock before restarting. Child services must not inherit installer locks.
    flock -u 8
    install_service 6>&- 8>&-
    log INFO '执行首次 DNS 同步……'
    if ! "$SELF" --once 6>&- 8>&-; then
        log WARN '首次同步尚未成功；服务和定时任务已安装，将继续重试。请查看日志。'
        return 1
    fi
    log INFO "安装完成。查看状态：$SELF --status；修改参数：$ENTRY TOKEN ZONE_ID 域名"
}
show_status() {
    printf '脚本：%s\n配置：%s\n' "$SELF" "$CONF"
    if [ -f "$CONF" ]; then
        load_config
        printf '域名：%s\n间隔：%s 秒（每轮完成后）\nTTL：%s\nCloudflare 代理：%s\n清理同名重复 A：%s\n' "$NAME" "$INTERVAL" "$TTL" "$PROXIED" "$CLEAN_DUP"
    fi
    case "$(manager)" in
        systemd) systemctl --no-pager --full status cf-ddns.service || :; printf '\n定时任务：\n'; cat /etc/cron.d/cf-ddns 2>/dev/null || :;;
        openrc) rc-service cf-ddns status || :; printf '\n定时任务：\n'; crontab -l 2>/dev/null | grep '# cf-ddns-managed' || :;;
        *) printf '未检测到运行中的服务管理器。\n';;
    esac
    if [ -f "$STATE/status.json" ]; then
        printf '\n最近一次成功核对（不是实时状态）：\n'
        jq -r '"域名：\(.record_name)\nIPv4：\(.ipv4)\n时间：\(.last_success)"' "$STATE/status.json"
    fi
}
usage() {
    cat <<'HELP'
用法（root）：
  /usr/local/bin/cf-ddns.sh TOKEN ZONE_ID FQDN  自动安装/修复、保存参数、立即同步
  /usr/local/bin/cf-ddns.sh                    使用已保存配置同步一次
  /usr/local/bin/cf-ddns.sh --install TOKEN ZONE_ID FQDN  同上（可选显式入口）
  /usr/local/bin/cf-ddns.sh --configure TOKEN ZONE_ID FQDN  替换参数并重启
  /usr/local/bin/cf-ddns.sh --once              立即同步一次，显示结果
  /usr/local/bin/cf-ddns.sh --status            查看配置、服务、定时任务及上次成功状态
  /usr/local/bin/cf-ddns.sh --logs              查看日志
  /usr/local/bin/cf-ddns.sh --version           查看脚本版本

仅管理指定完整域名的 A 记录。默认 DNS only、TTL=60、间隔=60 秒。
支持泛域名，例如 *.example.com、*.sub.example.com；参数请加引号。
默认清理该域名重复 A 记录；其它域名、AAAA/MX/TXT 等不处理。
凭据存于 /etc/cf-ddns.json（600），不会执行配置里的 shell 代码。
HELP
}
case "${1:---default}" in
    --help|-h) usage;;
    --version) printf '%s\n' "$VERSION";;
    --install) shift; root_check; [ "$#" = 0 ] || [ "$#" = 3 ] || die '安装需要 0 或 3 个参数。'; install_main "$@";;
    --configure) shift; root_check; [ "$#" = 3 ] || die '修改配置需要三个参数。'; runtime_deps; dirs
        exec 6>"$RUN/install.lock"; flock -x 6
        exec 8>"$RUN/update.lock"; flock -x 8
        write_config "$@"; flock -u 8
        case "$(manager)" in systemd) systemctl restart cf-ddns.service 6>&- 8>&-;; openrc) rc-service cf-ddns restart 6>&- 8>&-;; *) die '服务管理器不可用。';; esac
        "$SELF" --once 6>&- 8>&-;;
    --once) root_check; sync_once no;;
    --run) root_check; sync_once yes;;
    --daemon) root_check; daemon_loop;;
    --supervise) root_check; legacy_supervisor;;
    --watchdog) root_check; watchdog;;
    --status) root_check; runtime_deps; show_status;;
    --logs) root_check
        [ -f "$LOG" ] && tail -n 100 "$LOG" || die '尚未生成日志。';;
    --default) root_check; sync_once no;;
    *) root_check; [ "$#" = 3 ] || die '需要 TOKEN ZONE_ID 完整域名三个参数；使用 --help 查看用法。'; install_main "$@";;
esac
