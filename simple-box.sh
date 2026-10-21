#!/usr/bin/env bash
# ==============================================================================
# Simple-Box Manager - 极简、安全、透明的自用 Sing-box 管理脚本
# 协议支持: 
#   1. VLESS-TCP-Reality-Vision (日常主力直连)
#   2. Hysteria 2 (晚高峰弱网/UDP端口跳跃, 基于 Cloudflare 证书)
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
ENV_FILE="${CONF_DIR}/env.conf"
YAML_FILE="${CONF_DIR}/clash_meta_provider.yaml"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本！${PLAIN}" && exit 1

# 架构判定
get_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) echo -e "${RED}不支持的系统架构: $arch${PLAIN}"; exit 1 ;;
    esac
}

# 基础依赖检查与安装 (最小化，不影响系统现有防火墙策略)
install_deps() {
    local missing=()
    for cmd in curl tar jq openssl ufw; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${BLUE}安装必要基础组件: ${missing[*]}...${PLAIN}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq "${missing[@]}" iptables-persistent socat
        elif command -v yum &>/dev/null; then
            yum install -y epel-release && yum install -y "${missing[@]}" socat
        fi
    fi
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

# 配置 Cloudflare ACME 证书
issue_cf_cert() {
    local domain="$1"
    local cf_token="$2"

    echo -e "${BLUE}配置 acme.sh 并使用 Cloudflare DNS API 申请证书...${PLAIN}"
    mkdir -p "$CERT_DIR"
    
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        curl -sSL https://get.acme.sh | sh -s email="admin@${domain}"
    fi

    export CF_Token="$cf_token"
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
    "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$domain" -d "*.${domain}" --keylength ec-256 --force

    "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" --ecc \
        --fullchain-file "${CERT_DIR}/fullchain.cer" \
        --key-file "${CERT_DIR}/private.key" \
        --reloadcmd "systemctl reload sing-box 2>/dev/null || true"

    if [[ -f "${CERT_DIR}/fullchain.cer" && -f "${CERT_DIR}/private.key" ]]; then
        echo -e "${GREEN}证书已成功签发并安装至 ${CERT_DIR}！${PLAIN}"
    else
        echo -e "${RED}证书签发失败，请检查 CF Token 权限与域名托管状态！${PLAIN}"
        exit 1
    fi
}

# 端口跳跃 iptables 规则配置 (精准增量设置，不破坏原有规则)
setup_port_hopping() {
    local hy_port="$1"
    local range="$2" # e.g. 20000:40000

    echo -e "${BLUE}配置 Hysteria 2 端口跳跃 (UDP ${range} -> ${hy_port})...${PLAIN}"
    iptables -t nat -D PREROUTING -p udp --dport "$range" -j REDIRECT --to-ports "$hy_port" 2>/dev/null || true
    iptables -t nat -A PREROUTING -p udp --dport "$range" -j REDIRECT --to-ports "$hy_port"
    if command -v ip6tables &>/dev/null; then
        ip6tables -t nat -D PREROUTING -p udp --dport "$range" -j REDIRECT --to-ports "$hy_port" 2>/dev/null || true
        ip6tables -t nat -A PREROUTING -p udp --dport "$range" -j REDIRECT --to-ports "$hy_port" 2>/dev/null || true
    fi

    # 保存 iptables 规则
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi

    # 精准开放防火墙 (UFW 友好模式)
    if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
        ufw allow "$hy_port/udp" >/dev/null 2>&1 || true
        ufw allow "${range/:/-}/udp" >/dev/null 2>&1 || true
    fi
}

# 部署与配置主函数
install_node() {
    install_deps
    [[ ! -f /usr/local/bin/sing-box ]] && update_singbox_core

    mkdir -p "$CONF_DIR"

    # 读取公网 IP
    local server_ip=$(curl -s4m5 https://icanhazip.com || curl -s4m5 https://api.ipify.org || echo "YOUR_SERVER_IP")

    echo -e "\n${YELLOW}=== 1. 配置 VLESS-Reality 参数 ===${PLAIN}"
    if [[ -z "$VL_PORT" ]]; then
        read -p "请输入 Reality 监听端口 [默认 443]: " vl_port
    fi
    vl_port=${vl_port:-${VL_PORT:-443}}

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

    if [[ -z "$HY_PORT" ]]; then
        read -p "请输入 Hysteria 2 主监听 UDP 端口 [默认 8443]: " hy_port
    fi
    hy_port=${hy_port:-${HY_PORT:-8443}}

    if [[ -z "$HY_RANGE" ]]; then
        read -p "请输入端口跳跃范围 [默认 20000:40000]: " hy_range
    fi
    hy_range=${hy_range:-${HY_RANGE:-20000:40000}}

    if [[ -z "$NODE_PREFIX" ]]; then
        read -p "请输入节点名称前缀 (如 HK / US / Oracle-O1) [默认 Node]: " node_prefix
    fi
    node_prefix=${node_prefix:-${NODE_PREFIX:-Node}}

    # 签发证书
    issue_cf_cert "$hy_domain" "$cf_token"

    # 生成密钥对与 UUID
    echo -e "${BLUE}生成安全密钥凭证...${PLAIN}"
    local key_pair=$(/usr/local/bin/sing-box generate reality-keypair)
    local vl_privkey=$(echo "$key_pair" | awk '/PrivateKey/{print $2}')
    local vl_pubkey=$(echo "$key_pair" | awk '/PublicKey/{print $2}')
    local vl_shortid=$(/usr/local/bin/sing-box generate rand 8 --hex)
    local user_uuid=$(/usr/local/bin/sing-box generate uuid)
    local hy_password=$(/usr/local/bin/sing-box generate rand 16 --base64 | tr -dc 'a-zA-Z0-9' | head -c 16)

    # 精准放行防火墙端口 (绝对不全局清空)
    if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
        ufw allow "$vl_port/tcp" >/dev/null 2>&1 || true
        ufw allow "$hy_port/udp" >/dev/null 2>&1 || true
    fi
    setup_port_hopping "$hy_port" "$hy_range"

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

    # 保存环境变量备忘 (便于查看与卸载)
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

    # 生成 Clash.Meta (Mihomo) 的 Provider 片段
    local hy_ports_display="${hy_port},${hy_range/:/-}"
    cat > "$YAML_FILE" <<EOF
# ==============================================================================
# 复制以下内容直接粘贴至你的 Clash.Meta / Mihomo 配置文件中的 proxies: 列表下
# 或作为独立的 proxy-providers 文件引入
# ==============================================================================
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
    server: ${hy_domain}
    port: ${hy_port}
    ports: "${hy_ports_display}"
    password: "${hy_password}"
    sni: ${hy_domain}
    skip-cert-verify: false
EOF

    show_yaml
}

# 输出与查看配置
show_yaml() {
    if [[ -f "$YAML_FILE" ]]; then
        echo -e "\n${GREEN}================== ClashX.Meta (Mihomo) 节点配置 ==================${PLAIN}"
        cat "$YAML_FILE"
        echo -e "${GREEN}===================================================================${PLAIN}"
        echo -e "配置文件已保存在: ${YELLOW}${YAML_FILE}${PLAIN}\n"
    else
        echo -e "${RED}未找到已生成的配置文件！${PLAIN}"
    fi
}

# 彻底干净卸载
uninstall_all() {
    echo -e "${YELLOW}警告: 即将彻底卸载 sing-box 并清除所有节点与证书配置！${PLAIN}"
    read -p "确认卸载吗？(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "已取消。" && return 0

    echo -e "${BLUE}正在停止并移除服务...${PLAIN}"
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload

    # 读取旧环境变量精准撤销端口跳跃规则与防火墙
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
    fi

    # 清除文件
    rm -f /usr/local/bin/sing-box
    rm -rf "$CONF_DIR"

    echo -e "${GREEN}sing-box 已彻底干净卸载，系统未残留任何无用规则与配置！${PLAIN}"
}

# 交互菜单
menu() {
    clear
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e "${GREEN}        Simple-Box Manager - 极简安全 Sing-box 控制台     ${PLAIN}"
    echo -e "${GREEN}====================================================${PLAIN}"
    echo -e " 1. 安装 / 重置配置 (VLESS-Reality + Hysteria2)"
    echo -e " 2. 查看当前节点的 Clash.Meta YAML 配置"
    echo -e " 3. 检查并升级 sing-box 官方最新内核"
    echo -e " 4. 重启 sing-box 服务"
    echo -e " 5. 查看运行日志"
    echo -e " 6. 彻底干净卸载"
    echo -e " 0. 退出"
    echo -e "${GREEN}====================================================${PLAIN}"
    
    local status="未安装"
    if [[ -f /usr/local/bin/sing-box ]]; then
        if systemctl is-active --quiet sing-box; then
            status="${GREEN}运行中${PLAIN}"
        else
            status="${RED}未运行${PLAIN}"
        fi
    fi
    echo -e "服务状态: ${status}"
    echo ""
    read -p "请输入选项 [0-6]: " opt
    case "$opt" in
        1) install_node ;;
        2) show_yaml ;;
        3) update_singbox_core ;;
        4) systemctl restart sing-box && echo -e "${GREEN}已重启！${PLAIN}" ;;
        5) journalctl -u sing-box -o cat -e -f ;;
        6) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项！${PLAIN}" ;;
    esac
}

# 支持命令行参数快速调用
case "$1" in
    install) install_node ;;
    update) update_singbox_core ;;
    yaml) show_yaml ;;
    del|uninstall) uninstall_all ;;
    *) menu ;;
esac
