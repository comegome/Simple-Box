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

`check_range_conflict` 用来拦住「端口跳跃范围包含已分配端口」的情况。重构时给它加了个 `skip` 参数，两处调用都把 Hy2 主端口传进去跳过比较——恰好关掉了这个函数唯一存在的意义。

iptables 会把整个 UDP 段 DNAT 到主端口，主端口落在段内会和跳跃端口抢同一批包，客户端握手随机失败。

如果某个检查看起来「误报」，先确认它想防什么，再决定是放宽还是修调用方。不要为了消掉一条提示而加旁路参数。

## 三、回滚必须验证「回滚后真的恢复了」

`render_and_reload` 里的配置回滚写了很久，实际从未生效：

```bash
write_singbox_config   # mv 覆盖正式配置，坏配置已落盘
write_env_config
render_and_reload      # 到这里才 cp 备份 —— 备份的是刚写的坏配置
```

回滚等于把坏配置复制回自己。验证方法很简单：造一个必定失败的状态，跑一遍，看最终文件内容。

现在已删除该逻辑，改为报错并提示重装。`update_singbox_core` 的内核回滚是有效的（先备份旧二进制再装新的），保留。

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

## 验证清单

改完跑这四组，缺一不可：

```bash
sudo bash /tmp/r22.sh          # 非破坏性全功能，102 项
sudo bash /tmp/r23b.sh         # 破坏性（装/卸/重装），44 项
sudo bash /tmp/final_verify.sh # 健康与出网，16 项
```

专项测试按改动内容补充。全部通过才算完成。

## 提交粒度

一个需求一个提交。`9d0eb5a` 曾把三个缺陷修复、一个新功能、一次文案替换塞进同一个提交，事后回溯「哪个改动对应哪个需求」要翻 diff 才能分清。
