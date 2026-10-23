#!/usr/bin/env bash
# ==============================================================================
# Simple-Box Manager - 极简、安全、透明的自用 sing-box 服务端管理脚本
# 协议支持: 
#   1. VLESS-TCP-Reality-Vision (日常主力直连)
#   2. Hysteria 2 (晚高峰弱网/UDP端口跳跃, 支持 Cloudflare 证书或自签证书)
# 证书管理:
#   集成 Caddy 提供 HTTPS 订阅地址，输出完整规则模板订阅、纯节点订阅、URI 与二维码
# 维护约定:
#   二次开发或修改脚本前请务必阅读 MAINTAINING.md，遵循权限收紧与安全变更规范
# ==============================================================================
set -e

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
PLAIN=$'\033[0m'
GRAY=$'\033[0;90m'
BOLD=$'\033[1m'

CONF_DIR="/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"
CERT_DIR="${CONF_DIR}/cert"
WEB_DIR="${CONF_DIR}/web"
ENV_FILE="${CONF_DIR}/env.conf"
LINKS_FILE="${CONF_DIR}/links.txt"
TEMPLATE_FILE="${CONF_DIR}/template.yaml"

SCRIPT_URL="https://raw.githubusercontent.com/comegome/Simple-Box/main/simple-box.sh"

# 管道执行（curl ... | bash）不受支持，且必须在此处就拦下：
# bash 从 stdin 读取脚本正文，脚本里的 read 会与 bash 抢同一条流，
# 用户看到的每个提问都会把脚本剩余代码当成答案吃掉，结果是静默错乱而非报错。
# 检测依据：BASH_SOURCE[0] 为空 且 stdin 不是终端。
if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    cat >/dev/null 2>&1 || true   # 抽干管道，让外层 curl 正常结束（否则 curl: (23)）
    echo -e "${RED}不支持管道执行（curl ... | bash）。${PLAIN}"
    echo -e "${YELLOW}原因: bash 从 stdin 读取脚本，脚本内的交互提问会与脚本正文抢同一条输入流。${PLAIN}"
    echo -e "${YELLOW}请先下载再运行：${PLAIN}"
    echo -e "  curl -fsSL ${SCRIPT_URL} -o /tmp/simple-box.sh && sudo bash /tmp/simple-box.sh"
    exit 1
fi

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本！${PLAIN}" && exit 1

get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) return 1 ;;
    esac
}

# 架构校验（供需要中止流程处调用，避免在 $(...) 子 shell 中 exit 被吞掉）
require_arch() {
    local a
    if ! a=$(get_arch); then
        echo -e "${RED}不支持的系统架构: $(uname -m)（仅支持 x86_64 / aarch64）${PLAIN}"
        return 1
    fi
    echo "$a"
}

# 支持范围：Ubuntu 24.04+ / Debian 12+（x86_64 / aarch64）。
# 收缩到这个范围是为了让所有依赖都直接用发行版仓库，无需第三方 apt 源：
#   - caddy 自 Ubuntu noble / Debian bookworm 起才进发行版仓库（22.04 jammy 没有这个包）
#   - 两者仓库里的 2.6.2 已实测能完整承载本脚本的订阅地址配置
#   - 两者共用 apt + systemd + iptables-persistent，脚本的系统调用完全同构
# 已知版本下限（供后续新增依赖时对照）：
#   caddy 2.6.2 | openssl 3.0 | iptables 1.8.10 | qrencode 4.1.1
MIN_UBUNTU_VERSION="24.04"
MIN_DEBIAN_VERSION="12"

# 版本号比较：$1 >= $2 返回 0
ver_ge() {
    [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

require_os() {
    local id="" ver="" name=""
    local osrel="${OS_RELEASE_FILE:-/etc/os-release}"
    if [[ -r "$osrel" ]]; then
        # shellcheck disable=SC1091
        . "$osrel"
        id="${ID:-}"; ver="${VERSION_ID:-}"; name="${PRETTY_NAME:-$id $ver}"
    fi

    local min=""
    case "$id" in
        ubuntu) min="$MIN_UBUNTU_VERSION" ;;
        debian) min="$MIN_DEBIAN_VERSION" ;;
        *)
            echo -e "${RED}不支持的操作系统: ${name:-未知}${PLAIN}"
            echo -e "${YELLOW}本脚本仅支持 Ubuntu ${MIN_UBUNTU_VERSION}+ 或 Debian ${MIN_DEBIAN_VERSION}+（x86_64 / aarch64）。${PLAIN}"
            return 1
            ;;
    esac

    # 用 sort -V 比较：字符串比较会把 24.10 判成低于 24.04
    if [[ -z "$ver" ]] || ! ver_ge "$ver" "$min"; then
        echo -e "${RED}系统版本过低: ${name:-$id $ver}${PLAIN}"
        echo -e "${YELLOW}本脚本要求 ${id} ${min} 及以上（当前 ${ver:-未知}）。${PLAIN}"
        echo -e "${CYAN}  原因: 更早的版本仓库不含 caddy，无法直接安装证书管理服务。${PLAIN}"
        return 1
    fi
    echo "$name"
}

# 端口与端口段合法性校验
validate_port() {
    local p="${1:-}"
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    (( p >= 1 && p <= 65535 ))
}

validate_range() {
    local r="${1:-}"
    [[ "$r" =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]] || return 1
    local s="${BASH_REMATCH[1]}" e="${BASH_REMATCH[2]}"
    (( s >= 1 && e <= 65535 && e > s ))
}

validate_domain() {
    local d="${1:-}"
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]]
}

# 校验域名是否已解析到本机公网 IP（软提示，不强行阻断）
# $1=域名 $2=本机公网 IP
# 匹配返回 0；不匹配或未解析时给出诊断提示并询问用户是否强行使用（选 y 返回 0，放弃返回 1）
check_domain_ip_binding() {
    local domain="${1:-}"
    local server_ip="${2:-}"
    [[ -z "$domain" || -z "$server_ip" ]] && return 0

    echo -e "正在检测域名 ${domain} 的 DNS 解析..."
    local resolved_ips
    resolved_ips=$(timeout 4 getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)

    if [[ -z "$resolved_ips" ]]; then
        echo -e "${YELLOW}⚠️  警告: 域名 ${domain} 当前未检测到任何 A 记录解析！${PLAIN}"
        echo -e "${YELLOW}可能原因: 1. A 记录尚未在 Cloudflare 添加 2. 全球 DNS 尚未刷新生效${PLAIN}"
    elif echo "$resolved_ips" | grep -qw "$server_ip"; then
        echo -e "${GREEN}✓ 域名解析已成功指向本机公网 IP (${server_ip})！${PLAIN}"
        return 0
    else
        local ip_list
        ip_list=$(echo "$resolved_ips" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        echo -e "${YELLOW}⚠️  警告: 域名 ${domain} 当前解析为 [${ip_list}]，未指向本机公网 IP (${server_ip})！${PLAIN}"
        echo -e "${YELLOW}可能原因:${PLAIN}"
        echo -e "${YELLOW}  1. Cloudflare 开启了【小黄云】代理（必须设为灰色云朵【仅限 DNS】，否则 UDP 无法连通）${PLAIN}"
        echo -e "${YELLOW}  2. A 记录填写错误或尚未更新生效${PLAIN}"
    fi

    local confirm=""
    read -r -p "是否仍要继续使用该域名？y/N (回车放弃，重新输入域名或使用 IP): " confirm || confirm=""
    if [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]]; then
        echo -e "${YELLOW}已确认继续使用未匹配的域名: ${domain}${PLAIN}"
        return 0
    fi
    return 1
}

# 剔除字符串首尾的空白字符与引号（清洗换行符、制表符、空格与单双引号任意层嵌套）
trim_string() {
    local val="${1:-}"
    echo "$val" | tr -d '\r\n' | sed -E ':loop; s/^[[:space:]]+|[[:space:]]+$//g; s/^["'"'"']+|["'"'"']+$//g; t loop'
}

# 判断 CERT_DIR 中的证书是否确实签给指定域名（含有效期与公私钥配对校验）
# 用途：复用旧域名时可免输 Token，但必须确认证书真的覆盖该域名，
#       否则会把「IP 自签证书」误当成域名证书复用，最终 CERT_MODE 与实际情况不符。
cert_covers_domain() {
    local domain="${1:-}"
    local crt="${CERT_DIR}/fullchain.cer"
    local key="${CERT_DIR}/private.key"
    [[ -z "$domain" ]] && return 1
    [[ -s "$crt" && -s "$key" ]] || return 1

    # 有效期：至少还剩 1 天
    openssl x509 -in "$crt" -noout -checkend 86400 >/dev/null 2>&1 || return 1

    # 证书主题/SAN 必须覆盖该域名
    openssl x509 -in "$crt" -noout -checkhost "$domain" 2>/dev/null | grep -q "does match" || return 1

    # 公私钥配对
    local crt_pub key_pub
    crt_pub=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
    key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
    [[ -n "$crt_pub" && "$crt_pub" == "$key_pub" ]] || return 1

    return 0
}

