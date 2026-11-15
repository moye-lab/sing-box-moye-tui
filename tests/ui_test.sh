#!/usr/bin/env bash
# =====================================================================
#  tests/ui_test.sh — Phase 1 UI 架构回归测试
#  用法：bash tests/ui_test.sh（仓库根目录或任意目录均可）
#  覆盖：bash -n 全项目、宽度模式不越界、CJK/Emoji 宽度、NO_COLOR/ASCII/
#  非 TTY 去色、30 个旧接口回归、ui_menu_select 行降级、ui_confirm、
#  输入组件、新组件、script(1) 伪终端按键会话（字母立即、数字需回车）与终端恢复。
#  退出码：0 全部通过（SKIP 不计失败），1 有 FAIL。
# =====================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP: %s\n' "$1"; }

# UTF-8 locale：CJK 宽度计算依赖多字节字符语义（与 sbx.sh 入口行为一致）
if locale -a 2>/dev/null | grep -qiE '^C\.utf8$'; then
    export LC_ALL=C.utf8
    HAVE_UTF8=1
else
    HAVE_UTF8=0
fi

# --- 加载被测代码（非 TTY 环境，与 CI/管道一致） ---
source "$ROOT/core/env.sh"
source "$ROOT/core/ui.sh"

# state 桩：reality/tuic 已安装，其余未安装
state_has_proto() { [[ "$1" == "reality" || "$1" == "tuic" ]]; }
state_get_field() {
    case "$1/$2" in
        reality/port) echo 443 ;;
        reality/sni) echo "example.com" ;;
        tuic/port) echo 8443 ;;
        *) echo "" ;;
    esac
}

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# =====================================================================
# 1. bash -n 全项目
# =====================================================================
_syntax_bad=0
while IFS= read -r -d '' _f; do
    bash -n "$_f" 2>/dev/null || { _syntax_bad=1; fail "bash -n: $_f"; }
done < <(find "$ROOT" -type f -name '*.sh' -print0)
(( _syntax_bad == 0 )) && ok "bash -n 全项目通过"

# =====================================================================
# 2. 兼容层自检 + 主题变量
# =====================================================================
if _ui_compat_check 2>"$TMPD/compat.err"; then ok "旧接口兼容自检（30 个）"; else fail "旧接口兼容自检：$(cat "$TMPD/compat.err")"; fi
_theme_ok=1
for _v in T_PRIMARY T_SUCCESS T_WARNING T_DANGER T_INFO T_MUTED T_ACCENT T_TEXT; do
    declare -p "$_v" >/dev/null 2>&1 || _theme_ok=0
done
(( _theme_ok == 1 )) && ok "主题变量 T_* 已定义" || fail "主题变量 T_* 缺失"

# =====================================================================
# 3. 宽度模式：UI_W/UI_MODE + 渲染不越界
# =====================================================================
check_widths() { # $1=cols $2=期望 UI_W $3=期望 UI_MODE
    local cols="$1" exp_w="$2" exp_mode="$3"
    SBM_COLS=$cols ui_init
    if [[ "$UI_W" != "$exp_w" || "$UI_MODE" != "$exp_mode" ]]; then
        fail "宽度模式 cols=$cols 期望 UI_W=$exp_w/$exp_mode 实际 $UI_W/$UI_MODE"
        return
    fi
    local out line bad=0
    out=$( {
        ui_top
        ui_line "中英文混排测试 Mixed Text 12345 😀"
        ui_line ""
        ui_split "左端标题 Left" "右端 Right"
        ui_section "PROTOCOLS" "协议矩阵"
        ui_kv "标签" "值"
        ui_kv "超长域名" "a-very-long-subdomain-name-that-keeps-going-and-going.example.org"
        ui_kv2 "节点标识" "us-west-1-very-long-hostname.example.com" "$WHITE" "公网地址" "203.0.113.42" "$CYAN"
        ui_item "1/r" "超长节点名称测试节点名称很长很长很长" "这是一个非常非常长的描述文字用来测试截断行为是否正确处理不会越界"
        ui_item "0/q" "退出管理面板" ""
        ui_proto_row "1/r" "VLESS-Reality" reality
        ui_proto_row "2/h" "Hysteria 2" hysteria2
        ui_dash_row "节点标识" "host-01" "$WHITE" "公网地址" "203.0.113.42" "$CYAN"
        ui_bot
    } 2>&1 )
    while IFS= read -r line; do
        ui_vwidth "$line"
        if (( UI_VW > UI_W )); then
            bad=1
            printf '  越界行(%s列 > UI_W=%s): %s\n' "$UI_VW" "$UI_W" "$line"
        fi
    done <<< "$out"
    if (( bad == 0 )); then ok "宽度模式 cols=$cols (UI_W=$UI_W/$UI_MODE) 渲染无越界"; else fail "宽度模式 cols=$cols 存在越界行"; fi
}
check_widths 120 100 wide
check_widths 100 96 wide
check_widths 80 78 normal
check_widths 60 58 compact
check_widths 40 38 narrow
check_widths 30 30 plain

