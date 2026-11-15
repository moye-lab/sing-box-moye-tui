#!/usr/bin/env bash
# =====================================================================
#  tests/termius_fix_test.sh — Termius 修复回归测试
#  用法：bash tests/termius_fix_test.sh（仓库根目录或任意目录均可）
#  背景（2026-11-15 用户真机反馈）：iPhone Termius 上按方向键出现
#  ^[[D^[[A^[[B^[[C，菜单不导航。根因：TUI 仓库 install.sh 的下载地址
#  仍指向主线仓库，一键安装装的是主线 v1.7.0（纯 read -rp 菜单，无方向键
#  支持），用户根本没跑上 TUI 代码。本测试覆盖：
#    1. install.sh 引导地址指向 TUI 仓库 + 正确 tag 与解压目录
#    2. ui_tty_ready 判定：TERM=dumb/未设置不再硬性拦截，SBM_MENU_LINE 强制行模式
#    3. TTY 下逐字节读键：字母立即、数字需回车；方向键序列被忽略且不漏出 ^[[
#    4. 菜单不再调用 stty：stty 完全失效时菜单仍可正常工作
#    5. SBM_DEBUG_MENU=1 打印 TTY 检测详情
#    6. 快捷命令提示按终端宽度自适应，不在单词中部换行
#  注：方向键导航已于 2026-11-15 移除（用户决定），本文件相关用例已改为
#  字母/数字键；"行模式方向键"相关断言改为方向键序列忽略断言。
#  退出码：0 全部通过（SKIP 不计失败），1 有 FAIL。
# =====================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; SKIP=0
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

