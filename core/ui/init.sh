#!/usr/bin/env bash
# =====================================================================
#  core/ui/init.sh — UI 初始化与环境检测
#  职责：终端宽度检测（SBM_COLS / tput）、宽度模式判定、边框字符集选择、
#        列宽规范（ui_kv 标签列 / ui_item 标题列）的窄屏收紧。
#  依赖：仅 core/env.sh 的颜色变量（UI_BC）；_ui_theme_apply 在运行时调用，
#        与 theme.sh 的加载顺序无关。
# =====================================================================

UI_W=78          # 外框总宽
UI_IW=76         # 内宽（不含左右边框）
UI_MODE=normal   # wide | normal | compact | narrow | plain
UI_COLS=80       # 检测到的终端列数（SBM_COLS 覆盖后即为覆盖值）
UI_KV_LAB=10     # ui_kv 标签列宽（用户定规：正常 10，窄屏收紧）
UI_ITEM_TITLE=16 # ui_item / ui_proto_row 标题列宽（用户定规：正常 16，窄屏收紧）
UI_BC=""         # 边框颜色（= BLUE）

# 宽度模式（替代旧版固定 58~78）：
#   ≥120 列 → UI_W=100（wide）   100~119 → UI_W=96（wide）
#   80~99  → UI_W=78（normal）   60~79   → UI_W=cols-2（compact）
#   40~59  → UI_W=cols-2（narrow，ui_kv2 退化单列、ui_item 描述可省略）
#   <40    → UI_MODE=plain，全部边框函数退化为空操作，行函数输出纯文本
ui_init() {
    local cols="${SBM_COLS:-}" cm
    if [[ -z "$cols" ]]; then
        if [[ -t 1 ]]; then cols=$(tput cols 2>/dev/null || echo 80); else cols=80; fi
    fi
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    UI_COLS=$cols
    if (( cols >= 120 )); then
        UI_W=100; UI_MODE=wide
    elif (( cols >= 100 )); then
        UI_W=96; UI_MODE=wide
    elif (( cols >= 80 )); then
        UI_W=78; UI_MODE=normal
    elif (( cols >= 60 )); then
        UI_W=$(( cols - 2 )); UI_MODE=compact
    elif (( cols >= 40 )); then
        UI_W=$(( cols - 2 )); UI_MODE=narrow
    else
        UI_W=$cols; UI_MODE=plain
    fi
    (( UI_W < 1 )) && UI_W=1
    UI_IW=$(( UI_W - 2 ))
    (( UI_IW < 0 )) && UI_IW=0
    if (( UI_W >= 60 )); then
        UI_KV_LAB=10; UI_ITEM_TITLE=16
    else
        UI_KV_LAB=8; UI_ITEM_TITLE=12
    fi
    UI_BC="${BLUE:-}"

    cm=$(locale charmap 2>/dev/null || true)
    if [[ "$cm" == "UTF-8" && -z "${SBM_ASCII:-}" ]]; then
        UI_TL='╭'; UI_TR='╮'; UI_BL='╰'; UI_BR='╯'
        UI_H='─'; UI_V='│'; UI_ML='├'; UI_MR='┤'
        UI_ON='●'; UI_OFF='○'; UI_ARROW='❯'; UI_DIA='◆'; UI_ELL='…'
    else
        UI_TL='+'; UI_TR='+'; UI_BL='+'; UI_BR='+'
        UI_H='-'; UI_V='|'; UI_ML='+'; UI_MR='+'
        UI_ON='*'; UI_OFF='o'; UI_ARROW='>'; UI_DIA='#'; UI_ELL='~'
    fi

    # 主题变量随环境重算（颜色可能在 ui.sh 加载后才就绪）
    if declare -F _ui_theme_apply >/dev/null 2>&1; then
        _ui_theme_apply
    fi
}
