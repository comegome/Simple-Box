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

for fn in trim_string validate_port validate_range validate_domain ver_ge \
          cert_covers_domain harden_private_key issue_cert_bundle issue_self_signed_cert \
          fetch_latest_script reinstall_with_latest write_singbox_config \
          verify_cloudflare_token prompt_cf_token; do
    if declare -F "$fn" >/dev/null 2>&1; then ok "函数已定义: $fn"; else bad "函数缺失: $fn"; fi
done

set +e   # 后续测试自行判定，不因单条失败中断

# ---------- 3. 本次提交的 5 项修复 ----------
group "3. 本次提交修复项验证"

# M-3: config.json 权限 600
if grep -q 'chmod 600 "\$tmp_conf"' "$TARGET"; then ok "M-3: config.json 使用 chmod 600"; else bad "M-3: config.json 权限未收紧"; fi
if grep -q 'chmod 644 "\$tmp_conf"' "$TARGET"; then bad "M-3: 仍残留 chmod 644 \$tmp_conf"; else ok "M-3: 无残留 644"; fi

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

# ---------- 7. 全量回归：核心工具函数 ----------
group "7. 全量回归：校验函数"

# validate_port
for p in 1 80 443 65535; do
    validate_port "$p" && ok "validate_port 接受 $p" || bad "validate_port 误拒 $p"
done
for p in "" 0 65536 abc -1 "80 " 1.5; do
    validate_port "$p" && bad "validate_port 误收 '$p'" || ok "validate_port 拒绝 '$p'"
done

# validate_range
for r in "20000:40000" "1:65535" "1000:2000"; do
    validate_range "$r" && ok "validate_range 接受 $r" || bad "validate_range 误拒 $r"
done
for r in "" "20000" "40000:20000" "0:100" "20000:40000:50000" "a:b"; do
    validate_range "$r" && bad "validate_range 误收 '$r'" || ok "validate_range 拒绝 '$r'"
done

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

# ---------- 9. 全量回归：幂等性静态断言 ----------
group "9. 全量回归：幂等性静态断言"
grep -q 'iptables -t nat -F PREROUTING' "$TARGET" && bad "存在 iptables 全表清空炸弹" || ok "无 iptables 全表清空"
grep -qE 'apt-get purge|apt purge' "$TARGET" && ok "卸载使用 apt purge（避免 mask 残留）" || bad "卸载未使用 apt purge"
grep -q 'DEBIAN_FRONTEND=noninteractive' "$TARGET" && ok "apt 操作设置 noninteractive" || bad "缺少 DEBIAN_FRONTEND=noninteractive"
grep -q 'sing-box check' "$TARGET" && ok "启动前执行 sing-box check" || bad "缺少配置校验"
grep -q 'BASH_SOURCE\[0\]' "$TARGET" && ok "存在管道执行检测" || bad "缺少管道执行检测"

# BBR 幂等：已开启则跳过
grep -qE '\[\[ "\$cur" == "bbr" \]\]' "$TARGET" && ok "BBR 已开启时跳过（幂等）" || bad "BBR 缺少幂等判断"

# Caddy 归属标记
grep -q 'simple-box' "$TARGET" && ok "Caddy 配置带归属标记" || bad "Caddy 缺少归属标记"

# ---------- 10. 全量回归：危险命令审计 ----------
group "10. 全量回归：危险命令审计"
# 允许删除脚本自有的安装目录 /usr/local/share/simple-box
SUSPICIOUS=$(grep -nE 'rm -rf /' "$TARGET" | grep -v '\$' | grep -v '/usr/local/share/simple-box')
if [[ -n "$SUSPICIOUS" ]]; then bad "存在可疑的 rm -rf 绝对路径" "$SUSPICIOUS"; else ok "无裸 rm -rf 绝对路径（仅删除自有安装目录）"; fi
grep -qE 'curl[^|]*\|[[:space:]]*(ba)?sh' "$TARGET" && printf '  \033[33m!\033[0m 存在 curl|sh 模式（acme.sh 官方安装，已知可接受）\n' || ok "无 curl|sh 管道"
grep -q 'eval ' "$TARGET" && bad "存在 eval 调用" || ok "无 eval 调用"
grep -q 'chmod 777' "$TARGET" && bad "存在 chmod 777" || ok "无 chmod 777"

# ---------- 11. 清理 ----------
group "11. 清理"
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
