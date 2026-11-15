#!/usr/bin/env bash
# tests/submenu_nav_test.sh — 子菜单按键导航 + stderr 可见性验证
#
# 背景（2026-11-15 用户真机反馈，RN + Termius）：主菜单方向键正常，子菜单
# （VLESS-Reality、节点订阅中心 EXPORT）方向键失效：按方向键回显 ^[[A，
# 直接输入字母需回车，q+回车后卡住需再按回车。
# 调查结论：
#   1. EXPORT 截图是主线（mainline）行为——主线无方向键支持，属预期行为，
#      非 TUI bug；但 pause 提示不可见（stderr 吞没 bug）让用户误以为卡住。
#   2. Reality 截图的 ^[[A 是 bash read -n 在读与读之间恢复 termios 的窗口
#      造成（RN bash 5.1，沙箱 bash 5.2 无法复现）。
#   3. 2026-11-15 用户决定移除方向键导航（iPhone Termius 上不常用，字母键
#      更快；方向键是 bug 重灾区）：菜单改为字母立即执行、数字回车确认，
#      方向键序列到达时整段忽略且不回显 ^[[；dd 字节读与 stty termios
#      代码一并删除，逐字节读改回 bash read -n。
# 修复（stderr 部分保留）：
#   state_manager.sh 三处 exec 200>... 2>/dev/null 去掉 2>/dev/null，
#   stderr 不再被永久吞没，pause/read -rp 提示可见。
#
# 用法：bash tests/submenu_nav_test.sh
# 依赖：script(1)（PTY）、timeout、jq

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPD="$(mktemp -d /tmp/submenu_nav_test.XXXXXX)"
PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $*"; }

cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

# =====================================================================
# 驱动脚本
# =====================================================================
# 驱动 1：真实 main_menu → 子菜单完整流程（reality 已安装，端口 48886）
cat > "$TMPD/drv_main.sh" <<'DRVEOF'
#!/usr/bin/env bash
export LC_ALL=C.utf8
ROOT="${ROOT:?}"
TMPD="${TMPD:?}"
mkdir -p "$TMPD/etc/certs" "$TMPD/etc/export"
source "$ROOT/sbx.sh"
export SB_ETC="$TMPD/etc"
export SB_CERT_DIR="$SB_ETC/certs"
export SB_EXPORT_DIR="$SB_ETC/export"
export SB_STATE="$SB_ETC/state.json"
export SB_CONFIG="$SB_ETC/config.json"
export SB_BIN="$TMPD/sing-box"
init_state_file >/dev/null 2>&1
state_set_proto reality '{"port":48886,"uuid":"11111111-2222-3333-4444-555555555555","sni":"itunes.apple.com","public_key":"testpub","short_id":"abcdef"}' >/dev/null 2>&1
jq '.meta.ip="107.175.220.79" | .meta.ip_updated=9999999999 | .meta.asn="AS36352" | .meta.country="US" | .meta.city="Los Angeles"' "$SB_STATE" > "$SB_STATE.tmp" && mv "$SB_STATE.tmp" "$SB_STATE"
echo '{"log":{},"inbounds":[],"outbounds":[]}' > "$SB_CONFIG"
systemctl() { return 1; }
get_public_ip() { echo "107.175.220.79"; }
main_menu
echo "SBX_EXITED rc=$?"
DRVEOF

# 驱动 2：stderr 可见性（非 PTY）
cat > "$TMPD/drv_stderr.sh" <<'DRVEOF'
#!/usr/bin/env bash
source "${ROOT}/core/env.sh"
source "${ROOT}/core/state_manager.sh"
export SB_ETC="${TMPD}/etc"
export SB_STATE="$SB_ETC/state.json"
mkdir -p "$SB_ETC"
init_state_file >/dev/null 2>&1
# 两次状态写（触发 _state_lock/_state_unlock 各两次）
state_set_proto reality '{"port":48886}' >/dev/null 2>&1
state_set_proto hysteria2 '{"port":20287}' >/dev/null 2>&1
state_del_proto hysteria2 >/dev/null 2>&1
echo "STDERR_PROBE_AFTER_LOCK" >&2
# fd 2 必须未被重定向到 /dev/null（根因级检查：旧 bug 会让 fd 2 指向 /dev/null）
if [[ "$(readlink /proc/self/fd/2)" == "/dev/null" ]]; then
    echo "FD2_IS_DEVNULL" >&2
