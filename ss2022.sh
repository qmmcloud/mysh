#!/bin/sh
#=============================================================================
# Shadowsocks-2022 (Rust) Management Script for Alpine Linux
# Architecture: musl-libc / OpenRC (supervise-daemon)
# Idempotent: Safe to re-run, no duplicate configs, auto-supervising process
#=============================================================================
set -e

# ANSI 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
PLAIN="\033[0m"

REPO="shadowsocks/shadowsocks-rust"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"
INIT_FILE="/etc/init.d/shadowsocks-rust"
BIN_FILE="/usr/local/bin/ssserver"
PID_FILE="/run/shadowsocks-rust.pid"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}[ERROR] 必须使用 root 用户权限运行此脚本！${PLAIN}" >&2
        exit 1
    fi
}

check_os() {
    if [ ! -f /etc/alpine-release ]; then
        echo -e "${RED}[ERROR] 当前系统非 Alpine Linux，此脚本基于 musl 与 OpenRC 深度构建，终止执行。${PLAIN}" >&2
        exit 1
    fi
}

install_deps() {
    local missing_pkgs=""
    for pkg in curl jq tar openssl; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            missing_pkgs="$missing_pkgs $pkg"
        fi
    done

    if [ -n "$missing_pkgs" ]; then
        echo -e "${CYAN}[INFO] 正在补全核心依赖:${missing_pkgs}...${PLAIN}"
        apk update >/dev/null 2>&1
        apk add --no-cache $missing_pkgs >/dev/null 2>&1
    fi
}

get_target_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64) echo "aarch64-unknown-linux-musl" ;;
        armv7l)  echo "armv7-unknown-linux-musleabihf" ;;
        *) echo "";;
    esac
}

generate_psk() {
    local method="$1"
    if [ "$method" = "2022-blake3-aes-128-gcm" ]; then
        openssl rand -base64 16
    else
        openssl rand -base64 32
    fi
}

get_public_ip() {
    local ip
    ip=$(curl -s4m 3 https://api.ipify.org || curl -s4m 3 https://ifconfig.me || echo "YOUR_SERVER_IP")
    echo "$ip"
}

# 部署 OpenRC supervise-daemon 守护服务
write_openrc_service() {
    cat <<'EOF_RC' > "$INIT_FILE"
#!/sbin/openrc-run
# Distributed under the terms of the Apache-2.0 License

name="Shadowsocks-Rust SS2022"
description="High-performance Shadowsocks-Rust supervised by OpenRC"

# 使用 supervise-daemon 替代 command_background，原生支持进程崩溃自动拉起
supervisor="supervise-daemon"
command="/usr/local/bin/ssserver"
command_args="-c /etc/shadowsocks-rust/config.json"
respawn_delay=5
respawn_max=10

pidfile="/run/shadowsocks-rust.pid"

depend() {
    need net
    after firewall
}
EOF_RC
    chmod 755 "$INIT_FILE"
}

# 二进制拉取（带幂等性检查，相同版本不重复下载）
deploy_binary() {
    local target="$1"
    local tag
    tag=$(curl -sSL "https://api.github.com/repos/${REPO}/releases/latest" | jq -r .tag_name)
    [ -z "$tag" ] || [ "$tag" = "null" ] && tag="v1.22.0" # 降级默认版本

    if [ -x "$BIN_FILE" ]; then
        local current_ver
        current_ver=$("$BIN_FILE" --version 2>&1 | awk '{print $2}' || echo "")
        if [ "v${current_ver}" = "$tag" ] || [ "${current_ver}" = "$tag" ]; then
            echo -e "${GREEN}[OK] 已存在最新版本 shadowsocks-rust (${tag})，跳过二进制拉取。${PLAIN}"
            return 0
        fi
        echo -e "${CYAN}[INFO] 检测到新版本: 本地(${current_ver}) -> 最新(${tag})，执行二进制热替换...${PLAIN}"
    fi

    local download_url="https://github.com/${REPO}/releases/download/${tag}/shadowsocks-${tag}.${target}.tar.xz"
    echo -e "${CYAN}[INFO] 正在下载静态 musl 二进制包: ${download_url}...${PLAIN}"
    
    mkdir -p /usr/local/bin
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if curl -sSL "$download_url" | tar -xJ -C "$tmp_dir"; then
        mv "${tmp_dir}/ssserver" "$BIN_FILE"
        chmod +x "$BIN_FILE"
        rm -rf "$tmp_dir"
        echo -e "${GREEN}[OK] 二进制更新部署成功。${PLAIN}"
    else
        rm -rf "$tmp_dir"
        echo -e "${RED}[ERROR] 二进制下载/解压失败，请检查网络栈连接。${PLAIN}" >&2
        return 1
    fi
}

install_action() {
    install_deps
    local target
    target=$(get_target_arch)
    if [ -z "$target" ]; then
        echo -e "${RED}[ERROR] 暂不支持当前设备架构: $(uname -m)${PLAIN}" >&2
        exit 1
    fi

    deploy_binary "$target"

    mkdir -p "$CONFIG_DIR"
    local port method pass

    # 幂等处理：如果已有配置，直接读取并询问是否保留
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "\n${YELLOW}[!] 检测到已存在运行配置：${PLAIN}"
        port=$(jq -r '.server_port // 8388' "$CONFIG_FILE")
        method=$(jq -r '.method // "2022-blake3-aes-128-gcm"' "$CONFIG_FILE")
        pass=$(jq -r '.password // ""' "$CONFIG_FILE")
        echo -e "当前端口: ${GREEN}${port}${PLAIN} | 加密: ${GREEN}${method}${PLAIN}"
        printf "是否覆盖并重新生成配置？[y/N]: "
        read -r reconfig
        if [ "$reconfig" != "y" ] && [ "$reconfig" != "Y" ]; then
            echo -e "${GREEN}[OK] 保持原有配置不变。${PLAIN}"
            write_openrc_service
            rc-update add shadowsocks-rust default >/dev/null 2>&1 || true
            rc-service shadowsocks-rust restart
            show_config_action
            return 0
        fi
    fi

    # 交互式参数输入
    echo -e "\n${YELLOW}--- 基础参数配置 ---${PLAIN}"
    printf "请输入监听端口 [默认: 8388]: "
    read -r in_port
    port=${in_port:-8388}

    echo -e "\n请选择加密协议 (SS-2022):"
    echo "1) 2022-blake3-aes-128-gcm (推荐: 16-byte Key，低开销)"
    echo "2) 2022-blake3-aes-256-gcm (高强度: 32-byte Key)"
    printf "请选择 [1-2, 默认: 1]: "
    read -r m_choice
    case "$m_choice" in
        2) method="2022-blake3-aes-256-gcm" ;;
        *) method="2022-blake3-aes-128-gcm" ;;
    esac

    printf "是否自定义 Key？(留空则系统自动随机生成) [y/N]: "
    read -r cust_key
    if [ "$cust_key" = "y" ] || [ "$cust_key" = "Y" ]; then
        printf "请输入 Base64 编码的 Key: "
        read -r pass
    else
        pass=$(generate_psk "$method")
    fi

    # 写入生产级配置
    cat <<EOF > "$CONFIG_FILE"
{
    "server": "::",
    "server_port": ${port},
    "method": "${method}",
    "password": "${pass}",
    "mode": "tcp_and_udp",
    "fast_open": true,
    "tcp_congestion_control": "bbr"
}
EOF

    # 注册系统服务并启动守护
    write_openrc_service
    rc-update add shadowsocks-rust default >/dev/null 2>&1 || true
    rc-service shadowsocks-rust restart

    echo -e "\n${GREEN}[OK] Shadowsocks-Rust SS2022 部署成功并已进入系统守护状态！${PLAIN}"
    show_config_action
}

