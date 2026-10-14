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

仅管理指定完整域名的 A 记录。默认 DNS only、TTL=60、间隔=60 秒。
默认清理该域名重复 A 记录；其它域名、AAAA/MX/TXT 等不处理。
凭据存于 /etc/cf-ddns.json（600），不会执行配置里的 shell 代码。
HELP
}
case "${1:---default}" in
    --help|-h) usage;;
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
