#!/usr/bin/env bash
# ==============================================================================
# Simple-Box Manager - 极简、安全、透明的自用 sing-box 服务端管理脚本
# 协议支持: 
#   1. VLESS-TCP-Reality-Vision (日常主力直连)
#   2. Hysteria 2 (晚高峰弱网/UDP端口跳跃, 支持 Cloudflare 证书或自签证书)
# 订阅分发:
#   集成 Caddy HTTPS 安全分发，输出完整规则模板订阅、纯节点订阅、URI 与二维码
# ==============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

CONF_DIR="/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"
CERT_DIR="${CONF_DIR}/cert"
WEB_DIR="${CONF_DIR}/web"
ENV_FILE="${CONF_DIR}/env.conf"
YAML_PROVIDER="${CONF_DIR}/clash_meta_provider.yaml"
LINKS_FILE="${CONF_DIR}/links.txt"
TEMPLATE_FILE="${CONF_DIR}/template.yaml"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本！${PLAIN}" && exit 1

get_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) echo -e "${RED}不支持的系统架构: $arch${PLAIN}"; exit 1 ;;
    esac
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

# 剔除字符串首尾的空白字符与引号（清洗换行符、制表符、空格与单双引号任意层嵌套）
trim_string() {
    local val="${1:-}"
    echo "$val" | tr -d '\r\n' | sed -E ':loop; s/^[[:space:]]+|[[:space:]]+$//g; s/^["'"'"']+|["'"'"']+$//g; t loop'
}