# SBM_COLS 非法值回退 80；空值走检测（非 TTY 下为 80）
SBM_COLS=abc ui_init
[[ "$UI_W" == "78" ]] && ok "SBM_COLS 非法值回退 80 列" || fail "SBM_COLS 非法值回退失败 (UI_W=$UI_W)"
SBM_COLS= ui_init
[[ "$UI_W" == "78" ]] && ok "SBM_COLS 为空走默认检测" || fail "SBM_COLS 为空检测失败 (UI_W=$UI_W)"

# 窄屏 ui_kv2 退化为两行单列；plain 下 ui_item 为纯文本格式
SBM_COLS=50 ui_init
_narrow_lines=$(ui_kv2 "节点标识" "host-01" "$WHITE" "公网地址" "1.2.3.4" "$CYAN" | wc -l)
[[ "$_narrow_lines" == "2" ]] && ok "窄屏 ui_kv2 退化为两行单列" || fail "窄屏 ui_kv2 行数=$_narrow_lines（期望 2）"
SBM_COLS=30 ui_init
_plain_item=$(ui_item "1/r" "VLESS-Reality" "描述文字")
[[ "$_plain_item" == "[1/r] VLESS-Reality - 描述文字" ]] && ok "plain 模式 ui_item 纯文本格式" || fail "plain 模式 ui_item 格式异常：$_plain_item"
_plain_top=$(ui_top)
[[ -z "$_plain_top" ]] && ok "plain 模式边框函数为空操作" || fail "plain 模式 ui_top 仍有输出"

# =====================================================================
# 4. 宽度计算：CJK / Emoji / ANSI / 截断 / 空串
# =====================================================================
SBM_COLS=80 ui_init
ui_vwidth "中文";      [[ "$UI_VW" == "4" ]] && ok "ui_vwidth 中文=4" || fail "ui_vwidth 中文=$UI_VW（期望 4）"
ui_vwidth "😀ab";      [[ "$UI_VW" == "4" ]] && ok "ui_vwidth Emoji=2/个" || fail "ui_vwidth 😀ab=$UI_VW（期望 4）"
ui_vwidth "中文abc";   [[ "$UI_VW" == "7" ]] && ok "ui_vwidth 中英混排=7" || fail "ui_vwidth 中文abc=$UI_VW（期望 7）"
ui_vwidth "${CYAN}ab${PLAIN}"; [[ "$UI_VW" == "2" ]] && ok "ui_vwidth 排除 ANSI 码" || fail "ui_vwidth 含 ANSI=$UI_VW（期望 2）"
ui_vwidth "";          [[ "$UI_VW" == "0" ]] && ok "ui_vwidth 空串=0" || fail "ui_vwidth 空串=$UI_VW"
ui_fit "" 5;           [[ "$UI_FIT" == "     " ]] && ok "ui_fit 空串补齐 5 列" || fail "ui_fit 空串异常"
ui_fit "1234567890" 5; ui_vwidth "$UI_FIT"; [[ "$UI_VW" == "5" ]] && ok "ui_fit 超长截断到 5 列" || fail "ui_fit 截断后宽度=$UI_VW（期望 5）"
ui_cw 20013;           [[ "$UI_CW" == "2" ]] && ok "ui_cw CJK 码点=2" || fail "ui_cw 中=$UI_CW"
ui_strip "${RED}x${PLAIN}"; [[ "$UI_STRIPPED" == "x" ]] && ok "ui_strip 去除 ANSI" || fail "ui_strip 结果=$UI_STRIPPED"

