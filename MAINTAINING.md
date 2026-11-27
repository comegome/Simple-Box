# 维护约定

这份文档记录改这个脚本时反复踩到的坑，以及验证方式上的硬性要求。不是功能说明，改代码前读一遍能省一次返工。

## 一、改权限前，先确认谁要读这个文件

`cert/private.key` 曾被设成 `600 root:root`，理由是「私钥不能给别的用户读」。结果 caddy 直接起不来：

```
loading tls app module: provision tls: loading certificates:
open /etc/sing-box/cert/private.key: permission denied
```

caddy 以 `caddy` 用户运行，要用私钥做 TLS。正确值是 `640 root:caddy`：其它本地用户进不来，caddy 能读。

改任何文件权限前，先跑一遍确认读者是谁：

```bash
systemctl show caddy -p User -p Group
systemctl show sing-box -p User -p Group
sudo -u <服务用户> cat <文件> >/dev/null && echo 可读 || echo 不可读
```

`env.conf` 是 `600 root:root` 没问题——只有以 root 运行的脚本和 sing-box 读它。

## 二、加参数放行某个检查前，先问这个检查为什么存在

一个检查项被「误报」时，先确认它想防什么，再决定是放宽还是修调用方。历史上 `check_range_conflict` 就这样被加过一个 `skip` 参数，调用方把要校验的端口本身传进去跳过比较，恰好关掉了这个函数唯一存在的意义。

不要为了消掉一条提示而加旁路参数；如果整个检查确实不再需要（例如 4.0 移除了端口跳跃，连带删掉 `check_range_conflict`），就把它和它的调用点一起删干净，而不是留一个永远为真的判据。

## 三、回滚必须验证「回滚后真的恢复了」

`render_and_reload` 里的配置回滚写了很久，实际从未生效：

```bash
write_singbox_config   # mv 覆盖正式配置，坏配置已落盘
write_env_config
render_and_reload      # 到这里才 cp 备份 —— 备份的是刚写的坏配置
```

回滚等于把坏配置复制回自己。验证方法很简单：造一个必定失败的状态，跑一遍，看最终文件内容。

现在已删除该逻辑，改为报错并提示重装。`update_singbox_core` 的内核回滚是有效的（先备份旧二进制再装新的），保留。

内核升级现在还会按 GitHub API 返回的 asset `digest` 校验安装包：校验发生在解压与替换之前，不符就中止且现网二进制不动。备份二进制显式 `chmod 755`——`cp` 覆盖已存在的同名文件时不改权限，回滚会得到不可执行的内核。

**`load_env` 有一处已知差异，不要当成 bug 修掉。** 它把 `source` 的返回码吞掉（`if . "$ENV_FILE"; then :; fi`），所以 env.conf 语法坏掉时不再中止，而是带着已加载的部分继续。原本 9 处 `set +e` 包裹的调用点语义不变；只有裸调它的 `menu_camo` / `menu_exit` 从「中止」变成「继续」。这个函数在回归套件里没有执行型断言，改它必须在一次性机器上手工验。

## 四、测试不能顺着实现写

写 `check_range_conflict` 的测试时，D4 用例断言「传 skip 时跳过主端口」——这正是错误实现的行为。测试全绿，缺陷还在。

断言要来自需求，不来自代码：

```
错误：skip 参数应跳过主端口
正确：范围包含主端口必须拒绝
```

如果一个测试是照着刚写的实现反推出来的，它只能证明代码和测试一致，不能证明代码正确。

## 五、改菜单编号要同步所有依赖编号的测试

菜单从 9 项减到 8 项时，卸载从 `8` 变成 `7`。主套件同步了，另一个专项脚本里 4 处 `printf "8\ny\n"` 漏了，导致卸载从未执行，13 项断言全部落空。

改编号后全局搜一遍：

```bash
grep -rn 'printf "[0-9]\\n' ~/.hermes/cache/scratch/*.sh
```