else
    echo "FD2_OK" >&2
fi
echo "STDERR_DONE" >&2
DRVEOF

# =====================================================================
# PTY 运行器（按键分阶段送入，输出落文件，返回 script 退出码）
# =====================================================================
run_pty_file() { # $1=按键脚本 $2=驱动 $3=输出文件 $4..=额外 env（k=v）
    local _keys="$1" _drv="$2" _out="$3"; shift 3
    bash "$_keys" | ROOT="$ROOT" TMPD="$TMPD" "$@" timeout 30 script -qec "bash $_drv" /dev/null > "$_out" 2>/dev/null
    return "${PIPESTATUS[1]}"
}

if ! command -v script >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    skip "PTY 全部用例（沙箱无 script/timeout 命令）"
    PTY_OK=0
else
    PTY_OK=1
fi

# =====================================================================
# A. 子菜单按键导航（真实 main_menu → menu_reality）
#    按键：Enter 进 Reality（默认项）→ 方向键序列（应被忽略）→ 数字 0+回车
#    返回主菜单 → Enter 过 pause → q 退出
# =====================================================================
if (( PTY_OK == 1 )); then
    cat > "$TMPD/keys_A.sh" <<'KEYEOF'
sleep 2.0; printf '\n'; sleep 1.5; printf '\033[A\033[B'; sleep 0.7; printf '0'; sleep 0.5; printf '\n'; sleep 1.0; printf '\n'; sleep 1.5; printf 'q'; sleep 0.5
KEYEOF
    run_pty_file "$TMPD/keys_A.sh" "$TMPD/drv_main.sh" "$TMPD/out_A.txt" env TERM=xterm
    _rc=$?
    _out="$TMPD/out_A.txt"
    if grep -q "VLESS-Reality" "$_out" && grep -q "请选择" "$_out"; then
        ok "A1 主菜单 Enter 进入 Reality 子菜单"
    else fail "A1 未进入 Reality 子菜单"; fi
    if ! grep -q '\^\[\[A' "$_out" && ! grep -q '\^\[\[B' "$_out"; then
        ok "A2 子菜单方向键序列被忽略，全程无 ^[[A/^[[B 回显"
    else fail "A2 出现 ^[[ 回显"; fi
    if grep -q "按回车返回菜单" "$_out"; then
        ok "A3 数字 0+回车返回主菜单，pause 提示可见（stderr 修复生效）"
    else fail "A3 未返回主菜单或 pause 提示不可见"; fi
    _n_main=$(grep -c "NETWORK MANAGEMENT CONSOLE" "$_out")
    if (( _n_main >= 2 )); then
        ok "A4 Enter 后回到主菜单（仪表盘出现 $_n_main 次）"
    else fail "A4 未回到主菜单（仪表盘出现 $_n_main 次）"; fi
    if (( _rc == 0 )); then
        ok "A5 主菜单 q 干净退出（rc=0）"
    else fail "A5 退出码异常 rc=$_rc"; fi
fi

# =====================================================================
# B. 子菜单字母直输（无需回车）
# =====================================================================
if (( PTY_OK == 1 )); then
    # B1：q 无回车立即返回主菜单
    cat > "$TMPD/keys_B1.sh" <<'KEYEOF'
sleep 2.0; printf '\n'; sleep 1.5; printf 'q'; sleep 1.0; printf '\n'; sleep 1.5; printf 'q'; sleep 0.5
KEYEOF
    run_pty_file "$TMPD/keys_B1.sh" "$TMPD/drv_main.sh" "$TMPD/out_B1.txt" env TERM=xterm
    if grep -q "按回车返回菜单" "$TMPD/out_B1.txt" && grep -q "NETWORK MANAGEMENT CONSOLE" "$TMPD/out_B1.txt"; then
        ok "B1 子菜单按 q（无回车）立即返回主菜单"
    else fail "B1 q 未立即返回"; fi
    # B2/B3：m 无回车立即进入修改流程，q 取消后 stderr 提示可见
    cat > "$TMPD/keys_B2.sh" <<'KEYEOF'
