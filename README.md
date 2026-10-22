# Simple-Box

专为追求系统整洁、网络安全与纯净架构的个人 VPS 用户设计。避免防火墙滥开、内置未知二进制、明文 HTTP 暴露与多核心混合部署等隐患，全代码标准 Bash，透明可审计。

---

### 🖥️ 运行环境

* 系统：支持 Ubuntu 24.04+ 或 Debian 12+（官方仓库内置 Caddy，无需任何第三方源）
* 硬件：支持 x86_64 (amd64) 或 aarch64 (arm64)，内存 $\ge$ 256MB
* 网络：具备公网 IPv4 地址（双栈 VPS 仅在 IPv4 上提供服务；不支持纯 IPv6 VPS）

---

### 🚀 一键安装

以 root 权限运行以下命令：

```bash
curl -fsSL https://raw.githubusercontent.com/comegome/Simple-Box/main/simple-box.sh -o /tmp/simple-box.sh && sudo bash /tmp/simple-box.sh
```

---

### ⌨️ 快捷指令

安装成功后，随时在终端任意目录下输入 `simbo` 即可打开控制台：

```bash
simbo
```

---

### 🛠️ 核心特性

* 支持 VLESS-Reality / Hysteria 2 双协议节点
* 使用 sing-box 单内核驱动，支持内核在线升级
* 使用纯 IPv4 架构设计，兼容双栈 VPS 安装
* 自适应开启 TCP BBR 加速（不破坏系统原有配置）
* 支持 IP 自签或 Cloudflare 托管域名（证书通过 Caddy 自动申请与续期）
* 提供 Clash / Mihomo 托管配置与纯节点列表
* 支持自定义所有节点的统一名称前缀
* 支持独立修改重置单个协议节点的配置
* 支持修改重置订阅地址的链接（旧链接立即作废）

---

### 📖 详细指南

<details>
<summary>📖 Cloudflare 域名解析与 API Token 申请指南（点击展开）</summary>

