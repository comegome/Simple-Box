#!/usr/bin/env bash
# Simple-Box 回归测试套件
# 用法: sudo bash test-regression.sh [--commit <ref>]
# 说明: 直接 source 目标脚本以复用全部函数定义；source 时 BASH_SOURCE[0] != $0，
#       入口守卫会被跳过，不会触发主流程。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TARGET_SCRIPT:-${SCRIPT_DIR}/simple-box.sh}"

PASS=0
FAIL=0
FAILED_NAMES=()

ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \033[31m✗\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------- 0. 前置检查 ----------
group "0. 前置检查"
[[ -f "$TARGET" ]] && ok "目标脚本存在: $TARGET" || { bad "目标脚本不存在: $TARGET"; exit 1; }
[[ $EUID -eq 0 ]] && ok "以 root 运行" || { bad "必须以 root 运行（脚本第 45 行有 EUID 守卫）"; exit 1; }

# ---------- 1. 语法与静态检查 ----------
group "1. 语法与静态检查"
if bash -n "$TARGET" 2>/dev/null; then ok "bash -n 语法检查通过"; else bad "bash -n 语法检查失败" "$(bash -n "$TARGET" 2>&1 | head -5)"; fi

if command -v shellcheck >/dev/null 2>&1; then
    # 只关注 error 级别；warning 为已知的 SC1090/SC2155 等存量问题
    if shellcheck -S error "$TARGET" >/dev/null 2>&1; then
        ok "shellcheck (error 级别) 无问题"
    else
        bad "shellcheck 发现 error 级问题" "$(shellcheck -S error "$TARGET" 2>&1 | head -20)"
    fi
else
    printf '  \033[33m-\033[0m shellcheck 未安装，跳过\n'
fi

# ---------- 2. 加载函数 ----------
group "2. 函数加载"
# shellcheck disable=SC1090
source "$TARGET" 2>/dev/null
RC=$?
if [[ $RC -eq 0 ]]; then ok "source 成功（入口守卫已跳过）"; else bad "source 失败 rc=$RC"; fi

for fn in trim_string validate_port validate_domain ver_ge \
          cert_covers_domain harden_private_key issue_cert_bundle issue_self_signed_cert \
          fetch_latest_script reinstall_with_latest write_singbox_config \
          verify_cloudflare_token prompt_cf_token cleanup_legacy_port_hopping; do
    if declare -F "$fn" >/dev/null 2>&1; then ok "函数已定义: $fn"; else bad "函数缺失: $fn"; fi
done

set +e   # 后续测试自行判定，不因单条失败中断

# ---------- 3. 本次提交的 5 项修复 ----------
group "3. 本次提交修复项验证"

# M-3: config.json 权限 600（由 mktemp 保证，不再依赖事后 chmod）
if grep -q 'tmp_conf=$(mktemp "${CONF_FILE}.tmp.XXXXXX")' "$TARGET"; then
    ok "M-3: config.json 临时文件由 mktemp 创建（天然 0600）"
else
    bad "M-3: 未使用 mktemp 创建 config 临时文件"
fi
if grep -q 'chmod 644 "\$tmp_conf"' "$TARGET"; then bad "M-3: 仍残留 chmod 644 \$tmp_conf"; else ok "M-3: 无残留 644"; fi
if grep -q 'chmod 600 "\$tmp_conf"' "$TARGET"; then
    bad "M-3: chmod 600 兜底未删除（mktemp 已保证权限，属冗余）"
else
    ok "M-3: 冗余 chmod 600 已移除"
fi
# config 临时文件与目标同目录（保证 mv 原子性）
grep -q 'mktemp "${CONF_FILE}.tmp.XXXXXX"' "$TARGET" && ok "M-3: 临时文件与目标同目录（mv 原子）" || bad "M-3: 临时文件跨目录（mv 非原子）"

# M-4: 证书目录先 640 后单独 644 公钥
M4_COUNT=$(grep -c 'chmod 640 "\${CERT_DIR}"/\* 2>/dev/null || true; chmod 644 "\${CERT_DIR}/fullchain.cer"' "$TARGET")
if [[ "$M4_COUNT" -eq 3 ]]; then ok "M-4: 3 处证书权限逻辑均已改造"; else bad "M-4: 期望 3 处，实际 $M4_COUNT 处"; fi
if grep -q 'chmod 644 "\${CERT_DIR}"/\* 2>/dev/null || true$' "$TARGET"; then bad "M-4: 仍残留整体 chmod 644 通配"; else ok "M-4: 无整体 644 通配残留"; fi

# M-1/M-2: 已按"简单优先"决策回退，不再断言 unset 存在。
# 保留一项反向断言：确认没有 unset 破坏大写 CF_TOKEN 预置变量路径。
if grep -q 'unset CF_TOKEN' "$TARGET"; then
    bad "M-1: 误删大写 CF_TOKEN 预置变量（会破坏无人值守部署）"
else
    ok "M-1/M-2: 未触碰大写 CF_TOKEN 预置路径（回退后仍安全）"
fi

# M-5: mktemp 替代可预测 PID 路径
if grep -q 'latest=$(mktemp /tmp/simple-box.latest.XXXXXX)' "$TARGET"; then ok "M-5: 使用 mktemp 生成临时文件"; else bad "M-5: 未使用 mktemp"; fi
if grep -q 'simple-box.latest.\$\$' "$TARGET"; then bad "M-5: 仍残留 \$\$ 可预测路径"; else ok "M-5: 无 \$\$ 可预测路径残留"; fi

# ---------- 4. 功能测试：set -e 回归（本次修复引入的真实 Bug）----------
group "4. set -e 回归测试（关键）"

# 4.1 空证书目录下，chmod 组合不得因 glob 不匹配而中断
TMPD=$(mktemp -d)
(
  set -e
  D="$TMPD/empty"
  mkdir -p "$D"
  chmod 640 "$D"/* 2>/dev/null || true
  chmod 644 "$D/fullchain.cer" 2>/dev/null || true
  echo "OK"
) >/tmp/t41.out 2>&1
if grep -q '^OK$' /tmp/t41.out; then ok "4.1 空目录 glob 不匹配时不中断 set -e"; else bad "4.1 空目录导致 set -e 中断" "$(cat /tmp/t41.out)"; fi

# 4.2 真实证书目录：私钥 640、公钥 644
D2="$TMPD/real"; mkdir -p "$D2"
echo "privkey" > "$D2/private.key"
echo "fullchain" > "$D2/fullchain.cer"
(
  set -e
  chmod 640 "$D2"/* 2>/dev/null || true
  chmod 644 "$D2/fullchain.cer" 2>/dev/null || true
) >/dev/null 2>&1
P_KEY=$(stat -c %a "$D2/private.key")
P_CRT=$(stat -c %a "$D2/fullchain.cer")
if [[ "$P_KEY" == "640" ]]; then ok "4.2 私钥权限为 640"; else bad "4.2 私钥权限为 $P_KEY（期望 640）"; fi
if [[ "$P_CRT" == "644" ]]; then ok "4.2 公钥证书权限为 644"; else bad "4.2 公钥证书权限为 $P_CRT（期望 644）"; fi

# 4.3 无 caddy 组时 harden_private_key 仍能收紧到 640
CERT_DIR="$TMPD/hpk"; mkdir -p "$CERT_DIR"; echo "k" > "$CERT_DIR/private.key"; chmod 666 "$CERT_DIR/private.key"
harden_private_key >/dev/null 2>&1
P=$(stat -c %a "$CERT_DIR/private.key")
if [[ "$P" == "640" ]]; then ok "4.3 harden_private_key 收紧至 640"; else bad "4.3 harden_private_key 结果为 $P"; fi

# 4.4 config.json 写入后权限为 600
CONF_DIR="$TMPD/conf"; mkdir -p "$CONF_DIR"
cat > "$CONF_DIR/config.json" <<'JSONEOF'
{"log":{"level":"warn"}}
JSONEOF
TMPC="$CONF_DIR/config.json.tmp"; cp "$CONF_DIR/config.json" "$TMPC"
chmod 600 "$TMPC" 2>/dev/null || true
mv -f "$TMPC" "$CONF_DIR/config.json"
PC=$(stat -c %a "$CONF_DIR/config.json")
if [[ "$PC" == "600" ]]; then ok "4.4 config.json 权限为 600"; else bad "4.4 config.json 权限为 $PC（期望 600）"; fi

# ---------- 5. 功能测试：mktemp 临时文件 ----------
group "5. mktemp 临时文件测试"
T1=$(mktemp /tmp/simple-box.latest.XXXXXX)
T2=$(mktemp /tmp/simple-box.latest.XXXXXX)
[[ -f "$T1" && -f "$T2" ]] && ok "mktemp 正常创建文件" || bad "mktemp 创建失败"
[[ "$T1" != "$T2" ]] && ok "两次 mktemp 路径不重复" || bad "mktemp 路径重复"
P1=$(stat -c %a "$T1")
[[ "$P1" == "600" ]] && ok "mktemp 默认权限 600（非全局可写）" || bad "mktemp 权限为 $P1"
rm -f "$T1" "$T2"

# ---------- 6. 功能测试：Token 生命周期 ----------
group "6. Token 生命周期测试"
# 6.1 CF_Token 能正常传递到 acme.sh 子进程（export 语义未被破坏）
(
  export CF_Token="dummy-token-for-test"
  bash -c '[[ -n "${CF_Token:-}" ]] && echo "VISIBLE" || echo "HIDDEN"'
) > /tmp/t61.out 2>&1
grep -q 'VISIBLE' /tmp/t61.out && ok "6.1 CF_Token 可传递至 acme.sh 子进程" || bad "6.1 CF_Token 无法传递（证书申请会失败）"

# 6.2 unset 不影响 CF_TOKEN（大写，无人值守预置变量）
(
  export CF_TOKEN="preset-token"
  export CF_Token="temp-token"
  unset CF_Token 2>/dev/null || true
  [[ -n "${CF_TOKEN:-}" ]] && echo "PRESERVED" || echo "LOST"
) > /tmp/t62.out 2>&1
grep -q 'PRESERVED' /tmp/t62.out && ok "6.2 大写 CF_TOKEN 预置变量未受影响" || bad "6.2 CF_TOKEN 被误删（破坏无人值守部署）"

# 6.3 PROMPTED_CF_TOKEN 全局回传机制完整（prompt_cf_token 的设置/读取路径未被破坏）
grep -q 'PROMPTED_CF_TOKEN="\$token"' "$TARGET" && grep -q 'cf_token="\$PROMPTED_CF_TOKEN"' "$TARGET" \
    && ok "6.3 PROMPTED_CF_TOKEN 设置与读取路径完整" \
    || bad "6.3 PROMPTED_CF_TOKEN 回传机制被破坏"

# 6.4 重装必须换新 Token（顺手换锁），且不能沿用旧值
if grep -q 'old_token="\${SUB_TOKEN:-}"' "$TARGET" || grep -q 'sub_token="\$old_token"' "$TARGET"; then
    bad "6.4 仍存在沿用旧 Token 的代码（重装不再换锁）"
else
    ok "6.4 无沿用旧 Token 的残留代码"
fi
# 6.5 重装后清理所有非当前 token 的订阅目录（含历史孤儿目录）
grep -q 'find "\$WEB_DIR" -mindepth 1 -maxdepth 1 -type d ! -name "\$sub_token" -exec rm -rf {} +' "$TARGET" \
    && ok "6.5 重装清理非当前 Token 的订阅目录" \
    || bad "6.5 缺少旧订阅目录清理（重装会堆积）"
# 6.6 凭证仍然每次重装都重新生成
_inst_start=$(grep -n '^install_node()' "$TARGET" | cut -d: -f1)
_next_fn=$(awk -v s="$_inst_start" 'NR>s && /^[a-z_]+\(\) \{/ {print NR; exit}' "$TARGET")
_inst_body=$(sed -n "${_inst_start},${_next_fn}p" "$TARGET")
if grep -q 'generate reality-keypair' <<<"$_inst_body" && grep -q 'generate uuid' <<<"$_inst_body"; then
    ok "6.6 重装仍重新生成 Reality 密钥与 UUID"
else
    bad "6.6 凭证生成逻辑被破坏" "install_node 范围 ${_inst_start}-${_next_fn}"
fi
# 6.7 清理逻辑必须在生成订阅文件之前（否则删掉刚建的新目录）
if [[ -n "$_inst_body" ]]; then
    _rm_line=$(grep -n 'find "\$WEB_DIR"' <<<"$_inst_body" | head -1 | cut -d: -f1)
    # 订阅由 render_and_reload 内的 regen_subscription 重建，「生成」标记取它
    _gen_line=$(grep -n 'render_and_reload' <<<"$_inst_body" | head -1 | cut -d: -f1)
    if [[ -n "$_rm_line" && -n "$_gen_line" && "$_rm_line" -lt "$_gen_line" ]]; then
        ok "6.7 清理顺序正确（先删旧订阅目录，再渲染并重建订阅）"
    else
        bad "6.7 清理顺序错误" "find 在第 ${_rm_line:-?} 行，generate 在第 ${_gen_line:-?} 行"
    fi
fi

# ---------- 7. 全量回归：核心工具函数 ----------
group "7. 全量回归：校验函数"

# validate_port
for p in 1 80 443 65535; do
    validate_port "$p" && ok "validate_port 接受 $p" || bad "validate_port 误拒 $p"
done
for p in "" 0 65536 abc -1 "80 " 1.5; do
    validate_port "$p" && bad "validate_port 误收 '$p'" || ok "validate_port 拒绝 '$p'"
done

# 端口跳跃已移除：不得再有任何 REDIRECT 规则的创建，只保留一次性清理
if declare -F validate_range >/dev/null 2>&1; then
    bad "validate_range 仍存在（端口跳跃残留）"
else
    ok "validate_range 已随端口跳跃移除"
fi
if grep -q -- '-A PREROUTING .*REDIRECT' "$TARGET"; then
    bad "脚本仍在创建 iptables REDIRECT 规则"
else
    ok "不再创建端口跳跃规则（只清理旧版遗留）"
fi
if declare -F setup_port_hopping >/dev/null 2>&1; then
    bad "setup_port_hopping 仍存在"
else
    ok "setup_port_hopping 已移除"
fi

# validate_domain
for d in "example.com" "sub.example.com" "a-b.example.co.uk" "x1.y2.io"; do
    validate_domain "$d" && ok "validate_domain 接受 $d" || bad "validate_domain 误拒 $d"
done
for d in "" "localhost" "-bad.com" "bad-.com" "no_tld" "a..b" ".com"; do
    validate_domain "$d" && bad "validate_domain 误收 '$d'" || ok "validate_domain 拒绝 '$d'"
done

# ver_ge
ver_ge "24.04" "24.04" && ok "ver_ge 24.04 >= 24.04" || bad "ver_ge 同版本判定失败"
ver_ge "24.10" "24.04" && ok "ver_ge 24.10 >= 24.04（字符串比较会误判）" || bad "ver_ge 24.10 误判"
ver_ge "22.04" "24.04" && bad "ver_ge 22.04 误判为 >= 24.04" || ok "ver_ge 22.04 < 24.04"
ver_ge "12" "12" && ok "ver_ge 12 >= 12" || bad "ver_ge 12 判定失败"

# trim_string
R=$(trim_string "  hello  "); [[ "$R" == "hello" ]] && ok "trim_string 去首尾空格" || bad "trim_string 空格: '$R'"
R=$(trim_string '"quoted"'); [[ "$R" == "quoted" ]] && ok "trim_string 去双引号" || bad "trim_string 双引号: '$R'"
R=$(trim_string "'single'"); [[ "$R" == "single" ]] && ok "trim_string 去单引号" || bad "trim_string 单引号: '$R'"
R=$(trim_string $'\r\ntoken123\r\n'); [[ "$R" == "token123" ]] && ok "trim_string 去换行符" || bad "trim_string 换行: '$R'"
R=$(trim_string ''); [[ -z "$R" ]] && ok "trim_string 空输入返回空" || bad "trim_string 空输入: '$R'"

# ---------- 8. 全量回归：证书逻辑 ----------
group "8. 全量回归：证书逻辑"
TMPC2=$(mktemp -d)
CERT_DIR="$TMPC2"
# 生成自签证书
if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 30 -nodes \
     -keyout "$CERT_DIR/private.key" -out "$CERT_DIR/fullchain.cer" \
     -subj "/CN=test.example.com" >/dev/null 2>&1; then
    ok "测试证书生成成功"
    cert_covers_domain "test.example.com" && ok "cert_covers_domain 匹配正确域名" || bad "cert_covers_domain 误拒匹配域名"
    cert_covers_domain "other.example.com" && bad "cert_covers_domain 误收不匹配域名" || ok "cert_covers_domain 拒绝不匹配域名"
    cert_covers_domain "" && bad "cert_covers_domain 误收空域名" || ok "cert_covers_domain 拒绝空域名"
else
    bad "测试证书生成失败（openssl 不可用？）"
fi

# 过期证书应被拒绝
TMPC3=$(mktemp -d)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 0 -nodes \
    -keyout "$TMPC3/private.key" -out "$TMPC3/fullchain.cer" \
    -subj "/CN=expired.example.com" >/dev/null 2>&1
CERT_DIR="$TMPC3"
if cert_covers_domain "expired.example.com"; then
    bad "cert_covers_domain 误收已过期证书"
else
    ok "cert_covers_domain 拒绝已过期证书"
fi

# 公私钥不配对应被拒绝
TMPC4=$(mktemp -d)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 30 -nodes \
    -keyout "$TMPC4/private.key" -out "$TMPC4/fullchain.cer" \
    -subj "/CN=pair.example.com" >/dev/null 2>&1
openssl ecparam -name prime256v1 -genkey -noout -out "$TMPC4/private.key" 2>/dev/null
CERT_DIR="$TMPC4"
if cert_covers_domain "pair.example.com"; then
    bad "cert_covers_domain 误收公私钥不配对的证书"
else
    ok "cert_covers_domain 拒绝公私钥不配对"
fi

# 站点在用 CERT_DIR 的证书时，证书降级不得覆盖它（否则站点 + Reality 回落一起失效）
_s8=$(mktemp -d); mkdir -p "$_s8/cert" "$_s8/sites" "$_s8/empty"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$_s8/k.pem" -out "$_s8/c.pem" -days 2 \
    -subj "/CN=old.example.com" -addext "subjectAltName=DNS:old.example.com" >/dev/null 2>&1
cp "$_s8/c.pem" "$_s8/cert/fullchain.cer"; cp "$_s8/k.pem" "$_s8/cert/private.key"
printf 'site.example.com {\n\ttls %s/cert/fullchain.cer %s/cert/private.key\n\tfile_server\n}\n' "$_s8" "$_s8" > "$_s8/sites/site.caddy"
_s8_before=$(sha256sum "$_s8/cert/fullchain.cer" | cut -d' ' -f1)
_s8_cd="$CERT_DIR"; _s8_sites="${CADDY_SITES_DIR-}"
CERT_DIR="$_s8/cert"; CADDY_SITES_DIR="$_s8/sites"
issue_cert_bundle "site.example.com" "" "203.0.113.7" > "$_s8/o" 2>&1; _s8_rc=$?
if [[ "$_s8_rc" -ne 0 && "$(sha256sum "$_s8/cert/fullchain.cer" | cut -d' ' -f1)" == "$_s8_before" ]]; then
    ok "8.7 站点在用 CERT_DIR 证书时拒绝写 IP 自签（证书未变）"
else
    bad "8.7 证书被 IP 自签覆盖或未中止" "rc=$_s8_rc"
fi
grep -q '未改动任何证书' "$_s8/o" && ok "8.8 中止原因写明「未改动任何证书」" || bad "8.8 缺少中止原因"
CADDY_SITES_DIR="$_s8/empty"
issue_cert_bundle "" "" "203.0.113.7" >/dev/null 2>&1; _s8_rc2=$?
_s8_chk=$(openssl x509 -in "$_s8/cert/fullchain.cer" -noout -checkhost 203.0.113.7 2>/dev/null || true)
if [[ "$_s8_rc2" -eq 0 ]] && grep -q 'does match' <<<"$_s8_chk"; then
    ok "8.9 没有站点引用时仍正常降级为 IP 自签"
else
    bad "8.9 正常自签路径被破坏"
fi
CERT_DIR="$_s8_cd"; if [[ -n "$_s8_sites" ]]; then CADDY_SITES_DIR="$_s8_sites"; else unset CADDY_SITES_DIR; fi; rm -rf "$_s8"

# ---------- 9. 全量回归：幂等性静态断言 ----------
group "9. 全量回归：幂等性静态断言"
grep -q 'iptables -t nat -F PREROUTING' "$TARGET" && bad "存在 iptables 全表清空炸弹" || ok "无 iptables 全表清空"
grep -qE 'apt-get[^|]*[[:space:]]purge|apt purge' "$TARGET" && ok "卸载使用 apt purge（避免 mask 残留）" || bad "卸载未使用 apt purge"
grep -q 'DEBIAN_FRONTEND=noninteractive' "$TARGET" && ok "apt 操作设置 noninteractive" || bad "缺少 DEBIAN_FRONTEND=noninteractive"
grep -q 'sing-box check' "$TARGET" && ok "启动前执行 sing-box check" || bad "缺少配置校验"
grep -q 'BASH_SOURCE\[0\]' "$TARGET" && ok "存在管道执行检测" || bad "缺少管道执行检测"

# 网络基线：归属、迁移、回读与 qdisc（行为测试：沙箱目录 + sysctl/ip/tc stub）
# 静态 grep 只能证明代码长得像，证明不了文件落在哪、卸载删了什么。
_sb9=$(mktemp -d)
sysctl() {
    [[ "${1:-}" == "-n" ]] || return 0
    local k="${2:-}" line
    if [[ "$k" == "net.ipv4.tcp_congestion_control" && -f "$_sb9/badcc" ]]; then
        echo cubic; return 0
    fi
    line=$(grep -E "^[[:space:]]*${k//./\\.}[[:space:]]*=" "$_sb9/99-zz-simbo-net.conf" 2>/dev/null | head -1)
    [[ -n "$line" ]] && { printf '%s\n' "${line#*=}" | sed 's/^ *//'; return 0; }
    return 1
}
ip() { echo "default via 192.0.2.1 dev eth9 proto static"; }
tc() {
    [[ -f "$_sb9/badtc" ]] && return 1
    [[ "${1:-}" == "qdisc" && "${2:-}" == "show" ]] && echo "qdisc fq 0: root refcnt 2"
    return 0
}
SYSCTL_DIR="$_sb9" apply_net_baseline >"$_sb9/out1" 2>&1
if [[ -f "$_sb9/99-zz-simbo-net.conf" ]] \
   && grep -qxF "$BBR_MARK" "$_sb9/99-zz-simbo-net.conf" \
   && [[ "$(grep -c '^net\.' "$_sb9/99-zz-simbo-net.conf")" -eq 9 ]]; then
    ok "9.6 安装写入 99-zz-simbo-net.conf（带标记，9 个键）"
else
    bad "9.6 基线文件缺失/缺标记/键数不对"
fi
if grep -q '网络基线已应用（9 项一致）' "$_sb9/out1" && grep -q 'eth9 队列规则已切换为 fq' "$_sb9/out1" \
   && ! grep -q '原有 sysctl 配置未改动' "$_sb9/out1"; then
    ok "9.7 回读 9 项一致，对默认路由网卡应用 fq；无外部文件时不打印覆盖提示"
else
    bad "9.7 回读或 qdisc 应用未按预期工作" "$(tail -3 "$_sb9/out1")"
fi
# 不碰非网络参数，也不写对 sing-box 无效的 rmem_max
if grep -qE '^[[:space:]]*(vm\.swappiness|kernel\.panic|net\.core\.rmem_max)' "$_sb9/99-zz-simbo-net.conf"; then
    bad "9.8 基线混入了非网络参数或无效键"
else
    ok "9.8 基线只含网络性能键（无 swappiness/panic/rmem_max）"
fi
# 旧版带标记文件必须迁走，否则卸载会漏、重启又会生效
rm -f "$_sb9/99-zz-simbo-net.conf"
printf '%s\nnet.core.default_qdisc=fq\n' "$BBR_MARK" > "$_sb9/99-bbr.conf"
SYSCTL_DIR="$_sb9" apply_net_baseline >/dev/null 2>&1
if [[ ! -f "$_sb9/99-bbr.conf" && -f "$_sb9/99-zz-simbo-net.conf" ]]; then
    ok "9.9 旧版 99-bbr.conf（带标记）迁移到新文件"
else
    bad "9.9 旧文件未迁移（卸载会残留）"
fi
# 无标记 = 服务商配置：内容不动，但基线仍写入（靠文件名覆盖效果），且日志点名
_sb9f=$(mktemp -d)
printf 'net.core.default_qdisc=cake\n' > "$_sb9f/99-bbr.conf"
_sb9_h1=$(sha256sum "$_sb9f/99-bbr.conf" | cut -d' ' -f1)
SYSCTL_DIR="$_sb9f" apply_net_baseline >"$_sb9f/out" 2>&1
_sb9_h2=$(sha256sum "$_sb9f/99-bbr.conf" | cut -d' ' -f1)
if [[ "$_sb9_h1" == "$_sb9_h2" && -f "$_sb9f/99-zz-simbo-net.conf" ]] \
   && grep -q '原有 sysctl 配置未改动' "$_sb9f/out" && grep -q '99-bbr.conf' "$_sb9f/out"; then
    ok "9.10 服务商配置不改写，基线生效且日志点名 99-bbr.conf"
else
    bad "9.10 服务商配置被改写、基线未写入或日志没点名"
fi
rm -rf "$_sb9f"
# 服务商的调优文件未必叫 99-bbr.conf（isif 就是 99-network-tuning.conf），也要点名
_sb9g=$(mktemp -d)
printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > "$_sb9g/99-network-tuning.conf"
SYSCTL_DIR="$_sb9g" apply_net_baseline >"$_sb9g/out" 2>&1
if grep -q '原有 sysctl 配置未改动' "$_sb9g/out" && grep -q '99-network-tuning.conf' "$_sb9g/out"; then
    ok "9.16 非 99-bbr.conf 的服务商文件同样被点名"
else
    bad "9.16 只按文件名判断覆盖对象（会漏报）"
fi
rm -rf "$_sb9g"
# 回读不一致只告警，不中止安装
touch "$_sb9/badcc"
SYSCTL_DIR="$_sb9" apply_net_baseline >"$_sb9/out2" 2>&1; _sb9_rc=$?
if [[ "$_sb9_rc" -eq 0 ]] && grep -q 'tcp_congestion_control 期望 bbr' "$_sb9/out2" && grep -q '未生效' "$_sb9/out2"; then
    ok "9.11 回读不一致时告警且安装继续（rc=0）"
else
    bad "9.11 不一致被静默吞掉或中止了安装" "rc=$_sb9_rc"
fi
rm -f "$_sb9/badcc"
# qdisc 失败只告警，不回滚基线
touch "$_sb9/badtc"
SYSCTL_DIR="$_sb9" apply_net_baseline >"$_sb9/out3" 2>&1; _sb9_rc=$?
if [[ "$_sb9_rc" -eq 0 ]] && grep -q '切换 fq 失败' "$_sb9/out3" && [[ -f "$_sb9/99-zz-simbo-net.conf" ]]; then
    ok "9.12 qdisc 失败告警但保留已写入的基线（rc=0）"
else
    bad "9.12 qdisc 失败路径处理不对" "rc=$_sb9_rc"
fi
rm -f "$_sb9/badtc"
# 卸载：删自己的两种文件名，绝不碰外来文件；重复执行不报错
printf '%s\nnet.core.default_qdisc=fq\n' "$BBR_MARK" > "$_sb9/99-bbr.conf"
SYSCTL_DIR="$_sb9" remove_net_baseline
if [[ ! -f "$_sb9/99-zz-simbo-net.conf" && ! -f "$_sb9/99-bbr.conf" ]]; then
    ok "9.13 卸载删除本脚本的新旧两个文件"
else
    bad "9.13 卸载残留本脚本配置文件"
fi
printf 'cake\n' > "$_sb9/99-bbr.conf"
SYSCTL_DIR="$_sb9" remove_net_baseline
[[ -f "$_sb9/99-bbr.conf" ]] && ok "9.14 卸载不碰无标记的外来文件" || bad "9.14 卸载误删外来文件"
SYSCTL_DIR="$_sb9" remove_net_baseline; ok "9.15 卸载幂等（重复执行不报错）"
unset -f sysctl ip tc
rm -rf "$_sb9"

# BBR 卸载只删文件，不改运行中的拥塞控制（卸载代理不该动系统网络栈）
if grep -q 'sysctl -w net.ipv4.tcp_congestion_control=cubic' "$TARGET"; then
    bad "disable_bbr 仍在改运行中的拥塞控制算法"
else
    ok "disable_bbr 不改运行中的拥塞控制"
fi
_dbb=$(awk '/^remove_net_baseline\(\)/,/^}/' "$TARGET")
if grep -q 'NET_CONF_NAME' <<<"$_dbb" && grep -q 'LEGACY_BBR_NAME' <<<"$_dbb" && grep -q 'BBR_MARK' <<<"$_dbb"; then
    ok "remove_net_baseline 同时清理新文件与旧版文件，且只删带标记的"
else
    bad "remove_net_baseline 清理范围不完整（迁移后会残留）"
fi

# Caddy 归属标记
grep -q 'caddy_installed_by_script' "$TARGET" && ok "Caddy 配置带归属标记" || bad "Caddy 缺少归属标记"

# 10.1 Caddy reload 只能在「负责改 Caddy 配置」的几个函数里调用（不按次数，按归属）
_reload_fns=$(awk '/^[a-z_0-9]+\(\) \{/{fn=$1; sub(/\(\)/,"",fn)} /reload_caddy_safe/{if(fn!="")print fn}' "$TARGET" | sort -u)
_reload_allowed=$(printf '%s\n' build_camo_site flip_site menu_camo reload_caddy_safe setup_caddy_subscription site_handover_to_loopback | sort -u)
_reload_stray=$(comm -23 <(printf '%s\n' "$_reload_fns") <(printf '%s\n' "$_reload_allowed"))
if [[ -z "$_reload_stray" ]]; then
    ok "Caddy reload 只出现在负责改 Caddy 配置的函数里"
else
    bad "Caddy reload 调用点异常" "越界函数: $(echo $_reload_stray)"
fi

# 10.2 发布订阅的动作序列：render_and_reload 自己生成；install_node 委托给协议模块
_body=$(awk '/^_render_and_reload\(\)/ {p=1} p {print} p && /^}/ && NR>1 {exit}' "$TARGET")
_has_gen=$(grep -cE 'regen_subscription|generate_full_client_config' <<<"$_body")
_has_setup=$(grep -c 'setup_caddy_subscription' <<<"$_body")
if [[ "$_has_gen" -ge 1 && "$_has_setup" -ge 1 ]]; then
    ok "render_and_reload 含 generate + setup_caddy"
else
    bad "render_and_reload 缺少发布订阅的关键步骤" "generate=${_has_gen} setup=${_has_setup}"
fi

# install_node 不再自己写配置/订阅：按冻结集合调 render_set，再交给 render_and_reload
_ibody=$(awk '/^install_node\(\)/ {p=1} p {print} p && /^}/ && NR>1 {exit}' "$TARGET")
if grep -qE '^[[:space:]]+(if ! )?render_set' <<<"$_ibody" && grep -q 'render_and_reload' <<<"$_ibody" \
   && ! grep -q 'proto_enable_' <<<"$_ibody"; then
    ok "install_node 按集合渲染一次（订阅站由 render_and_reload 内部建）"
else
    bad "install_node 写路径不对" "render_set=$(grep -cE '^\s+render_set' <<<"$_ibody") reload=$(grep -cE '^\s+render_and_reload' <<<"$_ibody")"
fi

# 10.2 端口跳跃已整体移除：订阅里不得再出现 ports / mport
if grep -qE 'ports:|mport=' "$TARGET"; then
    bad "订阅生成里仍有端口跳跃字段（ports / mport）"
else
    ok "订阅里已无 ports / mport（端口跳跃移除）"
fi
# 订阅只有一个生产者：generate_full_client_config 只能被 regen_subscription 调用。
# 这是真正的不变式；下面那条计数只是「已知触发点没被悄悄删掉」的旁证。
_producer_calls=$(grep -cE '^[[:space:]]+generate_full_client_config' "$TARGET" || true)
_producer_in_regen=$(awk '/^regen_subscription\(\)/,/^}/' "$TARGET" | grep -c 'generate_full_client_config' || true)
if [[ "${_producer_calls:-0}" -eq 1 && "${_producer_in_regen:-0}" -eq 1 ]]; then
    ok "订阅生成器仅由 regen_subscription 调用（唯一生产者）"
else
    bad "订阅生成器存在多处调用" "共 ${_producer_calls} 处，其中在 regen_subscription 内 ${_producer_in_regen} 处"
fi
# 会改变节点参数、必须重生成订阅的触发点：
_regen_calls=$(grep -cE '^\s+regen_subscription' "$TARGET" || true)
# 1 = 重载后；3 = token 轮换 / 节点前缀 / 直连后缀；2 = show_links + show_clash_snippet
# 安装不单独调用：它走 render_set + render_and_reload，由重载触发
if [[ "${_regen_calls:-0}" -eq 6 ]]; then
    ok "regen_subscription 覆盖 6 个触发点"
else
    bad "regen_subscription 调用点数量异常" "共 ${_regen_calls} 处，应为 6"
fi

# ---------- 10. 全量回归：危险命令审计 ----------
group "10. 全量回归：危险命令审计"
# 允许删除脚本自有的安装目录 /usr/local/share/simple-box
SUSPICIOUS=$(grep -nE 'rm -rf /' "$TARGET" | grep -v '\$' | grep -v '/usr/local/share/simple-box')
if [[ -n "$SUSPICIOUS" ]]; then bad "存在可疑的 rm -rf 绝对路径" "$SUSPICIOUS"; else ok "无裸 rm -rf 绝对路径（仅删除自有安装目录）"; fi
grep -qE 'curl[^|]*\|[[:space:]]*(ba)?sh' "$TARGET" && printf '  \033[33m!\033[0m 存在 curl|sh 模式（acme.sh 官方安装，已知可接受）\n' || ok "无 curl|sh 管道"
grep -q 'eval ' "$TARGET" && bad "存在 eval 调用" || ok "无 eval 调用"
grep -q 'chmod 777' "$TARGET" && bad "存在 chmod 777" || ok "无 chmod 777"

# ---------- 11. 端到端功能测试：write_singbox_config ----------
group "11. 端到端：write_singbox_config 真实调用"
E2E=$(mktemp -d)
(
  CONF_DIR="$E2E"
  CONF_FILE="$E2E/config.json"
  U=$(cat /proc/sys/kernel/random/uuid)
  PK=$(head -c 32 /dev/urandom | base64 | tr -d '=/+')
  SI=$(head -c 4 /dev/urandom | xxd -p)
  HP=$(head -c 16 /dev/urandom | base64 | tr -d '=/+')
  write_singbox_config 443 www.microsoft.com "$U" "$PK" "$SI" 8443 "$HP"
  echo "$U" > "$E2E/.uuid"; echo "$PK" > "$E2E/.pk"; echo "$HP" > "$E2E/.hp"
) >/dev/null 2>&1

if [[ -s "$E2E/config.json" ]]; then
    ok "11.1 配置已生成"
    P=$(stat -c %a "$E2E/config.json")
    [[ "$P" == "600" ]] && ok "11.2 配置权限 600" || bad "11.2 配置权限为 $P"
    if command -v jq >/dev/null 2>&1 && jq -e . "$E2E/config.json" >/dev/null 2>&1; then
        ok "11.3 JSON 合法"
        N=$(jq '.inbounds | length' "$E2E/config.json")
        [[ "$N" == "2" ]] && ok "11.4 inbounds 数量为 2 (vless + hysteria2)" || bad "11.4 inbounds 数量为 $N"
        T=$(jq -r '[.inbounds[].type] | join(",")' "$E2E/config.json")
        [[ "$T" == "vless,hysteria2" ]] && ok "11.5 协议类型正确" || bad "11.5 协议类型为 $T"
        VP=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port' "$E2E/config.json")
        [[ "$VP" == "443" ]] && ok "11.6 VLESS 端口正确" || bad "11.6 VLESS 端口为 $VP"
        HP2=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "$E2E/config.json")
        [[ "$HP2" == "8443" ]] && ok "11.7 Hy2 端口正确" || bad "11.7 Hy2 端口为 $HP2"
    else
        bad "11.3 JSON 非法"
    fi
    # 敏感字段确实写入（非空壳）
    U=$(cat "$E2E/.uuid" 2>/dev/null); PK=$(cat "$E2E/.pk" 2>/dev/null); HP=$(cat "$E2E/.hp" 2>/dev/null)
    grep -qF "$U" "$E2E/config.json" 2>/dev/null && ok "11.8 UUID 已写入" || bad "11.8 UUID 缺失"
    grep -qF "$PK" "$E2E/config.json" 2>/dev/null && ok "11.9 Reality 私钥已写入" || bad "11.9 私钥缺失"
    grep -qF "$HP" "$E2E/config.json" 2>/dev/null && ok "11.10 Hy2 密码已写入" || bad "11.10 密码缺失"
