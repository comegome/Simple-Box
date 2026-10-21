# Simple-Box

> 极简、安全、透明的自用 Sing-box 服务端一键管理脚本。

专为追求**系统整洁、网络安全与纯净架构**的个人 VPS 用户设计。摒弃开源一键脚本中常见的防火墙滥开、内置未知二进制、明文 HTTP 暴露与多核心混部等隐患，全代码仅 ~450 行标准 Bash，逻辑简单、透明可审计。

---

## 🖥️ 环境要求与兼容性

### 1. VPS 硬件最低配置要求
* **CPU**：1 核心（x86_64 / aarch64）
* **内存**：最低 256 MB（推荐 **512 MB 及以上**）
  * *注：Sing-box 服务端常驻内存仅约 8~15 MB，集成 Caddy 常驻仅约 10 MB，极省资源。*
* **磁盘**：可用空间 $\ge$ 1 GB
* **网络**：具备公网 IPv4 或 IPv6 地址

### 2. 支持的操作系统
* **Ubuntu** $\ge$ 20.04 (强烈推荐 22.04 / 24.04 LTS)
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

## 🛠️ 功能特性

* **单内核纯净运行**：100% 官方正版 `SagerNet/sing-box` Release，无任何未知或第三方闭源二进制，系统常驻内存仅约 8~15 MB。
* **双主力协议矩阵**：
  * **VLESS-TCP-Reality-Vision**：日常主力直连。基于 x25519 密钥对伪装大厂 SNI 借壳，免证书维护，延迟低、无额外加密开销。
  * **Hysteria 2**：晚高峰与恶劣弱网冲刺。基于 UDP/QUIC 自研单边拥塞控制，原生支持**端口跳跃（Port Hopping）**，有效抵御单端口 UDP QoS 限速与阻断。
* **Cloudflare DNS 自动化证书**：集成 `acme.sh`，基于 Cloudflare API Token 自动申请证书并静默续期。**无需开放 80 端口，不怕防火墙阻挡，支持通配符泛域名**。
* **集成 Caddy 安全订阅分发**：
  * 若系统未安装 Caddy，脚本将**自动安装并配置官方 Caddy**；
  * 提供自选 HTTPS 端口（默认 8444），与宿主机原有 Nginx/Apache (80/443) 完全隔离，互不冲突；
  * 采用高强度随机安全 Token 隔离访问，未授权路径一律 404，杜绝扫描与泄密。
* **多种订阅与导出形态（自动输出）**：
  * **完整托管订阅 URL**：内置 MIPS TUN、纯 IP DoH、ARC 缓存与精准分流模板，客户端直接导入即用；
  * **纯节点 Provider 订阅 URL**：供自建分流规则配置引用；
  * **原生分享链接与二维码**：自动生成 `vless://` 和 `hysteria2://` 分享 URI，并在终端直接渲染 ANSI 字符二维码，方便手机扫描导入。
* **精准防火墙策略与冲突检测**：
  * 严格遵循最小权限原则，仅针对性放行 Reality 端口、Hy2 端口与跳跃端口段，绝不无脑清空防火墙；
  * 输入端口时**自动检测冲突**，若被 Nginx 等外部服务占用则拦截并提示更换，若为已有 sing-box 进程则平滑接管。
* **彻底干净卸载**：一键清除所有服务文件、配置目录与网络转发规则，不留僵尸 Crontab，不留系统垃圾。

---

## 🖥️ 交互菜单使用说明

直接运行脚本（或执行 `/root/simple-box.sh`）即可唤起交互式控制面板：

```text
====================================================
        Simple-Box Manager - 极简安全控制台        
====================================================
 1. 安装 / 重置配置 (VLESS-Reality + Hysteria2 + Caddy)
 2. 查看在线订阅链接与节点 YAML
 3. 查看单独节点链接 (vless:// / hy2://) 与二维码
 4. 检查并升级 sing-box 官方最新内核
 5. 重启服务 (sing-box 与 Caddy)
 6. 查看 sing-box 运行日志
 7. 彻底干净卸载
 0. 退出
====================================================
Sing-box 状态: 运行中 | Caddy 订阅状态: 运行中
```

### 选项说明：
* **[1] 安装 / 重置配置**：首次部署或更改协议参数时使用。依次输入 Reality 端口、借壳伪装域名、绑定域名、Cloudflare API Token、Hy2 端口、跳跃范围以及 Caddy 订阅端口，全自动完成证书申请、环境编译、防火墙放行与服务启动。
* **[2] 查看在线订阅链接与节点 YAML**：打印完整托管订阅 URL、纯 Provider 订阅 URL 以及本地节点 YAML 片段。
* **[3] 查看单独节点链接 (vless:// / hy2://) 与二维码**：针对不需要客户端规则模板的场景，直接输出标准 URI 链接并在终端绘制二维码，方便手机扫码添加。
* **[4] 检查并升级 sing-box 官方最新内核**：秒级检查 GitHub 官方 Releases 最新 Tag，执行原子覆盖升级并平滑重启服务。
* **[5] 重启服务**：平滑重载并重启后台 `sing-box` 与 `caddy` 守护进程。
* **[6] 查看运行日志**：流式跟踪 `journalctl -u sing-box` 输出。
* **[7] 彻底干净卸载**：停止服务，精准删除 iptables 端口跳跃规则与 Caddy 订阅站点，彻底删除 `/etc/sing-box`。

---

## ⌨️ 全局快捷指令

安装完成后，在服务器任意目录下直接输入 **`simbo`** 即可随时唤起管理控制台：

```bash
simbo               # 快速打开交互控制面板
simbo sub           # 查看在线订阅链接与 YAML
simbo link          # 查看单独节点 vless/hy2 链接与二维码
simbo update        # 一键静默升级 sing-box 官方最新内核
simbo del           # 彻底干净卸载并还原网络规则
```

---

## 📄 开源许可证

本项目采用 [MIT 许可证](LICENSE)。
