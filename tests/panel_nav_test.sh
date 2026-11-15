#!/usr/bin/env bash
# =====================================================================
#  tests/panel_nav_test.sh — 面板菜单回归测试
#  用法：bash tests/panel_nav_test.sh（仓库根目录或任意目录均可）
#  背景（2026-11-15 用户真机反馈）：主菜单先画仪表盘（含全部 15 项），
#  再调 ui_menu_select 又在下方重画一遍列表，手机上两遍占满屏。修复：
#  面板只显示一次，打印后直接读键（ui_menu_read_key），不另画列表。
#  方向键已于 2026-11-15 移除（用户决定）：面板不再有高亮行，导航方式
#  为字母立即执行、数字回车确认。本测试覆盖：
#    1. 静态检查：主菜单/维护菜单用面板 + ui_menu_read_key，entries 按视觉顺序排列
#    2. 面板 API 单元测试：行拆分、菜单下标映射、打印无重复、无反显 ANSI
#    3. PTY 机制测试：小面板按键选择（回车/字母/数字/Esc/q/方向键忽略）
#    4. PTY 主菜单端到端（mock 状态）：仅 q 时每项出现 1 次；字母/数字进子菜单
#    5. PTY 维护菜单端到端（mock 状态）
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

_count() { # $1=子串 $2=文本 → 出现次数（固定字符串，不含换行）
    local _n
    _n=$(printf '%s' "$2" | grep -F -o "$1" 2>/dev/null | wc -l)
    printf '%s' "${_n// /}"
}

# =====================================================================
# 1. 静态检查：主菜单/维护菜单用面板 + ui_menu_read_key
# =====================================================================
_MAIN_BODY="$(awk '/^main_menu\(\) \{/{f=1} f{print} /^}/{if(f)exit}' "$ROOT/sbx.sh")"
_MAINT_BODY="$(awk '/^menu_maintenance\(\) \{/{f=1} f{print} /^}/{if(f)exit}' "$ROOT/sbx.sh")"

if [[ "$_MAIN_BODY" == *'ui_menu_read_key "请输入选项"'* ]]; then
    ok "主菜单调用 ui_menu_read_key 读键"
else
    fail "主菜单未调用 ui_menu_read_key"
fi
if printf '%s' "$_MAIN_BODY" | grep -qE 'ui_menu_select[[:space:]]'; then
    fail "主菜单仍调用 ui_menu_select（会重画列表）"
else
    ok "主菜单不再调用 ui_menu_select"
fi
if printf '%s' "$_MAIN_BODY" | grep -q 'ui_menu_select_panel'; then
    fail "主菜单仍调用已移除的 ui_menu_select_panel"
else
    ok "主菜单不再调用 ui_menu_select_panel（方向键 API 已移除）"
fi
if [[ "$_MAINT_BODY" == *'ui_menu_read_key "请选择"'* ]]; then
    ok "维护菜单调用 ui_menu_read_key 读键"
else
    fail "维护菜单未调用 ui_menu_read_key"
fi
if printf '%s' "$_MAINT_BODY" | grep -qE 'ui_menu_select[[:space:]]'; then
    fail "维护菜单仍调用 ui_menu_select（会重画列表）"
else
    ok "维护菜单不再调用 ui_menu_select"
fi
if printf '%s' "$_MAINT_BODY" | grep -q 'ui_menu_select_panel'; then
    fail "维护菜单仍调用已移除的 ui_menu_select_panel"
else
    ok "维护菜单不再调用 ui_menu_select_panel（方向键 API 已移除）"
fi
# entries 按面板视觉顺序：13/w 在 11/s 之前（与面板显示顺序一致）
_L13=$(printf '%s' "$_MAIN_BODY" | grep -n '"13/w|' | head -1 | cut -d: -f1)
_L11=$(printf '%s' "$_MAIN_BODY" | grep -n '"11/s|' | head -1 | cut -d: -f1)
if [[ -n "$_L13" && -n "$_L11" && "$_L13" -lt "$_L11" ]]; then
    ok "主菜单 entries 按视觉顺序（13/w 在 11/s 之前）"
else
    fail "主菜单 entries 顺序不对（13/w 行 $_L13，11/s 行 $_L11）"