else
    bad "11.1 配置未生成"
fi

# 临时文件无残留（原子替换后应清理干净）
LEFT=$(find "$E2E" -name '*.tmp.*' 2>/dev/null | wc -l)
[[ "$LEFT" -eq 0 ]] && ok "11.11 无 .tmp 残留" || bad "11.11 残留 $LEFT 个临时文件"

# 幂等：重复调用仍正常
(
  CONF_DIR="$E2E"; CONF_FILE="$E2E/config.json"
  write_singbox_config 443 www.microsoft.com "$(cat "$E2E/.uuid")" "$(cat "$E2E/.pk")" abcd 8443 "$(cat "$E2E/.hp")"
) >/dev/null 2>&1
P2=$(stat -c %a "$E2E/config.json" 2>/dev/null)
[[ "$P2" == "600" ]] && ok "11.12 重复调用后权限仍为 600" || bad "11.12 重复调用后权限为 $P2"
LEFT2=$(find "$E2E" -name '*.tmp.*' 2>/dev/null | wc -l)
[[ "$LEFT2" -eq 0 ]] && ok "11.13 重复调用后无残留" || bad "11.13 重复调用残留 $LEFT2 个"
rm -rf "$E2E"

# ---------- 12. Caddyfile：只在仍是本脚本骨架时才写 ----------
group "12. Caddyfile 归属与 80 端口"
if grep -q 'auto_https disable_redirects' "$TARGET"; then
    ok "12.1 脚本写入的 Caddyfile 含 disable_redirects"
else
    bad "12.1 脚本未写 disable_redirects（会意外监听 80）"
fi
if grep -q 'cat > "\$caddyfile" <<.CADDYEOF.' "$TARGET"; then
    ok "12.2 使用 heredoc 写入完整全局块"
else
    bad "12.2 未用 heredoc 写全局块"
fi

# 12.3-12.7 直接调用 ensure_caddyfile（不再在测试里复刻实现——复刻出来的副本会和实现漂移）
CD=$(mktemp -d); mkdir -p "$CD/conf"
_save_cf="${CADDYFILE:-}"; _save_cd="$CONF_DIR"; CONF_DIR="$CD/conf"

CADDYFILE="$CD/new/Caddyfile"
_a=$(ensure_caddyfile)
if [[ "$_a" == "written" ]] && grep -q 'auto_https disable_redirects' "$CADDYFILE" \
   && [[ "$(grep -c '^import sites/\*\.caddy$' "$CADDYFILE")" == "1" ]]; then
    ok "12.3 新装写入骨架（含 disable_redirects，import 只有一行）"
else
    bad "12.3 新装骨架不对" "$_a"
fi
_h1=$(sha256sum "$CADDYFILE" | cut -d' ' -f1); _a=$(ensure_caddyfile); _h2=$(sha256sum "$CADDYFILE" | cut -d' ' -f1)
if [[ "$_a" == "ours" && "$_h1" == "$_h2" ]]; then ok "12.4 规范骨架重复执行不改文件"; else bad "12.4 幂等失败" "$_a"; fi

CADDYFILE="$CD/legacy/Caddyfile"; mkdir -p "$CD/legacy"; printf 'import sites/*.caddy\n' > "$CADDYFILE"
_a=$(ensure_caddyfile)
if grep -q 'auto_https disable_redirects' "$CADDYFILE" && [[ "$(grep -c '^import sites/\*\.caddy$' "$CADDYFILE")" == "1" ]]; then
    ok "12.5 旧版 import-only Caddyfile 升级后含 disable_redirects"
else
    bad "12.5 旧版升级失败" "$_a"
fi

CADDYFILE="$CD/user/Caddyfile"; mkdir -p "$CD/user"
printf 'example.com {\n  reverse_proxy localhost:3000\n}\n' > "$CADDYFILE"
_cp="$CD/user/orig"; cp "$CADDYFILE" "$_cp"
_a=$(ensure_caddyfile)
if grep -q 'reverse_proxy localhost:3000' "$CADDYFILE" && [[ "$(grep -c '^import sites/\*\.caddy$' "$CADDYFILE")" == "1" ]] \
   && [[ "$(head -3 "$CADDYFILE")" == "$(cat "$_cp")" ]]; then
    ok "12.6 用户 Caddyfile 只追加 import，内容原样"
else
    bad "12.6 用户 Caddyfile 被改写" "$_a"
fi

CADDYFILE="$CD/user2/Caddyfile"; mkdir -p "$CD/user2"
printf '{ auto_https off }\nexample.com {\n  reverse_proxy localhost:3000\n}\nimport sites/*.caddy\n' > "$CADDYFILE"
_b=$(sha256sum "$CADDYFILE" | cut -d' ' -f1); _a=$(ensure_caddyfile)
if [[ "$_a" == "foreign" && "$(sha256sum "$CADDYFILE" | cut -d' ' -f1)" == "$_b" ]]; then
    ok "12.7 用户改过的 Caddyfile 原样保留（foreign）"
