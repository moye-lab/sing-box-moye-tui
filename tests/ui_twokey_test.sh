#!/usr/bin/env bash
# =====================================================================
#  tests/ui_twokey_test.sh — 数字键回车确认 + 字母键立即执行回归测试
#  用法：bash tests/ui_twokey_test.sh（仓库根目录或任意目录均可）
#  覆盖（2026-11-15 用户要求）：字母键立即匹配执行，无需回车；数字键
#  只缓存回显，必须按回车确认才匹配（否则输两位数如 10 会误入 1）。
#  旧行为（0.4 秒缓冲：快按两位选中、单按停顿后按首位匹配）已废弃，
#  本文件按新规则重写。
#  覆盖：两位数+回车选中（10/11/12/13），一位数+回车选中，无效数字
#  回车后留在菜单并可继续输入，字母键立即匹配，数字未回车时不执行，
#  数字后跟字母/q 时缓存被丢弃，退格删数字缓存。
#  退出码：0 全部通过（SKIP 不计失败），1 有 FAIL。
# =====================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP: %s\n' "$1"; }

if locale -a 2>/dev/null | grep -qiE '^C\.utf8$'; then
    export LC_ALL=C.utf8
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

if ! command -v script >/dev/null 2>&1; then
    skip "数字键回车确认 PTY（沙箱无 script 命令）"
elif ! command -v timeout >/dev/null 2>&1; then
    skip "数字键回车确认 PTY（沙箱无 timeout 命令）"
else
    # 15 项主菜单同构 entry（key 含 10/11/12/13 两位数快捷键）
    cat > "$TMPD/pty_menu15.sh" <<'PTYEOF'
#!/usr/bin/env bash
export LC_ALL=C.utf8 TERM=xterm
source "${ROOT}/core/env.sh"
source "${ROOT}/core/ui.sh"
before=$(stty -g)
ui_menu_select "请选择功能" 0 \
    "1/r|VLESS-Reality|d1" "2/h|Hysteria 2|d2" "3/t|TUIC v5|d3" \
    "4/a|AnyTLS|d4" "5/p|Cloudflare Argo|d5" "6/y|SOCKS5|d6" \
    "7/i|一键全装|d7" "8/e|节点订阅中心|d8" "9/n|节点命名规则|d9" \
    "10/o|系统网络调优|d10" "11/s|内核服务维护|d11" "12/d|运行环境诊断|d12" \
    "13/w|WARP 与域名分流|d13" "x|彻底卸载清理|dx" "0/q|退出管理面板|"
