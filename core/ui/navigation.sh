#!/usr/bin/env bash
# =====================================================================
#  core/ui/navigation.sh — 菜单导航（简化版，无方向键）
#  ui_menu_select：打印选项列表 + 按键选择（子菜单用）。
#  ui_menu_read_key：不打印列表，仅按键选择（主菜单/维护菜单用，调用方
#  已用 ui_panel_* 渲染面板，避免面板与列表重复显示）。
#  输入模型（2026-11-15 用户定）：
#    · 字母键：立即匹配执行，无需回车；
#    · 数字键：只缓存回显，必须按回车确认才匹配（否则输两位数如 10 会误入 1）；
#    · 回车（无数字缓存）：选中默认项；
#    · Esc：返回；q：退出；退格：删数字缓存最后一位。
#  方向键已移除（2026-11-15 用户决定：iPhone Termius 上不常用，字母键
#  更快；方向键是 bug 重灾区）。方向键等转义序列到达时整段忽略，不导航
#  也不回显成 ^[[A（Esc 后用短超时吞掉后续字节）。
#  TTY 下逐字节读：bash 的 read -n 会自行切非规范模式，无需 stty/dd，
#  不碰终端状态（退出后 stty 天然不变）；非 TTY 或 SBM_MENU_LINE=1 时
#  用 read -rp 整行读，语义与 v1.7.0 一致。
#  Ctrl+C：TTY 下经 INT trap + 短超时轮询返回 3（调用方作返回处理）——
#  trap 执行后 read 不会提前返回，故用 0.2s 短超时轮询查标志；行模式
#  下不设 trap，按默认行为终止脚本（与主线一致）。
#  环境变量：SBM_MENU_LINE=1 强制行输入模式；SBM_DEBUG_MENU=1 打印 TTY
#  检测详情（写 /dev/tty；无控制终端时走 stderr）。
# =====================================================================

UI_SEL_IDX=0        # 选中下标（0 起）
UI_SEL_KEY=""       # 选中项的 key 字段（如 "1/r"）
UI_MATCH_IDX=0      # _ui_menu_key_match 的匹配结果

_UI_MENU_KEYS=()
_UI_MENU_LABELS=()
_UI_MENU_DESCS=()
_UI_MENU_PROMPT=""
_UI_MENU_DEFAULT=0
_UI_MENU_KEY_ONLY=""   # 为 1 时行模式禁用数字序号定位（仅 key 匹配），供 ui_menu_read_key 用
_UI_MENU_INTERRUPTED=0 # INT trap 置位，_ui_menu_read_byte 轮询检查
_UI_MENU_BYTE=""       # _ui_menu_read_byte* 的输出变量

_ui_menu_debug() { # SBM_DEBUG_MENU=1 时打印调试信息；优先写 /dev/tty
    [[ -n "${SBM_DEBUG_MENU:-}" ]] || return 0
    printf '[menu-debug] %s\n' "$*" > /dev/tty 2>/dev/null \
        || printf '[menu-debug] %s\n' "$*" >&2
}

# TTY 判定（ui_menu_select 与 ui_menu_read_key 共用）：stdin 为 TTY 即
# 走逐字节读。TERM 不再作为条件（Termius 等终端可能误报 TERM，但 stdin
# 正常）；stty 不再需要（本文件已不调用 stty）。
ui_tty_ready() {
    local stdin_tty=0
    if [[ -t 0 ]]; then stdin_tty=1; fi
    _ui_menu_debug "SBM_MENU_LINE=${SBM_MENU_LINE:-<unset>} TERM=${TERM:-<unset>} stdin_tty=$stdin_tty"
    if [[ -n "${SBM_MENU_LINE:-}" ]]; then
        _ui_menu_debug "判定：行模式（SBM_MENU_LINE 已设置）"
        return 1
    fi
    if (( stdin_tty == 1 )); then
        _ui_menu_debug "判定：TTY 模式"
        return 0
    fi
    _ui_menu_debug "判定：行模式（stdin 非 TTY）"
    return 1
}