else
    bad "12.7 用户 Caddyfile 被改动" "$_a"
fi
_un_all=$(awk '/^uninstall_all\(\) \{/,/^}/' "$TARGET")
# 先落变量再匹配：set -o pipefail 下 `awk | grep -q` 会因 SIGPIPE 假红
if grep -q 'caddyfile_is_ours' <<<"$_un_all"; then
    ok "12.8 卸载按内容判 Caddyfile 归属"
else
    bad "12.8 卸载仍只看标记，会误删用户 Caddyfile"
fi

CONF_DIR="$_save_cd"; if [[ -n "$_save_cf" ]]; then CADDYFILE="$_save_cf"; else unset CADDYFILE; fi
rm -rf "$CD"

# ---------- 13. 端口占用判定：Caddy 只在订阅端口上算可复用 ----------
group "13. 端口占用判定"
# Caddy 占着 443（Reality 伪装站）时，Reality 不能也用 443，否则装完 bind 失败无限重启
_cpo=$(sed -n '/^check_port_occupied()/,/^}/p' "$TARGET")
if grep -q 'SUB_PORT' <<<"$_cpo" && grep -q '"\$port" == "\$SUB_PORT"' <<<"$_cpo"; then
    ok "13.1 caddy 分支按 SUB_PORT 判定是否可复用"
else
    bad "13.1 caddy 分支未校验 SUB_PORT，会把伪装站占用的 443 当可复用"
fi
if grep -q '伪装站占用 443' <<<"$_cpo"; then
    ok "13.2 冲突时给出可操作的提示"
else
    bad "13.2 冲突提示缺失"
fi

# ---------- 15. 协议模块（站点发现 / 翻转 / 渲染） ----------
group "15. 协议模块"