## 六、sed 的 a 命令会吃掉行首空格

用 `sed -i "/^rules:/a ${rule}"` 插入 YAML 规则时，`rule` 开头的两个空格被吃掉，生成非法缩进：

```yaml
rules:
- IP-CIDR,10.0.0.1/32,DIRECT    # 顶格，非法
```

改用 awk 原样写入：

```bash
awk -v rule="$rule" '{print} /^rules:[[:space:]]*$/ && !done {print rule; done=1}' f > f.tmp && mv f.tmp f
```

## 七、apt purge 遇到改过的 conffile 必须非交互

`/etc/caddy/Caddyfile` 被脚本改过，`apt-get purge` 时 dpkg 会弹 conffile 询问。脚本里 stdin 是管道，无人应答直接 EOF：

```
end of file on stdin at conffile prompt
```

包卡在 `iU` 半安装状态，之后任何 apt 操作都失败。必须：

```bash
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
    -o Dpkg::Options::="--force-confold" caddy
```

## 八、写系统配置要能区分归属

BBR 曾无条件覆盖 `/etc/sysctl.d/99-bbr.conf`，卸载时只要文件存在就删。在本来就开着 BBR、或有自己配置的机器上，安装会覆盖、卸载会把系统切回 cubic——比装之前更糟。

现在写入时打标记，卸载只删带标记的：

```bash
BBR_MARK="# managed-by: simple-box"
grep -q "^${BBR_MARK}" "$BBR_CONF" || return 0   # 不是自己的，不动
```

任何写 `/etc` 下共享位置的操作都该这样。

### 例外：靠文件名覆盖，而不是改对方的文件

网络基线用的是另一种接管方式：不修改、不删除服务商的 `99-bbr.conf` / `99-network-tuning.conf`，而是写自己的 `99-zz-simbo-net.conf`。`sysctl.d` 按文件名字典序应用，`99-zz-*` 排在它们之后，所以同名键以本脚本为准。

判据（三条同时满足才允许这么做）：

1. 只写自己的文件，对方文件的字节一个都不动（回归里用 sha256 断言）
2. 卸载能完整移除自己的文件——包括旧版文件名。改名时必须迁移旧文件，否则「卸载后旧配置在下次启动又生效」
3. 明确知道自己在覆盖谁：安装日志里必须打印被覆盖的文件名

反例：`/etc/sysctl.conf` 在 `sysctl.d/*` 之后应用，优先级比任何 `99-zz` 都高。安装时会检测并告警，但脚本不做自动修改。

## 九、校验函数返回失败，调用方必须接住

`write_env_config` 加了空值校验后返回 1，但调用方没检查：

```
内部错误: 环境变量缺失 (vl_privkey)，已中止写入
✓ 节点名称前缀已更新为: PERMTEST
```

第一行拒绝写入，第二行照常报成功。加了校验却没接住，比不加更危险——它制造了「有保护」的错觉。

现在 5 个调用点全部 `if ! write_env_config; then ... continue; fi`。

## 十、测试脚本自身也会骗人

今天遇到的测试 bug：

- `set -u` 下被测函数引用的颜色变量未定义，脚本静默退出，看起来像功能失败
- `$(func 2>&1)` 抓不到 `echo -e` 写到 stderr 的内容
- awk 提取函数体时被内部 heredoc 提前截断
- 用 `chmod` 在断言前替被测代码「修好」状态，等于自欺

测试失败先怀疑测试，再怀疑代码。

## 十一、坏 IPv6 会让每个连接白等 200-300ms

某节点上所有双栈域名的 TCP 握手都要 203ms，`ping` 到同一个 IP 却只有 1.7ms。原因是机器有全局 IPv6 地址、有默认路由，但实际连不出去：curl 和 sing-box 用的 Go dialer 都会先试 IPv6，等 200-300ms 无响应才回退 IPv4。强制 IPv4 后立刻降到 2ms。

