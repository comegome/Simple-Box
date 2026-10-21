# Simple-Box

> 极简、安全、透明的自用 Sing-box 服务端一键管理脚本。

专为追求**系统整洁、网络安全与纯净架构**的个人 VPS 用户设计。摒弃开源一键脚本中常见的防火墙滥开、内置未知二进制、明文 HTTP 暴露与多核心混部等隐患，全代码仅 ~500 行标准 Bash，逻辑简单、透明可审计。

---

## 🖥️ 环境要求与兼容性

### 1. VPS 硬件最低配置要求
* **CPU**：1 核心（支持 `x86_64` / AMD64 及 `aarch64` / ARM64）
* **内存**：最低 256 MB（推荐 **512 MB 及以上**）
  * *注：Sing-box 服务端常驻内存仅约 8~15 MB，集成 Caddy 常驻仅约 10 MB，极省资源。*
* **磁盘**：可用空间 $\ge$ 1 GB
* **网络**：具备公网 IPv4 或 IPv6 地址

### 2. 支持的操作系统
* **Ubuntu** $\ge$ 20.04 (推荐 22.04 / 24.04 LTS)
* **Debian** $\ge$ 11 (Bullseye / Bookworm)
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

首次运行脚本后，系统会自动在全局注册快捷指令。今后在服务器的**任意路径下**，直接输入 **`simbo`** 即可随时唤起控制台：

```bash
simbo               # 打开交互式控制面板
simbo sub           # 快速查看在线订阅链接与本地 YAML
simbo link          # 快速查看单独节点链接 (vless:// / hy2://) 与二维码
simbo bbr           # 管理 TCP BBR 拥塞控制 (开启 / 关闭切换)
simbo update        # 一键静默升级 sing-box 官方最新内核
simbo del           # 彻底干净卸载并还原网络规则
```

---


---

## 📖 Cloudflare 域名解析与 API Token 申请指南

如果你希望为 Hysteria 2 绑定自有域名并申请受信任的 Let's Encrypt 正规证书，请参考以下两步操作（整个过程耗时约 1 分钟，全走 DNS-01 验证，**无需 VPS 开放 80 端口，哪怕防火墙把 Web 端口全关了也能正常签发**）：