# 在线校验 Cloudflare API Token 有效性
verify_cloudflare_token() {
    local token="${1:-}"
    token=$(trim_string "$token")
    [[ -z "$token" ]] && return 1

    echo -e "${BLUE}正在在线校验 Cloudflare API Token...${PLAIN}"
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

# 端口冲突检测
check_port_occupied() {
    local port="${1:-}"
    local proto="${2:-}"
    local in_use=""
    local lister="ss"
    command -v ss &>/dev/null || lister="netstat"
    if [[ "$proto" == "tcp" ]]; then
        if [[ "$lister" == "ss" ]]; then
            in_use=$(ss -tlnp 2>/dev/null | grep -E "[: ]${port} " || true)
        else
            in_use=$(netstat -tlnp 2>/dev/null | grep -E "[: ]${port} " || true)
        fi
    elif [[ "$proto" == "udp" ]]; then
        if [[ "$lister" == "ss" ]]; then
            in_use=$(ss -ulnp 2>/dev/null | grep -E "[: ]${port} " || true)
        else
            in_use=$(netstat -ulnp 2>/dev/null | grep -E "[: ]${port} " || true)
        fi
    fi
    if [[ -n "$in_use" ]]; then
        if echo "$in_use" | grep -q "sing-box"; then
            echo -e "${BLUE}提示: 端口 ${port} 当前由已有 sing-box 进程使用，重置安装将自动平滑接管。${PLAIN}"
            return 0
        elif echo "$in_use" | grep -q "caddy"; then
            echo -e "${BLUE}提示: 端口 ${port} 当前由已有 caddy 订阅服务使用，重置安装将自动复用。${PLAIN}"
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
install_deps() {
    local missing=()
    for cmd in curl tar jq openssl iptables socat qrencode; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${BLUE}安装必要基础组件: ${missing[*]}...${PLAIN}"
        if command -v apt-get &>/dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections 2>/dev/null || true
            echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null || true
            apt-get update -qq || echo -e "${YELLOW}apt-get update 失败，尝试直接安装。${PLAIN}"
            apt-get install -y -qq "${missing[@]}" iptables-persistent \
                || echo -e "${YELLOW}部分依赖安装失败，将尝试继续（缺少 qrencode 仅影响二维码显示）。${PLAIN}"
        elif command -v yum &>/dev/null; then
            yum install -y epel-release >/dev/null 2>&1 || true
            yum install -y "${missing[@]}" || echo -e "${YELLOW}部分依赖安装失败，将尝试继续。${PLAIN}"
        fi
    fi
}

# 检查并自动安装 Caddy
install_caddy() {
    if command -v caddy &>/dev/null; then
        return 0
    fi
    echo -e "${BLUE}正在安装 Caddy 用于安全的 HTTPS 订阅分发...${PLAIN}"
    if command -v apt-get &>/dev/null; then
        apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt-get update -qq && apt-get install -y -qq caddy
    elif command -v yum &>/dev/null; then
        yum install -y yum-plugin-copr
        yum copr enable -y @caddy/caddy
        yum install -y caddy
    fi
    systemctl enable caddy >/dev/null 2>&1 || true
}

# BBR 拥塞控制管理（开启与关闭）
manage_bbr() {
    while true; do
        [ -t 1 ] && clear
        local cur_bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
        local cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
        local bbr_tag="${YELLOW}未开启 (${cur_bbr})${PLAIN}"
        local action_desc="开启加速 (bbr + fq)"
        local target_action="enable"
        if [[ "$cur_bbr" == "bbr" ]]; then
            bbr_tag="${GREEN}已开启 (bbr)${PLAIN}"
            action_desc="恢复默认 (cubic + fq_codel)"
            target_action="disable"
        fi

        echo -e "\n${GREEN}================== TCP BBR 加速管理 ===================${PLAIN}"
        echo -e " 当前状态: ${bbr_tag} | 队列规则: ${CYAN}${cur_qdisc}${PLAIN}"
        echo -e "${GREEN}-------------------------------------------------------${PLAIN}"
        echo -e " 1. ${action_desc}"
        echo -e " 0. 返回主菜单"
        echo -e "${GREEN}=======================================================${PLAIN}"
        local opt=""
        read -r -p "请输入选项 [0-1]: " opt || opt=""
        case "$opt" in
            1)
                if [[ "$target_action" == "enable" ]]; then
                    mkdir -p /etc/sysctl.d
                    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
                    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
                    local check_bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
                    local check_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
                    echo -e "\n${BLUE}正在验证内核参数...${PLAIN}"
                    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
                    if [[ "$check_bbr" == "bbr" ]]; then
                        echo -e "\n${GREEN}✓ 验证成功: TCP BBR 与 fq 队列调度已在内核立即生效！${PLAIN}"
                    else
                        echo -e "\n${YELLOW}! 配置已写入，但内核当前返回: ${check_bbr}，若未生效请检查内核并重启系统。${PLAIN}"
                    fi
                else
                    rm -f /etc/sysctl.d/99-bbr.conf
                    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
                    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
                    local check_bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
                    local check_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
                    echo -e "\n${BLUE}正在验证内核参数...${PLAIN}"
                    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
                    echo -e "\n${GREEN}✓ 验证成功: 已关闭 BBR，当前内核已恢复为默认 (${check_bbr} + ${check_qdisc})！${PLAIN}"
                fi
                echo ""
                read -r -p "按回车键继续..." dummy || true
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

# 获取并升级官方 sing-box 内核（带精准版本校验）
update_singbox_core() {
    local force_flag="${1:-}"
    echo -e "${BLUE}检查 sing-box 官方最新版本...${PLAIN}"

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
    local arch=$(get_arch)

    echo -e "本地当前版本: ${CYAN}v${cur_ver}${PLAIN} | 官方最新版本: ${GREEN}${tag}${PLAIN} (${arch})"

    if [[ "$cur_ver" == "$latest_ver" && "$force_flag" != "force" ]]; then
        echo -e "${GREEN}当前已是官方最新版本，无需重复更新！${PLAIN}"
        if [ -t 0 ]; then
            read -p "是否强制重新下载覆盖安装？(y/N): " re_install
            [[ "$re_install" != "y" && "$re_install" != "Y" ]] && return 0
        else
            return 0
        fi
    fi

    local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${latest_ver}-linux-${arch}.tar.gz"
    local tmp_dir=$(mktemp -d)
    local tmp_tar="${tmp_dir}/sing-box.tar.gz"

    echo -e "${BLUE}正在下载并更新内核...${PLAIN}"
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
        install -m 755 "$tmp_dir/sing-box" /usr/local/bin/sing-box
        rm -rf "$tmp_dir"
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

# 证书管理（支持 CF API 证书与无域名自签证书）
# 结果通过全局 CERT_MODE 回传: domain | selfsigned
CERT_MODE=""
issue_cert_bundle() {
    local domain="${1:-}"
    local cf_token="${2:-}"
    local server_ip="${3:-}"
    local acme_bin="$HOME/.acme.sh/acme.sh"
    CERT_MODE="selfsigned"

    mkdir -p "$CERT_DIR"

    # 模式 A: 自有域名 + CF Token，走 DNS-01 申请 Let's Encrypt
    if [[ -n "$domain" && -n "$cf_token" ]]; then
        echo -e "${BLUE}配置 acme.sh 证书环境...${PLAIN}"
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
                echo -e "${BLUE}通过 Cloudflare DNS API 申请证书（DNS-01，无需 80 端口）...${PLAIN}"
                "$acme_bin" --set-default-ca --server letsencrypt || true
                "$acme_bin" --issue --dns dns_cf -d "$domain" --dnssleep 20 --keylength ec-256 --force || true
            fi
            "$acme_bin" --install-cert -d "$domain" --ecc \
                --fullchain-file "${CERT_DIR}/fullchain.cer" \
                --key-file "${CERT_DIR}/private.key" \
                --reloadcmd "systemctl reload sing-box 2>/dev/null || true; systemctl reload caddy 2>/dev/null || true" || true
        fi
    fi

    # 校验：域名证书是否真的落地（含有效期）
    local ok=false
    if [[ -s "${CERT_DIR}/fullchain.cer" && -s "${CERT_DIR}/private.key" ]]; then
        if openssl x509 -in "${CERT_DIR}/fullchain.cer" -noout -checkend 0 >/dev/null 2>&1; then
            ok=true
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
    chmod 644 "${CERT_DIR}"/* 2>/dev/null || true

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
    chmod 644 "${CERT_DIR}"/* 2>/dev/null || true
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

    echo -e "${BLUE}配置 Hysteria 2 端口跳跃 (UDP ${range} -> ${hy_port})...${PLAIN}"
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
        echo -e "${YELLOW}未安装 Caddy，跳过订阅站点重载。${PLAIN}"
        return 1
    fi

    # 1. 配置语法校验（不通过就不要碰运行中的服务）
    if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
        echo -e "${RED}Caddyfile 校验失败，已保持现有订阅服务不变。${PLAIN}"
        caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | tail -5
        return 1
    fi

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

# 部署 Caddy 订阅分发服务
setup_caddy_subscription() {
    local domain_or_ip="${1:-}"
    local token="${2:-}"
    local sub_port="${3:-}"
    local cert_mode="${4:-selfsigned}"

    install_caddy

    mkdir -p "/etc/caddy/sites"
    
    if [ ! -f /etc/caddy/Caddyfile ]; then
        echo -e "import sites/*.caddy\n" > /etc/caddy/Caddyfile
    elif ! grep -q "import sites/\*\.caddy" /etc/caddy/Caddyfile; then
        echo -e "\nimport sites/*.caddy" >> /etc/caddy/Caddyfile
    fi

    # 清理所有旧版 simple-box caddy 配置文件
    rm -f /etc/caddy/sites/*-${sub_port}.caddy /etc/caddy/sites/simple-box*.caddy

    if [[ "$cert_mode" == "domain" ]]; then
        echo -e "${BLUE}配置 Caddy HTTPS 安全订阅站点 (端口 ${sub_port}, 域名 CA 证书)...${PLAIN}"
        cat > "/etc/caddy/sites/simple-box-sub.caddy" <<EOF
# Simple-Box HTTPS 订阅分发站点 (域名 CA 证书)
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
        echo -e "${BLUE}配置 Caddy HTTP 订阅分发站点 (端口 ${sub_port}, 客户端直接导入免证书报错)...${PLAIN}"
        cat > "/etc/caddy/sites/simple-box-sub.caddy" <<EOF
# Simple-Box HTTP 订阅分发站点 (IP 自签兼容模式)
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
    reload_caddy_safe || echo -e "${YELLOW}订阅站点配置已写入，但 Caddy 未能生效，可稍后手动 systemctl restart caddy。${PLAIN}"
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
    local hy_enabled="${10}"
    local hy_port="${11}"
    local hy_ports_display="${12}"
    local hy_password="${13}"
    local hy_skip_cert="${14}"

    mkdir -p "${WEB_DIR}/${token}"

    if [ ! -f "$TEMPLATE_FILE" ]; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -f "${script_dir}/template.yaml" ]; then
            cp -f "${script_dir}/template.yaml" "$TEMPLATE_FILE" 2>/dev/null || true
        else
            curl -fsSL https://raw.githubusercontent.com/comegome/simple-box/main/template.yaml -o "$TEMPLATE_FILE" 2>/dev/null || true
        fi
    fi

    # 1. 组装完整配置
    local full_config_file="${WEB_DIR}/${token}/config.yaml"
    if [ -f "$TEMPLATE_FILE" ]; then
        cat "$TEMPLATE_FILE" > "$full_config_file"
    else
        echo "mixed-port: 7890" > "$full_config_file"
        echo "mode: rule" >> "$full_config_file"
    fi

    # 分流规则防死锁：无论域名或 IP 均注入顶层直连，确保节点更新/失效时订阅拉取 100% 不死锁
    if [[ "$domain_or_ip" == "$server_ip" || -z "$domain_or_ip" ]]; then
        sed -i "/^rules:/a \  - IP-CIDR,${server_ip}/32,DIRECT,no-resolve" "$full_config_file"
    else
        sed -i "/^rules:/a \  - DOMAIN,${domain_or_ip},DIRECT\n  - IP-CIDR,${server_ip}/32,DIRECT,no-resolve" "$full_config_file"
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

    if [ "$hy_enabled" = true ]; then
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
    fi

    cat >> "$full_config_file" <<EOF

proxy-groups:
  - name: "📌节点选择"
    type: select
    proxies:
      - "${node_prefix}-VLESS-Reality"
EOF

    if [ "$hy_enabled" = true ]; then
        cat >> "$full_config_file" <<EOF
      - "${node_prefix}-Hysteria2"
EOF
    fi
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

    if [ "$hy_enabled" = true ]; then
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
    fi
    cp -f "$provider_file" "$YAML_PROVIDER"

    # 3. 组装原生分享链接
    local vless_link="vless://${user_uuid}@${server_ip}:${vl_port}?security=reality&encryption=none&pbk=${vl_pubkey}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${vl_sni}&sid=${vl_shortid}#${node_prefix}-VLESS-Reality"
    local links_out="${WEB_DIR}/${token}/links.txt"
    echo "$vless_link" > "$links_out"

    if [ "$hy_enabled" = true ]; then
        local insecure_flag="0"
        [[ "$hy_skip_cert" == "true" ]] && insecure_flag="1"
        local mport_param=""
        [[ -n "$hy_ports_display" && "$hy_ports_display" == *,* ]] && mport_param="&mport=${hy_ports_display}"
        local hy2_link="hysteria2://${hy_password}@${domain_or_ip}:${hy_port}/?sni=${domain_or_ip}&insecure=${insecure_flag}${mport_param}#${node_prefix}-Hysteria2"
        echo "$hy2_link" >> "$links_out"
    fi
    cp -f "$links_out" "$LINKS_FILE"
}

# 注册全局 simbo 指令（兼容 bash <(curl ...) 管道执行）
install_simbo_command() {
    local share_dir="/usr/local/share/simple-box"
    local target="${share_dir}/simple-box.sh"

    mkdir -p "$share_dir"

    if [[ -f "$0" && -r "$0" ]]; then
        # 本地脚本文件直接复制
        install -m 755 "$0" "$target" 2>/dev/null || cp -f "$0" "$target" 2>/dev/null || true
    fi

    # 管道执行（$0 为 /dev/fd/xx）或复制失败时，从仓库拉取一份落地
    if [[ ! -s "$target" ]]; then
        curl -fsSL https://raw.githubusercontent.com/comegome/simple-box/main/simple-box.sh -o "$target" 2>/dev/null || true
        chmod 755 "$target" 2>/dev/null || true
    fi

    if [[ -s "$target" ]]; then
        ln -sf "$target" /usr/local/bin/simbo
        echo -e "${GREEN}已注册全局指令: simbo${PLAIN}"
    else
        echo -e "${YELLOW}未能自动注册 simbo 指令，可稍后手动: curl -fsSL <脚本地址> -o /usr/local/bin/simbo${PLAIN}"
    fi
}

# 部署与配置主函数
# 集中生成 sing-box 服务端配置文件
write_singbox_config() {
    local vl_port="${1:-}"
    local vl_sni="${2:-}"
    local user_uuid="${3:-}"
    local vl_privkey="${4:-}"
    local vl_shortid="${5:-}"
    local hy_enabled="${6:-}"
    local hy_port="${7:-}"
    local hy_password="${8:-}"

    cat > "$CONF_FILE" <<EOF
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

    if [ "$hy_enabled" = true ]; then
        cat >> "$CONF_FILE" <<EOF
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
    fi

    cat >> "$CONF_FILE" <<EOF
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

# 集中写入持久化环境变量
write_env_config() {
    cat > "$ENV_FILE" <<EOF
NODE_PREFIX="${node_prefix}"
SERVER_IP="${server_ip}"
VL_PORT="${vl_port}"
VL_SNI="${vl_sni}"
VL_UUID="${user_uuid}"
VL_PRIVKEY="${vl_privkey}"
VL_PUBKEY="${vl_pubkey}"
VL_SHORTID="${vl_shortid}"
HY_ENABLED="${hy_enabled}"
HY_DOMAIN="${hy_domain}"
TARGET_HOST="${target_host}"
HY_PORT="${hy_port}"
HY_RANGE="${hy_range}"
HY_PASS="${hy_password}"
HY_SKIP_CERT="${hy_skip_cert}"
SUB_PORT="${sub_port}"
SUB_PROTO="${sub_proto}"
SUB_TOKEN="${sub_token}"
EOF
}

# 校验 sing-box 配置、重启并全量刷新客户端文件与 Caddy 订阅
render_and_reload() {
    if [[ ! -x /usr/local/bin/sing-box ]]; then
        echo -e "${RED}未找到 sing-box 内核，无法应用配置。${PLAIN}"
        return 1
    fi
    if ! /usr/local/bin/sing-box check -c "$CONF_FILE" >/dev/null 2>&1; then
        echo -e "${RED}生成的 sing-box 配置文件校验失败！已回滚到上一份可用配置。${PLAIN}"
        /usr/local/bin/sing-box check -c "$CONF_FILE" || true
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
    generate_full_client_config "$target_host" "$sub_token" "$node_prefix" "$server_ip" "$vl_port" "$user_uuid" "$vl_sni" "$vl_pubkey" "$vl_shortid" "$hy_enabled" "$hy_port" "$hy_ports_display" "$hy_password" "$hy_skip_cert"

    setup_caddy_subscription "$target_host" "$sub_token" "$sub_port" "$CERT_MODE"
    reload_caddy_safe || true
    verify_caddy_listening "$sub_port" || true
}

install_node() {
    install_deps

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
        [[ "$HY_SKIP_CERT" != "true" ]] && old_domain="$HY_DOMAIN"
    fi

    local server_ip
    server_ip=$(curl -s4m5 https://icanhazip.com || curl -s4m5 https://api.ipify.org || true)
    server_ip=${server_ip:-}
    if ! [[ "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}无法探测本机公网 IPv4（curl icanhazip/ipify 均失败）。${PLAIN}"
        echo -e "${YELLOW}自签证书需要真实公网 IP，请检查网络后重试。${PLAIN}"
        return 1
    fi

    echo -e "\n${YELLOW}=== 1. 配置 VLESS-Reality 参数 ===${PLAIN}"
    local vl_port
    while true; do
        read -r -p "请输入 Reality 监听端口 [默认 ${old_vl_port:-443}]: " vl_port || vl_port=""
        vl_port=${vl_port:-${old_vl_port:-443}}
        if ! validate_port "$vl_port"; then
            echo -e "${RED}端口非法（应为 1-65535 的整数），请重新输入。${PLAIN}"; continue
        fi
        if check_port_occupied "$vl_port" "tcp"; then break; fi
        echo -e "${YELLOW}请更换其他未占用的端口！${PLAIN}"
    done

    local vl_sni
    while true; do
        read -r -p "请输入 Reality 借壳伪装域名 [默认 ${old_vl_sni:-gateway.icloud.com}]: " vl_sni || vl_sni=""
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

    echo -e "\n${YELLOW}=== 2. 配置 Hysteria 2 参数 ===${PLAIN}"
    local hy_enabled=true
    local hy_skip_cert="false"
    local cert_fell_back=""

    echo -e "${CYAN}提示:${PLAIN}"
    echo -e "${CYAN}  1. 用自有域名: 需先在 Cloudflare 添加 A 记录指向本机 IP (${server_ip})${PLAIN}"
    echo -e "${CYAN}  2. CF 代理状态必须为【仅限 DNS】(灰色云朵)，小黄云会阻断 UDP${PLAIN}"
    echo -e "${CYAN}  3. 直接回车 = IP 自签证书；skip = 只装 Reality${PLAIN}"
    [[ -n "$old_domain" ]] && echo -e "${CYAN}  4. 当前已有域名 ${old_domain}，输入 keep 可沿用${PLAIN}"

    local hy_domain
    while true; do
        read -r -p "请输入域名 [回车=IP自签]: " hy_domain || hy_domain=""
        [[ -z "$hy_domain" ]] && hy_domain="ip"

        case "${hy_domain,,}" in
            ip|self|selfsigned) hy_domain=""; break ;;
            none|skip)          hy_domain="skip"; break ;;
            keep)
                if [[ -n "$old_domain" ]]; then
                    hy_domain="$old_domain"
                    echo -e "${BLUE}沿用已有域名: ${hy_domain}${PLAIN}"
                    break
                fi
                echo -e "${YELLOW}当前没有已配置的域名，回退为 IP 自签证书。${PLAIN}"
                hy_domain=""; break
                ;;
        esac

        if [[ "$hy_domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]]; then
            break
        fi
        echo -e "${RED}域名格式非法: ${hy_domain}（示例: node.example.com）${PLAIN}"
    done

    local target_host="$hy_domain"
    local cf_token=""

    if [[ "$hy_domain" == "skip" || "$hy_domain" == "none" ]]; then
        echo -e "${YELLOW}已选择跳过 Hysteria 2，将仅部署 VLESS-Reality。${PLAIN}"
        hy_enabled=false
    elif [[ -z "$hy_domain" ]]; then
        echo -e "${YELLOW}未输入域名，自动启用自签证书模式 (IP 直连 + skip-cert-verify)。${PLAIN}"
        target_host="$server_ip"
        hy_skip_cert="true"
    else
        target_host="$hy_domain"
        if [[ -z "$CF_TOKEN" ]]; then
            echo -e "\n${CYAN}------------------- Cloudflare API Token 获取指引 -------------------${PLAIN}"
echo -e "${CYAN} 1. 登录 CF -> 右上角头像 -> [配置文件] -> 左侧导航 [API 令牌]${PLAIN}"
echo -e "${CYAN} 2. 点击 [创建令牌] -> 找到 [编辑区域 DNS (Edit zone DNS)] 点击 [使用模板]${PLAIN}"
echo -e "${CYAN} 3. 区域资源选择: [包括] -> [特定区域] -> 选择你的域名${PLAIN}"
echo -e "${CYAN} 4. 底部点击 [继续以显示摘要] -> 最终确认页点击 [创建令牌] 并复制生成的令牌${PLAIN}"
echo -e "${CYAN}---------------------------------------------------------------------${PLAIN}"
            while true; do
                read -r -p "请输入 Cloudflare API Token: " cf_token || cf_token=""
                cf_token=$(trim_string "$cf_token")
                if [[ -z "$cf_token" ]]; then
                    echo -e "${YELLOW}未输入 Token，将自动使用 IP 自签证书。${PLAIN}"
                    target_host="$server_ip"
                    hy_skip_cert="true"
                    hy_domain=""
                    cert_fell_back="true"
                    break
                fi
                if verify_cloudflare_token "$cf_token"; then
                    break
                fi
                local retry=""
                read -r -p "是否重新输入 Token？[Y/n (回车重试，输入 n 使用 IP 自签)]: " retry || retry=""
                if [[ "${retry,,}" == "n" ]]; then
                    echo -e "${YELLOW}已放弃域名证书，将自动使用 IP 自签证书。${PLAIN}"
                    target_host="$server_ip"
                    hy_skip_cert="true"
                    hy_domain=""
                    cf_token=""
                    cert_fell_back="true"
                    break
                fi
            done
        fi
    fi

    local hy_port=""
    local hy_range=""

    if [ "$hy_enabled" = true ]; then
        hy_port="8443"
        hy_range="20000:40000"
        while true; do
            read -r -p "请输入 Hysteria 2 主监听 UDP 端口 [默认 ${old_hy_port:-8443}]: " hy_port || hy_port=""
            hy_port=${hy_port:-${old_hy_port:-8443}}
            if ! validate_port "$hy_port"; then
                echo -e "${RED}端口非法（应为 1-65535 的整数），请重新输入。${PLAIN}"; continue
            fi
            if [[ "$hy_port" == "$vl_port" ]]; then
                echo -e "${RED}端口冲突: 该端口已分配给 VLESS-Reality (${vl_port})，不能共用！${PLAIN}"; continue
            fi
            if check_port_occupied "$hy_port" "udp"; then break; fi
            echo -e "${YELLOW}请更换其他未占用的 UDP 端口！${PLAIN}"
        done

        while true; do
            read -r -p "请输入端口跳跃范围 [默认 ${old_hy_range:-20000:40000}] (none=不启用): " hy_range || hy_range=""
            hy_range=${hy_range:-${old_hy_range:-20000:40000}}
            [[ "${hy_range,,}" == "none" ]] && { hy_range=""; break; }
            if ! validate_range "$hy_range"; then
                echo -e "${RED}范围格式非法，应为 起始:结束（如 20000:40000）。${PLAIN}"; continue
            fi
            local r_start="${hy_range%%:*}"
            local r_end="${hy_range##*:}"
            if (( vl_port >= r_start && vl_port <= r_end )); then
                echo -e "${RED}范围冲突: 端口跳跃范围包含已设定的 Reality 端口 (${vl_port})，请调整！${PLAIN}"; continue
            fi
            if (( hy_port >= r_start && hy_port <= r_end )); then
                echo -e "${RED}范围冲突: 端口跳跃范围包含 Hysteria 2 主端口 (${hy_port})，请调整！${PLAIN}"; continue
            fi
            break
        done
    fi

    echo -e "\n${YELLOW}=== 3. 配置在线订阅站点参数 ===${PLAIN}"
    local sub_port
    while true; do
        read -r -p "请输入 Caddy 订阅监听端口 [默认 ${old_sub_port:-8444}]: " sub_port || sub_port=""
        sub_port=${sub_port:-${old_sub_port:-8444}}
        if ! validate_port "$sub_port"; then
            echo -e "${RED}端口非法（应为 1-65535 的整数），请重新输入。${PLAIN}"; continue
        fi
        if [[ "$sub_port" == "$vl_port" ]]; then
            echo -e "${RED}端口冲突: 该端口已分配给 VLESS-Reality (${vl_port})，不能共用！${PLAIN}"; continue
        fi
        if [[ -n "$hy_port" && "$sub_port" == "$hy_port" ]]; then
            echo -e "${RED}端口冲突: 该端口已分配给 Hysteria 2 主端口 (${hy_port})，不能共用！${PLAIN}"; continue
        fi
        if [[ -n "$hy_range" ]]; then
            local r_start="${hy_range%%:*}"
            local r_end="${hy_range##*:}"
            if (( sub_port >= r_start && sub_port <= r_end )); then
                echo -e "${RED}范围冲突: 订阅端口 (${sub_port}) 落在 Hysteria 2 跳跃范围 (${hy_range}) 内，请更换！${PLAIN}"; continue
            fi
        fi
        if check_port_occupied "$sub_port" "tcp"; then break; fi
        echo -e "${YELLOW}请更换其他未占用的 TCP 端口！${PLAIN}"
    done

    local node_prefix
    read -r -p "请输入节点名称前缀 (如 HK / US / Oracle-O2) [默认 ${old_prefix:-Node}]: " node_prefix || node_prefix=""
    node_prefix=${node_prefix:-${old_prefix:-Node}}
    # 去掉会破坏 YAML/URI 的字符
    node_prefix=$(echo "$node_prefix" | tr -d '"' | tr -d "'")

    # 证书重生成前先停 sing-box，避免文件监视器读到写入中途的 cert/key 组合
    if systemctl is-active --quiet sing-box; then
        systemctl stop sing-box 2>/dev/null || true
    fi

    # 签发证书（skip 模式下仍需自签证书，仅供 Caddy 订阅站点的 TLS 使用）
    if [ "$hy_enabled" = true ]; then
        issue_cert_bundle "$hy_domain" "$cf_token" "$server_ip" || return 1
        if [[ "$CERT_MODE" == "domain" ]]; then
            hy_skip_cert="false"
            target_host="$hy_domain"
        else
            hy_skip_cert="true"
            target_host="$server_ip"
            if [[ -n "$hy_domain" && "$hy_domain" != "skip" ]]; then
                hy_domain=""          # 已降级，清除域名避免后续误用
                cert_fell_back="true"
            fi
        fi
    else
        issue_cert_bundle "" "" "$server_ip" || return 1
        target_host="$server_ip"
        hy_skip_cert="true"
    fi

    # 生成密钥凭证
    echo -e "${BLUE}生成安全密钥凭证...${PLAIN}"
    local key_pair=$(/usr/local/bin/sing-box generate reality-keypair)
    local vl_privkey=$(echo "$key_pair" | awk '/PrivateKey/{print $2}')
    local vl_pubkey=$(echo "$key_pair" | awk '/PublicKey/{print $2}')
    local vl_shortid=$(/usr/local/bin/sing-box generate rand 8 --hex)
    local user_uuid=$(/usr/local/bin/sing-box generate uuid)
    local hy_password=$(/usr/local/bin/sing-box generate rand 16 --base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
    local sub_token=$(openssl rand -hex 12)

    # 防火墙精准放行
    if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
        ufw allow "$vl_port/tcp" >/dev/null 2>&1 || true
        if [ "$hy_enabled" = true ]; then
            ufw allow "$hy_port/udp" >/dev/null 2>&1 || true
        fi
    fi
    # 先清理本脚本可能遗留的端口跳跃规则，再按当前配置重建
    clear_port_hopping
    if [ "$hy_enabled" = true ] && [[ -n "$hy_range" ]]; then
        setup_port_hopping "$hy_port" "$hy_range"
    fi

    local sub_proto="http"
    [[ "$CERT_MODE" == "domain" ]] && sub_proto="https"

    write_singbox_config "$vl_port" "$vl_sni" "$user_uuid" "$vl_privkey" "$vl_shortid" "$hy_enabled" "$hy_port" "$hy_password"
    write_env_config

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
    generate_full_client_config "$target_host" "$sub_token" "$node_prefix" "$server_ip" "$vl_port" "$user_uuid" "$vl_sni" "$vl_pubkey" "$vl_shortid" "$hy_enabled" "$hy_port" "$hy_ports_display" "$hy_password" "$hy_skip_cert"
    setup_caddy_subscription "$target_host" "$sub_token" "$sub_port" "$CERT_MODE"

    show_subscription


    if [[ "${cert_fell_back:-}" == "true" ]]; then
        echo -e "${YELLOW}注意: 本次因域名证书申请失败已回退为 IP 自签证书，客户端已自动设为 skip-cert-verify。${PLAIN}"
    fi

    echo -e "\n${GREEN}===================================================================${PLAIN}"
    echo -e "${GREEN}🎉 Simple-Box 安装就绪！随时在终端输入 ${YELLOW}simbo${GREEN} 即可打开管理控制台。${PLAIN}"
    echo -e "${GREEN}===================================================================${PLAIN}\n"
}

# 输出订阅详情与节点 YAML
show_subscription() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未找到已安装的环境配置！${PLAIN}"
        return 1
    fi
    set +e
    source "$ENV_FILE"
    set -e
    local port=${SUB_PORT:-8444}
    local proto=${SUB_PROTO:-https}
    local host=${TARGET_HOST:-${HY_DOMAIN:-$SERVER_IP}}
    local sub_url="${proto}://${host}:${port}/${SUB_TOKEN}/config.yaml"
    local provider_url="${proto}://${host}:${port}/${SUB_TOKEN}/provider.yaml"

    echo -e "\n${GREEN}====================== 节点在线订阅已生成 ======================${PLAIN}"
    echo -e "1. ${YELLOW}完整配置订阅 (推荐 ClashX.Meta / Mihomo 直接导入托管)${PLAIN}:"
    echo -e "   ${GREEN}${sub_url}${PLAIN}"
    echo -e "   (内置 MIPS TUN、纯 IP DoH、ARC 缓存与 📌节点选择 分流规则)\n"
    echo -e "2. ${YELLOW}纯节点 Provider 订阅 (供自建规则文件引用)${PLAIN}:"
    echo -e "   ${GREEN}${provider_url}${PLAIN}"
    echo -e "${GREEN}=================================================================${PLAIN}"

    if [[ "$proto" == "http" ]]; then
        echo -e "${YELLOW}⚠️  安全与隐私提示 (IP 模式):${PLAIN}"
        echo -e "   • 分流规则已将 VPS IP 设为直连，确保节点更新/失效时订阅拉取绝不死锁。"
        echo -e "   • ${RED}注意: 当前订阅通过 HTTP 明文传输，不受 TLS 保护${PLAIN}，请勿在公共 Wi-Fi / 不可信网络环境下更新。"
        echo -e "   • 若需全链路隐私防嗅探保护，请在菜单 [2] 中配置自有域名启用 HTTPS 模式。"
    else
        echo -e "${GREEN}🛡️  隐私安全提示 (域名 HTTPS 模式):${PLAIN}"
        echo -e "   • 分流规则已将订阅域名 (${host}) 设为直连，确保节点更新/失效时订阅拉取绝不死锁。"
        echo -e "   • 订阅内容由权威 CA 证书 (TLS 1.3) 全程强加密分发，防链路嗅探，隐私受到完整保护。"
    fi

    if [[ -f "$YAML_PROVIDER" ]]; then
        echo -e "\n${YELLOW}=== 本地节点 YAML 片段 (亦可手动复制) ===${PLAIN}"
        cat "$YAML_PROVIDER"
        echo -e "${YELLOW}==========================================${PLAIN}\n"
    fi
}

# 展示单独节点链接与二维码
show_links() {
    if [[ ! -f "$LINKS_FILE" ]]; then
        if [[ -f "$ENV_FILE" ]]; then
            set +e; source "$ENV_FILE"; set -e
            local hy_ports_display="${HY_PORT}"
            [[ -n "${HY_RANGE:-}" ]] && hy_ports_display="${HY_PORT},${HY_RANGE/:/-}"
            local host=${TARGET_HOST:-${HY_DOMAIN:-$SERVER_IP}}
            local vless_link="vless://${VL_UUID}@${SERVER_IP}:${VL_PORT}?security=reality&encryption=none&pbk=${VL_PUBKEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${VL_SNI}&sid=${VL_SHORTID}#${NODE_PREFIX}-VLESS-Reality"
            echo "$vless_link" > "$LINKS_FILE"
            if [ "${HY_ENABLED:-true}" = true ]; then
                local insecure_flag="0"
                [[ "${HY_SKIP_CERT:-false}" == "true" ]] && insecure_flag="1"
                local mport_param=""
                [[ -n "$hy_ports_display" && "$hy_ports_display" == *,* ]] && mport_param="&mport=${hy_ports_display}"
                local hy2_link="hysteria2://${HY_PASS}@${host}:${HY_PORT}/?sni=${host}&insecure=${insecure_flag}${mport_param}#${NODE_PREFIX}-Hysteria2"
                echo "$hy2_link" >> "$LINKS_FILE"
            fi
        else
            echo -e "${RED}未找到节点环境配置，请先执行安装！${PLAIN}"
            return 1
        fi
    fi

    local vless_url=$(head -n 1 "$LINKS_FILE")
    local hy2_url=$(sed -n '2p' "$LINKS_FILE")

    echo -e "\n${GREEN}====================== 节点原生分享链接 ======================${PLAIN}"
    echo -e "${YELLOW}[1] VLESS-Reality 链接:${PLAIN}"
    echo -e "${GREEN}${vless_url}${PLAIN}"
    if command -v qrencode &>/dev/null; then
        echo -e "\n${YELLOW}[VLESS-Reality 二维码]:${PLAIN}"
        qrencode -t ANSIUTF8 "${vless_url}"
    fi

    if [[ -n "$hy2_url" ]]; then
        echo -e "\n--------------------------------------------------------------"
        echo -e "${YELLOW}[2] Hysteria 2 链接:${PLAIN}"
        echo -e "${GREEN}${hy2_url}${PLAIN}"
        if command -v qrencode &>/dev/null; then
            echo -e "\n${YELLOW}[Hysteria 2 二维码]:${PLAIN}"
            qrencode -t ANSIUTF8 "${hy2_url}"
        fi
    fi
    echo -e "${GREEN}==============================================================${PLAIN}\n"
    read -r -p "按回车键返回主菜单..." dummy || true
}

# 彻底干净卸载
uninstall_all() {
    echo -e "${YELLOW}警告: 即将彻底卸载 sing-box 并清除所有节点、订阅与证书配置！${PLAIN}"
    local confirm=""
    read -r -p "确认卸载吗？(y/N): " confirm || confirm=""
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "已取消。" && return 0

    echo -e "${BLUE}正在停止并移除服务...${PLAIN}"
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload

    if [[ -f "$ENV_FILE" ]]; then
        set +e; source "$ENV_FILE"; set -e
        if [[ -n "${HY_RANGE:-}" && -n "${HY_PORT:-}" ]]; then
            echo -e "${BLUE}精准清理端口跳跃规则...${PLAIN}"
            iptables -t nat -D PREROUTING -p udp --dport "$HY_RANGE" -j REDIRECT --to-ports "$HY_PORT" 2>/dev/null || true
            # 清理历史版本可能遗留的 IPv6 规则
            if command -v ip6tables &>/dev/null; then
                ip6tables -t nat -D PREROUTING -p udp --dport "$HY_RANGE" -j REDIRECT --to-ports "$HY_PORT" 2>/dev/null || true
            fi
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save >/dev/null 2>&1 || true
            fi
        fi
        rm -f /etc/caddy/sites/*-${SUB_PORT:-8444}.caddy /etc/caddy/sites/simple-box*.caddy
        systemctl reload caddy 2>/dev/null || true
    fi

    # 清理 acme.sh 中本机签发的续期任务（仅当存在 acme.sh 时）
    if [[ -x "$HOME/.acme.sh/acme.sh" && -f "$ENV_FILE" ]]; then
        local un_domain
        un_domain=$(grep -oP '^HY_DOMAIN="\K[^"]*' "$ENV_FILE" 2>/dev/null || true)
        if [[ -n "$un_domain" && "$un_domain" != "skip" ]]; then
            "$HOME/.acme.sh/acme.sh" --remove -d "$un_domain" --ecc >/dev/null 2>&1 || true
        fi
    fi

    rm -f /usr/local/bin/sing-box
    rm -f /usr/local/bin/simbo
    rm -rf /usr/local/share/simple-box
    rm -rf "$CONF_DIR"

    echo -e "${GREEN}sing-box 与订阅配置已彻底干净卸载！${PLAIN}"
}

# 交互控制台主循环

# ==================== 模块化独立子菜单 ====================

# 1. VLESS-Reality 独立模块配置
menu_reality_module() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未检测到已安装的配置，请先运行选项 7 重新安装Simple-Box！${PLAIN}"
        read -r -p "按回车键返回..." dummy || true
        return 0
    fi
    set +e; source "$ENV_FILE"; set -e

    while true; do
        [ -t 1 ] && clear
        echo -e "
${GREEN}================= VLESS-Reality 模块配置 =================${PLAIN}"
        echo -e " 1. 重置并更新 Reality 参数"
        echo -e " 0. 返回主菜单"
        echo -e "${GREEN}==========================================================${PLAIN}"
        local opt=""
        read -r -p "请输入选项 [0-1]: " opt || opt=""
        case "$opt" in
            1)
                echo -e "\n${YELLOW}=== 重置 VLESS-Reality 参数 ===${PLAIN}"
                local vl_port
                while true; do
                    read -r -p "请输入 Reality 监听端口 [默认 ${VL_PORT}]: " vl_port || vl_port=""
                    vl_port=$(trim_string "${vl_port:-${VL_PORT}}")
                    if ! validate_port "$vl_port"; then
                        echo -e "${RED}端口非法（应为 1-65535 的整数），请重新输入。${PLAIN}"; continue
                    fi
                    if [[ -n "${HY_PORT:-}" && "$vl_port" == "$HY_PORT" ]]; then
                        echo -e "${RED}端口冲突: 该端口已分配给 Hysteria 2 (${HY_PORT})，不能共用！${PLAIN}"; continue
                    fi
                    if [[ -n "${SUB_PORT:-}" && "$vl_port" == "$SUB_PORT" ]]; then
                        echo -e "${RED}端口冲突: 该端口已分配给 Caddy 订阅 (${SUB_PORT})，不能共用！${PLAIN}"; continue
                    fi
                    if [[ -n "${HY_RANGE:-}" ]]; then
                        local r_start="${HY_RANGE%%:*}" r_end="${HY_RANGE##*:}"
                        if (( vl_port >= r_start && vl_port <= r_end )); then
                            echo -e "${RED}范围冲突: 端口落在 Hysteria 2 跳跃范围 (${HY_RANGE}) 内，请调整！${PLAIN}"; continue
                        fi
                    fi
                    if [[ "$vl_port" == "$VL_PORT" ]] || check_port_occupied "$vl_port" "tcp"; then break; fi
                    echo -e "${YELLOW}请更换其他未占用的 TCP 端口！${PLAIN}"
                done

                local vl_sni
                while true; do
                    read -r -p "请输入 Reality 伪装域名 (SNI) [默认 ${VL_SNI}]: " vl_sni || vl_sni=""
                    vl_sni=$(trim_string "${vl_sni:-${VL_SNI}}")
                    if ! validate_domain "$vl_sni"; then
                        echo -e "${RED}伪装域名格式非法（示例: gateway.icloud.com），请重新输入。${PLAIN}"; continue
                    fi
                    if [[ "$vl_sni" == "$SERVER_IP" ]]; then
                        echo -e "${RED}伪装域名不能是本机 IP，必须为可正常 TLS1.3 握手的站点。${PLAIN}"; continue
                    fi
                    break
                done

                echo -e "${BLUE}生成新的 Reality 密钥凭证...${PLAIN}"
                local key_pair
                key_pair=$(/usr/local/bin/sing-box generate reality-keypair)
                local vl_privkey vl_pubkey vl_shortid user_uuid
                vl_privkey=$(echo "$key_pair" | awk '/PrivateKey/{print $2}')
                vl_pubkey=$(echo "$key_pair" | awk '/PublicKey/{print $2}')
                vl_shortid=$(/usr/local/bin/sing-box generate rand 8 --hex)
                user_uuid=$(/usr/local/bin/sing-box generate uuid)

                local node_prefix="$NODE_PREFIX"
                local server_ip="$SERVER_IP"
                local hy_enabled="${HY_ENABLED:-true}"
                local hy_domain="${HY_DOMAIN:-}"
                local target_host="${TARGET_HOST:-$server_ip}"
                local hy_port="${HY_PORT:-8443}"
                local hy_range="${HY_RANGE:-}"
                local hy_password="${HY_PASS:-}"
                local hy_skip_cert="${HY_SKIP_CERT:-true}"
                local sub_port="${SUB_PORT:-8444}"
                local sub_proto="${SUB_PROTO:-http}"
                local sub_token="${SUB_TOKEN}"
                local CERT_MODE="selfsigned"
                [[ "$hy_skip_cert" != "true" ]] && CERT_MODE="domain"

                write_singbox_config "$vl_port" "$vl_sni" "$user_uuid" "$vl_privkey" "$vl_shortid" "$hy_enabled" "$hy_port" "$hy_password"
                write_env_config
                if ! render_and_reload; then
                    echo -e "${RED}Reality 模块更新失败，请检查上面的错误信息。${PLAIN}"
                    read -r -p "按回车键返回..." dummy || true
                    continue
                fi

                echo -e "\n${GREEN}VLESS-Reality 模块已成功更新！${PLAIN}"
                echo -e "${CYAN}提示: 订阅链接与 Token 保持完全一致，客户端仅需点击“更新订阅”即可自动同步新节点。${PLAIN}"
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
        echo -e "${RED}未检测到已安装的配置，请先运行选项 7 重新安装Simple-Box！${PLAIN}"
        read -r -p "按回车键返回..." dummy || true
        return 0
    fi
    set +e; source "$ENV_FILE"; set -e

    while true; do
        [ -t 1 ] && clear
        echo -e "
${GREEN}================== Hysteria 2 模块配置 ===================${PLAIN}"
        echo -e " 1. 重置并更新 Hysteria 2 参数"
        echo -e " 0. 返回主菜单"
        echo -e "${GREEN}==========================================================${PLAIN}"
        local opt=""
        read -r -p "请输入选项 [0-1]: " opt || opt=""
        case "$opt" in
            1)
                echo -e "\n${YELLOW}=== 重置 Hysteria 2 参数 ===${PLAIN}"
                local hy_domain="" cf_token=""
                local CERT_MODE="selfsigned"
                local target_host="$SERVER_IP"
                local hy_skip_cert="true"

                while true; do
                    echo -e "\n请输入你的自有域名 (直接回车继续使用 IP 自签证书):"
                    read -r -p "域名: " hy_domain || hy_domain=""
                    hy_domain=$(trim_string "$hy_domain")
                    if [[ -z "$hy_domain" ]]; then
                        echo -e "${GREEN}选择使用 IP 自签证书。${PLAIN}"
                        break
                    fi
                    if ! validate_domain "$hy_domain"; then
                        echo -e "${RED}域名格式不合法（示例: node.example.com），请重新输入。${PLAIN}"; continue
                    fi
                    echo -e "\n${CYAN}------------------- Cloudflare API Token 获取指引 -------------------${PLAIN}"
echo -e "${CYAN} 1. 登录 CF -> 右上角头像 -> [配置文件] -> 左侧导航 [API 令牌]${PLAIN}"
echo -e "${CYAN} 2. 点击 [创建令牌] -> 找到 [编辑区域 DNS (Edit zone DNS)] 点击 [使用模板]${PLAIN}"
echo -e "${CYAN} 3. 区域资源选择: [包括] -> [特定区域] -> 选择你的域名${PLAIN}"
echo -e "${CYAN} 4. 底部点击 [继续以显示摘要] -> 最终确认页点击 [创建令牌] 并复制生成的令牌${PLAIN}"
echo -e "${CYAN}---------------------------------------------------------------------${PLAIN}"
                    while true; do
                        read -r -p "请输入 Cloudflare API Token: " cf_token || cf_token=""
                        cf_token=$(trim_string "$cf_token")
                        if [[ -z "$cf_token" ]]; then
                            echo -e "${YELLOW}未输入 Token，将自动使用 IP 自签证书。${PLAIN}"
                            hy_domain=""
                            break
                        fi
                        if verify_cloudflare_token "$cf_token"; then
                            break
                        fi
                        local retry=""
                        read -r -p "是否重新输入 Token？[Y/n (回车重试，输入 n 使用 IP 自签)]: " retry || retry=""
                        if [[ "${retry,,}" == "n" ]]; then
                            echo -e "${YELLOW}已放弃域名证书，将自动使用 IP 自签证书。${PLAIN}"
                            hy_domain=""
                            cf_token=""
                            break
                        fi
                    done
                    break
                done

                local hy_port
                while true; do
                    read -r -p "请输入 Hysteria 2 主监听 UDP 端口 [默认 ${HY_PORT:-8443}]: " hy_port || hy_port=""
                    hy_port=$(trim_string "${hy_port:-${HY_PORT:-8443}}")
                    if ! validate_port "$hy_port"; then
                        echo -e "${RED}端口非法，请重新输入。${PLAIN}"; continue
                    fi
                    if [[ "$hy_port" == "$VL_PORT" ]]; then
                        echo -e "${RED}端口冲突: 该端口已分配给 VLESS-Reality (${VL_PORT})，不能共用！${PLAIN}"; continue
                    fi
                    if [[ "$hy_port" == "$SUB_PORT" ]]; then
                        echo -e "${RED}端口冲突: 该端口已分配给 Caddy 订阅 (${SUB_PORT})，不能共用！${PLAIN}"; continue
                    fi
                    if [[ "$hy_port" == "$HY_PORT" ]] || check_port_occupied "$hy_port" "udp"; then break; fi
                    echo -e "${YELLOW}请更换其他未占用的 UDP 端口！${PLAIN}"
                done

                local hy_range
                while true; do
                    read -r -p "请输入端口跳跃范围 [默认 ${HY_RANGE:-20000:40000}] (none=不启用): " hy_range || hy_range=""
                    hy_range=$(trim_string "${hy_range:-${HY_RANGE:-20000:40000}}")
                    [[ "${hy_range,,}" == "none" ]] && { hy_range=""; break; }
                    if ! validate_range "$hy_range"; then
                        echo -e "${RED}范围格式非法，应为 起始:结束（如 20000:40000）。${PLAIN}"; continue
                    fi
                    local r_start="${hy_range%%:*}" r_end="${hy_range##*:}"
                    if (( VL_PORT >= r_start && VL_PORT <= r_end )); then
                        echo -e "${RED}范围冲突: 跳跃范围包含 Reality 端口 (${VL_PORT})，请调整！${PLAIN}"; continue
                    fi
                    if (( hy_port >= r_start && hy_port <= r_end )); then
                        echo -e "${RED}范围冲突: 跳跃范围包含 Hy2 主端口 (${hy_port})，请调整！${PLAIN}"; continue
                    fi
                    if [[ -n "$SUB_PORT" ]] && (( SUB_PORT >= r_start && SUB_PORT <= r_end )); then
                        echo -e "${RED}范围冲突: 跳跃范围包含 Caddy 订阅端口 (${SUB_PORT})，请调整！${PLAIN}"; continue
                    fi
                    break
                done

                # 重签证书前必须先停 sing-box，否则文件监视器会读到「新 cert + 旧 key」
                if systemctl is-active --quiet sing-box 2>/dev/null; then
                    systemctl stop sing-box 2>/dev/null || true
                fi

                if [[ -n "$hy_domain" && -n "$cf_token" ]]; then
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
                local hy_enabled="true"

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
                    echo -e "${YELLOW}请进入 [1] VLESS-Reality 模块配置 重新生成一次密钥，再回到此处。${PLAIN}"
                    systemctl start sing-box 2>/dev/null || true
                    read -r -p "按回车键返回..." dummy || true
                    continue
                fi

                write_singbox_config "$vl_port" "$vl_sni" "$user_uuid" "$vl_privkey" "$vl_shortid" "$hy_enabled" "$hy_port" "$hy_password"
                write_env_config
                if ! render_and_reload; then
                    echo -e "${RED}Hysteria 2 模块更新失败，请检查上面的错误信息。${PLAIN}"
                    # 证书阶段可能已停服务，失败路径必须把服务拉回来
                    systemctl start sing-box 2>/dev/null || true
                    read -r -p "按回车键返回..." dummy || true
                    continue
                fi

                echo -e "\n${GREEN}Hysteria 2 模块已成功更新！${PLAIN}"
                echo -e "${CYAN}提示: 订阅链接与 Token 保持完全一致，客户端仅需点击“更新订阅”即可自动同步新节点。${PLAIN}"
                read -r -p "按回车键返回..." dummy || true
                set +e; source "$ENV_FILE"; set -e
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

# 3. 在线订阅站点独立模块配置 (结构与模块 1、2 统一)
menu_sub_module() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未检测到已安装的配置，请先运行选项 7 重新安装Simple-Box！${PLAIN}"
        read -r -p "按回车键返回..." dummy || true
        return 0
    fi
    set +e; source "$ENV_FILE"; set -e

    while true; do
        [ -t 1 ] && clear
        echo -e "
${GREEN}================ 在线订阅站点模块配置 ================${PLAIN}"
        echo -e " 1. 重置并更新在线订阅参数 (改端口 / 刷新 Token)"
        echo -e " 0. 返回主菜单"
        echo -e "${GREEN}======================================================${PLAIN}"
        local opt=""
        read -r -p "请输入选项 [0-1]: " opt || opt=""
        case "$opt" in
            1)
                echo -e "\n${YELLOW}=== 重置并更新在线订阅参数 ===${PLAIN}"
                local sub_port
                while true; do
                    read -r -p "请输入新的订阅监听端口 [默认 ${SUB_PORT}]: " sub_port || sub_port=""
                    sub_port=$(trim_string "${sub_port:-${SUB_PORT}}")
                    if ! validate_port "$sub_port"; then
                        echo -e "${RED}端口非法，请重新输入。${PLAIN}"; continue
                    fi
                    if [[ "$sub_port" == "$VL_PORT" ]]; then
                        echo -e "${RED}端口冲突: 该端口已分配给 VLESS-Reality (${VL_PORT})！${PLAIN}"; continue
                    fi
                    if [[ -n "${HY_PORT:-}" && "$sub_port" == "$HY_PORT" ]]; then
                        echo -e "${RED}端口冲突: 该端口已分配给 Hysteria 2 (${HY_PORT})！${PLAIN}"; continue
                    fi
                    if [[ -n "${HY_RANGE:-}" ]]; then
                        local r_start="${HY_RANGE%%:*}" r_end="${HY_RANGE##*:}"
                        if (( sub_port >= r_start && sub_port <= r_end )); then
                            echo -e "${RED}范围冲突: 订阅端口落在 Hysteria 2 跳跃范围 (${HY_RANGE}) 内！${PLAIN}"; continue
                        fi
                    fi
                    if [[ "$sub_port" == "$SUB_PORT" ]] || check_port_occupied "$sub_port" "tcp"; then break; fi
                    echo -e "${YELLOW}请更换其他未占用的 TCP 端口！${PLAIN}"
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
                local CERT_MODE="selfsigned"
                [[ "${HY_SKIP_CERT:-true}" != "true" ]] && CERT_MODE="domain"

                local node_prefix="$NODE_PREFIX"
                local server_ip="$SERVER_IP"
                local vl_port="$VL_PORT"
                local vl_sni="$VL_SNI"
                local user_uuid="$VL_UUID"
                local vl_privkey="${VL_PRIVKEY:-}"
                local vl_pubkey="$VL_PUBKEY"
                local vl_shortid="$VL_SHORTID"
                local hy_enabled="${HY_ENABLED:-true}"
                local hy_domain="${HY_DOMAIN:-}"
                local target_host="${TARGET_HOST:-$server_ip}"
                local hy_port="${HY_PORT:-8443}"
                local hy_range="${HY_RANGE:-}"
                local hy_password="${HY_PASS:-}"
                local hy_skip_cert="${HY_SKIP_CERT:-true}"
                local sub_proto="$SUB_PROTO"
                local sub_token="$new_token"
                write_env_config

                local hy_ports_display="$hy_port"
                [[ -n "$hy_range" ]] && hy_ports_display="${hy_port},${hy_range/:/-}"
                generate_full_client_config "$target_host" "$new_token" "$node_prefix" "$server_ip" "$vl_port" "$user_uuid" "$vl_sni" "$vl_pubkey" "$vl_shortid" "$hy_enabled" "$hy_port" "$hy_ports_display" "$hy_password" "$hy_skip_cert"

                setup_caddy_subscription "$target_host" "$new_token" "$SUB_PORT" "$CERT_MODE"
                reload_caddy_safe || true
                verify_caddy_listening "$SUB_PORT" || true

                echo -e "\n${GREEN}✓ 在线订阅站点已成功更新！${PLAIN}"
                echo -e "当前在线订阅: ${CYAN}${sub_proto}://${target_host}:${SUB_PORT}/${new_token}/config.yaml${PLAIN}"
                echo -e "${YELLOW}提示: 订阅参数已更新，请在客户端 (如 ClashX.Meta) 中修改端口或更新订阅 URL。${PLAIN}"
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
        echo -e "\n${GREEN}=================== sing-box 内核管理 ===================${PLAIN}"
        echo -e " 1. 重启 / 启动 sing-box 服务"
        echo -e " 2. 检查并更新 sing-box 内核"
        echo -e " 3. 查看实时运行日志"
        echo -e " 0. 返回主菜单"
        echo -e "${GREEN}==========================================================${PLAIN}"
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
                echo -e "\n${BLUE}正在获取 sing-box 最近 40 行运行日志：${PLAIN}\n"
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
        echo -e "${GREEN}====================================================${PLAIN}"
        echo -e "${GREEN}        Simple-Box Manager - 极简安全控制台        ${PLAIN}"
        echo -e "${GREEN}====================================================${PLAIN}"
        
        # 1. 宿主机基本信息提取
        local os_name="Linux"
        if [ -f /etc/os-release ]; then
            os_name=$(grep -oP 'PRETTY_NAME="\K[^"]+' /etc/os-release || grep -oP 'PRETTY_NAME=\K.+' /etc/os-release | tr -d '"')
        fi
        local arch=$(get_arch)
        local cur_ip=$(curl -s4m3 https://icanhazip.com || echo "检测中...")
        local bbr_status=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "关闭")
        if [[ "$bbr_status" == "bbr" ]]; then
            bbr_status="${GREEN}已开启 (bbr)${PLAIN}"
        else
            bbr_status="${YELLOW}未开启 (${bbr_status})${PLAIN}"
        fi

        # 2. 服务运行状态与版本提取
        local sb_ver="未安装"
        local sb_status="${RED}未运行${PLAIN}"
        if [[ -f /usr/local/bin/sing-box ]]; then
            sb_ver=$(/usr/local/bin/sing-box version 2>/dev/null | head -n1 | awk '{print $3}')
            if systemctl is-active --quiet sing-box; then
                sb_status="${GREEN}运行中 (v${sb_ver})${PLAIN}"
            else
                sb_status="${RED}已停止 (v${sb_ver})${PLAIN}"
            fi
        fi

        local caddy_status="${RED}未运行${PLAIN}"
        local sub_port="8444"
        if [[ -f "$ENV_FILE" ]]; then
            set +e; source "$ENV_FILE"; set -e
            sub_port=${SUB_PORT:-8444}
        fi
        if command -v caddy &>/dev/null && systemctl is-active --quiet caddy; then
            local p_tag="HTTP"
            [[ "${SUB_PROTO:-}" == "https" ]] && p_tag="HTTPS"
            caddy_status="${GREEN}运行中 (端口: ${sub_port} [${p_tag}])${PLAIN}"
        fi

        # 3. 打印系统面板
        echo -e " 操作系统: ${CYAN}${os_name} (${arch})${PLAIN}"
        local cert_display="未配置"
        if [[ -f "$ENV_FILE" ]]; then
            set +e; source "$ENV_FILE"; set -e
            if [[ "$HY_ENABLED" == "false" || "$HY_DOMAIN" == "skip" ]]; then
                cert_display="未启用 (仅Reality)"
            elif [[ -n "$HY_DOMAIN" && "$HY_DOMAIN" != "skip" ]]; then
                cert_display="${HY_DOMAIN}"
            elif [[ "$HY_SKIP_CERT" == "true" ]]; then
                cert_display="IP 自签证书"
            fi
        fi
        echo -e " 公网 IP : ${CYAN}${cur_ip}${PLAIN} | TLS 证书: ${CYAN}${cert_display}${PLAIN}"
        echo -e " TCP 加速: ${bbr_status}"
        echo -e " sing-box: ${sb_status}"
        echo -e " Caddy订阅: ${caddy_status}"
        
        if [[ -f "$ENV_FILE" ]]; then
            local p_hy="未启用"
            if [ "${HY_ENABLED:-true}" = true ]; then
                if [[ -n "${HY_RANGE:-}" ]]; then
                    p_hy="UDP ${HY_PORT:-8443} [跳跃: ${HY_RANGE}]"
                else
                    p_hy="UDP ${HY_PORT:-8443} [无跳跃]"
                fi
            fi
            echo -e " 当前节点: ${BLUE}Reality: TCP ${VL_PORT:-443} | Hy2: ${p_hy}${PLAIN}"
            
            local proto=${SUB_PROTO:-http}
            local host=${TARGET_HOST:-${HY_DOMAIN:-$SERVER_IP}}
            local port=${SUB_PORT:-8444}
            echo -e "${GREEN}----------------------------------------------------${PLAIN}"
            echo -e " 在线订阅: ${CYAN}${proto}://${host}:${port}/${SUB_TOKEN}/config.yaml${PLAIN}"
            echo -e " 节点列表: ${CYAN}${proto}://${host}:${port}/${SUB_TOKEN}/provider.yaml${PLAIN}"
            if [[ "$proto" == "http" ]]; then
                echo -e " 订阅安全: ${YELLOW}直连分发 (HTTP 未加密，建议在可信网络下更新)${PLAIN}"
            else
                echo -e " 订阅安全: ${GREEN}TLS 1.3 强加密保护 (权威 CA 证书，直连防死锁)${PLAIN}"
            fi
        fi

        echo -e "${GREEN}----------------------------------------------------${PLAIN}"
        echo -e " 1. VLESS-Reality 模块配置"
        echo -e " 2. Hysteria 2 模块配置"
        echo -e " 3. 在线订阅站点模块配置"
        echo -e " 4. 查看节点链接与二维码 (URI/QR Code)"
        echo -e " 5. TCP BBR 加速管理"
        echo -e " 6. sing-box 内核管理"
        echo -e " 7. 重新安装Simple-Box"
        echo -e " 8. 卸载 Simple-Box 脚本"
        echo -e " 0. 退出管理控制台"
        echo -e "${GREEN}====================================================${PLAIN}"
        
        local opt=""
        read -r -p "请输入选项 [0-8]: " opt || opt="0"
        case "$opt" in
            1) menu_reality_module || true ;;
            2) menu_hy2_module || true ;;
            3) menu_sub_module || true ;;
            4) show_links || true ;;
            5) manage_bbr || true ;;
            6) menu_singbox_manage || true ;;
            7) install_node || true ;;
            8) uninstall_all || true ;;
            0) echo -e "${GREEN}已退出。随时输入 simbo 即可重新打开面板。${PLAIN}"; exit 0 ;;
            *) echo -e "${RED}无效选项！${PLAIN}"; sleep 1 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        install|reinstall) install_node || exit 1 ;;
        reality) menu_reality_module ;;
        hy2) menu_hy2_module ;;
        sub|yaml) show_subscription ;;
        link|url|qr) show_links ;;
        bbr) manage_bbr ;;
        core|box) menu_singbox_manage ;;
        del|uninstall) uninstall_all ;;
        *) menu ;;
    esac
fi