sleep 2.0; printf '\n'; sleep 1.5; printf 'm'; sleep 1.5; printf 'q\n'; sleep 1.0; printf '\n'; sleep 1.5; printf 'q'; sleep 0.5
KEYEOF
    run_pty_file "$TMPD/keys_B2.sh" "$TMPD/drv_main.sh" "$TMPD/out_B2.txt" env TERM=xterm
    if grep -q "请输入监听端口 \[默认: 48886" "$TMPD/out_B2.txt"; then
        ok "B2 子菜单按 m（无回车）立即进入修改流程"
    else fail "B2 m 未立即进入修改流程"; fi
    if grep -q "已取消端口配置" "$TMPD/out_B2.txt"; then
        ok "B3 修改流程 q 取消，stderr 提示可见"
    else fail "B3 取消提示不可见"; fi
fi

# =====================================================================
# C. EXPORT 子菜单按键（主菜单按 e 直达）
# =====================================================================
if (( PTY_OK == 1 )); then
    cat > "$TMPD/keys_C.sh" <<'KEYEOF'
sleep 2.0; printf 'e'; sleep 1.5; printf '\033[B'; sleep 0.7; printf 'q'; sleep 1.0; printf '\n'; sleep 1.5; printf 'q'; sleep 0.5
KEYEOF
    run_pty_file "$TMPD/keys_C.sh" "$TMPD/drv_main.sh" "$TMPD/out_C.txt" env TERM=xterm
    if grep -q "节点订阅中心" "$TMPD/out_C.txt"; then
        ok "C1 主菜单按 e（无回车）进入 EXPORT 子菜单"
    else fail "C1 未进入 EXPORT 子菜单"; fi
    if ! grep -q '\^\[\[A' "$TMPD/out_C.txt" && ! grep -q '\^\[\[B' "$TMPD/out_C.txt"; then
        ok "C2 EXPORT 子菜单方向键序列被忽略，无 ^[[ 回显"
    else fail "C2 出现 ^[[ 回显"; fi
    if grep -q "按回车返回菜单" "$TMPD/out_C.txt"; then
        ok "C3 EXPORT 子菜单按 q（无回车）返回主菜单"
    else fail "C3 q 未返回主菜单"; fi
    # C4：EXPORT 子菜单数字 1+回车显示分享链接（reality 已安装）
    cat > "$TMPD/keys_C4.sh" <<'KEYEOF'
sleep 2.0; printf 'e'; sleep 1.5; printf '1'; sleep 0.5; printf '\n'; sleep 1.5; printf '\n'; sleep 1.0; printf 'q'; sleep 1.0; printf '\n'; sleep 1.5; printf 'q'; sleep 0.5
KEYEOF
    run_pty_file "$TMPD/keys_C4.sh" "$TMPD/drv_main.sh" "$TMPD/out_C4.txt" env TERM=xterm
    if grep -q "vless://" "$TMPD/out_C4.txt"; then
        ok "C4 EXPORT 子菜单数字 1+回车显示分享链接"
    else fail "C4 数字 1+回车未显示分享链接"; fi
fi

# =====================================================================
# D. stderr 可见性（state_manager 修复，非 PTY）
# =====================================================================
ROOT="$ROOT" TMPD="$TMPD" bash "$TMPD/drv_stderr.sh" >"$TMPD/stderr_stdout.txt" 2>"$TMPD/stderr_stderr.txt"
if grep -q "STDERR_PROBE_AFTER_LOCK" "$TMPD/stderr_stderr.txt"; then
    ok "D1 状态锁操作后 stderr 仍可见"
