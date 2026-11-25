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

菜单从 9 项减到 8 项时，卸载从 `8` 变成 `7`。`r22.sh` 同步了，`r23b.sh` 里 4 处 `printf "8\ny\n"` 漏了，导致卸载从未执行，13 项断言全部落空。

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

## 验证清单

改完跑这四组，缺一不可：

```bash
sudo bash /tmp/r22.sh          # 非破坏性全功能，102 项
sudo bash /tmp/r23b.sh         # 破坏性（装/卸/重装），44 项
sudo bash /tmp/final_verify.sh # 健康与出网，16 项
```

专项测试按改动内容补充。全部通过才算完成。

第 35 组把几条「机械不变式」变成了红灯，不再靠记性：配置只能从 `render_set` 进 `write_singbox_config`、`render_set` 的调用方必须补 `apply_exit_config`/`render_and_reload`、清 `ENV_LOADED` 只能发生在 `write_env_config`、`mktemp` 要登记 `TMP_CLEANUP`、每个 `menu*` 循环都要能在 stdin 关闭时退出。新增路径时如果踩到这几条，先看断言名字，不要改断言去迁就实现。

## 提交粒度

一个需求一个提交。`9d0eb5a` 曾把三个缺陷修复、一个新功能、一次文案替换塞进同一个提交，事后回溯「哪个改动对应哪个需求」要翻 diff 才能分清。