fi
# 面板菜单行下标与 entries 对应：13/w→10，11/s→11，12/d→12
if printf '%s' "$_MAIN_BODY" | grep -q 'ui_panel_add_menu 10 "$(ui_item "13/w"'; then
    ok "面板菜单行 13/w 下标为 10"
else
    fail "面板菜单行 13/w 下标不是 10"
fi
if printf '%s' "$_MAIN_BODY" | grep -q 'ui_panel_add_menu 11 "$(ui_item "11/s"'; then
    ok "面板菜单行 11/s 下标为 11"
else
    fail "面板菜单行 11/s 下标不是 11"
fi
if printf '%s' "$_MAIN_BODY" | grep -q 'ui_panel_add_menu 14 "$(ui_item "0/q"'; then
    ok "面板菜单行 0/q 下标为 14"
else
    fail "面板菜单行 0/q 下标不是 14"
fi
# 主菜单面板提示行：方向键说明已改为字母/数字说明
if printf '%s' "$_MAIN_BODY" | grep -q '字母直接进入 · 数字+回车确认'; then
    ok "主菜单面板提示行含字母/数字输入说明"
else
    fail "主菜单面板提示行未更新为字母/数字说明"
fi
if printf '%s' "$_MAIN_BODY" | grep -q '↑↓'; then
    fail "主菜单仍有 ↑↓ 提示（方向键已移除）"
else
    ok "主菜单无 ↑↓ 提示残留"
fi