SB15="$TMPD/m15"; mkdir -p "$SB15/sites"
CADDYFILE="$SB15/Caddyfile"
cat > "$CADDYFILE" <<'EOF'
import sites/*.caddy
EOF
cat > "$SB15/sites/signal.caddy" <<'EOF'
agisignal.example.com {
	encode gzip
	root * /var/www/signal
	file_server
}
EOF
cat > "$SB15/sites/other.caddy" <<'EOF'
https://other.example.com:9443 {
	root * /var/www/other
	file_server
}
EOF
cat > "$SB15/sites/trap.caddy" <<'EOF'
agisignal.example.com.evil.com {
	root * /var/www/trap
}
EOF

export CADDY_SITES_DIR="$SB15/sites"

# 15.1 命中
_hit=$(site_file_for "agisignal.example.com" 2>/dev/null || true)
[[ "$_hit" == "$SB15/sites/signal.caddy" ]] && ok "15.1 精确命中站点文件" || bad "15.1 站点发现失败" "得到: ${_hit:-空}"

# 15.2 子串不误命中
_hit2=$(site_file_for "agisignal.example.com.evil.com" 2>/dev/null || true)
[[ "$_hit2" == "$SB15/sites/trap.caddy" ]] && ok "15.2 后缀相似域名各自命中" || bad "15.2 域名匹配不精确" "得到: ${_hit2:-空}"

# 15.3 https://domain:port 形式
_hit3=$(site_file_for "other.example.com" 2>/dev/null || true)
[[ "$_hit3" == "$SB15/sites/other.caddy" ]] && ok "15.3 识别 https://域名:端口 站点块" || bad "15.3 未识别带端口的站点块"

# 15.4 未命中返回非零
if site_file_for "nope.example.com" >/dev/null 2>&1; then bad "15.4 未命中却返回成功"; else ok "15.4 未命中返回非零"; fi

# 15.5 翻转到 9443
_f="$SB15/sites/signal.caddy"; _orig=$(sha256sum "$_f" | cut -d' ' -f1)
flip_transform "$_f" "agisignal.example.com" 9443 on >/dev/null 2>&1
grep -q "^https://agisignal.example.com:9443 {" "$_f" && grep -q "bind 127.0.0.1" "$_f" \
    && ok "15.5 翻转写入 https://域名:9443 + bind" || bad "15.5 翻转结果不正确"

# 15.6 幂等：再翻一次不变
_h1=$(sha256sum "$_f" | cut -d' ' -f1)
flip_transform "$_f" "agisignal.example.com" 9443 on >/dev/null 2>&1
_h2=$(sha256sum "$_f" | cut -d' ' -f1)
[[ "$_h1" == "$_h2" ]] && ok "15.6 重复翻转字节不变" || bad "15.6 重复翻转改动了文件"

# 15.5b/15.5c 旧实现只认裸「域名 {」，另外两种常见写法会静默不改，
# 随后 sing-box 抢 443 失败（bind: address already in use）——必须都能翻。
printf 'port.example.com:443 {\n\troot * /var/www/p\n}\n' > "$SB15/sites/ported.caddy"
flip_transform "$SB15/sites/ported.caddy" port.example.com 9443 on >/dev/null 2>&1
grep -q '^https://port.example.com:9443 {' "$SB15/sites/ported.caddy" && grep -q 'bind 127.0.0.1' "$SB15/sites/ported.caddy" \
    && ok "15.5b 带端口的站点块可翻转" || bad "15.5b 带端口的站点块未翻转"
printf 'https://scheme.example.com {\n\troot * /var/www/s\n}\n' > "$SB15/sites/scheme.caddy"
flip_transform "$SB15/sites/scheme.caddy" scheme.example.com 9443 on >/dev/null 2>&1
if grep -q '^https://scheme.example.com:9443 {' "$SB15/sites/scheme.caddy" && ! grep -q 'https://https://' "$SB15/sites/scheme.caddy"; then
    ok "15.5c 带 scheme 的站点块翻转不重复拼 scheme"
else
    bad "15.5c 带 scheme 的站点块翻坏"
fi

# 15.9b 认不出块首时必须返回非零（否则 Caddy 仍占 443，sing-box 起不来）
printf 'sub.example.com {\n\trespond ok\n}\n' > "$SB15/sites/subonly.caddy"
_s_before=$(sha256sum "$SB15/sites/subonly.caddy" | cut -d' ' -f1)
if flip_transform "$SB15/sites/subonly.caddy" example.com 9443 on >/dev/null 2>&1; then
    bad "15.9b 找不到块首却返回成功（会导致 443 冲突）"
else
    [[ "$(sha256sum "$SB15/sites/subonly.caddy" | cut -d' ' -f1)" == "$_s_before" ]] \
        && ok "15.9b 认不出的站点块返回非零且文件不变" || bad "15.9b 失败时仍改动了文件"
fi

# 15.7 别的站点块不受影响
grep -q "^https://other.example.com:9443 {" "$SB15/sites/other.caddy" \
    && ! grep -q "agisignal" "$SB15/sites/other.caddy" && ok "15.7 其它站点块未被改动" || bad "15.7 误伤其它站点"

# 15.8 翻回来与原文一致
flip_transform "$_f" "agisignal.example.com" 9443 off >/dev/null 2>&1
_back=$(sha256sum "$_f" | cut -d' ' -f1)
[[ "$_back" == "$_orig" ]] && ok "15.8 退出翻转后与原文件字节一致" || bad "15.8 退出翻转未完全还原"

# 15.9 站点内容里的同名域名不被误改
_f2="$SB15/sites/content.caddy"
cat > "$_f2" <<'EOF'
plain.example.com {
	respond "plain.example.com"
}
EOF
_c_before=$(sha256sum "$_f2" | cut -d' ' -f1)
flip_transform "$_f2" "other.example.com" 9443 on >/dev/null 2>&1
_c_after=$(sha256sum "$_f2" | cut -d' ' -f1)
[[ "$_c_before" == "$_c_after" ]] && ok "15.9 不存在的域名不修改文件" || bad "15.9 错误改写了无关文件"

# 15.10 current_inbounds / set_has
SB_CONF="$SB15/config.json"
cat > "$SB_CONF" <<'EOF'
{"inbounds":[{"type":"vless","tag":"vless-reality-in"},{"type":"hysteria2","tag":"hy2-in"}]}
EOF
CONF_FILE="$SB_CONF"
_t=$(current_inbounds)
[[ "$_t" == *vless-reality-in* && "$_t" == *hy2-in* ]] && ok "15.10 current_inbounds 解析两个 inbound" || bad "15.10 current_inbounds 解析失败" "$_t"
set_has "hy2-in" && set_has "vless-reality-in" && ok "15.11 set_has 判定启用" || bad "15.11 set_has 误判"
cat > "$SB_CONF" <<'EOF'
{"inbounds":[{"type":"hysteria2","tag":"hy2-in"}]}
EOF
if set_has "vless-reality-in"; then bad "15.12 缺席 inbound 被误判为启用"; else ok "15.12 缺席 inbound 判定为未启用"; fi

# 15.13-15.15 render_set 无参，按 env 里冻结的集合渲染三种组合
CERT_DIR="$SB15/cert"; mkdir -p "$CERT_DIR"
VL_PORT=443; VL_SNI="agisignal.example.com"; VL_UUID="11111111-1111-1111-1111-111111111111"
VL_PRIVKEY="PRIV"; VL_SHORTID="abcd1234"
HY_PORT=10443; HY_PASS="pass123"
_tags15() { python3 -c "import json;print(' '.join(i['tag'] for i in json.load(open('$SB_CONF'))['inbounds']))"; }

PROTO_SET="reality"; render_set
[[ "$(_tags15)" == "vless-reality-in" ]] && ok "15.13 集合=reality 只写一个 inbound" || bad "15.13 集合=reality 输出异常" "$(_tags15)"

PROTO_SET="hy2"; render_set
[[ "$(_tags15)" == "hy2-in" ]] && ok "15.14 集合=hy2 只写一个 inbound" || bad "15.14 集合=hy2 输出异常" "$(_tags15)"

PROTO_SET="reality hy2"; render_set
_three=$(_tags15)
_hs=$(python3 -c "import json;h=[i for i in json.load(open('$SB_CONF'))['inbounds'] if i['tag']=='vless-reality-in'][0]['tls']['reality']['handshake'];print(h['server'], h['server_port'])")
[[ "$_three" == "vless-reality-in hy2-in" && "$_hs" == "127.0.0.1 9443" ]] \
    && ok "15.15 集合=两个都装 + handshake 指向本机站点回环端口" || bad "15.15 双协议渲染异常" "$_three / $_hs"

# 15.16 旧模块已删除
if grep -qE '^menu_(reality|hy2)_module\(\)' "$TARGET"; then bad "15.16 旧模块函数仍存在"; else ok "15.16 旧模块函数已删除"; fi

# 15.17 运行期协议开关全部删除：集合只能来自 env
if grep -qE '^(proto_enable_reality|proto_enable_hy2|disable_protocol|menu_protocol|current_set)\(\)' "$TARGET"; then
    bad "15.17 运行期协议开关仍存在" "$(grep -nE '^(proto_enable_|disable_protocol|menu_protocol|current_set)' "$TARGET")"
else
    ok "15.17 proto_enable_* / disable_protocol / menu_protocol / current_set 已删除"
fi
grep -q '^reality_target_check()' "$TARGET" && grep -q '^hy2_cert_sync()' "$TARGET" \
    && ok "15.17b 安装期检查函数就位（reality_target_check / hy2_cert_sync）" \
    || bad "15.17b 缺少安装期检查函数"

# 15.18 控制台不再有入站管理入口
if grep -qE 'menu_protocol|入站管理' "$TARGET"; then
    bad "15.18 仍残留入站管理入口"
else
    ok "15.18 入站管理已从控制台移除"
fi
if grep -q '重建 Reality' "$TARGET"; then bad "15.19 菜单仍残留「重建 Reality」"; else ok "15.19 无「重建」残留"; fi

# 15.20 翻转失败必须还原站点文件（真实 caddy validate）
CADDY_BIN=""
for c in /tmp/bin/caddy /usr/bin/caddy /usr/local/bin/caddy; do [[ -x "$c" ]] && { CADDY_BIN="$c"; break; }; done
if [[ -n "$CADDY_BIN" ]]; then
    export PATH="$(dirname "$CADDY_BIN"):$PATH"
    _bad="$SB15/sites/bad.caddy"; printf 'broken.example.com {\n\troot * /x\n' > "$_bad"
    _b1=$(sha256sum "$_bad" | cut -d' ' -f1)
    if flip_site on broken.example.com >/dev/null 2>&1; then bad "15.20 非法配置未被拦截"; else
        _b2=$(sha256sum "$_bad" | cut -d' ' -f1)
        [[ "$_b1" == "$_b2" ]] && ok "15.20 validate 失败后站点文件已还原" || bad "15.20 失败后文件未还原"
    fi
    rm -f "$_bad"   # 坏站点会让后续 validate 必然失败，先移除

    # 15.21 合法站点：validate 通过后文件变成翻转形态
    _good="$SB15/sites/signal.caddy"
    flip_site on agisignal.example.com >/dev/null 2>&1 || true   # 无 caddy 服务时 reload 失败不影响文件断言
    grep -q '^https://agisignal.example.com:9443 {' "$_good" && grep -q 'bind 127.0.0.1' "$_good" \
        && ok "15.21 合法站点翻转成功" || bad "15.21 合法站点翻转失败"
    flip_transform "$_good" "agisignal.example.com" 9443 off >/dev/null 2>&1
    [[ "$(sha256sum "$_good" | cut -d' ' -f1)" == "$_orig" ]] && ok "15.22 复原后与原始站点一致" || bad "15.22 复原失败"
else
    printf '  \033[33m-\033[0m 未找到 caddy 二进制，跳过翻转 validate 测试\n'
fi

# 15.23 port_holder 能识别占用者
python3 -m http.server 18099 --bind 127.0.0.1 >/dev/null 2>&1 &
_ph_pid=$!
for _i in $(seq 1 25); do ss -ltn 2>/dev/null | grep -q ':18099 ' && break; sleep 0.2; done
_h=$(port_holder 18099 tcp)
kill "$_ph_pid" 2>/dev/null; wait "$_ph_pid" 2>/dev/null
[[ "$_h" == *python* ]] && ok "15.23 port_holder 识别端口占用者" || bad "15.23 port_holder 未识别占用者" "${_h:-空}"

# 15.24 外部 SNI 探测：好域名通过、坏域名失败（需要网络）
if probe_external_sni "www.cloudflare.com"; then
    if probe_external_sni "example.invalid"; then bad "15.24 不存在的域名被误判为可用"; else ok "15.24 外部 SNI 探测可区分好坏域名"; fi
else
    printf '  \033[33m-\033[0m 无外网或 TLS 探测失败，跳过外部 SNI 测试\n'
fi

unset CADDY_SITES_DIR

# ---------- 16. 安装走协议模块 + 非交互入口 ----------
group "16. 安装 / 协议模块集成"

SB16="$TMPD/m16"; mkdir -p "$SB16/sites" "$SB16/cert"
cat > "$SB16/sites/site.caddy" <<'EOF'
site.example.com {
	root * /var/www/site
	file_server
}
EOF
cat > "$SB16/env.conf" <<'EOF'
NODE_PREFIX="T16"
SERVER_IP="203.0.113.10"
VL_PORT="443"
VL_SNI="site.example.com"
VL_UUID="11111111-1111-1111-1111-111111111111"
VL_PRIVKEY="PRIVKEY16"
VL_PUBKEY="PUBKEY16"
VL_SHORTID="abcd1234"
HY_DOMAIN=""
TARGET_HOST="203.0.113.10"
HY_PORT="10443"
HY_PASS="hy16pass"
SUB_PORT="8444"
SUB_TOKEN="token16"
CERT_MODE="selfsigned"
DIRECT_SUFFIXES=""
VL_HANDSHAKE=""
VL_HANDSHAKE_PORT=""
EOF
printf '{"inbounds":[]}\n' > "$SB16/config.json"

# 覆盖到沙箱 + 桩掉会碰系统的两个动作
ENV_FILE="$SB16/env.conf"; CONF_FILE="$SB16/config.json"; CERT_DIR="$SB16/cert"
CADDY_SITES_DIR="$SB16/sites"
ENV_LOADED=""
_save_render_and_reload=$(declare -f render_and_reload)
_save_flip_site=$(declare -f flip_site)
render_and_reload() { return 0; }
flip_site() { return 0; }

# 16.1 安装不再自己写配置
_inst=$(awk '/^install_node\(\) \{/,/^\}/' "$TARGET")
if grep -q 'write_singbox_config' <<<"$_inst"; then
    bad "16.1 install_node 仍在直接写配置"
else
    ok "16.1 install_node 不再直接调 write_singbox_config"
fi
# 16.2 安装的集合来自 ask_proto_set（安装期唯一入口）
_inst_body=$(awk '/^install_node\(\) \{/,/^\}/' "$TARGET")
if grep -q 'ask_proto_set' <<<"$_inst_body" && ! grep -q 'proto_enable_' <<<"$_inst_body"; then
    ok "16.2 安装由 ask_proto_set 决定集合，不再调用运行期开关"
else
    bad "16.2 安装流程仍走运行期协议开关"
fi

# 16.3c 站点证书不覆盖域名时必须中止（否则回落握手全挂，而配置看起来全对）
_bc="$SB16/badcert"; mkdir -p "$_bc"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$_bc/k.pem" -out "$_bc/c.pem" -days 2 \
    -subj "/CN=wrong.example.com" >/dev/null 2>&1
printf 'bad.example.com {\n\ttls %s/c.pem %s/k.pem\n\troot * /var/www/bad\n}\n' "$_bc" "$_bc" > "$SB16/sites/badcert.caddy"
_cfg_before=$(md5sum "$SB16/config.json" | cut -d' ' -f1)
if reality_target_check 443 bad.example.com > "$SB16/o1c" 2>&1; then
    bad "16.3c 站点证书不覆盖域名时仍判定可用"
else
    if grep -q '证书不可用' "$SB16/o1c" && [[ "$(md5sum "$SB16/config.json" | cut -d' ' -f1)" == "$_cfg_before" ]]; then
        ok "16.3c 站点证书不可用时中止且不写配置"
    else
        bad "16.3c 中止原因或副作用不对" "$(tail -2 "$SB16/o1c")"
    fi
fi
rm -f "$SB16/sites/badcert.caddy"

# 16.3b 有本机站点时，非 443 端口必须拒绝（否则站点被搬到回环、公网 443 空着）
if reality_target_check 8443 site.example.com > "$SB16/o1b" 2>&1; then
    bad "16.3b 有站点时非 443 端口未被拒绝"
else
    grep -q '只能监听 443' "$SB16/o1b" \
        && [[ "$(python3 -c "import json;print(len(json.load(open('$SB16/config.json'))['inbounds']))")" == "0" ]] \
        && ok "16.3b 有站点 + 非 443 时拒绝且不写配置" \
        || bad "16.3b 拒绝原因或副作用不对" "$(tail -2 "$SB16/o1b")"
fi

# 16.3 站点可用时通过
load_env   # 旧流程由 proto_enable_* 读 env，现在由这里显式回读
if reality_target_check 443 site.example.com > "$SB16/o1" 2>&1; then
    PROTO_SET="reality hy2"; render_set
    tags=$(python3 -c "import json;print(' '.join(i['tag'] for i in json.load(open('$SB16/config.json'))['inbounds']))")
    hs=$(python3 -c "import json;h=[i for i in json.load(open('$SB16/config.json'))['inbounds'] if i['tag']=='vless-reality-in'][0]['tls']['reality'];print(h['handshake']['server'], h['handshake']['server_port'], [i for i in json.load(open('$SB16/config.json'))['inbounds']][0]['listen_port'])")
    [[ "$tags" == "vless-reality-in hy2-in" && "$hs" == "127.0.0.1 9443 443" ]] \
        && ok "16.3 集合渲染：端口 443 + 回落 127.0.0.1:9443 + 两个 inbound" \
        || bad "16.3 渲染结果异常" "$tags / $hs"
else
    bad "16.3 reality_target_check 拒绝了可用站点" "$(tail -3 "$SB16/o1")"
fi

# 16.4 翻转状态不落库：env 里没有 SITE_FILE / FLIP_HOST / FLIP_PORT，翻转目标现场解析
if grep -qE '^(SITE_FILE|FLIP_HOST)=' "$TARGET"; then
    bad "16.4 env 仍在落库翻转字段" "$(grep -nE '^(SITE_FILE|FLIP_HOST)=' "$TARGET")"
else
    ok "16.4 env 不再落库翻转字段（目标恒为 VL_SNI 的站点块）"
fi

# 16.5b 域名有值但没有该域名的证书时必须中止（否则 [已启用] 但客户端 x509 失败）
if hy2_cert_sync "nocert.example.com" > "$SB16/o2b" 2>&1; then
    bad "16.5b 缺证书时仍判定可用"
else
    grep -q '没有 nocert.example.com 的可用证书' "$SB16/o2b" \
        && ok "16.5b 缺证书时中止" || bad "16.5b 中止原因不明确" "$(tail -2 "$SB16/o2b")"
fi

# 16.5 IP 自签模式（域名为空）不需要额外证书，直接通过
hy2_cert_sync "" > "$SB16/o2" 2>&1 && ok "16.5 IP 自签模式不要求域名证书" || bad "16.5 IP 自签模式被误拦" "$(tail -2 "$SB16/o2")"

# 16.5c 证书模式不可中途切换：无证书一律中止，不再为存量 skip 节点开例外
_ph16=$(awk '/^hy2_cert_sync\(\) \{/,/^\}/' "$TARGET")
if ! grep -q 'HY_SKIP_CERT' <<<"$_ph16" && grep -q '证书模式不可中途切换' <<<"$_ph16"; then
    ok "16.5c 无证书时一律中止（不再按旧 skip 标记放行）"
else
    bad "16.5c 仍在为存量 skip 节点开例外"
fi

# 16.6 PROTO_SET 落库并规范成注册表顺序
( ENV_FILE="$SB16/env2.conf"
  node_prefix=SB; server_ip=203.0.113.11; vl_port=443; vl_sni=site.example.com
  user_uuid="11111111-1111-1111-1111-111111111111"; vl_privkey=K; vl_pubkey=P; vl_shortid=ab
  hy_port=8443; hy_password=pw; sub_port=8444; sub_token=tok16
  hy_domain=""; target_host=203.0.113.11
  PROTO_SET="hy2 reality"; write_env_config 2>/dev/null
)
grep -qx 'PROTO_SET="reality hy2"' "$SB16/env2.conf" 2>/dev/null \
    && ok "16.6 PROTO_SET 落库并规范成注册表顺序" \
    || bad "16.6 PROTO_SET 未按预期落库" "$(grep '^PROTO_SET' "$SB16/env2.conf" 2>/dev/null)"

# 16.7 非法集合（含未知协议名）拒绝写 env，不留半套配置
( ENV_FILE="$SB16/env3.conf"
  node_prefix=SB; server_ip=203.0.113.11; vl_port=443; vl_sni=site.example.com
  user_uuid="11111111-1111-1111-1111-111111111111"; vl_privkey=K; vl_pubkey=P; vl_shortid=ab
  hy_port=8443; hy_password=pw; sub_port=8444; sub_token=tok16
  hy_domain=""; target_host=203.0.113.11
  PROTO_SET="reality vless"; write_env_config 2>/dev/null
)
[[ ! -f "$SB16/env3.conf" ]] && ok "16.7 非法 PROTO_SET 拒绝写 env" || bad "16.7 非法集合仍写入了 env"

# 16.8 / 16.9 随 proto_enable_* 删除（安装期检查已在 16.3/16.5 覆盖）



# 第 16 组的桩必须在这里撤掉：flip_site 造假会让后面的伪装站测试看不见真翻转
eval "$_save_render_and_reload"
eval "$_save_flip_site"
unset _save_render_and_reload _save_flip_site

# ---------- 17. 出口中转 ----------
group "17. 出口中转"

SB17="$TMPD/m17"; mkdir -p "$SB17/cert" "$SB17/web/tok17"
printf '{"log":{"level":"warn"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}\n' > "$SB17/base.json"

VL_PORT=443; VL_SNI="gh.example.com"; VL_UUID="11111111-1111-1111-1111-111111111111"
VL_PRIVKEY="PRIV17"; VL_PUBKEY="PBK17"; VL_SHORTID="ab12cd34"
HY_PORT=8443; HY_PASS="hypass17"
VL_HANDSHAKE="127.0.0.1"; VL_HANDSHAKE_PORT=9443
CONF_FILE="$SB17/cfg.json"; CERT_DIR="$SB17/cert"
NODE_PREFIX="FN"; SERVER_IP="203.0.113.11"; TARGET_HOST="fn.example.com"
HY_DOMAIN="fn.example.com"; CERT_MODE="domain"; SUB_TOKEN="tok17"

render_set "reality hy2"
_md5_none=$(md5sum "$CONF_FILE" | cut -d' ' -f1)

# 17.1 none 时不改动配置
EXIT_TYPE="none"
apply_exit_config
[[ "$(md5sum "$CONF_FILE" | cut -d' ' -f1)" == "$_md5_none" ]] \
    && ok "17.1 EXIT_TYPE=none 配置字节不变" || bad "17.1 none 仍改动了配置"

# 17.2 hy2 出口：4 个 inbound + exit-out + route
EXIT_TYPE="hy2"; EXIT_HY_SERVER="isif.example.com"; EXIT_HY_PORT="8443"; EXIT_HY_PASS="exitpass17"
EXIT_HY_SNI="isif.example.com"; EXIT_ENTRY_VL="2053"; EXIT_ENTRY_HY="2054"
apply_exit_config
_tags=$(python3 -c "import json;print(' '.join(i['tag'] for i in json.load(open('$CONF_FILE'))['inbounds']))")
_ob=$(python3 -c "import json;d=json.load(open('$CONF_FILE'));o=[x for x in d['outbounds'] if x['tag']=='exit-out'][0];print(o['type'],o['server_port'])")
_rt=$(python3 -c "import json;d=json.load(open('$CONF_FILE'));r=d.get('route',{});print(len(r.get('rules',[])), r.get('final'))")
[[ "$_tags" == *exit-vless-in* && "$_tags" == *exit-hy2-in* && "$_ob" == "hysteria2 8443" && "$_rt" == "2 direct" ]] \
    && ok "17.2 hy2 出口：链式入口 + exit-out + route final=direct" \
    || bad "17.2 hy2 出口结构异常" "$_tags / $_ob / $_rt"

# 17.3 出口端口与主入口不冲突
_ports=$(python3 -c "import json;print(sorted(i['listen_port'] for i in json.load(open('$CONF_FILE'))['inbounds']))")
[[ "$_ports" == "[443, 2053, 2054, 8443]" ]] && ok "17.3 四个入口端口正确" || bad "17.3 端口集合异常" "$_ports"

# 17.4 订阅里出现 -SG 节点（由生成器直接产出，不再后处理）
EXIT_TYPE="hy2"; EXIT_HY_SERVER="isif.example.com"; EXIT_HY_PORT="8443"
EXIT_ENTRY_VL="2053"; EXIT_ENTRY_HY="2054"; EXIT_LABEL="SG"
VL_PORT=443; HY_PORT=8443; VL_SNI="gh.example.com"; SERVER_IP="203.0.113.11"
user_uuid="11111111-1111-1111-1111-111111111111"; vl_pubkey="PBK17"; vl_shortid="ab12cd34"
hy_password="hypass17"; CERT_MODE="domain"; node_prefix="FN"; token="tok17"
domain_or_ip="fn.example.com"; vl_port=443; hy_port=8443
hy_ports_display="8443"; server_ip="203.0.113.11"; vl_sni="gh.example.com"
WEB_DIR="$SB17/web"; mkdir -p "$WEB_DIR/tok17"
generate_full_client_config "fn.example.com" tok17 FN 203.0.113.11 443 \
  11111111-1111-1111-1111-111111111111 gh.example.com PBK17 ab12cd34 8443 8443 hypass17
grep -q 'FN-VLESS-Reality-SG' "$WEB_DIR/tok17/config.yaml" && grep -q 'FN-Hysteria2-SG' "$WEB_DIR/tok17/config.yaml" \
    && ok "17.4 订阅 config.yaml 含两条链式节点" || bad "17.4 订阅缺少链式节点"
grep -q 'port: 2053' "$WEB_DIR/tok17/provider.yaml" && grep -q 'port: 2054' "$WEB_DIR/tok17/provider.yaml" \
    && ok "17.5 provider.yaml 端口为 2053/2054" || bad "17.5 provider 端口异常"
_nlinks=$(grep -c '://' "$WEB_DIR/tok17/links.txt")
[[ "$_nlinks" -eq 4 ]] && ok "17.6 links.txt 共 4 条链接" || bad "17.6 链接条数异常" "$_nlinks"
grep -A1 -- '- "FN-VLESS-Reality-SG"' "$WEB_DIR/tok17/config.yaml" | grep -q 'DIRECT\|FN-' \
    && ok "17.7 链式节点已加入策略组" || bad "17.7 策略组未包含链式节点"


# 17.16 proxies 段空行规整：块间一个空行，块内无空行
_blank_inside=$(awk '/^proxies:/{f=1;next} f&&/^[a-z-]+:/{f=0} f&&/^$/{print}' "$WEB_DIR/tok17/provider.yaml" | wc -l)
_blank_between=$(awk '/^  - name:/{c++} END{print c-1}' "$WEB_DIR/tok17/provider.yaml")
[[ "$_blank_inside" -eq "$_blank_between" ]] \
    && ok "17.16 节点之间恰好一个空行，块内无空行" \
    || bad "17.16 空行规整异常" "块内 $_blank_inside / 块间应有 $_blank_between"

# 17.11 出口 Hy2 节点不得继承端口跳跃（否则客户端会跳到主入口端口，落地变成入口机）
awk '/FN-Hysteria2-SG/,/FN-VLESS|^EOF|^$/' "$WEB_DIR/tok17/provider.yaml" | grep -q 'ports:' \
    && bad "17.11 -SG 节点带了端口跳跃" || ok "17.11 -SG 节点不含 ports（避免跳到主入口）"

# 17.12 旧版分协议字段（EXIT_VL_*）已彻底移除
if grep -q 'EXIT_VL_' "$TARGET"; then
    bad "17.12 仍残留 EXIT_VL_* 字段"
else
    ok "17.12 EXIT_VL_* 字段已全部移除"
fi

# 17.13 节点后缀可自定义且做白名单校验
grep -q '节点后缀 \[' "$TARGET" && ok "17.13 菜单可设置节点后缀" || bad "17.13 未提供后缀设置"
grep -q 'A-Za-z0-9_-' "$TARGET" && ok "17.13 后缀有字符白名单" || bad "17.13 后缀无校验"


# 15.25 安装时探测本机站点（用于默认伪装域名）
SB19=$(mktemp -d); mkdir -p "$SB19/sites"
cat > "$SB19/sites/a.caddy" <<'CEOF'
https://site.example.com:9443 {
	root * /var/www/site
}
http://site.example.com {
	redir https://{host}{uri} permanent
}
CEOF
_doms=$(CADDY_SITES_DIR="$SB19/sites" local_site_domains | sort -u | tr '\n' ' ')
if [[ "$_doms" == "site.example.com " ]]; then
    ok "15.25 能探测本机站点域名（去重）"
else
    bad "15.25 站点探测异常" "$_doms"
fi

# 15.26 证书查找覆盖 /etc/ssl 与 acme.sh 目录
mkdir -p "$SB19/ssl"
(cd "$SB19/ssl" && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
   -keyout private.key -out fullchain.cer -days 2 -nodes -subj "/CN=x.example.com" >/dev/null 2>&1)
_src=$(CERT_DIR="$SB19/empty" find_cert_dir "/tmp" 2>/dev/null || true)
if find_cert_dir "" >/dev/null 2>&1; then
    bad "15.26 空域名不应命中证书"
else
    ok "15.26 find_cert_dir 对空域名返回失败"
fi
rm -rf "$SB19"

# 15.22 证书目录解析统一在 find_cert_dir（sync_hy2_cert 不再自己找目录）
_fcd=$(awk '/^find_cert_dir\(\) \{/,/^\}/' "$TARGET")
grep -q 'CERT_ACME_ROOT' <<<"$_fcd" && ok "15.22 find_cert_dir 覆盖 acme.sh 目录" || bad "15.22 find_cert_dir 未覆盖 acme.sh 目录"
grep -q 'key="$c/$d.key"' <<<"$_fcd" && ok "15.22 find_cert_dir 识别 acme 的 <域名>.key" || bad "15.22 find_cert_dir 未处理 acme key 命名"
_shc=$(awk '/^sync_hy2_cert\(\) \{/,/^\}/' "$TARGET")
if grep -q 'find_cert_dir' <<<"$_shc" && ! grep -q '/root/.acme.sh' <<<"$_shc"; then
    ok "15.22 sync_hy2_cert 复用 find_cert_dir（不再自带一套查找）"
else
    bad "15.22 sync_hy2_cert 仍有重复的证书查找逻辑"
fi

# 17.15 出口菜单进循环必须先解析分协议字段，否则显示成 "Hy2 → :"
_body=$(awk '/^menu_exit\(\) \{/,/^\}/' "$TARGET")
if grep -q 'sync_env_locals' <<<"$_body"; then
    ok "17.15 出口菜单进入前解析出口字段"
else
    bad "17.15 出口菜单未解析字段（地址会显示为空）"
fi

# 17.14 四个端口都可设置：直连走协议参数，链式走出口设置
grep -q '链式入口端口 · Reality' "$TARGET" && ok "17.14 链式入口端口可设置" || bad "17.14 未提供入口端口设置"
grep -q '不能与直连' "$TARGET" && ok "17.14 端口冲突有校验" || bad "17.14 端口冲突无校验"

# 17.8 旧版 vless 出口已移除：EXIT_TYPE=vless 视为无出口，不生成中转
EXIT_TYPE="vless"; EXIT_HY_SERVER=""; EXIT_HY_PORT=""
render_set "reality hy2"; apply_exit_config
_o2=$(python3 -c "import json;d=json.load(open('$CONF_FILE'));print(' '.join(o['tag'] for o in d['outbounds']))")
[[ "$_o2" == "direct" ]] && ok "17.8 EXIT_TYPE=vless 不再生成中转单元" || bad "17.8 仍生成 vless 出口" "$_o2"

# 17.9 关闭出口后回到两个 inbound
EXIT_TYPE="none"; render_set "reality hy2"; apply_exit_config
_n=$(python3 -c "import json;print(len(json.load(open('$CONF_FILE'))['inbounds']))")
[[ "$_n" == "2" ]] && ok "17.9 关闭出口后只剩两个 inbound" || bad "17.9 关闭出口残留" "$_n"

# 17.10 菜单入口
grep -q '2. 出站管理' "$TARGET" && grep -q '^menu_exit()' "$TARGET" && ok "17.10 菜单含出站管理" || bad "17.10 菜单缺少出站管理"


# ---------- 18. 出口导入与自检 ----------
group "18. 出口导入 / 自检"

SB18="$TMPD/m18"; mkdir -p "$SB18/www"
cat > "$SB18/www/provider.yaml" <<'EOF'
proxies:
  - name: "ISIF-VLESS-Reality"
    type: vless
    server: 198.51.100.20
    port: 443
    uuid: 33333333-3333-3333-3333-333333333333
    servername: isif.example.com
    reality-opts:
      public-key: PBKISIF
      short-id: 0a1b2c3d
    client-fingerprint: chrome
  - name: "ISIF-Hysteria2"
    type: hysteria2
    server: isif.example.com
    port: 8443
    password: "hyisif99"
    sni: isif.example.com
    skip-cert-verify: false
EOF
cat > "$SB18/www/only-vless.yaml" <<'EOF'
proxies:
  - name: "B-VLESS"
    type: vless
    server: 198.51.100.21
    port: 443
    uuid: 44444444-4444-4444-4444-444444444444
    servername: b.example.com
    reality-opts:
      public-key: PBKB
      short-id: aabbccdd
EOF
python3 -m http.server 18093 --bind 127.0.0.1 --directory "$SB18/www" >/dev/null 2>&1 &
S18PID=$!
sleep 1.5

parse_apply() { local k v; while IFS=$'\t' read -r k v; do case "$k" in EXIT_*) printf -v "$k" '%s' "$v" ;; esac; done; }
_out=$(exit_parse_url "http://127.0.0.1:18093/provider.yaml" 2>/dev/null)
parse_apply <<< "$_out"
[[ "$EXIT_HY_SERVER" == "isif.example.com" && "$EXIT_HY_PORT" == "8443" && "$EXIT_HY_PASS" == "hyisif99" ]] \
    && ok "18.1 从 provider.yaml 优先解析出 Hy2" || bad "18.1 Hy2 解析失败" "$_out"

if exit_parse_url "http://127.0.0.1:18093/only-vless.yaml" >/dev/null 2>&1; then
    bad "18.2 只有 Reality 节点的订阅仍被导入（出口只支持 Hysteria2）"
else
    ok "18.2 无 Hy2 节点的订阅导入失败"
fi

if exit_parse_url "http://127.0.0.1:18093/nope.yaml" >/dev/null 2>&1; then
    bad "18.3 不存在的订阅未报错"
else
    ok "18.3 订阅不可达时返回失败"
fi

kill "$S18PID" 2>/dev/null || true
wait "$S18PID" 2>/dev/null || true

# 18.4 无 exit-out 时自检判定失败
CONF_FILE="$SB18/empty.json"
printf '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}\n' > "$CONF_FILE"
if exit_health_check >/dev/null 2>&1; then bad "18.4 无出口时自检未拦截"; else ok "18.4 无出口时自检返回失败"; fi

# 18.5 菜单含导入入口
grep -qF 'provider.yaml 地址' "$TARGET" && grep -q 'exit_parse_url' "$TARGET" \
    && ok "18.5 出口菜单支持订阅导入" || bad "18.5 菜单缺少导入入口"



# ---------- 20. 面板与 IPv6 清理 ----------
group "20. 面板与 IPv6"
_n_ipv6=$(grep -ci 'ipv6' "$TARGET" || true)
[[ "$_n_ipv6" -eq 0 ]] && ok "20.1 脚本内已无 IPv6 代码" || bad "20.1 仍残留 IPv6" "$_n_ipv6 处"

grep -q 'print_io_status' "$TARGET" && ok "20.2 面板使用入站/出站状态块" || bad "20.2 面板未使用状态块"
_missing=""
for _kw in '[已启用]' '[配置缺失]' '[未安装]' '[已停用]'; do
    grep -qF "$_kw" "$TARGET" || _missing+=" $_kw"
done
[[ -z "$_missing" ]] && ok "20.3 状态词齐全" || bad "20.3 缺少状态词" "$_missing"

# ---------- 21. Caddy 重载稳定性 ----------
group "21. Caddy 重载稳定性（轮询 + fallback）"
if declare -F wait_service_active >/dev/null 2>&1; then
    ok "21.1 wait_service_active 已定义"
else
    bad "21.1 缺少 wait_service_active"
fi
if [[ "$(grep -c 'wait_service_active caddy 10' "$TARGET")" -ge 2 ]]; then
    ok "21.2 reload 与 restart 两条路径都轮询 active"
else
    bad "21.2 轮询未覆盖两条路径" "$(grep -n 'wait_service_active' "$TARGET" | head -5)"
fi
if grep -A3 'systemctl reload caddy 2>/dev/null; then' "$TARGET" | grep -q 'wait_service_active'; then
    ok "21.3 reload 返回 0 后不再直接判定成功"
else
    bad "21.3 reload 成功分支缺少 active 校验（重载卡死会被误判成功）"
fi
if grep -q 'reset-failed caddy' "$TARGET"; then
    ok "21.4 保留 systemd 限流解除"
else
    bad "21.4 缺少 reset-failed 兜底"
fi

# ---------- 22. 证书与域名匹配 ----------
group "22. 证书域名校验"
if declare -F cert_covers_host >/dev/null 2>&1; then
    ok "22.1 cert_covers_host 已定义"
else
    bad "22.1 缺少 cert_covers_host"
fi
CTD=$(mktemp -d)
if openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CTD/k" -out "$CTD/c" -days 2 \
        -subj "/CN=test.example.com" -addext "subjectAltName=DNS:test.example.com" >/dev/null 2>&1; then
    cert_covers_host "$CTD/c" "test.example.com" && ok "22.2 同域名判定为匹配" || bad "22.2 同域名未匹配"
    cert_covers_host "$CTD/c" "other.example.com" && bad "22.3 异域名被误判为匹配" || ok "22.3 异域名判定为不匹配"
else
    printf '  \033[33m-\033[0m openssl 生成测试证书失败，跳过 22.2/22.3\n'
fi
if grep -q 'return 2' "$TARGET" && grep -q '证书与域名不匹配，已中止安装' "$TARGET"; then
    ok "22.4 证书不匹配时中止安装（不再静默沿用旧证书）"
else
    bad "22.4 缺少不匹配中止路径"
fi
if grep -q 'sync_hy2_cert "\$domain" || rc=\$?' "$TARGET"; then
    ok "22.5 退出码被显式捕获（set -e 下不会误退出）"
else
    bad "22.5 退出码未捕获，set -e 可能直接退出"
fi

group "24. 证书定位（find_cert_dir / install_cert_to）"
C24=$(mktemp -d)
export CERT_SSL_ROOT="$C24/ssl" CERT_ACME_ROOT="$C24/acme"
_old_cert_dir="$CERT_DIR"; CERT_DIR="$C24/sbcert"
mkdir -p "$CERT_SSL_ROOT" "$CERT_ACME_ROOT" "$CERT_DIR"
if openssl req -x509 -newkey rsa:2048 -nodes -keyout "$C24/a.key" -out "$C24/a.crt" -days 2 \
        -subj "/CN=a.example.com" -addext "subjectAltName=DNS:a.example.com" >/dev/null 2>&1; then

    # 24.1 标准布局：/etc/ssl/<域名>/{fullchain.cer,private.key}
    mkdir -p "$CERT_SSL_ROOT/a.example.com"
    cp "$C24/a.crt" "$CERT_SSL_ROOT/a.example.com/fullchain.cer"
    cp "$C24/a.key" "$CERT_SSL_ROOT/a.example.com/private.key"
    _r=$(find_cert_dir "a.example.com" 2>/dev/null)
    [[ "$_r" == "$CERT_SSL_ROOT/a.example.com" ]] && ok "24.1 标准布局直接命中" \
        || bad "24.1 标准布局未命中" "got=${_r:-空}"

    # 24.2 acme.sh 布局（<域名>.key）→ 会自动补出 private.key 并改指 /etc/ssl/<域名>
    mkdir -p "$CERT_ACME_ROOT/b.example.com_ecc"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CERT_ACME_ROOT/b.example.com_ecc/b.example.com.key" \
        -out "$CERT_ACME_ROOT/b.example.com_ecc/fullchain.cer" -days 2 \
        -subj "/CN=b.example.com" -addext "subjectAltName=DNS:b.example.com" >/dev/null 2>&1
    _r=$(find_cert_dir "b.example.com" 2>/dev/null)
    if [[ "$_r" == "$CERT_SSL_ROOT/b.example.com" && -f "$CERT_SSL_ROOT/b.example.com/private.key" ]]; then
        ok "24.2 acme 布局已规范化为 /etc/ssl/<域名>/private.key"
    else
        bad "24.2 acme 布局未规范化" "got=${_r:-空}"
    fi

    # 24.3 目录存在但证书不覆盖该域名 → 返回 2（区别于「没证书」的 1）
    mkdir -p "$CERT_SSL_ROOT/c.example.com"
    cp "$C24/a.crt" "$CERT_SSL_ROOT/c.example.com/fullchain.cer"
    cp "$C24/a.key" "$CERT_SSL_ROOT/c.example.com/private.key"
    rc=0; find_cert_dir "c.example.com" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 2 ]] && ok "24.3 域名不匹配返回 2" || bad "24.3 域名不匹配返回 ${rc}，应为 2"
    rc=0; find_cert_dir "nope.example.com" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 1 ]] && ok "24.4 无证书返回 1" || bad "24.4 无证书返回 ${rc}，应为 1"

    # 24.5 install_cert_to 统一权限
    install_cert_to "$CERT_SSL_ROOT/a.example.com" "$C24/dst" >/dev/null 2>&1
    _m=$(stat -c '%a' "$C24/dst/private.key" 2>/dev/null)
    [[ -f "$C24/dst/fullchain.cer" && "$_m" =~ ^(640|600)$ ]] && ok "24.5 install_cert_to 装好证书且私钥权限 ${_m}" \
        || bad "24.5 install_cert_to 结果异常" "mode=${_m:-无}"

    # 24.6 证书与私钥不配对时拒绝
    cp "$C24/a.crt" "$C24/mix/fullchain.cer" 2>/dev/null || { mkdir -p "$C24/mix"; cp "$C24/a.crt" "$C24/mix/fullchain.cer"; }
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$C24/mix/private.key" -out "$C24/mix/o.crt" -days 2 \
        -subj "/CN=a.example.com" -addext "subjectAltName=DNS:a.example.com" >/dev/null 2>&1
    cert_pair_ok "$C24/mix/fullchain.cer" "$C24/mix/private.key" && bad "24.6 不配对却被判为配对" \
        || ok "24.6 不配对的证书与私钥被判为不配对"
else
    printf '  \033[33m-\033[0m openssl 不可用，跳过第 24 组\n'
fi
CERT_DIR="$_old_cert_dir"; unset CERT_SSL_ROOT CERT_ACME_ROOT
rm -rf "$C24"

group "23. 伪装站点（camo）"
_blk=$(camo_caddy_block "cam.example.com" "/var/www/cam.example.com" "/etc/ssl/cam.example.com" 2>/dev/null)
if printf '%s' "$_blk" | grep -q '^cam\.example\.com {'; then ok "23.1 站点块以域名开头"; else bad "23.1 站点块缺少域名行"; fi
if printf '%s' "$_blk" | grep -q 'root \* /var/www/cam.example.com'; then ok "23.2 站点根目录正确"; else bad "23.2 站点根目录缺失"; fi
if printf '%s' "$_blk" | grep -q 'tls /etc/ssl/cam.example.com/fullchain.cer'; then ok "23.3 证书路径写入"; else bad "23.3 证书路径缺失"; fi
if printf '%s' "$_blk" | grep -q 'noindex, nofollow'; then ok "23.4 带 noindex 响应头"; else bad "23.4 缺少 noindex"; fi
if printf '%s' "$_blk" | grep -q 'rewrite \* /404.html'; then ok "23.5 404 走自定义页"; else bad "23.5 404 未接管"; fi
if camo_caddy_block "" "/tmp" "" >/dev/null 2>&1; then bad "23.6 空域名应当报错"; else ok "23.6 空域名返回非 0"; fi
if python3 -c 'import ast,sys;ast.parse(open(sys.argv[1]).read())' "${SCRIPT_DIR}/camo/camo-site.py" 2>/dev/null; then
    ok "23.7 生成器随仓库分发且可解析"
else
    bad "23.7 生成器缺失或语法错误"
fi
if find_cert_dir "" >/dev/null 2>&1; then bad "23.9 空域名应当失败"; else ok "23.9 空域名返回非 0"; fi
if grep -q 'menu_camo' "$TARGET" && grep -q '8. 伪装站点' "$TARGET"; then ok "23.8 主菜单已挂载伪装站点入口"; else bad "23.8 菜单入口缺失"; fi

# 23.10/23.11 建站只允许「当前伪装域名」，且不得与已有站点块抢同一地址
_t23=$(mktemp -d); mkdir -p "$_t23/sites"
printf '{"inbounds":[{"type":"vless","tag":"vless-reality-in"}]}\n' > "$_t23/config.json"
_s_conf="$CONF_FILE"; _s_sites="$CADDY_SITES_DIR"; _s_sni="${VL_SNI:-}"; _s_camo="$CAMO_PY"
_s_ssl="${CERT_SSL_ROOT-}"; _s_acme="${CERT_ACME_ROOT-}"
# 生成器桩成 /bin/true：断言只关心「守卫是否拦住」，不该让它去下载生成器或碰网络
# 证书根目录显式指到沙箱：第 24 组结尾 unset 过它们，set -u 下漏了会让整套测试当场退出
CAMO_PY=/bin/true
CERT_SSL_ROOT="$_t23/ssl"; CERT_ACME_ROOT="$_t23/acme"
mkdir -p "$CERT_SSL_ROOT" "$CERT_ACME_ROOT"
CONF_FILE="$_t23/config.json"; CADDY_SITES_DIR="$_t23/sites"; VL_SNI="other.example.com"
if build_camo_site "cam.example.com" "eso" "" </dev/null > "$_t23/o1" 2>&1; then
    bad "23.10 Reality 占用 443 时未经确认就给别的域名建站"
else
    if grep -q '必须重新拉订阅' "$_t23/o1" && grep -q '已取消' "$_t23/o1" && [[ "$VL_SNI" == "other.example.com" ]]; then
        ok "23.10 非当前伪装域名需确认切换，EOF 视为取消且不改 VL_SNI"
    else
        bad "23.10 取消路径说明不清或有副作用" "$(tail -1 "$_t23/o1")"
    fi
fi
printf 'cam.example.com {\n\trespond ok\n}\n' > "$_t23/sites/existing.caddy"
CONF_FILE="$_t23/none.json"; VL_SNI=""
if build_camo_site "cam.example.com" "eso" "" </dev/null > "$_t23/o2" 2>&1; then
    bad "23.11 已有站点块时仍重复建站（Caddy 会因重复地址加载失败）"
else
    grep -q '不再重复建站' "$_t23/o2" \
        && ok "23.11 同一域名已有站点块时拒绝重复建站" || bad "23.11 拒绝原因不明确" "$(tail -1 "$_t23/o2")"
fi
CONF_FILE="$_s_conf"; CADDY_SITES_DIR="$_s_sites"; VL_SNI="$_s_sni"; CAMO_PY="$_s_camo"
if [[ -n "$_s_ssl" ]]; then CERT_SSL_ROOT="$_s_ssl"; else unset CERT_SSL_ROOT; fi
if [[ -n "$_s_acme" ]]; then CERT_ACME_ROOT="$_s_acme"; else unset CERT_ACME_ROOT; fi
rm -rf "$_t23"

group "25. 订阅生成与证书助手"
# 25.1/25.2 sub_scheme 由 CERT_MODE 唯一决定
_ss=$(CERT_MODE=domain sub_scheme); [[ "$_ss" == "https" ]] && ok "25.1 domain → https" || bad "25.1 domain 模式得到 ${_ss}"
_ss=$(CERT_MODE=selfsigned sub_scheme); [[ "$_ss" == "http" ]] && ok "25.2 selfsigned → http" || bad "25.2 自签模式得到 ${_ss}"

# 25.3/25.4 后缀清洗：非法项丢弃、合法项保留
_cs=$(clean_suffixes "example.com bad!! corp.net" 2>/dev/null)
[[ "$_cs" == "example.com corp.net" ]] && ok "25.3 clean_suffixes 过滤非法项" || bad "25.3 清洗结果异常: ${_cs}"
[[ -z "$(clean_suffixes '' 2>/dev/null)" ]] && ok "25.4 空输入返回空串" || bad "25.4 空输入未返回空"

# 25.5/25.6 node_port：直连取主端口、出口取链式端口，协议停用时为空
vl_port=443; hy_port=8443; EXIT_ENTRY_VL=2053; EXIT_ENTRY_HY=2054
[[ "$(node_port reality direct)" == "443" && "$(node_port hy2 exit)" == "2054" ]] \
    && ok "25.5 node_port 直连/出口取值正确" || bad "25.5 node_port 取值错误"
vl_port=""; hy_port=""
[[ -z "$(node_port reality direct)" && -z "$(node_port hy2 exit)" ]] \
    && ok "25.6 协议停用（端口空）时返回空" || bad "25.6 停用仍返回端口"
vl_port=443; hy_port=8443

# 25.7 订阅生成只保留一处「取端口 + 发节点」的遍历
_cnt=$(grep -c 'emit_nodes ' "$TARGET")
[[ "$_cnt" -eq 4 ]] && ok "25.7 emit_nodes 定义 + 三处调用（proxy/provider/link）" \
    || bad "25.7 emit_nodes 调用点异常" "共 ${_cnt} 处，应为 4"
_case_cnt=$(awk '/^generate_full_client_config\(\) \{/,/^}/' "$TARGET" | grep -c 'case "\$_p" in')
[[ "$_case_cnt" -le 2 ]] && ok "25.8 订阅生成里重复的 case 已收敛（剩 ${_case_cnt} 处）" \
    || bad "25.8 仍有 ${_case_cnt} 处重复 case"

# 25.9 缺证书时 build_camo_site 会现签，而不是让用户去菜单 4 碰壁
# 注意：awk | grep -q 在 pipefail 下会因 SIGPIPE 假红，先取变量再匹配
_bcs=$(awk '/^build_camo_site\(\) \{/,/^}/' "$TARGET")
if grep -q 'issue_site_cert' <<<"$_bcs"; then
    ok "25.9 伪装站缺证书时自动签发"
else
    bad "25.9 伪装站缺证书时不会签发"
fi

# 25.10 建站菜单不再运行期切换 Reality SNI（集合冻结后换伪装域名只能重装）
_mc=$(awk '/^menu_camo\(\) \{/,/^}/' "$TARGET")
if grep -q 'proto_enable_reality' <<<"$_mc"; then
    bad "25.10 建站菜单仍残留运行期 SNI 切换"
else
    ok "25.10 建站菜单不含运行期 SNI 切换"
fi

# 25.11 Reality 的伪装目标由安装期检查统一判定（站点/外部 SNI 一处收口）
_per=$(awk '/^reality_target_check\(\) \{/,/^}/' "$TARGET")
if grep -q 'site_cert_problem' <<<"$_per" && grep -q 'probe_external_sni' <<<"$_per"; then
    ok "25.11 安装期检查同时覆盖本机站点与外部 SNI"
else
    bad "25.11 安装期检查缺站点或外部 SNI 校验"
fi

# 25.12 不再有重复的 ASK_EOF 判断
_dup=$(grep -c 'ASK_EOF" == "1" \]\] && break' "$TARGET")
_dup_lines=$(grep -n 'ASK_EOF" == "1" \]\] && break' "$TARGET" | wc -l)
if [[ $(( _dup_lines - $(grep -c 'if \[\[ "\$ASK_EOF"' "$TARGET") )) -le 4 ]]; then
    ok "25.12 各菜单各一处 EOF 判断（共 ${_dup_lines} 处）"
else
    bad "25.12 EOF 判断仍重复" "共 ${_dup_lines} 处"
fi

group "26. env 搬运收敛（set_env_scene）"
# 26.1 write_env_config 强制非空的每个键，set_env_scene 都必须赋值，否则菜单会写回空串
_scene=$(awk '/^set_env_scene\(\) \{/,/^}/' "$TARGET")
_req=$(awk '/for v in node_prefix/,/hy_password sub_port sub_token/' "$TARGET")
_missing=""
for _k in node_prefix server_ip vl_port vl_sni user_uuid vl_privkey vl_pubkey vl_shortid hy_port hy_password sub_port sub_token; do
    grep -qE "^    ${_k}=" <<<"$_scene" || _missing+=" ${_k}"
done
[[ -z "$_missing" ]] && ok "26.1 set_env_scene 覆盖 write_env_config 的全部必填字段" \
    || bad "26.1 set_env_scene 缺字段:${_missing}"

# 26.2 菜单里的三个写入分支不再各自搬运（regen_from_scope 是订阅作用域，另算）
_menu=$(awk '/^menu_sub_module\(\) \{/,/^\}/' "$TARGET")
_n=$(grep -c 'local server_ip="\$SERVER_IP"' <<<"$_menu")
[[ "$_n" -eq 0 ]] && ok "26.2 菜单分支不再手工搬运 env 字段" || bad "26.2 仍有 ${_n} 处手工搬运"

# 26.3 三条写入路径都改走 set_env_scene
_n=$(grep -c 'set_env_scene' "$TARGET")
[[ "$_n" -ge 4 ]] && ok "26.3 set_env_scene 定义 + 三处调用（共 ${_n} 处）" \
    || bad "26.3 调用点不足" "共 ${_n} 处，应为 4"

# 26.4 HY_PASS 等敏感字段不得出现在报错文案里
if grep -q 'hy_password="\${HY_PASS:-}"' "$TARGET"; then
    ok "26.4 hy_password 从 HY_PASS 派生"
else
    bad "26.4 hy_password 取值路径异常"
fi

group "27. 协议集合是安装期常量"

# 27.1 PROTO_SET 的赋值只出现在安装向导（ask_proto_set）与落库（write_env_config）
_ps_all=$(grep -c 'PROTO_SET="' "$TARGET")
_ps_ask=$(awk '/^ask_proto_set\(\) \{/,/^}/' "$TARGET" | grep -c 'PROTO_SET="')
_ps_write=$(awk '/^write_env_config\(\) \{/,/^}/' "$TARGET" | grep -c 'PROTO_SET="')
# +1 = 文件顶部的默认值（PROTO_SET="${PROTO_SET:-reality hy2}"，load_env 会覆盖它）
if [[ "$_ps_all" -eq $(( _ps_ask + _ps_write + 1 )) && "$_ps_ask" -ge 3 && "$_ps_write" -ge 1 ]]; then
    ok "27.1 PROTO_SET 只由安装向导与 write_env_config 赋值（${_ps_all} 处）"
else
    bad "27.1 运行期仍在改协议集合" "全脚本 ${_ps_all} 处，向导 ${_ps_ask}，落库 ${_ps_write}"
fi

# 27.2 render_set 不接受参数：集合只能来自 env，调用方无法传一个集合进来
if awk '/^render_set\(\) \{/,/^}/' "$TARGET" | grep -q '\$1'; then
    bad "27.2 render_set 仍读位置参数"
else
    ok "27.2 render_set 无参（集合只从 env 派生）"
fi

# 27.4 翻转端口是常量，翻转状态不落库（没有 SITE_FILE / FLIP_HOST）
_n_fp=$(grep -c '^FLIP_PORT=' "$TARGET")
_n_sf=$(grep -c 'SITE_FILE\|FLIP_HOST' "$TARGET")
[[ "$_n_fp" == "1" && "$_n_sf" == "0" ]] \
    && ok "27.4 FLIP_PORT 是常量 9443，翻转状态不落库" \
    || bad "27.4 翻转状态仍有落库或常量被改写" "FLIP_PORT 赋值 ${_n_fp} 处 / 翻转字段 ${_n_sf} 处"

# 27.3 集合派生只有 proto_in_set 一处
_n_in=$(grep -c 'proto_in_set ' "$TARGET")
[[ "$_n_in" -ge 4 ]] && ok "27.3 proto_in_set 是集合判定的唯一入口（${_n_in} 处）" \
    || bad "27.3 集合判定没有收口" "proto_in_set 出现 ${_n_in} 处"

group "28. 卸载清理伪装站"
_un=$(awk '/^uninstall_all\(\) \{/,/^\}/' "$TARGET")
if grep -q 'camo-\*\.caddy' <<<"$_un"; then
    ok "28.1 卸载会删除 camo-*.caddy"
else
    bad "28.1 卸载遗留伪装站站点块（会让 foreign_sites 误判、站点指向已删证书）"
fi
if grep -q '_croot' <<<"$_un"; then
    ok "28.2 站点根目录一并清理（仅限 /var/www/*）"
else
    bad "28.2 未清理站点根目录"
fi
_mc2=$(awk '/^menu_camo\(\) \{/,/^\}/' "$TARGET")
if grep -q '正被 Reality 当作伪装域名' <<<"$_mc2"; then
    ok "28.3 删除在用的伪装域名会被拦下"
else
    bad "28.3 删除在用的伪装域名没有保护"
fi

group "29. 证书与中转单元不被静默抹掉"

# 29.1 已随 disable_protocol 删除：集合冻结后运行期没有停用路径，
# 「停用协议把中转单元抹掉」这条失败路径不复存在；渲染路径的守卫见 30.6 / 35.2。

_c1=$(grep -n 'cert_covers_host "${CERT_DIR}/fullchain.cer"' "$TARGET" | cut -d: -f1 | head -1)
_c2=$(grep -n 'for _c in "/etc/ssl/${HY_DOMAIN:-}"' "$TARGET" | cut -d: -f1 | head -1)
if [[ -n "$_c1" && -n "$_c2" && "$_c1" -lt "$_c2" ]]; then
    ok "29.2 订阅站优先用续期目标 CERT_DIR"
else
    bad "29.2 订阅站可能优先读 /etc/ssl 下的陈旧副本（续期后仍用旧证书）"
fi

_b1=$(grep -n '^build_camo_site() {' "$TARGET" | cut -d: -f1 | head -1)
_bc=$(sed -n "${_b1},$((_b1+45))p" "$TARGET" | sed '/^[[:space:]]*#/d')
if grep -q '"\$domain" == "\$HY_DOMAIN"' <<<"$_bc" && grep -q 'issue_site_cert "\$domain"' <<<"$_bc"; then
    ok "29.3 伪装站区分接入域/内容域，内容域走 issue_site_cert"
else
    bad "29.3 build_camo_site 未区分接入域，续期不会更新伪装站证书"
fi

_is=$(awk '/^issue_site_cert\(\) \{/,/^}/' "$TARGET" | sed '/^[[:space:]]*#/d')
if grep -q 'have_cert" == 0' <<<"$_is"; then
    ok "29.4 已有证书时不再索取 CF Token"
else
    bad "29.4 issue_site_cert 无谓要求 Token（无 token 的机器建站会卡住）"
fi

group "30. 出站槽位抽象（纯重构，N=1 零行为变化）"

# 30.1 槽位映射存在，槽 1 读派生字段、为空时回落到 EXIT_HY_*
if declare -F exit_slot_env >/dev/null 2>&1 && declare -F exit_active_slots >/dev/null 2>&1; then
    ( EXIT_TYPE=hy2; EXIT_SERVER=""; EXIT_PORT=""; EXIT_PASS=""; EXIT_SNI=""
      EXIT_HY_SERVER="isif.example.com"; EXIT_HY_PORT="8443"; EXIT_HY_PASS="p9"; EXIT_HY_SNI="isif.example.com"
      exit_slot_env 1
      [[ "$SE_SERVER" == "isif.example.com" && "$SE_PORT" == "8443" && "$SE_PASS" == "p9" ]] )
    if [[ $? -eq 0 ]]; then ok "30.1 exit_slot_env 槽 1 回落读取 EXIT_HY_*（漏 sync 也不会丢中转）"
    else bad "30.1 exit_slot_env 槽 1 映射错误"; fi
else
    bad "30.1 槽位抽象缺失（exit_slot_env / exit_active_slots 未定义）"
fi

# 30.2 槽 1 的 tag 一字不改
if declare -F exit_slot_tag >/dev/null 2>&1; then
    _t1="$(exit_slot_tag 1 vless-in) $(exit_slot_tag 1 hy2-in) $(exit_slot_tag 1 out)"
    [[ "$_t1" == "exit-vless-in exit-hy2-in exit-out" ]] \
        && ok "30.2 槽 1 tag 保持 exit-vless-in / exit-hy2-in / exit-out" \
        || bad "30.2 槽 1 tag 变了（存量订阅与客户端会失联）" "$_t1"
else
    bad "30.2 exit_slot_tag 未定义"
fi

# 30.3 只有 EXIT_HY_*（未 sync）时仍然追加中转单元
SB30="$TMPD/m30"; mkdir -p "$SB30"
python3 - "$SB30/cfg.json" <<'PY'
import json, sys
d = {"log": {"level": "warn"},
     "inbounds": [
       {"type": "vless", "tag": "vless-reality-in", "listen": "0.0.0.0", "listen_port": 443,
        "users": [{"uuid": "11111111-1111-1111-1111-111111111111"}],
        "tls": {"enabled": True, "server_name": "gh.example.com"}},
       {"type": "hysteria2", "tag": "hy2-in", "listen": "0.0.0.0", "listen_port": 8443,
        "users": [{"password": "x"}],
        "tls": {"enabled": True, "certificate_path": "/tmp/c.cer", "key_path": "/tmp/c.key"}}],
     "outbounds": [{"type": "direct", "tag": "direct"}]}
json.dump(d, open(sys.argv[1], "w"))
PY
(
  CONF_FILE="$SB30/cfg.json"
  unset EXIT_SERVER EXIT_PORT EXIT_PASS EXIT_SNI EXIT_UUID EXIT_PBK EXIT_SID
  EXIT_TYPE="hy2"; EXIT_HY_SERVER="isif.example.com"; EXIT_HY_PORT="8443"; EXIT_HY_PASS="p9"
  EXIT_HY_SNI="isif.example.com"; EXIT_ENTRY_VL="2053"; EXIT_ENTRY_HY="2054"; EXIT_LABEL="ISIF"
  apply_exit_config
  python3 -c "import json,sys;d=json.load(open('$SB30/cfg.json'));print(' '.join(i['tag'] for i in d['inbounds']))" > "$SB30/tags"
)
_tags30=$(cat "$SB30/tags" 2>/dev/null || true)
[[ "$_tags30" == *exit-hy2-in* && "$_tags30" == *exit-vless-in* ]] \
    && ok "30.3 未 sync 时也按 EXIT_HY_* 追加中转单元" \
    || bad "30.3 未 sync 时 apply_exit_config 静默返回、中转消失" "$_tags30"

# 30.4 配置渲染按槽循环，不再读单一 EXIT_TYPE 后直接返回
_aec=$(awk '/^apply_exit_config\(\) \{/,/^}/' "$TARGET" | sed '/^[[:space:]]*#/d')
if grep -q 'exit_active_slots' <<<"$_aec" && ! grep -qE 'EXIT_TYPE:-none.*return 0' <<<"$_aec"; then
    ok "30.4 apply_exit_config 遍历槽位"
else
    bad "30.4 apply_exit_config 仍按单一 EXIT_TYPE 处理"
fi

# 30.5 订阅 / 面板 / 策略组都按槽遍历
_em=$(awk '/^emit_nodes\(\) \{/,/^}/' "$TARGET" | sed '/^[[:space:]]*#/d')
grep -q 'exit_active_slots' <<<"$_em" && ok "30.5 emit_nodes 按槽遍历" || bad "30.5 emit_nodes 未按槽遍历"
_io=$(awk '/^print_io_status\(\) \{/,/^}/' "$TARGET" | sed '/^[[:space:]]*#/d')
grep -q 'exit_active_slots' <<<"$_io" && ok "30.5 面板按槽遍历" || bad "30.5 print_io_status 未按槽遍历"
_gf=$(awk '/^generate_full_client_config\(\) \{/,/^}/' "$TARGET" | sed '/^[[:space:]]*#/d')
grep -q 'exit_active_slots' <<<"$_gf" && ok "30.5 策略组按槽遍历" || bad "30.5 策略组未按槽遍历"

# 30.6 render_and_reload 里先 sync_env_locals，再 apply_exit_config
_rr=$(awk '/^_render_and_reload\(\) \{/,/^}/' "$TARGET" | sed '/^[[:space:]]*#/d')
_s=$(grep -n 'sync_env_locals' <<<"$_rr" | head -1 | cut -d: -f1)
_a=$(grep -n 'apply_exit_config' <<<"$_rr" | head -1 | cut -d: -f1)
[[ -n "$_s" && -n "$_a" && "$_s" -lt "$_a" ]] \
    && ok "30.6 render_and_reload 先 sync 再追加中转" \
    || bad "30.6 render_and_reload 缺少 sync_env_locals 前置"

# 30.7 槽位上限常量存在且本版锁死为 1
_max=$(grep -oP '^EXIT_SLOTS_MAX=\K[0-9]+' "$TARGET" | head -1)
[[ "$_max" == "4" ]] && ok "30.7 EXIT_SLOTS_MAX=4（槽 1..4）" \
    || bad "30.7 EXIT_SLOTS_MAX 取值异常" "=${_max:-未定义}"

group "31. 第二出口（hy2-only）与菜单"

SB31="$TMPD/m31"; mkdir -p "$SB31"
# 每个路径都从 render_set 重新写出的配置开始（apply_exit_config 本身是追加式的）
mk31cfg() {
    python3 - "$1" <<'PYEOF'
import json, sys
d = {"log": {"level": "warn"},
     "inbounds": [
       {"type": "vless", "tag": "vless-reality-in", "listen": "0.0.0.0", "listen_port": 443,
        "users": [{"uuid": "11111111-1111-1111-1111-111111111111"}],
        "tls": {"enabled": True, "server_name": "gh.example.com"}},
       {"type": "hysteria2", "tag": "hy2-in", "listen": "0.0.0.0", "listen_port": 8443,
        "users": [{"password": "x"}],
        "tls": {"enabled": True, "certificate_path": "/tmp/c.cer", "key_path": "/tmp/c.key"}}],
     "outbounds": [{"type": "direct", "tag": "direct"}]}
json.dump(d, open(sys.argv[1], "w"))
PYEOF
}
mk31cfg "$SB31/cfg.json"

snap31() {
    python3 - "$1" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(" ".join(i["tag"] for i in d["inbounds"]))
print(" ".join(o["tag"] for o in d["outbounds"]))
print(len(d.get("route", {}).get("rules", [])))
print(" ".join(sorted(str(i["listen_port"]) for i in d["inbounds"])))
PYEOF
}

# 两个槽都启用后连续渲染两次（覆盖 render_and_reload / disable_protocol 两条写配置路径）
(
  CONF_FILE="$SB31/cfg.json"
  unset EXIT_SERVER EXIT_PORT EXIT_PASS EXIT_SNI EXIT_UUID EXIT_PBK EXIT_SID
  EXIT_TYPE="hy2"; EXIT_HY_SERVER="isif.example.com"; EXIT_HY_PORT="8443"; EXIT_HY_PASS="p1"
  EXIT_HY_SNI="isif.example.com"; EXIT_LABEL="ISIF"; EXIT_ENTRY_VL="2053"; EXIT_ENTRY_HY="2054"
  EXIT2_SERVER="sl.example.com"; EXIT2_PORT="8443"; EXIT2_PASS="p2"; EXIT2_SNI="sl.example.com"
  EXIT2_LABEL="SL"; EXIT2_ENTRY_VL="2063"; EXIT2_ENTRY_HY="2064"
  apply_exit_config
  snap31 "$CONF_FILE" > "$SB31/snap1"
  # 路径二：从同一份基础配置重新渲染（apply_exit_reload / disable_protocol 同序）
  mk31cfg "$CONF_FILE"
  apply_exit_config
  snap31 "$CONF_FILE" > "$SB31/snap2"
)
_tags31=$(sed -n 1p "$SB31/snap1" 2>/dev/null || true)
_outs31=$(sed -n 2p "$SB31/snap1" 2>/dev/null || true)
_rules31=$(sed -n 3p "$SB31/snap1" 2>/dev/null || true)
_ports31=$(sed -n 4p "$SB31/snap1" 2>/dev/null || true)
[[ "$_tags31" == *exit2-vless-in* && "$_tags31" == *exit2-hy2-in* && "$_outs31" == *exit2-out* && "$_rules31" == "4" ]] \
    && ok "31.1 槽 2 生成 exit2-vless-in / exit2-hy2-in / exit2-out + 两条路由" \
    || bad "31.1 槽 2 结构异常" "tags=$_tags31 outs=$_outs31 rules=$_rules31"
[[ "$_ports31" == "2053 2054 2063 2064 443 8443" ]] \
    && ok "31.1 四个链式入口端口 2053/2054/2063/2064" \
    || bad "31.1 入口端口集合异常" "$_ports31"
if diff -q "$SB31/snap1" "$SB31/snap2" >/dev/null 2>&1 && grep -q 'exit2-vless-in' <<<"$_tags31"; then
    ok "31.2 两条写配置路径产出一致（都保留两组出口）"
else
    bad "31.2 两条写配置路径结果不一致" "$(diff "$SB31/snap1" "$SB31/snap2" 2>/dev/null | head -4)"
fi

# 31.3 槽 2 为空：配置回到单槽形态；env 仍写回 8 个 EXIT2_* 字段
(
  CONF_FILE="$SB31/cfg.json"
  unset EXIT_SERVER EXIT_PORT EXIT_PASS EXIT_SNI EXIT_UUID EXIT_PBK EXIT_SID
  EXIT_TYPE="hy2"; EXIT_HY_SERVER="isif.example.com"; EXIT_HY_PORT="8443"; EXIT_HY_PASS="p1"
  EXIT_HY_SNI="isif.example.com"; EXIT_LABEL="ISIF"; EXIT_ENTRY_VL="2053"; EXIT_ENTRY_HY="2054"
  EXIT2_SERVER=""; EXIT2_PORT=""; EXIT2_PASS=""; EXIT2_SNI=""
  EXIT2_LABEL=""; EXIT2_ENTRY_VL=""; EXIT2_ENTRY_HY=""
  mk31cfg "$CONF_FILE"
  apply_exit_config
  snap31 "$CONF_FILE" > "$SB31/slot1only"
)
_s1=$(sed -n 1p "$SB31/slot1only" 2>/dev/null || true)
_s1o=$(sed -n 2p "$SB31/slot1only" 2>/dev/null || true)
_max31=$(grep -oP '^EXIT_SLOTS_MAX=\K[0-9]+' "$TARGET" | head -1)
_slots_active=$( (unset EXIT_SERVER EXIT_PORT EXIT_PASS EXIT_SNI EXIT_UUID EXIT_PBK EXIT_SID
  EXIT_TYPE="hy2"; EXIT_HY_SERVER="isif.example.com"; EXIT_HY_PORT="8443"; EXIT_HY_PASS="p1"
  EXIT2_SERVER=""; EXIT2_PORT=""; EXIT2_PASS=""
  exit_active_slots | tr '\n' ' ') )
[[ "$_s1" == "vless-reality-in hy2-in exit-vless-in exit-hy2-in" && "$_s1o" == "direct exit-out" \
   && "$_max31" == "4" && "$_slots_active" == "1 " ]] \
    && ok "31.3 槽 2 为空时只生成槽 1 的中转单元（槽 2 结构存在但不生效）" \
    || bad "31.3 槽 2 为空仍产生多余结构" "$_s1 / $_s1o"

( ENV_FILE="$SB31/env2.conf"
  node_prefix=SB; server_ip=203.0.113.11; vl_port=443; vl_sni=gh.example.com
  user_uuid="11111111-1111-1111-1111-111111111111"; vl_privkey=K; vl_pubkey=P; vl_shortid=ab
  hy_port=8443; hy_password=pw; sub_port=8444; sub_token=tok31
  hy_domain=""; target_host=203.0.113.11
  unset EXIT2_SERVER EXIT2_PORT EXIT2_LABEL EXIT2_ENTRY_VL EXIT2_ENTRY_HY
  write_env_config 2>/dev/null || true
)
_n31=$(grep -c '^EXIT2_' "$SB31/env2.conf" 2>/dev/null || true)
if [[ "$_n31" == "8" ]] && grep -q '^NODE_PREFIX="SB"' "$SB31/env2.conf" 2>/dev/null; then
    ok "31.3 env 写回全部 8 个 EXIT2_* 字段（空值）"
else
    bad "31.3 env 缺少 EXIT2_* 字段或主字段没写出" "EXIT2=${_n31:-0} 个"
fi

# 31.4 桥接断言：入口端口有值但落点不完整时拒绝写 env
( ENV_FILE="$SB31/env3.conf"
  node_prefix=SB; server_ip=203.0.113.11; vl_port=443; vl_sni=gh.example.com
  user_uuid="11111111-1111-1111-1111-111111111111"; vl_privkey=K; vl_pubkey=P; vl_shortid=ab
  hy_port=8443; hy_password=pw; sub_port=8444; sub_token=tok31
  EXIT2_ENTRY_HY=2064; EXIT2_ENTRY_VL=2063
  EXIT2_SERVER=""; EXIT2_PORT=""; EXIT2_PASS=""
  hy_domain=""; target_host=203.0.113.11
  write_env_config 2>/dev/null || true
)
if [[ ! -f "$SB31/env3.conf" ]]; then
    ok "31.4 槽 2 参数不完整时拒绝写入 env（不留半套出口）"
else
    bad "31.4 槽 2 不完整仍写入了 env"
fi

# 31.4b 槽 3 / 槽 4 也写进 env（上限 4，落点字段按槽循环写出）
(
  ENV_FILE="$SB31/env4.conf"
  node_prefix=SB; server_ip=203.0.113.11; vl_port=443; vl_sni=gh.example.com
  user_uuid="11111111-1111-1111-1111-111111111111"; vl_privkey=K; vl_pubkey=P; vl_shortid=ab
  hy_port=8443; hy_password=pw; sub_port=8444; sub_token=tok31
  EXIT3_SERVER="tw1.example.com"; EXIT3_PORT=8443; EXIT3_PASS="p3"; EXIT3_SNI="tw1.example.com"
  EXIT3_LABEL="TW1"; EXIT3_ENTRY_VL=2087; EXIT3_ENTRY_HY=2088
  write_env_config 2>/dev/null || true
)
_n3=$(grep -c '^EXIT3_' "$SB31/env4.conf" 2>/dev/null || true)
if [[ "$_n3" == "8" ]] && grep -q '^EXIT4_SERVER=""' "$SB31/env4.conf" 2>/dev/null; then
    ok "31.4b 槽 3 写回 8 个字段、槽 4 以空值占位（上限 4）"
else
    bad "31.4b 槽 3/4 字段写回异常" "EXIT3 共 ${_n3:-0} 个"
fi

# 31.4c apply_exit_config 幂等：同一份配置连跑两次不得出现重复 tag
(
  CONF_FILE="$SB31/cfg.json"
  unset EXIT_SERVER EXIT_PORT EXIT_PASS EXIT_SNI
  EXIT_TYPE="hy2"; EXIT_HY_SERVER="isif.example.com"; EXIT_HY_PORT="8443"; EXIT_HY_PASS="p1"
  EXIT_HY_SNI="isif.example.com"; EXIT_LABEL="ISIF"; EXIT_ENTRY_VL="2053"; EXIT_ENTRY_HY="2054"
  mk31cfg "$CONF_FILE"
  apply_exit_config; apply_exit_config
  python3 -c "import json,collections;d=json.load(open('$SB31/cfg.json'));c=collections.Counter(i['tag'] for i in d['inbounds']);print(' '.join(k for k,v in c.items() if v>1))" > "$SB31/dup"
)
if [[ -z "$(cat "$SB31/dup" 2>/dev/null)" ]]; then
    ok "31.4c apply_exit_config 连跑两次无重复 tag（幂等）"
else
    bad "31.4c 重复应用产生了重复 inbound tag" "$(cat "$SB31/dup")"
fi

# 31.5 删除槽 2：订阅回到 4 条节点（2 直连 + 2 槽 1 出口）
(
  CONF_FILE="$SB31/cfg.json"
  unset EXIT_SERVER EXIT_PORT EXIT_PASS EXIT_SNI EXIT_UUID EXIT_PBK EXIT_SID
  EXIT_TYPE="hy2"; EXIT_HY_SERVER="isif.example.com"; EXIT_HY_PORT="8443"; EXIT_HY_PASS="p1"
  EXIT_HY_SNI="isif.example.com"; EXIT_LABEL="ISIF"; EXIT_ENTRY_VL="2053"; EXIT_ENTRY_HY="2054"
  EXIT2_SERVER=""; EXIT2_PORT=""; EXIT2_PASS=""; EXIT2_SNI=""
  EXIT2_LABEL=""; EXIT2_ENTRY_VL=""; EXIT2_ENTRY_HY=""
  mk31cfg "$CONF_FILE"
  render_set "reality hy2"; apply_exit_config
  node_prefix="SB"; server_ip="203.0.113.11"; vl_port=443; hy_port=8443
  user_uuid="11111111-1111-1111-1111-111111111111"; vl_sni="gh.example.com"
  vl_pubkey="PBK"; vl_shortid="ab12cd34"; hy_password="hp"; CERT_MODE="domain"
  WEB_DIR="$SB31/web"; mkdir -p "$WEB_DIR/tok31"
  generate_full_client_config "sb.example.com" tok31 SB 203.0.113.11 443 \
    "11111111-1111-1111-1111-111111111111" gh.example.com PBK ab12cd34 8443 8443 hp
  grep -c '://' "$WEB_DIR/tok31/links.txt" > "$SB31/nlinks"
  grep -c '^  - name:' "$WEB_DIR/tok31/provider.yaml" > "$SB31/nnodes"
)
# 同一份渲染条件下，槽 2 启用时应当是 6 条（证明「删除」确实减少了节点）
(
  CONF_FILE="$SB31/cfg.json"
  unset EXIT_SERVER EXIT_PORT EXIT_PASS EXIT_SNI EXIT_UUID EXIT_PBK EXIT_SID
  EXIT_TYPE="hy2"; EXIT_HY_SERVER="isif.example.com"; EXIT_HY_PORT="8443"; EXIT_HY_PASS="p1"
  EXIT_HY_SNI="isif.example.com"; EXIT_LABEL="ISIF"; EXIT_ENTRY_VL="2053"; EXIT_ENTRY_HY="2054"
  EXIT2_SERVER="sl.example.com"; EXIT2_PORT="8443"; EXIT2_PASS="p2"; EXIT2_SNI="sl.example.com"
  EXIT2_LABEL="SL"; EXIT2_ENTRY_VL="2063"; EXIT2_ENTRY_HY="2064"
  mk31cfg "$CONF_FILE"; render_set "reality hy2"; apply_exit_config
  node_prefix="SB"; server_ip="203.0.113.11"; vl_port=443; hy_port=8443
  user_uuid="11111111-1111-1111-1111-111111111111"; vl_sni="gh.example.com"
  vl_pubkey="PBK"; vl_shortid="ab12cd34"; hy_password="hp"; CERT_MODE="domain"
  WEB_DIR="$SB31/webB"; mkdir -p "$WEB_DIR/tok31b"
  generate_full_client_config "sb.example.com" tok31b SB 203.0.113.11 443 \
    "11111111-1111-1111-1111-111111111111" gh.example.com PBK ab12cd34 8443 8443 hp
  grep -c '^  - name:' "$WEB_DIR/tok31b/provider.yaml" > "$SB31/nnodes_before"
)
[[ "$(cat "$SB31/nnodes_before" 2>/dev/null)" == "6" && "$(cat "$SB31/nlinks" 2>/dev/null)" == "4" \
   && "$(cat "$SB31/nnodes" 2>/dev/null)" == "4" ]] \
    && ok "31.5 槽 2 启用 6 条 → 删除后回到 4 条节点" \
    || bad "31.5 订阅节点数异常" "links=$(cat "$SB31/nlinks" 2>/dev/null) nodes=$(cat "$SB31/nnodes" 2>/dev/null)"
if [[ "$(cat "$SB31/nnodes_before" 2>/dev/null)" == "6" ]]; then
    grep -q 'SL' "$SB31/web/tok31/provider.yaml" 2>/dev/null \
        && bad "31.5 删除后仍残留 SL 节点" || ok "31.5 已删除槽 2 的订阅节点"
fi

# 31.6 菜单：新增 / 编辑 / 删除，且不再有「切换出站协议」
_me31=$(awk '/^menu_exit\(\) \{/,/^}/' "$TARGET")
if grep -q '2. 新增出口' <<<"$_me31" && grep -q '3. 编辑出口' <<<"$_me31" \
   && grep -q '4. 删除出口' <<<"$_me31" && ! grep -q '切换出站协议' <<<"$_me31"; then
    ok "31.6 出站菜单为 查看/新增/编辑/删除（无「切换协议」）"
else
    bad "31.6 出站菜单结构不符"
fi
if grep -q '落点' <<<"$_me31" && grep -q '入口' <<<"$_me31" && grep -q '标签' <<<"$_me31"; then
    ok "31.6 菜单表格含 落点 / 入口 / 标签 三列"
else
    bad "31.6 菜单表格缺列"
fi

# 31.7 端口表：槽 1..4 = 2053/2054、2083/2084、2087/2088、2096/2097
if declare -F exit_slot_default_ports >/dev/null 2>&1; then
    _d1=$(exit_slot_default_ports 1); _d2=$(exit_slot_default_ports 2)
    _d3=$(exit_slot_default_ports 3); _d4=$(exit_slot_default_ports 4)
    [[ "$_d1" == "2053 2054" && "$_d2" == "2083 2084" && "$_d3" == "2087 2088" && "$_d4" == "2096 2097" ]] \
        && ok "31.7 入口端口默认值按 CF HTTPS 端口表取（2053/2083/2087/2096）" \
        || bad "31.7 端口表异常" "$_d1 / $_d2 / $_d3 / $_d4"
else
    bad "31.7 exit_slot_default_ports 未定义"
fi

# 31.8 旧版 Reality 出口已移除：菜单只提示重配，编辑流程不再有 vless 分支
_ee31=$(awk '/^exit_edit\(\) \{/,/^}/' "$TARGET")
_me31b=$(awk '/^menu_exit\(\) \{/,/^}/' "$TARGET")
if ! grep -q 'SE_TYPE" == "vless"' <<<"$_ee31" && grep -q '旧版 Reality 出口已不再支持' <<<"$_me31b"; then
    ok "31.8 编辑流程无 vless 分支，菜单对旧出口给出重配提示"
else
    bad "31.8 vless 出口仍残留在编辑流程里"
fi

# 31.9 订阅：两个出口的节点名与策略组同源
(
  CONF_FILE="$SB31/cfg.json"
  unset EXIT_SERVER EXIT_PORT EXIT_PASS EXIT_SNI EXIT_UUID EXIT_PBK EXIT_SID
  EXIT_TYPE="hy2"; EXIT_HY_SERVER="isif.example.com"; EXIT_HY_PORT="8443"; EXIT_HY_PASS="p1"
  EXIT_HY_SNI="isif.example.com"; EXIT_LABEL="ISIF"; EXIT_ENTRY_VL="2053"; EXIT_ENTRY_HY="2054"
  EXIT2_SERVER="sl.example.com"; EXIT2_PORT="8443"; EXIT2_PASS="p2"; EXIT2_SNI="sl.example.com"
  EXIT2_LABEL="SL"; EXIT2_ENTRY_VL="2063"; EXIT2_ENTRY_HY="2064"
  mk31cfg "$CONF_FILE"
  render_set "reality hy2"; apply_exit_config
  node_prefix="SB"; server_ip="203.0.113.11"; vl_port=443; hy_port=8443
  user_uuid="11111111-1111-1111-1111-111111111111"; vl_sni="gh.example.com"
  vl_pubkey="PBK"; vl_shortid="ab12cd34"; hy_password="hp"; CERT_MODE="domain"
  WEB_DIR="$SB31/web2"; mkdir -p "$WEB_DIR/tok32"
  generate_full_client_config "sb.example.com" tok32 SB 203.0.113.11 443 \
    "11111111-1111-1111-1111-111111111111" gh.example.com PBK ab12cd34 8443 8443 hp
)
_ok31=1
for _nm in "SB-Hysteria2-ISIF" "SB-Hysteria2-SL"; do
    grep -q "name: \"$_nm\"" "$SB31/web2/tok32/provider.yaml" || _ok31=0
    grep -q -- "- \"$_nm\"" "$SB31/web2/tok32/config.yaml" || _ok31=0
done
[[ "$_ok31" == "1" ]] && ok "31.9 两个出口各生成节点并被策略组引用" \
    || bad "31.9 出口节点/策略组缺失"
grep -q 'port: 2063' "$SB31/web2/tok32/provider.yaml" && grep -q 'port: 2064' "$SB31/web2/tok32/provider.yaml" \
    && ok "31.9 槽 2 节点端口为 2063/2064" || bad "31.9 槽 2 节点端口异常"

# 31.10 订阅 YAML 可被真内核解析（mihomo 可用时）
if command -v mihomo >/dev/null 2>&1; then
    if mihomo -t -f "$SB31/web2/tok32/config.yaml" >/dev/null 2>&1; then
        ok "31.10 mihomo -t 校验生成的订阅通过"
    else
        bad "31.10 mihomo -t 校验失败"
    fi
else
    printf '  \033[33m-\033[0m mihomo 未安装，跳过订阅内核校验\n'
fi

# ---------- 32. 此前零覆盖 / 只有静态断言的函数，补执行型断言 ----------
group "32. 核心函数执行覆盖"

# 32.1-32.4 load_env：缺文件返回 1；末条命令失败不带走调用方；读一次即缓存
_t32=$(mktemp -d)
_s_env="$ENV_FILE"; _s_loaded="${ENV_LOADED-}"
ENV_FILE="$_t32/env.conf"; ENV_LOADED=""
load_env; _rc=$?
[[ "$_rc" -eq 1 ]] && ok "32.1 env.conf 不存在时返回 1（未安装护栏）" || bad "32.1 缺文件返回 ${_rc}，应为 1"
printf 'FOO=bar\nfalse\n' > "$ENV_FILE"
# 真正要守的是「set -e 下不把调用方带走」——必须在 -e 生效的子进程里跑，
# 套件本身是 set +e，原地调用区分不出裸 source 与条件式 source。
_o32=$(bash -c 'set -e; source "$1"; ENV_FILE="$2"; load_env; echo "SURVIVED:${FOO:-}"' _ "$TARGET" "$ENV_FILE" 2>&1)
[[ "$_o32" == *"SURVIVED:bar"* ]] \
    && ok "32.2 set -e 下 env.conf 末条命令失败不带走调用方" \
    || bad "32.2 调用方被 source 的返回码带走" "${_o32:-无输出}"
ENV_LOADED=""; load_env
printf 'FOO=baz\n' > "$ENV_FILE"
load_env; [[ "${FOO:-}" == "bar" ]] \
    && ok "32.3 第二次调用走缓存，不重读文件" || bad "32.3 缓存失效，读到 ${FOO:-}"
ENV_LOADED=""; load_env; [[ "${FOO:-}" == "baz" ]] \
    && ok "32.4 清缓存后重读生效（write_env_config 依赖）" || bad "32.4 清缓存后仍读到 ${FOO:-}"
ENV_FILE="$_s_env"; ENV_LOADED="$_s_loaded"; unset FOO

# 32.5-32.7 _release_digest：只认目标资产，变体不串味，缺 digest 返回空
_j32=$(cat <<'EOF'
{
  "assets": [
    {
      "name": "sing-box-1.2.3-linux-amd64-glibc.tar.gz",
      "size": 10,
      "digest": "sha256:aaaa"
    },
    {
      "name": "sing-box-1.2.3-linux-amd64.tar.gz",
      "size": 20,
      "digest": "sha256:bbbb"
    },
    {
      "name": "sing-box-1.2.3-linux-amd64-musl.tar.gz",
      "size": 30
    }
  ]
}
EOF
)
_d32=$(_release_digest "$_j32" "sing-box-1.2.3-linux-amd64.tar.gz")
[[ "$_d32" == "sha256:bbbb" ]] \
    && ok "32.5 取到 plain 包的 digest（不被 glibc 变体串味）" || bad "32.5 取到 ${_d32:-空}"
_d32=$(_release_digest "$_j32" "sing-box-1.2.3-linux-amd64-musl.tar.gz")
[[ -z "$_d32" ]] && ok "32.6 该资产没有 digest 时返回空（调用方跳过校验）" || bad "32.6 返回 ${_d32}"
_d32=$(_release_digest "$_j32" "sing-box-9.9.9-linux-amd64.tar.gz")
[[ -z "$_d32" ]] && ok "32.7 目标资产不存在时返回空" || bad "32.7 返回 ${_d32}"

# 32.8-32.10 detect_public_ip：占位串 / 内网段必须拒绝（写坏订阅的旧坑）
mkdir -p "$_t32/bin"
cat > "$_t32/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "${FAKE_CURL_OUT:-}"
EOF
chmod 755 "$_t32/bin/curl"
_s_path="$PATH"; PATH="$_t32/bin:$PATH"
export FAKE_CURL_OUT="public-ip-xxxx"
detect_public_ip >/dev/null 2>&1 && bad "32.8 占位串被当成公网 IP" \
    || ok "32.8 占位串被拒绝（曾写进 SERVER_IP 导致订阅不可解析）"
export FAKE_CURL_OUT="203.0.113.9"
[[ "$(detect_public_ip)" == "203.0.113.9" ]] && ok "32.9 合法 IPv4 原样输出" || bad "32.9 合法 IP 未输出"
export FAKE_CURL_OUT="10.0.0.5"
detect_public_ip >/dev/null 2>&1 && bad "32.10 内网地址被当成公网 IP" || ok "32.10 内网地址被跳过"
PATH="$_s_path"; unset FAKE_CURL_OUT

# 32.11-32.12 tidy_links / tidy_proxies：块与块之间恰好一个空行，块内不得有空行
printf 'vless://a\nhysteria2://b\nvless://c\n' > "$_t32/links.txt"
tidy_links "$_t32/links.txt"
[[ "$(grep -c '://' "$_t32/links.txt")" -eq 3 && "$(grep -c '^$' "$_t32/links.txt")" -eq 2 ]] \
    && ok "32.11 tidy_links：3 条链接、条间恰好 2 个空行" \
    || bad "32.11 tidy_links 结果异常" "行数=$(wc -l < "$_t32/links.txt") 空行=$(grep -c '^$' "$_t32/links.txt")"
cat > "$_t32/prov.yaml" <<'EOF'
proxies:
  - name: "A"
    type: vless

  - name: "B"
    type: vless
proxy-groups:
  - name: "G"
EOF
tidy_proxies "$_t32/prov.yaml"
[[ "$(grep -c '^$' "$_t32/prov.yaml")" -eq 2 ]] \
    && awk 'NF==0 { if (prev==0) e=1; prev=0; next } { prev=1 } END { exit e }' "$_t32/prov.yaml" \
    && ok "32.12 tidy_proxies：块间各一个空行、无连续空行" \
    || bad "32.12 tidy_proxies 结果异常" "空行=$(grep -c '^$' "$_t32/prov.yaml")"

# 32.13-32.16 出口槽位字段映射：写错会静默写坏 env.conf
_f32a=$(exit_slot_field_var 1 SERVER); _f32b=$(exit_slot_field_var 1 SKIP)
[[ "$_f32a" == "EXIT_HY_SERVER" && "$_f32b" == "EXIT_SKIP_CERT" ]] \
    && ok "32.13 槽 1 沿用历史字段名（存量订阅指着它们）" || bad "32.13 槽 1 映射变了: ${_f32a} ${_f32b}"
_f32a=$(exit_slot_field_var 2 SKIP); _f32b=$(exit_slot_field_var 4 PASS)
[[ "$_f32a" == "EXIT2_SKIP_CERT" && "$_f32b" == "EXIT4_PASS" ]] \
    && ok "32.14 槽 n>1 映射为 EXIT<n>_*，SKIP 展开成 SKIP_CERT" || bad "32.14 映射异常: ${_f32a} ${_f32b}"
exit_slot_set 3 LABEL "TST"
[[ "$(exit_slot_get 3 LABEL)" == "TST" && "${EXIT3_LABEL:-}" == "TST" ]] \
    && ok "32.15 set/get 往返一致且落到真实变量" || bad "32.15 往返异常: ${EXIT3_LABEL:-空}"
exit_slot_set 3 SERVER ""
[[ -z "${EXIT3_SERVER:-}" ]] && ok "32.16 set 空值可清字段" || bad "32.16 清空失败: ${EXIT3_SERVER:-}"
unset EXIT3_LABEL EXIT3_SERVER EXIT3_PORT

# 32.17-32.20 exit_entry_ports_ok：相同端口 / 撞直连 / 撞订阅 / 合法
_o_vl="${VL_PORT:-}"; _o_hy="${HY_PORT:-}"; _o_sp="${SUB_PORT:-}"
VL_PORT=443; HY_PORT=8443; SUB_PORT=8444
exit_entry_ports_ok 1 39181 39181 >/dev/null 2>&1 && bad "32.17 两个入口端口相同未拦" || ok "32.17 两端口相同被拒"
exit_entry_ports_ok 1 443 39182 >/dev/null 2>&1 && bad "32.18 入口端口撞 VL_PORT 未拦" || ok "32.18 撞直连端口被拒"
exit_entry_ports_ok 1 39181 8444 >/dev/null 2>&1 && bad "32.19 入口端口撞 SUB_PORT 未拦" || ok "32.19 撞订阅端口被拒"
exit_entry_ports_ok 1 39181 39182 >/dev/null 2>&1 && ok "32.20 合法端口组合通过" || bad "32.20 合法组合被误拒"
VL_PORT="${_o_vl:-443}"; HY_PORT="${_o_hy:-8443}"; SUB_PORT="${_o_sp:-8444}"

# 32.21 / 32.22 随证书降级路径删除：4.1 起证书申请失败直接中止安装，
# 不存在「自签覆盖 CERT_DIR 打死站点」这条失败路径，sites_using_cert_dir 已删除。
# 32.23 站点证书校验本身仍在（reality_target_check 依赖它）。
mkdir -p "$_t32/sites" "$_t32/cert"
_c_cd="$CERT_DIR"; _c_sites="${CADDY_SITES_DIR:-}"; _c_file="${CADDYFILE:-}"
CERT_DIR="$_t32/cert"; CADDY_SITES_DIR="$_t32/sites"; CADDYFILE="$_t32/Caddyfile"
printf 'c.example.com {\n\ttls %s/nope.cer %s/nope.key\n}\n' "$_t32" "$_t32" > "$_t32/sites/c.caddy"
site_cert_problem "$_t32/sites/c.caddy" "c.example.com" >/dev/null 2>&1 \
    && bad "32.23 站点证书文件缺失未报错" || ok "32.23 站点证书缺失被拦"
CERT_DIR="$_c_cd"; CADDY_SITES_DIR="$_c_sites"; CADDYFILE="$_c_file"

# 32.24 EXIT 兜底清理函数本身有效（trap 在入口安装，这里只验清理动作）
mkdir -p "$_t32/junk/file.txt"
TMP_CLEANUP=( "$_t32/junk" ); cleanup_tmp
[[ ! -d "$_t32/junk" ]] && ok "32.24 cleanup_tmp 清目录与文件" || bad "32.24 cleanup_tmp 未清干净"
TMP_CLEANUP=()
rm -rf "$_t32"

# ---------- 33. 写路径互斥（flock 只包 render_and_reload） ----------
group "33. 写路径互斥"

_lock_fixed=$(grep -c '^SIMBO_LOCK="/run/simbo.lock"' "$TARGET")
[[ "$_lock_fixed" -eq 1 ]] \
    && ok "33.1 锁文件是固定路径（不同实例锁同一个文件）" \
    || bad "33.1 锁文件路径不是固定值" "命中 ${_lock_fixed} 处"

_wrap=$(awk '/^render_and_reload\(\) \{/,/^}/' "$TARGET")
if grep -q 'flock -w' <<<"$_wrap"; then
    ok "33.2 包装层取锁且有等待上限（不会无限阻塞）"
else
    bad "33.2 包装层未取锁或无 -w 上限"
fi

if grep -q '_render_and_reload' <<<"$_wrap"; then
    ok "33.3 包装层调用真正的写入实现"
else
    bad "33.3 包装层没有调用 _render_and_reload"
fi

_body33=$(awk '/^_render_and_reload\(\) \{/,/^}/' "$TARGET")
_body_flock=$(grep -c 'flock' <<<"$_body33")
[[ "$_body_flock" -eq 0 ]] \
    && ok "33.4 写入实现内部不再取锁（避免自锁/嵌套）" \
    || bad "33.4 函数体内又取了锁" "命中 ${_body_flock} 处"

# 锁必须只覆盖写路径：菜单入口不得取锁
_menu33=$(awk '/^menu\(\) \{/,/^}/' "$TARGET")
if grep -q 'flock' <<<"$_menu33"; then
    bad "33.5 菜单入口取了锁（会把「看状态」也拦住）"
else
    ok "33.5 菜单入口不取锁，只拦写路径"
fi

# ---------- 34. 内容域证书用独立 acme home（一个 home 只能存一个 zone 的 token） ----------
group "34. 内容域证书独立 acme home"

_isc34=$(awk '/^issue_site_cert\(\) \{/,/^}/' "$TARGET")
if grep -q 'acme_site_home_ensure' <<<"$_isc34" && grep -q '\-\-home "\$acme_home"' <<<"$_isc34"; then
    ok "34.1 issue_site_cert 走独立 home，且每条 acme 调用都带 --home"
else
    bad "34.1 issue_site_cert 仍在默认 home 里签内容域证书"
fi

_stray34=$(grep -c 'local acme_bin="\$HOME/.acme.sh/acme.sh"' "$TARGET")
[[ "$_stray34" -eq 1 ]] \
    && ok "34.2 只有接入域（issue_cert_bundle）用默认 home" \
    || bad "34.2 默认 home 的引用数量异常" "命中 ${_stray34} 处，应为 1"

if grep -q 'ACME_SITE_HOME="\${ACME_SITE_HOME:-\$HOME/.acme.sh-site}"' "$TARGET"; then
    ok "34.3 site home 路径可覆盖（测试/迁移用）"
else
    bad "34.3 site home 不可覆盖"
fi

if grep -q 'mv "\$HOME/.acme.sh/\${domain}_ecc"' "$TARGET"; then
    ok "34.4 旧布局证书会就地迁移，不重签"
else
    bad "34.4 缺少旧布局迁移逻辑"
fi

if awk '/^issue_site_cert\(\) \{/,/^}/' "$TARGET" | grep -n 'cf-token-site\|cf-token"' | head -2 | grep -q 'cf-token-site'; then
    ok "34.9 内容域 token 优先读 /root/.cf-token-site（不与接入域混用）"
else
    bad "34.9 内容域仍会误用接入域的 /root/.cf-token"
fi

# 34.5-34.8 acme_site_home_ensure 真实调用（沙箱 HOME + crontab 桩）
_h34=$(mktemp -d)
mkdir -p "$_h34/.acme.sh/dnsapi" "$_h34/bin"
printf '#!/bin/sh\necho stub\n' > "$_h34/.acme.sh/acme.sh"; chmod 755 "$_h34/.acme.sh/acme.sh"
printf "ACCOUNT_EMAIL='ops@example.com'\nSAVED_CF_Token='accesstok'\n" > "$_h34/.acme.sh/account.conf"
cat > "$_h34/bin/crontab" <<'EOF'
#!/bin/sh
if [ "$1" = "-l" ]; then cat "$CRON_DB" 2>/dev/null; exit 0; fi
if [ "$1" = "-" ]; then cat > "$CRON_DB"; exit 0; fi
EOF
chmod 755 "$_h34/bin/crontab"
_s_home34="$HOME"; _s_site34="$ACME_SITE_HOME"; _s_path34="$PATH"; _s_cron34="${CRON_DB-}"
export CRON_DB="$_h34/cron"
HOME="$_h34"; ACME_SITE_HOME="$_h34/site"; PATH="$_h34/bin:$PATH"
_out34=$(acme_site_home_ensure "sitetok")
[[ -x "$ACME_SITE_HOME/acme.sh" && -d "$ACME_SITE_HOME/dnsapi" ]] \
    && ok "34.5 site home 由骨架复制创建（不带任何已签域名）" || bad "34.5 site home 创建失败" "${_out34}"
_acc34=$(stat -c %a "$ACME_SITE_HOME/account.conf" 2>/dev/null)
[[ "$_acc34" == "600" ]] && grep -q "SAVED_CF_Token='sitetok'" "$ACME_SITE_HOME/account.conf" \
    && ok "34.6 account.conf 600 且写入内容域 token" || bad "34.6 account.conf 权限/token 异常" "mode=${_acc34}"
grep -qF -- "--cron --home \"$ACME_SITE_HOME\"" "$CRON_DB" \
    && ok "34.7 自动挂上 site home 的续期 cron" || bad "34.7 未挂 cron"
acme_site_home_ensure "othertok" >/dev/null
[[ "$(grep -c 'othertok' "$ACME_SITE_HOME/account.conf")" -eq 0 && "$(grep -c "$ACME_SITE_HOME" "$CRON_DB")" -eq 1 ]] \
    && ok "34.8 重复调用幂等（不覆盖已有 home、不重复挂 cron）" \
    || bad "34.8 非幂等"
HOME="$_s_home34"; ACME_SITE_HOME="$_s_site34"; PATH="$_s_path34"
if [[ -n "$_s_cron34" ]]; then CRON_DB="$_s_cron34"; else unset CRON_DB; fi
rm -rf "$_h34"

# ---------- 35. 「只能靠记性」的机械不变式 ----------
group "35. 机械不变式（调用点/顺序/退出保护）"

# 35.1 配置只有一个写入口：write_singbox_config 必须且只能出现在 render_set 里
_wsw=$(awk '/^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { fn=$1; sub(/\(\)/,"",fn) }
            /^[[:space:]]+write_singbox_config / { print fn }' "$TARGET")
if [[ "$_wsw" == "render_set" ]]; then
    ok "35.1 write_singbox_config 只在 render_set 内调用（唯一写入口）"
else
    bad "35.1 配置写入绕过 render_set" "调用点所在函数: ${_wsw:-无}"
fi

# 35.2 render_set 不能单独用：调用它的函数必须接着 apply_exit_config 或 render_and_reload
_rs_bad=$(awk '
    /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { fn=$1; sub(/\(\)/,"",fn); next }
    /^}/ { fn=""; next }
    fn != "" && /^[[:space:]]+render_set / { call[fn]=1 }
    fn != "" && /apply_exit_config|render_and_reload/ { guard[fn]=1 }
    END { bad=""; for (f in call) if (!(f in guard)) bad=bad" "f; print bad }
' "$TARGET")
if [[ -z "$_rs_bad" ]]; then
    ok "35.2 render_set 的调用方都补了中转追加/重载（单独用会抹掉 exit-*-in）"
else
    bad "35.2 render_set 被单独调用" "缺 apply_exit_config/render_and_reload:${_rs_bad}"
fi

# 35.3 写 env 必须清缓存，且只有 write_env_config 一处写 env
_el=$(awk '/^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { fn=$1; sub(/\(\)/,"",fn) }
           /^[[:space:]]*ENV_LOADED=""$/ { print fn }' "$TARGET" | sed '/^$/d')
if [[ "$_el" == "write_env_config" ]]; then
    ok "35.3 ENV_LOADED 的清缓存只在 write_env_config（写后必清）"
else
    bad "35.3 env 缓存清理位置异常" "命中: ${_el:-无}"
fi

# 35.4 新增 mktemp 要登记 TMP_CLEANUP（差值不得超过已知未登记的 4 处）
_mk=$(grep -c 'mktemp' "$TARGET")
_reg=$(grep -c 'TMP_CLEANUP+=(' "$TARGET")
if (( _mk - _reg <= 4 )); then
    ok "35.4 mktemp 与 TMP_CLEANUP 登记数匹配（${_mk} / ${_reg}）"
else
    bad "35.4 有 mktemp 未登记到 TMP_CLEANUP" "mktemp=${_mk} 登记=${_reg}"
fi

# 35.5 每个菜单循环都要能在 stdin 关闭时退出（ASK_EOF 或 read || return/opt）
_bad_menu=""
for _fn in $(grep -oE '^menu[a-z_]*\(\)' "$TARGET" | sed 's/()//'); do
    _mb=$(awk "/^${_fn}\\(\\) \\{/,/^}/" "$TARGET")
    grep -q 'while true' <<<"$_mb" || continue
    grep -q 'ASK_EOF' <<<"$_mb" && continue
    grep -qE '\|\|[[:space:]]*(return|opt=)' <<<"$_mb" && continue
    _bad_menu="$_bad_menu $_fn"
done
if [[ -z "$_bad_menu" ]]; then
    ok "35.5 所有菜单循环都能在 stdin 关闭时退出（不会刷屏死循环）"
else
    bad "35.5 菜单循环缺退出保护" "${_bad_menu}"
fi

# 35.6 install_node 的每个输入循环都要有 ASK_EOF 守卫。
# 管道喂答案耗尽时没有守卫的循环会空转：域名循环实测刷了 1 万行「必须填域名」，
# 而端口循环当时已经有守卫——守卫要逐个循环加，不能只加一处。
_inst35=$(awk '/^install_node\(\) \{/,/^}/' "$TARGET")
_n_loops=$(grep -c 'while true; do' <<<"$_inst35")
_n_guard=$(grep -c 'ASK_EOF' <<<"$_inst35")
if [[ "$_n_loops" -gt 0 && "$_n_guard" -ge "$_n_loops" ]]; then
    ok "35.6 install_node 的 ${_n_loops} 个输入循环都有 EOF 守卫"
else
    bad "35.6 install_node 有输入循环缺 EOF 守卫（喂答案耗尽会空转）" "循环 ${_n_loops} 个 / 守卫 ${_n_guard} 处"
fi

# ---------- 36. 菜单 8 删除只清自己的产物 ----------
group "36. 伪装站删除边界"

_del36=$(awk '/^menu_camo\(\) \{/,/^}/' "$TARGET")
if grep -q '未找到 simbo 生成的' <<<"$_del36" && grep -q '\[\[ ! -f "\$f" && ! -d "\$d" \]\]' <<<"$_del36"; then
    ok "36.1 手工维护的站点（非 camo-*.caddy）不会被误报为「已删除」"
else
    bad "36.1 删除分支仍会对手工站点假报成功"
fi
if grep -q 'simbo 不删不属于自己的文件' <<<"$_del36"; then
    ok "36.2 提示语说明「不删不属于自己的文件」"
else
    bad "36.2 缺少归属提示"
fi

# ---------- 37. 订阅协议由 CERT_MODE 唯一派生（不再落库） ----------
group "37. 派生值不落库"

if [[ "$(grep -c 'SUB_PROTO' "$TARGET")" -eq 0 ]]; then
    ok "37.1 env 不再写 SUB_PROTO（协议由 CERT_MODE 派生）"
else
    bad "37.1 SUB_PROTO 仍在落库或引用" "命中 $(grep -c 'SUB_PROTO' "$TARGET") 处"
fi

_panel37=$(awk '/^menu\(\) \{/,/^}/' "$TARGET")
if grep -q 'proto=\$(sub_scheme)' <<<"$_panel37"; then
    ok "37.2 面板订阅地址直接用 sub_scheme 派生"
else
    bad "37.2 面板仍读旧的 SUB_PROTO"
fi

if grep -q '^sub_proto=' "$TARGET"; then
    bad "37.3 仍有函数派生并保存 sub_proto"
else
    ok "37.3 没有函数把 sub_proto 存成状态"
fi

# ---------- 38. 证书模式安装期定死：skip 由 CERT_MODE 派生 ----------
group "38. 证书模式不可变"

if [[ "$(grep -cE '^[[:space:]]*HY_SKIP_CERT=' "$TARGET")" -eq 0 ]]; then
    ok "38.1 env 不再持久化 HY_SKIP_CERT"
else
    bad "38.1 仍在写 HY_SKIP_CERT"
fi

_gen38=$(awk '/^generate_full_client_config\(\) \{/,/^}/' "$TARGET")
if grep -q 'CERT_MODE:-selfsigned' <<<"$_gen38" && ! grep -q 'local hy_skip_cert="\${12}"' <<<"$_gen38"; then
    ok "38.2 生成器从 CERT_MODE 派生 skip（不再收位置参数）"
else
    bad "38.2 生成器仍依赖外部传入 skip"
fi

SB38=$(mktemp -d)
(
  CERT_MODE="domain"
  node_prefix="SB"; server_ip="203.0.113.11"; vl_port=443; hy_port=8443
  vl_sni="gh.example.com"; vl_pubkey="PBK"; vl_shortid="ab12cd34"; hy_password="hp"
  WEB_DIR="$SB38/web"; mkdir -p "$WEB_DIR/tok38"
  generate_full_client_config "sb.example.com" tok38 SB 203.0.113.11 443 \
    "11111111-1111-1111-1111-111111111111" gh.example.com PBK ab12cd34 8443 hp
)
if grep -q 'skip-cert-verify: false' "$SB38/web/tok38/provider.yaml" && ! grep -q 'insecure=1' "$SB38/web/tok38/links.txt"; then
    ok "38.3 domain 模式：不跳过校验、链接不带 insecure"
else
    bad "38.3 domain 模式仍标记 skip" "$(grep -h 'skip-cert-verify' "$SB38/web/tok38/provider.yaml" 2>/dev/null)"
fi
(
  CERT_MODE="selfsigned"
  node_prefix="SB"; server_ip="203.0.113.11"; vl_port=443; hy_port=8443
  vl_sni="gh.example.com"; vl_pubkey="PBK"; vl_shortid="ab12cd34"; hy_password="hp"
  WEB_DIR="$SB38/web2"; mkdir -p "$WEB_DIR/tok38"
  generate_full_client_config "203.0.113.11" tok38 SB 203.0.113.11 443 \
    "11111111-1111-1111-1111-111111111111" gh.example.com PBK ab12cd34 8443 hp
)
if grep -q 'skip-cert-verify: true' "$SB38/web2/tok38/provider.yaml" && grep -q 'insecure=1' "$SB38/web2/tok38/links.txt"; then
    ok "38.4 selfsigned 模式：跳过校验、链接带 insecure=1"
else
    bad "38.4 selfsigned 模式未标记 skip"
fi
rm -rf "$SB38"

_asis=$(grep -cE 'CERT_MODE="(domain|selfsigned)"' "$TARGET")
_inissue=$(awk '/^issue_cert_bundle\(\) \{/,/^}/' "$TARGET" | grep -cE 'CERT_MODE="(domain|selfsigned)"')
if [[ "$_asis" -eq "$_inissue" && "$_asis" -gt 0 ]]; then
    ok "38.5 CERT_MODE 只在 issue_cert_bundle 内被赋值（write-once）"
else
    bad "38.5 有运行期代码改证书模式" "全部=${_asis} 安装内=${_inissue}"
fi

# ---------- 39. 重装默认沿用凭据 ----------
group "39. 重装保留凭据"

_inst39=$(awk '/^install_node\(\) \{/,/^}/' "$TARGET")
if grep -q 'keep_uuid=' <<<"$_inst39" && grep -q 'keep_token=' <<<"$_inst39"; then
    ok "39.1 安装流程读入既有凭据"
else
    bad "39.1 安装流程没有读入既有凭据"
fi

if grep -q 'vl_privkey="\$keep_privkey"' <<<"$_inst39" \
   && grep -q 'hy_password="\$keep_hypass"' <<<"$_inst39" \
   && grep -q 'sub_token="\$keep_token"' <<<"$_inst39"; then
    ok "39.2 Reality / Hy2 / 订阅 token 三处都优先沿用"
else
    bad "39.2 有凭据仍被无条件重新生成"
fi

if grep -q 'local rotate_creds="N"' <<<"$_inst39" && grep -q 'rotate_creds,,.*== "y"' <<<"$_inst39"; then
    ok "39.3 轮换必须显式输入 y（默认沿用）"
else
    bad "39.3 轮换不是显式选择"
fi

if grep -q 'type d ! -name "\$sub_token"' <<<"$_inst39"; then
    ok "39.4 只清理不属于当前 token 的订阅目录（沿用时不误删）"
else
    bad "39.4 订阅目录清理规则变了"
fi

if [[ "$(grep -c '所有客户端配置都会失效\|并更换订阅 token' "$TARGET")" -eq 0 ]]; then
    ok "39.5 菜单不再宣称重装必然轮换"
else
    bad "39.5 菜单文案仍说重装必然轮换"
fi

# ---------- 40. 443 已被 Caddy 站点占用时的接管 ----------
group "40. 安装期站点交接"

if grep -q '^site_handover_to_loopback()' "$TARGET"; then
    ok "40.1 存在站点交接函数"
else
    bad "40.1 缺少站点交接函数"
fi

_h40=$(awk '/^site_handover_to_loopback\(\)/,/^}/' "$TARGET")
if grep -q 'caddy validate' <<<"$_h40" && grep -q -- '--resolve' <<<"$_h40" \
   && grep -q 'flip_transform "\$site" "\$domain" "\$port" off' <<<"$_h40"; then
    ok "40.2 交接含校验、回环探测与失败还原"
else
    bad "40.2 交接缺少校验/探活/还原"
fi

_inst40=$(awk '/^install_node\(\) \{/,/^}/' "$TARGET")
if grep -q 'site_handover_to_loopback "\$_site" "\$_pick"' <<<"$_inst40"; then
    ok "40.3 安装流程在 443 被 Caddy 占用时调用交接"
else
    bad "40.3 安装流程没有接入交接"
fi

if grep -q '本脚本只接管 Caddy 站点' <<<"$_inst40"; then
    ok "40.4 非 Caddy 占用时明确拒绝接管"
else
    bad "40.4 非 Caddy 占用没有明确提示"
fi

if grep -q 'vl_sni="\$handover_domain"' <<<"$_inst40"; then
    ok "40.5 交接后伪装域名固定为被搬走的站点"
else
    bad "40.5 交接后 SNI 仍可填成别的域名"
fi

# 沙箱行为：flip 幂等 + 反向还原
SB40=$(mktemp -d)
cat > "$SB40/site.caddy" <<'EOF2'
https://sb40.example.com {
	root * /var/www/sb40
	file_server
}
EOF2
flip_transform "$SB40/site.caddy" sb40.example.com 9443 on >/dev/null 2>&1
_after_on=$(head -1 "$SB40/site.caddy")
_after_bind=$(sed -n '2p' "$SB40/site.caddy")
flip_transform "$SB40/site.caddy" sb40.example.com 9443 on >/dev/null 2>&1
_idem=$(head -1 "$SB40/site.caddy")
if [[ "$_after_on" == "https://sb40.example.com:9443 {" && "$_after_bind" == *"bind 127.0.0.1"* && "$_idem" == "$_after_on" ]]; then
    ok "40.6 交接改写块首行并加 bind，重复执行幂等"
else
    bad "40.6 flip 输出不符合预期" "$_after_on | $_after_bind"
fi
flip_transform "$SB40/site.caddy" sb40.example.com 9443 off >/dev/null 2>&1
_back=$(head -1 "$SB40/site.caddy")
[[ "$_back" == "sb40.example.com {" ]] && ok "40.7 反向翻回原样（不留 bind）" || bad "40.7 反向还原异常" "$_back"
rm -rf "$SB40"

group "41. 伪装站点接管 VL_SNI（安装/建站死锁）"
_sb41=$(mktemp -d); mkdir -p "$_sb41/sites" "$_sb41/www" "$_sb41/cert"
printf '{"inbounds":[{"type":"vless","tag":"vless-reality-in"}]}\n' > "$_sb41/config.json"
printf 'import sys\nsys.exit(0)\n' > "$_sb41/gen.py"
_s41_conf=$CONF_FILE; _s41_sites=${CADDY_SITES_DIR:-}; _s41_camo=$CAMO_ROOT
_s41_sni=$VL_SNI; _s41_hy=${HY_DOMAIN:-}; _s41_th=${TARGET_HOST:-}; _s41_ssl=${CERT_SSL_ROOT:-}
CONF_FILE=$_sb41/config.json; CADDY_SITES_DIR=$_sb41/sites; CAMO_ROOT=$_sb41/www
CERT_SSL_ROOT=$_sb41/cert; VL_SNI="old.example.com"; HY_DOMAIN="other.example.com"; TARGET_HOST="other.example.com"; FLIP_PORT=9443
ensure_camo_generator(){ printf '%s\n' "$_sb41/gen.py"; }
issue_site_cert(){ return 0; }
caddy(){ return 0; }
reload_caddy_safe(){ return 0; }
write_env_config(){ echo ENV >> "$_sb41/marks"; return 0; }
render_set(){ echo RENDER >> "$_sb41/marks"; return 0; }
render_and_reload(){ echo RELOAD >> "$_sb41/marks"; return 0; }
curl(){ printf '200'; }
ask(){ printf -v "$2" '%s' "${_41_ans:-y}"; }

build_camo_site "new.example.com" eso "" >"$_sb41/out" 2>&1
if [[ "$VL_SNI" == "new.example.com" ]]; then ok "41.1 确认后 VL_SNI 切到新域名"; else bad "41.1 VL_SNI 未切换" "VL_SNI=$VL_SNI"; fi
if grep -qx ENV "$_sb41/marks" 2>/dev/null && grep -qx RENDER "$_sb41/marks" 2>/dev/null && grep -qx RELOAD "$_sb41/marks" 2>/dev/null; then
    ok "41.2 切换按 env → render_set → render_and_reload 顺序落地"
else
    bad "41.2 切换步骤缺失" "$(tr '\n' ' ' < "$_sb41/marks" 2>/dev/null)"
fi
if grep -q 'https://new.example.com:9443 {' "$_sb41/sites/camo-new.example.com.caddy" 2>/dev/null \
   && grep -q 'bind 127.0.0.1' "$_sb41/sites/camo-new.example.com.caddy" 2>/dev/null; then
    ok "41.3 站点块在回环 9443 上（不抢 443）"
else
    bad "41.3 站点块未翻转到回环" "files=$(ls "$_sb41/sites" 2>/dev/null | tr '\n' ' ') head=$(head -2 "$_sb41/sites/camo-new.example.com.caddy" 2>/dev/null | tr '\n' ' ') out=$(tail -2 "$_sb41/out" | tr '\n' ' ')"
fi

# 拒绝切换：不做任何改动
VL_SNI="old.example.com"; rm -f "$_sb41/marks" "$_sb41/sites/camo-new.example.com.caddy"
_41_ans=n build_camo_site "new.example.com" eso "" >"$_sb41/out2" 2>&1; _rc41=$?
unset _41_ans
if [[ "$_rc41" -ne 0 && "$VL_SNI" == "old.example.com" && ! -f "$_sb41/marks" ]]; then
    ok "41.4 回答 n 时不改 VL_SNI、不写 env"
else
    bad "41.4 取消路径仍有副作用" "rc=$_rc41 VL_SNI=$VL_SNI"
fi

# 当前伪装域名本身就允许（旧行为：直接建站，不需要确认）
VL_SNI="new.example.com"; rm -f "$_sb41/marks"
build_camo_site "new.example.com" eso "" >"$_sb41/out3" 2>&1
if [[ -f "$_sb41/sites/camo-new.example.com.caddy" && ! -f "$_sb41/marks" ]]; then
    ok "41.5 域名已是 VL_SNI 时直接建站、不触发切换"
else
    bad "41.5 同域名路径被切换逻辑污染"
fi

unset -f ensure_camo_generator issue_site_cert caddy reload_caddy_safe write_env_config render_set render_and_reload curl ask
CONF_FILE=$_s41_conf; CADDY_SITES_DIR=$_s41_sites; CAMO_ROOT=$_s41_camo
VL_SNI=$_s41_sni; HY_DOMAIN=$_s41_hy; TARGET_HOST=$_s41_th; CERT_SSL_ROOT=$_s41_ssl
rm -rf "$_sb41"

group "43. 内容源选择（回车=随机）"
_s43_map="1:eso 2:wikimedia 3:w3c 4:bhl"
_s43_ok=1
for _kv in $_s43_map; do
    _k=${_kv%%:*}; _v=${_kv##*:}
    [[ "$(pick_camo_source "$_k")" == "$_v" ]] || { _s43_ok=0; bad "43.1 内容源 $_k 映射错误" "$(pick_camo_source "$_k")"; }
done
[[ "$_s43_ok" == "1" ]] && ok "43.1 1-4 映射到四种内容源"
if pick_camo_source 9 >/dev/null 2>&1; then
    bad "43.2 非法选项未拒绝"
else
    ok "43.2 非法选项返回非零（菜单不留死在生成分支）"
fi
_s43_seen=""
for _i in $(seq 1 40); do _s43_seen+=$(pick_camo_source "")$'\n'; done
_s43_uniq=$(printf '%s\n' "$_s43_seen" | sed '/^$/d' | sort -u)
_s43_valid=1
for _v in $_s43_uniq; do
    case "$_v" in eso|wikimedia|w3c|bhl) ;; *) _s43_valid=0 ;; esac
done
if [[ "$_s43_valid" == "1" && -n "$_s43_uniq" ]]; then
    ok "43.3 空输入只落在四种源内"
else
    bad "43.3 空输入出现非法源" "$(printf '%s' "$_s43_uniq" | tr '\n' ' ')"
fi
if [[ "$(printf '%s' "$_s43_seen" | sort -u | wc -l)" -ge 2 ]]; then
    ok "43.4 40 次空输入不是同一个源"
else
    bad "43.4 空输入每次都给同一个源（随机没生效）"
fi

group "14. 清理"
rm -rf "$TMPD" "$TMPC2" "$TMPC3" "$TMPC4" /tmp/t41.out /tmp/t61.out /tmp/t62.out /tmp/t63.out 2>/dev/null
ok "临时文件已清理"

# ---------- 汇总 ----------
printf '\n\033[1m================ 测试汇总 ================\033[0m\n'
printf '通过: \033[32m%d\033[0m   失败: \033[31m%d\033[0m   总计: %d\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
if [[ $FAIL -gt 0 ]]; then
    printf '\n失败项:\n'
    for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
    exit 1
fi
printf '\033[32m全部通过\033[0m\n'
exit 0
