# Simple-Box

> 极简、安全、透明的自用 Sing-box 服务端一键管理脚本。

专为追求**系统整洁、网络安全与纯净架构**的个人 VPS 用户设计。摒弃开源一键脚本中常见的防火墙滥开、内置未知二进制、明文 HTTP 暴露与多核心混部等隐患，全代码约 1100 行标准 Bash，逻辑简单、透明可审计。

---

## 🖥️ 环境要求与兼容性

### 1. VPS 硬件最低配置要求
* **CPU**：1 核心（支持 `x86_64` / AMD64 及 `aarch64` / ARM64）
* **内存**：最低 256 MB（推荐 **512 MB 及以上**）
  * *注：Sing-box 服务端常驻内存约 8~15 MB，集成 Caddy 常驻约 10 MB，极省资源。*
* **磁盘**：可用空间 $\ge$ 1 GB
* **网络**：具备公网 IPv4（自签证书与节点信息均依赖公网 IP 探测）

### 2. 支持的操作系统
* **Ubuntu** $\ge$ 20.04（推荐 22.04 / 24.04 LTS）
* **Debian** $\ge$ 11（Bullseye / Bookworm）
* **CentOS / RHEL / Rocky Linux / AlmaLinux** $\ge$ 8
* **Alpine Linux** $\ge$ 3.16

---

## 🚀 一键安装与管理

在任意满足要求的 VPS 上以 `root` 权限运行：

### 1. 官方直链（海外 VPS 推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/comegome/simple-box/main/simple-box.sh)
```
或使用 `wget`：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/comegome/simple-box/main/simple-box.sh)
```

