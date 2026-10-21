#!/usr/bin/env bash
# ==============================================================================
# Simple-Box Manager - 极简、安全、透明的自用 Sing-box 服务端管理脚本
# 协议支持: 
#   1. VLESS-TCP-Reality-Vision (日常主力直连)
#   2. Hysteria 2 (晚高峰弱网/UDP端口跳跃, 基于 Cloudflare 证书)
# 订阅分发:
#   集成 Caddy HTTPS 安全分发，输出完整规则模板订阅与纯节点订阅，附带 URI 与二维码
# ==============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
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
    local proto="$2" # tcp 或 udp
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

# 获取并升级官方最新 sing-box 内核
update_singbox_core() {
    echo -e "${BLUE}检查 sing-box 官方最新版本...${PLAIN}"
    local tag=$(curl -sSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep -Po '"tag_name": "\K[^"]*')
    [[ -z "$tag" ]] && echo -e "${RED}获取最新版本失败，请检查网络！${PLAIN}" && return 1
    local version=${tag#v}
    local arch=$(get_arch)

    echo -e "发现最新版本: ${GREEN}${tag}${PLAIN} (${arch})"
    local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${version}-linux-${arch}.tar.gz"
    local tmp_dir=$(mktemp -d)
    
    echo -e "${BLUE}正在下载并安装...${PLAIN}"
    curl -sSL "$url" | tar -xz -C "$tmp_dir" --strip-components=1
    if [[ -f "$tmp_dir/sing-box" ]]; then
        install -m 755 "$tmp_dir/sing-box" /usr/local/bin/sing-box
        rm -rf "$tmp_dir"
        echo -e "${GREEN}sing-box 内核已就绪: $(/usr/local/bin/sing-box version | head -n1)${PLAIN}"
        if systemctl is-active --quiet sing-box; then
            systemctl restart sing-box
            echo -e "${GREEN}sing-box 服务已自动重启！${PLAIN}"
        fi
    else
        echo -e "${RED}安装失败！${PLAIN}"
        rm -rf "$tmp_dir"
        return 1
    fi
}

# Cloudflare DNS 证书管理
issue_cf_cert() {
    local domain="$1"
    local cf_token="$2"
    local acme_bin="$HOME/.acme.sh/acme.sh"

    echo -e "${BLUE}配置 acme.sh 证书环境...${PLAIN}"
    mkdir -p "$CERT_DIR"
    
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

    chmod 755 "$CONF_DIR" "$CERT_DIR" 2>/dev/null || true
    chmod 644 "${CERT_DIR}"/* 2>/dev/null || true

    if [[ -f "${CERT_DIR}/fullchain.cer" && -f "${CERT_DIR}/private.key" ]]; then
        echo -e "${GREEN}证书已成功部署至 ${CERT_DIR}！${PLAIN}"
    else
        echo -e "${RED}证书部署失败，请检查配置！${PLAIN}"
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
    local domain="$1"
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

    rm -f "/etc/caddy/sites/${domain}-${sub_port}.caddy" "/etc/caddy/sites/simple-box.caddy"

    cat > "/etc/caddy/sites/${domain}-${sub_port}.caddy" <<EOF
# Simple-Box HTTPS 订阅分发站点
${domain}:${sub_port} {
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
    local domain="$1"
    local token="$2"
    local node_prefix="$3"
    local server_ip="$4"
    local vl_port="$5"
    local user_uuid="$6"
    local vl_sni="$7"
    local vl_pubkey="$8"
    local vl_shortid="$9"
    local hy_port="${10}"
    local hy_ports_display="${11}"
    local hy_password="${12}"

    mkdir -p "${WEB_DIR}/sub_${token}"

    if [ ! -f "$TEMPLATE_FILE" ]; then
        curl -fsSL https://raw.githubusercontent.com/comegome/simple-box/main/template.yaml -o "$TEMPLATE_FILE" 2>/dev/null || true
    fi

    # 1. 组装完整配置 (模板 + proxies + proxy-groups)
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

  - name: "${node_prefix}-Hysteria2"
    type: hysteria2
    server: ${domain}
    port: ${hy_port}
    ports: "${hy_ports_display}"
    password: "${hy_password}"
    sni: ${domain}
    skip-cert-verify: false

proxy-groups:
  - name: "📌节点选择"
    type: select
    proxies:
      - "${node_prefix}-VLESS-Reality"
      - "${node_prefix}-Hysteria2"
      - "DIRECT"
EOF

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

  - name: "${node_prefix}-Hysteria2"
    type: hysteria2
    server: ${domain}
    port: ${hy_port}
    ports: "${hy_ports_display}"
    password: "${hy_password}"
    sni: ${domain}
    skip-cert-verify: false
EOF
    cp -f "$provider_file" "$YAML_PROVIDER"

    # 3. 组装原生分享链接
    local vless_link="vless://${user_uuid}@${server_ip}:${vl_port}?security=reality&encryption=none&pbk=${vl_pubkey}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${vl_sni}&sid=${vl_shortid}#${node_prefix}-VLESS-Reality"
    local hy2_link="hysteria2://${hy_password}@${domain}:${hy_port}/?sni=${domain}&insecure=0&mport=${hy_ports_display}#${node_prefix}-Hysteria2"
    
    local links_out="${WEB_DIR}/sub_${token}/links.txt"
    cat > "$links_out" <<EOF
${vless_link}
${hy2_link}
EOF
    cp -f "$links_out" "$LINKS_FILE"
}

# 部署与配置主函数
install_node() {
    install_deps
    [[ ! -f /usr/local/bin/sing-box ]] && update_singbox_core

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
    if [[ -z "$HY_DOMAIN" ]]; then
        read -p "请输入你的自有域名 (已在 Cloudflare 托管且解析到此 IP): " hy_domain
    fi
    hy_domain=${hy_domain:-$HY_DOMAIN}
    [[ -z "$hy_domain" ]] && echo -e "${RED}域名不能为空！${PLAIN}" && exit 1

    if [[ -z "$CF_TOKEN" ]]; then
        read -p "请输入 Cloudflare API Token (需拥有 Zone.DNS 编辑权限): " cf_token
    fi
    cf_token=${cf_token:-$CF_TOKEN}
    [[ -z "$cf_token" ]] && echo -e "${RED}CF Token 不能为空！${PLAIN}" && exit 1

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
        read -p "请输入节点名称前缀 (如 HK / US / Oracle-O1) [默认 Node]: " node_prefix
    fi
    node_prefix=${node_prefix:-${NODE_PREFIX:-Node}}

    # 签发证书
    issue_cf_cert "$hy_domain" "$cf_token"

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
        ufw allow "$hy_port/udp" >/dev/null 2>&1 || true
    fi
    setup_port_hopping "$hy_port" "$hy_range"

    # 生成服务端配置文件
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
    },
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
HY_DOMAIN="${hy_domain}"
HY_PORT="${hy_port}"
HY_RANGE="${hy_range}"
HY_PASS="${hy_password}"
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

    # 创建全局快捷指令
    install -m 755 "$0" /usr/local/bin/simbo 2>/dev/null || cp -f "$0" /usr/local/bin/simbo

    # 部署 Caddy 订阅并组装完整客户端配置
    local hy_ports_display="${hy_port},${hy_range/:/-}"
    generate_full_client_config "$hy_domain" "$sub_token" "$node_prefix" "$server_ip" "$vl_port" "$user_uuid" "$vl_sni" "$vl_pubkey" "$vl_shortid" "$hy_port" "$hy_ports_display" "$hy_password"
    setup_caddy_subscription "$hy_domain" "$sub_token" "$sub_port"

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
    local sub_url="https://${HY_DOMAIN}:${port}/sub_${SUB_TOKEN}/config.yaml"
    local provider_url="https://${HY_DOMAIN}:${port}/sub_${SUB_TOKEN}/provider.yaml"

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
            local vless_link="vless://${VL_UUID}@${SERVER_IP}:${VL_PORT}?security=reality&encryption=none&pbk=${VL_PUBKEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${VL_SNI}&sid=${VL_SHORTID}#${NODE_PREFIX}-VLESS-Reality"
            local hy2_link="hysteria2://${HY_PASS}@${HY_DOMAIN}:${HY_PORT}/?sni=${HY_DOMAIN}&insecure=0&mport=${hy_ports_display}#${NODE_PREFIX}-Hysteria2"
            echo -e "${vless_link}\n${hy2_link}" > "$LINKS_FILE"
        else
            echo -e "${RED}未找到节点环境配置，请先执行安装！${PLAIN}"
            return 1
        fi
    fi
    local vless_url=$(head -n 1 "$LINKS_FILE")
    local hy2_url=$(tail -n 1 "$LINKS_FILE")

    echo -e "\n${GREEN}====================== 节点原生分享链接 ======================${PLAIN}"
    echo -e "${YELLOW}[1] VLESS-Reality 链接:${PLAIN}"
    echo -e "${GREEN}${vless_url}${PLAIN}"
    if command -v qrencode &>/dev/null; then
        echo -e "\n${YELLOW}[VLESS-Reality 二维码]:${PLAIN}"
        qrencode -t ANSIUTF8 "${vless_url}"
    fi

    echo -e "\n--------------------------------------------------------------"
    echo -e "${YELLOW}[2] Hysteria 2 链接:${PLAIN}"
    echo -e "${GREEN}${hy2_url}${PLAIN}"
    if command -v qrencode &>/dev/null; then
        echo -e "\n${YELLOW}[Hysteria 2 二维码]:${PLAIN}"
        qrencode -t ANSIUTF8 "${hy2_url}"
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
        rm -f "/etc/caddy/sites/${HY_DOMAIN}-${port}.caddy" "/etc/caddy/sites/simple-box.caddy"
        systemctl reload caddy 2>/dev/null || true
    fi

    rm -f /usr/local/bin/sing-box
    rm -rf "$CONF_DIR"

    echo -e "${GREEN}sing-box 与订阅配置已彻底干净卸载！${PLAIN}"
}

# 交互菜单
menu() {
    clear
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e "${GREEN}        Simple-Box Manager - 极简安全控制台        ${PLAIN}"
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e " 1. 安装 / 重置配置 (VLESS-Reality + Hysteria2 + Caddy)"
    echo -e " 2. 查看在线订阅链接与节点 YAML"
    echo -e " 3. 查看单独节点链接 (vless:// / hy2://) 与二维码"
    echo -e " 4. 检查并升级 sing-box 官方最新内核"
    echo -e " 5. 重启服务 (sing-box 与 Caddy)"
    echo -e " 6. 查看 sing-box 运行日志"
    echo -e " 7. 彻底干净卸载"
    echo -e " 0. 退出"
    echo -e "${GREEN}====================================================${PLAIN}"
    
    local sb_status="未安装"
    if [[ -f /usr/local/bin/sing-box ]]; then
        if systemctl is-active --quiet sing-box; then
            sb_status="${GREEN}运行中${PLAIN}"
        else
            sb_status="${RED}未运行${PLAIN}"
        fi
    fi
    local caddy_status="未安装"
    if command -v caddy &>/dev/null; then
        if systemctl is-active --quiet caddy; then
            caddy_status="${GREEN}运行中${PLAIN}"
        else
            caddy_status="${RED}未运行${PLAIN}"
        fi
    fi
    echo -e "Sing-box 状态: ${sb_status} | Caddy 订阅状态: ${caddy_status}\n"
    read -p "请输入选项 [0-7]: " opt
    case "$opt" in
        1) install_node ;;
        2) show_subscription ;;
        3) show_links ;;
        4) update_singbox_core ;;
        5) 
            systemctl restart sing-box && systemctl restart caddy 2>/dev/null || true
            echo -e "${GREEN}服务已重启！${PLAIN}"
            ;;
        6) journalctl -u sing-box -o cat -e -f ;;
        7) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项！${PLAIN}" ;;
    esac
}

case "$1" in
    install) install_node ;;
    update) update_singbox_core ;;
    yaml|sub) show_subscription ;;
    link|url|qr) show_links ;;
    del|uninstall) uninstall_all ;;
    *) menu ;;
esac
