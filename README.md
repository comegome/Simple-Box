# Simple-Box

> 极简、安全、透明的自用 Sing-box 服务端一键管理脚本。

专为追求**系统整洁、网络安全与纯净架构**的个人 VPS 用户设计。摒弃开源一键脚本中常见的防火墙滥开、内置未知二进制、明文 HTTP 暴露与多核心混部等隐患，全代码仅 ~350 行标准 Bash，逻辑简单、透明可审计。

---

## 🚀 一键安装与管理

在任意 Ubuntu / Debian / CentOS / Alpine VPS 上以 `root` 权限运行：

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

* **单内核纯净运行**：100% 官方正版 `SagerNet/sing-box` Release，无任何未知或第三方闭源二进制，系统常驻内存仅约 15~25 MB。
* **原生 Systemd 接管**：开机自启、异常自愈，生命周期管理标准规范。
* **双主力协议矩阵**：
  * **VLESS-TCP-Reality-Vision**：日常主力直连。基于 x25519 密钥对伪装大厂 SNI 借壳，免证书维护，延迟低、无额外加密开销。
  * **Hysteria 2**：晚高峰与恶劣弱网冲刺。基于 UDP/QUIC 自研单边拥塞控制，原生支持**端口跳跃（Port Hopping）**，有效抵御单端口 UDP QoS 限速与阻断。
* **Cloudflare DNS 自动化证书**：集成 `acme.sh`，基于 Cloudflare API Token 自动申请 Let's Encrypt 证书并静默续期。**无需开放 80 端口，不怕防火墙阻挡，支持通配符泛域名**。
* **精准防火墙策略**：严格遵循最小权限原则，仅针对性放行 Reality 端口与 Hy2 端口/跳跃端口段，绝不无脑清空防火墙。
* **原生 Mihomo 导出**：一键生成标准 ClashX.Meta / Mihomo `proxies:` YAML 格式代码块，方便直接嵌入自建订阅。
* **彻底干净卸载**：一键清除所有服务文件、配置目录与网络转发规则，不留僵尸 Crontab，不留系统垃圾。

---

## 🖥️ 交互菜单使用说明

直接运行脚本（或执行 `/root/simple-box.sh`）即可唤起交互式控制面板：

```text
====================================================
        Simple-Box Manager - 极简安全控制台        
====================================================
 1. 安装 / 重置配置 (VLESS-Reality + Hysteria2)
 2. 查看当前节点的 Clash.Meta YAML 配置
 3. 检查并升级 sing-box 官方最新内核
 4. 重启 sing-box 服务
 5. 查看运行日志
 6. 彻底干净卸载
 0. 退出
====================================================
服务状态: 运行中
```

### 选项说明：
* **[1] 安装 / 重置配置**：
  首次部署或更改协议参数时使用。依次输入 Reality 端口、借壳伪装域名、绑定域名、Cloudflare API Token、Hy2 端口与跳跃范围等参数，脚本将自动拉取官方最新内核、申请证书、配置防火墙与 Systemd，并启动服务。
* **[2] 查看当前节点的 Clash.Meta YAML 配置**：
  在终端高亮格式化打印当前节点配置，便于直接复制追加至你的 `proxy-providers` 订阅文件中。
* **[3] 检查并升级 sing-box 官方最新内核**：
  秒级检查 GitHub 官方 Releases 最新 Tag，执行原子覆盖升级并平滑重启服务，配置文件保持不变。
* **[4] 重启 sing-box 服务**：
  重载并重启后台 Systemd 守护进程。
* **[5] 查看运行日志**：
  实时流式跟踪 `journalctl -u sing-box` 运行输出，排查握手与连接状态，按 `Ctrl + C` 退出查看。
* **[6] 彻底干净卸载**：
  停止并删除 Systemd 单元，精准清除 iptables 端口跳跃 NAT 规则与防火墙规则，彻底删除 `/etc/sing-box` 目录与内核程序，完整还原纯净系统环境。

---

## 📋 快捷命令行调用

除交互菜单外，支持在终端直接追加参数执行：

```bash
/root/simple-box.sh yaml       # 查看当前节点的 Clash.Meta YAML 配置
/root/simple-box.sh update     # 一键静默升级 sing-box 官方最新内核
/root/simple-box.sh del        # 彻底干净卸载并还原网络规则
```

---

## 📄 开源许可证

本项目采用 [MIT 许可证](LICENSE)。