#### 步骤 1：在 Cloudflare 添加 A 记录
1. 登录 [Cloudflare 控制台](https://dash.cloudflare.com/)，进入你的域名；
2. 左侧菜单 DNS → 记录 (Records) → 添加记录 (Add record)；
3. 填写：
   * 类型 (Type)：`A`
   * 名称 (Name)：二级前缀（例如 `node`、`o2`，根域用 `@`）
   * IPv4 地址：这台 VPS 的公网 IPv4
   * 代理状态 (Proxy status)：必须为“仅限 DNS”（灰色云朵）。开启小黄云 CDN 会阻断 UDP，Hysteria 2 将完全无法连接。
4. 点击保存 (Save)。

#### 步骤 2：生成专属 API Token
1. Cloudflare 右上角头像 → 配置文件 (Profile)；
2. 左侧 API 令牌 (API Tokens) → 创建令牌 (Create Token)；
3. 找到模板“编辑区域 DNS (Edit zone DNS)”，点击“使用模板 (Use template)”；
4. 配置：
   * 令牌名称：任意（如 `simple-box-cert`）
   * 区域资源 (Zone Resources)：包括 (Include) → 特定区域 (Specific zone) → 选中目标域名
   * 其余保持默认
5. 底部点击“继续以显示摘要” → 创建令牌；
6. 复制生成的 Token（仅展示一次，妥善保存）。

#### 步骤 3：在 VPS 终端填入
运行 `simbo` 进行安装或在 Hysteria 2 模块输入域名后，按提示粘贴 Token。脚本会自动在线校验有效性并签发 ECC 证书。
</details>

<details>
<summary>🖥️ 控制台菜单与常用配置项速查表（点击展开）</summary>

#### 控制台主界面看板预览

```text
====================================================
            Simple-Box Manager - 控制台            
====================================================
 操作系统: Ubuntu 24.04.5 LTS (amd64)
 公网地址: 203.0.113.10
 TLS 证书: 自签 IP 证书
 TCP 加速: BBR
 证书管理: 运行中 (Caddy v2.6.2)
 代理服务: 运行中 (sing-box v1.14.3)
 VLESS-Reality | TCP:443 | ServerName: gateway.icloud.com
 Hysteria 2 | UDP:8443 | SNI: 203.0.113.10 | Ports: 20000:40000
----------------------------------------------------
 Clash 订阅配置: http://203.0.113.10:8444/2dac50852729bf55bb61833d/config.yaml
 Clash 节点列表: http://203.0.113.10:8444/2dac50852729bf55bb61833d/provider.yaml
 (无域名证书加密，建议在可信网络下更新)
----------------------------------------------------
 1. vless / hy2 原生链接查看
 2. VLESS-Reality 模块配置
 3. Hysteria 2 模块配置
 4. Clash 订阅地址配置
 5. 内核管理
 6. 脚本升级 / 重装
 7. 脚本卸载
 0. 退出控制台
====================================================
```

#### 安装流程关键输入项

| 配置项 | 默认值 | 行为说明 |
| :--- | :--- | :--- |
| Reality 监听端口 | `443` | 1-65535，被外部占用会提示更换；与 Nginx 共存时可改为其他端口 |
| Reality 伪装域名 | `gateway.icloud.com` | 需支持 TLS 1.3 的大厂 SNI 站点，禁止填本机 IP |
| Hysteria 2 域名 | 自动检测旧域名 | 检测到旧域名可一键回车沿用；没有域名直接回车 = IP 自签（自动直连） |
| Cloudflare Token | — | 仅配置域名且无本地有效证书时需要，留空自动降级为自签 |
| Hy2 主监听端口 | `8443` | UDP 端口，与 Reality 端口互斥 |
| 端口跳跃范围 | `20000:40000` | 格式 `起:止`；输入 `none` 关闭端口跳跃 |
| Caddy 订阅端口 | `8444` | TCP 端口，独立托管订阅地址，不抢占 80 端口 |
| 节点名称前缀 | `Node` | 节点显示前缀，自动过滤特殊字符 |
</details>

<details>
<summary>❓ 常见问题解答 (FAQ)（点击展开）</summary>

#### Q1：没有域名可以使用吗？
完全可以。安装时遇到域名输入直接回车，即自动生成 10 年期 IP ECC 自签证书。客户端配置会自动注入 `skip-cert-verify: true`，网络连接质量、加密强度与正规域名证书完全一致。

#### Q2：为什么自签模式下订阅地址是 HTTP？安全吗？
这是为兼容主流客户端的必要设计：
1. 防导入阻断：主流客户端（Clash Verge、ClashX.Meta、Shadowrocket 等）拉取订阅时，底层 TLS 堆栈会严格阻断不受信任的自签证书导致无法导入；若用自签 HTTPS，用户必须手动将自签 CA 安装到系统受信任列表，极其繁琐。
2. 安全性保障：自签模式采用 HTTP 配合 24 位高强度随机 Token 路径隔离（例如 `http://<IP>:8444/<24位随机Token>/config.yaml`），全网扫描无法遍历订阅路径。建议在受信任网络下拉取；绑定域名后会自动升级为标准 HTTPS。

#### Q3：机器上已有 Nginx 或其他 Web 站点，会有冲突吗？
互不影响，只需注意端口规划：
1. 80 端口零占用：Simple-Box 的 Caddy 专用于 8444 端口提供订阅地址，不监听 80 端口，80 端口完整留给既有 Web 服务。
2. 证书申请零冲突：域名证书仅走 Cloudflare DNS-01 API 验证，不走 HTTP-01，不需要占用 80 端口，与 Certbot 或 Web 服务器证书续签互不干扰。
3. 443 端口规划：
   - 若 443 端口已被 Nginx 占用，安装 Simple-Box 时将 Reality 端口设为其他端口（如 `20443`、`34443`）即可。
   - 若 Simple-Box 先占用了 443 端口，后续可通过 `simbo` 控制台选项 2 随时将 Reality 改为其他端口。

#### Q4：如果以后在同一台机器上用 Caddy 部署个人网站，卸载 Simple-Box 会受影响吗？
完全不会。Simple-Box 卸载时会自动扫描 `/etc/caddy/sites` 目录：
- 若检测到用户自建的其它站点配置，脚本会自动保留 Caddy 软件包、主 Caddyfile 及 `import sites/*.caddy` 引入行，仅安全移除本脚本的订阅配置并优雅重载，个人站点全程正常运行。
- 仅当 Caddy 是由本脚本全新安装且无任何外部站点时，才会彻底 purge 卸载软件包与配置。

#### Q5：域名证书申请失败，或者域名不在 Cloudflare 怎么办？
- 若申请失败或网络超时，脚本会自动降级为 10 年 IP 自签证书完成安装，保证节点立即可用；排查 CF Token 权限后，在 `simbo` 选项 3（Hysteria 2 模块配置）中随时可重新配置升级为域名证书。
- 域名证书仅支持 Cloudflare DNS-01 API。若域名在其他注册商，推荐直接使用 IP 自签模式，或将域名 NS 免费托管至 Cloudflare。

#### Q6：能用 IPv6 连接节点吗？
不能。Simple-Box 坚持纯 IPv4 极简架构，服务显式绑定 `0.0.0.0`，不接管也不配置双栈路由与 ip6tables 规则。若 VPS 仅有 IPv6 地址，请勿使用本脚本。

#### Q7：为什么仅支持 Ubuntu 24.04+ 和 Debian 12+？
这两个主流发行版的官方系统仓库已内置 Caddy（v2.6.2+），无需引入任何第三方软件源、第三方 GPG Keyring 或编译环境，即可实现极简、稳定、无外部网络依赖的自闭环安装与运行。
</details>

<details>
<summary>🧪 安装后状态自检命令（点击展开）</summary>

```bash
systemctl status sing-box caddy --no-pager        # 检查服务运行状态
sing-box check -c /etc/sing-box/config.json       # 校验 sing-box 配置完整性
ss -tlnp | grep -E ':(443|8444)'                  # 检查 Reality 与 Caddy 订阅端口
ss -ulnp | grep 8443                              # 检查 Hysteria 2 UDP 端口
iptables -t nat -L PREROUTING -n --line-numbers   # 检查端口跳跃 REDIRECT 规则
```
</details>

---

### 📄 开源许可证

本项目采用 [MIT 许可证](LICENSE)。

修改脚本前建议先读 [MAINTAINING.md](MAINTAINING.md)，里面记着改权限、改菜单编号、写系统配置时容易踩的坑。
