#!/usr/bin/env bash
# =====================================================================
#  core/ui/layout.sh — 面板 / 分区 / 排版
#  职责：边框线、内容行、左右对齐行、分区标题。plain 模式（<40 列）下
#  边框函数退化为空操作，行函数输出去色截断的纯文本。
#  所有行输出都经 ui_line 的 _ui_truncate_ansi 兜底，永不越界。
# =====================================================================

_ui_plain_line() {   # 纯文本行：去色、截断到 UI_W（plain 模式专用）
    ui_strip "$1"
    _ui_truncate_ansi "$UI_STRIPPED" "$UI_W"
    printf '%s\n' "$UI_TRUNC"
}

# ---------- 边框与行 ----------
ui_rule() {
    [[ "${UI_MODE:-}" == "plain" ]] && return 0
    local l="$1" r="$2" bar
    printf -v bar '%*s' "$UI_IW" ''
    printf '%s%s%s%s%s\n' "$UI_BC" "$l" "${bar// /$UI_H}" "$r" "$PLAIN"
}
ui_top() { ui_rule "$UI_TL" "$UI_TR"; }
ui_mid() { ui_rule "$UI_ML" "$UI_MR"; }
ui_bot() { ui_rule "$UI_BL" "$UI_BR"; }

ui_line() {    # 一行内容（两侧各留 2 格边距），自动补齐并闭合右边框
    local content="  ${1:-}" pad
    if [[ "${UI_MODE:-}" == "plain" ]]; then
        _ui_plain_line "$content"
        return
    fi
    _ui_truncate_ansi "$content" "$UI_IW"
    content="$UI_TRUNC"
    ui_vwidth "$content"
    pad=$(( UI_IW - UI_VW )); (( pad < 0 )) && pad=0
    printf '%s%s%s%s%s%*s%s%s%s\n' "$UI_BC" "$UI_V" "$PLAIN" "$content" "$PLAIN" "$pad" "" "$UI_BC" "$UI_V" "$PLAIN"
}

ui_split() {   # 左右两端对齐的一行
    local l="$1" r="${2:-}" lw rw gap sp
    if [[ "${UI_MODE:-}" == "plain" ]]; then
        if [[ -n "$r" ]]; then _ui_plain_line "${l}  ${r}"; else _ui_plain_line "$l"; fi
        return
    fi
    ui_vwidth "$l"; lw=$UI_VW
    ui_vwidth "$r"; rw=$UI_VW
    gap=$(( UI_IW - 4 - lw - rw )); (( gap < 1 )) && gap=1
    printf -v sp '%*s' "$gap" ''
    ui_line "${l}${sp}${r}"
}

ui_section() { ui_line "${PURPLE}${BOLD}${UI_DIA} ${1}${PLAIN}  ${GRAY}${2:-}${PLAIN}"; }