# =====================================================================
# 2. 面板 API 单元测试（非 PTY，输出经管道捕获，确定性）
# =====================================================================
SBM_COLS=80
ui_init
ui_panel_begin
ui_panel_add "$(ui_top)"
ui_panel_add "$(ui_line "TEST PANEL")"
ui_panel_add "line one
line two"
ui_panel_add_menu 0 "$(ui_item "1/r" "VLESS-Reality" "desc one")"
ui_panel_add_menu 1 "$(ui_item "2/h" "Hysteria 2" "desc two")"
ui_panel_add "$(ui_bot)"
ui_panel_add_hint "hint line"
if (( ${#_UI_PANEL_LINES[@]} == 7 )); then
    ok "ui_panel_add 多行拆分正确（7 行：top+line+2 拆分行+2 菜单行+bot）"
else
    fail "面板行数 ${#_UI_PANEL_LINES[@]}（期望 7）"
fi
if (( ${_UI_PANEL_MENU[4]} == 0 && ${_UI_PANEL_MENU[5]} == 1 && ${_UI_PANEL_MENU[0]} == -1 )); then
    ok "面板菜单下标映射正确（行 4→0，行 5→1，行 0→-1）"
else
    fail "面板菜单下标映射不对：${_UI_PANEL_MENU[*]}"
fi
ui_panel_print > "$TMPD/panel.out"
_POUT="$(cat "$TMPD/panel.out")"
_POUT_LINES=$(wc -l < "$TMPD/panel.out")
if (( _POUT_LINES == 8 )); then
    ok "ui_panel_print 输出 8 行（7 面板行 + 1 提示行）"
else
    fail "ui_panel_print 输出行数 $_POUT_LINES（期望 8）"
fi
if [[ "$(_count "VLESS-Reality" "$_POUT")" == "1" && "$(_count "Hysteria 2" "$_POUT")" == "1" ]]; then
    ok "ui_panel_print 每项出现 1 次（无重复渲染）"
else
    fail "ui_panel_print 出现次数异常：VLESS=$(_count "VLESS-Reality" "$_POUT") Hy2=$(_count "Hysteria 2" "$_POUT")"
fi
if [[ "$_POUT" != *$'\033[7m'* ]]; then
    ok "ui_panel_print 无反显 ANSI（方向键移除后面板无高亮行）"
else
    fail "ui_panel_print 仍输出反显 ANSI"
fi
# 方向键相关函数已移除（静态检查）
if grep -q "ui_panel_redraw\|_ui_panel_highlight\|ui_menu_select_panel\|_ui_menu_select_tty\|_ui_menu_tty_enter" "$ROOT/core/ui/navigation.sh"; then
    fail "navigation.sh 仍有方向键相关函数残留"
else
    ok "navigation.sh 无方向键相关函数残留"
fi
if grep -q "dd bs=1" "$ROOT/core/ui/navigation.sh"; then
    fail "navigation.sh 仍有 dd 字节读残留（方向键专用，已移除）"
else
    ok "navigation.sh 无 dd 字节读残留"
fi

# =====================================================================
# 3. PTY 机制测试（小面板 + ui_menu_read_key）
# =====================================================================
if ! command -v script >/dev/null 2>&1; then
    skip "PTY 全部用例（沙箱无 script 命令）"
elif ! command -v timeout >/dev/null 2>&1; then
    skip "PTY 全部用例（沙箱无 timeout 命令）"
else
    cat > "$TMPD/pty_panel.sh" <<'PTYEOF'
#!/usr/bin/env bash
export LC_ALL=C.utf8
export SBM_COLS=80
source "${ROOT}/core/env.sh"
source "${ROOT}/core/ui.sh"
stty rows 40 cols 80 2>/dev/null || true
before=$(stty -g 2>/dev/null || echo NOSTTY)
ui_clear
ui_panel_begin
ui_panel_add "$(ui_top)"
ui_panel_add "$(ui_line "TEST PANEL")"
ui_panel_add "$(ui_mid)"
ui_panel_add_menu 0 "$(ui_item "1/r" "VLESS-Reality" "desc one")"
ui_panel_add_menu 1 "$(ui_item "2/h" "Hysteria 2" "desc two")"
ui_panel_add_menu 2 "$(ui_item "3/t" "TUIC v5" "desc three")"
ui_panel_add_menu 3 "$(ui_item "0/q" "Back" "")"
ui_panel_add "$(ui_bot)"
ui_panel_add_hint "hint line"
ui_panel_print
ui_menu_read_key "请选择" 0 "1/r|VLESS-Reality|d1" "2/h|Hysteria 2|d2" "3/t|TUIC v5|d3" "0/q|Back|"
rc=$?
after=$(stty -g 2>/dev/null || echo NOSTTY)
echo "PANEL_RC=$rc IDX=$UI_SEL_IDX KEY=$UI_SEL_KEY"
if [[ "$before" == "$after" ]]; then echo "STTY_OK"; else echo "STTY_DIFF"; fi
PTYEOF
    run_pty() { # $1=按键 $2=驱动脚本 $3..=额外 env（k=v）
        local _keys="$1" _drv="$2"; shift 2
        (sleep 0.8; printf '%s' "$_keys"; sleep 0.5) \
            | ROOT="$ROOT" "$@" timeout 15 script -qec "bash $_drv" /dev/null 2>/dev/null | tr -d '\r'
    }
    # 仅回车：面板只打印一次，无重复列表，选中默认项
    _pty=$(run_pty $'\n' "$TMPD/pty_panel.sh" env TERM=xterm)
    if [[ "$(_count "VLESS-Reality" "$_pty")" == "1" && "$(_count "Hysteria 2" "$_pty")" == "1" && "$(_count "TUIC v5" "$_pty")" == "1" ]]; then
        ok "PTY 面板：仅回车时每项出现 1 次（无重复列表）"
    else
        fail "PTY 面板重复渲染：VLESS=$(_count "VLESS-Reality" "$_pty") Hy2=$(_count "Hysteria 2" "$_pty") TUIC=$(_count "TUIC v5" "$_pty")"
    fi
    if [[ "$_pty" == *"PANEL_RC=0 IDX=0 KEY=1/r"* ]]; then
        ok "PTY 面板：回车选中默认项下标 0"
    else
        fail "PTY 面板回车：${_pty}"
    fi
    if [[ "$_pty" == *"STTY_OK"* ]]; then
        ok "PTY 面板：退出后 stty 恢复"
    else
        fail "PTY 面板 stty 未恢复"
    fi
    if [[ "$_pty" != *$'\033[7m'* ]]; then
        ok "PTY 面板：无反显高亮（方向键已移除）"
    else
        fail "PTY 面板仍有反显高亮"
    fi
    # 数字 3+回车选中下标 2
    _pty=$(run_pty $'3\n' "$TMPD/pty_panel.sh" env TERM=xterm)
    if [[ "$_pty" == *"PANEL_RC=0 IDX=2 KEY=3/t"* ]]; then
        ok "PTY 面板：数字 3+回车选中下标 2"
    else
        fail "PTY 面板数字 3+回车：${_pty}"
    fi
    # 方向键序列被忽略且无 ^[[ 回显，随后 q 正常退出
    _pty=$(run_pty $'\033[B\033[Aq' "$TMPD/pty_panel.sh" env TERM=xterm)
    if [[ "$_pty" == *"PANEL_RC=2"* && "$_pty" != *'^[[A'* && "$_pty" != *'^[[B'* ]]; then
        ok "PTY 面板：方向键序列被忽略且无 ^[[ 回显，q 正常退出"
    else
        fail "PTY 面板方向键忽略：${_pty}"
    fi
    # 字母快捷键；Esc；q；数字不回车不执行
    _pty=$(run_pty 'h' "$TMPD/pty_panel.sh" env TERM=xterm)
    if [[ "$_pty" == *"PANEL_RC=0 IDX=1 KEY=2/h"* ]]; then
        ok "PTY 面板：字母 h 选中下标 1"
    else
        fail "PTY 面板 h：${_pty}"
    fi
    _pty=$(run_pty $'\033' "$TMPD/pty_panel.sh" env TERM=xterm)
    if [[ "$_pty" == *"PANEL_RC=1"* ]]; then
        ok "PTY 面板：Esc 返回 1"
    else
        fail "PTY 面板 Esc：${_pty}"
    fi
    _pty=$(run_pty 'q' "$TMPD/pty_panel.sh" env TERM=xterm)
    if [[ "$_pty" == *"PANEL_RC=2"* ]]; then
        ok "PTY 面板：q 返回 2"
    else
        fail "PTY 面板 q：${_pty}"
    fi
    _pty=$(run_pty $'2q' "$TMPD/pty_panel.sh" env TERM=xterm)
    if [[ "$_pty" == *"PANEL_RC=2"* ]]; then
        ok "PTY 面板：数字 2 不回车不执行，q 丢弃缓存后退出"
    else
        fail "PTY 面板数字不回车：${_pty}"
    fi
    # SBM_MENU_LINE=1 行模式：面板只打印一次，字母+回车选中
    _pty=$(run_pty $'h\n' "$TMPD/pty_panel.sh" env TERM=xterm SBM_MENU_LINE=1)
    if [[ "$_pty" == *"PANEL_RC=0 IDX=1 KEY=2/h"* ]]; then
        ok "PTY 面板行模式：字母 h+回车选中下标 1"
    else
        fail "PTY 面板行模式 h：${_pty}"
    fi
    _pty=$(run_pty $'3\n' "$TMPD/pty_panel.sh" env TERM=xterm SBM_MENU_LINE=1)
    if [[ "$_pty" == *"PANEL_RC=0 IDX=2 KEY=3/t"* ]]; then
        ok "PTY 面板行模式：数字 3+回车选中下标 2"
    else
        fail "PTY 面板行模式数字 3：${_pty}"
    fi

    # =====================================================================
    # 4. PTY 主菜单端到端（mock 状态，无网络）
    # =====================================================================
    cat > "$TMPD/pty_main.sh" <<'PTYEOF'
#!/usr/bin/env bash
export LC_ALL=C.utf8
export SBM_COLS=80
source "${ROOT}/sbx.sh"
# 覆盖路径（env.sh 硬设，source 后重写），预置 meta 避免网络探测
TEST_ETC="$(mktemp -d)"
trap 'rm -rf "$TEST_ETC"' EXIT
SB_ETC="$TEST_ETC"; SB_CERT_DIR="$TEST_ETC/certs"; SB_EXPORT_DIR="$TEST_ETC/export"
SB_STATE="$TEST_ETC/state.json"; SB_CONFIG="$TEST_ETC/config.json"; SB_BIN="$TEST_ETC/no-such-bin"
mkdir -p "$SB_CERT_DIR" "$SB_EXPORT_DIR"
cp "${ROOT}/templates/base.json" "$SB_CONFIG"
_now=$(date +%s)
cat > "$SB_STATE" <<EOF
{
  "schema_version": 2,
  "version": "1.7.0",
  "app_version": "1.7.0",
  "installed_protocols": [],
  "meta": {"node_prefix": "US-test", "naming_version": 3, "ip": "203.0.113.9", "ip_updated": $_now, "asn": "AS64500", "country": "US", "city": "Los Angeles"},
  "protocols": {},
  "updated_at": $_now
}
EOF
chmod 600 "$SB_STATE"
systemctl() { return 1; }
stty rows 60 cols 80 2>/dev/null || true
main_menu
PTYEOF
    run_main_pty() { # $1=按键（单批，2.5s 后发送）
        local _keys="$1"
        (sleep 2.5; printf '%s' "$_keys"; sleep 0.5) \
            | ROOT="$ROOT" timeout 30 script -qec "bash $TMPD/pty_main.sh" /dev/null 2>/dev/null | tr -d '\r'
    }
    # 仅 q：主菜单只渲染一次
    _pty=$(run_main_pty 'q')
    if [[ "$(_count "[1/r]" "$_pty")" == "1" ]]; then
        ok "PTY 主菜单：仅 q 时 [1/r] 出现 1 次（无重复列表）"
    else
        fail "PTY 主菜单 [1/r] 出现 $(_count "[1/r]" "$_pty") 次（期望 1）"
    fi
    if [[ "$(_count "[13/w]" "$_pty")" == "1" && "$(_count "[11/s]" "$_pty")" == "1" ]]; then
        ok "PTY 主菜单：[13/w] 与 [11/s] 各出现 1 次"
    else
        fail "PTY 主菜单 [13/w] 出现 $(_count "[13/w]" "$_pty") 次，[11/s] 出现 $(_count "[11/s]" "$_pty") 次"
    fi
    if [[ "$(_count "SYSTEM OVERVIEW" "$_pty")" == "1" && "$(_count "SING-BOX MOYE" "$_pty")" == "1" ]]; then
        ok "PTY 主菜单：仪表盘只渲染一次"
    else
        fail "PTY 主菜单仪表盘重复：OVERVIEW=$(_count "SYSTEM OVERVIEW" "$_pty") BRAND=$(_count "SING-BOX MOYE" "$_pty")"
    fi
    if [[ "$_pty" == *"字母直接进入 · 数字+回车确认"* ]]; then
        ok "PTY 主菜单：面板提示行含字母/数字输入说明"
    else
        fail "PTY 主菜单面板提示行缺失"
    fi
    if [[ "$_pty" != *$'\033[7m'* ]]; then
        ok "PTY 主菜单：无反显高亮（方向键已移除）"
    else
        fail "PTY 主菜单仍有反显高亮"
    fi
    # 字母导航端到端：h 进 Hysteria 2 子菜单，Esc 返回，\n 过 pause，q 退出
    _pty=$( (sleep 2.5; printf 'h'; sleep 1.5; printf '\033'; sleep 1.5; printf '\n'; sleep 1.5; printf 'q'; sleep 0.5) \
        | ROOT="$ROOT" timeout 30 script -qec "bash $TMPD/pty_main.sh" /dev/null 2>/dev/null | tr -d '\r' )
    _pty_rc=$?
    if [[ "$_pty" == *"Hysteria 2"* ]]; then
        ok "PTY 主菜单导航：字母 h 进入 Hysteria 2 子菜单"
    else
        fail "PTY 主菜单导航未进入 Hysteria 2 子菜单"
    fi
    if (( _pty_rc == 0 )); then
        ok "PTY 主菜单导航：Esc→pause→q 正常退出（无挂死）"
    else
        fail "PTY 主菜单导航退出码 $_pty_rc（期望 0，可能挂死被 timeout 杀死）"
    fi
    # 数字导航端到端：输入 13+回车进入 WARP 菜单（两位数需回车确认）
    _pty=$( (sleep 2.5; printf '13'; sleep 0.5; printf '\n'; sleep 1.5; printf '\033'; sleep 1.5; printf '\n'; sleep 1.5; printf 'q'; sleep 0.5) \
        | ROOT="$ROOT" timeout 30 script -qec "bash $TMPD/pty_main.sh" /dev/null 2>/dev/null | tr -d '\r' )
    _pty_rc=$?
    if [[ "$_pty" == *"WARP 与域名分流"* ]]; then
        ok "PTY 主菜单数字导航：13+回车进入 WARP 菜单"
    else
        fail "PTY 主菜单数字导航：13+回车未进入 WARP 菜单"
    fi
    if (( _pty_rc == 0 )); then
        ok "PTY 主菜单数字导航：后续 Esc→pause→q 正常退出"
    else
        fail "PTY 主菜单数字导航退出码 $_pty_rc（期望 0）"
    fi
    # 数字不回车不执行：输入 1 不回车、停顿后按 q，应直接退出主菜单（不进 Reality）
    _pty=$( (sleep 2.5; printf '1'; sleep 1.0; printf 'q'; sleep 0.5) \
        | ROOT="$ROOT" timeout 30 script -qec "bash $TMPD/pty_main.sh" /dev/null 2>/dev/null | tr -d '\r' )
    _pty_rc=$?
    if [[ "$_pty" != *"VLESS-Reality"* || "$(_count "VLESS-Reality" "$_pty")" == "1" ]]; then
        ok "PTY 主菜单：数字 1 不回车不执行（q 退出，未进 Reality 子菜单）"
    else
        fail "PTY 主菜单数字 1 未回车即执行"
    fi
    if (( _pty_rc == 0 )); then
        ok "PTY 主菜单数字不回车：q 正常退出"
    else
        fail "PTY 主菜单数字不回车退出码 $_pty_rc（期望 0）"
    fi

    # =====================================================================
    # 5. PTY 维护菜单端到端（mock 状态）
    # =====================================================================
    cat > "$TMPD/pty_maint.sh" <<'PTYEOF'
#!/usr/bin/env bash
export LC_ALL=C.utf8
export SBM_COLS=80
source "${ROOT}/sbx.sh"
TEST_ETC="$(mktemp -d)"
trap 'rm -rf "$TEST_ETC"' EXIT
SB_ETC="$TEST_ETC"; SB_CERT_DIR="$TEST_ETC/certs"; SB_EXPORT_DIR="$TEST_ETC/export"
SB_STATE="$TEST_ETC/state.json"; SB_CONFIG="$TEST_ETC/config.json"; SB_BIN="$TEST_ETC/no-such-bin"
mkdir -p "$SB_CERT_DIR" "$SB_EXPORT_DIR"
cp "${ROOT}/templates/base.json" "$SB_CONFIG"
_now=$(date +%s)
cat > "$SB_STATE" <<EOF
{
  "schema_version": 2,
  "version": "1.7.0",
  "app_version": "1.7.0",
  "installed_protocols": [],
  "meta": {"node_prefix": "US-test", "naming_version": 3, "ip": "203.0.113.9", "ip_updated": $_now, "asn": "AS64500", "country": "US", "city": "Los Angeles"},
  "protocols": {},
  "updated_at": $_now
}
EOF
chmod 600 "$SB_STATE"
systemctl() { return 1; }
stty rows 40 cols 80 2>/dev/null || true
menu_maintenance
echo "MAINT_DONE"
PTYEOF
    _pty=$( (sleep 2.0; printf 'q'; sleep 0.5) \
        | ROOT="$ROOT" timeout 30 script -qec "bash $TMPD/pty_maint.sh" /dev/null 2>/dev/null | tr -d '\r' )
    if [[ "$(_count "[1/u]" "$_pty")" == "1" && "$(_count "[2/r]" "$_pty")" == "1" ]]; then
        ok "PTY 维护菜单：仅 q 时 [1/u]/[2/r] 各出现 1 次（无重复列表）"
    else
        fail "PTY 维护菜单重复：[1/u]=$(_count "[1/u]" "$_pty") [2/r]=$(_count "[2/r]" "$_pty")"
    fi
    if [[ "$_pty" == *"MAINT_DONE"* ]]; then
        ok "PTY 维护菜单：q 正常返回"
    else
        fail "PTY 维护菜单未正常返回"
    fi
fi

# =====================================================================
# 汇总
# =====================================================================
printf '\n==============================\n'
printf 'PANEL NAV TEST SUMMARY: PASS=%s FAIL=%s SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
printf '==============================\n'
(( FAIL > 0 )) && exit 1
exit 0