else fail "D1 stderr 被吞没（STDERR_PROBE_AFTER_LOCK 未出现）"; fi
if grep -q "FD2_OK" "$TMPD/stderr_stderr.txt" && ! grep -q "FD2_IS_DEVNULL" "$TMPD/stderr_stderr.txt"; then
    ok "D2 fd 2 未被重定向到 /dev/null（根因级检查）"
else fail "D2 fd 2 指向 /dev/null（stderr 吞没 bug 未修）"; fi
if grep -q "STDERR_DONE" "$TMPD/stderr_stderr.txt"; then
    ok "D3 多次 lock/unlock 后 stderr 仍可见"
else fail "D3 stderr 在多次操作后被吞没"; fi

# =====================================================================
# E. 方向键代码移除静态检查
# =====================================================================
if grep -q "ui_menu_select_panel\|ui_panel_redraw\|_ui_panel_highlight\|_ui_menu_select_tty\|_ui_menu_tty_enter\|_ui_menu_cleanup\|_ui_menu_draw\b" "$ROOT/core/ui/navigation.sh"; then
    fail "E1 navigation.sh 仍有方向键相关函数残留"
else ok "E1 navigation.sh 无方向键相关函数残留"; fi
if grep -q "dd bs=1" "$ROOT/core/ui/navigation.sh"; then
    fail "E2 navigation.sh 仍有 dd 字节读残留"
else ok "E2 navigation.sh 无 dd 字节读残留"; fi
if grep -vE '^\s*#' "$ROOT/core/ui/navigation.sh" | grep -qE '(^|[;|&$( ])stty[ -]'; then
    fail "E3 navigation.sh 仍有 stty 调用残留"
else ok "E3 navigation.sh 无 stty 调用（不再碰终端状态）"; fi
if grep -q "↑↓" "$ROOT/core/ui/navigation.sh" "$ROOT/sbx.sh"; then
    fail "E4 仍有 ↑↓ 提示残留"
else ok "E4 无 ↑↓ 提示残留"; fi

# =====================================================================
# F. 子菜单数字键回车确认（2026-11-15 用户要求：字母立即、数字需回车）
# =====================================================================
if (( PTY_OK == 1 )); then
    # F1：Reality 子菜单按 2 + 回车 → 进入修改流程
    cat > "$TMPD/keys_F1.sh" <<'KEYEOF'
sleep 2.0; printf '\n'; sleep 1.5; printf '2'; sleep 0.5; printf '\n'; sleep 1.5; printf 'q\n'; sleep 1.0; printf '\n'; sleep 1.5; printf 'q'; sleep 0.5
KEYEOF
    run_pty_file "$TMPD/keys_F1.sh" "$TMPD/drv_main.sh" "$TMPD/out_F1.txt" env TERM=xterm
    if grep -q "请输入监听端口 \[默认: 48886" "$TMPD/out_F1.txt"; then
        ok "F1 子菜单按 2 + 回车进入修改流程"
    else fail "F1 数字 2 + 回车未进入修改流程"; fi
    # F2：Reality 子菜单按 2 不回车、停顿 1.0 秒 → 不执行；再按 q 返回主菜单
    cat > "$TMPD/keys_F2.sh" <<'KEYEOF'
sleep 2.0; printf '\n'; sleep 1.5; printf '2'; sleep 1.0; printf 'q'; sleep 1.0; printf '\n'; sleep 1.5; printf 'q'; sleep 0.5
KEYEOF
    run_pty_file "$TMPD/keys_F2.sh" "$TMPD/drv_main.sh" "$TMPD/out_F2.txt" env TERM=xterm
    if ! grep -q "请输入监听端口" "$TMPD/out_F2.txt" && grep -q "按回车返回菜单" "$TMPD/out_F2.txt"; then
        ok "F2 子菜单按 2 不回车不执行（q 返回主菜单）"
    else fail "F2 数字 2 未回车即执行或未返回主菜单"; fi
fi

# =====================================================================
# 汇总
# =====================================================================
printf '\n==============================\n'
printf 'SUBMENU NAV TEST SUMMARY: PASS=%s FAIL=%s SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
printf '==============================\n'
(( FAIL > 0 )) && exit 1
exit 0