_ui_menu_parse_entries() {  # "$@" entries → _UI_MENU_KEYS/LABELS/DESCS
    local e k l d rest
    _UI_MENU_KEYS=(); _UI_MENU_LABELS=(); _UI_MENU_DESCS=()
    for e in "$@"; do
        if [[ "$e" == *"|"* ]]; then
            k="${e%%|*}"; rest="${e#*|}"
            if [[ "$rest" == *"|"* ]]; then l="${rest%%|*}"; d="${rest#*|}"; else l="$rest"; d=""; fi
        else
            k="$e"; l="$e"; d=""
        fi
        _UI_MENU_KEYS+=("$k"); _UI_MENU_LABELS+=("$l"); _UI_MENU_DESCS+=("$d")
    done
}

_ui_menu_key_match() { # $1 输入 → 匹配任一 entry key 中的快捷符（逗号或 / 分隔，字母不区分大小写）
    local input="$1" i tok
    local lower_input="${input,,}"
    local -a toks=()
    for (( i = 0; i < ${#_UI_MENU_KEYS[@]}; i++ )); do
        IFS=',/' read -r -a toks <<< "${_UI_MENU_KEYS[$i]}"
        for tok in "${toks[@]}"; do
            if [[ "${tok,,}" == "$lower_input" ]]; then
                UI_MATCH_IDX=$i
                return 0
            fi
        done
    done
    return 1
}

# ---------- 面板：调用方先渲染面板（ui_panel_*），再调 ui_menu_read_key 读键 ----------
# 背景（2026-11-15 用户真机反馈）：主菜单先画仪表盘（含全部选项），再调
# ui_menu_select 又在下方重画一遍 15 项列表，手机上两遍占满屏。面板模式
# 只显示一次面板，按键直接读，不另画列表。方向键移除后面板不再有高亮
# 行（无"当前选中"概念），ui_panel_add_menu 的下标仅作行属性记录。
_UI_PANEL_LINES=()    # 面板行（已渲染，含 ANSI）
_UI_PANEL_MENU=()     # 与行平行的 entry 下标，-1 = 非菜单行
_UI_PANEL_HINT=()     # 面板下方提示行

ui_panel_begin() {  # 重置面板
    _UI_PANEL_LINES=()
    _UI_PANEL_MENU=()
    _UI_PANEL_HINT=()
}

ui_panel_add() {   # $1 = 已渲染文本（可含换行，按行拆分，全部记为非菜单行）
    local text="$1"
    [[ -n "$text" ]] || return 0
    local -a _pl=()
    mapfile -t _pl <<< "$text"
    local l
    for l in "${_pl[@]}"; do
        _UI_PANEL_LINES+=("$l")
        _UI_PANEL_MENU+=(-1)
    done
}

ui_panel_add_menu() {  # $1 = entry 下标，$2 = 已渲染的单行菜单项
    _UI_PANEL_LINES+=("$2")
    _UI_PANEL_MENU+=("$1")
}

ui_panel_add_hint() {  # $1 = 已渲染文本（可含换行，按行拆分记为提示行）
    local text="$1"
    [[ -n "$text" ]] || return 0
    local -a _pl=()
    mapfile -t _pl <<< "$text"
    local l
    for l in "${_pl[@]}"; do _UI_PANEL_HINT+=("$l"); done
}

ui_panel_print() {  # 逐行打印面板 + 提示行（无高亮；方向键已移除）
    local i h
    for (( i = 0; i < ${#_UI_PANEL_LINES[@]}; i++ )); do
        printf '%s\n' "${_UI_PANEL_LINES[$i]}"
    done
    for h in "${_UI_PANEL_HINT[@]}"; do printf '%s\n' "$h"; done
}

# ---------- 选项列表打印（ui_menu_select 用；按 UI_W 截断，与旧版一致） ----------
_ui_menu_print_list() {
    local i n=${#_UI_MENU_KEYS[@]}
    local pre desc pre_w desc_w w=$(( UI_W - 2 ))
    (( w < 10 )) && w=10
    for (( i = 0; i < n; i++ )); do
        pre="[${_UI_MENU_KEYS[$i]}] ${_UI_MENU_LABELS[$i]}"
        ui_vwidth "  $pre"
        pre_w=$UI_VW
        if [[ -n "${_UI_MENU_DESCS[$i]}" ]]; then
            ui_vwidth "${_UI_MENU_DESCS[$i]}"
            desc_w=$UI_VW
            if (( pre_w + 2 + desc_w <= w )); then
                desc="${_UI_MENU_DESCS[$i]}"
            elif (( pre_w + 2 < w )); then
                ui_fit "${_UI_MENU_DESCS[$i]}" $(( w - pre_w - 2 ))
                desc="${UI_FIT%"${UI_FIT##*[! ]}"}"   # 去掉 ui_fit 的尾部补齐空格
            else
                ui_fit "  $pre  ${_UI_MENU_DESCS[$i]}" "$w"
                printf '%s\n' "${UI_FIT%"${UI_FIT##*[! ]}"}"
                continue
            fi
            printf '  %s[%s]%s %s%s%s  %s%s%s\n' "${CYAN:-}" "${_UI_MENU_KEYS[$i]}" "${PLAIN:-}" "${WHITE:-}" "${_UI_MENU_LABELS[$i]}" "${PLAIN:-}" "${GRAY:-}" "$desc" "${PLAIN:-}"
        elif (( pre_w <= w )); then
            printf '  %s[%s]%s %s%s%s\n' "${CYAN:-}" "${_UI_MENU_KEYS[$i]}" "${PLAIN:-}" "${WHITE:-}" "${_UI_MENU_LABELS[$i]}" "${PLAIN:-}"
        else
            ui_fit "  $pre" "$w"
            printf '%s\n' "${UI_FIT%"${UI_FIT##*[! ]}"}"
        fi
    done
}

# ---------- 逐字节读（TTY 路径用；bash read -n 自行管理 termios，无需 stty） ----------
# 返回：0=读到字节（_UI_MENU_BYTE），1=EOF/错误，2=被 Ctrl+C 中断。
# SIGINT 到达时 trap 只置 _UI_MENU_INTERRUPTED，read 本身不提前返回
# （2026-11-15 沙箱实测：trap 触发后 read 仍等满超时），故用 0.2s 短
# 超时轮询，每轮查标志；有按键时 read 立即返回，无额外延迟。
_ui_menu_read_byte() {
    local rc
    while :; do
        if (( _UI_MENU_INTERRUPTED )); then return 2; fi
        # -s 静默（不回显）；-d ''（NUL 分隔）：否则 read 会把 \n 当行分隔符吞掉，Enter 读不到
        IFS= read -rsn1 -d '' -t 0.2 _UI_MENU_BYTE 2>/dev/null
        rc=$?
        if (( rc == 0 )); then return 0; fi
        if (( _UI_MENU_INTERRUPTED )); then return 2; fi
        if (( rc <= 128 )); then return 1; fi   # EOF/错误；rc>128 为超时，继续等
    done
}

# 带超时的逐字节读（Esc 后吞转义序列用）。有字节返回 0，超时返回 1。
_ui_menu_read_byte_timed() {
    IFS= read -rsn1 -d '' -t "${1:-0.05}" _UI_MENU_BYTE 2>/dev/null
}

_ui_menu_restore_int() {  # $1 = trap -p INT 的旧输出（空 = 无旧 trap）：恢复调用方的 INT trap
    trap - INT 2>/dev/null || true
    [[ -n "${1:-}" ]] && eval "$1" 2>/dev/null || true
    _UI_MENU_INTERRUPTED=0
}

_ui_menu_prompt_line() {  # 打印一次输入提示（TTY 逐字节读用，数字回显跟在其后）
    printf ' %s%s%s %s：' "${CYAN:-}" "${UI_ARROW:-»}" "${PLAIN:-}" "$_UI_MENU_PROMPT"
}

# 按键循环（ui_menu_select 与 ui_menu_read_key 共用）。
# stdin 为 TTY 时逐字节读：字母键立即匹配、数字键回车确认、Esc 返回、
# q 退出；非 TTY 或 SBM_MENU_LINE=1 时用 read -rp 整行读，行为与 v1.7.0 一致。
# 前置：_UI_MENU_KEYS/LABELS/DESCS/_UI_MENU_PROMPT/_UI_MENU_DEFAULT 已设置。
# 返回：0=选中（UI_SEL_IDX/UI_SEL_KEY），1=Esc，2=q，3=EOF/中断
_ui_menu_read_keys() {
    local input n=${#_UI_MENU_KEYS[@]}
    if ! ui_tty_ready; then
        # 行模式：整行读（原有逻辑，原样保留）
        while :; do
            IFS= read -rp "$(ui_prompt_str "$_UI_MENU_PROMPT" "1-${n} / q")" input || return 3
            input="${input#"${input%%[![:space:]]*}"}"
            input="${input%"${input##*[![:space:]]}"}"
            if [[ -z "$input" ]]; then   # 空输入 = 默认项
                UI_SEL_IDX=$_UI_MENU_DEFAULT
                UI_SEL_KEY="${_UI_MENU_KEYS[$UI_SEL_IDX]}"
                return 0
            fi
            if [[ "$input" == "q" || "$input" == "Q" ]]; then return 2; fi
            if _ui_menu_key_match "$input"; then
                UI_SEL_IDX=$UI_MATCH_IDX
                UI_SEL_KEY="${_UI_MENU_KEYS[$UI_SEL_IDX]}"
                return 0
            fi
            # 数字序号定位：仅 ui_menu_select 行降级可用；ui_menu_read_key
            # （主菜单/维护菜单）禁用——否则输入 14 会选中序号 14 的卸载项，
            # 而旧版行模式里 14 是无效输入。
            if [[ -z "${_UI_MENU_KEY_ONLY:-}" && "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= n )); then
                UI_SEL_IDX=$(( input - 1 ))
                UI_SEL_KEY="${_UI_MENU_KEYS[$UI_SEL_IDX]}"
                return 0
            fi
            printf ' %s无效选项，请重新输入%s\n' "${YELLOW:-}" "${PLAIN:-}" >&2
        done
    fi
    # TTY：逐字节读。INT trap 只置标志，由 _ui_menu_read_byte 的短超时轮询检查。
    local _old_int
    _old_int="$(trap -p INT 2>/dev/null || true)"
    _UI_MENU_INTERRUPTED=0
    trap '_UI_MENU_INTERRUPTED=1' INT
    local key rest _digit_buf="" rc
    _ui_menu_prompt_line
    while :; do
        _ui_menu_read_byte
        rc=$?
        if (( rc != 0 )); then
            _ui_menu_restore_int "$_old_int"
            printf '\n'
            return 3   # EOF 或 Ctrl+C 中断
        fi
        key="$_UI_MENU_BYTE"
        # 数字键：只缓存 + 回显，不执行；回车时才匹配
        if [[ "$key" =~ ^[0-9]$ ]]; then
            _digit_buf+="$key"
            printf '%s' "$key"
            continue
        fi
        # 退格：删除数字缓存的最后一位（仅数字输入时有效）
        if [[ "$key" == $'\177' || "$key" == $'\010' ]]; then
            if [[ -n "$_digit_buf" ]]; then
                _digit_buf="${_digit_buf%?}"
                printf '\b \b'
            fi
            continue
        fi
        # 回车：有数字缓存时匹配缓存，无缓存时选中默认项
        if [[ "$key" == $'\r' || "$key" == $'\n' ]]; then
            if [[ -n "$_digit_buf" ]]; then
                if _ui_menu_key_match "$_digit_buf"; then
                    _ui_menu_restore_int "$_old_int"
                    printf '\n'
                    UI_SEL_IDX=$UI_MATCH_IDX
                    UI_SEL_KEY="${_UI_MENU_KEYS[$UI_SEL_IDX]}"
                    return 0
                fi
                printf '\n %s无效选项：%s，请重新输入%s\n' "${YELLOW:-}" "$_digit_buf" "${PLAIN:-}"
                _digit_buf=""
                _ui_menu_prompt_line
                continue
            fi
            _ui_menu_restore_int "$_old_int"
            printf '\n'
            UI_SEL_IDX=$_UI_MENU_DEFAULT
            UI_SEL_KEY="${_UI_MENU_KEYS[$UI_SEL_IDX]}"
            return 0
        fi
        # 其他按键：丢弃数字缓存，清掉本行回显后重打提示行
        if [[ -n "$_digit_buf" ]]; then
            printf '\r\033[2K'
            _ui_menu_prompt_line
            _digit_buf=""
        fi
        case "$key" in
            $'\033')
                # 区分单独 Esc 与转义序列：短超时读后续字节；有后续字节
                # 说明是方向键等序列，整段忽略（方向键已移除，不导航）；
                # 无后续字节才是单独 Esc = 返回。
                rest=""
                if _ui_menu_read_byte_timed 0.05; then
                    rest="$_UI_MENU_BYTE"
                    _ui_menu_read_byte_timed 0.05 || true
                fi
                if [[ -z "$rest" ]]; then
                    _ui_menu_restore_int "$_old_int"
                    printf '\n'
                    return 1
                fi
                ;;   # 转义序列：忽略，继续等按键
            $'\003'|$'\004')   # Ctrl+C（极少数终端直接递字节时）/ Ctrl+D
                _ui_menu_restore_int "$_old_int"
                printf '\n'
                return 3
                ;;
            'q'|'Q')
                _ui_menu_restore_int "$_old_int"
                printf '\n'
                return 2
                ;;
            *)
                # 字母键立即匹配（数字已在上方分支处理，不会走到这里）
                if _ui_menu_key_match "$key"; then
                    _ui_menu_restore_int "$_old_int"
                    printf '\n'
                    UI_SEL_IDX=$UI_MATCH_IDX
                    UI_SEL_KEY="${_UI_MENU_KEYS[$UI_SEL_IDX]}"
                    return 0
                fi
                ;;   # 无匹配按键：静默忽略
        esac
    done
}

# ---------- 公共入口 ----------
# 用法：ui_menu_select <prompt> <default_index> <entry...>
#   每个 entry 格式："key|label|desc"（key 如 "1/r"，desc 可空）
# 返回：0=选中，1=返回(Esc)，2=退出(q)，3=EOF/中断
# 结果变量：UI_SEL_IDX（0 起选中下标）、UI_SEL_KEY（选中项的 key 字段）
ui_menu_select() {
    local prompt="$1" def="${2:-0}"
    shift 2 || return 3
    _ui_menu_parse_entries "$@"
    local n=${#_UI_MENU_KEYS[@]}
    (( n == 0 )) && return 3
    _UI_MENU_PROMPT="$prompt"
    _UI_MENU_DEFAULT="$def"
    [[ "$_UI_MENU_DEFAULT" =~ ^[0-9]+$ ]] || _UI_MENU_DEFAULT=0
    (( _UI_MENU_DEFAULT >= n )) && _UI_MENU_DEFAULT=$(( n - 1 ))
    (( _UI_MENU_DEFAULT < 0 )) && _UI_MENU_DEFAULT=0
    UI_SEL_IDX=$_UI_MENU_DEFAULT
    UI_SEL_KEY="${_UI_MENU_KEYS[$UI_SEL_IDX]}"
    _UI_MENU_KEY_ONLY=""
    _ui_menu_print_list
    if [[ -t 1 ]]; then
        printf ' %s字母直接进入 · 数字+回车确认 · Esc 返回 · q 退出%s\n' "${GRAY:-}" "${PLAIN:-}"
    fi
    _ui_menu_read_keys
    return $?
}

# 用法：ui_menu_read_key <prompt> <default_index> <entry...>
# 单次按键选择：不打印列表（调用方已展示面板，如主菜单/维护菜单），
# 仅读取一次选择。TTY 下逐字节读（字母立即、数字需回车）；非 TTY 下
# read -rp 整行读。返回码与结果变量与 ui_menu_select 一致。
# 注意：禁用数字序号定位，仅 key 匹配——主菜单输入 14 在旧版是无效输入，
# 若按序号定位会选中第 14 项（卸载），行为不一致且危险。
ui_menu_read_key() {
    local prompt="$1" def="${2:-0}"
    shift 2 || return 3
    _ui_menu_parse_entries "$@"
    local n=${#_UI_MENU_KEYS[@]}
    (( n == 0 )) && return 3
    _UI_MENU_PROMPT="$prompt"
    _UI_MENU_DEFAULT="$def"
    [[ "$_UI_MENU_DEFAULT" =~ ^[0-9]+$ ]] || _UI_MENU_DEFAULT=0
    (( _UI_MENU_DEFAULT >= n )) && _UI_MENU_DEFAULT=$(( n - 1 ))
    (( _UI_MENU_DEFAULT < 0 )) && _UI_MENU_DEFAULT=0
    UI_SEL_IDX=$_UI_MENU_DEFAULT
    UI_SEL_KEY="${_UI_MENU_KEYS[$UI_SEL_IDX]}"
    _UI_MENU_KEY_ONLY=1
    _ui_menu_read_keys
    return $?
}
