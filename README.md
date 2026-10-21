# Simple-Box

> 极简、安全、透明的自用 sing-box 服务端一键管理脚本。

专为追求**系统整洁、网络安全与纯净架构**的个人 VPS 用户设计。摒弃开源一键脚本中常见的防火墙滥开、内置未知二进制、明文 HTTP 暴露与多核心混部等隐患，全代码标准 Bash，透明可审计。

---

## 🖥️ 硬性适用范围

在开始前，请确认你的 VPS 与网络符合以下硬性边界：

| 维度 | 支持范围 | 说明 |
| :--- | :--- | :--- |
| **网络协议栈** | **仅 IPv4** | sing-box 与 Caddy 均绑定 `0.0.0.0`，**不支持 IPv6**。 |
| **TLS 证书来源** | **仅 Cloudflare DNS API** 或 **IP 自签证书** | 域名证书仅走 Cloudflare DNS-01 API（不占 80 端口）；无域名直接回车生成 10 年 IP ECC 证书。 |
| **系统架构与内存** | **x86_64 / aarch64**，内存 $\ge$ 256MB | 支持 Ubuntu 20.04+、Debian 11+、CentOS/Rocky 8+、Alpine 3.16+。 |

---

## 🚀 一键安装与管理

在任意满足要求的 VPS 上以 `root` 权限运行：

### 官方直链（海外 VPS 推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/comegome/simple-box/main/simple-box.sh -o /tmp/simple-box.sh && sudo bash /tmp/simple-box.sh
```

### CDN 加速直链（国内机器 / 抗 DNS 污染）

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/comegome/simple-box@main/simple-box.sh -o /tmp/simple-box.sh && sudo bash /tmp/simple-box.sh
```

> 💡 **为什么必须“先下载成文件再运行”？**
> `sudo bash <(...)` 会因 `sudo` 默认关闭子进程文件描述符而报错 `/dev/fd/63: No such file or directory`；
> `curl ... | sudo bash` 管道执行时，交互输入会与脚本正文争抢 stdin 导致提问错乱。
> 唯有“先下载再运行”兼顾交互稳定与可审计性。
>
> 🤖 **无人值守模式（全默认值、无交互直接安装）：**
> ```bash
> curl -fsSL https://raw.githubusercontent.com/comegome/simple-box/main/simple-box.sh -o /tmp/simple-box.sh && sudo bash /tmp/simple-box.sh install
> ```

---

## ⌨️ 全局快捷指令

安装成功后，随时在终端任意目录下输入 **`simbo`** 即可打开管理控制台：

```bash
simbo
```

---

## 🛠️ 核心功能特性

* **单内核纯净运行**：直接拉取官方 `SagerNet/sing-box` Release，无任何外置闭源二进制，常驻约 45 MB。
* **双主力协议矩阵**：
  * **VLESS-TCP-Reality-Vision**：日常主力，伪装大厂 SNI，低延迟、免证书维护。
  * **Hysteria 2**：弱网冲刺，UDP/QUIC 单边加速，支持端口跳跃（Port Hopping）抵御 QoS。
* **证书智能自适应**：
  * **自动检测本地域名**：重新配置时自动检测既有域名，回车一键沿用（未过期证书自动免输 Token 复用）；
  * **IP 自签证书**：无域名直接回车，签发 10 年 ECC 证书，客户端自动注入 `skip-cert-verify: true`；
  * **域名模式**：Cloudflare DNS-01 API 签发正规 CA 证书，自动续期。
* **Caddy 订阅安全分发**：
  * **智能协议切换**：域名模式开启 HTTPS 绿锁；IP 模式自动降级为 HTTP 分发，彻底解决 ClashX.Meta 等客户端因阻断自签证书无法导入的问题；
  * **订阅防死锁**：客户端配置顶层注入精准直连规则，节点失效也能正常刷新拉取订阅；
  * **Web 隔离与零冲突**：Caddy 订阅仅监听专用端口（默认 8444），不占用 80 端口，与既有 Nginx 互不抢占。
