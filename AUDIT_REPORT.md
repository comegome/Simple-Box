# Simple-Box 安全与代码质量审计报告

**审计对象**: `simple-box.sh` (2433 行)  
**审计日期**: 2026-10-23  
**审计范围**: 安全性、健壮性、幂等性与副作用、代码质量、兼容性

---

## 一、总体评价

脚本整体工程质量**在同类一键管理脚本中属于上游水平**。体现在：

- 安全意识较强：env.conf 用 `umask 077` 写入 + `chmod 600`，私钥权限 640 + caddy 组、证书公私钥配对校验、输入白名单校验、管道执行拦截等
- 幂等性设计优秀：BBR 归属标记、Caddy 归属标记、iptables 精准清理、卸载时外来站点保护
- 错误处理较完善：`set -e` + 子 shell exit 防吞设计、密钥生成空值检查、配置校验后才启动服务

但仍存在 **1 个高危功能性 Bug** 和若干中低危安全/健壮性问题，下面逐一列出。

---

## 二、🔴 高危发现

### H-1: `verify_cloudflare_token` 永远发送 `***` 而非真实 Token（功能性 Bug + 安全误判）

| 项目 | 内容 |
|------|------|
| **行号** | 206 |
| **代码** | `check_res=$(curl -s -m 8 -H "Authorization: Bearer ***" https://api.cloudflare.com/client/v4/user/tokens/verify \|\| true)` |
| **问题** | Authorization header 中使用了字面量 `***` 而非变量 `$token`。所有 Token 校验请求都会被 Cloudflare 返回 401 无效，但函数不会 crash（`|| true`），只会返回 1 |
| **风险** | 1) Token 校验形同虚设，永远返回"失败" → 用户被迫重试或放弃，降级为自签证书。2) 如果 Cloudflare 的 verify 端点未来改变返回格式使 grep 误匹配，可能让无效 Token 通过校验 |
| **影响范围** | `prompt_cf_token()` → 所有需要 CF Token 的域名证书流程 |
| **修复** | 将 `***` 替换为 `$token`：`-H "Authorization: Bearer $token"` |

---

## 三、🟡 中危发现

### M-1: `CF_Token` 环境变量 export 后从未 unset（凭证残留）

| 项目 | 内容 |
|------|------|
| **行号** | 603 |
| **代码** | `export CF_Token="$cf_token"` |
| **问题** | `export` 使 CF Token 在当前 shell 及所有后续子进程的环境中可见，但整个脚本无任何 `unset CF_Token` 调用 |
| **风险** | acme.sh 执行完毕后，Token 仍留在环境中。若脚本后续 fork 的子进程（如 `curl`、`systemctl reload` 等触发的进程链）可被同机其他进程通过 `/proc/<pid>/environ` 读取（需 root 权限，但多 root 服务场景下存在泄露面） |
| **修复** | 在 `issue_cert_bundle` 的 acme.sh 调用完毕后添加 `unset CF_Token` |

### M-2: `PROMPTED_CF_TOKEN` 全局变量从未清零

| 项目 | 内容 |
|------|------|
| **行号** | 244, 260 |
| **问题** | `PROMPTED_CF_TOKEN` 是全局变量，存储明文 CF Token。赋值后在脚本生命周期内持续存在，无 `unset` |
| **风险** | 脚本是一个长期运行的交互式菜单循环。Token 在整个会话期间留在进程内存中，攻击面与 M-1 类似 |
| **修复** | 在 `prompt_cf_token` 调用方获取值后立即 `unset PROMPTED_CF_TOKEN` |

### M-3: `config.json` 权限为 644，含 Reality 私钥与 Hy2 密码

| 项目 | 内容 |
|------|------|
| **行号** | 1213 |
| **代码** | `chmod 644 "$tmp_conf"` → mv 到 `$CONF_FILE` |
| **问题** | sing-box 配置文件中嵌入了 `private_key`（Reality 私钥）和 Hysteria 2 `password`，但文件权限为 644（所有本地用户可读） |
| **风险** | 任何本机用户可读取 `/etc/sing-box/config.json` 获得所有代理凭证 |
| **修复** | 将 `chmod 644` 改为 `chmod 600`。sing-box 以 root 运行，不影响读取 |

### M-4: `fullchain.cer` 证书文件权限为 644（私钥已 640，但整体不一致）