# 在线校验 Cloudflare API Token 有效性
verify_cloudflare_token() {
    local token="${1:-}"
    token=$(trim_string "$token")
    [[ -z "$token" ]] && return 1

    echo -e "正在在线校验 Cloudflare API Token..."
    local check_res
    check_res=$(curl -s -m 8 -H "Authorization: Bearer ${token}" https://api.cloudflare.com/client/v4/user/tokens/verify || true)
    if echo "$check_res" | grep -q '"status":"active"'; then
        echo -e "${GREEN}✓ Cloudflare API Token 校验通过 (Active)！${PLAIN}"
        return 0
    else
        echo -e "${RED}✗ Cloudflare API Token 校验失败 (无效或权限不足)！${PLAIN}"
        echo -e "${YELLOW}请确认: 1. 区域资源是否包含该域名 2. 权限是否为 [编辑区域 DNS]${PLAIN}"
        return 1
    fi
}

# 收紧私钥权限
# 私钥不能 644（任何本地用户可读），也不能 600 root:root
# —— caddy 以 caddy 用户运行，要读它来做 TLS，600 root:root 会让 caddy
# 启动/reload 直接失败（permission denied）。
# 正确做法：属主 root、属组 caddy、640。sing-box 以 root 运行，不受影响。
harden_private_key() {
    local key="${CERT_DIR}/private.key"
    [[ -f "$key" ]] || return 0
    # caddy 组可能尚不存在：全新机器上证书签发发生在 install_caddy 之前。
    # 那种情况下 chown 会失败（invalid group），私钥会留在 root:root，
    # caddy 装好后就读不到 —— 所以这里必须区分两种情况，不能一律 || true 吞掉。
    if getent group caddy >/dev/null 2>&1; then
        chown root:caddy "$key" 2>/dev/null || true
        chmod 640 "$key" 2>/dev/null || true
    else
        # caddy 尚未安装：先按 root:root 640 收紧，装好 caddy 后由
        # setup_caddy_subscription 再调一次本函数补上属组。
        chmod 640 "$key" 2>/dev/null || true
    fi
    return 0
}

# 引导用户输入 Cloudflare API Token
# 成功时设置全局 PROMPTED_CF_TOKEN 并返回 0；用户放弃或输入为空时返回 1（调用方回退 IP 自签）
# 注意：不能用 $(prompt_cf_token) 取返回值，函数内的指引文字会一起被捕获，
# 所以结果走全局变量。不能叫 CF_TOKEN —— 那是支持无人值守部署的预置环境变量名。
prompt_cf_token() {
    PROMPTED_CF_TOKEN=""
    echo -e "\n${GRAY}----------------- Cloudflare API Token 获取指引 -----------------${PLAIN}"
    echo -e " 1. 登录 CF -> 右上角头像 -> [配置文件] -> 左侧导航 [API 令牌]"
    echo -e " 2. 点击 [创建令牌] -> 找到 [编辑区域 DNS (Edit zone DNS)] 点击 [使用模板]"
    echo -e " 3. 区域资源选择: [包括] -> [特定区域] -> 选择你的域名"
    echo -e " 4. 底部点击 [继续以显示摘要] -> 最终确认页点击 [创建令牌] 并复制生成的令牌"
    echo -e "${GRAY}-----------------------------------------------------------------${PLAIN}"
    local token=""
    while true; do
        read -r -p "请输入 Cloudflare API Token: " token || token=""
        token=$(trim_string "$token")
        if [[ -z "$token" ]]; then
            echo -e "${YELLOW}未输入 Token，将自动使用 IP 自签证书。${PLAIN}"
            return 1
        fi
        if verify_cloudflare_token "$token"; then
            PROMPTED_CF_TOKEN="$token"
            return 0
        fi
        local retry=""
        read -r -p "是否重新输入 Token？Y/n (回车重试，输入 n 使用 IP 自签): " retry || retry=""
        if [[ "${retry,,}" == "n" ]]; then
            echo -e "${YELLOW}已放弃域名证书，将自动使用 IP 自签证书。${PLAIN}"
            return 1
        fi
    done
}

# 校验一个 TCP/UDP 端口是否与已分配的其它服务冲突
# $1=待校验端口 $2=tcp|udp $3=当前正在配置的服务名（跳过与自身的比较）
# 冲突时打印原因并返回 1
check_port_conflict() {
    local port="${1:-}" proto="${2:-tcp}" self="${3:-}" range="${4:-}"
    local label
    [[ "$proto" == "udp" ]] && label="UDP" || label="TCP"

    if [[ -n "${VL_PORT:-}" && "$self" != "vless" && "$port" == "$VL_PORT" ]]; then
        echo -e "${RED}端口冲突: 该端口已分配给 VLESS-Reality (${VL_PORT})，不能共用！${PLAIN}"
        return 1
    fi
    if [[ -n "${HY_PORT:-}" && "$self" != "hy2" && "$port" == "$HY_PORT" ]]; then
        echo -e "${RED}端口冲突: 该端口已分配给 Hysteria 2 (${HY_PORT})，不能共用！${PLAIN}"
        return 1
    fi
    if [[ -n "${SUB_PORT:-}" && "$self" != "sub" && "$port" == "$SUB_PORT" ]]; then
        echo -e "${RED}端口冲突: 该端口已分配给 Caddy 订阅 (${SUB_PORT})，不能共用！${PLAIN}"
        return 1
    fi

    # 端口落在 Hysteria 2 跳跃范围内也不行（UDP 段会被 iptables 整段转发）
    local r="${range:-${HY_RANGE:-}}"
    if [[ -n "$r" && "$r" == *:* ]]; then
        local r_start="${r%%:*}" r_end="${r##*:}"
        if (( port >= r_start && port <= r_end )); then
            echo -e "${RED}范围冲突: 端口 ${port} 落在 Hysteria 2 跳跃范围 (${r}) 内，请调整！${PLAIN}"
            return 1
        fi
    fi

    if check_port_occupied "$port" "$proto"; then
        return 0
    fi
    echo -e "${YELLOW}请更换其他未占用的 ${label} 端口！${PLAIN}"
    return 1
}

# 校验端口跳跃范围是否与已分配的端口冲突
# $1=范围(起始:结束)
# 注意：Hy2 主端口落在跳跃范围内必须拒绝。iptables 会对整段 UDP 做 DNAT，
# 主端口若在段内会和跳跃端口抢同一批包，客户端握手随机失败。
# 不要为「主端口是本次新选的值」而加 skip 参数放行 —— 那正是该拦的情况。
check_range_conflict() {
    local r="${1:-}"
    local r_start="${r%%:*}" r_end="${r##*:}"
    local p
    for p in "${VL_PORT:-}:VLESS-Reality" "${SUB_PORT:-}:Caddy 订阅" "${HY_PORT:-}:Hysteria 2 主端口"; do
        local val="${p%%:*}" name="${p#*:}"
        [[ -z "$val" ]] && continue
        if (( val >= r_start && val <= r_end )); then
            echo -e "${RED}范围冲突: 跳跃范围包含 ${name} 端口 (${val})，请调整！${PLAIN}"
            return 1
        fi
    done
    return 0
}

# 端口冲突检测
check_port_occupied() {
    local port="${1:-}"
    local proto="${2:-}"
    local in_use=""
    # 支持范围内（Ubuntu 24.04+/Debian 12+）的 iproute2 都带 ss，无需 netstat 回退
    if [[ "$proto" == "tcp" ]]; then
        in_use=$(ss -tlnp 2>/dev/null | grep -E "[: ]${port} " || true)
    elif [[ "$proto" == "udp" ]]; then
        in_use=$(ss -ulnp 2>/dev/null | grep -E "[: ]${port} " || true)
    fi
    if [[ -n "$in_use" ]]; then
        if echo "$in_use" | grep -q "sing-box"; then
            echo -e "提示: 端口 ${port} 当前由已有 sing-box 进程使用，重置安装将自动平滑接管。"
            return 0
        elif echo "$in_use" | grep -q "caddy"; then
            echo -e "提示: 端口 ${port} 当前由已有 caddy 订阅服务使用，重置安装将自动复用。"
            return 0
        else
            echo -e "${RED}警告: ${proto^^} 端口 ${port} 已被外部服务占用！${PLAIN}"
            echo -e "${YELLOW}占用详情: ${in_use}${PLAIN}"
            return 1
        fi
    fi
    return 0
}

# 基础依赖检查与安装
# 支持范围内的系统必然是 apt + systemd，直接 apt 安装，无需分支。
install_deps() {
    local missing=()
    for cmd in curl tar openssl iptables qrencode; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    # netfilter-persistent 由 iptables-persistent 提供，是端口跳跃规则持久化的前提。
    # 必须单独判定：iptables 在而持久化包缺失时，只看 missing 会漏装。
    command -v netfilter-persistent &>/dev/null || missing+=(iptables-persistent)

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "安装必要基础组件: ${missing[*]}..."
        export DEBIAN_FRONTEND=noninteractive
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections 2>/dev/null || true
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null || true
        apt-get update -qq || echo -e "${YELLOW}apt-get update 失败，尝试直接安装。${PLAIN}"
        apt-get install -y -qq "${missing[@]}" \
            || echo -e "${YELLOW}部分依赖安装失败，将尝试继续（缺少 qrencode 仅影响二维码显示）。${PLAIN}"
    fi

    # 关键依赖缺失时给出明确警告（iptables 缺失会导致端口跳跃静默失效）
    local critical_missing=()
    for cmd in curl tar openssl iptables; do
        command -v "$cmd" &>/dev/null || critical_missing+=("$cmd")
    done
    if [ ${#critical_missing[@]} -gt 0 ]; then
        echo -e "${RED}关键依赖缺失: ${critical_missing[*]}${PLAIN}"
        echo -e "${YELLOW}请手动安装后重试，例如: apt-get install -y ${critical_missing[*]}${PLAIN}"
        return 1
    fi
    return 0
}

# 检查并自动安装 Caddy（证书管理）
# 支持范围内（Ubuntu 24.04+ / Debian 12+）的发行版仓库自带 caddy，无需第三方源。
# 已有 caddy 则原样使用：不升级、不重启，避免打断用户自己托管在它上面的站点。
install_caddy() {
    # deb-systemd-helper 在 apt remove 时会 mask caddy.service，
    # 而 unmask 只在 configure 阶段执行；包处于 rc 状态重装时不会触发，
    # 服务将永久起不来。因此无论走哪条路径都先解除 mask。
    [[ "$(systemctl is-enabled caddy 2>/dev/null)" == "masked" ]] && systemctl unmask caddy >/dev/null 2>&1

    if command -v caddy &>/dev/null; then
        systemctl enable caddy >/dev/null 2>&1 || true
        return 0
    fi

    echo -e "正在安装 Caddy 用于证书管理..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    if ! apt-get install -y -qq caddy; then
        echo -e "${RED}Caddy 安装失败。${PLAIN}"
        echo -e "${YELLOW}请先执行 apt-get update 后重试，或手动安装: apt-get install -y caddy${PLAIN}"
        return 1
    fi

    # 全新安装后也解除一次，避免 rc 残留状态导致 mask 未清
    systemctl unmask caddy >/dev/null 2>&1 || true

    # 归属标记：只有本脚本装的包，卸载时才连软件包一起清理
    mkdir -p "$CONF_DIR" 2>/dev/null || true
    : > "${CONF_DIR}/.caddy_installed_by_script" 2>/dev/null || true
    systemctl enable caddy >/dev/null 2>&1 || true
}

# BBR 拥塞控制管理（开启与关闭）
# BBR 配置文件路径与归属标记
# 标记用于区分「本脚本创建的」与「用户自己配的」，
# 卸载时只删带标记的，绝不覆盖或误删别人的 sysctl 配置。
BBR_CONF="/etc/sysctl.d/99-bbr.conf"
BBR_MARK="# managed-by: simple-box"

# 开启 BBR（安装时调用，无交互）
# 三种情况分别处理：已开启则跳过；已有他人配置则不动；否则写入并打标记
enable_bbr() {
    local cur
    cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")

    if [[ "$cur" == "bbr" ]]; then
        echo -e "${GREEN}✓ TCP BBR 已处于开启状态，无需调整${PLAIN}"
        return 0
    fi

    # 文件存在但不带本脚本标记 → 是用户的配置，不动
    if [[ -f "$BBR_CONF" ]] && ! grep -q "^${BBR_MARK}" "$BBR_CONF"; then
        echo -e "${YELLOW}检测到已有的 ${BBR_CONF}（非本脚本创建），保留不覆盖。${PLAIN}"
        echo -e "${YELLOW}如需 BBR 加速请手动确认该文件内容。${PLAIN}"
        return 0
    fi

    mkdir -p /etc/sysctl.d
    cat > "$BBR_CONF" <<EOF
${BBR_MARK}
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p "$BBR_CONF" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true

    cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [[ "$cur" == "bbr" ]]; then
        echo -e "${GREEN}✓ TCP BBR 已开启${PLAIN}"
    else
        echo -e "${YELLOW}BBR 配置已写入，但内核当前返回 ${cur:-未知}，可能需要重启系统。${PLAIN}"
    fi
}

# 恢复系统默认（卸载时调用）
# 只处理带本脚本标记的文件；用户自己的 sysctl 配置一律不碰
disable_bbr() {
    [[ -f "$BBR_CONF" ]] || return 0
    if ! grep -q "^${BBR_MARK}" "$BBR_CONF"; then
        echo -e "${YELLOW}${BBR_CONF} 非本脚本创建，保留不动。${PLAIN}"
        return 0
    fi
    rm -f "$BBR_CONF"
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
    echo -e "已恢复系统默认拥塞控制算法"
}

# 获取并升级官方 sing-box 内核（带精准版本校验）
update_singbox_core() {
    local force_flag="${1:-}"
    echo -e "检查 sing-box 官方最新版本..."

    local cur_ver="未安装"
    if [[ -f /usr/local/bin/sing-box ]]; then
        cur_ver=$(/usr/local/bin/sing-box version 2>/dev/null | head -n1 | awk '{print $3}')
    fi

    local tag=""
    tag=$(curl -sSL --max-time 20 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | grep -Po '"tag_name": "\K[^"]*' || true)
    if [[ -z "$tag" ]]; then
        if [[ -f /usr/local/bin/sing-box ]]; then
            echo -e "${YELLOW}获取最新版本失败（GitHub API 不通或被限流），已保留现有版本 (v${cur_ver})。${PLAIN}"
            return 0
        else
            echo -e "${YELLOW}GitHub API 限流，启用内置稳定发布版本 (v1.14.3) 进行安装...${PLAIN}"
            tag="v1.14.3"
        fi
    fi
    local latest_ver=${tag#v}
    local arch
    if ! arch=$(require_arch); then
        return 1
    fi

    echo -e "本地当前版本: ${CYAN}v${cur_ver}${PLAIN} | 官方最新版本: ${GREEN}${tag}${PLAIN} (${arch})"

    if [[ "$cur_ver" == "$latest_ver" && "$force_flag" != "force" ]]; then
        echo -e "${GREEN}当前已是官方最新版本，无需重复更新！${PLAIN}"
        if [ -t 0 ]; then
            read -r -p "是否强制重新下载覆盖安装？(y/N): " re_install
            [[ "$re_install" != "y" && "$re_install" != "Y" ]] && return 0
        else
            return 0
        fi
    fi

    local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${latest_ver}-linux-${arch}.tar.gz"
    local tmp_dir=$(mktemp -d)
    local tmp_tar="${tmp_dir}/sing-box.tar.gz"

    echo -e "正在下载并更新内核..."
    if ! curl -fsSL "$url" -o "$tmp_tar"; then
        echo -e "${RED}内核下载失败（网络不通或该版本无 ${arch} 构建），已保留现有版本。${PLAIN}"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! tar -xzf "$tmp_tar" -C "$tmp_dir" --strip-components=1 2>/dev/null; then
        echo -e "${RED}内核压缩包解压失败，已保留现有版本。${PLAIN}"
        rm -rf "$tmp_dir"
        return 1
    fi
    if [[ -f "$tmp_dir/sing-box" ]]; then
        # 升级前备份旧内核，新内核若无法解析现有配置则自动回滚
        local old_bin_backup=""
        if [[ -x /usr/local/bin/sing-box ]]; then
            old_bin_backup="/usr/local/bin/sing-box.bak.$$"
            cp -f /usr/local/bin/sing-box "$old_bin_backup" 2>/dev/null || old_bin_backup=""
        fi
        install -m 755 "$tmp_dir/sing-box" /usr/local/bin/sing-box
        rm -rf "$tmp_dir"

        if [[ -f "$CONF_FILE" ]] && ! /usr/local/bin/sing-box check -c "$CONF_FILE" >/dev/null 2>&1; then
            echo -e "${RED}新内核无法解析现有配置，正在回滚到旧版本...${PLAIN}"
            if [[ -n "$old_bin_backup" ]]; then
                mv -f "$old_bin_backup" /usr/local/bin/sing-box
                echo -e "${GREEN}已回滚，仍使用原内核: $(/usr/local/bin/sing-box version | head -n1)${PLAIN}"
            else
                echo -e "${RED}无旧内核备份可回滚，请手动重装。${PLAIN}"
            fi
            return 1
        fi
        [[ -n "$old_bin_backup" ]] && rm -f "$old_bin_backup" 2>/dev/null || true

        echo -e "${GREEN}sing-box 内核更新成功: $(/usr/local/bin/sing-box version | head -n1)${PLAIN}"
        if systemctl is-active --quiet sing-box; then
            systemctl restart sing-box
            echo -e "${GREEN}sing-box 服务已自动平滑重启！${PLAIN}"
        fi
    else
        echo -e "${RED}下载或更新失败！${PLAIN}"
        rm -rf "$tmp_dir"
        return 1
    fi
}

# 证书签发（支持 CF API 证书与无域名自签证书）
# 结果通过全局 CERT_MODE 回传: domain | selfsigned
CERT_MODE=""
issue_cert_bundle() {
    local domain="${1:-}"
    local cf_token="${2:-}"
    local server_ip="${3:-}"
    local acme_bin="$HOME/.acme.sh/acme.sh"
    CERT_MODE="selfsigned"

    mkdir -p "$CERT_DIR"

    # 模式 A0: 有域名但无 Token —— 尝试复用本地已有的该域名证书（免输 Token 场景）
    # 必须先于下面的失败降级逻辑判断，否则会把有效域名证书覆盖成自签证书
    if [[ -n "$domain" && -z "$cf_token" ]]; then
        if cert_covers_domain "$domain"; then
            echo -e "${GREEN}本地已有覆盖 ${domain} 的有效证书，直接复用（无需重新申请）。${PLAIN}"
            chmod 755 "$CONF_DIR" "$CERT_DIR" 2>/dev/null || true
            chmod 640 "${CERT_DIR}"/* 2>/dev/null || true; chmod 644 "${CERT_DIR}/fullchain.cer" 2>/dev/null || true
            harden_private_key
            CERT_MODE="domain"
            echo -e "${GREEN}TLS 证书已就绪: ${CERT_DIR} (模式: ${CERT_MODE})${PLAIN}"
            return 0
        fi
        echo -e "${YELLOW}本地无覆盖 ${domain} 的有效证书，且未提供 CF Token，将降级为 IP 自签。${PLAIN}"
    fi

    # 模式 A: 自有域名 + CF Token，走 DNS-01 申请 Let's Encrypt
    if [[ -n "$domain" && -n "$cf_token" ]]; then
        echo -e "配置 acme.sh 证书环境..."
        if [[ ! -f "$acme_bin" ]]; then
            curl -sSL https://get.acme.sh | sh -s email="admin@${domain}" || true
        fi
        if [[ ! -f "$acme_bin" ]]; then
            echo -e "${RED}acme.sh 安装失败（无法访问 get.acme.sh）。${PLAIN}"
        else
            export CF_Token="$cf_token"
            if [[ -f "$HOME/.acme.sh/${domain}_ecc/fullchain.cer" && -f "$HOME/.acme.sh/${domain}_ecc/${domain}.key" ]]; then
                echo -e "${GREEN}检测到本地已有 ${domain} 的证书，直接同步部署...${PLAIN}"
            else
                echo -e "通过 Cloudflare DNS API 申请证书（DNS-01，无需 80 端口）..."
                "$acme_bin" --set-default-ca --server letsencrypt || true
                "$acme_bin" --issue --dns dns_cf -d "$domain" --dnssleep 20 --keylength ec-256 --force || true
            fi
            "$acme_bin" --install-cert -d "$domain" --ecc \
                --fullchain-file "${CERT_DIR}/fullchain.cer" \
                --key-file "${CERT_DIR}/private.key" \
                --reloadcmd "systemctl reload sing-box 2>/dev/null || true; systemctl reload caddy 2>/dev/null || true" || true
        fi
    fi

    # 校验：域名证书是否真的落地（含有效期 + 公私钥配对，避免 acme 写半截）
    local ok=false
    if [[ -s "${CERT_DIR}/fullchain.cer" && -s "${CERT_DIR}/private.key" ]]; then
        if openssl x509 -in "${CERT_DIR}/fullchain.cer" -noout -checkend 0 >/dev/null 2>&1; then
            local d_crt_pub d_key_pub
            d_crt_pub=$(openssl x509 -in "${CERT_DIR}/fullchain.cer" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
            d_key_pub=$(openssl pkey -in "${CERT_DIR}/private.key" -pubout 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
            if [[ -n "$d_crt_pub" && "$d_crt_pub" == "$d_key_pub" ]]; then
                ok=true
            else
                echo -e "${RED}域名证书与私钥不配对（acme 写入异常），将降级为自签证书。${PLAIN}"
            fi
        fi
    fi

    # 域名证书还必须真的覆盖该域名，否则视为申请失败（防止 acme 返回旧证书/空证书）
    if [[ "$ok" == true && -n "$domain" ]]; then
        if ! openssl x509 -in "${CERT_DIR}/fullchain.cer" -noout -checkhost "$domain" 2>/dev/null | grep -q "does match"; then
            echo -e "${RED}已签发的证书未覆盖域名 ${domain}，将降级为自签证书。${PLAIN}"
            ok=false
        fi
    fi

    if [[ "$ok" == true && -n "$domain" && -n "$cf_token" ]]; then
        CERT_MODE="domain"
        echo -e "${GREEN}域名证书部署成功: ${domain}${PLAIN}"
    else
        [[ -n "$domain" ]] && {
            echo -e "${RED}域名证书申请失败（Token 权限、域名拼写或 CF 网络问题）。${PLAIN}"
            echo -e "${YELLOW}已自动降级为 10 年期 IP 自签证书，保证节点立即可用。${PLAIN}"
        }
        # 模式 B: 为公网 IP 生成 10 年自签 ECC 证书（含公私钥配对严格校验）
        if ! issue_self_signed_cert "$server_ip"; then
            echo -e "${RED}自签证书生成失败。${PLAIN}"
            return 1
        fi
        CERT_MODE="selfsigned"
    fi

    chmod 755 "$CONF_DIR" "$CERT_DIR" 2>/dev/null || true
    chmod 640 "${CERT_DIR}"/* 2>/dev/null || true; chmod 644 "${CERT_DIR}/fullchain.cer" 2>/dev/null || true
    harden_private_key

    if [[ ! -s "${CERT_DIR}/fullchain.cer" || ! -s "${CERT_DIR}/private.key" ]]; then
        echo -e "${RED}致命错误: 证书文件未能生成，请检查 openssl 是否可用。${PLAIN}"
        return 1
    fi
    echo -e "${GREEN}TLS 证书已就绪: ${CERT_DIR} (模式: ${CERT_MODE})${PLAIN}"
    return 0
}

# 仅签发 IP 自签证书（独立函数，供子菜单复用）
issue_self_signed_cert() {
    local server_ip="${1:-}"
    mkdir -p "$CERT_DIR"
    [[ -z "$server_ip" ]] && { echo -e "${RED}缺少公网 IP，无法生成自签证书。${PLAIN}"; return 1; }

    echo -e "${YELLOW}为服务器 IP (${server_ip}) 生成 10 年期自签 ECC 证书...${PLAIN}"
    local tmp_key="${CERT_DIR}/.private.key.tmp"
    local tmp_crt="${CERT_DIR}/.fullchain.cer.tmp"
    if ! openssl ecparam -genkey -name prime256v1 -out "$tmp_key" >/dev/null 2>&1; then
        echo -e "${RED}自签私钥生成失败（openssl 不可用？）。${PLAIN}"; return 1
    fi
    if ! openssl req -new -x509 -days 3650 -key "$tmp_key" -out "$tmp_crt" \
        -subj "/CN=${server_ip}" -addext "subjectAltName=IP:${server_ip},IP:127.0.0.1" >/dev/null 2>&1; then
        rm -f "$tmp_key" "$tmp_crt"
        echo -e "${RED}自签证书生成失败。${PLAIN}"; return 1
    fi
    # 原子替换，避免 sing-box/caddy 读到半写状态
    # 先校验新证书与私钥确实配对，再原子替换，避免上线后握手失败
    # 统一用公钥比对（RSA/ECC 通用；-modulus 对 ECC 无效）
    local crt_pub key_pub
    crt_pub=$(openssl x509 -in "$tmp_crt" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
    key_pub=$(openssl pkey -in "$tmp_key" -pubout 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
    if [[ -z "$crt_pub" || -z "$key_pub" || "$crt_pub" != "$key_pub" ]]; then
        rm -f "$tmp_key" "$tmp_crt"
        echo -e "${RED}自签证书与私钥不匹配 (crt=${crt_pub:-空} key=${key_pub:-空})，已放弃本次写入（原证书保持不变）。${PLAIN}"
        return 1
    fi

    mv -f "$tmp_key" "${CERT_DIR}/private.key"
    mv -f "$tmp_crt" "${CERT_DIR}/fullchain.cer"
    chmod 755 "$CONF_DIR" "$CERT_DIR" 2>/dev/null || true
    chmod 640 "${CERT_DIR}"/* 2>/dev/null || true; chmod 644 "${CERT_DIR}/fullchain.cer" 2>/dev/null || true
    harden_private_key
    echo -e "${GREEN}IP 自签证书已就绪 (10 年有效期，公私钥已配对校验)。${PLAIN}"
    return 0
}

# 清理本脚本遗留的端口跳跃规则（按标记逐条删除，不触碰其它规则）
clear_port_hopping() {
    local ranges
    # iptables -S 输出形如: -A PREROUTING -p udp -m udp --dport 20000:40000 -j REDIRECT --to-ports 8443
    ranges=$(iptables -t nat -S PREROUTING 2>/dev/null \
        | grep -oP -- '--dport \K[0-9]+:[0-9]+(?=.*REDIRECT --to-ports)' | sort -u || true)
    local r tport
    for r in $ranges; do
        tport=$(iptables -t nat -S PREROUTING 2>/dev/null \
            | grep -F -- "--dport $r " | grep -oP -- '--to-ports \K[0-9]+' | head -1 || true)
        if [[ -n "$tport" ]]; then
            iptables -t nat -D PREROUTING -p udp --dport "$r" -j REDIRECT --to-ports "$tport" 2>/dev/null || true
        fi
    done
    # 清理历史版本遗留的 IPv6 跳跃规则（本脚本已不支持 IPv6，只删不加）
    if command -v ip6tables &>/dev/null; then
        local r6
        for r6 in $(ip6tables -t nat -S PREROUTING 2>/dev/null \
            | grep -oP -- '--dport \K[0-9]+:[0-9]+(?=.*REDIRECT --to-ports)' | sort -u || true); do
            local t6
            t6=$(ip6tables -t nat -S PREROUTING 2>/dev/null \
                | grep -F -- "--dport $r6 " | grep -oP -- '--to-ports \K[0-9]+' | head -1 || true)
            [[ -n "$t6" ]] && ip6tables -t nat -D PREROUTING -p udp --dport "$r6" \
                -j REDIRECT --to-ports "$t6" 2>/dev/null || true
        done
    fi

    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi
}

# 端口跳跃 iptables 规则配置
setup_port_hopping() {
    local hy_port="${1:-}"
    local range="${2:-}"

    echo -e "配置 Hysteria 2 端口跳跃 (UDP ${range} -> ${hy_port})..."
    iptables -t nat -D PREROUTING -p udp --dport "$range" -j REDIRECT --to-ports "$hy_port" 2>/dev/null || true
    iptables -t nat -A PREROUTING -p udp --dport "$range" -j REDIRECT --to-ports "$hy_port"

    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi

    if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
        ufw allow "$hy_port/udp" >/dev/null 2>&1 || true
        ufw allow "${range/:/-}/udp" >/dev/null 2>&1 || true
    fi
}

# 安全重载 Caddy：先校验配置，优先 reload，失败才 restart，并解除 systemd 限流
reload_caddy_safe() {
    if ! command -v caddy &>/dev/null; then
        echo -e "${YELLOW}未安装 Caddy，跳过订阅地址重载。${PLAIN}"
        return 1
    fi

    # 1. 配置语法校验（不通过就不要碰运行中的服务）
    if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
        echo -e "${RED}Caddyfile 校验失败，已保持现有订阅服务不变。${PLAIN}"
        caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | tail -5
        return 1
    fi

    # 包被 apt remove 后 deb-systemd-helper 会留下 mask，此处兜底解除
    [[ "$(systemctl is-enabled caddy 2>/dev/null)" == "masked" ]] && systemctl unmask caddy >/dev/null 2>&1

    # 2. 运行中优先热重载，避免反复 restart 触发 systemd start-limit-hit
    if systemctl is-active --quiet caddy; then
        if systemctl reload caddy 2>/dev/null; then
            return 0
        fi
        echo -e "${YELLOW}Caddy 热重载未生效，改为重启...${PLAIN}"
    else
        # 3. 未运行（或曾被限流）时先清除失败计数，再启动
        systemctl reset-failed caddy 2>/dev/null || true
    fi

    if systemctl restart caddy 2>/dev/null; then
        return 0
    fi
    echo -e "${RED}Caddy 启动失败，请查看: journalctl -u caddy -n 30${PLAIN}"
    return 1
}

# 校验 Caddy 是否真的在目标端口监听（重载后调用，防止"配置成功但没生效"）
verify_caddy_listening() {
    local port="${1:-}"
    local i
    for i in 1 2 3 4 5; do
        if ss -tln 2>/dev/null | grep -qE "[:.]${port} "; then
            return 0
        fi
        sleep 1
    done
    echo -e "${RED}警告: Caddy 未在端口 ${port} 上监听，订阅链接当前不可用。${PLAIN}"
    echo -e "${YELLOW}请检查: journalctl -u caddy -n 30${PLAIN}"
    return 1
}

# 部署 Caddy 证书管理服务
setup_caddy_subscription() {
    local domain_or_ip="${1:-}"
    local token="${2:-}"
    local sub_port="${3:-}"
    local cert_mode="${4:-selfsigned}"

    if ! install_caddy; then
        echo -e "${RED}Caddy 不可用，无法部署证书管理服务。${PLAIN}"
        return 1
    fi

    # caddy 装好后 caddy 组才存在。全新机器上证书先于 caddy 签发，那时
    # harden_private_key 只能把私钥留在 root:root，caddy 读不到会直接
    # permission denied 起不来。这里补调一次把属组补上。
    harden_private_key

    mkdir -p "/etc/caddy/sites"
    
    # 若 Caddy 为本脚本安装，或 Caddyfile 尚不存在：写入纯净配置，绝不监听 80 端口（杜绝与 Nginx/Apache 冲突）
    if [ ! -f /etc/caddy/Caddyfile ] || [[ -f "${CONF_DIR}/.caddy_installed_by_script" ]]; then
        echo -e "import sites/*.caddy\n" > /etc/caddy/Caddyfile
        : > "${CONF_DIR}/.caddyfile_created_by_script" 2>/dev/null || true
    elif ! grep -q "import sites/\*\.caddy" /etc/caddy/Caddyfile; then
        echo -e "\nimport sites/*.caddy" >> /etc/caddy/Caddyfile
        : > "${CONF_DIR}/.caddyfile_appended_by_script" 2>/dev/null || true
    fi

    # 清理所有旧版 simple-box caddy 配置文件
    rm -f /etc/caddy/sites/*-${sub_port}.caddy /etc/caddy/sites/simple-box*.caddy

    if [[ "$cert_mode" == "domain" ]]; then
        echo -e "配置 Caddy HTTPS 域名证书 (端口 ${sub_port})..."
        cat > "/etc/caddy/sites/simple-box-sub.caddy" <<EOF
# Simple-Box HTTPS 域名证书
:${sub_port} {
    bind tcp4/0.0.0.0
    tls ${CERT_DIR}/fullchain.cer ${CERT_DIR}/private.key

    @sub path /${token}/config.yaml /${token}/provider.yaml /${token}/links.txt
    handle @sub {
        root * ${WEB_DIR}
        header Content-Type "text/plain; charset=utf-8"
        file_server
    }

    handle {
        respond 404
    }
}
EOF
    else
        echo -e "配置 Caddy HTTP 自签证书 (端口 ${sub_port}, 客户端直接导入免证书报错)..."
        cat > "/etc/caddy/sites/simple-box-sub.caddy" <<EOF
# Simple-Box HTTP 自签证书
http://:${sub_port} {
    bind tcp4/0.0.0.0
    @sub path /${token}/config.yaml /${token}/provider.yaml /${token}/links.txt
    handle @sub {
        root * ${WEB_DIR}
        header Content-Type "text/plain; charset=utf-8"
        file_server
    }

    handle {
        respond 404
    }
}
EOF
    fi

    if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
        ufw allow "${sub_port}/tcp" >/dev/null 2>&1 || true
    fi

    chmod 755 "$WEB_DIR" 2>/dev/null || true
    if ! command -v caddy &>/dev/null; then
        echo -e "${RED}Caddy 未安装成功，在线订阅不可用。${PLAIN}"
        echo -e "${YELLOW}节点本身不受影响；可稍后手动安装 Caddy 再重跑本项。${PLAIN}"
        return 0
    fi
    reload_caddy_safe || echo -e "${YELLOW}订阅地址配置已写入，但 Caddy 未能生效，可稍后手动 systemctl restart caddy。${PLAIN}"
}

# 组装客户端订阅与独立链接
generate_full_client_config() {
    local domain_or_ip="${1:-}"
    local token="${2:-}"
    local node_prefix="${3:-}"
    local server_ip="${4:-}"
    local vl_port="${5:-}"
    local user_uuid="${6:-}"
    local vl_sni="${7:-}"
    local vl_pubkey="${8:-}"
    local vl_shortid="${9:-}"
    local hy_port="${10}"
    local hy_ports_display="${11}"
    local hy_password="${12}"
    local hy_skip_cert="${13}"

    mkdir -p "${WEB_DIR}/${token}"

    if [ ! -f "$TEMPLATE_FILE" ]; then
        local script_dir=""
        if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
            script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        fi
        if [[ -n "$script_dir" && -f "${script_dir}/template.yaml" ]]; then
            cp -f "${script_dir}/template.yaml" "$TEMPLATE_FILE" 2>/dev/null || true
        else
            curl -fsSL https://raw.githubusercontent.com/comegome/Simple-Box/main/template.yaml -o "$TEMPLATE_FILE" 2>/dev/null || true
        fi
    fi

    # 1. 组装完整配置
    local full_config_file="${WEB_DIR}/${token}/config.yaml"
    if [ -f "$TEMPLATE_FILE" ]; then
        cat "$TEMPLATE_FILE" > "$full_config_file"
    else
        # 模板缺失时的兜底必须自带 rules: 段，否则下面的防死锁规则无处可插
        {
            echo "mixed-port: 7890"
            echo "mode: rule"
            echo "rules:"
        } > "$full_config_file"
    fi

    # 分流规则防死锁：域名模式精准直连该域名；IP 模式直连 VPS 本机 IP
    # 用 awk 插入而不是 sed a 命令：sed 的 a 会吃掉行首空格，导致 YAML 缩进错乱
    # （- IP-CIDR 顶格 → 解析失败），awk 能原样保留两空格缩进。
    local direct_rule
    if [[ "$domain_or_ip" == "$server_ip" || -z "$domain_or_ip" ]]; then
        direct_rule="  - IP-CIDR,${server_ip}/32,DIRECT,no-resolve"
    else
        direct_rule="  - DOMAIN,${domain_or_ip},DIRECT"
    fi
    if grep -q '^rules:' "$full_config_file"; then
        awk -v rule="$direct_rule" '
            { print }
            /^rules:[[:space:]]*$/ && !done { print rule; done=1 }
        ' "$full_config_file" > "${full_config_file}.tmp" && mv -f "${full_config_file}.tmp" "$full_config_file"
    else
        printf 'rules:\n%s\n' "$direct_rule" >> "$full_config_file"
    fi

    local ports_line=""
    [[ -n "$hy_ports_display" && "$hy_ports_display" == *,* ]] && ports_line="    ports: \"${hy_ports_display}\""

    cat >> "$full_config_file" <<EOF

# ==================== Simple-Box 动态生成节点 ====================
proxies:
  - name: "${node_prefix}-VLESS-Reality"
    type: vless
    server: ${server_ip}
    port: ${vl_port}
    uuid: ${user_uuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${vl_sni}
    reality-opts:
      public-key: ${vl_pubkey}
      short-id: ${vl_shortid}
    client-fingerprint: chrome
EOF

    cat >> "$full_config_file" <<EOF
  - name: "${node_prefix}-Hysteria2"
    type: hysteria2
    server: ${domain_or_ip}
    port: ${hy_port}
${ports_line}
    password: "${hy_password}"
    sni: ${domain_or_ip}
    skip-cert-verify: ${hy_skip_cert}
EOF

    cat >> "$full_config_file" <<EOF

proxy-groups:
  - name: "📌节点选择"
    type: select
    proxies:
      - "${node_prefix}-VLESS-Reality"
EOF

    printf '      - "%s-Hysteria2"\n' "$node_prefix" >> "$full_config_file"
    printf '      - "DIRECT"\n' >> "$full_config_file"

    # 2. 组装纯 Provider 片段
    local provider_file="${WEB_DIR}/${token}/provider.yaml"
    cat > "$provider_file" <<EOF
proxies:
  - name: "${node_prefix}-VLESS-Reality"
    type: vless
    server: ${server_ip}
    port: ${vl_port}
    uuid: ${user_uuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${vl_sni}
    reality-opts:
      public-key: ${vl_pubkey}
      short-id: ${vl_shortid}
    client-fingerprint: chrome
EOF

    cat >> "$provider_file" <<EOF
  - name: "${node_prefix}-Hysteria2"
    type: hysteria2
    server: ${domain_or_ip}
    port: ${hy_port}
${ports_line}
    password: "${hy_password}"
    sni: ${domain_or_ip}
    skip-cert-verify: ${hy_skip_cert}
EOF


    # 3. 组装原生分享链接
    local vless_link="vless://${user_uuid}@${server_ip}:${vl_port}?security=reality&encryption=none&pbk=${vl_pubkey}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${vl_sni}&sid=${vl_shortid}#${node_prefix}-VLESS-Reality"
    local links_out="${WEB_DIR}/${token}/links.txt"
    echo "$vless_link" > "$links_out"

    local insecure_flag="0"
    [[ "$hy_skip_cert" == "true" ]] && insecure_flag="1"
    local mport_param=""
    [[ -n "$hy_ports_display" && "$hy_ports_display" == *,* ]] && mport_param="&mport=${hy_ports_display}"
    local hy2_link="hy2://${hy_password}@${domain_or_ip}:${hy_port}/?sni=${domain_or_ip}&insecure=${insecure_flag}${mport_param}#${node_prefix}-Hysteria2"
    echo "$hy2_link" >> "$links_out"
    cp -f "$links_out" "$LINKS_FILE"
}

# 注册全局 simbo 指令（兼容 bash <(curl ...) 管道执行）
install_simbo_command() {
    local share_dir="/usr/local/share/simple-box"
    local target="${share_dir}/simple-box.sh"

    mkdir -p "$share_dir"

    # 仅当 $0 确实是一个真实的脚本文件时才复制（管道执行时 $0 为 bash，不能复制）
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" && -r "${BASH_SOURCE[0]}" ]]; then
        install -m 755 "${BASH_SOURCE[0]}" "$target" 2>/dev/null \
            || cp -f "${BASH_SOURCE[0]}" "$target" 2>/dev/null || true
    fi

    # 管道执行（$0 为 /dev/fd/xx）或复制失败时，从仓库拉取一份落地
    if [[ ! -s "$target" ]]; then
        curl -fsSL "$SCRIPT_URL" -o "$target" 2>/dev/null || true
        chmod 755 "$target" 2>/dev/null || true
    fi

    if [[ -s "$target" ]]; then
        ln -sf "$target" /usr/local/bin/simbo
        echo -e "${GREEN}已注册全局指令: simbo${PLAIN}"
    else
        echo -e "${YELLOW}未能自动注册 simbo 指令，可稍后手动: curl -fsSL <脚本地址> -o /usr/local/bin/simbo${PLAIN}"
    fi
}

# 拉取仓库最新脚本到指定路径
# 返回 0 表示拿到了一份完整可用的脚本，1 表示网络失败或内容不可信
fetch_latest_script() {
    local dest="${1:-}"
    [[ -z "$dest" ]] && return 1
    local tmp="${dest}.dl.$$"

    curl -fsSL --max-time 20 "$SCRIPT_URL" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }

    # 必须是一份完整的 bash 脚本：非空 + 语法通过 + 含标志串。
    # 否则可能把 404 页面、限流提示或半截下载当成脚本执行。
    if [[ ! -s "$tmp" ]] \
        || ! bash -n "$tmp" >/dev/null 2>&1 \
        || ! grep -q 'Simple-Box Manager' "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    mv -f "$tmp" "$dest"
}

# 主菜单选项 6：先取仓库最新脚本，有更新就切换过去再用新版继续安装
# 这样「重装」同时承担了「升级脚本」的职责，用户无需手动 curl 覆盖
reinstall_with_latest() {
    local share_dir="/usr/local/share/simple-box"
    local target="${share_dir}/simple-box.sh"
    local latest; latest=$(mktemp /tmp/simple-box.latest.XXXXXX)

    echo -e "正在检查仓库最新脚本..."
    if ! fetch_latest_script "$latest"; then
        echo -e "${YELLOW}获取最新脚本失败（网络不通或被限流），将用当前版本继续重装。${PLAIN}"
        rm -f "$latest"
        install_node || true
        return 0
    fi

    if [[ -f "$target" ]] && cmp -s "$latest" "$target"; then
        echo -e "${GREEN}当前已是最新脚本，直接重装。${PLAIN}"
        rm -f "$latest"
        install_node || true
        return 0
    fi

    echo -e "${GREEN}检测到仓库有新版本，正在更新脚本...${PLAIN}"
    mkdir -p "$share_dir"
    if ! install -m 755 "$latest" "$target" 2>/dev/null && ! cp -f "$latest" "$target"; then
        echo -e "${RED}脚本更新失败（磁盘只读？），将用当前版本继续重装。${PLAIN}"
        rm -f "$latest"
        install_node || true
        return 0
    fi
    chmod 755 "$target" 2>/dev/null || true
    rm -f "$latest"
    ln -sf "$target" /usr/local/bin/simbo

    echo -e "${GREEN}脚本已更新，正在用新版本继续安装...${PLAIN}"
    # 用新脚本接管当前进程：确保后续交互逻辑与提示都来自新版本，
    # 而不是内存里这份旧代码（否则装完菜单仍是旧的）
    exec bash "$target" install
}

# 部署与配置主函数
# 集中生成 sing-box 服务端配置文件
write_singbox_config() {
    local vl_port="${1:-}"
    local vl_sni="${2:-}"
    local user_uuid="${3:-}"
    local vl_privkey="${4:-}"
    local vl_shortid="${5:-}"
    local hy_port="${6:-}"
    local hy_password="${7:-}"

    # 先写临时文件再原子替换，避免 sing-box 文件监视器读到半截 JSON
    # mktemp 天然 0600：配置含 Reality 私钥与 Hy2 密码，权限来自创建方式而非事后补救
    local tmp_conf
    tmp_conf=$(mktemp "${CONF_FILE}.tmp.XXXXXX")
    cat > "$tmp_conf" <<EOF
{
  "log": {
    "disabled": false,
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "listen_port": ${vl_port},
      "users": [
        {
          "uuid": "${user_uuid}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${vl_sni}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${vl_sni}",
            "server_port": 443
          },
          "private_key": "${vl_privkey}",
          "short_id": [
            "${vl_shortid}"
          ]
        }
      }
    }
EOF

    cat >> "$tmp_conf" <<EOF
    ,
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "0.0.0.0",
      "listen_port": ${hy_port},
      "users": [
        {
          "password": "${hy_password}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_DIR}/fullchain.cer",
        "key_path": "${CERT_DIR}/private.key"
      }
    }
EOF

    cat >> "$tmp_conf" <<EOF
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    mv -f "$tmp_conf" "$CONF_FILE"
}

# 集中写入持久化环境变量
write_env_config() {
    # 关键字段必须非空：这些值由调用方在函数内用 local 搬运，漏搬一行就会静默
    # 写入空串（曾导致 NODE_PREFIX="" 让节点名变成 "-VLESS-Reality"）。
    # 这里显式拦住，宁可报错也不写坏配置。
    local missing_keys="" v
    for v in node_prefix server_ip vl_port vl_sni user_uuid vl_privkey vl_pubkey \
             vl_shortid hy_port hy_password sub_port sub_token; do
        [[ -z "${!v:-}" ]] && missing_keys="${missing_keys} ${v}"
    done
    if [[ -n "$missing_keys" ]]; then
        echo -e "${RED}内部错误: 环境变量缺失 (${missing_keys# })，已中止写入 ${ENV_FILE}。${PLAIN}" >&2
        return 1
    fi

    # 600：env.conf 含 Reality 私钥、Hy2 密码、订阅 Token，不能给其它本地用户读
    ( umask 077; cat > "$ENV_FILE" <<EOF
NODE_PREFIX="${node_prefix}"
SERVER_IP="${server_ip}"
VL_PORT="${vl_port}"
VL_SNI="${vl_sni}"
VL_UUID="${user_uuid}"
VL_PRIVKEY="${vl_privkey}"
VL_PUBKEY="${vl_pubkey}"
VL_SHORTID="${vl_shortid}"
HY_DOMAIN="${hy_domain}"
TARGET_HOST="${target_host}"
HY_PORT="${hy_port}"
HY_RANGE="${hy_range}"
HY_PASS="${hy_password}"
HY_SKIP_CERT="${hy_skip_cert}"
SUB_PORT="${sub_port}"
SUB_PROTO="${sub_proto}"
SUB_TOKEN="${sub_token}"
CERT_MODE="${CERT_MODE:-selfsigned}"
EOF
    )
    chmod 600 "$ENV_FILE" 2>/dev/null || true
}

# 校验 sing-box 配置、重启并全量刷新客户端文件与 Caddy 订阅
render_and_reload() {
    if [[ ! -x /usr/local/bin/sing-box ]]; then
        echo -e "${RED}未找到 sing-box 内核，无法应用配置。${PLAIN}"
        return 1
    fi

    # 不做配置回滚：调用方已经用 write_singbox_config 把新配置 mv 到正式位置，
    # 此处再备份只会备份到「刚写入的新配置」，回滚等于把坏配置复制回自己。
    # 与其保留一个假的保护，不如直接失败并要求重装（重装会用同一份输入重建）。
    if ! /usr/local/bin/sing-box check -c "$CONF_FILE" >/dev/null 2>&1; then
        echo -e "${RED}sing-box 配置校验失败，服务未启动。${PLAIN}"
        /usr/local/bin/sing-box check -c "$CONF_FILE" 2>&1 | tail -3 || true
        echo -e "${YELLOW}请重新运行本脚本并选择「脚本升级 / 重装」重建配置。${PLAIN}"
        return 1
    fi

    if systemctl is-active --quiet sing-box 2>/dev/null; then
        systemctl restart sing-box 2>/dev/null || { echo -e "${RED}sing-box 重启失败，请查看: journalctl -u sing-box -n 30${PLAIN}"; return 1; }
    else
        systemctl start sing-box 2>/dev/null || { echo -e "${RED}sing-box 启动失败，请查看: journalctl -u sing-box -n 30${PLAIN}"; return 1; }
    fi
    sleep 1
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then
        echo -e "${RED}sing-box 未能进入运行状态，请查看: journalctl -u sing-box -n 30${PLAIN}"
        return 1
    fi

    local hy_ports_display="$hy_port"
    [[ -n "$hy_range" ]] && hy_ports_display="${hy_port},${hy_range/:/-}"
    generate_full_client_config "$target_host" "$sub_token" "$node_prefix" "$server_ip" "$vl_port" "$user_uuid" "$vl_sni" "$vl_pubkey" "$vl_shortid" "$hy_port" "$hy_ports_display" "$hy_password" "$hy_skip_cert"

    setup_caddy_subscription "$target_host" "$sub_token" "$sub_port" "$CERT_MODE"
    reload_caddy_safe || true
    verify_caddy_listening "$sub_port" || true
}

install_node() {
    if ! require_os >/dev/null; then
        return 1
    fi
    if ! require_arch >/dev/null; then
        return 1
    fi

    if ! install_deps; then
        echo -e "${RED}基础依赖检查未通过，安装中止。${PLAIN}"
        return 1
    fi

    if [[ ! -f /usr/local/bin/sing-box ]]; then
        update_singbox_core "force" || { echo -e "${RED}内核安装失败，无法继续。${PLAIN}"; return 1; }
    fi

    mkdir -p "$CONF_DIR" "$WEB_DIR"

    # 读取既有配置，作为重置时的默认值（直接回车即沿用）
    local old_vl_port="" old_vl_sni="" old_hy_port="" old_hy_range="" old_sub_port="" old_prefix="" old_domain=""
    if [[ -f "$ENV_FILE" ]]; then
        set +e; source "$ENV_FILE"; set -e
        old_vl_port="$VL_PORT"; old_vl_sni="$VL_SNI"; old_hy_port="$HY_PORT"
        old_hy_range="$HY_RANGE"; old_sub_port="$SUB_PORT"; old_prefix="$NODE_PREFIX"
        old_domain="${HY_DOMAIN:-}"
        # 若 env.conf 中无域名记录，探测 acme.sh 目录中是否曾签发过历史域名证书
        if [[ -z "$old_domain" ]] && [[ -d "$HOME/.acme.sh" ]]; then
            local acme_d
            acme_d=$(find "$HOME/.acme.sh" -maxdepth 1 -type d -name "*_ecc" 2>/dev/null | head -n1)
            if [[ -n "$acme_d" ]]; then
                local found_d
                found_d=$(basename "$acme_d" | sed 's/_ecc$//')
                if validate_domain "$found_d"; then
                    old_domain="$found_d"
                fi
            fi
        fi
    fi

    local server_ip
    server_ip=$(curl -s4m5 https://icanhazip.com || curl -s4m5 https://api.ipify.org || true)
    server_ip=${server_ip:-}
    if ! [[ "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}无法探测本机公网 IPv4（curl icanhazip/ipify 均失败）。${PLAIN}"
        echo -e "${YELLOW}自签证书需要真实公网 IP，请检查网络后重试。${PLAIN}"
        return 1
    fi

    echo -e "\n${GRAY}----------------------------------------------------${PLAIN}"
    echo -e "${BOLD}[1/3] 配置 VLESS-Reality 参数${PLAIN}"
    echo -e "${GRAY}----------------------------------------------------${PLAIN}"
    local vl_port
    while true; do
        read -r -p "请输入 Reality 监听端口 [默认: ${CYAN}${old_vl_port:-443}${PLAIN}]: " vl_port || vl_port=""
        vl_port=$(trim_string "${vl_port:-${old_vl_port:-443}}")
        if ! validate_port "$vl_port"; then
            echo -e "${RED}端口非法（应为 1-65535 的整数），请重新输入。${PLAIN}"; continue
        fi
        check_port_conflict "$vl_port" "tcp" "vless" && break
    done
    # 写入全局，供后续 hy_port / sub_port 的冲突校验比较（新建时 env.conf 里还没有值）
    VL_PORT="$vl_port"

    local vl_sni
    while true; do
        read -r -p "请输入 Reality 借壳伪装域名 [默认: ${CYAN}${old_vl_sni:-gateway.icloud.com}${PLAIN}]: " vl_sni || vl_sni=""
        vl_sni=$(trim_string "$vl_sni")
        vl_sni=${vl_sni:-${old_vl_sni:-gateway.icloud.com}}
        if [[ "$vl_sni" == "$server_ip" ]]; then
            echo -e "${RED}Reality 伪装域名不能是本机 IP，请重新输入！${PLAIN}"; continue
        fi
        if ! validate_domain "$vl_sni"; then
            echo -e "${RED}域名格式非法（示例: gateway.icloud.com），请重新输入！${PLAIN}"; continue
        fi
        break
    done

    echo -e "\n${GRAY}----------------------------------------------------${PLAIN}"
    echo -e "${BOLD}[2/3] 配置 Hysteria 2 参数${PLAIN}"
    echo -e "${GRAY}----------------------------------------------------${PLAIN}"
    local hy_skip_cert="false"
    local cert_fell_back=""

    local hy_domain=""

    # 1. 优先检测本地已存在的域名配置
    if [[ -n "$old_domain" ]]; then
        echo -e "检测到当前已配置域名: ${CYAN}${old_domain}${PLAIN}"
        local reuse_domain=""
        read -r -p "是否继续使用此域名？Y/n (回车沿用，输入 n 更换域名或使用 IP): " reuse_domain || reuse_domain=""
        if [[ -z "$reuse_domain" || "${reuse_domain,,}" == "y" || "${reuse_domain,,}" == "yes" ]]; then
            hy_domain="$old_domain"
            echo -e "已选择沿用当前域名: ${hy_domain}"
            if ! check_domain_ip_binding "$hy_domain" "$server_ip"; then
                hy_domain=""
            fi
        fi
    fi

    # 2. 若无已配置域名，或用户输入 n 放弃沿用，则提示输入
    if [[ -z "$hy_domain" ]]; then
        echo -e "提示:"
        echo -e "  • 使用自有域名: 需在 Cloudflare 将 A 记录解析至本机公网 IP (${CYAN}${server_ip}${PLAIN})"
        echo -e "  • Cloudflare 代理状态必须为【仅限 DNS】(灰色云朵)，开启小黄云会阻断 UDP"
        echo -e "  • 直接回车 = 使用 IP 自签证书（10 年 ECC，客户端自动开启跳过证书校验）"

        while true; do
            read -r -p "请输入域名 [回车=IP自签]: " hy_domain || hy_domain=""
            hy_domain=$(trim_string "$hy_domain")

            case "${hy_domain,,}" in
                ""|ip|self|selfsigned) hy_domain=""; break ;;
            esac

            if ! validate_domain "$hy_domain"; then
                echo -e "${RED}域名格式非法: ${hy_domain}（示例: node.example.com）${PLAIN}"
                continue
            fi
            if ! check_domain_ip_binding "$hy_domain" "$server_ip"; then
                echo -e "${YELLOW}请重新输入域名，或直接回车使用 IP 自签。${PLAIN}"
                continue
            fi
            break
        done
    fi

    local target_host="$hy_domain"
    local cf_token=""

    if [[ -z "$hy_domain" ]]; then
        echo -e "${YELLOW}未输入域名，自动启用自签证书模式 (IP 直连 + skip-cert-verify)。${PLAIN}"
        target_host="$server_ip"
        hy_skip_cert="true"
    else
        target_host="$hy_domain"
        # 支持预置 CF_TOKEN 环境变量（无人值守部署）；必须同步到局部变量，否则会静默降级为自签
        if [[ -n "${CF_TOKEN:-}" ]]; then
            cf_token="$CF_TOKEN"
        fi

        # 检查本地是否已有「确实覆盖该域名」且配对有效的证书：若是，可免输 Token 直接复用
        local reuse_local_cert=false
        if cert_covers_domain "$hy_domain"; then
            reuse_local_cert=true
            echo -e "${GREEN}检测到本地已有 ${hy_domain} 的有效证书，已自动复用（免输 CF Token）。${PLAIN}"
        fi

        if [[ -z "$cf_token" && "$reuse_local_cert" != "true" ]]; then
            if prompt_cf_token; then
                cf_token="$PROMPTED_CF_TOKEN"
            else
                cf_token=""
                target_host="$server_ip"
                hy_skip_cert="true"
                hy_domain=""
                cert_fell_back="true"
            fi
        fi
    fi

    local hy_port="8443"
    local hy_range="20000:40000"
    while true; do
        read -r -p "请输入 Hysteria 2 主监听 UDP 端口 [默认: ${CYAN}${old_hy_port:-8443}${PLAIN}]: " hy_port || hy_port=""
        hy_port=$(trim_string "${hy_port:-${old_hy_port:-8443}}")
        if ! validate_port "$hy_port"; then
            echo -e "${RED}端口非法（应为 1-65535 的整数），请重新输入。${PLAIN}"; continue
        fi
        check_port_conflict "$hy_port" "udp" "hy2" "" && break
    done
    HY_PORT="$hy_port"

    while true; do
        read -r -p "请输入端口跳跃范围 [默认: ${CYAN}${old_hy_range:-20000:40000}${PLAIN}] (none=不启用): " hy_range || hy_range=""
        hy_range=$(trim_string "${hy_range:-${old_hy_range:-20000:40000}}")
        [[ "${hy_range,,}" == "none" ]] && { hy_range=""; break; }
        if ! validate_range "$hy_range"; then
            echo -e "${RED}范围格式非法，应为 起始:结束（如 20000:40000）。${PLAIN}"; continue
        fi
        check_range_conflict "$hy_range" && break
    done
    HY_RANGE="$hy_range"

    echo -e "\n${GRAY}----------------------------------------------------${PLAIN}"
    echo -e "${BOLD}[3/3] 配置在线订阅与节点参数${PLAIN}"
    echo -e "${GRAY}----------------------------------------------------${PLAIN}"
    local sub_port
    while true; do
        read -r -p "请输入 Caddy 订阅监听端口 [默认: ${CYAN}${old_sub_port:-8444}${PLAIN}]: " sub_port || sub_port=""
        sub_port=$(trim_string "${sub_port:-${old_sub_port:-8444}}")
        if ! validate_port "$sub_port"; then
            echo -e "${RED}端口非法（应为 1-65535 的整数），请重新输入。${PLAIN}"; continue
        fi
        check_port_conflict "$sub_port" "tcp" "sub" && break
    done

    local node_prefix
    read -r -p "请输入节点名称前缀 (如 HK / US / JP) [默认: ${CYAN}${old_prefix:-Node}${PLAIN}]: " node_prefix || node_prefix=""
    node_prefix=$(trim_string "${node_prefix:-${old_prefix:-Node}}")
    # 去掉会破坏 YAML/URI 的字符（引号、逗号、井号、冒号、反斜杠）
    node_prefix=$(printf '%s' "$node_prefix" | tr -d '\"'"'"',#:\\')
    [[ -z "$node_prefix" ]] && node_prefix="Node"

    # 证书重生成前先停 sing-box，避免文件监视器读到写入中途的 cert/key 组合
    if systemctl is-active --quiet sing-box; then
        systemctl stop sing-box 2>/dev/null || true
    fi

    # 签发证书（域名走 CF DNS API，无域名走 10 年 IP ECC 自签）
    if ! issue_cert_bundle "$hy_domain" "$cf_token" "$server_ip"; then
        systemctl start sing-box 2>/dev/null || true
        echo -e "${RED}证书阶段失败，已恢复原有 sing-box 服务，安装中止。${PLAIN}"
        return 1
    fi
    if [[ "$CERT_MODE" == "domain" ]]; then
        hy_skip_cert="false"
        target_host="$hy_domain"
    else
        hy_skip_cert="true"
        target_host="$server_ip"
        if [[ -n "$hy_domain" ]]; then
            hy_domain=""          # 已降级，清除域名避免后续误用
            cert_fell_back="true"
        fi
    fi

    # 生成密钥凭证（任一步失败都必须中止，否则空值会写进配置导致服务起不来）
    echo -e "生成安全密钥凭证..."
    local key_pair vl_privkey vl_pubkey vl_shortid user_uuid hy_password sub_token
    key_pair=$(/usr/local/bin/sing-box generate reality-keypair) || {
        echo -e "${RED}Reality 密钥对生成失败，已中止。${PLAIN}"; return 1; }
    vl_privkey=$(echo "$key_pair" | awk '/PrivateKey/{print $2}')
    vl_pubkey=$(echo "$key_pair" | awk '/PublicKey/{print $2}')
    vl_shortid=$(/usr/local/bin/sing-box generate rand 8 --hex) || vl_shortid=""
    user_uuid=$(/usr/local/bin/sing-box generate uuid) || user_uuid=""
    hy_password=$(/usr/local/bin/sing-box generate rand 16 --base64 | tr -dc 'a-zA-Z0-9' | head -c 16) || hy_password=""
    sub_token=$(openssl rand -hex 12) || sub_token=""
    if [[ -z "$vl_privkey" || -z "$vl_pubkey" || -z "$vl_shortid" || -z "$user_uuid" || -z "$sub_token" ]]; then
        echo -e "${RED}关键凭证生成不完整（privkey/uuid/shortid/token 有空值），已中止安装。${PLAIN}"
        return 1
    fi
    if [[ -z "$hy_password" ]]; then
        echo -e "${RED}Hysteria 2 密码生成失败，已中止安装。${PLAIN}"
        return 1
    fi

    # 防火墙精准放行
    if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
        ufw allow "$vl_port/tcp" >/dev/null 2>&1 || true
        ufw allow "$hy_port/udp" >/dev/null 2>&1 || true
    fi
    # 先清理本脚本可能遗留的端口跳跃规则，再按当前配置重建
    clear_port_hopping
    if [[ -n "$hy_range" ]]; then
        setup_port_hopping "$hy_port" "$hy_range"
    fi

    local sub_proto="http"
    [[ "$CERT_MODE" == "domain" ]] && sub_proto="https"

    write_singbox_config "$vl_port" "$vl_sni" "$user_uuid" "$vl_privkey" "$vl_shortid" "$hy_port" "$hy_password"
    if ! write_env_config; then
        echo -e "${RED}环境配置写入失败，安装中止。${PLAIN}"
        return 1
    fi
    enable_bbr

    # 配置 systemd 服务
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c ${CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    # 启动前先做配置校验，避免带病重启导致服务起不来
    if ! /usr/local/bin/sing-box check -c "$CONF_FILE" >/dev/null 2>&1; then
        echo -e "${RED}生成的配置未通过 sing-box check 校验，已中止启动。${PLAIN}"
        /usr/local/bin/sing-box check -c "$CONF_FILE" || true
        return 1
    fi

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
    if ! systemctl restart sing-box; then
        echo -e "${RED}sing-box 启动失败，请查看: journalctl -u sing-box -n 50${PLAIN}"
        return 1
    fi

    install_simbo_command

    # 部署 Caddy 订阅并组装完整客户端配置
    local hy_ports_display="$hy_port"
    [[ -n "$hy_range" ]] && hy_ports_display="${hy_port},${hy_range/:/-}"
    generate_full_client_config "$target_host" "$sub_token" "$node_prefix" "$server_ip" "$vl_port" "$user_uuid" "$vl_sni" "$vl_pubkey" "$vl_shortid" "$hy_port" "$hy_ports_display" "$hy_password" "$hy_skip_cert"
    setup_caddy_subscription "$target_host" "$sub_token" "$sub_port" "$CERT_MODE"

    if [[ "${cert_fell_back:-}" == "true" ]]; then
        echo -e "${YELLOW}注意: 本次因域名证书申请失败已回退为 IP 自签证书，客户端已自动设为 skip-cert-verify。${PLAIN}"
    fi

    echo -e "\n${GRAY}====================================================${PLAIN}"
    echo -e " ${GREEN}✓${PLAIN} ${BOLD}Simple-Box 安装就绪！${PLAIN}"
    echo -e " 随时在终端输入 ${CYAN}simbo${PLAIN} 即可打开控制台。"
    echo -e "${GRAY}====================================================${PLAIN}\n"
}

# 展示单独节点链接与二维码
show_links() {
    # 每次都按 env.conf 现算一遍，不缓存：
    # 曾经按 mtime 判断是否陈旧，但升级脚本后 links.txt 仍是旧格式（如 hysteria2://），
    # 而它的 mtime 比 env.conf 新，于是永远不重算，用户看到的还是旧链接。
    # 这里无网络开销、纯本地拼字符串，直接重算最稳。
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未找到节点环境配置，请先执行安装！${PLAIN}"
        return 1
    fi
    set +e; source "$ENV_FILE"; set -e
    local hy_ports_display="${HY_PORT}"
    [[ -n "${HY_RANGE:-}" ]] && hy_ports_display="${HY_PORT},${HY_RANGE/:/-}"
    local host=${TARGET_HOST:-${HY_DOMAIN:-$SERVER_IP}}
    local vless_link="vless://${VL_UUID}@${SERVER_IP}:${VL_PORT}?security=reality&encryption=none&pbk=${VL_PUBKEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${VL_SNI}&sid=${VL_SHORTID}#${NODE_PREFIX}-VLESS-Reality"
    local insecure_flag="0"
    [[ "${HY_SKIP_CERT:-false}" == "true" ]] && insecure_flag="1"
    local mport_param=""
    [[ -n "$hy_ports_display" && "$hy_ports_display" == *,* ]] && mport_param="&mport=${hy_ports_display}"
    local hy2_link="hy2://${HY_PASS}@${host}:${HY_PORT}/?sni=${host}&insecure=${insecure_flag}${mport_param}#${NODE_PREFIX}-Hysteria2"

    # 两处都要写：$LINKS_FILE 是本地工作副本，WEB_DIR/$SUB_TOKEN/links.txt 才是
    # 订阅对外提供的文件（客户端可能拉它）。只写前者会导致面板显示新格式、
    # 订阅端仍是旧格式，两边不一致。
    printf '%s\n%s\n' "$vless_link" "$hy2_link" > "$LINKS_FILE"
    local web_links="${WEB_DIR}/${SUB_TOKEN}/links.txt"
    if [[ -d "${WEB_DIR}/${SUB_TOKEN}" ]]; then
        printf '%s\n%s\n' "$vless_link" "$hy2_link" > "$web_links" 2>/dev/null || true
        chmod 644 "$web_links" 2>/dev/null || true
    fi

    local vless_url="$vless_link"
    local hy2_url="$hy2_link"

    echo -e "\n${GRAY}==================== vless / hy2 原生链接 ====================${PLAIN}"
    echo -e " [1] vless 链接:"
    echo -e " ${CYAN}${vless_url}${PLAIN}"
    if command -v qrencode &>/dev/null; then
        echo -e "\n [vless 二维码]:"
        qrencode -t ANSIUTF8 "${vless_url}"
    fi

    if [[ -n "$hy2_url" ]]; then
        echo -e "\n${GRAY}--------------------------------------------------------------${PLAIN}"
        echo -e " [2] hy2 链接:"
        echo -e " ${CYAN}${hy2_url}${PLAIN}"
        if command -v qrencode &>/dev/null; then
            echo -e "\n [hy2 二维码]:"
            qrencode -t ANSIUTF8 "${hy2_url}"
        fi
    fi
    echo -e "${GRAY}==============================================================${PLAIN}\n"
    read -r -p "按回车键返回主菜单..." dummy || true
}

# 彻底干净卸载
uninstall_all() {
    echo -e "${YELLOW}警告: 即将彻底卸载 sing-box 并清除所有节点、订阅与证书配置！${PLAIN}"
    echo -e "${YELLOW}      同时会删除 ${CONF_DIR}、/usr/local/share/simple-box 以及 simbo 入口本身。${PLAIN}"
    local confirm=""
    read -r -p "确认卸载吗？(y/N): " confirm || confirm=""
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "已取消。" && return 0

    echo -e "正在停止并移除服务..."
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload

    if [[ -f "$ENV_FILE" ]]; then
        set +e; source "$ENV_FILE"; set -e
        if [[ -n "${HY_RANGE:-}" && -n "${HY_PORT:-}" ]]; then
            echo -e "精准清理端口跳跃规则..."
            iptables -t nat -D PREROUTING -p udp --dport "$HY_RANGE" -j REDIRECT --to-ports "$HY_PORT" 2>/dev/null || true
            # 清理历史版本可能遗留的 IPv6 规则
            if command -v ip6tables &>/dev/null; then
                ip6tables -t nat -D PREROUTING -p udp --dport "$HY_RANGE" -j REDIRECT --to-ports "$HY_PORT" 2>/dev/null || true
            fi
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save >/dev/null 2>&1 || true
            fi
        fi
        rm -f /etc/caddy/sites/*-"${SUB_PORT:-8444}".caddy /etc/caddy/sites/simple-box*.caddy
        systemctl reload caddy 2>/dev/null || true
    fi

    # 清理 acme.sh 中本机签发的续期任务（仅当存在 acme.sh 时）
    if [[ -x "$HOME/.acme.sh/acme.sh" && -f "$ENV_FILE" ]]; then
        local un_domain
        un_domain=$(grep -oP '^HY_DOMAIN="\K[^"]*' "$ENV_FILE" 2>/dev/null || true)
        if [[ -n "$un_domain" ]]; then
            "$HOME/.acme.sh/acme.sh" --remove -d "$un_domain" --ecc >/dev/null 2>&1 || true
        fi
    fi

    rm -f /usr/local/bin/sing-box
    rm -f /usr/local/bin/sing-box.bak.* 2>/dev/null || true
    rm -f /usr/local/bin/simbo
    rm -rf /usr/local/share/simple-box

    # ---- Caddy 收尾 ----
    # 站点配置一律删除；Caddyfile 中的 import 行只在「本脚本加的」才回退；
    # 软件包只在「本脚本装的」才卸载，避免误删用户原有的 caddy。
    local caddy_owned=false caddyfile_created=false caddyfile_appended=false
    [[ -f "${CONF_DIR}/.caddy_installed_by_script" ]] && caddy_owned=true
    [[ -f "${CONF_DIR}/.caddyfile_created_by_script" ]] && caddyfile_created=true
    [[ -f "${CONF_DIR}/.caddyfile_appended_by_script" ]] && caddyfile_appended=true

    # 关键判定：sites 目录里是否还有「不是本脚本的」站点。
    # 场景：脚本装了 caddy（有归属标记），用户后来用这个 caddy 跑了自己的服务。
    # 此时若直接删包，用户的站点会全部停摆 —— 必须降级为「只删本站点」。
    local foreign_sites=0
    if [[ -d /etc/caddy/sites ]]; then
        foreign_sites=$(find /etc/caddy/sites -maxdepth 1 -type f \
            ! -name 'simple-box*' ! -name "*-${SUB_PORT:-8444}.caddy" 2>/dev/null | wc -l)
    fi
    if [[ "$foreign_sites" -gt 0 ]]; then
        caddy_owned=false
        echo -e "${YELLOW}检测到 /etc/caddy/sites 下还有 ${foreign_sites} 个其它站点配置，${PLAIN}"
        echo -e "${YELLOW}说明 Caddy 已承载你自己的服务，将保留软件包与 Caddyfile，仅移除本脚本的订阅地址。${PLAIN}"
    fi

    if [[ "$caddy_owned" == "true" && "$caddyfile_created" == "true" ]]; then
        # 包是本脚本装的、Caddyfile 也是本脚本建的：一并删除（包已卸载，无副作用）
        rm -f /etc/caddy/Caddyfile
        echo -e "已移除本脚本创建的 Caddyfile"
    elif [[ "$caddyfile_created" == "true" || "$caddyfile_appended" == "true" ]]; then
        # Caddy 归用户使用（原有的，或已被用户接管）：只回退本脚本加的 import 行。
        # 有用户站点时 import 必须留着，否则用户的站点不会生效。
        if [[ "$foreign_sites" -gt 0 ]]; then
            echo -e "${CYAN}保留 Caddyfile 中的 import sites/*.caddy（你自己的站点依赖它生效）${PLAIN}"
        elif [[ -f /etc/caddy/Caddyfile ]]; then
            sed -i '\|^import sites/\*\.caddy$|d' /etc/caddy/Caddyfile
            sed -i -e :a -e '/^\n*$/{$d;N;};/\n$/ba' /etc/caddy/Caddyfile 2>/dev/null || true
            echo -e "已回退本脚本追加的 Caddyfile import 行"
        fi
    fi

    if [[ "$caddy_owned" == "true" ]]; then
        echo -e "正在卸载本脚本安装的 Caddy..."
        # 必须 purge 而非 remove：caddy.postrm 的 remove 分支会 mask 服务且不解除，
        # 留下 rc 残留状态，下次重装时 caddy.service 仍是 masked，永远起不来。
        # purge 分支才会 unmask 并清掉 /etc/caddy 与 /var/lib/caddy。
        #
        # DEBIAN_FRONTEND=noninteractive + force-confold 不能省：
        # /etc/caddy/Caddyfile 被本脚本改过，purge 时 dpkg 会弹 conffile 询问；
        # 无人应答（脚本里 stdin 是管道）就会报 "end of file on stdin at conffile
        # prompt"，把包卡在 iU 半安装状态，之后任何 apt 操作都失败。
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
            -o Dpkg::Options::="--force-confold" caddy >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq >/dev/null 2>&1 || true
        # apt remove 不删配置目录：只清理本脚本创建的站点文件，
        # 目录为空才 rmdir —— 用户后来自己加的站点配置必须保留。
        rm -f /etc/caddy/sites/simple-box*.caddy /etc/caddy/sites/*-"${SUB_PORT:-8444}".caddy 2>/dev/null || true
        rmdir /etc/caddy/sites 2>/dev/null || true
        rmdir /etc/caddy 2>/dev/null || true
        echo -e "已卸载本脚本安装的 Caddy 软件包"
    elif command -v caddy &>/dev/null; then
        systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
        if [[ "$foreign_sites" -gt 0 ]]; then
            echo -e "${CYAN}Caddy 保留运行，你的 ${foreign_sites} 个站点未受影响${PLAIN}"
        else
            echo -e "${CYAN}Caddy 为系统预装/他处安装，仅移除本站点配置，软件包保留${PLAIN}"
        fi
    fi

    rm -rf "$CONF_DIR"

    echo -e "${GREEN}sing-box 与订阅配置已彻底干净卸载！${PLAIN}"
    echo -e "${YELLOW}本脚本自身的入口 (simbo) 也已删除，控制台即将退出。${PLAIN}"
    echo -e "${YELLOW}如需重装，请重新执行一键安装命令。${PLAIN}"
    disable_bbr
    # 卸载后目录与入口都已不存在，继续停留在菜单毫无意义（面板还会读到已删除的配置）
    UNINSTALL_DONE=true
}

# 交互控制台主循环

# ==================== 模块化独立子菜单 ====================

# 1. VLESS-Reality 独立模块配置
menu_reality_module() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未检测到已安装的配置，请先运行选项 6 重新安装Simple-Box！${PLAIN}"
        read -r -p "按回车键返回..." dummy || true
        return 0
    fi
    set +e; source "$ENV_FILE"; set -e

    while true; do
        [ -t 1 ] && clear
        echo -e "
${GRAY}================= VLESS-Reality 模块配置 =================${PLAIN}"
        echo -e " 1. 重置并更新 VLESS-Reality 参数"
        echo -e " 0. 返回主菜单"
        echo -e "${GRAY}==========================================================${PLAIN}"
        local opt=""
        read -r -p "请输入选项 [0-1]: " opt || opt=""
        case "$opt" in
            1)
                echo -e "\n${YELLOW}=== 重置 VLESS-Reality 参数 ===${PLAIN}"
                local vl_port
                while true; do
                    read -r -p "请输入 Reality 监听端口 [默认: ${CYAN}${VL_PORT}${PLAIN}]: " vl_port || vl_port=""
                    vl_port=$(trim_string "${vl_port:-${VL_PORT}}")
                    if ! validate_port "$vl_port"; then
                        echo -e "${RED}端口非法（应为 1-65535 的整数），请重新输入。${PLAIN}"; continue
                    fi
                    # 端口未变 = 沿用当前配置，无需重新检测占用
                    [[ "$vl_port" == "$VL_PORT" ]] && break
                    check_port_conflict "$vl_port" "tcp" "vless" && break
                done

                local vl_sni
                while true; do
                    read -r -p "请输入 Reality 伪装域名 (SNI) [默认: ${CYAN}${VL_SNI}${PLAIN}]: " vl_sni || vl_sni=""
                    vl_sni=$(trim_string "${vl_sni:-${VL_SNI}}")
                    if ! validate_domain "$vl_sni"; then
                        echo -e "${RED}伪装域名格式非法（示例: gateway.icloud.com），请重新输入。${PLAIN}"; continue
                    fi
                    if [[ "$vl_sni" == "$SERVER_IP" ]]; then
                        echo -e "${RED}伪装域名不能是本机 IP，必须为可正常 TLS1.3 握手的站点。${PLAIN}"; continue
                    fi
                    break
                done

                echo -e "生成新的 Reality 密钥凭证..."
                local key_pair
                key_pair=$(/usr/local/bin/sing-box generate reality-keypair)
                local vl_privkey vl_pubkey vl_shortid user_uuid
                vl_privkey=$(echo "$key_pair" | awk '/PrivateKey/{print $2}')
                vl_pubkey=$(echo "$key_pair" | awk '/PublicKey/{print $2}')
                vl_shortid=$(/usr/local/bin/sing-box generate rand 8 --hex)
                user_uuid=$(/usr/local/bin/sing-box generate uuid)

                local node_prefix="$NODE_PREFIX"
                local server_ip="$SERVER_IP"
                local hy_domain="${HY_DOMAIN:-}"
                local target_host="${TARGET_HOST:-$server_ip}"
                local hy_port="${HY_PORT:-8443}"
                local hy_range="${HY_RANGE:-}"
                local hy_password="${HY_PASS:-}"
                local hy_skip_cert="${HY_SKIP_CERT:-true}"
                local sub_port="${SUB_PORT:-8444}"
                local sub_proto="${SUB_PROTO:-http}"
                local sub_token="${SUB_TOKEN}"
                local CERT_MODE="${CERT_MODE:-selfsigned}"

                write_singbox_config "$vl_port" "$vl_sni" "$user_uuid" "$vl_privkey" "$vl_shortid" "$hy_port" "$hy_password"
                if ! write_env_config; then
                    echo -e "${RED}环境配置写入失败，操作已中止。${PLAIN}"
                    read -r -p "按回车键返回..." dummy || true
                    continue
                fi
                if ! render_and_reload; then
                    echo -e "${RED}Reality 模块更新失败，请检查上面的错误信息。${PLAIN}"
                    read -r -p "按回车键返回..." dummy || true
                    continue
                fi

                echo -e "\n${GREEN}✓ VLESS-Reality 模块已成功更新！${PLAIN}"
                echo -e "提示: 订阅链接保持不变，客户端仅需点击「更新订阅」即可自动同步新节点。"
                read -r -p "按回车键返回..." dummy || true
                set +e; source "$ENV_FILE"; set -e
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

# 2. Hysteria 2 独立模块配置
menu_hy2_module() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未检测到已安装的配置，请先运行选项 6 重新安装Simple-Box！${PLAIN}"
        read -r -p "按回车键返回..." dummy || true
        return 0
    fi
    set +e; source "$ENV_FILE"; set -e

    while true; do
        [ -t 1 ] && clear
        echo -e "
${GRAY}=================== Hysteria 2 模块配置 ===================${PLAIN}"
        echo -e " 1. 重置并更新 Hysteria 2 参数"
        echo -e " 0. 返回主菜单"
        echo -e "${GRAY}==========================================================${PLAIN}"
        local opt=""
        read -r -p "请输入选项 [0-1]: " opt || opt=""
        case "$opt" in
            1)
                echo -e "\n${YELLOW}=== 重置 Hysteria 2 参数 ===${PLAIN}"
                local old_sub_proto="${SUB_PROTO:-http}"
                local old_target_host="${TARGET_HOST:-${HY_DOMAIN:-$SERVER_IP}}"
                local old_sub_url="${old_sub_proto}://${old_target_host}:${SUB_PORT:-8444}/${SUB_TOKEN}/config.yaml"

                local hy_domain="" cf_token=""
                local CERT_MODE="selfsigned"
                local target_host="$SERVER_IP"
                local hy_skip_cert="true"

                local old_hy_domain="${HY_DOMAIN:-}"
                # 1. 优先检测当前已配置域名
                if [[ -n "$old_hy_domain" ]]; then
                    echo -e "检测到当前已配置域名: ${CYAN}${old_hy_domain}${PLAIN}"
                    local reuse_d=""
                    read -r -p "是否继续使用该域名？Y/n (回车沿用，输入 n 更换域名或使用 IP): " reuse_d || reuse_d=""
                    if [[ -z "$reuse_d" || "${reuse_d,,}" == "y" || "${reuse_d,,}" == "yes" ]]; then
                        hy_domain="$old_hy_domain"
                        echo -e "已选择沿用当前域名: ${hy_domain}"
                        if ! check_domain_ip_binding "$hy_domain" "$SERVER_IP"; then
                            hy_domain=""
                        fi
                    fi
                fi

                # 2. 若未沿用，提示输入
                if [[ -z "$hy_domain" ]]; then
                    while true; do
                        echo -e "\n请输入自有域名 (直接回车使用 IP 自签证书):"
                        read -r -p "域名 [回车=IP自签]: " hy_domain || hy_domain=""
                        hy_domain=$(trim_string "$hy_domain")
                        if [[ -z "$hy_domain" ]]; then
                            echo -e "${GREEN}选择使用 IP 自签证书。${PLAIN}"
                            break
                        fi
                        if ! validate_domain "$hy_domain"; then
                            echo -e "${RED}域名格式不合法（示例: node.example.com），请重新输入。${PLAIN}"; continue
                        fi
                        if ! check_domain_ip_binding "$hy_domain" "$SERVER_IP"; then
                            echo -e "${YELLOW}请重新输入域名，或直接回车使用 IP 自签。${PLAIN}"
                            continue
                        fi
                        break
                    done
                fi

                if [[ -n "$hy_domain" ]]; then
                    # 检查是否可复用本地覆盖该域名的有效证书
                    local reuse_menu_cert=false
                    if cert_covers_domain "$hy_domain"; then
                        reuse_menu_cert=true
                        echo -e "${GREEN}检测到本地已有 ${hy_domain} 的有效证书，已自动复用（免输 CF Token）。${PLAIN}"
                    fi
                    if [[ "$reuse_menu_cert" != "true" ]]; then
                        if prompt_cf_token; then
                            cf_token="$PROMPTED_CF_TOKEN"
                        else
                            hy_domain=""
                            cf_token=""
                        fi
                    fi
                fi

                local hy_port
                while true; do
                    read -r -p "请输入 Hysteria 2 主监听 UDP 端口 [默认: ${CYAN}${HY_PORT:-8443}${PLAIN}]: " hy_port || hy_port=""
                    hy_port=$(trim_string "${hy_port:-${HY_PORT:-8443}}")
                    if ! validate_port "$hy_port"; then
                        echo -e "${RED}端口非法，请重新输入。${PLAIN}"; continue
                    fi
                    [[ "$hy_port" == "$HY_PORT" ]] && break
                    check_port_conflict "$hy_port" "udp" "hy2" "" && break
                done

                local hy_range
                while true; do
                    read -r -p "请输入端口跳跃范围 [默认: ${CYAN}${HY_RANGE:-20000:40000}${PLAIN}] (none=不启用): " hy_range || hy_range=""
                    hy_range=$(trim_string "${hy_range:-${HY_RANGE:-20000:40000}}")
                    [[ "${hy_range,,}" == "none" ]] && { hy_range=""; break; }
                    if ! validate_range "$hy_range"; then
                        echo -e "${RED}范围格式非法，应为 起始:结束（如 20000:40000）。${PLAIN}"; continue
                    fi
                    # HY_PORT 全局仍是旧值，临时换成本轮新选的 hy_port 参与比较，
                    # 否则改端口后仍按旧端口判断范围冲突
                    local saved_hy="${HY_PORT:-}"
                    HY_PORT="$hy_port"
                    if check_range_conflict "$hy_range"; then
                        HY_PORT="$saved_hy"; break
                    fi
                    HY_PORT="$saved_hy"
                done

                # 重签证书前必须先停 sing-box，否则文件监视器会读到「新 cert + 旧 key」
                if systemctl is-active --quiet sing-box 2>/dev/null; then
                    systemctl stop sing-box 2>/dev/null || true
                fi

                # 只要填了域名就交给 issue_cert_bundle：它内部会处理「无 Token 但本地已有
                # 覆盖该域名的有效证书」的复用场景，不能再按 cf_token 是否为空分流，
                # 否则复用证书时会被误判成自签模式，把有效域名证书覆盖掉。
                if [[ -n "$hy_domain" ]]; then
                    # issue_cert_bundle 内部会设置全局 CERT_MODE，必须以它为准而非返回码
                    issue_cert_bundle "$hy_domain" "$cf_token" "$SERVER_IP" || true
                    if [[ "$CERT_MODE" == "domain" ]]; then
                        target_host="$hy_domain"
                        hy_skip_cert="false"
                    else
                        echo -e "${YELLOW}域名证书未成功，已降级为 IP 自签证书兜底。${PLAIN}"
                        CERT_MODE="selfsigned"
                        target_host="$SERVER_IP"
                        hy_domain=""
                        hy_skip_cert="true"
                    fi
                else
                    if ! issue_self_signed_cert "$SERVER_IP"; then
                        echo -e "${RED}证书生成失败，操作中止（原配置与服务保持不变）。${PLAIN}"
                        systemctl start sing-box 2>/dev/null || true
                        read -r -p "按回车键返回..." dummy || true
                        continue
                    fi
                    CERT_MODE="selfsigned"
                    target_host="$SERVER_IP"
                    hy_domain=""
                    hy_skip_cert="true"
                fi

                local hy_password
                hy_password=$(/usr/local/bin/sing-box generate rand 16 --base64 | tr -dc 'a-zA-Z0-9' | head -c 16)

                local sub_proto="http"
                [[ "$CERT_MODE" == "domain" ]] && sub_proto="https"

                clear_port_hopping
                if [[ -n "$hy_range" ]]; then
                    setup_port_hopping "$hy_port" "$hy_range"
                fi

                local node_prefix="$NODE_PREFIX"
                local server_ip="$SERVER_IP"
                local vl_port="$VL_PORT"
                local vl_sni="$VL_SNI"
                local user_uuid="$VL_UUID"
                local vl_privkey="${VL_PRIVKEY:-}"
                local vl_pubkey="$VL_PUBKEY"
                local vl_shortid="$VL_SHORTID"
                local sub_port="$SUB_PORT"
                local sub_token="$SUB_TOKEN"

                # 老版本 env.conf 没有 VL_PRIVKEY，缺失时无法重建 Reality，必须先补齐
                if [[ -z "$vl_privkey" ]]; then
                    echo -e "${RED}环境配置缺少 Reality 私钥 (VL_PRIVKEY)，无法安全重建。${PLAIN}"
                    echo -e "${YELLOW}请进入 [2] VLESS-Reality 模块配置 重新生成一次密钥，再回到此处。${PLAIN}"
                    systemctl start sing-box 2>/dev/null || true
                    read -r -p "按回车键返回..." dummy || true
                    continue
                fi

                write_singbox_config "$vl_port" "$vl_sni" "$user_uuid" "$vl_privkey" "$vl_shortid" "$hy_port" "$hy_password"
                if ! write_env_config; then
                    echo -e "${RED}环境配置写入失败，操作已中止。${PLAIN}"
                    read -r -p "按回车键返回..." dummy || true
                    continue
                fi
                if ! render_and_reload; then
                    echo -e "${RED}Hysteria 2 模块更新失败，请检查上面的错误信息。${PLAIN}"
                    # 证书阶段可能已停服务，失败路径必须把服务拉回来
                    systemctl start sing-box 2>/dev/null || true
                    read -r -p "按回车键返回..." dummy || true
                    continue
                fi

                local new_sub_url="${sub_proto}://${target_host}:${sub_port}/${sub_token}/config.yaml"
                echo -e "\n${GREEN}✓ Hysteria 2 模块已成功更新！${PLAIN}"
                if [[ "$new_sub_url" == "$old_sub_url" ]]; then
                    echo -e "提示: 订阅链接保持不变，客户端仅需点击「更新订阅」即可自动同步新节点。"
                else
                    echo -e "${YELLOW}⚠️  提示: 域名或证书模式已变更，在线订阅地址已更新为:${PLAIN}"
                    echo -e "   ${CYAN}${new_sub_url}${PLAIN}"
                    echo -e "${YELLOW}   请在客户端 (如 Clash / Mihomo) 中替换为新的订阅地址。${PLAIN}"
                fi
                read -r -p "按回车键返回..." dummy || true
                set +e; source "$ENV_FILE"; set -e
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

# 3. 在线订阅地址独立模块配置 (结构与模块 1、2 统一)
menu_sub_module() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未检测到已安装的配置，请先运行选项 6 重新安装Simple-Box！${PLAIN}"
        read -r -p "按回车键返回..." dummy || true
        return 0
    fi
    set +e; source "$ENV_FILE"; set -e

    while true; do
        [ -t 1 ] && clear
        echo -e "
${GRAY}================= Clash 订阅地址配置 =================${PLAIN}"
        echo -e " 1. 重置并更新 Clash 订阅地址参数"
        echo -e " 2. 重置并更新节点名称前缀"
        echo -e " 0. 返回主菜单"
        echo -e "${GRAY}======================================================${PLAIN}"
        local opt=""
        read -r -p "请输入选项 [0-2]: " opt || opt=""
        case "$opt" in
            1)
                echo -e "\n${YELLOW}=== Clash 订阅地址参数 ===${PLAIN}"
                local sub_port
                while true; do
                    read -r -p "请输入新的订阅监听端口 [默认: ${CYAN}${SUB_PORT}${PLAIN}]: " sub_port || sub_port=""
                    sub_port=$(trim_string "${sub_port:-${SUB_PORT}}")
                    if ! validate_port "$sub_port"; then
                        echo -e "${RED}端口非法，请重新输入。${PLAIN}"; continue
                    fi
                    [[ "$sub_port" == "$SUB_PORT" ]] && break
                    check_port_conflict "$sub_port" "tcp" "sub" && break
                done

                local rotate_token=""
                read -r -p "是否同时刷新订阅 Token (旧链接将立即 404 作废)？[y/N]: " rotate_token || rotate_token=""
                rotate_token=$(trim_string "$rotate_token")

                local old_token="$SUB_TOKEN"
                local new_token="$SUB_TOKEN"
                if [[ "${rotate_token,,}" == "y" ]]; then
                    new_token=$(openssl rand -hex 12)
                    [[ -n "${old_token:-}" ]] && rm -rf "${WEB_DIR:?}/${old_token:?}"
                    mkdir -p "${WEB_DIR}/${new_token}"
                    echo -e "${YELLOW}Token 已轮换为新路径，旧 Token 链接已销毁。${PLAIN}"
                fi

                SUB_PORT="$sub_port"
                SUB_TOKEN="$new_token"
                # 证书模式以 env.conf 持久化的 CERT_MODE 为准（旧逻辑用 HY_SKIP_CERT 推断，
                # 在「仅 Reality」的 skip 模式下会误判成 domain，把自签证书配成 HTTPS 导致客户端导入失败）
                local CERT_MODE="${CERT_MODE:-selfsigned}"

                local node_prefix="$NODE_PREFIX"
                local server_ip="$SERVER_IP"
                local vl_port="$VL_PORT"
                local vl_sni="$VL_SNI"
                local user_uuid="$VL_UUID"
                local vl_privkey="${VL_PRIVKEY:-}"
                local vl_pubkey="$VL_PUBKEY"
                local vl_shortid="$VL_SHORTID"
                local hy_domain="${HY_DOMAIN:-}"
                local target_host="${TARGET_HOST:-$server_ip}"
                local hy_port="${HY_PORT:-8443}"
                local hy_range="${HY_RANGE:-}"
                local hy_password="${HY_PASS:-}"
                local hy_skip_cert="${HY_SKIP_CERT:-true}"
                # SUB_PROTO 必须由证书模式重新推导，不能沿用旧值（域名/自签切换后会写错协议）
                local sub_proto="http"
                [[ "$CERT_MODE" == "domain" ]] && sub_proto="https"
                local sub_token="$new_token"
                if ! write_env_config; then
                    echo -e "${RED}订阅参数写入失败，配置未变更。${PLAIN}"
                    read -r -p "按回车键返回..." dummy || true
                    continue
                fi

                local hy_ports_display="$hy_port"
                [[ -n "$hy_range" ]] && hy_ports_display="${hy_port},${hy_range/:/-}"
                generate_full_client_config "$target_host" "$new_token" "$node_prefix" "$server_ip" "$vl_port" "$user_uuid" "$vl_sni" "$vl_pubkey" "$vl_shortid" "$hy_port" "$hy_ports_display" "$hy_password" "$hy_skip_cert"

                setup_caddy_subscription "$target_host" "$new_token" "$SUB_PORT" "$CERT_MODE"
                reload_caddy_safe || true
                verify_caddy_listening "$SUB_PORT" || true

                echo -e "\n${GREEN}✓ 在线订阅地址已成功更新！${PLAIN}"
                echo -e "当前在线订阅: ${CYAN}${sub_proto}://${target_host}:${SUB_PORT}/${new_token}/config.yaml${PLAIN}"
                echo -e "${YELLOW}提示: 订阅参数已更新，请在客户端 (如 ClashX.Meta) 中修改端口或更新订阅 URL。${PLAIN}"
                read -r -p "按回车键返回..." dummy || true
                set +e; source "$ENV_FILE"; set -e
                ;;
            2)
                echo -e "\n${YELLOW}=== 重置节点名称前缀 ===${PLAIN}"
                echo -e "${CYAN}前缀用于节点显示名，如 HK-VLESS-Reality、US-Hysteria2。${PLAIN}"
                echo -e "${CYAN}会过滤引号、逗号、井号、冒号与反斜杠，避免破坏 YAML 与分享链接。${PLAIN}"
                local new_prefix=""
                while true; do
                    read -r -p "请输入节点名称前缀 [当前: ${CYAN}${NODE_PREFIX:-Node}${PLAIN}]: " new_prefix || new_prefix=""
                    new_prefix=$(trim_string "${new_prefix:-${NODE_PREFIX:-Node}}")
                    new_prefix=$(printf '%s' "$new_prefix" | tr -d '\"'"'"',#:\\')
                    if [[ -z "$new_prefix" ]]; then
                        echo -e "${RED}前缀不能为空（过滤特殊字符后为空），请重新输入。${PLAIN}"; continue
                    fi
                    break
                done

                local node_prefix="$new_prefix"
                local server_ip="$SERVER_IP"
                local vl_port="$VL_PORT"
                local vl_sni="$VL_SNI"
                local user_uuid="$VL_UUID"
                local vl_pubkey="$VL_PUBKEY"
                local vl_shortid="$VL_SHORTID"
                local vl_privkey="${VL_PRIVKEY:-}"
                local hy_domain="${HY_DOMAIN:-}"
                local target_host="${TARGET_HOST:-$server_ip}"
                local hy_port="${HY_PORT:-8443}"
                local hy_range="${HY_RANGE:-}"
                local hy_password="${HY_PASS:-}"
                local hy_skip_cert="${HY_SKIP_CERT:-true}"
                local sub_port="${SUB_PORT:-8444}"
                local sub_token="${SUB_TOKEN}"
                local CERT_MODE="${CERT_MODE:-selfsigned}"
                local sub_proto="http"
                [[ "$CERT_MODE" == "domain" ]] && sub_proto="https"

                if ! write_env_config; then
                    echo -e "${RED}节点前缀写入失败，配置未变更。${PLAIN}"
                    read -r -p "按回车键返回..." dummy || true
                    continue
                fi

                local hy_ports_display="$hy_port"
                [[ -n "$hy_range" ]] && hy_ports_display="${hy_port},${hy_range/:/-}"
                generate_full_client_config "$target_host" "$sub_token" "$node_prefix" "$server_ip" "$vl_port" "$user_uuid" "$vl_sni" "$vl_pubkey" "$vl_shortid" "$hy_port" "$hy_ports_display" "$hy_password" "$hy_skip_cert"

                echo -e "\n${GREEN}✓ 节点名称前缀已更新为: ${new_prefix}${PLAIN}"
                echo -e "提示: 订阅链接保持不变，客户端点击「更新订阅」即可同步新节点名。"
                read -r -p "按回车键返回..." dummy || true
                set +e; source "$ENV_FILE"; set -e
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

# 6. sing-box 内核管理独立模块 (合并启停、更新、日志)
menu_singbox_manage() {
    while true; do
        [ -t 1 ] && clear
        echo -e "\n${GRAY}====================== 内核管理 ======================${PLAIN}"
        echo -e " 1. 重启 / 启动 sing-box 服务"
        echo -e " 2. 检查并更新 sing-box 内核"
        echo -e " 3. 查看实时运行日志"
        echo -e " 0. 返回主菜单"
        echo -e "${GRAY}==========================================================${PLAIN}"
        local opt=""
        read -r -p "请输入选项 [0-3]: " opt || opt=""
        case "$opt" in
            1)
                if systemctl is-active --quiet sing-box 2>/dev/null; then
                    systemctl restart sing-box 2>/dev/null && echo -e "\n${GREEN}✓ sing-box 服务已成功平滑重启！${PLAIN}" || echo -e "\n${RED}重启失败${PLAIN}"
                else
                    systemctl start sing-box 2>/dev/null && echo -e "\n${GREEN}✓ sing-box 服务已成功启动！${PLAIN}" || echo -e "\n${RED}启动失败${PLAIN}"
                fi
                echo ""
                read -r -p "按回车键继续..." dummy || true
                ;;
            2)
                update_singbox_core || true
                read -r -p "按回车键返回..." dummy || true
                ;;
            3)
                echo -e "\n正在获取 sing-box 最近 40 行运行日志：\n"
                journalctl -u sing-box -o cat -n 40 --no-pager || true
                echo ""
                read -r -p "按回车键返回..." dummy || true
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu() {
    while true; do
        [ -t 1 ] && clear
        echo -e "${GRAY}====================================================${PLAIN}"
        echo -e "${BOLD}                 Simple-Box 控制台                  ${PLAIN}"
        echo -e "${GRAY}====================================================${PLAIN}"
        
        # 1. 宿主机基本信息提取（OS 已在入口解析并缓存，此处不再读文件）
        local os_name arch cur_ip bbr_status
        os_name="${OS_NAME:-Linux}"
        arch=$(get_arch 2>/dev/null || echo "unknown")
        # 优先读已持久化的 SERVER_IP，避免每次刷新面板都外呼 curl（菜单响应从 3s 降到瞬时）
        if [[ -f "$ENV_FILE" ]]; then
            cur_ip=$(grep -oP '^SERVER_IP="\K[^"]*' "$ENV_FILE" 2>/dev/null || true)
        fi
        [[ -z "${cur_ip:-}" ]] && cur_ip=$(curl -s4m3 https://icanhazip.com 2>/dev/null || echo "检测中...")
        local cc_algo
        cc_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "关闭")
        if [[ "$cc_algo" == "bbr" ]]; then
            bbr_status="${GREEN}BBR${PLAIN}"
        else
            bbr_status="${YELLOW}${cc_algo^^}${PLAIN}"
        fi

        # 2. 服务运行状态与版本提取
        local sb_ver=""
        local sb_status="${RED}未运行${PLAIN}"
        if [[ -f /usr/local/bin/sing-box ]]; then
            sb_ver=$(/usr/local/bin/sing-box version 2>/dev/null | head -n1 | awk '{print $3}')
            sb_ver="v${sb_ver#v}"
            if systemctl is-active --quiet sing-box; then
                sb_status="${GREEN}运行中 (sing-box ${sb_ver})${PLAIN}"
            else
                sb_status="${RED}已停止 (sing-box ${sb_ver})${PLAIN}"
            fi
        else
            sb_status="${RED}未安装${PLAIN}"
        fi

        # 证书管理 = Caddy 进程在跑 + 本脚本的订阅地址配置确实存在。
        # 只判服务不判站点，卸载或站点丢失后会谎报「运行中」。
        local caddy_ver=""
        local caddy_status="${RED}未安装${PLAIN}"
        if command -v caddy &>/dev/null; then
            caddy_ver=$(caddy version 2>/dev/null | head -n1 | awk '{print $1}')
            caddy_ver="v${caddy_ver#v}"
            if ! systemctl is-active --quiet caddy; then
                caddy_status="${RED}已停止 (Caddy ${caddy_ver})${PLAIN}"
            elif [[ -f /etc/caddy/sites/simple-box-sub.caddy ]]; then
                caddy_status="${GREEN}运行中 (Caddy ${caddy_ver})${PLAIN}"
            else
                caddy_status="${YELLOW}无订阅地址 (Caddy ${caddy_ver})${PLAIN}"
            fi
        fi

        local cert_display="未配置"
        if [[ -f "$ENV_FILE" ]]; then
            set +e; source "$ENV_FILE"; set -e
            if [[ "${CERT_MODE:-selfsigned}" == "domain" && -n "${HY_DOMAIN:-}" ]]; then
                cert_display="${HY_DOMAIN} (CA 证书)"
            else
                cert_display="自签 IP 证书"
            fi
        fi

        # 3. 打印系统面板
        echo -e " 操作系统: ${os_name} (${arch})"
        echo -e " 公网地址: ${cur_ip}"
        echo -e " TLS 证书: ${cert_display}"
        echo -e " TCP 加速: ${bbr_status}"
        echo -e " 证书管理: ${caddy_status}"
        echo -e " 代理服务: ${sb_status}"
        
        if [[ -f "$ENV_FILE" ]]; then
            local hy_sni="${HY_DOMAIN:-$SERVER_IP}"
            local hy_ports="${HY_RANGE:-无}"
            echo -e "${GRAY}----------------------------------------------------${PLAIN}"
            echo -e " VLESS-Reality | TCP: ${CYAN}${VL_PORT:-443}${PLAIN}  | ServerName: ${CYAN}${VL_SNI:-gateway.icloud.com}${PLAIN}"
            echo -e " Hysteria 2    | UDP: ${CYAN}${HY_PORT:-8443}${PLAIN} | SNI: ${CYAN}${hy_sni}${PLAIN} | Ports: ${CYAN}${hy_ports}${PLAIN}"
            
            local proto=${SUB_PROTO:-http}
            local host=${TARGET_HOST:-${HY_DOMAIN:-$SERVER_IP}}
            local port=${SUB_PORT:-8444}
            echo -e "${GRAY}----------------------------------------------------${PLAIN}"
            echo -e " Clash 订阅配置: ${CYAN}${proto}://${host}:${port}/${SUB_TOKEN}/config.yaml${PLAIN}"
            echo -e " Clash 节点列表: ${CYAN}${proto}://${host}:${port}/${SUB_TOKEN}/provider.yaml${PLAIN}"
            if [[ "$proto" == "http" ]]; then
                echo -e " ${YELLOW}✗ (无域名证书加密，建议在可信网络下更新)${PLAIN}"
            else
                echo -e " ${GREEN}✓ (TLS 1.3 强加密保护，直连防死锁)${PLAIN}"
            fi
        fi

        echo -e "${GRAY}----------------------------------------------------${PLAIN}"
        echo -e " 1. vless / hy2 原生链接查看"
        echo -e " 2. VLESS-Reality 模块配置"
        echo -e " 3. Hysteria 2 模块配置"
        echo -e " 4. Clash 订阅地址配置"
        echo -e " 5. sing-box 内核管理"
        echo -e " 6. Simple-Box 脚本升级"
        echo -e " 7. Simple-Box 脚本卸载"
        echo -e " 0. 退出控制台"
        echo -e "${GRAY}====================================================${PLAIN}"
        
        local opt=""
        read -r -p "请输入选项 [0-7]: " opt || opt="0"
        case "$opt" in
            1) show_links || true ;;
            2) menu_reality_module || true ;;
            3) menu_hy2_module || true ;;
            4) menu_sub_module || true ;;
            5) menu_singbox_manage || true ;;
            6) reinstall_with_latest || true ;;
            7)
                uninstall_all || true
                # 卸载已彻底完成：脚本与配置目录均被删除，直接退出
                if [[ "${UNINSTALL_DONE:-false}" == "true" ]]; then
                    exit 0
                fi
                ;;
            0) echo -e "${GREEN}已退出。随时输入 simbo 即可重新打开面板。${PLAIN}"; exit 0 ;;
            *) echo -e "${RED}无效选项！${PLAIN}"; sleep 1 ;;
        esac
    done
}

# 入口守卫：三种执行方式都要能进入主流程
#   1) ./simple-box.sh / bash simple-box.sh  -> BASH_SOURCE[0] == $0
#   2) bash <(curl ...)                      -> BASH_SOURCE[0] == /dev/fd/63 == $0
#   3) curl ... | bash                       -> BASH_SOURCE[0] 为空，$0 为 bash（管道）
_ENTRY_SRC="${BASH_SOURCE[0]:-}"
if [[ -z "$_ENTRY_SRC" || "$_ENTRY_SRC" == "$0" ]]; then
    # 系统不在支持范围内就直接退出，别让用户走到一半才失败
    OS_NAME=$(require_os) || exit 1
    export OS_NAME
    case "${1:-}" in
        install|reinstall) install_node || exit 1 ;;
        "")
            # 判定依据只能是「配置是否存在」，不能看二进制：
            # 卸载会删配置目录，但残留的 sing-box 二进制（或旧版本卸载未清理）会让
            # 「二进制在、配置没了」这种半残状态被误判成已安装，于是直接弹空面板，
            # 表现为「假安装」—— 瞬间进菜单、全是未配置/未运行。
            if [[ ! -f "$ENV_FILE" ]]; then
                if [[ -f /usr/local/bin/sing-box ]]; then
                    echo -e "${YELLOW}检测到残留的 sing-box 内核但无配置，视为未安装，正在进入安装向导...${PLAIN}"
                else
                    echo -e "${YELLOW}未检测到已安装的 Simple-Box，正在进入安装向导...${PLAIN}"
                fi
                install_node || exit 1
            else
                menu
            fi
            ;;
        *) menu ;;
    esac
fi