# =====================================================================
# 5. 颜色 / 字符集环境变量（全新子 shell 进程）
# =====================================================================
_out=$(SBM_COLS=80 LC_ALL=C.utf8 bash -c 'source "$1/core/env.sh"; source "$1/core/ui.sh"; ui_line hello; ui_top' _ "$ROOT")
[[ "$_out" != *$'\033'* ]] && ok "非 TTY 默认去色" || fail "非 TTY 默认仍有 ANSI 码"
_out=$(NO_COLOR=1 SBM_FORCE_COLOR=1 SBM_COLS=80 LC_ALL=C.utf8 bash -c 'source "$1/core/env.sh"; source "$1/core/ui.sh"; ui_line hello' _ "$ROOT")
[[ "$_out" != *$'\033'* ]] && ok "NO_COLOR=1 优先于 SBM_FORCE_COLOR" || fail "NO_COLOR 下仍有 ANSI 码"
_out=$(SBM_FORCE_COLOR=1 SBM_COLS=80 LC_ALL=C.utf8 bash -c 'source "$1/core/env.sh"; source "$1/core/ui.sh"; ui_line hello' _ "$ROOT")
[[ "$_out" == *$'\033'* ]] && ok "SBM_FORCE_COLOR=1 非 TTY 下强制颜色" || fail "SBM_FORCE_COLOR 未生效"
_out=$(SBM_ASCII=1 SBM_COLS=80 LC_ALL=C.utf8 bash -c 'source "$1/core/env.sh"; source "$1/core/ui.sh"; ui_top' _ "$ROOT")
if [[ "$_out" == *"+"* && "$_out" != *"╭"* ]]; then ok "SBM_ASCII=1 只有 ASCII 边框"; else fail "SBM_ASCII 边框异常：$_out"; fi
if (( HAVE_UTF8 == 1 )); then
    _out=$(SBM_COLS=80 LC_ALL=C.utf8 bash -c 'source "$1/core/env.sh"; source "$1/core/ui.sh"; ui_top; ui_line x; ui_bot' _ "$ROOT")
    [[ "$_out" == *"╭"* && "$_out" == *"│"* ]] && ok "UTF-8 下 Unicode 边框" || fail "UTF-8 下未用 Unicode 边框"
else
    skip "UTF-8 下 Unicode 边框（沙箱无 UTF-8 locale）"
fi

# =====================================================================
# 6. 旧接口回归：30 个旧接口全部可调用，输出含预期内容
# =====================================================================
SBM_COLS=80 ui_init
_out=$( {
    ui_top; ui_mid; ui_bot; ui_box_top; ui_box_mid; ui_box_bot; ui_rule "+" "+"
    ui_line "hello-regression"
    ui_split "左" "右"
    ui_section "SEC" "sub"
    ui_kv "标签" "值"
    ui_kv2 "L1" "V1" "$WHITE" "L2" "V2" "$CYAN"
    ui_item "1/r" "名称" "描述"
    ui_proto_row "1/r" "VLESS-Reality" reality
    ui_proto_row "2/h" "Hysteria 2" hysteria2
    ui_proto_status reality
    ui_proto_status hysteria2
    ui_hint "提示文字"
    ui_banner "横幅标题"
    ui_node_card "节点名" "说明" "https://example.com/link"
    ui_menu_head "菜单标题" "面包屑"
    ui_prompt_str "请选择" "1-3"
    ui_clear
    echo "REGRESSION-DONE"
} 2>&1 )
_rc=$?
for _needle in hello-regression VLESS-Reality "已启用" "未安装" "提示文字" "横幅标题" "节点名" "https://example.com/link" "请选择" "REGRESSION-DONE"; do
    [[ "$_out" == *"$_needle"* ]] || fail "旧接口回归输出缺失：$_needle"
done
[[ "$_out" == *"REGRESSION-DONE"* ]] && ok "旧接口回归：28 个渲染/屏幕接口无报错且输出完整" || fail "旧接口回归中途失败"
ui_proto_detail reality
[[ "$UI_DETAIL" == *"443"* && "$UI_DETAIL" == *"example.com"* ]] && ok "ui_proto_detail 返回端口与 SNI" || fail "ui_proto_detail=$UI_DETAIL"
ui_init
[[ "$UI_W" == "78" ]] && ok "ui_init 可重复调用" || fail "ui_init 重复调用异常"