这不是域名问题，是主机配置问题。它表现为「所有目标一起慢」，很容易被误判成「这个 SNI 的 CDN 节点远」——排查顺序应该是先看 `curl -4` 和默认的差值。

现在 `check_ipv6` 在安装时测一次，只在「有地址但连不通」时禁用，写入带 `managed-by` 标记的 `/etc/sysctl.d/99-disable-ipv6.conf`；卸载时 `disable_ipv6_managed` 只删带标记的文件，并把运行时切回启用（IPv6 只有开/关，装之前必然是开，可精确还原）。IPv6 正常的主机完全不受影响。

## 十二、升级路径不能在活节点上测，raw 有 CDN 缓存

`reinstall_with_latest` 用 `cmp -s` 判断「仓库版本是否等于本地」，但 raw.githubusercontent.com 有 CDN 缓存，push 之后几分钟内仍会返回旧内容。结果是「本地已是最新」被误判成「有新版本」，把旧脚本装回去再跑一遍安装向导。

更糟的是它原本无条件进安装向导：在跑着真实节点的机器上测一次，UUID、密钥、short-id、订阅 token 全部换新，客户端集体失效。这个错误当天在同一个节点上发生了两次。

现在的规则：

- 获取失败 → 中止，不回退到重装
- 已是最新 → 二次确认，默认不动手
- 有新版本 → 只替换脚本文件，重装需显式回答 y

测试这类路径请在没有 sing-box 的机器上做（`/usr/local/share/simple-box` 不存在时走的就是「有新版本」分支），或者先备份 `env.conf`。

## 十三、一个 acme 实例只能存一个 zone 的 token

`acme.sh` 把 Cloudflare 凭证存成 `SAVED_CF_Token`，而它是 **每个 home 一份**，不是每个域名一份：`_saveaccountconf_mutable` 写的是 `$ACCOUNT_CONF_PATH`。

所以同一个 `~/.acme.sh` 里同时挂「接入域（ducto.net）」和「内容域（yuzhaizu.com）」时，**后签的那个会覆盖前者**。表面一切正常（`acme.sh --list` 两个域名都在、续期时间都排好了），到点续期才会失败，而 cron 输出进 `/dev/null`——直接静默。

规则：一个 zone 一个 home。接入域用默认 `~/.acme.sh`，内容域（伪装站）用 `~/.acme.sh-site`，各自有独立 `account.conf` 与 cron 行；token 分别放 `/root/.cf-token`（接入）与 `/root/.cf-token-site`（内容）。`issue_site_cert` 已经这么做了，`acme_site_home_ensure` 负责按需创建 home 并幂等挂 cron。

验证不能只看 `--list`：要拿**每个 home 的 token** 去它声称的 zone 里各写一条 TXT 再删掉。能写才叫「这个 zone 的续期可用」。

## 十四、证书模式是安装期的常量，不是运行期的状态

`CERT_MODE` 只由 `issue_cert_bundle` 赋值，运行期没有任何代码路径改它；订阅里的 `skip-cert-verify` 与链接里的 `insecure=` 都由它派生，因此 `HY_SKIP_CERT` 这个字段被删掉了（4.x）。

代价与约束写在这里，免得以后有人「顺手加个开关」：

- 安装时填域名 = LE 证书；输入 `ip` = IP 自签。两种模式之后都不能中途切换，要换只能重跑安装向导（凭据会轮换，客户端要重新拿订阅）。
- 域名证书申请失败**直接中止安装**，不再降级自签。降级的后果是「域名客户端全部 x509 失败，而日志说节点可用」。
- `proto_enable_hy2` 找不到该域名的证书时一律中止，不再为「旧 skip 节点」开例外——那个例外正是两份状态并存的根源。
- 套件 38.1–38.5 守这条：env 不写 `HY_SKIP_CERT`、生成器从 `CERT_MODE` 派生、domain/selfsigned 两种输出各一条、运行期不得赋值 `CERT_MODE`。改断言之前先想清楚是不是在放宽不变式。

