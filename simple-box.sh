#!/usr/bin/env bash
# Simple-Box Manager —— 自用 sing-box 服务端管理脚本
# 协议: VLESS-Reality-Vision / Hysteria 2；Caddy 提供订阅分发与证书
# 改动前请先读 MAINTAINING.md（权限收紧与安全变更规范）
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

# 读取 env.conf：同一进程内只读一次；write_env_config 会清空缓存强制重读
ENV_LOADED=""
load_env() {
    [[ -n "$ENV_LOADED" ]] && return 0
    [[ -f "$ENV_FILE" ]] || return 1
    # 写成 if 条件：env.conf 末条命令失败也不会在 set -e 下把调用方带走，
    # 调用处因此不需要 set +e / set -e 包裹（原先 9 处已删）。
    if . "$ENV_FILE"; then :; fi
    ENV_LOADED=1
}
TEMPLATE_FILE="${CONF_DIR}/template.yaml"

SCRIPT_URL="https://raw.githubusercontent.com/comegome/Simple-Box/main/simple-box.sh"

# 临时文件兜底：正常路径各自删，异常退出（Ctrl-C / 报错）时由主流程里的 EXIT trap 收尾。
# 只在入口设置 trap——被 source 时不能往调用方 shell 里塞 trap。
TMP_CLEANUP=()
cleanup_tmp() { local _f; for _f in "${TMP_CLEANUP[@]}"; do [[ -n "$_f" ]] && rm -rf "$_f"; done; }

# 管道执行（curl ... | bash）不受支持，且必须在此处就拦下：
# bash 从 stdin 读取脚本正文，脚本里的 read 会与 bash 抢同一条流，
# 用户看到的每个提问都会把脚本剩余代码当成答案吃掉，结果是静默错乱而非报错。
# 检测依据：BASH_SOURCE[0] 为空 且 stdin 不是终端。
if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    cat >/dev/null 2>&1 || true   # 抽干管道，让外层 curl 正常结束（否则 curl: (23)）
    echo -e "${RED}不支持管道执行（curl ... | bash）：交互提问会和脚本正文抢 stdin。${PLAIN}"
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
#   - 两者共用 apt + systemd，脚本的系统调用完全同构
# 已知版本下限（供后续新增依赖时对照）：
#   caddy 2.6.2 | openssl 3.0 | qrencode 4.1.1
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
    ask "是否仍要继续使用该域名？y/N (回车放弃，重新输入域名或使用 IP): " confirm
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

# 统一输入：ask 纯输入 / ask_trim 去空格+默认值 / confirm_yes 确认
# 统一的单行输入。stdin 关闭（EOF）时置 ASK_EOF=1，菜单循环据此退出，
# 否则 read 一直失败、选项一直为空，会变成死循环。
ASK_EOF=0
ask() {
    local _in=""
    if read -r -p "$1" _in; then ASK_EOF=0; else _in=""; ASK_EOF=1; fi
    printf -v "$2" '%s' "$_in"
}
ask_trim() {
    local _in=""
    if read -r -p "$1" _in; then ASK_EOF=0; else _in=""; ASK_EOF=1; fi
    printf -v "$3" '%s' "$(trim_string "${_in:-$2}")"
}
confirm_yes() { local _in=""; read -r -p "$1" _in || _in=""; [[ "${_in,,}" == y* ]]; }


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

    # 公私钥配对（与 find_cert_dir 用同一套判定）
    cert_pair_ok "$crt" "$key" || return 1

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
        ask "请输入 Cloudflare API Token: " token
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
        ask "是否重新输入 Token？Y/n (回车重试，输入 n 使用 IP 自签): " retry
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
    local port="${1:-}" proto="${2:-tcp}" self="${3:-}"
    local label
    [[ "$proto" == "udp" ]] && label="UDP" || label="TCP"

    if [[ -n "${VL_PORT:-}" && "$self" != "vless" && "$port" == "$VL_PORT" ]]; then
        echo -e "${RED}端口冲突: 该端口已分配给 VLESS-Reality (${VL_PORT})，不能共用！${PLAIN}"
        return 1
    fi
    if [[ -n "${HY_PORT:-}" && "$self" != "hy2" && "$port" == "$HY_PORT" ]]; then
        echo -e "${RED}端口冲突: 该端口已分配给 Hysteria2 (${HY_PORT})，不能共用！${PLAIN}"
        return 1
    fi
    if [[ -n "${SUB_PORT:-}" && "$self" != "sub" && "$port" == "$SUB_PORT" ]]; then
        echo -e "${RED}端口冲突: 该端口已分配给 Caddy 订阅 (${SUB_PORT})，不能共用！${PLAIN}"
        return 1
    fi

    check_port_occupied "$port" "$proto" && return 0
    echo -e "${YELLOW}请更换其他未占用的 ${label} 端口！${PLAIN}"
    return 1
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
            # 只有「订阅端口」才谈得上复用。Caddy 的其它站点（例如 Reality 伪装站
            # 占着 443）与 sing-box 抢同一端口，必须当冲突拒绝，否则装完起不来：
            # sing-box 报 "bind: address already in use" 然后无限重启。
            if [[ -n "${SUB_PORT:-}" && "$port" == "$SUB_PORT" ]]; then
                echo -e "提示: 端口 ${port} 当前由已有 caddy 订阅服务使用，重置安装将自动复用。"
                return 0
            fi
            echo -e "${RED}警告: ${proto^^} 端口 ${port} 被 Caddy 的其它站点占用（订阅端口是 ${SUB_PORT:-未设置}）！${PLAIN}"
            echo -e "${YELLOW}占用详情: ${in_use}${PLAIN}"
            echo -e "${YELLOW}提示: 伪装站占用 443 时 Reality 不能也用 443，请换端口或先把伪装站移走。${PLAIN}"
            return 1
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
    for cmd in curl tar openssl python3 qrencode; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "安装必要基础组件: ${missing[*]}..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o DPkg::Lock::Timeout=180 update -qq || echo -e "${YELLOW}apt-get update 失败，尝试直接安装。${PLAIN}"
        apt-get -o DPkg::Lock::Timeout=180 install -y -qq "${missing[@]}" \
            || echo -e "${YELLOW}部分依赖安装失败，将尝试继续（缺少 qrencode 仅影响二维码显示）。${PLAIN}"
    fi

    # 关键依赖缺失时给出明确警告（python3 缺失会让配置生成整条链路失效）
    local critical_missing=()
    for cmd in curl tar openssl python3; do
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
    # 全新系统首次开机时 unattended-upgrades 常驻占用 apt 锁，直接 install 会以
    # 「Could not get lock」失败——节点照样装好，但订阅端点起不来，用户只看到一个
    # 打不开的订阅地址。这里让 apt 排队等锁，而不是立即放弃。
    apt-get -o DPkg::Lock::Timeout=180 update -qq >/dev/null 2>&1 || true
    if ! apt-get -o DPkg::Lock::Timeout=180 install -y -qq caddy; then
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

# 卸载时调用：只删除本脚本创建的 BBR 配置文件
# 不改运行中的拥塞控制算法——卸载代理软件不该动系统网络栈，而且多数机器的
# bbr 也写在 /etc/sysctl.conf 里，这里改成 cubic 会在下次 sysctl --system 时
# 被覆盖回去，"恢复系统默认"本就做不到。用户自己的配置一律不碰。
disable_bbr() {
    [[ -f "$BBR_CONF" ]] && grep -q "^${BBR_MARK}" "$BBR_CONF" && rm -f "$BBR_CONF" || true
}


