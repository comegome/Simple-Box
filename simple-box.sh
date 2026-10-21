#!/usr/bin/env bash
# ==============================================================================
# Simple-Box Manager - 极简、安全、透明的自用 Sing-box 服务端管理脚本
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

# 端口冲突检测
check_port_occupied() {
    local port="$1"
    local proto="$2"
    local in_use=""
    if [[ "$proto" == "tcp" ]]; then
        in_use=$(ss -tlnp 2>/dev/null | grep -E "[: ]${port} " || true)
    elif [[ "$proto" == "udp" ]]; then
        in_use=$(ss -ulnp 2>/dev/null | grep -E "[: ]${port} " || true)
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
            apt-get update -qq && apt-get install -y -qq "${missing[@]}" iptables-persistent
        elif command -v yum &>/dev/null; then
            yum install -y epel-release && yum install -y "${missing[@]}"
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
    local cur_bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    local cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")

    echo -e "\n${GREEN}====================================================${PLAIN}"
    echo -e "${GREEN}              TCP 拥塞控制管理 (BBR)                ${PLAIN}"
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e " 当前算法: ${CYAN}${cur_bbr}${PLAIN} | 队列规则: ${CYAN}${cur_qdisc}${PLAIN}"
    echo -e " 1. 开启 / 优化 BBR 加速 (推荐: bbr + fq)"
    echo -e " 2. 关闭 BBR 并恢复系统默认 (恢复为 cubic)"
    echo -e " 0. 返回"
    echo -e "${GREEN}====================================================${PLAIN}"

    local opt=""
    read -r -p "请输入选项 [0-2]: " opt || true
    opt=${opt:-1}

    case "$opt" in
        1)
            if [[ "$cur_bbr" == "bbr" ]]; then
                echo -e "${GREEN}当前已处于 BBR 状态，无需重复开启！${PLAIN}"
            else
                mkdir -p /etc/sysctl.d
                cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
                sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
                local new_bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
                if [[ "$new_bbr" == "bbr" ]]; then
                    echo -e "${GREEN}BBR 拥塞控制加速已成功开启并立即生效！${PLAIN}"
                else
                    echo -e "${YELLOW}已写入配置，若未生效请检查内核版本是否 >= 4.9 并重启系统。${PLAIN}"
                fi
            fi
            ;;
        2)
            rm -f /etc/sysctl.d/99-bbr.conf
            sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
            sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
            echo -e "${GREEN}已成功关闭 BBR，当前已还原为系统默认 (cubic)！${PLAIN}"
            ;;
        0) return 0 ;;
        *) echo -e "${RED}无效选项！${PLAIN}" ;;
    esac
}