# =====================================================================
# 7. ui_menu_select 非 TTY 降级（进程替换保持当前 shell，取回 UI_SEL_*）
# =====================================================================
_ENTRIES=("1/r|VLESS-Reality|d1" "2/h|Hysteria 2|d2" "3/t|TUIC v5|")
run_menu() { # $1=输入 $2..=ui_menu_select 参数
    local _input="$1"; shift
    ui_menu_select "$@" < <(printf '%b' "$_input") > "$TMPD/menu.out" 2>&1
    MENU_RC=$?
}
run_menu '2\n' "请选择" 0 "${_ENTRIES[@]}"
[[ "$MENU_RC" == "0" && "$UI_SEL_IDX" == "1" && "$UI_SEL_KEY" == "2/h" ]] && ok "ui_menu_select 管道 2 选中下标 1" || fail "ui_menu_select 管道 2：RC=$MENU_RC IDX=$UI_SEL_IDX KEY=$UI_SEL_KEY"
run_menu 'r\n' "请选择" 0 "${_ENTRIES[@]}"
[[ "$MENU_RC" == "0" && "$UI_SEL_IDX" == "0" ]] && ok "ui_menu_select 快捷字母 r 选中下标 0" || fail "ui_menu_select r：RC=$MENU_RC IDX=$UI_SEL_IDX"
run_menu 'H\n' "请选择" 0 "${_ENTRIES[@]}"
[[ "$MENU_RC" == "0" && "$UI_SEL_IDX" == "1" ]] && ok "ui_menu_select 快捷字母大小写不敏感" || fail "ui_menu_select H：RC=$MENU_RC IDX=$UI_SEL_IDX"
run_menu 'q\n' "请选择" 0 "${_ENTRIES[@]}"
[[ "$MENU_RC" == "2" ]] && ok "ui_menu_select 输入 q 返回 2" || fail "ui_menu_select q：RC=$MENU_RC（期望 2）"
run_menu '' "请选择" 0 "${_ENTRIES[@]}"
[[ "$MENU_RC" == "3" ]] && ok "ui_menu_select EOF 返回 3" || fail "ui_menu_select EOF：RC=$MENU_RC（期望 3）"
run_menu '\n' "请选择" 2 "${_ENTRIES[@]}"
[[ "$MENU_RC" == "0" && "$UI_SEL_IDX" == "2" ]] && ok "ui_menu_select 空输入选中默认项" || fail "ui_menu_select 空输入：RC=$MENU_RC IDX=$UI_SEL_IDX"
run_menu '9\n2\n' "请选择" 0 "${_ENTRIES[@]}"
[[ "$MENU_RC" == "0" && "$UI_SEL_IDX" == "1" ]] && ok "ui_menu_select 无效输入后重问" || fail "ui_menu_select 9后2：RC=$MENU_RC IDX=$UI_SEL_IDX"

# =====================================================================
# 8. ui_confirm / ui_dialog_confirm（管道 = 非 TTY 行内路径）
# =====================================================================
run_confirm() { # $1=输入 $2=函数名
    local _input="$1" _fn="$2"
    "$_fn" "确认吗" < <(printf '%b' "$_input") > "$TMPD/confirm.out" 2>&1
    CONFIRM_RC=$?
}
run_confirm 'y\n' ui_confirm; [[ "$CONFIRM_RC" == "0" ]] && ok "ui_confirm 管道 y 返回 0" || fail "ui_confirm y：RC=$CONFIRM_RC"
run_confirm 'Y\n' ui_confirm; [[ "$CONFIRM_RC" == "0" ]] && ok "ui_confirm 管道 Y 返回 0" || fail "ui_confirm Y：RC=$CONFIRM_RC"
run_confirm 'n\n' ui_confirm; [[ "$CONFIRM_RC" == "1" ]] && ok "ui_confirm 管道 n 返回 1" || fail "ui_confirm n：RC=$CONFIRM_RC"
run_confirm '\n' ui_confirm;  [[ "$CONFIRM_RC" == "1" ]] && ok "ui_confirm 空行默认 N 返回 1" || fail "ui_confirm 空行：RC=$CONFIRM_RC"
run_confirm '' ui_confirm;    [[ "$CONFIRM_RC" == "1" ]] && ok "ui_confirm EOF 返回 1" || fail "ui_confirm EOF：RC=$CONFIRM_RC"
run_confirm 'y\n' ui_dialog_confirm; [[ "$CONFIRM_RC" == "0" ]] && ok "ui_dialog_confirm 管道 y 返回 0" || fail "ui_dialog_confirm y：RC=$CONFIRM_RC"
run_confirm 'n\n' ui_dialog_confirm; [[ "$CONFIRM_RC" == "1" ]] && ok "ui_dialog_confirm 管道 n 返回 1" || fail "ui_dialog_confirm n：RC=$CONFIRM_RC"