* **极简管理与彻底卸载**：TCP BBR 加速独立管控；卸载时彻底移除 sing-box、订阅服务与网络规则，无隐藏残留。

---

## 📖 详细指南与常见问题

<details>
<summary><b>📖 Cloudflare 域名解析与 API Token 申请指南（点击展开）</b></summary>

### 步骤 1：在 Cloudflare 添加 A 记录
1. 登录 [Cloudflare 控制台](https://dash.cloudflare.com/)，进入你的域名；
2. 左侧菜单 **DNS** $\to$ **记录 (Records)** $\to$ **添加记录 (Add record)**；
3. 填写：
   * **类型 (Type)**：`A`
   * **名称 (Name)**：二级前缀（例如 `node`、`o2`，根域用 `@`）
   * **IPv4 地址**：这台 VPS 的公网 IPv4
   * **代理状态 (Proxy status)**：**【核心关键】必须为“仅限 DNS”（灰色云朵）！开启小黄云 CDN 会阻断 UDP，Hysteria 2 将完全无法连接。**
4. 点击 **保存 (Save)**。

### 步骤 2：生成专属 API Token
1. Cloudflare 右上角头像 $\to$ **配置文件 (Profile)**；
2. 左侧 **API 令牌 (API Tokens)** $\to$ **创建令牌 (Create Token)**；
3. 找到模板 **编辑区域 DNS (Edit zone DNS)**，点击 **使用模板 (Use template)**；
4. 配置：
   * **令牌名称**：任意（如 `simple-box-cert`）
   * **区域资源 (Zone Resources)**：**包括 (Include)** $\to$ **特定区域 (Specific zone)** $\to$ 选中目标域名
   * 其余保持默认
5. 底部 **继续以显示摘要** $\to$ **创建令牌**；
6. 复制生成的 Token（仅展示一次，妥善保存）。

### 步骤 3：在 VPS 终端填入
运行 `simbo` 进行安装或在 Hysteria 2 模块输入域名后，按提示粘贴 Token。脚本会自动当场在线校验有效性并签发 ECC 证书。
</details>

<details>
<summary><b>🖥️ 控制台菜单与常用配置项速查表（点击展开）</b></summary>

### 控制台主界面看板预览

```text
====================================================
        Simple-Box Manager - 极简安全控制台        
====================================================
 操作系统: Ubuntu 24.04.5 LTS (amd64)
 公网 IP : 203.0.113.10 | TLS 证书: IP 自签证书
 TCP 加速: 已开启 (bbr)
 sing-box: 运行中 (v1.14.3)
 Caddy订阅: 运行中 (端口: 8444 [HTTP])
 当前节点: Reality: TCP 443 | Hy2: UDP 8443 [跳跃: 20000:40000]
----------------------------------------------------
 在线订阅: http://203.0.113.10:8444/2dac50852729bf55bb61833d/config.yaml
 节点列表: http://203.0.113.10:8444/2dac50852729bf55bb61833d/provider.yaml
----------------------------------------------------
 1. VLESS-Reality 模块配置
 2. Hysteria 2 模块配置
 3. 在线订阅站点模块配置
 4. 查看节点链接与二维码 (URI/QR Code)
 5. TCP BBR 加速管理
 6. sing-box 内核管理
 7. 重新安装Simple-Box
 8. 卸载 Simple-Box 脚本
 0. 退出管理控制台
====================================================
```

### 安装流程关键输入项

| 配置项 | 默认值 | 行为说明 |
| :--- | :--- | :--- |
| **Reality 监听端口** | `443` | 1-65535，被外部占用会提示更换；与 Nginx 共存时可改为其他端口 |
| **Reality 伪装域名** | `gateway.icloud.com` | 需支持 TLS 1.3 的大厂 SNI 站点，禁止填本机 IP |
| **Hysteria 2 域名** | 自动检测旧域名 | 检测到旧域名可一键回车沿用；直接回车 = IP 自签；`skip` = 跳过 Hy2 |
| **Cloudflare Token** | — | 仅配置域名且无本地有效证书时需要，留空自动降级为自签 |
| **Hy2 主监听端口** | `8443` | UDP 端口，与 Reality 端口互斥 |
| **端口跳跃范围** | `20000:40000` | 格式 `起:止`；输入 `none` 关闭端口跳跃 |
| **Caddy 订阅端口** | `8444` | TCP 端口，独立分发订阅，不抢占 80 端口 |
| **节点名称前缀** | `Node` | 节点显示前缀，自动过滤特殊字符 |
</details>

<details>
<summary><b>❓ 常见问题解答 (FAQ)（点击展开）</b></summary>

#### Q1：如果机器上已有 Nginx，或者安装本脚本后再安装 Nginx，会有冲突吗？
**绝大部分情况下互不干扰，只需注意一个关键点：**
1. **80 端口零冲突**：Simple-Box 的 Caddy 专用于订阅分发，只监听在 8444 端口（通过 `bind tcp4/0.0.0.0`），脚本会自动清除 Caddy 默认占用的 80 端口，**80 端口完全留给 Nginx 使用**。
2. **443 端口注意事项**：
   - 如果你的 Nginx 已经配置了 HTTPS 网站占用了 443 端口，安装 Simple-Box 时 Reality 端口输入不能选 443（脚本会自动检测并提示已被占用），请将 Reality 端口改为其他端口（如 `20443`、`34443` 等）。
   - 如果先安装了 Simple-Box（Reality 默认占用了 443），后续在 Nginx 里配置监听 443 的 HTTPS 站点时，Nginx 会报端口被占；此时在 `simbo` 控制台选项 1 中将 Reality 端口改成其他端口即可。
3. **证书申请零冲突**：Simple-Box 走 Cloudflare DNS API 验证，不需要占用 80 端口做 HTTP-01 验证，完全不会与 Certbot 或 Nginx 的证书续签产生冲突。

#### Q2：没有域名能用 Hysteria 2 吗？为什么自签模式下订阅是 HTTP？
能！安装时域名询问直接回车即可启用 IP 自签证书，客户端节点自带 `skip-cert-verify: true`，连接速度与正规证书完全一致。
**关于订阅**：主流客户端（ClashX.Meta / Clash Verge / Shadowrocket 等）在拉取订阅时，底层的 TLS 客户端会硬性阻断未受信任的自签证书导致无法导入。因此在自签模式下，Caddy 订阅站点自动走 HTTP 分发（配合 24 位高强度随机 Token 路径隔离防护），免除用户手动安装系统 CA 的麻烦；绑定正规域名后则会自动升级为带 CA 证书的标准 HTTPS。

#### Q3：能用 IPv6 连接节点吗？
不能。Simple-Box 为追求极简与可靠，彻底移除了 IPv6 双栈与相关复杂的 ip6tables 规则。所有服务显式绑定 IPv4。如果你的网络或机器仅有 IPv6，请勿使用本脚本。

#### Q4：域名不在 Cloudflare，能申请正规证书吗？
不能。域名证书仅支持 Cloudflare DNS-01 API。若域名在其他提供商，建议直接回车使用 IP 自签模式，或者将域名 NS 托管至 Cloudflare。

#### Q5：域名证书申请失败会怎样？
脚本会自动降级为 10 年期 IP 自签证书兜底完成安装，保证节点立即可用；后续检查 CF Token 权限后，在 `simbo` 选项 2 中随时可重新配置升级为域名证书。
</details>

<details>
<summary><b>🧪 安装后状态自检命令（点击展开）</b></summary>

```bash
systemctl status sing-box caddy --no-pager        # 检查服务运行状态
sing-box check -c /etc/sing-box/config.json       # 校验 sing-box 配置完整性
ss -tlnp | grep -E ':(443|8444)'                  # 检查 Reality 与 Caddy 订阅端口
ss -ulnp | grep 8443                              # 检查 Hysteria 2 UDP 端口
iptables -t nat -L PREROUTING -n --line-numbers   # 检查端口跳跃 REDIRECT 规则
```
</details>

---

## 📄 开源许可证

本项目采用 [MIT 许可证](LICENSE)。