# 获取并升级官方 sing-box 内核（带精准版本校验）
update_singbox_core() {
    local force_flag="$1"
    echo -e "${BLUE}检查 sing-box 官方最新版本...${PLAIN}"

    local cur_ver="未安装"
    if [[ -f /usr/local/bin/sing-box ]]; then
        cur_ver=$(/usr/local/bin/sing-box version 2>/dev/null | head -n1 | awk '{print $3}')
    fi

    local tag=$(curl -sSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep -Po '"tag_name": "\K[^"]*')
    [[ -z "$tag" ]] && echo -e "${RED}获取最新版本失败，请检查网络！${PLAIN}" && return 1
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

    local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${version:-$latest_ver}-linux-${arch}.tar.gz"
    local tmp_dir=$(mktemp -d)
    
    echo -e "${BLUE}正在下载并更新内核...${PLAIN}"
    curl -sSL "$url" | tar -xz -C "$tmp_dir" --strip-components=1
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
issue_cert_bundle() {
    local domain="$1"
    local cf_token="$2"
    local server_ip="$3"
    local acme_bin="$HOME/.acme.sh/acme.sh"

    mkdir -p "$CERT_DIR"

    # 模式 A: 用户提供了自有域名与 CF Token
    if [[ -n "$domain" && -n "$cf_token" ]]; then
        echo -e "${BLUE}配置 acme.sh 证书环境...${PLAIN}"
        if [ ! -f "$acme_bin" ]; then
            curl -sSL https://get.acme.sh | sh -s email="admin@${domain}"
        fi

        export CF_Token="$cf_token"
        if [[ -f "$HOME/.acme.sh/${domain}_ecc/fullchain.cer" && -f "$HOME/.acme.sh/${domain}_ecc/${domain}.key" ]]; then
            echo -e "${GREEN}检测到本地已有 ${domain} 的有效证书，直接同步部署...${PLAIN}"
        else
            echo -e "${BLUE}通过 Cloudflare DNS API 申请全新证书...${PLAIN}"
            "$acme_bin" --set-default-ca --server letsencrypt
            "$acme_bin" --issue --dns dns_cf -d "$domain" --dnssleep 20 --keylength ec-256 --force
        fi

        "$acme_bin" --install-cert -d "$domain" --ecc \
            --fullchain-file "${CERT_DIR}/fullchain.cer" \
            --key-file "${CERT_DIR}/private.key" \
            --reloadcmd "systemctl reload sing-box 2>/dev/null || true; systemctl reload caddy 2>/dev/null || true"
    else
        # 模式 B: 无自有域名，降级为 10年 ECC 自签证书 (针对公网 IP 签发)
        echo -e "${YELLOW}未配置自有域名，正在为服务器 IP (${server_ip}) 生成 10 年自签 ECC 证书...${PLAIN}"
        openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/private.key" >/dev/null 2>&1
        openssl req -new -x509 -days 3650 -key "${CERT_DIR}/private.key" -out "${CERT_DIR}/fullchain.cer" \
            -subj "/CN=${server_ip}" >/dev/null 2>&1
    fi

    chmod 755 "$CONF_DIR" "$CERT_DIR" 2>/dev/null || true
    chmod 644 "${CERT_DIR}"/* 2>/dev/null || true

    if [[ -f "${CERT_DIR}/fullchain.cer" && -f "${CERT_DIR}/private.key" ]]; then
        echo -e "${GREEN}证书已就绪安装至 ${CERT_DIR}！${PLAIN}"
    else
        echo -e "${RED}证书生成失败，请检查配置！${PLAIN}"
        exit 1
    fi
}

# 端口跳跃 iptables 规则配置
setup_port_hopping() {
    local hy_port="$1"
    local range="$2"

    echo -e "${BLUE}配置 Hysteria 2 端口跳跃 (UDP ${range} -> ${hy_port})...${PLAIN}"
    iptables -t nat -D PREROUTING -p udp --dport "$range" -j REDIRECT --to-ports "$hy_port" 2>/dev/null || true
    iptables -t nat -A PREROUTING -p udp --dport "$range" -j REDIRECT --to-ports "$hy_port"
    if command -v ip6tables &>/dev/null; then
        ip6tables -t nat -D PREROUTING -p udp --dport "$range" -j REDIRECT --to-ports "$hy_port" 2>/dev/null || true
        ip6tables -t nat -A PREROUTING -p udp --dport "$range" -j REDIRECT --to-ports "$hy_port" 2>/dev/null || true
    fi

    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi

    if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
        ufw allow "$hy_port/udp" >/dev/null 2>&1 || true
        ufw allow "${range/:/-}/udp" >/dev/null 2>&1 || true
    fi
}

# 部署 Caddy 订阅分发服务
setup_caddy_subscription() {
    local domain_or_ip="$1"
    local token="$2"
    local sub_port="$3"

    install_caddy

    echo -e "${BLUE}配置 Caddy HTTPS 安全订阅站点 (端口 ${sub_port})...${PLAIN}"
    mkdir -p "/etc/caddy/sites"
    
    if [ ! -f /etc/caddy/Caddyfile ]; then
        echo -e "import sites/*.caddy\n" > /etc/caddy/Caddyfile
    elif ! grep -q "import sites/\*\.caddy" /etc/caddy/Caddyfile; then
        echo -e "\nimport sites/*.caddy" >> /etc/caddy/Caddyfile
    fi

    rm -f "/etc/caddy/sites/${domain_or_ip}-${sub_port}.caddy" "/etc/caddy/sites/simple-box.caddy"

    cat > "/etc/caddy/sites/${domain_or_ip}-${sub_port}.caddy" <<EOF
# Simple-Box HTTPS 订阅分发站点
${domain_or_ip}:${sub_port} {
    tls ${CERT_DIR}/fullchain.cer ${CERT_DIR}/private.key

    @sub path /sub_${token}/config.yaml /sub_${token}/provider.yaml /sub_${token}/links.txt
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

    if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
        ufw allow "${sub_port}/tcp" >/dev/null 2>&1 || true
    fi

    chmod 755 "$WEB_DIR" 2>/dev/null || true
    systemctl restart caddy
}

# 组装客户端订阅与独立链接
generate_full_client_config() {
    local domain_or_ip="$1"
    local token="$2"
    local node_prefix="$3"
    local server_ip="$4"
    local vl_port="$5"
    local user_uuid="$6"
    local vl_sni="$7"
    local vl_pubkey="$8"
    local vl_shortid="$9"
    local hy_enabled="${10}"
    local hy_port="${11}"
    local hy_ports_display="${12}"
    local hy_password="${13}"
    local hy_skip_cert="${14}"

    mkdir -p "${WEB_DIR}/sub_${token}"

    if [ ! -f "$TEMPLATE_FILE" ]; then
        curl -fsSL https://raw.githubusercontent.com/comegome/simple-box/main/template.yaml -o "$TEMPLATE_FILE" 2>/dev/null || true
    fi

    # 1. 组装完整配置
    local full_config_file="${WEB_DIR}/sub_${token}/config.yaml"
    if [ -f "$TEMPLATE_FILE" ]; then
        cat "$TEMPLATE_FILE" > "$full_config_file"
    else
        echo "mixed-port: 7890" > "$full_config_file"
        echo "mode: rule" >> "$full_config_file"
    fi

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
    ports: "${hy_ports_display}"
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
    echo "      - "DIRECT"" >> "$full_config_file"

    # 2. 组装纯 Provider 片段
    local provider_file="${WEB_DIR}/sub_${token}/provider.yaml"
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
    ports: "${hy_ports_display}"
    password: "${hy_password}"
    sni: ${domain_or_ip}
    skip-cert-verify: ${hy_skip_cert}
EOF
    fi
    cp -f "$provider_file" "$YAML_PROVIDER"

    # 3. 组装原生分享链接
    local vless_link="vless://${user_uuid}@${server_ip}:${vl_port}?security=reality&encryption=none&pbk=${vl_pubkey}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${vl_sni}&sid=${vl_shortid}#${node_prefix}-VLESS-Reality"
    local links_out="${WEB_DIR}/sub_${token}/links.txt"
    echo "$vless_link" > "$links_out"

    if [ "$hy_enabled" = true ]; then
        local insecure_flag="0"
        [[ "$hy_skip_cert" == "true" ]] && insecure_flag="1"
        local hy2_link="hysteria2://${hy_password}@${domain_or_ip}:${hy_port}/?sni=${domain_or_ip}&insecure=${insecure_flag}&mport=${hy_ports_display}#${node_prefix}-Hysteria2"
        echo "$hy2_link" >> "$links_out"
    fi
    cp -f "$links_out" "$LINKS_FILE"
}

# 部署与配置主函数
install_node() {
    install_deps
    [[ ! -f /usr/local/bin/sing-box ]] && update_singbox_core "force"

    mkdir -p "$CONF_DIR" "$WEB_DIR"
    local server_ip=$(curl -s4m5 https://icanhazip.com || curl -s4m5 https://api.ipify.org || echo "YOUR_SERVER_IP")

    echo -e "\n${YELLOW}=== 1. 配置 VLESS-Reality 参数 ===${PLAIN}"
    while true; do
        if [[ -z "$VL_PORT" ]]; then
            read -p "请输入 Reality 监听端口 [默认 443]: " vl_port
        fi
        vl_port=${vl_port:-${VL_PORT:-443}}
        if check_port_occupied "$vl_port" "tcp"; then
            break
        else
            echo -e "${YELLOW}请更换其他未占用的端口！${PLAIN}"
            VL_PORT=""
            vl_port=""
        fi
    done

    if [[ -z "$VL_SNI" ]]; then
        read -p "请输入 Reality 借壳伪装域名 [默认 gateway.icloud.com]: " vl_sni
    fi
    vl_sni=${vl_sni:-${VL_SNI:-gateway.icloud.com}}

    echo -e "\n${YELLOW}=== 2. 配置 Hysteria 2 参数 ===${PLAIN}"
    local hy_enabled=true
    local hy_skip_cert="false"

    if [[ -z "$HY_DOMAIN" ]]; then
        echo -e "${CYAN}重要提示:${PLAIN}"
        echo -e "${CYAN}  1. 若使用自有域名，请确保已在 Cloudflare 添加 A 记录解析到本服务器 IP (${server_ip})${PLAIN}"
        echo -e "${CYAN}  2. Cloudflare 代理状态必须为【仅限 DNS】(灰色云朵，切勿开启小黄云 CDN，否则阻断 UDP)${PLAIN}"
        echo -e "${CYAN}  3. 若无域名可直接回车，将自动生成 10 年自签证书基于公网 IP 直连启用 Hysteria 2${PLAIN}"
        read -p "请输入你的自有域名 [留空使用自签证书，输入 skip 完全跳过]: " hy_domain
    fi
    hy_domain=${hy_domain:-$HY_DOMAIN}

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
            read -p "请输入 Cloudflare API Token (需拥有 Zone.DNS 编辑权限): " cf_token
        fi
        cf_token=${cf_token:-$CF_TOKEN}
        [[ -z "$cf_token" ]] && echo -e "${RED}CF Token 不能为空！${PLAIN}" && exit 1
    fi

    local hy_port="8443"
    local hy_range="20000:40000"

    if [ "$hy_enabled" = true ]; then
        while true; do
            if [[ -z "$HY_PORT" ]]; then
                read -p "请输入 Hysteria 2 主监听 UDP 端口 [默认 8443]: " hy_port
            fi
            hy_port=${hy_port:-${HY_PORT:-8443}}
            if check_port_occupied "$hy_port" "udp"; then
                break
            else
                echo -e "${YELLOW}请更换其他未占用的 UDP 端口！${PLAIN}"
                HY_PORT=""
                hy_port=""
            fi
        done

        if [[ -z "$HY_RANGE" ]]; then
            read -p "请输入端口跳跃范围 [默认 20000:40000]: " hy_range
        fi
        hy_range=${hy_range:-${HY_RANGE:-20000:40000}}
    fi

    echo -e "\n${YELLOW}=== 3. 配置 HTTPS 订阅站点参数 ===${PLAIN}"
    while true; do
        if [[ -z "$SUB_PORT" ]]; then
            read -p "请输入 Caddy 订阅 HTTPS 监听端口 [默认 8444]: " sub_port
        fi
        sub_port=${sub_port:-${SUB_PORT:-8444}}
        if check_port_occupied "$sub_port" "tcp"; then
            break
        else
            echo -e "${YELLOW}请更换其他未占用的 TCP 端口！${PLAIN}"
            SUB_PORT=""
            sub_port=""
        fi
    done

    if [[ -z "$NODE_PREFIX" ]]; then
        read -p "请输入节点名称前缀 (如 HK / US / Oracle-O2) [默认 Node]: " node_prefix
    fi
    node_prefix=${node_prefix:-${NODE_PREFIX:-Node}}

    # 签发证书 (正规 CA 或自签)
    issue_cert_bundle "$hy_domain" "$cf_token" "$server_ip"

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
    if [ "$hy_enabled" = true ]; then
        setup_port_hopping "$hy_port" "$hy_range"
    fi

    # 生成 sing-box 配置文件
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
      "listen": "::",
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
      "listen": "::",
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

    # 保存环境配置备忘
    cat > "$ENV_FILE" <<EOF
NODE_PREFIX="${node_prefix}"
SERVER_IP="${server_ip}"
VL_PORT="${vl_port}"
VL_SNI="${vl_sni}"
VL_UUID="${user_uuid}"
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
SUB_TOKEN="${sub_token}"
EOF

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
    systemctl enable --now sing-box
    systemctl restart sing-box

    # 注册全局快捷指令 simbo
    install -m 755 "$0" /usr/local/bin/simbo 2>/dev/null || cp -f "$0" /usr/local/bin/simbo

    # 部署 Caddy 订阅并组装完整客户端配置
    local hy_ports_display="${hy_port},${hy_range/:/-}"
    generate_full_client_config "$target_host" "$sub_token" "$node_prefix" "$server_ip" "$vl_port" "$user_uuid" "$vl_sni" "$vl_pubkey" "$vl_shortid" "$hy_enabled" "$hy_port" "$hy_ports_display" "$hy_password" "$hy_skip_cert"
    setup_caddy_subscription "$target_host" "$sub_token" "$sub_port"

    show_subscription
}

# 输出订阅详情与节点 YAML
show_subscription() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}未找到已安装的环境配置！${PLAIN}"
        return 1
    fi
    source "$ENV_FILE"
    local port=${SUB_PORT:-8444}
    local host=${TARGET_HOST:-${HY_DOMAIN:-$SERVER_IP}}
    local sub_url="https://${host}:${port}/sub_${SUB_TOKEN}/config.yaml"
    local provider_url="https://${host}:${port}/sub_${SUB_TOKEN}/provider.yaml"

    echo -e "\n${GREEN}====================== 节点在线订阅已生成 ======================${PLAIN}"
    echo -e "1. ${YELLOW}完整配置订阅 (推荐 ClashX.Meta / Mihomo 直接导入托管)${PLAIN}:"
    echo -e "   ${GREEN}${sub_url}${PLAIN}"
    echo -e "   (内置 MIPS TUN、纯 IP DoH、ARC 缓存与 📌节点选择 分流规则)\n"
    echo -e "2. ${YELLOW}纯节点 Provider 订阅 (供自建规则文件引用)${PLAIN}:"
    echo -e "   ${GREEN}${provider_url}${PLAIN}"
    echo -e "${GREEN}=================================================================${PLAIN}"

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
            source "$ENV_FILE"
            local hy_ports_display="${HY_PORT},${HY_RANGE/:/-}"
            local host=${TARGET_HOST:-${HY_DOMAIN:-$SERVER_IP}}
            local vless_link="vless://${VL_UUID}@${SERVER_IP}:${VL_PORT}?security=reality&encryption=none&pbk=${VL_PUBKEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${VL_SNI}&sid=${VL_SHORTID}#${NODE_PREFIX}-VLESS-Reality"
            echo "$vless_link" > "$LINKS_FILE"
            if [ "${HY_ENABLED:-true}" = true ]; then
                local insecure_flag="0"
                [[ "${HY_SKIP_CERT:-false}" == "true" ]] && insecure_flag="1"
                local hy2_link="hysteria2://${HY_PASS}@${host}:${HY_PORT}/?sni=${host}&insecure=${insecure_flag}&mport=${hy_ports_display}#${NODE_PREFIX}-Hysteria2"
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
}

# 彻底干净卸载
uninstall_all() {
    echo -e "${YELLOW}警告: 即将彻底卸载 sing-box 并清除所有节点、订阅与证书配置！${PLAIN}"
    read -p "确认卸载吗？(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "已取消。" && return 0

    echo -e "${BLUE}正在停止并移除服务...${PLAIN}"
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload

    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE"
        if [[ -n "$HY_RANGE" && -n "$HY_PORT" ]]; then
            echo -e "${BLUE}精准清理端口跳跃规则...${PLAIN}"
            iptables -t nat -D PREROUTING -p udp --dport "$HY_RANGE" -j REDIRECT --to-ports "$HY_PORT" 2>/dev/null || true
            if command -v ip6tables &>/dev/null; then
                ip6tables -t nat -D PREROUTING -p udp --dport "$HY_RANGE" -j REDIRECT --to-ports "$HY_PORT" 2>/dev/null || true
            fi
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save >/dev/null 2>&1 || true
            fi
        fi
        local port=${SUB_PORT:-8444}
        local host=${TARGET_HOST:-${HY_DOMAIN:-$SERVER_IP}}
        rm -f "/etc/caddy/sites/${host}-${port}.caddy" "/etc/caddy/sites/simple-box.caddy"
        systemctl reload caddy 2>/dev/null || true
    fi

    rm -f /usr/local/bin/sing-box
    rm -f /usr/local/bin/simbo
    rm -rf "$CONF_DIR"

    echo -e "${GREEN}sing-box 与订阅配置已彻底干净卸载！${PLAIN}"
}

# 交互控制台主循环
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
        [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" && sub_port=${SUB_PORT:-8444}
        if command -v caddy &>/dev/null && systemctl is-active --quiet caddy; then
            caddy_status="${GREEN}运行中 (端口: ${sub_port})${PLAIN}"
        fi

        # 3. 打印系统面板
        echo -e " 操作系统: ${CYAN}${os_name} (${arch})${PLAIN}"
        local domain_display="未配置"
        if [[ -f "$ENV_FILE" ]]; then
            source "$ENV_FILE"
            if [[ -n "$HY_DOMAIN" && "$HY_DOMAIN" != "skip" ]]; then
                domain_display="${HY_DOMAIN}"
            elif [[ "$HY_SKIP_CERT" == "true" ]]; then
                domain_display="IP自签证书"
            fi
        fi
        echo -e " 公网 IP : ${CYAN}${cur_ip}${PLAIN} | 绑定域名: ${CYAN}${domain_display}${PLAIN}"
        echo -e " TCP 加速: ${bbr_status}"
        echo -e " Sing-box: ${sb_status}"
        echo -e " Caddy订阅: ${caddy_status}"
        
        if [[ -f "$ENV_FILE" ]]; then
            local p_hy="未启用"
            if [ "${HY_ENABLED:-true}" = true ]; then
                p_hy="UDP ${HY_PORT:-8443} [跳跃: ${HY_RANGE:-20000:40000}]"
            fi
            echo -e " 当前节点: ${BLUE}Reality: TCP ${VL_PORT:-443} | Hy2: ${p_hy}${PLAIN}"
        fi

        echo -e "${GREEN}----------------------------------------------------${PLAIN}"
        echo -e " 1. 安装 / 重置配置 (VLESS-Reality + Hysteria2 + Caddy)"
        echo -e " 2. 查看在线订阅链接与节点 YAML"
        echo -e " 3. 查看单独节点链接 (vless:// / hy2://) 与二维码"
        echo -e " 4. 检查并升级 sing-box 官方最新内核"
        echo -e " 5. TCP BBR 拥塞控制管理 (开启 / 关闭)"
        echo -e " 6. 重启服务 (sing-box 与 Caddy)"
        echo -e " 7. 查看 sing-box 运行日志"
        echo -e " 8. 彻底干净卸载"
        echo -e " 0. 退出管理控制台"
        echo -e "${GREEN}====================================================${PLAIN}"
        
        read -p "请输入选项 [0-8]: " opt
        case "$opt" in
            1) install_node ;;
            2) show_subscription ;;
            3) show_links ;;
            4) update_singbox_core ;;
            5) manage_bbr ;;
            6) 
                systemctl restart sing-box && systemctl restart caddy 2>/dev/null || true
                echo -e "${GREEN}服务已重启！${PLAIN}"
                ;;
            7) journalctl -u sing-box -o cat -e -f ;;
            8) uninstall_all ;;
            0) echo -e "${GREEN}已退出。随时输入 simbo 即可重新打开面板。${PLAIN}"; exit 0 ;;
            *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
        echo ""
        read -p "按回车键返回主菜单..." dummy
    done
}

case "$1" in
    install) install_node ;;
    update) 
        if [[ "$2" == "force" || "$2" == "-f" ]]; then
            update_singbox_core "force"
        else
            update_singbox_core
        fi
        ;;
    yaml|sub) show_subscription ;;
    link|url|qr) show_links ;;
    bbr) manage_bbr ;;
    del|uninstall) uninstall_all ;;
    *) menu ;;
esac