## 十五、重装默认沿用凭据

重装向导会读入 env 里现有的 `VL_UUID / VL_PRIVKEY / VL_PUBKEY / VL_SHORTID / HY_PASS / SUB_TOKEN`，默认原样沿用；只有显式回答 `y` 才会轮换。菜单里那句「重装会让客户端失效」的旧文案一并删了。

规则：

- 轮换是**显式选择**（`rotate_creds` 初值 `N`），默认不轮换。写代码时不要把 `ask` 的默认值设成 `y`。
- 沿用 token 时，`web/<token>/` 目录必须保留：清理规则是 `find "$WEB_DIR" -mindepth 1 ! -name "$sub_token" -exec rm -rf`，改这条之前先想清楚「沿用」路径。
- 套件 39.1–39.5 守这条（读入、三处沿用、显式轮换、目录清理、菜单文案）。变异自检：把默认改成 `y`、把 `keep_hypass` 丢掉、把 `-name` 条件删掉，三处都应变红。

这是「配置靠重装实现」这个方向的前置：重装不再有凭据代价，后面把协议集合、443 归属挪到安装期才划算。

## 十六、443 上已有站点时，安装阶段就交接

「先有网站、后装节点」是真实用法（AGI Signal / HW Signal 这类）。安装 `[1/3]` 现在会看选中端口的持有者：

- 持有者是 **caddy** 且 `/etc/caddy/sites` 里有站点块 → 列出域名（多个时让用户选）→ `site_handover_to_loopback` 把它改成 `https://<域名>:9443 { bind 127.0.0.1 }` → `caddy validate` + reload + 回环 HTTPS 探活 → 腾出端口
- 交接成功后 **`VL_SNI` 强制等于该域名**，不再允许填写别的 SNI：回落目标是刚搬走的那个站点，SNI 对不上就会打到 404
- 持有者是别的进程（nginx / docker 里的 nginx / python…）→ 明确报「本脚本只接管 Caddy 站点」，不静默降级
- 交接失败（校验/重载/探活任一步）→ 自动把站点翻回原样，然后重新问端口

只支持 Caddy 是**有意为之**：舰队 7 台都没有 nginx，443 全是 sing-box；为不存在的场景维护第二套配置改写不划算。

**每个输入循环都要有 `ASK_EOF` 守卫**，不是只给端口循环加：域名、SNI、Hy2 端口、订阅端口四个循环原来都没有，管道喂答案耗尽时会空转（实测刷了一万行「必须填域名」）。套件 35.6 按「`while true` 个数 ≤ `ASK_EOF` 出现次数」机械检查。

**443 被 Caddy 站点占着时，`[1/3]` 会就地交接，并且不再问 SNI**（SNI 固定为被搬走的那个站点）。照搬固定行数喂答案的脚本会整体前移一位：域名答案被当成「是否沿用」、端口答案被当成域名，一路错到底而每一步都显示「✓」。喂答案前先判断这台机器的 443 归谁，或者装完立刻回读 env（见下）。套件 40.1–40.7 守交接本身的行为。

## 十七、协议集合是安装期的常量

`PROTO_SET`（env.conf）= 这台机器装了哪些协议，取值只能是 `PROTOCOLS` 的非空子集。安装向导第一问决定它、重装默认沿用，**运行期没有任何路径改它**。