show_config_action() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}[ERROR] 配置文件不存在，请先执行安装！${PLAIN}"
        return 1
    fi

    local port method pass ip b64_auth ss_link
    port=$(jq -r '.server_port' "$CONFIG_FILE")
    method=$(jq -r '.method' "$CONFIG_FILE")
    pass=$(jq -r '.password' "$CONFIG_FILE")
    ip=$(get_public_ip)

    b64_auth=$(printf "%s:%s" "$method" "$pass" | openssl base64 -A)
    ss_link="ss://${b64_auth}@${ip}:${port}#SS2022-Alpine"

    echo -e "\n================ Shadowsocks 2022 节点信息 ================"
    echo -e "主机地址 (Address) : ${CYAN}${ip}${PLAIN}"
    echo -e "服务端口 (Port)    : ${CYAN}${port}${PLAIN}"
    echo -e "加密方式 (Method)  : ${CYAN}${method}${PLAIN}"
    echo -e "预共享钥 (Password): ${CYAN}${pass}${PLAIN}"
    echo -e "-----------------------------------------------------------"
    echo -e "标准 URI 分享链接  : \n${YELLOW}${ss_link}${PLAIN}"
    echo -e "==========================================================="
}

service_action() {
    local action="$1"
    case "$action" in
        restart)
            rc-service shadowsocks-rust restart
            echo -e "${GREEN}[OK] 服务已重启${PLAIN}"
            ;;
        stop)
            rc-service shadowsocks-rust stop
            echo -e "${YELLOW}[OK] 服务已停止${PLAIN}"
            ;;
        status)
            rc-service shadowsocks-rust status
            ;;
    esac
}

uninstall_action() {
    printf "${RED}[WARN] 确认彻底卸载 SS-2022 及其相关守护配置？[y/N]: ${PLAIN}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        rc-service shadowsocks-rust stop >/dev/null 2>&1 || true
        rc-update del shadowsocks-rust default >/dev/null 2>&1 || true
        rm -f "$INIT_FILE" "$BIN_FILE" "$PID_FILE"
        rm -rf "$CONFIG_DIR"
        echo -e "${GREEN}[OK] 卸载完成，所有相关组件及持久化数据已清理干净。${PLAIN}"
    else
        echo -e "${CYAN}[INFO] 操作已取消。${PLAIN}"
    fi
}

main_menu() {
    check_root
    check_os
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${GREEN}      Alpine SS2022 管理脚手架 (Supervised OpenRC)    ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo "1) 安装 / 升级 Shadowsocks-Rust (幂等安全)"
    echo "2) 查看当前节点连接参数与 URI 链接"
    echo "3) 重启服务"
    echo "4) 停止服务"
    echo "5) 检查运行状态 (查看 supervisor 状态)"
    echo "6) 彻底卸载"
    echo "0) 退出"
    echo -e "${CYAN}====================================================${PLAIN}"
    printf "请输入指令编号 [0-6]: "
    read -r choice

    case "$choice" in
        1) install_action ;;
        2) show_config_action ;;
        3) service_action restart ;;
        4) service_action stop ;;
        5) service_action status ;;
        6) uninstall_action ;;
        0) exit 0 ;;
        *) echo -e "${RED}[ERROR] 输入无效${PLAIN}" ;;
    esac
}

main_menu
