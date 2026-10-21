# Simple-Box

> 极简、安全、透明的自用 Sing-box 服务端一键管理脚本。

专为追求**系统整洁、网络安全与纯净架构**的个人 VPS 用户设计。摒弃开源一键脚本中常见的“清空防火墙、内置闭源黑盒二进制、明文 HTTP 裸奔、双核心冗余”等隐患，全代码仅 ~350 行 Bash，透明可审计。

---

##  特性对比

| 维度 | 传统开源脚本 (如 sing-box-yg 等) | **Simple-Box** |
|---|---|---|
| **核心程序** | 自带 24MB 不明预编译二进制 (`sbwpph`) | **100% 官方正版** (`SagerNet/sing-box`) Release |
| **防火墙策略** | 暴力执行 `iptables -F`，系统全端口裸奔 | **零破坏**，针对性增量放行，卸载精准撤销 |
| **协议组合** | 塞入十几种协议，代码冗长难维护 | **精选双主力**：VLESS-Reality + Hysteria 2 |
| **端口跳跃** | 需手动折腾或粗暴转发 | **原生支持 Hysteria 2 UDP 端口跳跃**，抗 QoS 封锁 |
| **证书管理** | 依赖外部 80 端口验证或自签 | **Cloudflare DNS API 自动签发**，免开 80 端口，支持泛域名 |
| **节点导出** | 依赖 `busybox httpd` 明文公网暴露 | **直接生成 ClashX.Meta (Mihomo) YAML**，直接嵌入订阅 |
| **系统侵入** | 强行修改系统全局 DNS、禁用服务 | **零系统污染**，卸载彻底干净 |

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

### 2. 加速直链（国内机器 / 抗 DNS 污染）

```bash
bash <(curl -fsSL https://raw.loc.us.kg/comegome/simple-box/main/simple-box.sh)
```

---

## 🛠️ 支持的协议组合

### 1. VLESS-TCP-Reality-Vision (日常主力直连)
* **默认端口**：`443` (支持自定义)
* **抗封锁机制**：Xray 原创的 Reality 借壳伪装（默认伪装 `gateway.icloud.com`），免证书维护，客户端零握手加密损耗。

### 2. Hysteria 2 (晚高峰弱网 / 丢包冲刺)
* **主监听端口**：`8443` (UDP)
* **端口跳跃范围**：`20000:40000` (UDP)
* **抗封锁机制**：自动将 UDP 端口段重定向到主服务，客户端配置跳跃端口段，有效应对晚高峰运营商针对单端口的 UDP QoS 断流与限速。
* **证书保障**：调用 Cloudflare DNS API 自动签发 Let's Encrypt 证书并静默续期。

---

## 📋 快捷命令行参数

无需进入交互菜单，支持脚本直接传参调用：

```bash
/root/simple-box.sh yaml       # 查看当前节点的 ClashX.Meta YAML 配置
/root/simple-box.sh update     # 一键静默升级 sing-box 官方最新内核
/root/simple-box.sh del        # 彻底干净卸载并还原网络规则
```

---

## 📄 开源许可证

本项目采用 [MIT 许可证](LICENSE)。