- 已删除：`proto_enable_reality` / `proto_enable_hy2` / `disable_protocol` / `menu_protocol` / `current_set` / `regen_from_scope`，主菜单不再有「入站管理」（3–8 前移为 2–7）。要增删协议就重跑安装，凭证默认沿用、客户端订阅不用改。
- 渲染：`render_set` 无参、只读 `PROTO_SET`；`write_singbox_config` 仍是唯一写入口（35.1）。`regen_subscription` 仍以 `config.json` 的 inbound 为准——配置是集合的产物，渲染失败会表现为「订阅少一条」，而不是「订阅指向没人监听的端口」。
- 安装期检查只有两处，都不写配置：`reality_target_check`（站点证书可用 / 有站点时 Reality 必须占 443 / 无站点时探测外部 SNI 的 TLS 1.3 + h2）、`hy2_cert_sync`（域名模式缺证书即中止，不回退自签）。
- **翻转状态不落库。** 没有 `SITE_FILE` / `FLIP_HOST` 字段，`FLIP_PORT` 是常量 `9443`；唯一入口是 `flip_site <on|off> <域名>`——现场用 `site_file_for` 解析站点，改完 `caddy validate`，失败还原文件并 reload。没有站点（外部 SNI）时它什么都不做、返回 0。
- **换伪装域名、或把 Reality 从集合里去掉时，旧站点必须搬回公网 443。** 翻转是站点块上的状态，不跟 env 走：`install_node` 在写 env 之前按**旧的 `VL_SNI`** 现场解析站点，不一致就 `flip_site off <旧域名>`，否则站点永久留在回环上，公网 443 空着（探测者拿到 connection refused，比不伪装更可疑）。
- **安装期建站必须早于 `render_set`。** `reality_target_check` 对「无站点但 A 记录指向本机」的域名只置 `CAMO_PENDING=1` 放行；真正建站在 `write_env_config` 之后、`load_env` 之前，用 `CAMO_SKIP_SWITCH=1 CAMO_DEFER_RELOAD=1` 调 `build_camo_site`：只落内容和站点文件（已经是回环 9443 形态），不 reload、不自检。若把这步挪到 `render_set` 之后，回落目标会先被写成「域名:443」，自环。
- **`CAMO_DEFER_RELOAD` 的站点必须已翻到回环。** 安装期 Caddyfile 的 `import sites/*.caddy` 还没写（由后续 `setup_caddy_subscription` 负责），所以这里不能走 `flip_site`（它要求 Caddyfile 存在并通过 `caddy validate`）；直接 `flip_transform` 改文本，重载交给安装流程。
- 面板：不在集合里的协议显示 `[未安装]`；在集合内但配置缺 inbound 显示 `[配置缺失]`（= 渲染失败，重装）。
- 套件 15.13–15.15（三种集合）、16.x（安装期检查）、27.x（`PROTO_SET` 只由 `ask_proto_set` 与 `write_env_config` 赋值）、35.6 守这些。变异自检：让 `render_set` 无视集合、删掉 env 落库行、让 `hy2_cert_sync` 缺证书放行，三处都应变红。
- 存量节点（env 里没有 `PROTO_SET`）默认按「两个都装」跑，换脚本不需要改 env；这个字段会在下一次写 env（改订阅参数 / 重装）时补上。

## 验证清单

改完跑仓库里的套件，这是唯一一套（旧的 `/tmp/r22.sh`、`r23b.sh`、`final_verify.sh` 已废弃并删除）：

```bash
cd ~/Simple-Box && sudo TARGET_SCRIPT=$PWD/simple-box.sh bash test-regression.sh
```

带 `caddy` / `mihomo` 的机器会多跑 15.20/15.21 与 31.10（缺二进制则跳过），计数以当次输出为准。全部通过才算完成。

第 35 组把几条「机械不变式」变成了红灯，不再靠记性：配置只能从 `render_set` 进 `write_singbox_config`、`render_set` 的调用方必须补 `apply_exit_config`/`render_and_reload`、清 `ENV_LOADED` 只能发生在 `write_env_config`、`mktemp` 要登记 `TMP_CLEANUP`、每个 `menu*` 循环都要能在 stdin 关闭时退出。新增路径时如果踩到这几条，先看断言名字，不要改断言去迁就实现。

## 提交粒度

一个需求一个提交。`9d0eb5a` 曾把三个缺陷修复、一个新功能、一次文案替换塞进同一个提交，事后回溯「哪个改动对应哪个需求」要翻 diff 才能分清。