| 项目 | 内容 |
|------|------|
| **行号** | 585, 658, 701 |
| **代码** | `chmod 644 "${CERT_DIR}"/*` |
| **问题** | 这条 glob 命令会将 `CERT_DIR` 下所有文件设为 644，包括 `private.key`。虽然紧接着调用 `harden_private_key` 把私钥改回 640，但存在一个极短的竞态窗口，且如果 `harden_private_key` 失败（`|| true` 吞错误），私钥就留在 644 |
| **风险** | 竞态条件下或函数失败时私钥对所有本地用户可读 |
| **修复** | 改为先设 `chmod 640 "${CERT_DIR}"/*`，然后单独 `chmod 644 "${CERT_DIR}/fullchain.cer"` |

### M-5: `/tmp/simple-box.latest.$$` 可被同机用户预测和抢占（Symlink Attack）

| 项目 | 内容 |
|------|------|
| **行号** | 1098 |
| **代码** | `local latest="/tmp/simple-box.latest.$$"` |
| **问题** | 使用 `$$`（PID）构造 `/tmp` 下的临时文件名，PID 可预测。攻击者可提前创建一个同名 symlink 指向任意路径 |
| **风险** | 如果文件被指向 `/etc/crontab` 等敏感位置，后续 `mv -f "$tmp" "$dest"` + `chmod 755` 可能覆盖系统关键文件。注：需要本地非 root 用户能在 `/tmp` 创建文件（默认可以）且 root 用 `mv` 跟随 symlink |
| **修复** | 使用 `mktemp` 替代手工构造：`local latest=$(mktemp /tmp/simple-box.latest.XXXXXX)` |

### M-6: `/tmp/` 临时文件无 trap 清理机制

| 项目 | 内容 |
|------|------|
| **行号** | 519, 1098 |
| **问题** | 整个脚本没有任何 `trap ... EXIT/INT/TERM` 清理逻辑。`mktemp -d`（行 519）和 `/tmp/simple-box.latest.$$`（行 1098）创建的临时文件/目录在脚本异常退出时无法清理 |
| **风险** | 磁盘碎片累积（低）；更重要的是 `set -e` 导致脚本在非预期位置退出时，sing-box 可能处于已停止但未重启的状态（行 1499-1500 先停了服务，后续步骤失败后 `set -e` 退出） |
| **修复** | 在脚本入口添加 `trap cleanup EXIT`，至少清理临时文件并尝试重启服务 |

### M-7: `source "$ENV_FILE"` 存在代码注入风险（需配合其他漏洞利用）

| 项目 | 内容 |
|------|------|
| **行号** | 1316, 1624, 1684, 1801, 1877, 1892, 2086, 2101, 2182, 2232, 2335 |
| **代码** | `set +e; source "$ENV_FILE"; set -e` |
| **问题** | `source` 会执行文件中所有 bash 代码。ENV_FILE 路径固定在 `/etc/sing-box/env.conf`，仅 root 可写（chmod 600），所以正常情况下安全。但如果攻击者获得了对该文件的写权限（如通过其他漏洞），可以注入任意 bash 命令 |
| **风险** | 属于纵深防御缺失。当前 600 权限足够保护，但 `source` 后无任何变量白名单校验 |
| **修复建议** | 可选增强：使用 `grep -E '^[A-Z_]+="[^"]*"$'` 白名单过滤后再 eval，或改用 `declare -A` 解析。当前优先级低 |

---

## 四、🔵 低危发现

### L-1: `$EUID` 未加双引号

| 项目 | 内容 |
|------|------|
| **行号** | 45 |
| **代码** | `[[ $EUID -ne 0 ]]` |
| **风险** | 在 `[[ ]]` 中不分词，实际无害。但不符合"所有变量引用一律双引号"的最佳实践 |

### L-2: `for r in $ranges` 未引用变量

| 项目 | 内容 |
|------|------|
| **行号** | 714 |
| **代码** | `for r in $ranges; do` |
| **问题** | `$ranges` 未加双引号，依赖 word splitting 迭代。该变量来自 `iptables -S` + `grep` 过滤，内容可控，实际安全。但如果 iptables 规则中包含 glob 字符（理论上不会），可能被错误展开 |

### L-3: `host=` 赋值缺少双引号

| 项目 | 内容 |
|------|------|
| **行号** | 1627, 2359 |
| **代码** | `local host=${TARGET_HOST:-${HY_DOMAIN:-$SERVER_IP}}` |
| **修复** | 改为 `local host="${TARGET_HOST:-${HY_DOMAIN:-$SERVER_IP}}"` |