ok()   { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP: %s\n' "$1"; }

if locale -a 2>/dev/null | grep -qiE '^C\.utf8$'; then
    export LC_ALL=C.utf8
fi

# 加载被测代码（source sbx.sh 会连带加载全部模块；被 source 时不启动菜单）
source "$ROOT/sbx.sh"

# =====================================================================
# 1. install.sh 引导地址（根因回归）
# =====================================================================
_BOOT_URL="$(grep -m1 '_URL=' "$ROOT/install.sh" || true)"
_BOOT_REPO="$(grep -m1 '^SBX_REPO=' "$ROOT/install.sh" | sed 's/.*"\([^"]*\)".*/\1/')"
_BOOT_TAG="$(grep -m1 '^SBX_TAG=' "$ROOT/install.sh" | sed 's/.*"\([^"]*\)".*/\1/')"
if [[ "$_BOOT_REPO" == "sing-box-moye-tui" ]]; then
    ok "install.sh 引导仓库为 sing-box-moye-tui"
else
    fail "install.sh SBX_REPO=$_BOOT_REPO（期望 sing-box-moye-tui）"
fi
if [[ "$_BOOT_TAG" == "v1.7.0-tui" ]]; then
    ok "install.sh 引导 tag 为 v1.7.0-tui"
else
    fail "install.sh SBX_TAG=$_BOOT_TAG（期望 v1.7.0-tui）"
fi
if [[ "$_BOOT_URL" == *'${SBX_REPO}'* && "$_BOOT_URL" == *'${SBX_TAG}'* ]]; then
    ok "install.sh 下载 URL 使用 SBX_REPO/SBX_TAG 变量"
else
    fail "install.sh 下载 URL 未使用 SBX_REPO/SBX_TAG：$_BOOT_URL"
fi
if grep -q 'sing-box-moye/archive/refs/tags' "$ROOT/install.sh"; then
    fail "install.sh 仍有指向主线仓库的下载地址"
else
    ok "install.sh 无指向主线仓库的下载地址"
fi
# 解压目录名须与 GitHub tarball 实际布局一致（<repo>-<tag 去 v 前缀>）
_BOOT_DIR="${_BOOT_REPO}-${_BOOT_TAG#v}"
if grep -qF '"${_TMPD}/${SBX_REPO}-${SBX_TAG#v}/install.sh"' "$ROOT/install.sh"; then
    ok "install.sh 转交路径为 \${SBX_REPO}-\${SBX_TAG#v}（=${_BOOT_DIR}）"
else
    fail "install.sh 转交路径未使用 \${SBX_REPO}-\${SBX_TAG#v}"
fi
# 实测 GitHub tarball 顶层目录（有网络时验证，无网络则跳过）
if command -v curl >/dev/null 2>&1; then
    if curl -fsSL --max-time 20 -o "$TMPD/tui.tar.gz" \
            "https://github.com/moye-lab/${_BOOT_REPO}/archive/refs/tags/${_BOOT_TAG}.tar.gz" 2>/dev/null \
        && _topdir="$(tar -tzf "$TMPD/tui.tar.gz" 2>/dev/null | head -1)"; then
        if [[ "$_topdir" == "${_BOOT_DIR}/" ]]; then
            ok "GitHub tarball 顶层目录为 ${_BOOT_DIR}/，与转交路径一致"
        else
            fail "GitHub tarball 顶层目录为 ${_topdir}，与 ${_BOOT_DIR}/ 不一致"
        fi
    else
        skip "GitHub tarball 顶层目录（下载失败，可能无网络）"
    fi
else
    skip "GitHub tarball 顶层目录（沙箱无 curl）"
fi

# =====================================================================
# 2. ui_tty_ready 判定（非 TTY 环境）
# =====================================================================
if ui_tty_ready 2>/dev/null; then
    fail "ui_tty_ready 在非 TTY 下应返回 1"
else
    ok "ui_tty_ready 在非 TTY 下返回 1"
fi
_dbg=$(SBM_DEBUG_MENU=1 ui_tty_ready 2>&1 >/dev/null || true)
if [[ "$_dbg" == *"[menu-debug]"* && "$_dbg" == *"stdin_tty=0"* ]]; then
    ok "SBM_DEBUG_MENU=1 打印检测详情（含 stdin_tty=0）"
else
    fail "SBM_DEBUG_MENU 输出缺失或格式不对：$_dbg"
fi

# =====================================================================
# 3. 快捷命令提示宽度自适应
# =====================================================================
_hint_max_width() { # 逐行测显示宽度，输出最大值 → HINT_MAX
    local line w max=0
    HINT_MAX=0
    while IFS= read -r line; do
        ui_vwidth "$line"
        w=$UI_VW
        (( w > max )) && max=$w
    done <<< "$1"
    HINT_MAX=$max
}
UI_COLS=120
_hint_out="$(_sbx_cli_hint)"
_hint_max_width "$_hint_out"
if [[ "$_hint_out" == *"subscription|export|rename|bbr"* && $HINT_MAX -le 120 ]]; then
    ok "120 列：完整单行提示（最大宽度 $HINT_MAX）"
else
    fail "120 列提示异常（最大宽度 $HINT_MAX）：$_hint_out"
fi
UI_COLS=80
_hint_out="$(_sbx_cli_hint)"
_hint_max_width "$_hint_out"
if [[ "$_hint_out" == *"export"* && "$_hint_out" != *"expor"$'\n'* && $HINT_MAX -le 80 ]]; then
    ok "80 列：两行提示且 export 未被截断（最大宽度 $HINT_MAX）"
else
    fail "80 列提示异常（最大宽度 $HINT_MAX）：$_hint_out"
fi
# 两行第二行的 [ 与第一行 [ 显示列对齐
_line1="$(printf '%s' "$_hint_out" | sed -n '1p')"
_line2="$(printf '%s' "$_hint_out" | sed -n '2p')"
ui_vwidth "${_line1%%[*}"; _c1=$UI_VW
ui_vwidth "${_line2%%[*}"; _c2=$UI_VW
if [[ -n "$_line2" && "$_c1" == "$_c2" ]]; then
    ok "80 列：两行 [ 对齐（均在第 $((_c1 + 1)) 列）"
else
    fail "80 列：两行 [ 不对齐（$((_c1 + 1)) vs $((_c2 + 1))）"
fi
UI_COLS=60
_hint_out="$(_sbx_cli_hint)"
_hint_max_width "$_hint_out"
if (( HINT_MAX <= 60 )); then
    ok "60 列：提示不越界（最大宽度 $HINT_MAX）"
else
    fail "60 列提示越界（最大宽度 $HINT_MAX）：$_hint_out"
fi
UI_COLS=40
_hint_out="$(_sbx_cli_hint)"
_hint_max_width "$_hint_out"
if (( HINT_MAX <= 40 )); then
    ok "40 列：短格式提示不越界（最大宽度 $HINT_MAX）"
else
    fail "40 列提示越界（最大宽度 $HINT_MAX）：$_hint_out"
fi

# =====================================================================
# 4. 伪终端测试（script(1)）：TERM 场景 + 字母/数字键 + stty 失效 + 方向键忽略
# =====================================================================
if ! command -v script >/dev/null 2>&1; then
    skip "PTY 全部用例（沙箱无 script 命令）"
elif ! command -v timeout >/dev/null 2>&1; then
    skip "PTY 全部用例（沙箱无 timeout 命令）"
else
    cat > "$TMPD/pty_menu.sh" <<'PTYEOF'
#!/usr/bin/env bash
export LC_ALL=C.utf8
source "${ROOT}/core/env.sh"
source "${ROOT}/core/ui.sh"
before=$(stty -g 2>/dev/null || echo NOSTTY)
ui_menu_select "请选择协议" 0 "1/r|VLESS-Reality|d1" "2/h|Hysteria 2|d2" "3/t|TUIC v5|d3"
rc=$?
after=$(stty -g 2>/dev/null || echo NOSTTY)
echo "MENU_RC=$rc IDX=$UI_SEL_IDX KEY=$UI_SEL_KEY"
if [[ "$before" == "$after" ]]; then echo "STTY_OK"; else echo "STTY_DIFF"; fi
PTYEOF
    cat > "$TMPD/pty_readkey.sh" <<'PTYEOF'
#!/usr/bin/env bash
export LC_ALL=C.utf8
source "${ROOT}/core/env.sh"
source "${ROOT}/core/ui.sh"
ui_menu_read_key "请输入选项" 0 "1/r|VLESS-Reality|d1" "2/h|Hysteria 2|d2" "3/t|TUIC v5|d3"
rc=$?
echo "READKEY_RC=$rc IDX=$UI_SEL_IDX KEY=$UI_SEL_KEY"
PTYEOF
    cat > "$TMPD/pty_nostty.sh" <<'PTYEOF'
#!/usr/bin/env bash
export LC_ALL=C.utf8 TERM=xterm
source "${ROOT}/core/env.sh"
source "${ROOT}/core/ui.sh"
# 模拟 stty 完全不可用：菜单代码已不再调用 stty（方向键移除后无 termios
# 操作），stty 失效不应影响菜单工作。
stty() { return 1; }
ui_menu_select "请选择协议" 0 "1/r|VLESS-Reality|d1" "2/h|Hysteria 2|d2" "3/t|TUIC v5|d3"
rc=$?
echo "MENU_RC=$rc IDX=$UI_SEL_IDX KEY=$UI_SEL_KEY"
PTYEOF
    run_pty() { # $1=按键 $2=驱动脚本 $3..=额外 env（k=v）
        local _keys="$1" _drv="$2"; shift 2
        (sleep 0.6; printf '%s' "$_keys"; sleep 0.4) \
            | ROOT="$ROOT" "$@" timeout 15 script -qec "bash $_drv" /dev/null 2>/dev/null | tr -d '\r'
    }
    # TERM=dumb 不再拦截 TTY 模式（字母键立即执行）
    _pty=$(run_pty 't' "$TMPD/pty_menu.sh" env TERM=dumb)
    if [[ "$_pty" == *"MENU_RC=0 IDX=2 KEY=3/t"* ]]; then ok "PTY TERM=dumb：字母 t 选中下标 2（TTY 模式未被拦截）"; else fail "PTY TERM=dumb：${_pty}"; fi
    # TERM 未设置也不拦截（数字键+回车）
    _pty=$(run_pty $'2\n' "$TMPD/pty_menu.sh" env -u TERM)
    if [[ "$_pty" == *"MENU_RC=0 IDX=1 KEY=2/h"* ]]; then ok "PTY TERM 未设置：数字 2+回车选中下标 1"; else fail "PTY TERM 未设置：${_pty}"; fi
    # 方向键序列被忽略且不漏出 ^[[，随后 q 正常退出
    _pty=$(run_pty $'\033[B\033[Aq' "$TMPD/pty_menu.sh" env TERM=xterm)
    if [[ "$_pty" == *"MENU_RC=2"* && "$_pty" != *'^[[A'* && "$_pty" != *'^[[B'* ]]; then ok "TTY 模式：方向键序列被忽略且无 ^[[ 回显，q 正常退出"; else fail "TTY 方向键忽略：${_pty}"; fi
    # SBM_MENU_LINE=1 强制行模式：整行读，字母/数字均需回车确认
    _pty=$(run_pty $'h\n' "$TMPD/pty_menu.sh" env TERM=xterm SBM_MENU_LINE=1)
    if [[ "$_pty" == *"MENU_RC=0 IDX=1 KEY=2/h"* ]]; then ok "行模式（SBM_MENU_LINE=1）：字母 h+回车选中下标 1"; else fail "行模式 h：${_pty}"; fi
    _pty=$(run_pty $'\n' "$TMPD/pty_menu.sh" env TERM=xterm SBM_MENU_LINE=1)
    if [[ "$_pty" == *"MENU_RC=0 IDX=0 KEY=1/r"* ]]; then ok "行模式：回车选中默认项下标 0"; else fail "行模式回车：${_pty}"; fi
    _pty=$(run_pty $'q\n' "$TMPD/pty_menu.sh" env TERM=xterm SBM_MENU_LINE=1)
    if [[ "$_pty" == *"MENU_RC=2"* ]]; then ok "行模式：q+回车返回 2"; else fail "行模式 q：${_pty}"; fi
    _pty=$(run_pty $'2\n' "$TMPD/pty_menu.sh" env TERM=xterm SBM_MENU_LINE=1)
    if [[ "$_pty" == *"MENU_RC=0 IDX=1 KEY=2/h"* ]]; then ok "行模式：数字 2+回车选中下标 1"; else fail "行模式 2：${_pty}"; fi
    _pty=$(run_pty $'14\n2\n' "$TMPD/pty_menu.sh" env TERM=xterm SBM_MENU_LINE=1)
    if [[ "$_pty" == *"MENU_RC=0 IDX=1 KEY=2/h"* && "$_pty" == *"无效选项"* ]]; then ok "行模式：无效输入 14 提示后 2 选中下标 1"; else fail "行模式 14 后 2：${_pty}"; fi
    # ui_menu_read_key（主菜单/维护菜单）：字母立即、数字需回车
    _pty=$(run_pty 't' "$TMPD/pty_readkey.sh" env TERM=xterm)
    if [[ "$_pty" == *"READKEY_RC=0 IDX=2 KEY=3/t"* ]]; then ok "ui_menu_read_key：字母 t 选中下标 2"; else fail "ui_menu_read_key t：${_pty}"; fi
    _pty=$(run_pty $'\n' "$TMPD/pty_readkey.sh" env TERM=xterm)
    if [[ "$_pty" == *"READKEY_RC=0 IDX=0 KEY=1/r"* ]]; then ok "ui_menu_read_key：回车选中默认项"; else fail "ui_menu_read_key 回车：${_pty}"; fi
    _pty=$(run_pty $'2\n' "$TMPD/pty_readkey.sh" env TERM=xterm)
    if [[ "$_pty" == *"READKEY_RC=0 IDX=1 KEY=2/h"* ]]; then ok "ui_menu_read_key：数字 2+回车选中下标 1"; else fail "ui_menu_read_key 2：${_pty}"; fi
    _pty=$(run_pty $'\033' "$TMPD/pty_readkey.sh" env TERM=xterm)
    if [[ "$_pty" == *"READKEY_RC=1"* ]]; then ok "ui_menu_read_key：Esc 返回 1"; else fail "ui_menu_read_key Esc：${_pty}"; fi
    # stty 完全失效：菜单不再调用 stty，字母键仍可正常工作
    _pty=$(run_pty 'h' "$TMPD/pty_nostty.sh")
    if [[ "$_pty" == *"MENU_RC=0 IDX=1 KEY=2/h"* ]]; then ok "stty 失效：字母 h 选中下标 1（菜单不依赖 stty）"; else fail "stty 失效：${_pty}"; fi
    # SBM_DEBUG_MENU=1 在 PTY 下可见
    _pty=$(run_pty $'\n' "$TMPD/pty_menu.sh" env TERM=xterm SBM_DEBUG_MENU=1)
    if [[ "$_pty" == *"[menu-debug]"* && "$_pty" == *"stdin_tty=1"* && "$_pty" == *"TTY 模式"* ]]; then ok "SBM_DEBUG_MENU=1：PTY 下打印检测详情（stdin_tty=1，TTY 模式）"; else fail "SBM_DEBUG_MENU PTY 输出：${_pty}"; fi
    _pty=$(run_pty $'\n' "$TMPD/pty_menu.sh" env TERM=xterm SBM_MENU_LINE=1 SBM_DEBUG_MENU=1)
    if [[ "$_pty" == *"[menu-debug]"* && "$_pty" == *"行模式"* ]]; then ok "SBM_DEBUG_MENU=1：SBM_MENU_LINE=1 时打印行模式判定"; else fail "SBM_DEBUG_MENU 行模式输出：${_pty}"; fi
fi

# =====================================================================
# 5. 非 TTY 行模式行为保持（管道输入，ui_menu_select 原有语义）
# =====================================================================
run_menu_pipe() { # $1=输入（进程替换保持当前 shell，取回 UI_SEL_*）
    local _input="$1"
    ui_menu_select "请选择协议" 2 "1/r|VLESS-Reality|d1" "2/h|Hysteria 2|d2" "3/t|TUIC v5|d3" \
        < <(printf '%b' "$_input") > "$TMPD/pipe.out" 2>&1
    MENU_RC=$?
}
run_menu_pipe '2\n'
if [[ "$MENU_RC" == "0" && "$UI_SEL_IDX" == "1" ]]; then ok "管道输入 2 选中下标 1（非 TTY 语义不变）"; else fail "管道 2：RC=$MENU_RC IDX=$UI_SEL_IDX"; fi
# ui_menu_read_key 管道输入：14 不得选中卸载项（数字序号定位已禁用）
ui_menu_read_key "请输入选项" 0 \
    "1/r|VLESS-Reality|d1" "2/h|Hysteria 2|d2" "3/t|TUIC v5|d3" \
    "4/a|AnyTLS|d4" "5/p|Argo|d5" "6/y|SOCKS5|d6" "7/i|一键全装|d7" \
    "8/e|订阅|d8" "9/n|命名|d9" "10/o|调优|d10" "11/s|维护|d11" \
    "12/d|诊断|d12" "13/w|WARP|d13" "x|彻底卸载清理|d14" "0/q|退出|d15" \
    < <(printf '%b' '14\n2\n') > "$TMPD/pipe2.out" 2>&1
MENU_RC=$?
if [[ "$MENU_RC" == "0" && "$UI_SEL_IDX" == "1" && "$UI_SEL_KEY" == "2/h" ]]; then
    ok "ui_menu_read_key 管道输入 14 被拒绝后 2 选中下标 1（无序号定位）"
else
    fail "ui_menu_read_key 14 后 2：RC=$MENU_RC IDX=$UI_SEL_IDX KEY=$UI_SEL_KEY（14 不应选中卸载）"
fi

# =====================================================================
# 汇总
# =====================================================================
printf '\n==============================\n'
printf 'TERMIUS FIX TEST SUMMARY: PASS=%s FAIL=%s SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
printf '==============================\n'
(( FAIL > 0 )) && exit 1
exit 0