# 获取并升级官方 sing-box 内核（带精准版本校验）
update_singbox_core() {
    local force_flag="${1:-}"
    echo -e "检查 sing-box 官方最新版本..."

    local cur_ver="未安装"
    if [[ -f /usr/local/bin/sing-box ]]; then
        cur_ver=$(/usr/local/bin/sing-box version 2>/dev/null | head -n1 | awk '{print $3}')
    fi

    local rel_json="" tag=""
    rel_json=$(curl -sSL --max-time 20 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null || true)
    tag=$(grep -Po '"tag_name": "\K[^"]*' <<<"$rel_json" || true)
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
    arch=$(require_arch) || return 1

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

    # 官方 release 不发布 checksum 文件，但 API 的 asset 对象自带 sha256 digest。
    # 校验挡的是「下到半截 / 变体选错 / 中间设备替换」，且不需要用户手抄哈希。
    local pkg="sing-box-${latest_ver}-linux-${arch}.tar.gz"
    local want_sha=""
    want_sha=$(awk -v want="$pkg" '
        index($0, want) && /"name"/ { hit = 1 }
        hit && /"digest":/ {
            v = $0
            sub(/.*"digest":[[:space:]]*"/, "", v)
            sub(/".*/, "", v)
            print v; exit
        }' <<<"$rel_json")
    local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${pkg}"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    TMP_CLEANUP+=("$tmp_dir")
    local tmp_tar="${tmp_dir}/sing-box.tar.gz"

    echo -e "正在下载并更新内核..."
    if ! curl -fsSL "$url" -o "$tmp_tar"; then
        # 部分机房到 GitHub 的 releases/download 路径会稳定回 504：实测台北某线路对
        # 任意仓库、任意版本的资产都 504，而 api.github.com 与 objects.githubusercontent.com
        # 均正常。改走官方 API 的资产端点，拿到的是同一个文件，不引入第三方镜像。
        echo -e "${YELLOW}直连 releases 失败，改用 GitHub API 资产端点重试...${PLAIN}"
        local asset_id=""
        # 资产 JSON 里 "id" 在 "name" 之前，用 awk 记住最近一个合法 id，命中目标名时吐出。
        # 不要用 grep -o 在 name 那行找 id——两者不在同一行。
        asset_id=$(curl -sSL --max-time 20 "https://api.github.com/repos/SagerNet/sing-box/releases/tags/${tag}" 2>/dev/null \
            | awk -v want="$pkg" '
                /"id":/ {
                    v = $0
                    sub(/.*"id":[[:space:]]*/, "", v)
                    sub(/,.*/, "", v)
                    if (v ~ /^[0-9]+$/) id = v
                }
                index($0, want) && /"name"/ { print id; exit }
            ')
        if [[ -z "$asset_id" ]] || ! curl -fsSL --max-time 600 \
                -H "Accept: application/octet-stream" \
                -o "$tmp_tar" \
                "https://api.github.com/repos/SagerNet/sing-box/releases/assets/${asset_id}"; then
            echo -e "${RED}内核下载失败（网络不通或该版本无 ${arch} 构建），已保留现有版本。${PLAIN}"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi
    # 校验失败立刻中止：此刻现网二进制一个字节都没动
    if [[ -n "$want_sha" ]]; then
        local got_sha
        got_sha=$(sha256sum "$tmp_tar" | awk '{print $1}')
        if [[ "sha256:${got_sha}" != "$want_sha" ]]; then
            echo -e "${RED}内核包 sha256 校验失败，已中止（现有内核未改动）。${PLAIN}"
            echo -e "${GRAY}期望: ${want_sha#sha256:}${PLAIN}"
            echo -e "${GRAY}实际: ${got_sha}${PLAIN}"
            rm -rf "$tmp_dir"
            return 1
        fi
        echo -e "${GREEN}✓ 内核包 sha256 校验通过${PLAIN}"
    else
        echo -e "${YELLOW}未取到官方 sha256（API 未返回 digest），跳过校验。${PLAIN}"
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
            # 备份必须可执行：cp 覆盖已存在的同名文件时不改权限
            [[ -n "$old_bin_backup" ]] && chmod 755 "$old_bin_backup" 2>/dev/null || true
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
        # 本机已有该域名的证书（/etc/ssl/<域名> 或 acme.sh 目录）→ 拷进 CERT_DIR 直接复用
        local _src="" _rc=0
        if ! cert_covers_domain "$domain"; then
            _src=$(find_cert_dir "$domain") || _rc=$?
            if [[ "$_rc" -eq 0 && -n "$_src" && "$_src" != "$CERT_DIR" ]]; then
                install_cert_to "$_src" "$CERT_DIR" || true
                echo -e "${GREEN}检测到本机已有 ${domain} 的证书（${_src}），已同步复用。${PLAIN}"
            fi
        fi
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
        }
        # 伪装站 / 接入域站点用的就是 CERT_DIR 里这份证书。此时写 IP 自签会让站点与
        # Reality 回落一起失效（客户端 x509 域名不匹配），而安装日志还会说「节点可用」。
        # 按「不破坏原有站点」优先的规则：直接中止，一个字节都不改。
        local _cert_users
        _cert_users=$(sites_using_cert_dir)
        if [[ -n "$_cert_users" ]]; then
            echo -e "${RED}✗ 本机站点正在使用 ${CERT_DIR} 的证书：${PLAIN}"
            printf '    %s\n' $_cert_users
            echo -e "${YELLOW}  改成 IP 自签会让这些站点与 Reality 回落一起失效，已中止（未改动任何证书）。${PLAIN}"
            echo -e "${YELLOW}  修好 Token / DNS 后重跑安装；或先停用 Reality、移走站点再装。${PLAIN}"
            return 1
        fi
        echo -e "${YELLOW}已自动降级为 10 年期 IP 自签证书，保证节点立即可用。${PLAIN}"
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

# 为「非 Hy2 域名」单独签一张站点证书，写 <CERT_SSL_ROOT>/<域名>，不动 sing-box 的 CERT_DIR。
# 用于伪装站想用别的域名（菜单 8 / Reality 启用流程）时，该域名此前从未签过证书。
issue_site_cert() {
    local domain="${1:-}" cf_token="${2:-}"
    local dir="${CERT_SSL_ROOT}/${domain}"
    local acme_bin="$HOME/.acme.sh/acme.sh"
    [[ -n "$domain" ]] || return 1

    # 已有证书时这一步只是「部署 + 挂续期钩子」，不需要 Token
    local have_cert=0
    [[ -f "$HOME/.acme.sh/${domain}_ecc/fullchain.cer" ]] && have_cert=1

    if [[ -z "$cf_token" ]]; then cf_token="${CF_TOKEN:-}"; fi
    if [[ -z "$cf_token" && -f /root/.cf-token ]]; then
        cf_token=$(tr -d '\r\n' < /root/.cf-token)
    fi
    if [[ "$have_cert" == 0 && -z "$cf_token" ]]; then
        prompt_cf_token || { echo -e "${YELLOW}没有 CF Token，无法签发 ${domain} 的证书${PLAIN}"; return 1; }
        cf_token="$PROMPTED_CF_TOKEN"
    fi

    if [[ ! -f "$acme_bin" ]]; then
        echo -e "安装 acme.sh ..."
        curl -sSL https://get.acme.sh | sh -s email="admin@${domain}" >/dev/null 2>&1 || true
    fi
    [[ -f "$acme_bin" ]] || { echo -e "${RED}acme.sh 不可用${PLAIN}"; return 1; }

    export CF_Token="$cf_token"
    if [[ ! -f "$HOME/.acme.sh/${domain}_ecc/fullchain.cer" ]]; then
        echo -e "通过 Cloudflare DNS API 申请 ${domain} 的证书（DNS-01）..."
        "$acme_bin" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
        "$acme_bin" --issue --dns dns_cf -d "$domain" --dnssleep 20 --keylength ec-256 --force >/dev/null 2>&1 || true
    fi
    install -d -m 755 "$dir" || return 1
    "$acme_bin" --install-cert -d "$domain" --ecc \
        --fullchain-file "${dir}/fullchain.cer" \
        --key-file "${dir}/private.key" \
        --reloadcmd "systemctl reload caddy 2>/dev/null || true" >/dev/null 2>&1 || true
    chgrp caddy "${dir}/private.key" 2>/dev/null || true
    chmod 640 "${dir}/private.key" 2>/dev/null || true
    chmod 644 "${dir}/fullchain.cer" 2>/dev/null || true

    if find_cert_dir "$domain" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 已签发并部署 ${domain} 的证书（${dir}）${PLAIN}"
        return 0
    fi
    echo -e "${RED}✗ ${domain} 的证书申请失败（Token 权限 / DNS 记录 / CF 网络）${PLAIN}"
    return 1
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

# 清理旧版（4.0 之前）遗留的端口跳跃规则。
# 4.0 起不再使用端口跳跃；升降级时那条 REDIRECT 会一直留在 PREROUTING 里，
# 把整段 UDP 继续重定向到旧端口，所以安装与卸载各清理一次。
# 只删「-p udp --dport 起:止 -j REDIRECT --to-ports N」这一种形态，不碰其它规则。
cleanup_legacy_port_hopping() {
    command -v iptables &>/dev/null || return 0
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # shellcheck disable=SC2086
        iptables -t nat -D PREROUTING $line 2>/dev/null || true
    done < <(iptables -t nat -S PREROUTING 2>/dev/null \
        | sed -n 's/^-A PREROUTING //p' \
        | grep -E '^-p udp -m udp --dport [0-9]+:[0-9]+ -j REDIRECT --to-ports [0-9]+$' || true)
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi
}

# 等待 systemd 单元回到 active（reload / restart 之后用）
# reload 会立刻返回 0，但新增/变更监听（例如 Caddy 的 UDP/HTTP3）时进程可能卡在 reloading，
# 只凭退出码会漏掉「重载成功但没生效」。
wait_service_active() {
    local unit="$1" secs="${2:-10}" i
    for ((i = 1; i <= secs; i++)); do
        [[ "$(systemctl is-active "$unit" 2>/dev/null)" == "active" ]] && return 0
        sleep 1
    done
    return 1
}

reload_caddy_safe() {
    # 先校验配置，优先 reload，失败才 restart，并解除 systemd 限流
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
            wait_service_active caddy 10 && return 0
            echo -e "${YELLOW}Caddy 重载后 10 秒内未回到 active，改为重启...${PLAIN}"
        else
            echo -e "${YELLOW}Caddy 热重载未生效，改为重启...${PLAIN}"
        fi
    else
        # 3. 未运行（或曾被限流）时先清除失败计数，再启动
        systemctl reset-failed caddy 2>/dev/null || true
    fi

    systemctl restart caddy 2>/dev/null && wait_service_active caddy 10 && return 0
    echo -e "${RED}Caddy 启动失败，请查看: journalctl -u caddy -n 30${PLAIN}"
    return 1
}

# 校验 Caddy 是否真的在目标端口监听（重载后调用，防止"配置成功但没生效"）
verify_caddy_listening() {
    local port="${1:-}"
    local i
    for i in 1 2 3 4 5; do
        ss -tln 2>/dev/null | grep -qE "[:.]${port} " && return 0
        sleep 1
    done
    echo -e "${RED}警告: Caddy 未在端口 ${port} 上监听，订阅链接当前不可用。${PLAIN}"
    echo -e "${YELLOW}请检查: journalctl -u caddy -n 30${PLAIN}"
    return 1
}

# ---- Caddyfile 归属：内容判据，不是标记判据 ----
# 标记只说明「装的时候是我写的」；用户完全可能之后在这份文件里加站点或全局选项。
# 只有内容仍是脚本骨架（或旧版「只有 import 一行」）才算我们的，才敢重写/删除。
caddyfile_is_ours() {
    local f="${CADDYFILE:-/etc/caddy/Caddyfile}" body skeleton
    [[ -f "$f" ]] || return 1
    body=$(cat "$f")
    skeleton=$(printf '{\n\t# 本机只有订阅站点，不需要 HTTP->HTTPS 重定向，避免额外监听 80\n\tauto_https disable_redirects\n}\nimport sites/*.caddy')
    [[ "$body" == "$skeleton" ]] && return 0
    [[ "$(printf '%s' "$body" | sed '/^[[:space:]]*$/d')" == "import sites/*.caddy" ]] && return 0
    return 1
}

# 决定 Caddyfile 怎么处理，打印 written / appended / ours / foreign 之一。
#   written  新装或旧版骨架 → 写成规范形态（含 auto_https disable_redirects）
#   appended 我们的文件以外、缺 import → 只追加一行（订阅站靠它加载）
#   ours     已经是规范形态 → 一个字节都不动
#   foreign  用户改过且已有 import → 保留原样
ensure_caddyfile() {
    local caddyfile="${CADDYFILE:-/etc/caddy/Caddyfile}" ours=false
    mkdir -p "$(dirname "$caddyfile")" 2>/dev/null || true
    [[ -f "$caddyfile" ]] && caddyfile_is_ours && ours=true

    if [[ ! -f "$caddyfile" ]] || [[ "$ours" == "true" ]]; then
        if [[ ! -f "$caddyfile" ]] || ! grep -q "auto_https disable_redirects" "$caddyfile"; then
            cat > "$caddyfile" <<'CADDYEOF'
{
	# 本机只有订阅站点，不需要 HTTP->HTTPS 重定向，避免额外监听 80
	auto_https disable_redirects
}
import sites/*.caddy
CADDYEOF
            printf 'written\n'
        else
            printf 'ours\n'
        fi
        : > "${CONF_DIR}/.caddyfile_created_by_script" 2>/dev/null || true
        return 0
    fi
    if ! grep -q "import sites/\*\\.caddy" "$caddyfile"; then
        printf '\nimport sites/*.caddy\n' >> "$caddyfile"
        : > "${CONF_DIR}/.caddyfile_appended_by_script" 2>/dev/null || true
        printf 'appended\n'
        return 0
    fi
    printf 'foreign\n'
}

# 部署 Caddy 证书管理服务
setup_caddy_subscription() {
    local domain_or_ip="${1:-}"
    local token="${2:-}"
    local sub_port="${3:-}"
    local cert_mode="${4:-selfsigned}"

    if ! install_caddy; then
        echo -e "${RED}Caddy 不可用，订阅地址无法访问。${PLAIN}"
        echo -e "${YELLOW}节点本身是好的：Reality / Hysteria2 照常可用，原生链接也不受影响，${PLAIN}"
        echo -e "${YELLOW}只有 http://<地址>:${sub_port}/ 这个订阅端点不会响应。${PLAIN}"
        echo -e "${YELLOW}装好 Caddy 后重跑菜单 4「Clash 订阅地址配置」即可补上，不用重装节点。${PLAIN}"
        return 1
    fi

    # caddy 装好后 caddy 组才存在。全新机器上证书先于 caddy 签发，那时
    # harden_private_key 只能把私钥留在 root:root，caddy 读不到会直接
    # permission denied 起不来。这里补调一次把属组补上。
    harden_private_key

    mkdir -p "/etc/caddy/sites"

    # Caddyfile 只在「文件不存在」或「内容仍是本脚本那份骨架」时才写。
    # 用户在这份文件里加过站点/全局选项时一律保留（只写 sites/ 下的订阅站点），
    # 否则一次保存订阅就会把人家自己的站点抹掉。
    local _cf_action
    _cf_action=$(ensure_caddyfile)
    case "$_cf_action" in
        foreign) echo -e "${CYAN}检测到 Caddyfile 已被修改，保留原样（订阅站只写 sites/）${PLAIN}" ;;
        appended) echo -e "${GRAY}已在 Caddyfile 追加 import sites/*.caddy${PLAIN}" ;;
    esac

    # 清理所有旧版 simple-box caddy 配置文件
    rm -f /etc/caddy/sites/*-${sub_port}.caddy /etc/caddy/sites/simple-box*.caddy

    if [[ "$cert_mode" == "domain" ]]; then
        echo -e "配置 Caddy HTTPS 域名证书 (端口 ${sub_port})..."
        # 续期目标就是 CERT_DIR（acme --install-cert 写这里），优先用它。
        # /etc/ssl/<域名> 可能只是 find_cert_dir 规范化时留下的副本，续期不会更新它——
        # 优先读那边会在下一次续期后让订阅站继续用旧证书。
        local tls_dir="$CERT_DIR" _c
        if [[ -n "${HY_DOMAIN:-}" ]] && cert_covers_host "${CERT_DIR}/fullchain.cer" "$HY_DOMAIN" \
            && cert_pair_ok "${CERT_DIR}/fullchain.cer" "${CERT_DIR}/private.key"; then
            tls_dir="$CERT_DIR"
        else
            for _c in "/etc/ssl/${HY_DOMAIN:-}" "/etc/ssl/${HY_DOMAIN%%.*}"; do
                [[ -n "${HY_DOMAIN:-}" && -f "$_c/fullchain.cer" && -f "$_c/private.key" ]] && { tls_dir="$_c"; break; }
            done
        fi
        cat > "/etc/caddy/sites/simple-box-sub.caddy" <<EOF
# Simple-Box HTTPS 域名证书
:${sub_port} {
    bind tcp4/0.0.0.0
    tls ${tls_dir}/fullchain.cer ${tls_dir}/private.key

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

    chmod 755 "$WEB_DIR" 2>/dev/null || true
    if ! command -v caddy &>/dev/null; then
        echo -e "${RED}Caddy 未安装成功，在线订阅不可用。${PLAIN}"
        echo -e "${YELLOW}节点本身不受影响；可稍后手动安装 Caddy 再重跑本项。${PLAIN}"
        return 0
    fi
    reload_caddy_safe || echo -e "${YELLOW}订阅地址配置已写入，但 Caddy 未能生效，可稍后手动 systemctl restart caddy。${PLAIN}"

    # 自检：订阅端点真的取到文件才算部署成功。只看 caddy 是 active 不够——
    # 站点配置写错、端口被占、bind 失败都会表现成「服务在跑，订阅 404/超时」，
    # 而用户是在客户端里才发现的。
    local _scheme="http" _code="000"
    [[ "$cert_mode" == "domain" ]] && _scheme="https"
    sleep 1
    _code=$(curl -s -o /dev/null -m 8 -k -w '%{http_code}' \
        "${_scheme}://127.0.0.1:${sub_port}/${token}/provider.yaml" 2>/dev/null || echo 000)
    if [[ "$_code" == "200" ]]; then
        echo -e "${GREEN}✓ 订阅端点自检通过 (${_scheme}://<本机>:${sub_port}/${token}/provider.yaml)${PLAIN}"
    else
        echo -e "${YELLOW}订阅端点自检未通过 (HTTP ${_code})${PLAIN}"
        echo -e "${YELLOW}节点本身可用，但客户端拉订阅会失败。排查: systemctl status caddy; ss -ltn | grep :${sub_port}${PLAIN}"
    fi
}


# 面板：入站/出站固定四行（槽位不随状态跳动）
print_io_status() {
    local st
    sync_env_locals   # env 存分协议字段，这里解析成当前生效的一组

    # ---- 入站（两个协议固定占位）----
    for _p in $PROTOCOLS; do
        local name; name=$(proto_human "$_p")
        local cred=""
        case "$_p" in reality) cred="${VL_UUID:-}" ;; hy2) cred="${HY_PASS:-}" ;; esac
        if set_has "$(proto_tag "$_p")"; then
            st="${GREEN}[已启用]${PLAIN}"
            case "$_p" in
                reality) printf ' 入站 %-14s %s  TCP %s   %s\n' "$name" "$st" "${VL_PORT:-443}" "${VL_SNI:-}";;
                hy2)     printf ' 入站 %-14s %s  UDP %s  %s\n' "$name" "$st" "${HY_PORT:-8443}" \
                            "${HY_DOMAIN:-$SERVER_IP}";;
            esac
        elif [[ -n "$cred" ]]; then
            printf ' 入站 %-14s %s\n' "$name" "${YELLOW}[未启用]${PLAIN}"
        else
            printf ' 入站 %-14s %s\n' "$name" "${GRAY}[未安装]${PLAIN}"
        fi
    done

    # ---- 出站：直连是默认行为（route.final=direct），不占行；只报中转 ----
    local ep="" en="" eshow="" _ip="" n="" _name="" _any=0 _vlp="" _hyp=""
    for n in $(exit_active_slots); do
        exit_slot_env "$n"
        _vlp="$SE_ENTRY_VL"; _hyp="$SE_ENTRY_HY"
        # 槽 1 的历史默认值：env 里没写也按 2053/2054 显示（与旧版面板一致）
        [[ -n "$_vlp" || "$n" != "1" ]] || _vlp=2053
        [[ -n "$_hyp" || "$n" != "1" ]] || _hyp=2054
        ep=""
        [[ -n "$_vlp" ]] && set_has "vless-reality-in" && ep="TCP $_vlp"
        [[ -n "$_hyp" ]] && set_has "hy2-in" && ep="${ep:+$ep / }UDP $_hyp"
        [[ -n "$ep" ]] || continue
        _any=1
        en="Hysteria2"
        # 连接仍用域名（落地机换 IP 时自动跟随），面板显示解析结果，便于和实测出口 IP 对照。
        # 不做缓存：解析失败就退回域名，避免出现「面板显示旧 IP」的假象。
        eshow="$SE_SERVER"
        _ip=$(timeout 2 getent ahostsv4 "$SE_SERVER" 2>/dev/null | awk '{print $1; exit}')
        [[ -n "$_ip" ]] && eshow="$_ip"
        _name="Relay"; [[ "$n" != "1" ]] && _name="Relay $SE_LABEL"
        printf ' 出站 %-14s %s  %s  →  %s (%s)\n' "$_name" "${GREEN}[已启用]${PLAIN}" \
            "$ep" "$eshow" "$en"
    done
    [[ "$_any" == "1" ]] || printf ' 出站 %-14s %s\n' "Relay" "${GRAY}[已停用]${PLAIN}"
}

# 订阅协议由证书模式唯一决定：domain → https，其余（含自签）→ http。
# 全脚本只在这里判断一次，避免各菜单分支各推一遍、改规则时漏改。
sub_scheme() {
    [[ "${CERT_MODE:-selfsigned}" == "domain" ]] && printf 'https' || printf 'http'
}

# 校验并规整「直连域名后缀」：非法项打警告后丢弃，返回空格分隔的干净串。
clean_suffixes() {
    local s out=""
    for s in $1; do
        if [[ "$s" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
            out+="${s} "
        else
            echo -e "${YELLOW} 忽略无效域名后缀: ${s}${PLAIN}" >&2
        fi
    done
    printf '%s' "${out% }"
}


# 从当前作用域的变量重建订阅（render_and_reload / install_node / 子菜单共用）
# 依赖 bash 动态作用域：调用方的 local 变量在函数内可见，无需显式传 13 个参数。
# 参数错位只可能发生在这里一处，调用点全部是单行。
#   $1 可选：指定 token（token 轮换时传新值），缺省用调用方的 $sub_token
regen_subscription() {
    local _token="${1:-${sub_token:-}}"
    # 端口存在 ≠ 协议启用：以 config.json 里的 inbound 为准，
    # 否则停用协议后任何一次重建都会把它又写回订阅。
    set_has "vless-reality-in" || vl_port=""
    set_has "hy2-in" || hy_port=""
    generate_full_client_config \
        "${target_host:-}" "$_token" "${node_prefix:-}" "${server_ip:-}" \
        "${vl_port:-}" "${user_uuid:-}" "${vl_sni:-}" "${vl_pubkey:-}" "${vl_shortid:-}" \
        "${hy_port:-}" "${hy_password:-}" "${hy_skip_cert:-}"
}

# 组装客户端订阅与独立链接

# ==================== 协议注册表 ====================
# 加新协议：在 PROTOCOLS 里加名字，再补 proto_<name>_* 的四个小函数即可，
# 订阅生成、菜单、启用/停用都从这里遍历，不需要再改别处。
PROTOCOLS="reality hy2"

proto_tag()   { case "$1" in reality) echo "vless-reality-in" ;; hy2) echo "hy2-in" ;; esac; }
proto_human() { case "$1" in reality) echo "Reality" ;; hy2) echo "Hysteria2" ;; esac; }
proto_label() { case "$1" in reality) echo "VLESS-Reality" ;; hy2) echo "Hysteria2" ;; esac; }

# 取某协议在「直连 / 出口」两种形态下实际监听的端口；该形态未启用则输出空。
# 第三个参数是槽位编号（缺省 1，字段名与历史一致）。
node_port() {
    local _p="$1" _shape="${2:-direct}" _slot="${3:-1}" _port="" _v
    if [[ "$_shape" == "exit" ]]; then
        case "$_p" in
            reality) _v="EXIT_ENTRY_VL"; [[ "$_slot" != "1" ]] && _v="EXIT${_slot}_ENTRY_VL"
                     [[ -n "${vl_port:-}" ]] && _port="${!_v:-}" ;;
            hy2)     _v="EXIT_ENTRY_HY"; [[ "$_slot" != "1" ]] && _v="EXIT${_slot}_ENTRY_HY"
                     [[ -n "${hy_port:-}" ]] && _port="${!_v:-}" ;;
        esac
    else
        case "$_p" in
            reality) _port="${vl_port:-}" ;;
            hy2)     _port="${hy_port:-}" ;;
        esac
    fi
    printf '%s' "$_port"
}

# 按顺序把节点交给回调：先直连协议，再逐槽的出口协议。
# 用法: emit_nodes <proto_proxy|proto_link> <输出文件>
emit_nodes() {
    local cb="$1" out="$2" _p _port n _label
    for _p in $PROTOCOLS; do
        _port=$(node_port "$_p" direct)
        [[ -n "$_port" ]] || continue
        "$cb" "$_p" "${node_prefix}-$(proto_label "$_p")" "$_port" >> "$out"
    done
    for n in $(exit_active_slots); do
        exit_slot_env "$n"
        _label="$SE_LABEL"
        for _p in $PROTOCOLS; do
            _port=$(node_port "$_p" exit "$n")
            [[ -n "$_port" ]] || continue
            "$cb" "$_p" "${node_prefix}-$(proto_label "$_p")-${_label}" "$_port" >> "$out"
        done
    done
}

# 订阅 YAML 片段：读调用方的小写局部变量（动态作用域）
proto_proxy() {
    local _p="$1" _name="$2" _port="$3"
    case "$_p" in
        reality) cat <<EOF
  - name: "${_name}"
    type: vless
    server: ${server_ip}
    port: ${_port}
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
            ;;
        hy2) cat <<EOF
  - name: "${_name}"
    type: hysteria2
    server: ${domain_or_ip}
    port: ${_port}
    password: "${hy_password}"
    sni: ${domain_or_ip}
    skip-cert-verify: ${hy_skip_cert}
EOF
            ;;
    esac
}

proto_link() {
    local _p="$1" _name="$2" _port="$3"
    case "$_p" in
        reality)
            echo "vless://${user_uuid}@${server_ip}:${_port}?security=reality&encryption=none&pbk=${vl_pubkey}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${vl_sni}&sid=${vl_shortid}#${_name}"
            ;;
        hy2)
            local _ins="0"; [[ "${hy_skip_cert}" == "true" ]] && _ins="1"
            echo "hy2://${hy_password}@${domain_or_ip}:${_port}/?sni=${domain_or_ip}&insecure=${_ins}#${_name}"
            ;;
    esac
}


# 规整 proxies 段的空行：块内不留空行，块与块之间恰好一个空行
tidy_proxies() {
    local f="${1:-}"
    [[ -s "$f" ]] || return 0
    python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]
out, in_px, first = [], False, True
for line in open(p).read().splitlines():
    if line.startswith("proxies:"):
        in_px = True; out.append(line); continue
    if in_px and re.match(r"^[A-Za-z_-]+:", line):
        in_px = False
        if out and out[-1].strip():
            out.append("")
    if in_px:
        if not line.strip():
            continue                      # 段内空行一律丢弃，稍后按块补
        if line.startswith("  - name:"):
            if not first and out and out[-1].strip():
                out.append("")
            first = False
        out.append(line)
    else:
        out.append(line)
open(p, "w").write("\n".join(out).rstrip("\n") + "\n")
PY
}

# 原生链接：一条一行，条与条之间空一行
tidy_links() {
    local f="${1:-}"
    [[ -s "$f" ]] || return 0
    awk 'NF{ if (n++) print ""; print }' "$f" > "${f}.tmp" && mv -f "${f}.tmp" "$f"
}

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
    local hy_password="${11}"
    local hy_skip_cert="${12}"

    # 入参校验：这些字段任一为空都会生成一份「看起来正常但连不上」的订阅，
    # 且 mihomo -t 照样通过（空 server / 空 uuid 都是合法 YAML）。必须显式拦截。
    local _missing=""
    [[ -z "$token" ]] && _missing+=" token"
    [[ -z "$server_ip" ]] && _missing+=" server_ip"
    [[ -z "$user_uuid" ]] && _missing+=" user_uuid"
    [[ -z "$vl_pubkey" ]] && _missing+=" vl_pubkey"
    [[ -z "$vl_shortid" ]] && _missing+=" vl_shortid"
    [[ -z "$hy_password" ]] && _missing+=" hy_password"
    if [[ -n "$_missing" ]]; then
        echo -e "${RED}内部错误: 订阅生成参数缺失 (${_missing# })，已中止（未写入任何文件）。${PLAIN}" >&2
        return 1
    fi

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
    # server_ip 是 IP 才用 IP-CIDR；是域名（SERVER_IP 改成域名后）必须用 DOMAIN，
    # 否则会生成 IP-CIDR,example.com/32 这种非法规则，mihomo -t 直接失败。
    if [[ "$server_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        direct_rule="  - IP-CIDR,${server_ip}/32,DIRECT,no-resolve"
    else
        direct_rule="  - DOMAIN,${server_ip},DIRECT"
    fi
    # 自有域名直连：由 env.conf 的 DIRECT_SUFFIXES 注入（空格分隔的后缀列表，
    # 例如 DIRECT_SUFFIXES="example.com mycorp.net"）。脚本与模板不内置任何
    # 私有域名，默认留空 —— 部署方按需填写，分享时无需删改代码。
    local suffix
    for suffix in ${DIRECT_SUFFIXES:-}; do
        direct_rule+=$'\n'"  - DOMAIN-SUFFIX,${suffix},DIRECT"
    done
    if grep -q '^rules:' "$full_config_file"; then
        awk -v rule="$direct_rule" '
            { print }
            /^rules:[[:space:]]*$/ && !done { print rule; done=1 }
        ' "$full_config_file" > "${full_config_file}.tmp" && mv -f "${full_config_file}.tmp" "$full_config_file"
    else
        printf 'rules:\n%s\n' "$direct_rule" >> "$full_config_file"
    fi

    cat >> "$full_config_file" <<EOF

# ==================== Simple-Box 动态生成节点 ====================
proxies:
EOF

    emit_nodes proto_proxy "$full_config_file"

    cat >> "$full_config_file" <<EOF

proxy-groups:
  - name: "📌节点选择"
    type: select
    proxies:
EOF

    for _p in $PROTOCOLS; do
        case "$_p" in reality) _port="$vl_port" ;; hy2) _port="$hy_port" ;; esac
        [[ -n "$_port" ]] && printf '      - "%s-%s"\n' "$node_prefix" "$(proto_label "$_p")" >> "$full_config_file"
        for _slot in $(exit_active_slots); do
            exit_slot_env "$_slot"
            _port=$(node_port "$_p" exit "$_slot")
            [[ -n "$_port" ]] || continue
            printf '      - "%s-%s-%s"\n' "$node_prefix" "$(proto_label "$_p")" "$SE_LABEL" >> "$full_config_file"
        done
    done
    printf '      - "DIRECT"\n' >> "$full_config_file"

    # 2. 组装纯 Provider 片段
    local provider_file="${WEB_DIR}/${token}/provider.yaml"
    printf 'proxies:\n' > "$provider_file"

    emit_nodes proto_proxy "$provider_file"

    # 3. 组装原生分享链接
    local links_out="${WEB_DIR}/${token}/links.txt"
    : > "$links_out"
    emit_nodes proto_link "$links_out"

    tidy_proxies "$full_config_file"
    tidy_proxies "$provider_file"
    tidy_links "$links_out"
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
    local latest
    latest=$(mktemp /tmp/simple-box.latest.XXXXXX)
    TMP_CLEANUP+=("$latest")

    echo -e "正在检查仓库最新脚本..."
    if ! fetch_latest_script "$latest"; then
        rm -f "$latest"
        echo -e "${RED}获取最新脚本失败，已中止，没有动任何配置。${PLAIN}"
        echo -e "${YELLOW}不能回退到重装：会轮换密钥，客户端配置全部失效。${PLAIN}"
        echo -e "${GRAY}排查：仓库是否私有 / 能否访问 raw.githubusercontent.com / 手动覆盖 ${target}${PLAIN}"
        return 1
    fi

    if [[ -f "$target" ]] && cmp -s "$latest" "$target"; then
        rm -f "$latest"
        echo -e "${GREEN}当前已是最新脚本，无需升级。${PLAIN}"
        echo -e "${YELLOW}重装会轮换 UUID / 密钥 / short-id，所有客户端配置都会失效。${PLAIN}"
        local again=""
        ask "仍要重装吗？(y/N): " again
        if [[ "$again" != "y" && "$again" != "Y" ]]; then
            echo -e "${GRAY}已取消，节点保持原样。${PLAIN}"
            return 0
        fi
        echo -e "${YELLOW}正在重装...${PLAIN}"
        install_node || true
        return 0
    fi

    echo -e "${GREEN}检测到仓库有新版本，正在更新脚本...${PLAIN}"
    mkdir -p "$share_dir"
    if ! install -m 755 "$latest" "$target" 2>/dev/null && ! cp -f "$latest" "$target"; then
        rm -f "$latest"
        echo -e "${RED}脚本更新失败（磁盘只读？），已中止，没有动任何配置。${PLAIN}"
        return 1
    fi
    chmod 755 "$target" 2>/dev/null || true
    rm -f "$latest"
    ln -sf "$target" /usr/local/bin/simbo

    echo -e "${GREEN}脚本已更新到最新版本。${PLAIN}"
    echo -e "${YELLOW}重装会轮换 UUID / 密钥 / short-id 并更换订阅 token，所有客户端都会失效。${PLAIN}"
    local do_reinstall=""
    ask "是否现在重装？(y/N): " do_reinstall
    if [[ "$do_reinstall" != "y" && "$do_reinstall" != "Y" ]]; then
        echo -e "${GRAY}已跳过重装，节点配置未改动。输入 simbo 打开面板即可使用新脚本。${PLAIN}"
        return 0
    fi

    echo -e "${YELLOW}正在用新版本重装...${PLAIN}"
    # 用新脚本接管当前进程：确保后续交互逻辑与提示都来自新版本，
    # 而不是内存里这份旧代码（否则装完菜单仍是旧的）
    exec bash "$target" install
}

# 部署与配置主函数
# 集中生成 sing-box 服务端配置文件
write_singbox_config() {
    local vl_port="${1:-}" vl_sni="${2:-}" user_uuid="${3:-}" vl_privkey="${4:-}" vl_shortid="${5:-}"
    local hy_port="${6:-}" hy_password="${7:-}"
    # 第 8/9 个参数给「443 翻转」用：回落目标（默认自身域名 + 443）
    local vl_hs="${8:-$vl_sni}" vl_hs_port="${9:-443}"

    local tmp_conf
    tmp_conf=$(mktemp "${CONF_FILE}.tmp.XXXXXX")

    local parts=() p
    if [[ -n "$vl_port" ]]; then
        parts+=("$(cat <<JSON
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "listen_port": ${vl_port},
      "users": [
        { "uuid": "${user_uuid}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${vl_sni}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${vl_hs}", "server_port": ${vl_hs_port} },
          "private_key": "${vl_privkey}",
          "short_id": [ "${vl_shortid}" ]
        }
      }
    }
JSON
)")
    fi
    if [[ -n "$hy_port" ]]; then
        parts+=("$(cat <<JSON
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "0.0.0.0",
      "listen_port": ${hy_port},
      "users": [
        { "password": "${hy_password}" }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_DIR}/fullchain.cer",
        "key_path": "${CERT_DIR}/private.key"
      }
    }
JSON
)")
    fi

    p=$(IFS=,; printf '%s' "${parts[*]}")
    cat > "$tmp_conf" <<EOF
{
  "log": { "disabled": false, "level": "warn", "timestamp": true },
  "inbounds": [
${p}
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
    mv -f "$tmp_conf" "$CONF_FILE"
}

# 集中写入持久化环境变量
# 把 env.conf 的大写字段铺成 write_env_config 需要的小写变量。
# 三个菜单分支原先各自抄了 18 行搬运，漏一行就会静默写回旧值（NODE_PREFIX="" 那类事故）。
# 调用方可先 set_env_scene，再覆盖个别字段（如 sub_token / sub_port），然后调 write_env_config。
set_env_scene() {
    node_prefix="${1:-${NODE_PREFIX:-}}"
    server_ip="$SERVER_IP"
    vl_port="$VL_PORT"
    vl_sni="$VL_SNI"
    user_uuid="$VL_UUID"
    vl_privkey="${VL_PRIVKEY:-}"
    vl_pubkey="$VL_PUBKEY"
    vl_shortid="$VL_SHORTID"
    hy_domain="${HY_DOMAIN:-}"
    target_host="${TARGET_HOST:-$server_ip}"
    hy_port="${HY_PORT:-8443}"
    hy_password="${HY_PASS:-}"
    hy_skip_cert="${HY_SKIP_CERT:-true}"
    sub_port="${SUB_PORT:-8444}"
    sub_token="$SUB_TOKEN"
    CERT_MODE="${CERT_MODE:-selfsigned}"
    sub_proto=$(sub_scheme)
}

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

    # 槽 n>1 的桥接断言：入口端口写了就必须有完整落点，否则配置里会出现
    # 一个连向空地址的出口（sing-box check 能过，客户端连上就断）。
    local _n _f _v
    for ((_n = 2; _n <= EXIT_SLOTS_MAX; _n++)); do
        _v="EXIT${_n}_ENTRY_HY"; local _ehy="${!_v:-}"
        _v="EXIT${_n}_ENTRY_VL"; local _evl="${!_v:-}"
        _v="EXIT${_n}_SERVER";   local _srv="${!_v:-}"
        [[ -n "$_ehy$_evl$_srv" ]] || continue
        for _f in SERVER PORT PASS; do
            _v="EXIT${_n}_${_f}"
            if [[ -z "${!_v:-}" ]]; then
                echo -e "${RED}内部错误: ${_v} 为空，槽 ${_n} 参数不完整，已中止写入 ${ENV_FILE}。${PLAIN}" >&2
                return 1
            fi
        done
    done

    # 600：env.conf 含 Reality 私钥、Hy2 密码、订阅 Token，不能给其它本地用户读
    # DIRECT_SUFFIXES 是部署方的私有配置（自有域名直连），重写时必须保留：
    # 优先用内存中的值，否则从旧文件里捞回来，避免菜单改配置时被清空。
    local direct_suffixes="${DIRECT_SUFFIXES:-}"
    if [[ -z "$direct_suffixes" && -f "$ENV_FILE" ]]; then
        direct_suffixes=$(grep -oP '^DIRECT_SUFFIXES="\K[^"]*' "$ENV_FILE" 2>/dev/null || true)
    fi
    # 槽 1 沿用历史字段名（存量 env 与订阅都指着它们）；槽 2..N 用 EXIT<n>_*，
    # 由循环统一写出，加槽位只需要改 EXIT_SLOTS_MAX。
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
HY_PASS="${hy_password}"
HY_SKIP_CERT="${hy_skip_cert}"
SUB_PORT="${sub_port}"
SUB_PROTO="${sub_proto}"
SUB_TOKEN="${sub_token}"
CERT_MODE="${CERT_MODE:-selfsigned}"
DIRECT_SUFFIXES="${direct_suffixes}"
FLIP_HOST="${FLIP_HOST:-}"
SITE_FILE="${SITE_FILE:-}"
FLIP_PORT="${FLIP_PORT:-9443}"
EXIT_TYPE="${EXIT_TYPE:-none}"
EXIT_HY_SERVER="${EXIT_HY_SERVER:-}"
EXIT_HY_PORT="${EXIT_HY_PORT:-}"
EXIT_HY_PASS="${EXIT_HY_PASS:-}"
EXIT_HY_SNI="${EXIT_HY_SNI:-}"
EXIT_SKIP_CERT="${EXIT_SKIP_CERT:-false}"
EXIT_LABEL="${EXIT_LABEL:-SG}"
EXIT_ENTRY_VL="${EXIT_ENTRY_VL:-2053}"
EXIT_ENTRY_HY="${EXIT_ENTRY_HY:-2054}"
EOF
        for ((_n = 2; _n <= EXIT_SLOTS_MAX; _n++)); do
            for _f in SERVER PORT PASS SNI SKIP_CERT LABEL ENTRY_VL ENTRY_HY; do
                _v="EXIT${_n}_${_f}"
                printf 'EXIT%d_%s="%s"\n' "$_n" "$_f" "${!_v:-}" >> "$ENV_FILE"
            done
        done
    )
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    ENV_LOADED=""

}

# 校验 sing-box 配置、重启并全量刷新客户端文件与 Caddy 订阅
render_and_reload() {
    if [[ ! -x /usr/local/bin/sing-box ]]; then
        echo -e "${RED}未找到 sing-box 内核，无法应用配置。${PLAIN}"
        return 1
    fi

    # 出口字段是运行时派生的：漏 sync 会让 apply_exit_config 认为槽位为空，
    # 中转单元与 2053/2054 静默消失（本仓库发生过两次）。
    sync_env_locals

    # 不做配置回滚：调用方已经用 write_singbox_config 把新配置 mv 到正式位置，
    # 此处再备份只会备份到「刚写入的新配置」，回滚等于把坏配置复制回自己。
    # 与其保留一个假的保护，不如直接失败并要求重装（重装会用同一份输入重建）。
    apply_exit_config

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

    regen_subscription

    # setup_caddy_subscription 末尾已经 reload 过一次 Caddy，这里不再重复调用，
    # 只补一次监听校验（热重载后端口偶尔要几百毫秒才起来）。
    setup_caddy_subscription "$target_host" "$sub_token" "$sub_port" "$CERT_MODE"
    verify_caddy_listening "$sub_port" || true
}

# 公网 IPv4 探测：必须校验格式，别把代理/劫持返回的字符串当 IP 写进配置
# （曾出现 icanhazip 返回 "public-ip-xxxx" 被当成 IP，导致订阅里 server 不可解析）
detect_public_ip() {
    local ip u
    for u in https://api.ipify.org https://icanhazip.com https://ifconfig.me/ip; do
        ip=$(curl -s4m5 "$u" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || continue
        [[ "$ip" =~ ^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]] && continue
        printf '%s\n' "$ip"; return 0
    done
    return 1
}

install_node() {
    require_os >/dev/null || return 1
    require_arch >/dev/null || return 1

    if ! install_deps; then
        echo -e "${RED}基础依赖检查未通过，安装中止。${PLAIN}"
        return 1
    fi

    # 每个连接多等 200-300ms，装完再修就白测一轮。

    if [[ ! -f /usr/local/bin/sing-box ]]; then
        update_singbox_core "force" || { echo -e "${RED}内核安装失败，无法继续。${PLAIN}"; return 1; }
    fi

    mkdir -p "$CONF_DIR" "$WEB_DIR"

    # 读取既有配置，作为重置时的默认值（直接回车即沿用）
    local old_vl_port="" old_vl_sni="" old_hy_port="" old_sub_port="" old_prefix="" old_domain=""
    if [[ -f "$ENV_FILE" ]]; then
        load_env
        old_vl_port="$VL_PORT"; old_vl_sni="$VL_SNI"; old_hy_port="$HY_PORT"
        old_sub_port="$SUB_PORT"; old_prefix="$NODE_PREFIX"
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
    server_ip=$(detect_public_ip || true)
    server_ip=${server_ip:-}
    if [[ -z "$server_ip" ]]; then
        echo -e "${RED}无法探测本机公网 IPv4（curl icanhazip/ipify 均失败）。${PLAIN}"
        echo -e "${YELLOW}自签证书需要真实公网 IP，请检查网络后重试。${PLAIN}"
        return 1
    fi

    echo -e "\n${GRAY}──────── ${BOLD}[1/3] VLESS-Reality${PLAIN}"
    local vl_port
    while true; do
        ask_trim "请输入 Reality 监听端口 [默认: ${CYAN}${old_vl_port:-443}${PLAIN}]: " "${old_vl_port:-443}" vl_port
        if ! validate_port "$vl_port"; then
            echo -e "${RED}端口非法（应为 1-65535 的整数），请重新输入。${PLAIN}"; continue
        fi
        check_port_conflict "$vl_port" "tcp" "vless" && break
    done
    # 写入全局，供后续 hy_port / sub_port 的冲突校验比较（新建时 env.conf 里还没有值）
    VL_PORT="$vl_port"

    local vl_sni local_sites=() _site_default
    mapfile -t local_sites < <(local_site_domains)
    if (( ${#local_sites[@]} )); then
        if (( ${#local_sites[@]} == 1 )); then
            echo -e "${GREEN}✓ 检测到本机站点: ${local_sites[0]}${PLAIN}"
            echo -e "${GRAY}  用它做伪装域名，探测者访问该域名看到的是真实站点，伪装效果最好。${PLAIN}"
        else
            echo -e "${GREEN}✓ 检测到本机站点:${PLAIN}"
            local _i=1 _d
            for _d in "${local_sites[@]}"; do echo -e "   ${_i}) ${_d}"; _i=$((_i+1)); done
        fi
    fi
    _site_default="${local_sites[0]:-}"
    if [[ -z "$old_vl_sni" && -n "$_site_default" ]]; then
        _site_default="$_site_default"
    else
        _site_default="${old_vl_sni:-www.icloud.com}"
    fi
    while true; do
        ask "请输入 Reality 借壳伪装域名 [默认: ${CYAN}${_site_default}${PLAIN}]: " vl_sni
        vl_sni=$(trim_string "$vl_sni")
        vl_sni=${vl_sni:-$_site_default}
        if [[ "$vl_sni" == "$server_ip" ]]; then
            echo -e "${RED}Reality 伪装域名不能是本机 IP，请重新输入！${PLAIN}"; continue
        fi
        if ! validate_domain "$vl_sni"; then
            echo -e "${RED}域名格式非法（示例: www.icloud.com），请重新输入！${PLAIN}"; continue
        fi
        break
    done

    echo -e "\n${GRAY}──────── ${BOLD}[2/3] Hysteria2${PLAIN}"
    local hy_skip_cert="false"
    local cert_fell_back=""

    local hy_domain=""

    # 1. 优先检测本地已存在的域名配置
    if [[ -n "$old_domain" ]]; then
        echo -e "检测到当前已配置域名: ${CYAN}${old_domain}${PLAIN}"
        local reuse_domain=""
        ask "是否继续使用此域名？Y/n (回车沿用，输入 n 更换域名或使用 IP): " reuse_domain
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
        echo -e "${GRAY}域名需在 Cloudflare 指向 ${server_ip}（仅限 DNS，小黄云会断 UDP）；回车 = IP 自签${PLAIN}"
        if (( ${#local_sites[@]} )); then
            echo -e "${GRAY}本机站点 ${local_sites[0]} 可复用现成证书（推荐）${PLAIN}"
        fi

        while true; do
            ask "请输入域名 [回车=IP自签]: " hy_domain
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
    while true; do
        ask_trim "请输入 Hysteria2 主监听 UDP 端口 [默认: ${CYAN}${old_hy_port:-8443}${PLAIN}]: " "${old_hy_port:-8443}" hy_port
        if ! validate_port "$hy_port"; then
            echo -e "${RED}端口非法（应为 1-65535 的整数），请重新输入。${PLAIN}"; continue
        fi
        check_port_conflict "$hy_port" "udp" "hy2" && break
    done
    HY_PORT="$hy_port"

    echo -e "\n${GRAY}──────── ${BOLD}[3/3] 订阅与节点${PLAIN}"
    local sub_port
    while true; do
        ask_trim "请输入 Caddy 订阅监听端口 [默认: ${CYAN}${old_sub_port:-8444}${PLAIN}]: " "${old_sub_port:-8444}" sub_port
        if ! validate_port "$sub_port"; then
            echo -e "${RED}端口非法（应为 1-65535 的整数），请重新输入。${PLAIN}"; continue
        fi
        check_port_conflict "$sub_port" "tcp" "sub" && break
    done

    local node_prefix
    ask_trim "请输入节点名称前缀 (如 HK / US / JP) [默认: ${CYAN}${old_prefix:-Node}${PLAIN}]: " "${old_prefix:-Node}" node_prefix
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
        echo -e "${RED}Hysteria2 密码生成失败，已中止安装。${PLAIN}"
        return 1
    fi

    # 先清理本脚本可能遗留的端口跳跃规则（旧版本装的），再继续
    # 4.0 起不再使用端口跳跃：旧 iptables REDIRECT 只在这里清理一次，
    # 否则升级后那条规则会继续把 UDP 段重定向到旧端口。
    cleanup_legacy_port_hopping

    local sub_proto
    sub_proto=$(sub_scheme)

    # 自有域名直连（可选）：填了就让客户端配置把这些后缀的流量直连，不绕代理。
    # 典型用途：自建 DERP 中继、管理面板、订阅分发、SSH。留空则不插入任何规则。
    # 重装时默认沿用 env.conf 里的旧值，输入 "-" 可清空。
    local old_suffixes="${DIRECT_SUFFIXES:-}" suffixes_input=""
    echo -e "\n${CYAN}自有域名直连（可选）${PLAIN}"
    echo -e " ${GRAY}这台机器若还跑着你自己的服务（自建 DERP / 管理面板 / 订阅分发 / SSH），${PLAIN}"
    echo -e " ${GRAY}填它们的域名后缀可让这些流量在客户端里直连，不绕代理。${PLAIN}"
    echo -e " ${GRAY}多个后缀用空格分隔，例如: example.com mycorp.net${PLAIN}"
    if [[ -n "$old_suffixes" ]]; then
        ask " 直连域名后缀 [回车=${old_suffixes}，输入 - 清空]: " suffixes_input
        [[ -z "$suffixes_input" ]] && suffixes_input="$old_suffixes"
    else
        ask " 直连域名后缀 [回车=跳过]: " suffixes_input
    fi
    # 两个分支都要认 "-"：没有旧值时输入它也应静默跳过，不该走到校验里报"无效后缀"
    [[ "$suffixes_input" == "-" ]] && suffixes_input=""
    DIRECT_SUFFIXES=$(clean_suffixes "$suffixes_input")
    [[ -n "$DIRECT_SUFFIXES" ]] && echo -e " ${GREEN}✓${PLAIN} 将直连: ${DIRECT_SUFFIXES}" \
                                || echo -e " ${GRAY}已跳过（不插入任何直连规则）${PLAIN}"

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

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true

    install_simbo_command

    # 每次重装换新 Token（顺手换锁），并把旧 Token 目录与历史残留一次清干净。
    find "$WEB_DIR" -mindepth 1 -maxdepth 1 -type d ! -name "$sub_token" -exec rm -rf {} + 2>/dev/null || true

    # 订阅站不在安装层单独建：render_and_reload 内部按「先写文件、再写站点、再自检」的顺序做，
    # 安装层提前建一次会拿旧 token 去自检，导致一次无意义的 404 告警。

    # 两个协议走同一套模块（非交互入口），安装里不再另写一份配置
    if ! proto_enable_reality "$vl_port" "$vl_sni"; then
        echo -e "${RED}Reality 启用失败，安装中止（Hysteria2 未启用）。${PLAIN}"
        return 1
    fi
    if ! proto_enable_hy2 "$hy_port" "$hy_domain"; then
        echo -e "${YELLOW}Hysteria2 启用失败，Reality 已可用。${PLAIN}"
        echo -e "${YELLOW}修复后执行: simbo → 协议管理 → 启用 Hysteria2${PLAIN}"
    fi

    if [[ "${cert_fell_back:-}" == "true" ]]; then
        echo -e "${YELLOW}证书申请失败，已回退 IP 自签（客户端已自动跳过校验）。${PLAIN}"
    fi

    echo -e "\n${GRAY}====================================================${PLAIN}"
    echo -e " ${GREEN}✓${PLAIN} ${BOLD}Simple-Box 安装就绪！${PLAIN}"
    echo -e " 随时在终端输入 ${CYAN}simbo${PLAIN} 即可打开控制台。"
    echo -e "${GRAY}====================================================${PLAIN}\n"
}

# 输出可直接粘贴进 mihomo / Clash.Meta 的片段。
# 直接 cat provider.yaml，保证与订阅同源；不套 ANSI 颜色（要整段复制）。
show_clash_snippet() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未找到节点环境配置，请先执行安装！${PLAIN}"
        return 1
    fi

    # 子 shell 隔离：source env.conf 的变量不外泄到调用方作用域
    (
        load_env
        local prov="${WEB_DIR}/${SUB_TOKEN}/provider.yaml"
        if [[ ! -s "$prov" ]]; then
            regen_subscription "${SUB_TOKEN:-}" >/dev/null 2>&1 || true
        fi
        if [[ ! -s "$prov" ]]; then
            echo -e "${RED}未生成订阅文件，请先重建配置${PLAIN}"
            exit 1
        fi

        echo ""
        echo -e "${GRAY}================ Clash.Meta / Mihomo 片段 ================${PLAIN}"
        echo " 整段复制，粘到你配置的 proxies: 下面（缩进已对齐）"
        echo ""
        # 直接输出生成器的产物：直连与中转节点都在里面，不再手拼
        cat "$prov"
        echo ""
        echo -e "${GRAY}---------- 可选：把这些节点挂进策略组 ----------${PLAIN}"
        echo ""
        echo "proxy-groups:"
        echo "  - name: \"节点选择\""
        echo "    type: select"
        echo "    proxies:"
        grep -oE '^  - name: "[^"]+"' "$prov" | sed 's/^  - name: /      - /'
        echo "      - \"DIRECT\""
        echo -e "${GRAY}==========================================================${PLAIN}"
        echo ""
    )
}

# 展示单独节点链接与二维码
show_links() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未找到节点环境配置，请先执行安装！${PLAIN}"
        return 1
    fi
    load_env
    sync_env_locals

    # 链接不再手拼：直接重建订阅（生成器含链式节点），再展示 links.txt，
    # 保证「菜单里看到的」= 「客户端拉到的」。
    regen_subscription "${SUB_TOKEN:-}" >/dev/null 2>&1 || true
    local web_links="${WEB_DIR}/${SUB_TOKEN}/links.txt"
    if [[ ! -s "$web_links" ]]; then
        echo -e "${RED}未生成链接文件，请先重建配置${PLAIN}"
        return 1
    fi

    # 片段在前、链接在后：片段是「贴进配置」的动作，链接是「复制/扫码」的动作
    show_clash_snippet || true

    echo -e "\n${GRAY}==================== 原生链接 ====================${PLAIN}"
    local i=0 line name
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        i=$((i+1))
        name="${line##*#}"
        echo -e " [${i}] ${BOLD}${name}${PLAIN}"
        echo -e " ${CYAN}${line}${PLAIN}"
        if command -v qrencode &>/dev/null; then
            qrencode -t ANSIUTF8 "$line"
        fi
        echo
    done < "$web_links"
    if [[ "${EXIT_TYPE:-none}" != "none" && -n "${EXIT_SERVER:-}" ]]; then
        echo -e "${GRAY}共 ${i} 条（含中转节点 -${EXIT_LABEL:-SG}）${PLAIN}"
    else
        echo -e "${GRAY}共 ${i} 条${PLAIN}"
    fi
    echo -e "${GRAY}==============================================================${PLAIN}\n"
    read -r -p "按回车键返回主菜单..." dummy || true
}

# 彻底干净卸载
uninstall_all() {
    echo -e "${YELLOW}警告: 即将彻底卸载 sing-box 并清除所有节点、订阅与证书配置！${PLAIN}"
    echo -e "${YELLOW}      同时会删除 ${CONF_DIR}、/usr/local/share/simple-box 以及 simbo 入口本身。${PLAIN}"
    local confirm=""
    ask "确认卸载吗？(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "已取消。" && return 0

    echo -e "正在停止并移除服务..."
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload

    # 旧版本留下的端口跳跃规则一并清掉（4.0 起不再使用）
    cleanup_legacy_port_hopping

    if [[ -f "$ENV_FILE" ]]; then
        load_env
        rm -f /etc/caddy/sites/*-"${SUB_PORT:-8444}".caddy /etc/caddy/sites/simple-box*.caddy
        systemctl reload caddy 2>/dev/null || true
    fi

    # 伪装站点同样是本脚本生成的：camo-*.caddy + 它声明的 /var/www 目录一起清掉，
    # 否则卸载后残留的站点块会让 foreign_sites 判定误以为「用户还有自己的站点」，
    # 从而跳过 Caddy 卸载，站点还会指向已删除的 /etc/sing-box/cert 报错。
    local _cf _croot
    for _cf in /etc/caddy/sites/camo-*.caddy; do
        [[ -f "$_cf" ]] || continue
        _croot=$(awk '/^[[:space:]]*root \*/{print $3; exit}' "$_cf" 2>/dev/null || true)
        rm -f "$_cf"
        [[ -n "$_croot" && "$_croot" == /var/www/* ]] && rm -rf "$_croot"
    done

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

    # 标记只说明「装的时候是我写的」。用户之后在这份 Caddyfile 里加过站点或全局选项时，
    # 按标记删文件 = 连人家的站点一起删。内容不再是脚本骨架就一律按用户所有处理：
    # 保留 Caddyfile、保留 import 行、保留 caddy 包，只删本脚本的站点文件。
    if [[ "$caddyfile_created" == "true" ]] && ! caddyfile_is_ours; then
        caddyfile_created=false
        caddy_owned=false
        echo -e "${YELLOW}检测到 Caddyfile 已被修改（不再是本脚本写入的形态），将保留 Caddyfile 与 Caddy 软件包${PLAIN}"
    fi

    # 关键判定：sites 目录里是否还有「不是本脚本的」站点。
    # 场景：脚本装了 caddy（有归属标记），用户后来用这个 caddy 跑了自己的服务。
    # 此时若直接删包，用户的站点会全部停摆 —— 必须降级为「只删本站点」。
    local foreign_sites=0
    if [[ -d /etc/caddy/sites ]]; then
        foreign_sites=$(find /etc/caddy/sites -maxdepth 1 -type f \
            ! -name 'simple-box*' ! -name 'camo-*' ! -name "*-${SUB_PORT:-8444}.caddy" 2>/dev/null | wc -l)
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
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 purge -y -qq \
            -o Dpkg::Options::="--force-confold" caddy >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 autoremove -y -qq >/dev/null 2>&1 || true
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

# ==================== 出站槽位 ====================
# 结构按 N 槽写，上限由 EXIT_SLOTS_MAX 锁死（4）；env 持久化由循环按槽写出，
# 加槽位只需要改这个常量（入口端口表 EXIT_ENTRY_PORT_PAIRS 够长即可）。
# 槽 1 沿用历史字段与 tag（exit-vless-in / exit-hy2-in / exit-out），
# 槽 n>1 用 EXIT<n>_* 字段与 exit<n>-* tag。槽 1 的字段名与 tag 一个都不许改：
# 存量节点的订阅、客户端配置全都指着它们。
EXIT_SLOTS_MAX=4

# 把槽 n 映射成统一局部变量 SE_*。槽 1 读历史字段 EXIT_HY_*，
# 槽 n>1 读 EXIT<n>_*；两种都直接读 env，不依赖调用方先 sync。
exit_slot_env() {
    local n="${1:-1}" _v
    SE_TYPE="none"; SE_SERVER=""; SE_PORT=""; SE_SNI=""; SE_SKIP="false"
    SE_ENTRY_VL=""; SE_ENTRY_HY=""; SE_LABEL="SG"
    SE_PASS=""
    if [[ "$n" == "1" ]]; then
        # 槽 1 沿用历史字段（EXIT_HY_*）；旧版 Reality 出口已移除，非 hy2 一律视为无出口
        SE_LABEL="${EXIT_LABEL:-SG}"
        SE_ENTRY_VL="${EXIT_ENTRY_VL:-}"; SE_ENTRY_HY="${EXIT_ENTRY_HY:-}"
        SE_SKIP="${EXIT_SKIP_CERT:-false}"
        if [[ "${EXIT_TYPE:-none}" == "hy2" ]]; then
            SE_TYPE="hy2"
            _v="EXIT_HY_SERVER"; SE_SERVER="${!_v:-}"
            _v="EXIT_HY_PORT";   SE_PORT="${!_v:-}"
            _v="EXIT_HY_PASS";   SE_PASS="${!_v:-}"
            _v="EXIT_HY_SNI";    SE_SNI="${!_v:-}"
        fi
    else
        # 槽 n>1 只有 Hysteria2：没有 EXIT<n>_TYPE 这类字段
        _v="EXIT${n}_SERVER";    SE_SERVER="${!_v:-}"
        _v="EXIT${n}_PORT";      SE_PORT="${!_v:-}"
        _v="EXIT${n}_PASS";      SE_PASS="${!_v:-}"
        _v="EXIT${n}_SNI";       SE_SNI="${!_v:-}"
        _v="EXIT${n}_SKIP_CERT"; SE_SKIP="${!_v:-false}"
        _v="EXIT${n}_LABEL";     SE_LABEL="${!_v:-EXIT${n}}"
        _v="EXIT${n}_ENTRY_VL";  SE_ENTRY_VL="${!_v:-}"
        _v="EXIT${n}_ENTRY_HY";  SE_ENTRY_HY="${!_v:-}"
        [[ -n "$SE_SERVER" ]] && SE_TYPE="hy2"
    fi
}

# 槽位是否已配置：落点与端口都在
exit_slot_active() {
    exit_slot_env "${1:-1}"
    [[ "$SE_TYPE" != "none" && -n "$SE_SERVER" && -n "$SE_PORT" ]]
}

# 已配置的槽位编号，一行一个（订阅生成、面板、配置渲染都遍历它）
exit_active_slots() {
    local n
    for ((n = 1; n <= EXIT_SLOTS_MAX; n++)); do
        exit_slot_active "$n" && printf '%s\n' "$n"
    done
}

# 槽位对应的 inbound/outbound tag；槽 1 保持历史命名
exit_slot_tag() {
    local n="${1:-1}" kind="$2"
    [[ "$n" == "1" ]] && printf 'exit-%s' "$kind" || printf 'exit%s-%s' "$n" "$kind"
}

# 按槽位给 config.json 追加「链式入口 + 出口」；无启用槽时一个字节都不改
apply_exit_config() {
    [[ -f "$CONF_FILE" ]] || return 0
    local -a slots=() envs=()
    local n
    for n in $(exit_active_slots); do
        exit_slot_env "$n"
        slots+=("$n")
        envs+=("E${n}_SERVER=$SE_SERVER" "E${n}_PORT=$SE_PORT" \
               "E${n}_PASS=$SE_PASS" "E${n}_SNI=$SE_SNI" "E${n}_SKIP_CERT=$SE_SKIP" \
               "E${n}_ENTRY_VL=$SE_ENTRY_VL" "E${n}_ENTRY_HY=$SE_ENTRY_HY")
    done
    [[ ${#slots[@]} -gt 0 ]] || return 0
    env "${envs[@]}" EXIT_SLOTS="${slots[*]}" python3 - "$CONF_FILE" <<'PY'
import json, os, sys, copy
conf = sys.argv[1]
d = json.load(open(conf))
inb = d.get("inbounds", [])
tags = {i["tag"]: i for i in inb}

def rename(n, kind):
    return "exit-%s" % kind if n == "1" else "exit%s-%s" % (n, kind)

def clone(src_tag, new_tag, port):
    if not port or src_tag not in tags:
        return None
    c = copy.deepcopy(tags[src_tag]); c["tag"] = new_tag; c["listen_port"] = int(port)
    return c

slots = os.environ["EXIT_SLOTS"].split()
# 幂等：先摘掉上一次追加的同类单元，重复应用不会再撞 duplicate inbound tag
own = {rename(n, k) for n in slots for k in ("vless-in", "hy2-in", "out")}
inb = [i for i in inb if i["tag"] not in own]
d["outbounds"] = [o for o in d.get("outbounds", []) if o.get("tag") not in own]

entries, outs, rules = [], [], []
for n in slots:
    e = [x for x in (clone("vless-reality-in", rename(n, "vless-in"), os.environ.get("E%s_ENTRY_VL" % n)),
                     clone("hy2-in", rename(n, "hy2-in"), os.environ.get("E%s_ENTRY_HY" % n))) if x]
    out_tag = rename(n, "out")
    out = {"type": "hysteria2", "tag": out_tag,
           "server": os.environ["E%s_SERVER" % n], "server_port": int(os.environ["E%s_PORT" % n]),
           "password": os.environ["E%s_PASS" % n],
           "tls": {"enabled": True,
                   "server_name": os.environ.get("E%s_SNI" % n) or os.environ["E%s_SERVER" % n],
                   "insecure": os.environ.get("E%s_SKIP_CERT" % n) == "true"}}
    entries += e; outs.append(out)
    rules += [{"inbound": [x["tag"]], "outbound": out_tag} for x in e]

d["inbounds"] = inb + entries
d.setdefault("outbounds", []).extend(outs)
_keep = [r for r in (d.get("route") or {}).get("rules", [])
         if r.get("outbound") not in {o["tag"] for o in outs}]
d["route"] = {"rules": _keep + rules, "final": "direct"}
json.dump(d, open(conf, "w"), ensure_ascii=False, indent=2)
PY
}


# ---------------------------------------------------------------- 协议模块
# enabled 的唯一事实来源：config.json 里的 inbound
current_inbounds() {
    [[ -f "$CONF_FILE" ]] || return 0
    python3 - "$CONF_FILE" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(" ".join(i.get("tag", "") for i in d.get("inbounds", [])))
except Exception:
    pass
PY
}

set_has() { [[ " $(current_inbounds) " == *" $1 "* ]]; }

port_holder() {
    local port="$1" proto="${2:-tcp}" flag="-ltnp"
    [[ "$proto" == "udp" ]] && flag="-lunp"
    ss $flag 2>/dev/null | grep ":$port " | grep -oE 'users:\(\("[^"]+' | head -1 | sed 's/.*("//'
}

# 在 Caddy 配置里按「站点块首字段」精确找域名，避免子串误命中
# 列出本机 Caddy 站点域名（去掉端口，去重）
local_site_domains() {
    local dir="${CADDY_SITES_DIR:-/etc/caddy/sites}" f line d seen=""
    for f in "$dir"/*.caddy; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*(https?://)?([A-Za-z0-9.-]+\.[A-Za-z]{2,})(:[0-9]+)?[[:space:]]*\{ ]] || continue
            d="${BASH_REMATCH[2]}"
            [[ ",$seen," == *",$d,"* ]] && continue
            seen+="$d,"; printf '%s\n' "$d"
        done < "$f"
    done
}

# ---- 证书目录：唯一的事实来源 ----
# 证书在盘上有三种摆法（/etc/sing-box/cert、/etc/ssl/<域名>、acme.sh 的 <域名>_ecc），
# 私钥还有两种命名（private.key / <域名>.key，Caddy 只认前者）。所有寻找证书的地方
# 都必须走这里，返回值保证「Caddy 与 sing-box 都能直接用」：
#   · fullchain.cer 存在     · 私钥存在（两种命名都认）
#   · 证书覆盖该域名         · 公私钥配对
# 命名不规范时（acme.sh）就地补一份 <SSL_ROOT>/<域名>/private.key。
# 返回 0=可用目录（stdout），1=没有该域名的证书，2=有证书但不覆盖域名/不配对。
CERT_SSL_ROOT="${CERT_SSL_ROOT:-/etc/ssl}"
CERT_ACME_ROOT="${CERT_ACME_ROOT:-/root/.acme.sh}"

cert_pair_ok() {   # 证书与私钥是否配对（没有 openssl 时不阻塞）
    local crt="${1:-}" key="${2:-}" a b
    [[ -s "$crt" && -s "$key" ]] || return 1
    command -v openssl >/dev/null 2>&1 || return 0
    a=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
    b=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
    [[ -n "$a" && "$a" == "$b" ]]
}

find_cert_dir() {
    local d="${1:-}" c crt key bad=""
    [[ -n "$d" ]] || return 1
    for c in "$CERT_DIR" "${CERT_SSL_ROOT}/$d" "${CERT_SSL_ROOT}/${d%%.*}" "${CERT_ACME_ROOT}/${d}_ecc"; do
        crt="$c/fullchain.cer"
        [[ -f "$crt" ]] || continue
        key="$c/private.key"; [[ -f "$key" ]] || key="$c/$d.key"
        [[ -f "$key" ]] || continue
        cert_covers_host "$crt" "$d" || { bad="${bad:-$crt}"; continue; }
        cert_pair_ok "$crt" "$key" || { bad="${bad:-$crt}"; continue; }
        if [[ "$key" != "$c/private.key" ]]; then
            install -d -m 755 "${CERT_SSL_ROOT}/$d" 2>/dev/null || return 1
            install -m 644 "$crt" "${CERT_SSL_ROOT}/$d/fullchain.cer" || return 1
            install -m 640 -g caddy "$key" "${CERT_SSL_ROOT}/$d/private.key" 2>/dev/null \
                || install -m 600 "$key" "${CERT_SSL_ROOT}/$d/private.key" || return 1
            c="${CERT_SSL_ROOT}/$d"
        fi
        printf '%s\n' "$c"; return 0
    done
    [[ -n "$bad" ]] && echo -e "${YELLOW}证书校验未通过：${bad}（域名不匹配或公私钥不成对）${PLAIN}" >&2
    [[ -n "$bad" ]] && return 2
    return 1
}

# 把一份证书装进目标目录，统一成 fullchain.cer + private.key（唯一改权限的地方）
install_cert_to() {
    local src="${1:-}" dst="${2:-}"
    [[ -f "$src/fullchain.cer" && -f "$src/private.key" && -n "$dst" ]] || return 1
    mkdir -p "$dst" || return 1
    install -m 644 "$src/fullchain.cer" "$dst/fullchain.cer" || return 1
    install -m 640 -g caddy "$src/private.key" "$dst/private.key" 2>/dev/null \
        || install -m 600 "$src/private.key" "$dst/private.key" || return 1
}

site_file_for() {
    local d="${1//./\\.}" f hits=()
    local dir="${CADDY_SITES_DIR:-/etc/caddy/sites}" main="${CADDYFILE:-/etc/caddy/Caddyfile}"
    for f in "$dir"/*.caddy "$main"; do
        [[ -f "$f" ]] || continue
        grep -qE "^[[:space:]]*(https?://)?${d}(:[0-9]+)?[[:space:]]*\{" "$f" && hits+=("$f")
    done
    (( ${#hits[@]} )) || return 1
    printf '%s\n' "${hits[0]}"
}

# 站点块里显式 tls 指向的证书是否可用。返回 0 = 没写 tls（Caddy 自管，无法判断）或可用；
# 返回 1 并把原因打到 stdout。站点是 Reality 的回落目标，证书坏了等于所有客户端握手失败。
site_cert_problem() {
    local file="${1:-}" domain="${2:-}" crt="" key=""
    [[ -f "$file" && -n "$domain" ]] || return 0
    read -r crt key < <(awk '/^[[:space:]]*tls[[:space:]]/{print $2, $3; exit}' "$file")
    [[ -n "${crt:-}" ]] || return 0
    [[ -f "$crt" && -n "${key:-}" && -f "$key" ]] || { printf '证书或私钥文件缺失: %s\n' "$crt"; return 1; }
    cert_covers_host "$crt" "$domain" || { printf '证书不覆盖 %s\n' "$domain"; return 1; }
    cert_pair_ok "$crt" "$key" || { printf '证书与私钥不配对: %s\n' "$crt"; return 1; }
    openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1 || { printf '证书已过期: %s\n' "$crt"; return 1; }
    return 0
}

# 有站点块直接引用 CERT_DIR 的证书（翻转后的伪装站、接入域站点）。
# 这些站点一旦被 IP 自签覆盖就会当场失效，所以证书降级前必须先问一句。
sites_using_cert_dir() {
    local dir="${CADDY_SITES_DIR:-/etc/caddy/sites}" main="${CADDYFILE:-/etc/caddy/Caddyfile}" f
    for f in "$dir"/*.caddy "$main"; do
        [[ -f "$f" ]] || continue
        grep -qE "^[[:space:]]*tls[[:space:]]+${CERT_DIR}/" "$f" && printf '%s\n' "$f"
    done
    return 0
}

# 外部伪装域名必须支持 TLS 1.3 + h2，否则 Reality 握手失败但配置看起来正常
probe_external_sni() {
    local d="$1"
    timeout 8 openssl s_client -connect "${d}:443" -servername "$d" -tls1_3 -alpn h2 </dev/null 2>/dev/null \
        | grep -q "ALPN protocol: h2"
}

# 证书是否覆盖某个域名（含通配符）。没有 openssl 时不阻塞流程。
cert_covers_host() {
    local cert="$1" host="$2"
    [[ -f "$cert" && -n "$host" ]] || return 1
    command -v openssl >/dev/null 2>&1 || return 0
    openssl x509 -in "$cert" -noout -checkhost "$host" 2>/dev/null | grep -q "does match"
}

sync_hy2_cert() {
    local d="${1:-}" src rc=0
    [[ -n "$d" ]] || return 1
    src=$(find_cert_dir "$d") || rc=$?
    if [[ "$rc" -eq 2 ]]; then return 2; fi
    if [[ "$rc" -ne 0 || -z "$src" ]]; then return 1; fi
    [[ "$src" == "$CERT_DIR" ]] && return 0        # 已就位
    install_cert_to "$src" "$CERT_DIR"
}

ensure_reality_creds() {
    [[ -n "${VL_UUID:-}" && -n "${VL_PRIVKEY:-}" ]] && return 0
    local kp
    kp=$(/usr/local/bin/sing-box generate reality-keypair) || return 1
    VL_PRIVKEY=$(awk '/PrivateKey/{print $2}' <<<"$kp")
    VL_PUBKEY=$(awk '/PublicKey/{print $2}' <<<"$kp")
    VL_SHORTID=$(/usr/local/bin/sing-box generate rand 8 --hex)
    VL_UUID=$(/usr/local/bin/sing-box generate uuid)
}

# 把大写 env 变量搬进 write_env_config 需要的变量名
sync_env_locals() {
    EXIT_TYPE="${EXIT_TYPE:-none}"; EXIT_SKIP_CERT="${EXIT_SKIP_CERT:-false}"
    EXIT_LABEL="${EXIT_LABEL:-SG}"; EXIT_ENTRY_VL="${EXIT_ENTRY_VL:-}"; EXIT_ENTRY_HY="${EXIT_ENTRY_HY:-}"
    # 槽 1 只支持 Hysteria2 落地；这里只派生「有无中转」判断用的地址。
    EXIT_SERVER=""
    [[ "$EXIT_TYPE" == "hy2" ]] && EXIT_SERVER="${EXIT_HY_SERVER:-}"
    EXIT_SNI="${EXIT_HY_SNI:-}"
    node_prefix="$NODE_PREFIX"; server_ip="$SERVER_IP"
    vl_port="$VL_PORT"; vl_sni="$VL_SNI"; user_uuid="$VL_UUID"
    vl_privkey="$VL_PRIVKEY"; vl_pubkey="$VL_PUBKEY"; vl_shortid="$VL_SHORTID"
    hy_domain="${HY_DOMAIN:-}"; target_host="${TARGET_HOST:-$SERVER_IP}"
    hy_port="$HY_PORT"; hy_password="$HY_PASS"
    hy_skip_cert="${HY_SKIP_CERT:-false}"; sub_port="$SUB_PORT"
    sub_proto=$(sub_scheme); sub_token="$SUB_TOKEN"
}

# 当前已在 config.json 里的协议集合（供菜单/出口重建使用）。
# 注意：不能在「即将启用某协议」的路径里用，那一刻它还没写进配置。
current_set() {
    local set=""
    set_has "vless-reality-in" && set="reality"
    set_has "hy2-in" && set="${set:+$set }hy2"
    printf '%s\n' "$set"
}

# 出口连通性自检 + 结果播报（三态）
report_exit_health() {
    exit_health_check "${1:-1}"
    case $? in
        0) echo -e "${GREEN}✓ 出站连通性正常${PLAIN}" ;;
        1) echo -e "${RED}✗ 出站连不通${PLAIN}"
           echo -e "${YELLOW}  检查落地机与端口放行${PLAIN}" ;;
        2) echo -e "${YELLOW}⚠ 出站 IP 与落地机不一致（对方可能也在中转）${PLAIN}" ;;
    esac
}

# 保存出口参数 → 重建配置 → 重载服务（菜单里三个入口共用）
apply_exit_reload() {
    sync_env_locals
    write_env_config || return 1
    render_set "$(current_set)" || return 1
    sync_env_locals
    render_and_reload
}

# 按启用集合写 config.json；集合来自 config.json 本身，不另设开关
render_set() {
    local set=" $1 " vl_p="" hy_p=""
    [[ "$set" == *" reality "* ]] && vl_p="$VL_PORT"
    [[ "$set" == *" hy2 "* ]] && hy_p="$HY_PORT"
    # 翻转不落库：VL_SNI 在本机 Caddy 里有站点块 → 回落 127.0.0.1:FLIP_PORT，
    # 否则直接用该域名（外部 SNI）。只有这一个判据。
    local hs="${VL_SNI:-}" hsp="443"
    if [[ -n "${VL_SNI:-}" ]] && site_file_for "$VL_SNI" >/dev/null 2>&1; then
        hs="127.0.0.1"; hsp="${FLIP_PORT:-9443}"
        SITE_FILE="$(site_file_for "$VL_SNI")"; FLIP_HOST="$VL_SNI"
    fi
    write_singbox_config "$vl_p" "${VL_SNI:-}" "${VL_UUID:-}" "${VL_PRIVKEY:-}" "${VL_SHORTID:-}" \
        "$hy_p" "${HY_PASS:-}" "$hs" "$hsp"
}

proto_enable_reality() {
    # 传参 = 非交互（安装向导用）；不传参 = 交互（协议菜单用）
    local port="${1:-}" sni="${2:-}" interactive=1
    if [[ $# -gt 0 ]]; then interactive=0; fi
    load_env || { echo -e "${RED}未检测到已安装的配置${PLAIN}"; return 1; }
    ensure_reality_creds || return 1

    if [[ "$interactive" == 1 ]]; then
        if [[ -n "${VL_PORT:-}" && -n "${VL_SNI:-}" ]]; then
            echo -e " 当前参数: 端口 ${CYAN}${VL_PORT}${PLAIN} / 伪装域名 ${CYAN}${VL_SNI}${PLAIN}"
            local okp=""
            ask "沿用这组参数？[Y/n]: " okp
            if [[ "${okp,,}" == "n" ]]; then
                ask_trim "请输入 Reality 监听端口 [默认: ${CYAN}${VL_PORT}${PLAIN}]: " "${VL_PORT}" port
                ask_trim "请输入 Reality 伪装域名 [默认: ${CYAN}${VL_SNI}${PLAIN}]: " "${VL_SNI}" sni
            fi
        else
            ask_trim "请输入 Reality 监听端口 [默认: ${CYAN}${VL_PORT:-443}${PLAIN}]: " "${VL_PORT:-443}" port
            ask_trim "请输入 Reality 伪装域名 [默认: ${CYAN}${VL_SNI:-www.icloud.com}${PLAIN}]: " "${VL_SNI:-www.icloud.com}" sni
        fi
    fi
    port="${port:-${VL_PORT:-443}}"; sni="${sni:-${VL_SNI:-www.icloud.com}}"
    validate_port "$port" || return 1
    validate_domain "$sni" || return 1

    # 检查点 B：这个域名在本机有没有站点
    local site=""
    if site=$(site_file_for "$sni"); then
        echo -e "${GREEN}✓ 找到本机站点 ${site}${PLAIN}"
        # 站点是 Reality 的回落目标：它出示的证书坏了，所有客户端握手都会失败，
        # 而配置、进程、订阅看起来全绿。显式 tls 的站点能在启用前就判掉。
        local _cert_why
        if ! _cert_why=$(site_cert_problem "$site" "$sni"); then
            echo -e "${RED}✗ 本机站点 ${site} 的证书不可用：${_cert_why}${PLAIN}"
            echo -e "${YELLOW}  站点是 Reality 的回落目标，证书坏了会让所有客户端握手失败，已中止${PLAIN}"
            echo -e "${YELLOW}  续期或重签该域名的证书后重试（simbo → 8. 伪装站点 / 证书签发）${PLAIN}"
            return 1
        fi
        echo -e "  Reality 占用 ${port}，站点回落到 127.0.0.1:${FLIP_PORT:-9443}"
    else
        # 域名解析到本机 = 这是自己的域名：可以现场建一个伪装站，比借外部站更自洽
        if [[ "$interactive" == 1 ]] && check_domain_ip_binding "$sni" "${SERVER_IP:-}" >/dev/null 2>&1; then
            echo -e "${YELLOW}本机没有 ${sni} 的站点，但该域名解析到本机。${PLAIN}"
            local want_site=""
            ask "现在就为它生成一个伪装站点（证书/站点/绑定一次做完）？[y/N]: " want_site
            if [[ "${want_site,,}" == y* ]]; then
                build_camo_site "$sni" "$(camo_pick_source "$sni")" "" || true
                site=$(site_file_for "$sni" 2>/dev/null || true)
                [[ -n "$site" ]] && echo -e "${GREEN}✓ 站点已就绪：${site}${PLAIN}"
            fi
        fi
        if [[ -n "$site" ]]; then
            :
        else
            echo -e "${YELLOW}本机没有 ${sni} 的站点，按外部伪装域名校验 TLS 1.3 + h2 ...${PLAIN}"
            if ! probe_external_sni "$sni"; then
                echo -e "${RED}✗ ${sni} 不支持 TLS 1.3 + h2 或不可达${PLAIN}"
                echo -e "${YELLOW}  换一个域名，或先在本机建好站点再启用。${PLAIN}"
                return 1
            fi
            echo -e "${GREEN}✓ 外部伪装域名可用${PLAIN}"
        fi
    fi

    # 检查点 A：端口归属
    local holder; holder=$(port_holder "$port" tcp)
    if [[ -n "$holder" && "$holder" != *sing-box* ]]; then
        if [[ "$holder" == *caddy* && -n "$site" ]]; then
            echo -e "${YELLOW}${port} 现在由 Caddy 的站点占用，将迁移到 127.0.0.1:${FLIP_PORT:-9443}${PLAIN}"
        else
            echo -e "${RED}✗ ${port} 已被 ${holder} 占用，无法启用 Reality${PLAIN}"
            return 1
        fi
    fi

    # 有本机站点时，只能把站点搬到回环、由 Reality 在 443 上代它回落。
    # Reality 换到非 443 端口时 443 会彻底空着，站点从此在公网消失（比不伪装更可疑）。
    # 宁可直接拒绝，也不做这种「成功了一半」的迁移。
    if [[ -n "$site" && "$port" != "443" ]]; then
        echo -e "${RED}✗ ${sni} 在本机有站点（${site}），Reality 只能监听 443 才能让它继续对外服务${PLAIN}"
        echo -e "${YELLOW}  二选一：① Reality 端口用 443；② 伪装域名换成外部借壳域名（如 www.icloud.com）${PLAIN}"
        return 1
    fi

    VL_PORT="$port"; VL_SNI="$sni"
    SITE_FILE="$site"; FLIP_HOST="${site:+$sni}"; FLIP_PORT="${FLIP_PORT:-9443}"

    # Reality 此刻还没写进 config.json，current_set 会漏掉自己，这里显式拼
    local set="reality"
    set_has "hy2-in" && set="reality hy2"
    render_set "$set" || return 1
    sync_env_locals; write_env_config || return 1

    [[ -n "$site" ]] && { flip_site_toggle on || return 1; }
    sync_env_locals   # render_and_reload 里的 regen_subscription 读小写变量
    render_and_reload || return 1
    echo -e "${GREEN}✓ Reality 已启用${PLAIN}"
}

proto_enable_hy2() {
    # 传参 = 非交互（安装向导用）；不传参 = 交互（协议菜单用）
    local port="" domain="" interactive=1
    if [[ $# -gt 0 ]]; then
        interactive=0; port="${1:-}"; domain="${2:-}"
    fi
    load_env || { echo -e "${RED}未检测到已安装的配置${PLAIN}"; return 1; }

    if [[ "$interactive" == 1 ]]; then
        # 三样都先从 env 取当前值：reuse 分支不重新赋值，漏掉 domain 就会在
        # 「沿用」之后把 HY_DOMAIN 写成空串，静默降级成 IP 自签（协议看着仍启用）。
        port="${HY_PORT:-}"; domain="${HY_DOMAIN:-}"
        echo -e " 当前参数: 端口 ${CYAN}${HY_PORT:-—}${PLAIN} / 域名 ${CYAN}${HY_DOMAIN:-无}${PLAIN}"
        local okh=""
        ask "沿用这组参数？[Y/n]: " okh
        if [[ "${okh,,}" == "n" ]]; then
            ask_trim "请输入 Hysteria2 域名 [默认: ${CYAN}${HY_DOMAIN:-留空=IP自签}${PLAIN}]: " "${HY_DOMAIN:-}" domain
            ask_trim "请输入 Hysteria2 端口 [默认: ${CYAN}${HY_PORT:-10443}${PLAIN}]: " "${HY_PORT:-10443}" port
        fi
    fi
    port="${port:-${HY_PORT:-10443}}"
    validate_port "$port" || return 1

    # 端口已被本机 sing-box 占用 = 就是这条协议自己在跑，跳过"被占用"判定（幂等重启）
    local holder; holder=$(port_holder "$port" udp)
    if [[ -z "$holder" || "$holder" != *sing-box* ]]; then
        check_port_conflict "$port" "udp" "hy2" || return 1
    fi

    HY_DOMAIN="$domain"; HY_PORT="$port"
    [[ -z "${HY_PASS:-}" ]] && HY_PASS=$(/usr/local/bin/sing-box generate rand --base64 16)
    # 初值必须是 0：写成 1 时「成功」路径不会赋值，分支永远走到「未找到证书」，
    # 结果是把有效域名证书的节点标成 skip-cert-verify（真实故障，不只是提示错）。
    local cert_rc=0
    if [[ -n "$domain" ]]; then
        sync_hy2_cert "$domain" || cert_rc=$?
    fi
    if [[ "$cert_rc" -eq 2 ]]; then
        echo -e "${RED}证书与域名不匹配，已中止启用 Hysteria2（换证书或改域名后重试）${PLAIN}"
        return 1
    elif [[ "$cert_rc" -eq 0 ]]; then
        HY_SKIP_CERT="false"
        echo -e "${GREEN}✓ 已同步 ${domain} 的证书${PLAIN}"
    else
        # 域名有值却找不到该域名的证书：CERT_DIR 里躺的是别的证书（旧域名 / IP 自签），
        # 继续启用只会得到「[已启用] 但客户端 x509 域名不匹配」。只有已明确 skip 的
        # 存量节点才放行（否则会打断一台本来能用的机器），其余一律中止。
        if [[ "${HY_SKIP_CERT:-false}" == "true" ]]; then
            echo -e "${YELLOW}未找到 ${domain} 的证书，沿用现有证书并保持 skip-cert-verify=true${PLAIN}"
        else
            echo -e "${RED}✗ 没有 ${domain} 的可用证书，已中止启用 Hysteria2${PLAIN}"
            echo -e "${YELLOW}  先让本机拥有该域名的证书（重跑安装向导，或菜单 8 建站时自动签发），或把域名留空改用 IP 自签${PLAIN}"
            return 1
        fi
    fi

    local set="hy2"; set_has "vless-reality-in" && set="reality hy2"
    render_set "$set" || return 1
    sync_env_locals; write_env_config || return 1
    sync_env_locals
    render_and_reload || return 1
    echo -e "${GREEN}✓ Hysteria2 已启用${PLAIN}"
}

menu_sub_module() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未检测到已安装的配置，请先运行选项 6 重新安装Simple-Box！${PLAIN}"
        read -r -p "按回车键返回..." dummy || true
        return 0
    fi
    load_env

    while true; do
        [ -t 1 ] && clear
        echo -e "
${GRAY}================= Clash 订阅地址配置 =================${PLAIN}"
        echo -e " 1. 重置并更新 Clash 订阅地址参数"
        echo -e " 2. 重置并更新节点名称前缀"
        echo -e " 3. 自有域名直连设置（可选）"
        echo -e " 0. 返回主菜单"
        echo -e "${GRAY}======================================================${PLAIN}"
        local opt=""
        ask "请输入选项 [0-3]: " opt
        [[ "$ASK_EOF" == "1" ]] && break
        case "$opt" in
            1)
                echo -e "\n${YELLOW}=== Clash 订阅地址参数 ===${PLAIN}"
                local sub_port
                while true; do
                    ask_trim "请输入新的订阅监听端口 [默认: ${CYAN}${SUB_PORT}${PLAIN}]: " "${SUB_PORT}" sub_port
                    if ! validate_port "$sub_port"; then
                        echo -e "${RED}端口非法，请重新输入。${PLAIN}"; continue
                    fi
                    [[ "$sub_port" == "$SUB_PORT" ]] && break
                    check_port_conflict "$sub_port" "tcp" "sub" && break
                done

                local rotate_token=""
                ask "是否同时刷新订阅 Token (旧链接将立即 404 作废)？[y/N]: " rotate_token
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
                set_env_scene
                sub_token="$new_token"
                if ! write_env_config; then
                    echo -e "${RED}订阅参数写入失败，配置未变更。${PLAIN}"
                    read -r -p "按回车键返回..." dummy || true
                    continue
                fi

                regen_subscription "$new_token"

                setup_caddy_subscription "$target_host" "$new_token" "$SUB_PORT" "$CERT_MODE"
                # setup_caddy_subscription 末尾已 reload，此处只补监听校验
                verify_caddy_listening "$SUB_PORT" || true

                echo -e "\n${GREEN}✓ 在线订阅地址已成功更新！${PLAIN}"
                echo -e "当前在线订阅: ${CYAN}${sub_proto}://${target_host}:${SUB_PORT}/${new_token}/config.yaml${PLAIN}"
                echo -e "${YELLOW}提示: 订阅参数已更新，请在客户端 (如 ClashX.Meta) 中修改端口或更新订阅 URL。${PLAIN}"
                read -r -p "按回车键返回..." dummy || true
                load_env
                ;;
            2)
                echo -e "\n${YELLOW}=== 重置节点名称前缀 ===${PLAIN}"
                echo -e "${CYAN}前缀用于节点显示名，如 HK-VLESS-Reality、US-Hysteria2。${PLAIN}"
                echo -e "${CYAN}会过滤引号、逗号、井号、冒号与反斜杠，避免破坏 YAML 与分享链接。${PLAIN}"
                local new_prefix=""
                while true; do
                    ask_trim "请输入节点名称前缀 [当前: ${CYAN}${NODE_PREFIX:-Node}${PLAIN}]: " "${NODE_PREFIX:-Node}" new_prefix
                    new_prefix=$(printf '%s' "$new_prefix" | tr -d '\"'"'"',#:\\')
                    if [[ -z "$new_prefix" ]]; then
                        echo -e "${RED}前缀不能为空（过滤特殊字符后为空），请重新输入。${PLAIN}"; continue
                    fi
                    break
                done

                set_env_scene "$new_prefix"

                if ! write_env_config; then
                    echo -e "${RED}节点前缀写入失败，配置未变更。${PLAIN}"
                    read -r -p "按回车键返回..." dummy || true
                    continue
                fi

                regen_subscription

                echo -e "\n${GREEN}✓ 节点名称前缀已更新为: ${new_prefix}${PLAIN}"
                echo -e "提示: 订阅链接保持不变，客户端点击「更新订阅」即可同步新节点名。"
                read -r -p "按回车键返回..." dummy || true
                load_env
                ;;
            3)
                echo -e "\n${YELLOW}=== 自有域名直连 ===${PLAIN}"
                echo -e "${CYAN}填了之后，客户端配置会把这些后缀的流量直连，不绕代理。${PLAIN}"
                echo -e "${CYAN}典型用途：自建 DERP 中继、管理面板、订阅分发、SSH。${PLAIN}"
                echo -e "${CYAN}留空表示不插入任何直连规则（不影响节点本身）。${PLAIN}"
                echo -e "当前设置: ${CYAN}${DIRECT_SUFFIXES:-（未设置）}${PLAIN}"
                local suffixes_input=""
                ask "请输入域名后缀（空格分隔，输入 - 清空，回车保持不变）: " suffixes_input
                if [[ -z "$suffixes_input" ]]; then
                    echo -e "${GRAY}保持不变。${PLAIN}"
                    read -r -p "按回车键返回..." dummy || true
                    continue
                fi
                [[ "$suffixes_input" == "-" ]] && suffixes_input=""
                DIRECT_SUFFIXES=$(clean_suffixes "$suffixes_input")

                set_env_scene

                if ! write_env_config; then
                    echo -e "${RED}写入失败，配置未变更。${PLAIN}"
                    read -r -p "按回车键返回..." dummy || true
                    continue
                fi

                regen_subscription

                echo -e "\n${GREEN}✓ 自有域名直连设置已保存${PLAIN}"
                if [[ -n "$DIRECT_SUFFIXES" ]]; then
                    echo -e " 将直连: ${CYAN}${DIRECT_SUFFIXES}${PLAIN}"
                else
                    echo -e " 已清空: 订阅配置不插入任何直连规则。"
                fi
                echo -e "${YELLOW}提示: 客户端点击「更新订阅」即可同步。${PLAIN}"
                read -r -p "按回车键返回..." dummy || true
                load_env
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
        ask "请输入选项 [0-3]: " opt
        [[ "$ASK_EOF" == "1" ]] && break
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

# 用当前 env 变量重建订阅；端口传空表示该协议未启用，SNI 可选覆盖
regen_from_scope() {
    # 注意用 ${1-...} 而不是 ${1:-...}：空串表示「该协议未启用」，不能被默认值顶回来
    local vl_p="${1-$VL_PORT}" hy_p="${2-$HY_PORT}" vl_s="${3:-$VL_SNI}"
    local server_ip="$SERVER_IP" target_host="${TARGET_HOST:-$HY_DOMAIN}" sub_token="$SUB_TOKEN"
    local node_prefix="$NODE_PREFIX" vl_port="$vl_p" user_uuid="$VL_UUID" vl_sni="$vl_s"
    local vl_pubkey="$VL_PUBKEY" vl_shortid="$VL_SHORTID" hy_port="$hy_p"
    local hy_password="$HY_PASS" hy_skip_cert="$HY_SKIP_CERT" direct_suffixes="${DIRECT_SUFFIXES:-}"
    regen_subscription "$sub_token" >/dev/null 2>&1 || true
}


# ---------------------------------------------------------------- 协议停用 / 启用
# 翻转：把伪装站搬到 127.0.0.1:9443（on）或搬回公网 443（off）
flip_site_toggle() {
    local mode="$1"
    local site="${SITE_FILE:-}" domain="${FLIP_HOST:-}" port="${FLIP_PORT:-9443}"
    [[ -n "$site" && -f "$site" && -n "$domain" ]] || return 0
    local backup; backup=$(mktemp /tmp/caddy-site.XXXXXX)
    cp -f "$site" "$backup" || return 1
    if ! flip_transform "$site" "$domain" "$port" "$mode"; then
        cp -f "$backup" "$site"; rm -f "$backup"
        echo -e "${RED}✗ 站点块首行无法识别（需写成 ${domain} { 或 ${domain}:端口 {），已还原文件${PLAIN}"
        return 1
    fi
    if ! caddy validate --config "${CADDYFILE:-/etc/caddy/Caddyfile}" >/dev/null 2>&1; then
        cp -f "$backup" "$site"; rm -f "$backup"
        echo -e "${RED}✗ Caddy 配置校验失败，已还原站点文件${PLAIN}"
        return 1
    fi
    rm -f "$backup"
    # 用 reload 而不是 restart：连续翻转/建站会撞 systemd 的 start-limit-hit（5 次/10 秒）
    reload_caddy_safe
}

# 纯文件变换（可单测）：只改站点块的监听地址与 bind，不动其它内容
# 块首行按「行首 + 域名 + 可选 scheme/端口 + {」匹配，绝不裸子串替换：
#   裸 replace("domain {", ...) 会漏掉 `domain:443 {` / `https://domain {` 两种写法
#   （此时 site_file_for 已经命中、校验也通过，但文件一字未改 → 443 仍被 Caddy 占着，
#    紧接着 sing-box restart 报 bind: address already in use，节点当场死掉），
#   也会误改 `sub.domain {` 里的子串。匹配不到就返回 2，由调用方还原并报错。
flip_transform() {
    python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import sys, pathlib, re
site, domain, port, mode = sys.argv[1:5]
p = pathlib.Path(site); s = p.read_text()
d = re.escape(domain)
head = re.compile(r"^(?P<indent>[ \t]*)(?:https?://)?" + d + r"(?::[0-9]+)?[ \t]*\{", re.M)
flipped_addr = "https://%s:%s {" % (domain, port)
on_head = re.compile(r"^(?P<indent>[ \t]*)https://" + d + r":" + re.escape(port) + r"[ \t]*\{", re.M)

if mode == "on":
    if flipped_addr in s:
        print("already flipped"); sys.exit(0)
    m = head.search(s)
    if not m:
        sys.stderr.write("找不到 %s 的站点块首行（写成 %s { 或 %s:端口 { 均可）\n" % (domain, domain, domain))
        sys.exit(2)
    new_head = m.group("indent") + flipped_addr
    rest = s[m.end():]
    if "bind 127.0.0.1" in s:
        s = s[:m.start()] + new_head + rest
    else:
        s = s[:m.start()] + new_head + "\n\tbind 127.0.0.1" + rest
else:
    m = on_head.search(s)
    if not m:
        print("already plain"); sys.exit(0)
    rest = s[m.end():]
    # 只摘掉块首行后面紧跟的那一行 bind，不碰用户自己写的其它 bind
    rest = re.sub(r"^\n[ \t]*bind 127\.0\.0\.1[ \t]*(?=\n|$)", "", rest, count=1)
    s = s[:m.start()] + m.group("indent") + domain + " {" + rest
p.write_text(s)
PYEOF
}

# 停用某个协议：从 config 移除 inbound，重建订阅；Reality 还要退出翻转
disable_protocol() {
    local which="$1"
    load_env || { echo -e "${RED}未检测到已安装的配置${PLAIN}"; return 1; }
    # EXIT_SERVER/PORT 是运行时派生字段；不 sync 的话 apply_exit_config 会因
    # EXIT_SERVER 为空直接返回，中转单元照样被抹掉
    sync_env_locals
    local label tag keep
    label="$(proto_human "$which")"; tag="$(proto_tag "$which")"
    keep="hy2"; [[ "$which" == "hy2" ]] && keep="reality"

    if ! set_has "$tag"; then
        echo -e "${YELLOW}${label} 当前未启用${PLAIN}"
        return 0
    fi

    local set="$keep"
    set_has "$(proto_tag "$keep")" || set=""
    render_set "$set" || return 1
    # render_set 只写主 inbound；中转单元由 apply_exit_config 追加，漏了这一步
    # 停用任一协议都会把 exit-*-in / exit-out 从配置里抹掉，链式入口静默变死端口
    apply_exit_config
    systemctl restart sing-box || return 1

    # Reality 停用后 443 空出来，把站点搬回去；SITE_FILE 缺失时按域名重新发现
    if [[ "$which" == "reality" ]]; then
        [[ -z "${SITE_FILE:-}" && -n "${VL_SNI:-}" ]] && SITE_FILE="$(site_file_for "$VL_SNI" 2>/dev/null || true)"
        [[ -n "${SITE_FILE:-}" ]] && { FLIP_HOST="${VL_SNI:-}"; flip_site_toggle off || return 1; }
    fi

    local vp="$VL_PORT" hp="$HY_PORT"
    [[ "$which" == "reality" ]] && vp=""
    [[ "$which" == "hy2" ]] && hp=""
    regen_from_scope "$vp" "$hp"
    echo -e "${GREEN}✓ 已停用 ${label}${PLAIN}"
    echo -e "  恢复：simbo → 协议管理 → 启用 ${label}"
}


# 从订阅 URL（provider.yaml）导入出口参数；打印 KEY<TAB>VALUE 供白名单赋值
# $2 = 槽位号：1（缺省）输出历史的 EXIT_HY_*；n>1 输出 EXIT<n>_SERVER/PORT/PASS/SNI。
# 出口只支持 Hysteria2：订阅里没有 hy2 节点就判定导入失败。
exit_parse_url() {
    local url="${1:-}" slot="${2:-1}"
    local body
    body=$(curl -fsSk -m 20 "$url" 2>/dev/null) || return 1
    local tmpf; tmpf=$(mktemp /tmp/exitimport.XXXXXX)
    printf '%s' "$body" > "$tmpf"
    python3 - "$tmpf" "$slot" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
blocks, cur = [], None
for ln in lines:
    if ln.strip().startswith("- name:"):
        if cur: blocks.append(cur)
        cur = {"__name": ln.split(":", 1)[1].strip().strip('"')}
        continue
    if cur is None:
        continue
    st = ln.strip()
    if st.startswith("reality-opts:"):
        cur["__reality"] = True
        continue
    if ":" in st and not st.startswith("#"):
        k, v = st.split(":", 1)
        cur.setdefault(k.strip(), v.strip().strip('"'))
if cur: blocks.append(cur)

def pick(t):
    for b in blocks:
        if b.get("type") == t: return b
    return None

b = pick("hysteria2")
if b:
    if sys.argv[2] != "1":
        for k, v in ((f"EXIT{sys.argv[2]}_SERVER", b.get("server", "")),
                     (f"EXIT{sys.argv[2]}_PORT", b.get("port", "")),
                     (f"EXIT{sys.argv[2]}_PASS", b.get("password", "")),
                     (f"EXIT{sys.argv[2]}_SNI", b.get("sni") or b.get("server", ""))):
            print(f"{k}\t{v}")
        sys.exit(0)
    for k, v in (("EXIT_HY_SERVER", b.get("server", "")),
                 ("EXIT_HY_PORT", b.get("port", "")), ("EXIT_HY_PASS", b.get("password", "")),
                 ("EXIT_HY_SNI", b.get("sni") or b.get("server", ""))):
        print(f"{k}\t{v}")
    sys.exit(0)
sys.exit(1)
PY
    local rc=$?
    rm -f "$tmpf"
    return $rc
}

# 出口生效性自检：起临时 socks 走该槽的出口，看出口 IP 是否符合预期
# 返回 0=正常 1=连不通 2=IP 不符
exit_health_check() {
    local n="${1:-1}" port=11080 tmp got want out_tag
    out_tag="$(exit_slot_tag "$n" out)"
    exit_slot_env "$n"
    tmp=$(mktemp /tmp/exitprobe.XXXXXX.json)
    python3 - "$CONF_FILE" "$tmp" "$port" "$out_tag" <<'PY' || { rm -f "$tmp"; return 1; }
import json, sys
d = json.load(open(sys.argv[1]))
out = [o for o in d.get("outbounds", []) if o.get("tag") == sys.argv[4]]
if not out:
    sys.exit(1)
cfg = {"log": {"level": "error"},
       "inbounds": [{"type": "socks", "tag": "in", "listen": "127.0.0.1", "listen_port": int(sys.argv[3])}],
       "outbounds": out}
json.dump(cfg, open(sys.argv[2], "w"))
PY
    /usr/local/bin/sing-box run -c "$tmp" >/dev/null 2>&1 &
    local pid=$!
    sleep 2
    got=$(curl -s -m 15 --socks5-hostname "127.0.0.1:${port}" https://api.ipify.org 2>/dev/null || true)
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$tmp"
    [[ -n "$got" ]] || return 1
    want=$(getent hosts "${SE_SERVER:-}" | awk '{print $1}' | head -1)
    [[ -n "$want" ]] || return 0
    [[ "$got" == "$want" ]] && return 0
    printf '%s %s\n' "$got" "$want" > /tmp/exitprobe.result
    return 2
}

# ==================== 8. 伪装站点（BYO 静态站） ====================
# 让 Reality 的回落目标从「借来的外部站点」变成「本机真实存在的小站」：
# 证书、域名、内容、IP 四者自洽，探测者看到的是一个正常运营的垂直小站。
# 站点由 camo-site.py 生成：纯静态、无 JS、无外部字体、无图片、全站 noindex。

CAMO_ROOT="${CAMO_ROOT:-/var/www}"
CAMO_PY="${CAMO_PY:-/usr/local/share/simple-box/camo-site.py}"
CAMO_URL="${CAMO_URL:-${SCRIPT_URL%/*}/camo/camo-site.py}"

# 纯函数：Caddy 站点块（test-regression.sh 覆盖）
camo_caddy_block() {
    local domain="${1:-}" root="${2:-}" cert="${3:-}"
    [[ -n "$domain" && -n "$root" ]] || return 1
    printf '# 伪装站点（simbo 生成，全站 noindex）\n'
    printf '%s {\n' "$domain"
    printf '\troot * %s\n' "$root"
    if [[ -n "$cert" ]]; then
        printf '\ttls %s/fullchain.cer %s/private.key\n' "$cert" "$cert"
    fi
    printf '\tencode gzip\n'
    printf '\theader {\n\t\tX-Robots-Tag "noindex, nofollow"\n\t\t-Server\n\t}\n'
    printf '\thandle_errors {\n\t\trewrite * /404.html\n\t\tfile_server\n\t}\n'
    printf '\tfile_server\n}\n'
}

# 生成器落地：优先用已安装版本，否则从仓库拉一份并做语法校验
ensure_camo_generator() {
    if [[ -s "$CAMO_PY" ]]; then printf '%s\n' "$CAMO_PY"; return 0; fi
    mkdir -p "$(dirname "$CAMO_PY")" 2>/dev/null || true
    local tmp="${CAMO_PY}.dl.$$"
    if curl -fsSL --max-time 25 "$CAMO_URL" -o "$tmp" 2>/dev/null \
        && [[ -s "$tmp" ]] \
        && python3 -c 'import ast,sys;ast.parse(open(sys.argv[1]).read())' "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$CAMO_PY"
        chmod 755 "$CAMO_PY"
        printf '%s\n' "$CAMO_PY"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# 域名 → 内容源的确定性映射（同一个域名每次都是同一个源）
camo_pick_source() {
    local pool=(eso wikimedia w3c bhl)
    local n
    n=$(printf '%s' "${1:-}" | cksum | awk '{print $1}')
    printf '%s' "${pool[$(( n % ${#pool[@]} ))]}"
}

# 生成 / 重建站点，并挂到 Caddy；Reality 在跑就同步翻转成 127.0.0.1:FLIP_PORT
build_camo_site() {
    local domain="$1" source="$2" style="${3:-}"
    local gen dir caddy_file cert
    # Reality 在跑时 443 归 sing-box，只有「当前伪装域名」能通过它的回落对外服务。
    # 给别的域名建站只能把它搬到回环，公网 443 上仍是 Reality 的回落目标——站点等于不存在，
    # 而且会把全局 SITE_FILE 指到这个站，后续停用 Reality 会翻错站点、把真正的站点留在回环上。
    if [[ -f "$CONF_FILE" ]] && set_has "vless-reality-in" && [[ "$domain" != "${VL_SNI:-}" ]]; then
        echo -e "${RED}✗ Reality 正在 443 上用 ${VL_SNI} 伪装，${domain} 无法同时对外服务${PLAIN}"
        echo -e "${YELLOW}  先把 ${domain} 设为 Reality 的伪装域名（菜单 2 → 启用 Reality），或先停用 Reality 再建站${PLAIN}"
        return 1
    fi
    # 同一域名已有站点块时不能再写 camo-<域名>.caddy：Caddy 会因同一个地址出现两次而加载失败
    local _exist
    _exist=$(site_file_for "$domain" 2>/dev/null || true)
    if [[ -n "$_exist" && "$_exist" != "/etc/caddy/sites/camo-${domain}.caddy" ]]; then
        echo -e "${RED}✗ 本机已有 ${domain} 的站点配置：${_exist}${PLAIN}"
        echo -e "${YELLOW}  不再重复建站（会与它抢同一个地址）。要接管请先手工移除那份站点块${PLAIN}"
        return 1
    fi
    gen=$(ensure_camo_generator) || {
        echo -e "${RED}✗ 无法获取站点生成器（${CAMO_URL}）${PLAIN}"
        echo -e "${YELLOW}  节点本身不受影响，可稍后重试${PLAIN}"
        return 1
    }
    # 伪装站证书单独落 /etc/ssl/<域名>，并把 acme 续期目标也指到这里（issue_site_cert 负责）。
    # 接入域（HY_DOMAIN / TARGET_HOST）例外：那张证书由 CERT_DIR 统一供给 sing-box 与订阅站，
    # 不能再复制一份到 /etc/ssl，否则续期只会更新其中一处。
    if [[ -n "${HY_DOMAIN:-}" && ( "$domain" == "$HY_DOMAIN" || "$domain" == "${TARGET_HOST:-}" ) ]]; then
        cert=$(find_cert_dir "$domain" 2>/dev/null || true)
        [[ -n "$cert" ]] || {
            echo -e "${RED}✗ 接入域 ${domain} 的证书缺失，先重跑证书签发${PLAIN}"
            return 1
        }
    else
        issue_site_cert "$domain" || return 1
        cert="$CERT_SSL_ROOT/$domain"
    fi

    dir="${CAMO_ROOT}/${domain}"
    mkdir -p "$dir" || return 1
    local -a args=(--source "$source" --node "$(hostname -s)" --output "$dir")
    [[ -n "$style" ]] && args+=(--style "$style")
    echo -e "生成站点内容（${source}）..."
    if ! python3 "$gen" "${args[@]}"; then
        echo -e "${RED}✗ 站点生成失败（源站不可达或合格文章不足）${PLAIN}"
        return 1
    fi
    chmod -R a+rX "$dir" 2>/dev/null || true

    caddy_file="/etc/caddy/sites/camo-${domain}.caddy"
    mkdir -p /etc/caddy/sites
    camo_caddy_block "$domain" "$dir" "$cert" > "$caddy_file" || return 1

    if [[ -f "$CONF_FILE" ]] && set_has "vless-reality-in"; then
        SITE_FILE="$caddy_file"
        FLIP_HOST="$domain"
        FLIP_PORT="${FLIP_PORT:-9443}"
        flip_site_toggle on || { echo -e "${RED}✗ Caddy 重载失败${PLAIN}"; return 1; }
    else
        reload_caddy_safe || { echo -e "${RED}✗ Caddy 重载失败${PLAIN}"; return 1; }
    fi

    # 自检：真的取到页面才算成功（配置写错 / 端口被占 都表现为「服务在跑但 404」）
    # 只有「Reality 在跑、站点已翻转」时才在回环高位端口上；否则站点就在公网 443
    local port="443" code="000"
    if [[ -f "$CONF_FILE" ]] && set_has "vless-reality-in"; then port="${FLIP_PORT:-9443}"; fi
    sleep 1
    code=$(curl -s -o /dev/null -k -m 8 -w '%{http_code}' --resolve "${domain}:${port}:127.0.0.1" \
        "https://${domain}:${port}/" 2>/dev/null || echo 000)
    if [[ "$code" == "200" ]]; then
        echo -e "${GREEN}✓ 伪装站点已上线：https://${domain}/（回落端口 ${port}）${PLAIN}"
        echo -e "  目录: ${dir}   配置: ${caddy_file}"
    else
        echo -e "${YELLOW}⚠ 站点已生成但自检返回 HTTP ${code}${PLAIN}"
        echo -e "  排查: systemctl status caddy; ss -ltnp | grep :${port}"
        return 1
    fi
}

menu_camo() {
    local domain source style choice
    while true; do
        load_env
        [ -t 1 ] && clear
        echo -e "${GRAY}=================== 伪装站点 ===================${PLAIN}"
        echo -e "Reality 的回落目标用本机静态站（证书/域名/内容自洽），比借用外部站点更干净。"
        echo -e "${GRAY}------------------------------------------------${PLAIN}"
        local sites
        sites=$(find "$CAMO_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -6 || true)
        if [[ -n "$sites" ]]; then
            echo -e "已生成："
            printf '%s\n' "$sites" | sed 's/^/  /'
            echo -e "${GRAY}------------------------------------------------${PLAIN}"
        fi
        echo -e " 1. 生成 / 重建站点"
        echo -e " 2. 删除站点"
        echo -e " 0. 返回主菜单"
        echo -e "${GRAY}------------------------------------------------${PLAIN}"
        read -r -p "请选择 [0-2]: " choice || return 0
        case "$choice" in
            1)
                read -r -p "域名 [${HY_DOMAIN:-}]: " domain || return 0
                domain="$(trim_string "${domain:-${HY_DOMAIN:-}}")"
                [[ -n "$domain" ]] || { echo -e "${RED}域名不能为空${PLAIN}"; continue; }
                validate_domain "$domain" || { echo -e "${RED}域名格式不合法${PLAIN}"; continue; }
                echo -e " 内容源: 1) ESO 天文  2) Wikimedia 开放知识  3) W3C 标准  4) BHL 自然史"
                read -r -p "内容源 [1-4]: " source || return 0
                case "$source" in
                    1) source=eso ;; 2) source=wikimedia ;; 3) source=w3c ;; 4) source=bhl ;;
                    *) echo -e "${RED}无效选项${PLAIN}"; continue ;;
                esac
                read -r -p "版式 0-7（回车=自动）: " style || return 0
                [[ "$style" =~ ^[0-7]$ ]] || style=""
                if build_camo_site "$domain" "$source" "$style"; then
                    if [[ -f "$CONF_FILE" ]] && set_has "vless-reality-in"; then
                        local attach=""
                        ask "把 ${domain} 设为 Reality 的伪装域名（会重启 sing-box，客户端需重拉订阅）？[Y/n]: " attach
                        if [[ -z "$attach" || "${attach,,}" == y* ]]; then
                            if proto_enable_reality "${VL_PORT:-443}" "$domain"; then
                                echo -e "${GREEN}✓ Reality 已切到 ${domain}，伪装站即日起作为回落${PLAIN}"
                            else
                                echo -e "${YELLOW}⚠ Reality 切换失败，站点已建好，可稍后在「入站管理」里重试${PLAIN}"
                            fi
                        fi
                    fi
                fi
                read -r -p "按回车键继续..." _ || true
                ;;
            2)
                read -r -p "要删除的域名: " domain || return 0
                domain="$(trim_string "${domain:-}")"
                [[ -n "$domain" ]] || continue
                # 正在给 Reality 当回落的站点不能直接删：删掉站点块后 443 会被转发到
                # 一个已经没人监听的 9443，探测者拿到的是连接重置，比不伪装更可疑。
                if [[ -f "$CONF_FILE" ]] && set_has "vless-reality-in" && [[ "${VL_SNI:-}" == "$domain" ]]; then
                    echo -e "${RED}✗ ${domain} 正被 Reality 当作伪装域名，不能直接删除${PLAIN}"
                    echo -e "${YELLOW}  先到「入站管理」把 Reality 的伪装域名换成别的（或先停用 Reality），再回来删${PLAIN}"
                    read -r -p "按回车键继续..." _ || true
                    continue
                fi
                local d="${CAMO_ROOT}/${domain}" f="/etc/caddy/sites/camo-${domain}.caddy"
                rm -f "$f"
                rm -rf "$d"
                reload_caddy_safe || true
                echo -e "${GREEN}✓ 已删除 ${domain} 的站点${PLAIN}"
                read -r -p "按回车键继续..." _ || true
                ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------- 出站槽位编辑
# 字段名按槽位推导：槽 1 = EXIT_HY_*（历史字段），槽 n>1 = EXIT<n>_*
exit_slot_field_var() {
    local n="$1" f="$2"
    if [[ "$n" == "1" ]]; then
        case "$f" in
            SERVER)   printf 'EXIT_HY_SERVER' ;;
            PORT)     printf 'EXIT_HY_PORT' ;;
            PASS)     printf 'EXIT_HY_PASS' ;;
            SNI)      printf 'EXIT_HY_SNI' ;;
            SKIP)     printf 'EXIT_SKIP_CERT' ;;
            LABEL)    printf 'EXIT_LABEL' ;;
            ENTRY_VL) printf 'EXIT_ENTRY_VL' ;;
            ENTRY_HY) printf 'EXIT_ENTRY_HY' ;;
        esac
    else
        [[ "$f" == "SKIP" ]] && f="SKIP_CERT"
        printf 'EXIT%s_%s' "$n" "$f"
    fi
}

exit_slot_get() {
    local v; v=$(exit_slot_field_var "$1" "$2")
    printf '%s' "${!v:-}"
}

exit_slot_set() {
    local v; v=$(exit_slot_field_var "$1" "$2")
    printf -v "$v" '%s' "${3:-}"
}

# 第一个未启用的槽位编号；全满返回 1
exit_next_free_slot() {
    local n
    for ((n = 1; n <= EXIT_SLOTS_MAX; n++)); do
        if ! exit_slot_active "$n"; then printf '%s' "$n"; return 0; fi
    done
    return 1
}

# 链式入口的默认端口对，按槽位顺序取：2053/2054、2083/2084、2087/2088、2096/2097。
# TCP 侧全部落在 Cloudflare 支持代理的 HTTPS 端口上（2053/2083/2087/2096）：
# 这些端口真实 TLS 流量密度高，且很多企业/校园网只放行这组端口，客户端第一跳
# 用它们比用 2063 这类自造高位端口更容易出去。UDP 侧取 +1 成对，纯为便于记忆。
# 槽位超出表长时退回 2053/2054，宁可撞端口被 exit_entry_ports_ok 拦下，也不给空值。
EXIT_ENTRY_PORT_PAIRS=("2053 2054" "2083 2084" "2087 2088" "2096 2097")
exit_slot_default_ports() {
    local n="${1:-1}" vl hy
    read -r vl hy <<< "${EXIT_ENTRY_PORT_PAIRS[$((n - 1))]:-2053 2054}"
    printf '%s %s' "$vl" "$hy"
}

# 校验槽 n 的两个入口端口；冲突时打印原因并返回 1
exit_entry_ports_ok() {
    local n="$1" vl="$2" hy="$3" p other held
    if ! validate_port "$vl" || ! validate_port "$hy"; then
        echo -e "${RED}端口必须是 1-65535${PLAIN}"; return 1
    fi
    if [[ "$vl" == "$hy" ]]; then
        echo -e "${RED}两个入口端口不能相同${PLAIN}"; return 1
    fi
    for p in "${VL_PORT:-}" "${HY_PORT:-}" "${SUB_PORT:-}"; do
        [[ -n "$p" ]] || continue
        if [[ "$vl" == "$p" || "$hy" == "$p" ]]; then
            echo -e "${RED}入口端口不能与直连 / 订阅端口 ${p} 重复${PLAIN}"; return 1
        fi
    done
    for other in $(exit_active_slots); do
        [[ "$other" == "$n" ]] && continue
        exit_slot_env "$other"
        if [[ "$vl" == "$SE_ENTRY_VL" || "$hy" == "$SE_ENTRY_HY" ]]; then
            echo -e "${RED}与出口 ${other} 的入口端口冲突${PLAIN}"; return 1
        fi
    done
    for p in "tcp:$vl" "udp:$hy"; do
        held=$(port_holder "${p#*:}" "${p%%:*}")
        [[ -n "$held" ]] || continue
        exit_slot_env "$n"
        # 编辑同一个槽时端口本来就被自己占着，放行
        if [[ "$held" == *sing-box* && ( "${p#*:}" == "$SE_ENTRY_VL" || "${p#*:}" == "$SE_ENTRY_HY" ) ]]; then
            continue
        fi
        echo -e "${RED}端口 ${p#*:}/${p%%:*} 已被 ${held} 占用${PLAIN}"; return 1
    done
    return 0
}

# 选一个已启用的槽位；取消或无效返回 1
exit_pick_slot() {
    local in=""
    ask "选择出口编号（0=取消）: " in
    [[ -z "$in" || "$in" == "0" ]] && return 1
    if ! exit_slot_active "$in"; then
        echo -e "${RED}没有编号 ${in} 的出口${PLAIN}" >&2
        return 1
    fi
    printf '%s' "$in"
}

exit_detail() {
    local n _en _res _any=0
    echo
    for n in $(exit_active_slots); do
        exit_slot_env "$n"
        _any=1
        _res=$(timeout 2 getent ahostsv4 "$SE_SERVER" 2>/dev/null | awk '{print $1; exit}')
        echo -e " 出口 ${n}: ${CYAN}[Hysteria2]${PLAIN} → ${SE_SERVER}:${SE_PORT}${_res:+  (${_res})}"
        echo -e "   入口: Reality ${SE_ENTRY_VL:-—} / Hysteria2 ${SE_ENTRY_HY:-—}"
        echo -e "   后缀: -${SE_LABEL}"
        echo
    done
    [[ "$_any" == "1" ]] || echo -e " 出站: ${GRAY}[已停用]${PLAIN} 只保留直连"
    echo
    read -r -p "按回车返回..." _ || true
}

# 保存一个槽位并重建（新增 / 编辑共用）
# $1=槽位 $2=落点地址 $3=落点端口 $4=密码 $5=SNI $6=后缀 $7=入口 Reality 端口 $8=入口 Hysteria2 端口
exit_save_slot() {
    local n="$1"
    exit_slot_set "$n" SERVER "$2"
    exit_slot_set "$n" PORT "$3"
    exit_slot_set "$n" PASS "$4"
    exit_slot_set "$n" SNI "$5"
    exit_slot_set "$n" LABEL "$6"
    exit_slot_set "$n" ENTRY_VL "$7"
    exit_slot_set "$n" ENTRY_HY "$8"
    [[ "$n" == "1" ]] && EXIT_TYPE="hy2"
    apply_exit_reload || return 1
    return 0
}

exit_add() {
    local n srv prt pw sni lbl evl ehy dvl dhy mode="" url="" _imp="" _k _v _in=""
    if ! n=$(exit_next_free_slot); then
        echo -e "${YELLOW}已达上限 ${EXIT_SLOTS_MAX} 个出口，请先删除一个${PLAIN}"
        read -r -p "按回车返回..." _ || true
        return 0
    fi
    srv=$(exit_slot_get "$n" SERVER); prt=$(exit_slot_get "$n" PORT)
    pw=$(exit_slot_get "$n" PASS);   sni=$(exit_slot_get "$n" SNI)
    lbl=$(exit_slot_get "$n" LABEL)
    ask "设置方式 [1=粘贴订阅地址导入 2=手动填写，默认 2]: " mode

    if [[ "$mode" == "1" ]]; then
        ask "粘贴落地机的 provider.yaml 地址: " url
        if [[ -z "$url" ]] || ! _imp=$(exit_parse_url "$url" "$n"); then
            echo -e "${RED}✗ 导入失败：地址不可达，或对方没有 Hysteria2 节点${PLAIN}"
            echo -e "${YELLOW}  出口只支持 Hysteria2 落地。${PLAIN}"
            read -r -p "按回车返回..." _ || true
            return 0
        fi
        while IFS=$'\t' read -r _k _v; do
            case "$_k" in
                EXIT_HY_SERVER|EXIT_HY_PORT|EXIT_HY_PASS|EXIT_HY_SNI|\
                EXIT[2-9]_SERVER|EXIT[2-9]_PORT|EXIT[2-9]_PASS|EXIT[2-9]_SNI)
                    printf -v "$_k" '%s' "$_v" ;;
            esac
        done <<< "$_imp"
        srv=$(exit_slot_get "$n" SERVER); prt=$(exit_slot_get "$n" PORT)
        pw=$(exit_slot_get "$n" PASS);   sni=$(exit_slot_get "$n" SNI)
        echo -e "${GREEN}✓ 已导入落点 ${srv}:${prt}${PLAIN}"
    else
        ask_trim "落点地址 [${srv:-必填}]: " "$srv" srv
        ask_trim "落点端口 [${prt:-8443}]: " "${prt:-8443}" prt
        ask "落点 Hysteria2 密码 [回车沿用]: " _in
        pw="${_in:-$pw}"
        ask_trim "落点 SNI [${sni:-$srv}]: " "${sni:-$srv}" sni
    fi

    if [[ -z "$srv" || -z "$pw" ]] || ! validate_port "$prt"; then
        echo -e "${RED}落点地址 / 端口 / 密码不完整${PLAIN}"
        read -r -p "按回车返回..." _ || true
        return 0
    fi
    [[ -n "$sni" ]] || sni="$srv"

    ask_trim "节点后缀 [${lbl:-EXIT$n}]: " "${lbl:-EXIT$n}" lbl
    if [[ ! "$lbl" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo -e "${RED}后缀只能用字母、数字、- 和 _${PLAIN}"
        read -r -p "按回车返回..." _ || true
        return 0
    fi
    read -r dvl dhy <<< "$(exit_slot_default_ports "$n")"
    ask_trim "链式入口端口 · Reality [${dvl}]: " "$dvl" evl
    ask_trim "链式入口端口 · Hysteria2 [${dhy}]: " "$dhy" ehy
    if ! exit_entry_ports_ok "$n" "$evl" "$ehy"; then
        read -r -p "按回车返回..." _ || true
        return 0
    fi

    if exit_save_slot "$n" "$srv" "$prt" "$pw" "$sni" "$lbl" "$evl" "$ehy"; then
        echo -e "${GREEN}✓ 出口 ${n} 已保存（Hysteria2 → ${srv}:${prt}，入口 ${evl}/${ehy}）${PLAIN}"
        report_exit_health "$n"
    else
        echo -e "${RED}✗ 应用失败${PLAIN}"
    fi
    read -r -p "按回车返回..." _ || true
}

exit_edit() {
    local n srv prt pw sni lbl evl ehy dvl dhy _in=""
    n=$(exit_pick_slot) || return 0
    exit_slot_env "$n"
    srv="$SE_SERVER"; prt="$SE_PORT"; pw="$SE_PASS"; sni="$SE_SNI"
    lbl="$SE_LABEL"; evl="$SE_ENTRY_VL"; ehy="$SE_ENTRY_HY"

    ask_trim "落点地址 [${srv:-必填}]: " "$srv" srv
    ask_trim "落点端口 [${prt:-8443}]: " "${prt:-8443}" prt
    ask "落点 Hysteria2 密码 [回车沿用]: " _in
    pw="${_in:-$pw}"
    ask_trim "落点 SNI [${sni:-$srv}]: " "${sni:-$srv}" sni
    if [[ -z "$srv" || -z "$pw" ]] || ! validate_port "$prt"; then
        echo -e "${RED}落点地址 / 端口 / 密码不完整${PLAIN}"
        read -r -p "按回车返回..." _ || true
        return 0
    fi
    [[ -n "$sni" ]] || sni="$srv"

    ask_trim "节点后缀 [${lbl:-EXIT$n}]: " "${lbl:-EXIT$n}" lbl
    if [[ ! "$lbl" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo -e "${RED}后缀只能用字母、数字、- 和 _${PLAIN}"
        read -r -p "按回车返回..." _ || true
        return 0
    fi
    read -r dvl dhy <<< "$(exit_slot_default_ports "$n")"
    evl="${evl:-$dvl}"; ehy="${ehy:-$dhy}"
    ask_trim "链式入口端口 · Reality [${evl}]: " "$evl" evl
    ask_trim "链式入口端口 · Hysteria2 [${ehy}]: " "$ehy" ehy
    if ! exit_entry_ports_ok "$n" "$evl" "$ehy"; then
        read -r -p "按回车返回..." _ || true
        return 0
    fi

    if exit_save_slot "$n" "$srv" "$prt" "$pw" "$sni" "$lbl" "$evl" "$ehy"; then
        echo -e "${GREEN}✓ 出口 ${n} 已更新${PLAIN}"
        report_exit_health "$n"
    else
        echo -e "${RED}✗ 应用失败${PLAIN}"
    fi
    read -r -p "按回车返回..." _ || true
}

exit_delete() {
    local n _k _in=""
    n=$(exit_pick_slot) || return 0
    exit_slot_env "$n"
    ask "确认删除出口 ${n}（${SE_SERVER}:${SE_PORT}，-${SE_LABEL}）？[y/N]: " _in
    if [[ "${_in,,}" != y* ]]; then
        echo -e "${YELLOW}已取消${PLAIN}"
        read -r -p "按回车返回..." _ || true
        return 0
    fi
    if [[ "$n" == "1" ]]; then
        EXIT_TYPE="none"
        EXIT_LABEL=""; EXIT_ENTRY_VL=""; EXIT_ENTRY_HY=""
        for _k in EXIT_HY_SERVER EXIT_HY_PORT EXIT_HY_PASS EXIT_HY_SNI; do
            printf -v "$_k" '%s' ""
        done
    else
        for _k in SERVER PORT PASS SNI SKIP LABEL ENTRY_VL ENTRY_HY; do
            exit_slot_set "$n" "$_k" ""
        done
    fi
    if apply_exit_reload; then
        echo -e "${GREEN}✓ 已删除出口 ${n}（入口 / 出口 / 路由 / 订阅节点一并移除）${PLAIN}"
    else
        echo -e "${RED}✗ 删除失败${PLAIN}"
    fi
    read -r -p "按回车返回..." _ || true
}

menu_exit() {
    while true; do
        load_env
        # env 里槽 1 用 EXIT_HY_*、槽 n>1 用 EXIT<n>_*，先 sync 再展示
        sync_env_locals
        [ -t 1 ] && clear
        echo -e "${GRAY}=================== 出站管理 ===================${PLAIN}"
        printf '   %s%s%s%s%s\n' "#  " "协议        " "落点                        " "入口            " "标签"
        local n _any=0 _pname
        for n in $(exit_active_slots); do
            exit_slot_env "$n"
            _any=1
            _pname="Hysteria2"
            printf '   %-3s%-12s%-28s%-16s%s\n' "$n" "$_pname" "${SE_SERVER}:${SE_PORT}" \
                "${SE_ENTRY_VL} / ${SE_ENTRY_HY}" "$SE_LABEL"
        done
        [[ "$_any" == "1" ]] || echo -e "   ${GRAY}（未配置出站，全部走直连）${PLAIN}"
        if [[ "${EXIT_TYPE:-none}" != "none" && "${EXIT_TYPE:-none}" != "hy2" ]]; then
            echo -e "${YELLOW}槽 1 的旧版 Reality 出口已不再支持，请用「3. 编辑出口」按 Hysteria2 重配${PLAIN}"
        fi
        echo -e "${GRAY}------------------------------------------------${PLAIN}"
        echo " 1. 查看出站详情"
        echo " 2. 新增出口"
        echo " 3. 编辑出口"
        echo " 4. 删除出口"
        echo " 0. 返回主菜单"
        echo -e "${GRAY}================================================${PLAIN}"
        local opt=""
        ask "请输入选项 [0-4]: " opt
        [[ "$ASK_EOF" == "1" ]] && break
        case "$opt" in
            1) exit_detail ;;
            2) exit_add ;;
            3) exit_edit ;;
            4) exit_delete ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu_protocol() {
    while true; do
        [ -t 1 ] && clear
        echo -e "${GRAY}=================== 入站管理 ===================${PLAIN}"
        local i=1 p state
        for p in $PROTOCOLS; do
            if set_has "$(proto_tag "$p")"; then state="${GREEN}当前启用${PLAIN}"; else state="${GRAY}当前停用${PLAIN}"; fi
            echo -e " $i. 启用/停用 $(proto_human "$p")  ${state}"
            i=$((i+1))
        done
        echo " 0. 返回主菜单"
        echo -e "${GRAY}================================================${PLAIN}"
        local opt="" ok=""
        ask "请输入选项 [0-$((i-1))]: " opt
        [[ "$ASK_EOF" == "1" ]] && break
        if [[ "$opt" == "0" ]]; then break; fi
        if [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt < i )); then
            p=$(echo $PROTOCOLS | cut -d' ' -f"$opt")
            if set_has "$(proto_tag "$p")"; then
                read -r -p "确认停用 $(proto_human "$p")？[y/N]: " ok || ok=""
                [[ "$ok" == [yY]* ]] && disable_protocol "$p"
            else
                "proto_enable_${p}"
            fi
            read -r -p "按回车返回..." _ || true
        else
            echo -e "${RED}无效选项${PLAIN}"; sleep 1
        fi
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
        [[ -z "${cur_ip:-}" ]] && cur_ip=$(detect_public_ip 2>/dev/null || echo "检测中...")
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
            load_env
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
            echo -e "${GRAY}----------------------------------------------------${PLAIN}"
            print_io_status
            
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
        echo -e " 1. 原始订阅信息"
        echo -e " 2. 入站管理"
        echo -e " 3. 出站管理"
        echo -e " 4. 订阅地址配置"
        echo -e " 5. sing-box 内核管理"
        echo -e " 6. 脚本升级"
        echo -e " 7. 脚本卸载"
        echo -e " 8. 伪装站点"
        echo -e " 0. 退出控制台"
        echo -e "${GRAY}====================================================${PLAIN}"
        
        local opt=""
        read -r -p "请输入选项 [0-8]: " opt || opt="0"
        case "$opt" in
            1) show_links || true ;;
            2) menu_protocol || true ;;
            3) menu_exit || true ;;
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
            8) menu_camo || true ;;
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
    trap cleanup_tmp EXIT
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