### L-4: `rm -f ... *-${sub_port}.caddy` 中变量未加双引号

| 项目 | 内容 |
|------|------|
| **行号** | 837 |
| **代码** | `rm -f /etc/caddy/sites/*-${sub_port}.caddy /etc/caddy/sites/simple-box*.caddy` |
| **问题** | `${sub_port}` 来自用户输入（已通过 `validate_port` 校验为纯数字），实际安全。但防御性编程应加双引号 |

### L-5: `links.txt` 权限为 644，含代理凭证（UUID、密码）

| 项目 | 内容 |
|------|------|
| **行号** | 1034, 1042, 1638, 1642 |
| **问题** | `$LINKS_FILE`（`/etc/sing-box/links.txt`）和 `$WEB_DIR/$token/links.txt` 中包含完整的 VLESS UUID、Hysteria 2 密码，权限为 644 |
| **风险** | 本机任何用户可读取代理凭证。但考虑到该文件需要被 Caddy（caddy 用户）读取提供给客户端订阅，644 有一定合理性 |
| **修复建议** | `$LINKS_FILE`（本地工作副本）可以设为 600；`$WEB_DIR` 下的文件保持 644 但依靠 Token 路径保护 |

### L-6: Caddy 订阅地址未限制访问频率（枚举 Token 风险）

| 项目 | 内容 |
|------|------|
| **行号** | 841-877 |
| **问题** | Caddy 配置中对不匹配 `@sub` 路径的请求返回 404，但无 rate limiting。Token 为 24 位十六进制（`openssl rand -hex 12`），熵足够（96 bit），暴力枚举不可行。但如果未来 Token 长度缩短则有风险 |

### L-7: `acme.sh` 安装走不安全的管道安装模式

| 项目 | 内容 |
|------|------|
| **行号** | 598 |
| **代码** | `curl -sSL https://get.acme.sh \| sh -s email="admin@${domain}"` |
| **问题** | `curl | sh` 模式无完整性校验。如果 DNS 被劫持或 MITM 攻击，可能执行恶意代码 |
| **风险** | acme.sh 官方推荐的安装方式，业界普遍接受。但从安全审计角度仍需指出 |

### L-8: `os-release` source 可能引入意外变量

| 项目 | 内容 |
|------|------|
| **行号** | 87 |
| **代码** | `. "$osrel"` |
| **问题** | 直接 source `/etc/os-release`，该文件通常由发行版维护且仅含赋值语句，但理论上可以包含任意代码 |
| **风险** | 极低。`/etc/os-release` 属于 root，且脚本本身就以 root 运行 |

---

## 五、💡 建议改进

### S-1: 增加 `trap` 清理钩子

**行号**: 脚本入口（约行 12 之后）  
**建议**: 
```bash
cleanup() {
    rm -rf "${_TMP_FILES[@]}" 2>/dev/null || true
}
trap cleanup EXIT
```
所有临时文件路径统一追加到 `_TMP_FILES` 数组，退出时自动清理。

### S-2: `write_singbox_config` 中 JSON 变量应做转义

**行号**: 1146-1214  
**问题**: heredoc 中直接插入 `${vl_privkey}` 等变量到 JSON，如果变量值包含双引号或反斜杠（虽然 sing-box generate 正常不会产生这些），JSON 会破损  
**建议**: 对值做 JSON 转义，或使用 `jq` 构建。当前值来自 sing-box 自己生成的 base64/hex 编码，实际风险极低

### S-3: `node_prefix` 的 YAML 特殊字符过滤不够全面

**行号**: 1494-1495  
**代码**: `node_prefix=$(printf '%s' "$node_prefix" | tr -d '\"'"'"',#:\\')`  
**问题**: 过滤了引号、逗号、井号、冒号、反斜杠，但未过滤 `{}`、`[]`、`!`、`&`、`*` 等 YAML 特殊字符  
**风险**: 若用户输入含这些字符的前缀，生成的 YAML 可能解析异常（但 sing-box check 会在启动前拦住）

### S-4: `sing-box.service` 建议增加安全沙箱参数

**行号**: 1563-1580  
**建议**: 
```ini
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/etc/sing-box
NoNewPrivileges=yes
```
进一步限制 sing-box 进程的系统访问范围。

### S-5: 建议为 Bash 版本设置最低要求