### 2. CDN 加速直链（国内机器 / 抗 DNS 污染）

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/comegome/simple-box@main/simple-box.sh)
```
或使用 `wget`：
```bash
bash <(wget -qO- https://cdn.jsdelivr.net/gh/comegome/simple-box@main/simple-box.sh)
```

---

## ⌨️ 全局快捷指令

安装完成后脚本会把自身落地到 `/usr/local/share/simple-box/simple-box.sh`，并注册软链 `/usr/local/bin/simbo`（管道执行 `bash <(curl ...)` 场景同样支持）。之后在服务器**任意路径**下直接输入 **`simbo`**：

```bash
simbo               # 打开交互式控制面板
simbo sub           # 查看在线订阅链接与本地 YAML
simbo link          # 查看单独节点链接 (vless:// / hy2://) 与二维码
simbo bbr           # 管理 TCP BBR 拥塞控制（开启 / 关闭）
simbo update        # 检查并升级 sing-box 官方内核
simbo update force  # 强制重新下载覆盖当前内核
simbo del           # 彻底卸载并还原网络规则
```

---

## 📖 Cloudflare 域名解析与 API Token 申请指南

如果你希望为 Hysteria 2 绑定自有域名并申请受信任的 Let's Encrypt 证书，请按以下步骤操作（全程 **DNS-01 验证**，**无需 VPS 开放 80 端口**，即使防火墙关闭所有 Web 端口也能签发）。

> **不想折腾域名？** 在一键安装的域名提示处**直接按回车**即可。脚本会为本机公网 IP 生成 10 年期自签证书（含 SAN），Hysteria 2 与订阅站点照常工作，客户端自动带上 `skip-cert-verify: true`。

### 步骤 1：在 Cloudflare 添加 A 记录
1. 登录 [Cloudflare 控制台](https://dash.cloudflare.com/)，点击进入你的域名；
2. 左侧菜单 **DNS** $\to$ **记录 (Records)** $\to$ **添加记录 (Add record)**；
3. 填写：
   * **类型 (Type)**：`A`
   * **名称 (Name)**：二级前缀（例如 `node`、`o2`，根域用 `@`）
   * **IPv4 地址**：这台 VPS 的公网 IPv4
   * **代理状态 (Proxy status)**：**【核心关键】必须为“仅限 DNS”（灰色云朵）！开启小黄云 CDN 会阻断 UDP，Hysteria 2 将完全无法连接。**
4. **保存 (Save)**。

### 步骤 2：生成专属 API Token
1. Cloudflare 右上角头像 $\to$ **我的个人资料 (My Profile)**；
2. 左侧 **API 令牌 (API Tokens)** $\to$ **创建令牌 (Create Token)**；
3. 找到模板 **编辑区域 DNS (Edit zone DNS)**，点击 **使用模板 (Use template)**；
4. 配置：
   * **令牌名称**：任意（如 `simple-box-cert`）
   * **区域资源 (Zone Resources)**：**包含 (Include)** $\to$ **特定区域 (Specific zone)** $\to$ 选中目标域名
   * 其余保持默认
5. 底部 **继续以显示摘要** $\to$ **创建令牌**；
6. 复制生成的 Token（仅展示一次，妥善保存）。

### 步骤 3：在 VPS 终端填入
运行 `simbo` 选 `[1] 安装 / 重置配置`，在域名提示处输入域名，随后粘贴 Token。脚本会全自动签发 ECC-256 证书，并由 acme.sh 的 cron 每 60 天静默续期。

---

## 🛠️ 功能特性

* **单内核纯净运行**：仅使用官方 `SagerNet/sing-box` Release，无任何未知或第三方闭源二进制，常驻内存约 8~15 MB。
* **双主力协议矩阵**：
  * **VLESS-TCP-Reality-Vision**：日常主力。x25519 密钥对伪装大厂 SNI，免证书维护，延迟低、无额外加密开销。
  * **Hysteria 2**：弱网冲刺。UDP/QUIC 单边拥塞控制，支持**端口跳跃（Port Hopping）**，抵御单端口 UDP QoS。
* **三档证书策略**：
  * **域名证书**：Cloudflare DNS API 申请 Let's Encrypt，无需 80 端口，自动续期；
  * **IP 自签证书**：直接回车即可，为公网 IP 签发 10 年 ECC 证书（含 SAN），客户端自动 `skip-cert-verify: true`；
  * **跳过 Hy2**：输入 `skip`，仅部署 Reality（订阅站点仍用自签证书保护）。
  * 域名证书申请失败时**自动降级**为 IP 自签证书，节点不会因证书问题瘫痪。
* **TCP BBR 管理**：检测 / 开启 / 关闭三态管理，写入独立 `/etc/sysctl.d/99-bbr.conf`，不改动系统其它参数。
* **Caddy 安全订阅分发**：
  * 未安装 Caddy 时自动安装官方版本；
  * 自定义 HTTPS 端口（默认 8444），与既有 Nginx/Apache 的 80/443 完全隔离；
  * 随机 Token 路径隔离，未授权路径一律 404。
* **三种导出形态（自动输出）**：
  * **完整托管订阅**：内置 MIPS TUN、纯 IP DoH、ARC 缓存与精准分流模板，导入即用；
  * **纯节点 Provider**：供自建分流配置引用；
  * **原生分享链接 + 二维码**：生成 `vless://` / `hysteria2://` URI，终端直接渲染 ANSI 二维码。
* **输入校验与冲突检测**：
  * 端口与跳跃范围做合法性校验（1-65535、起止有序）；
  * 端口被外部服务占用时拦截并要求更换，被自身 sing-box / caddy 占用时平滑接管；
  * 节点名前缀自动剔除会破坏 YAML/URI 的引号字符。
* **启动前配置校验**：写入配置后先跑 `sing-box check`，通过才重启服务，避免带病启动。
* **内核升级精准比对**：本地版本与 GitHub 最新 Tag 比对，相同则跳过下载；下载 / 解压失败保留原内核。
* **彻底干净卸载**：停止服务、删除 systemd 单元、清理 iptables 端口跳跃规则、移除 Caddy 站点与 acme 续期任务、删除配置目录与全局指令。

---

## 🖥️ 交互菜单与首页看板

直接输入 `simbo` 进入控制台，首页实时呈现系统与节点状态，每个操作结束后按回车返回主菜单：

```text
====================================================
        Simple-Box Manager - 极简安全控制台
====================================================
 操作系统: Ubuntu 24.04.5 LTS (amd64)
 公网 IP : 203.0.113.10 | TLS 证书: IP 自签证书
 TCP 加速: 已开启 (bbr)
 Sing-box: 运行中 (v1.14.3)
 Caddy订阅: 运行中 (端口: 8444)
 当前节点: Reality: TCP 443 | Hy2: UDP 8443 [跳跃: 20000:40000]
----------------------------------------------------
 1. 安装 / 重置配置 (VLESS-Reality + Hysteria2 + Caddy)
 2. 查看在线订阅链接与节点 YAML
 3. 查看单独节点链接 (vless:// / hy2://) 与二维码
 4. 检查并升级 sing-box 官方最新内核
 5. TCP BBR 拥塞控制管理 (开启 / 关闭)
 6. 重启服务 (sing-box 与 Caddy)
 7. 查看 sing-box 运行日志
 8. 彻底干净卸载
 0. 退出管理控制台
====================================================
```

`TLS 证书` 字段会显示四种状态：`域名` / `IP 自签证书` / `未启用 (仅Reality)` / `未配置`（尚未安装）。

### 安装流程的输入项

| 提示 | 默认 | 说明 |
| :--- | :--- | :--- |
| Reality 监听端口 | `443` | 1-65535，被外部占用则要求重填 |
| Reality 伪装域名 | `gateway.icloud.com` | 需支持 TLS 1.3 的站点，不能填本机 IP |
| 域名 | 回车 = IP 自签 | `skip` 只装 Reality；`keep` 沿用已配置域名 |
| CF API Token | — | 仅在填了域名时询问，留空自动降级为自签 |
| Hy2 UDP 端口 | `8443` | 1-65535 |
| 端口跳跃范围 | `20000:40000` | 格式 `起:止`；输入 `none` 关闭跳跃 |
| Caddy 订阅端口 | `8444` | 1-65535 |
| 节点名前缀 | `Node` | 会剔除引号字符 |

---

## 🧪 安装后自检

```bash
systemctl status sing-box caddy --no-pager    # 服务状态
sing-box check -c /etc/sing-box/config.json   # 配置合法性
ss -tlnp | grep -E ':(443|8444)'              # Reality 与订阅端口
ss -ulnp | grep 8443                          # Hy2 端口
iptables -t nat -L PREROUTING -n --line-numbers | grep 8443   # 端口跳跃
curl -k https://<域名或IP>:8444/sub_<token>/provider.yaml     # 订阅可达性
```

---

## ❓ 常见问题

**Q：没有域名能用 Hysteria 2 吗？**
能。安装时域名处直接回车，脚本为公网 IP 生成 10 年自签证书，客户端使用 `skip-cert-verify: true`，速度与正规证书无差异。

**Q：域名证书申请失败会怎样？**
脚本会自动降级为 IP 自签证书并继续完成安装，节点立即可用；修正 Token 后重跑 `simbo` 选 `[1]` 即可升级为域名证书。

**Q：80 端口被占用 / 服务器未备案会影响签证书吗？**
不会。本脚本使用 DNS-01 验证，全程走 Cloudflare API，不触碰 80/443。

**Q：能和 Nginx / 已有站点共存吗？**
能。订阅站点监听独立端口（默认 8444），不占用 80/443；安装时会检测端口冲突。

**Q：端口跳跃要开吗？**
UDP 被 QoS 限速时开启更稳。输入 `none` 可关闭，客户端将只连单一 UDP 端口。

**Q：重置配置时会不会丢掉现有节点？**
端口、伪装域名、节点前缀都会以当前配置作为默认值，直接回车即沿用；但 UUID、密码、订阅 Token 每次安装都会重新生成，旧订阅链接会失效，需重新导入。

---

## 📄 开源许可证

本项目采用 [MIT 许可证](LICENSE)。