rc=$?
after=$(stty -g)
echo "MENU_RC=$rc IDX=$UI_SEL_IDX KEY=$UI_SEL_KEY"
if [[ "$before" == "$after" ]]; then echo "STTY_OK"; else echo "STTY_DIFF before=$before after=$after"; fi
PTYEOF
    chmod +x "$TMPD/pty_menu15.sh"

    # $1 = 按键投递脚本（bash 代码，先 sleep 0.6 等菜单打印完列表再按键；
    # 尾部 sleep 保持管道打开）
    run_pty_keys() {
        local _sender="$1"
        ( eval "$_sender" ) \
            | ROOT="$ROOT" timeout 15 script -qec "bash $TMPD/pty_menu15.sh" /dev/null 2>/dev/null | tr -d '\r'
    }
    expect_key() { # $1=描述 $2=按键脚本 $3=期望 KEY
        local _desc="$1" _sender="$2" _key="$3" _pty
        _pty=$(run_pty_keys "$_sender")
        if [[ "$_pty" == *"MENU_RC=0"* && "$_pty" == *"KEY=$_key"* && "$_pty" == *"STTY_OK"* ]]; then
            ok "$_desc"
        else
            fail "$_desc：${_pty}"
        fi
    }
    expect_rc() { # $1=描述 $2=按键脚本 $3=期望 RC
        local _desc="$1" _sender="$2" _rc="$3" _pty
        _pty=$(run_pty_keys "$_sender")
        if [[ "$_pty" == *"MENU_RC=$_rc"* && "$_pty" == *"STTY_OK"* ]]; then
            ok "$_desc"
        else
            fail "$_desc：${_pty}"
        fi
    }

    # 1. 输入 12 + 回车 → 诊断 12/d
    expect_key "输入 12 回车选中 12/d" \
        "sleep 0.6; printf '12'; sleep 0.3; printf '\n'; sleep 0.5" "12/d"
    # 2. 输入 13 + 回车 → WARP 13/w
    expect_key "输入 13 回车选中 13/w" \
        "sleep 0.6; printf '13'; sleep 0.3; printf '\n'; sleep 0.5" "13/w"
    # 3. 输入 10 + 回车 → 调优 10/o
    expect_key "输入 10 回车选中 10/o" \
        "sleep 0.6; printf '10'; sleep 0.3; printf '\n'; sleep 0.5" "10/o"
    # 4. 输入 11 + 回车 → 维护 11/s
    expect_key "输入 11 回车选中 11/s" \
        "sleep 0.6; printf '11'; sleep 0.3; printf '\n'; sleep 0.5" "11/s"
    # 5. 输入 1 + 回车 → Reality 1/r（一位数同样需回车）
    expect_key "输入 1 回车选中 1/r" \
        "sleep 0.6; printf '1'; sleep 0.3; printf '\n'; sleep 0.5" "1/r"
    # 6. 输入 2 + 回车 → Hy2 2/h
    expect_key "输入 2 回车选中 2/h" \
        "sleep 0.6; printf '2'; sleep 0.3; printf '\n'; sleep 0.5" "2/h"
    # 7. 输入 19 + 回车（无 19 快捷键）→ 显示无效提示、留在菜单；再输 1 回车 → 1/r
    _pty=$(run_pty_keys "sleep 0.6; printf '19'; sleep 0.3; printf '\n'; sleep 0.5; printf '1'; sleep 0.3; printf '\n'; sleep 0.5")
    if [[ "$_pty" == *"MENU_RC=0"* && "$_pty" == *"KEY=1/r"* && "$_pty" == *"无效选项"* && "$_pty" == *"STTY_OK"* ]]; then
        ok "输入 19 回车无效提示后可继续输入 1 回车选中 1/r"
    else
        fail "输入 19 回车无效后继续输入：${_pty}"
    fi
    # 8. 字母键 d 立即选中 12/d（无需回车）
    expect_key "字母键 d 立即选中 12/d（无需回车）" \
        "sleep 0.6; printf 'd'; sleep 0.5" "12/d"
    # 9. 输入 12 不回车、停顿 1.0 秒（超过旧 0.4 秒缓冲窗）→ 不执行；再按 q 退出
    expect_rc "输入 12 不回车停顿后不执行（q 退出 RC=2）" \
        "sleep 0.6; printf '12'; sleep 1.0; printf 'q'; sleep 0.5" "2"
    # 10. 输入 9 后跟 q（无回车）：数字缓存被丢弃，q 退出 RC=2
    expect_rc "输入 9 后跟 q 时缓存丢弃、q 退出 RC=2" \
        "sleep 0.6; printf '9'; sleep 0.3; printf 'q'; sleep 0.5" "2"
    # 11. 输入 9 后跟字母 d：数字缓存被丢弃，d 立即选中 12/d
    expect_key "输入 9 后跟字母 d 时缓存丢弃、d 立即选中 12/d" \
        "sleep 0.6; printf '9'; sleep 0.3; printf 'd'; sleep 0.5" "12/d"
    # 12. 输入 19 后退格删 9、再输 2 回车 → 12/d
    expect_key "输入 19 退格改 12 回车选中 12/d" \
        "sleep 0.6; printf '19'; sleep 0.3; printf '\177'; sleep 0.3; printf '2'; sleep 0.3; printf '\n'; sleep 0.5" "12/d"
fi

# =====================================================================
# 汇总
# =====================================================================
printf '\n==============================\n'
printf 'TWOKEY TEST SUMMARY: PASS=%s FAIL=%s SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
printf '==============================\n'
(( FAIL > 0 )) && exit 1
exit 0