**问题**: 脚本使用了 `${var,,}`（小写转换，Bash 4.0+）、`${!v}`（间接引用，Bash 3.0+）、BASH_REMATCH（Bash 3.0+）等特性，但未声明 Bash 版本要求  
**建议**: 在入口添加:
```bash
(( BASH_VERSINFO[0] >= 4 )) || { echo "需要 Bash 4.0+"; exit 1; }
```
Ubuntu 24.04 / Debian 12 均自带 Bash 5.x，实际无影响，但防止在非标准环境下出错。

### S-6: `update_singbox_core` 中 `tmp_dir` 应使用引号包裹的 `$(mktemp -d)`

**行号**: 519  
**代码**: `local tmp_dir=$(mktemp -d)` — 赋值正确但未在 local 声明中引用  
**说明**: `local` 赋值不分词，实际安全。纯风格建议。

### S-7: `generate_full_client_config` 使用位置参数 ${10}~${13} 可读性差

**行号**: 903-906  
**建议**: 超过 9 个参数时考虑改用关联数组或 env 变量传参，提高可维护性

---

## 六、幂等性与副作用评估

| 操作 | 幂等性 | 评价 |
|------|--------|------|
| 重复安装 | ✅ | 每次重新生成密钥凭证，幂等安全 |
| BBR 开启 | ✅ | 已开启则跳过，非本脚本配置不动 |
| BBR 关闭 | ✅ | 仅删除带标记的配置文件 |
| Caddy 安装 | ✅ | 已安装则跳过，带归属标记 |
| Caddy 卸载 | ✅ | 有外来站点时降级为仅删本站点配置 |
| iptables 规则 | ✅ | 先 -D 再 -A，持久化到 netfilter-persistent |
| 端口跳跃清理 | ✅ | 基于 REDIRECT 特征精准匹配删除 |
| 完全卸载 | ✅ | 外来 Caddy 站点保护、BBR 归属检查均到位 |

**亮点**: 卸载逻辑（行 1670-1788）是同类脚本中见过的最周全的实现：
- Caddy 站点共存检测
- `apt purge` 而非 `remove`（避免 mask 残留）
- `DEBIAN_FRONTEND=noninteractive` 防止 conffile 询问阻塞
- Caddyfile import 行回退逻辑

---

## 七、兼容性评估

| 项目 | 状态 | 说明 |
|------|------|------|
| Ubuntu 24.04 | ✅ | 所有依赖均在发行版仓库 |
| Debian 12 | ✅ | 同上 |
| x86_64 | ✅ | `get_arch` 正确映射为 `amd64` |
| aarch64 | ✅ | `get_arch` 正确映射为 `arm64` |
| Bash 版本 | ✅ | 支持范围内的系统均 Bash 5.x，语法特性无问题 |
| apt 包名 | ✅ | `curl tar openssl iptables qrencode iptables-persistent caddy` 均在支持范围仓库 |
| systemd | ✅ | 均为 systemd 系统 |
| iptables | ⚠️ | Debian 12 默认使用 `nftables` 后端，`iptables` 命令实际是 `iptables-nft` 兼容层，功能可用但部分行为可能与传统 iptables 不同 |

---

## 八、优先修复清单

| 优先级 | 编号 | 修复内容 | 预估工作量 |
|--------|------|----------|------------|
| P0 | H-1 | `verify_cloudflare_token` 行 206 的 `***` 替换为 `$token` | 1 分钟 |
| P1 | M-3 | `config.json` 权限从 644 改为 600 | 1 分钟 |
| P1 | M-5 | `/tmp/simple-box.latest.$$` 改用 `mktemp` | 2 分钟 |
| P1 | M-1 | acme.sh 调用后 `unset CF_Token` | 1 分钟 |
| P2 | M-4 | cert 目录下先 640 再单独 644 公钥证书 | 5 分钟 |
| P2 | M-6 | 添加 `trap cleanup EXIT` | 10 分钟 |
| P2 | M-2 | Token 使用后 `unset PROMPTED_CF_TOKEN` | 1 分钟 |
| P3 | L-1~L-4 | 变量引用加双引号（防御性编程） | 5 分钟 |
| P3 | S-1~S-7 | 建议性改进 | 按需 |

---

*审计结论: 该脚本安全基线良好，核心架构设计合理。H-1 是一个需立即修复的功能性 Bug（CF Token 校验完全失效），其余问题均为纵深防御层面的加固建议。*