# =====================================================================
# 9. 输入组件
# =====================================================================
run_read() { # $1=输入 $2..=函数+参数
    local _input="$1"; shift
    "$@" < <(printf '%b' "$_input") > "$TMPD/read.out" 2>&1
    READ_RC=$?
}
run_read 'hello\n' ui_read_text "输入" "def"
[[ "$READ_RC" == "0" && "$UI_INPUT" == "hello" ]] && ok "ui_read_text 读入 hello" || fail "ui_read_text：RC=$READ_RC INPUT=$UI_INPUT"
run_read '\n' ui_read_text "输入" "def"
[[ "$READ_RC" == "0" && "$UI_INPUT" == "def" ]] && ok "ui_read_text 空输入返回默认值" || fail "ui_read_text 空输入：INPUT=$UI_INPUT"
run_read '' ui_read_text "输入" "def"
[[ "$READ_RC" != "0" ]] && ok "ui_read_text EOF 返回非零" || fail "ui_read_text EOF 应返回非零"
run_read 's3cr3t\n' ui_read_secret "密码"
[[ "$READ_RC" == "0" && "$UI_INPUT" == "s3cr3t" ]] && ok "ui_read_secret 静默读入" || fail "ui_read_secret：RC=$READ_RC INPUT=$UI_INPUT"
run_read '8443\n' ui_read_port "端口" "443"
[[ "$READ_RC" == "0" && "$UI_INPUT" == "8443" ]] && ok "ui_read_port 读入 8443" || fail "ui_read_port：RC=$READ_RC INPUT=$UI_INPUT"
run_read '\n' ui_read_port "端口" "443"
[[ "$READ_RC" == "0" && "$UI_INPUT" == "443" ]] && ok "ui_read_port 空输入返回默认值" || fail "ui_read_port 空输入：INPUT=$UI_INPUT"
run_read '2\n' ui_read_choice "选择" "甲|乙|丙" 0
[[ "$READ_RC" == "0" && "$UI_INPUT" == "1" ]] && ok "ui_read_choice 选 2 返回下标 1" || fail "ui_read_choice：RC=$READ_RC INPUT=$UI_INPUT"
run_read '\n' ui_read_choice "选择" "甲|乙|丙" 2
[[ "$READ_RC" == "0" && "$UI_INPUT" == "2" ]] && ok "ui_read_choice 空输入返回默认下标" || fail "ui_read_choice 空输入：INPUT=$UI_INPUT"
run_read '' ui_read_choice "选择" "甲|乙|丙" 0
[[ "$READ_RC" != "0" ]] && ok "ui_read_choice EOF 返回非零" || fail "ui_read_choice EOF 应返回非零"

# =====================================================================
# 10. 新组件：阶段 / spinner / 状态药丸 / 仪表盘 / 消息框
# =====================================================================
_out=$(ui_stage 2 5 "正在下载内核...")
[[ "$_out" == *"[2/5]"* && "$_out" == *"正在下载内核..."* ]] && ok "ui_stage 输出 [2/5] 描述" || fail "ui_stage 输出：$_out"
_out=$(ui_spinner_start "加载中..."; ui_spinner_stop "加载完成")
[[ "$_out" == *"加载中..."* && "$_out" == *"加载完成"* ]] && ok "ui_spinner 非 TTY 降级为 log 行" || fail "ui_spinner 输出：$_out"
_out=$(ui_status_pill running);  [[ "$_out" == *"RUNNING"* ]] && ok "ui_status_pill running" || fail "pill running：$_out"
_out=$(ui_status_pill stopped);  [[ "$_out" == *"STOPPED"* ]] && ok "ui_status_pill stopped" || fail "pill stopped：$_out"
_out=$(ui_status_pill error);    [[ "$_out" == *"ERROR"* ]] && ok "ui_status_pill error" || fail "pill error：$_out"
_out=$(ui_status_pill bogus);    [[ "$_out" == *"BOGUS"* ]] && ok "ui_status_pill 未知状态回退" || fail "pill bogus：$_out"
_out=$(ui_status_pill ok "已启用"); [[ "$_out" == *"已启用"* ]] && ok "ui_status_pill 自定义文本" || fail "pill 自定义：$_out"
SBM_COLS=80 ui_init
_out=$(ui_dash_row "节点标识" "host-01" "$WHITE" "公网地址" "1.2.3.4" "$CYAN")
[[ "$_out" == *"节点标识"* && "$_out" == *"公网地址"* ]] && ok "ui_dash_row 双列渲染" || fail "ui_dash_row 输出：$_out"
SBM_COLS=50 ui_init
_dash_lines=$(ui_dash_row "A" "1" "$WHITE" "B" "2" "$CYAN" | wc -l)
[[ "$_dash_lines" == "2" ]] && ok "ui_dash_row 窄屏退化两行" || fail "ui_dash_row 窄屏行数=$_dash_lines"
SBM_COLS=80 ui_init
_out=$(ui_msg_ok "成功消息"; ui_msg_warn "警告消息"; ui_msg_err "错误消息"; ui_msg_info "信息消息")
for _needle in "成功消息" "警告消息" "错误消息" "信息消息"; do
    [[ "$_out" == *"$_needle"* ]] || fail "消息框输出缺失：$_needle"