### 步骤 1：在 Cloudflare 添加 A 记录（解析 VPS 公网 IP）
1. 登录 [Cloudflare 控制台](https://dash.cloudflare.com/)，点击进入你的域名；
2. 在左侧菜单点击 **DNS** $\to$ **记录 (Records)** $\to$ 点击 **添加记录 (Add record)**；
3. 填写参数：
   * **类型 (Type)**：选择 `A`
   * **名称 (Name)**：输入你想使用的二级域名前缀（例如 `node`、`o2` 或 `@`）
   * **IPv4 地址**：填入这台 VPS 的公网 IPv4
   * **代理状态 (Proxy status)**：**【核心关键】务必点击切换为“仅限 DNS”（灰色云朵）！切勿开启小黄云 CDN 代理，否则 UDP (Hy2) 流量会被 Cloudflare 边缘阻断！**
4. 点击 **保存 (Save)**。

### 步骤 2：生成专属 API Token（授权脚本全自动申请与续期）
1. 点击 Cloudflare 控制台右上角个人头像 $\to$ **我的个人资料 (My Profile)**；
2. 在左侧菜单点击 **API 令牌 (API Tokens)** $\to$ 点击 **创建令牌 (Create Token)**；
3. 在常用模板列表中找到 **编辑区域 DNS (Edit zone DNS)**，点击右侧的 **使用模板 (Use template)**；
4. 权限设置极简：
   * **令牌名称**：任意填写（例如 `simple-box-cert`）
   * **区域资源 (Zone Resources)**：
     选择 **包含 (Include)** $\to$ **特定区域 (Specific zone)** $\to$ 在下拉框中选中你的目标域名
   * 其余参数默认保持不变
5. 滚动到页面最下方，点击 **继续以显示摘要 (Continue to summary)** $\to$ 点击 **创建令牌 (Create Token)**；
6. 复制屏幕上生成的一长串 Token 字符串（形如 `z5k9...`，注意：该 Token 仅展示一次，建议妥善保存）。

### 步骤 3：在 VPS 终端填入
在服务器运行 `simbo` 选择 `[1] 安装 / 重置配置`，在提示输入域名和 CF Token 时，直接将上述域名与 Token 粘贴进去即可。脚本将全自动签发 ECC-256 优质证书，并配置后台定时任务每 60 天静默续期。

## 🛠️ 功能特性

* **单内核纯净运行**：100% 官方正版 `SagerNet/sing-box` Release，无任何未知或第三方闭源二进制，系统常驻内存仅约 8~15 MB。
* **双主力协议矩阵**：
  * **VLESS-TCP-Reality-Vision**：日常主力直连。基于 x25519 密钥对伪装大厂 SNI 借壳，免证书维护，延迟低、无额外加密开销。
  * **Hysteria 2**：晚高峰与恶劣弱网冲刺。基于 UDP/QUIC 自研单边拥塞控制，原生支持**端口跳跃（Port Hopping）**，有效抵御单端口 UDP QoS 限速与阻断。
* **灵活证书机制（支持 CF API 或自签降级）**：
  * **有域名**：通过 Cloudflare DNS API 自动申请 Let's Encrypt 证书并静默续期。**无需开放 80 端口，不怕防火墙阻挡**；
  * **无域名**：自动降级生成 10 年 ECC 自签证书，客户端自动配置 `skip-cert-verify: true`，纯 IP 也能顺畅直连；
  * **完全跳过**：输入 `skip` 即可只部署 VLESS-Reality。
* **原生 TCP BBR 优化**：内置 BBR 检测与一键开启模块，配置 `/etc/sysctl.d/99-bbr.conf`，提升国际链路单线程吞吐。
* **集成 Caddy 安全订阅分发**：
  * 若系统未安装 Caddy，脚本将**自动安装并配置官方 Caddy**；
  * 自定义 HTTPS 订阅端口（默认 8444），与宿主机原有 Nginx/Apache (80/443) 完全隔离，互不冲突；
  * 采用高强度随机安全 Token 隔离访问，未授权路径一律 404，杜绝扫描与泄密。
* **多种订阅与导出形态（全自动输出）**：
  * **完整托管订阅 URL**：内置 MIPS TUN、纯 IP DoH、ARC 缓存与精准分流模板，客户端直接导入即用；
  * **纯节点 Provider 订阅 URL**：供自建分流规则配置引用；
  * **原生分享链接与二维码**：自动生成 `vless://` 和 `hysteria2://` 分享 URI，并在终端直接渲染 ANSI 字符二维码，方便手机扫描导入。
* **精准防火墙策略与冲突检测**：
  * 严格遵循最小权限原则，仅针对性放行 Reality 端口、Hy2 端口与跳跃端口段，绝不无脑清空防火墙；
  * 输入端口时**自动检测冲突**，若被 Nginx 等外部服务占用则拦截并提示更换，若为已有 sing-box 进程则平滑接管。
* **内核升级精准比对**：获取本地与 GitHub 官方最新 Tag 进行版本比对，已是最新版则避免重复下载 80MB 安装包。
* **彻底干净卸载**：一键清除所有服务文件、配置目录与网络转发规则，不留僵尸 Crontab，不留系统垃圾。

---

## 🖥️ 交互菜单与首页看板

直接输入 `simbo` 即可进入管理控制台，首页实时呈现系统与节点状态，执行完毕后自动返回主菜单：

```text
====================================================
        Simple-Box Manager - 极简安全控制台        
====================================================
 操作系统: Ubuntu 24.04 LTS (x86_64)
 公网 IP : 1.2.3.4 | TLS 证书: o2.ducto.net
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

---

## 📄 开源许可证

本项目采用 [MIT 许可证](LICENSE)。