done
[[ "$_out" == *"信息消息"* ]] && ok "ui_msg_ok/warn/err/info 输出完整" || fail "消息框输出不完整"

# =====================================================================
# 11. 全模块联加载（sbx.sh 的 source 顺序，不执行主菜单）
# =====================================================================
_out=$(LC_ALL=C.utf8 bash -c '
source "$1/core/env.sh"; source "$1/core/ui.sh"; source "$1/core/state_manager.sh"
source "$1/core/json_builder.sh"; source "$1/core/engine.sh"
source "$1/utils/cert.sh"; source "$1/utils/sysctl.sh"; source "$1/utils/export.sh"; source "$1/utils/subscription.sh"
source "$1/protocols/reality.sh"; source "$1/protocols/hysteria2.sh"; source "$1/protocols/tuic.sh"
source "$1/protocols/argo.sh"; source "$1/protocols/socks5.sh"; source "$1/protocols/anytls.sh"; source "$1/protocols/warp.sh"
echo LOAD_OK
SBM_COLS=80 ui_init
ui_top; ui_proto_row "1/r" "VLESS-Reality" reality; ui_bot
' _ "$ROOT" 2>&1)
[[ "$_out" == *"LOAD_OK"* && "$_out" == *"VLESS-Reality"* ]] && ok "全模块联加载 + 面板渲染" || fail "全模块联加载失败：${_out:0:200}"

# =====================================================================
# 12. 伪终端：按键菜单会话 + 终端恢复（script(1)）
#    方向键已移除（2026-11-15 用户决定）：字母键立即执行，数字键需回车
#    确认，方向键序列到达时被忽略且不回显 ^[[。
# =====================================================================
if ! command -v script >/dev/null 2>&1; then
    skip "PTY 按键会话（沙箱无 script 命令）"
elif ! command -v timeout >/dev/null 2>&1; then
    skip "PTY 按键会话（沙箱无 timeout 命令）"
else
    cat > "$TMPD/pty_menu.sh" <<'PTYEOF'
#!/usr/bin/env bash
export LC_ALL=C.utf8 TERM=xterm
source "${ROOT}/core/env.sh"
source "${ROOT}/core/ui.sh"
before=$(stty -g)
ui_menu_select "请选择协议" 0 "1/r|VLESS-Reality|d1" "2/h|Hysteria 2|d2" "3/t|TUIC v5|d3"
rc=$?
after=$(stty -g)
echo "MENU_RC=$rc IDX=$UI_SEL_IDX KEY=$UI_SEL_KEY"
if [[ "$before" == "$after" ]]; then echo "STTY_OK"; else echo "STTY_DIFF before=$before after=$after"; fi
PTYEOF
    cat > "$TMPD/pty_confirm.sh" <<'PTYEOF'
#!/usr/bin/env bash
export LC_ALL=C.utf8 TERM=xterm
source "${ROOT}/core/env.sh"
source "${ROOT}/core/ui.sh"
before=$(stty -g)
ui_confirm "确定要彻底卸载吗"
rc=$?
after=$(stty -g)
echo "CONFIRM_RC=$rc"
if [[ "$before" == "$after" ]]; then echo "STTY_OK"; else echo "STTY_DIFF"; fi
PTYEOF
    # 按键延迟 0.6s 投递：等菜单打印完列表后再按键（真实敲击节奏）；
    # 尾部 sleep 保持管道打开，避免 script 在子进程读完前送 EOF。
    run_pty() { # $1=按键 $2=驱动脚本
        local _keys="$1" _drv="$2"
        (sleep 0.6; printf '%s' "$_keys"; sleep 0.4) \
            | ROOT="$ROOT" timeout 15 script -qec "bash $_drv" /dev/null 2>/dev/null | tr -d '\r'
    }
    _pty=$(run_pty $'3\n' "$TMPD/pty_menu.sh")
    if [[ "$_pty" == *"MENU_RC=0 IDX=2 KEY=3/t"* && "$_pty" == *"STTY_OK"* ]]; then ok "PTY 下数字 3+回车选中下标 2，stty 恢复"; else fail "PTY 数字 3+回车：${_pty}"; fi
    _pty=$(run_pty $'\n' "$TMPD/pty_menu.sh")
    if [[ "$_pty" == *"MENU_RC=0 IDX=0 KEY=1/r"* && "$_pty" == *"STTY_OK"* ]]; then ok "PTY 下回车选中默认项，stty 恢复"; else fail "PTY 回车：${_pty}"; fi
    _pty=$(run_pty $'\033' "$TMPD/pty_menu.sh")
    if [[ "$_pty" == *"MENU_RC=1"* && "$_pty" == *"STTY_OK"* ]]; then ok "PTY 下 Esc 返回 1，stty 恢复"; else fail "PTY Esc：${_pty}"; fi
    _pty=$(run_pty 'q' "$TMPD/pty_menu.sh")
    if [[ "$_pty" == *"MENU_RC=2"* && "$_pty" == *"STTY_OK"* ]]; then ok "PTY 下 q 退出返回 2，stty 恢复"; else fail "PTY q：${_pty}"; fi
    _pty=$(run_pty 'h' "$TMPD/pty_menu.sh")
    if [[ "$_pty" == *"MENU_RC=0 IDX=1 KEY=2/h"* && "$_pty" == *"STTY_OK"* ]]; then ok "PTY 下快捷键 h 选中下标 1，stty 恢复"; else fail "PTY h：${_pty}"; fi
    _pty=$(run_pty $'\003' "$TMPD/pty_menu.sh")
    if [[ "$_pty" == *"MENU_RC=3"* && "$_pty" == *"STTY_OK"* ]]; then ok "PTY 下 Ctrl+C 返回 3，stty 恢复"; else fail "PTY Ctrl+C：${_pty}"; fi
    _pty=$(run_pty $'\033[B\033[Aq' "$TMPD/pty_menu.sh")
    if [[ "$_pty" == *"MENU_RC=2"* && "$_pty" != *'^[[A'* && "$_pty" != *'^[[B'* ]]; then ok "PTY 下方向键序列被忽略且无 ^[[ 回显，q 正常退出"; else fail "PTY 方向键忽略：${_pty}"; fi
    _pty=$(run_pty $'\n' "$TMPD/pty_menu.sh")
    if [[ "$_pty" == *"字母直接进入 · 数字+回车确认"* ]]; then ok "PTY 下菜单提示行含字母/数字输入说明"; else fail "PTY 提示行缺失"; fi
    _pty=$(run_pty $'y\n' "$TMPD/pty_confirm.sh")
    if [[ "$_pty" == *"CONFIRM_RC=0"* && "$_pty" == *"STTY_OK"* && "$_pty" == *"╭"* ]]; then ok "PTY 下 ui_confirm 带边框确认框，y 返回 0"; else fail "PTY ui_confirm y：${_pty}"; fi
    _pty=$(run_pty $'n\n' "$TMPD/pty_confirm.sh")
    if [[ "$_pty" == *"CONFIRM_RC=1"* && "$_pty" == *"STTY_OK"* ]]; then ok "PTY 下 ui_confirm n 返回 1"; else fail "PTY ui_confirm n：${_pty}"; fi
fi

# =====================================================================
# 汇总
# =====================================================================
printf '\n==============================\n'
printf 'UI TEST SUMMARY: PASS=%s FAIL=%s SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
printf '==============================\n'
(( FAIL > 0 )) && exit 1
exit 0
