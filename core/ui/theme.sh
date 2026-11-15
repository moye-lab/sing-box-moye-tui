#!/usr/bin/env bash
# =====================================================================
#  core/ui/theme.sh — 主题变量
#  职责：语义化主题色（映射到 core/env.sh 的颜色变量）与状态符号。
#  业务代码应优先用 T_* 而不是裸颜色变量；旧代码继续用 RED/GREEN 等
#  不受影响。颜色定义本身仍在 env.sh，这里只做映射，不改定义。
# =====================================================================

# 语义色（env.sh 未加载时退化为空串，即无色）
T_PRIMARY="${CYAN:-}"    # 青：品牌、标题、操作键
T_SUCCESS="${GREEN:-}"   # 绿：成功、已启用
T_WARNING="${YELLOW:-}"  # 黄：警告、待确认
T_DANGER="${RED:-}"      # 红：错误、危险操作
T_INFO="${BLUE:-}"       # 蓝：信息、边框
T_MUTED="${GRAY:-}"      # 灰：次要文字、描述
T_ACCENT="${PURPLE:-}"   # 紫：强调、版本号
T_TEXT="${WHITE:-}"      # 白：正文
T_BOLD="${BOLD:-}"
T_DIM="${DIM:-}"
T_RESET="${PLAIN:-}"

# 状态符号（字符集由 ui_init 决定，这里先给 Unicode 默认值，
# _ui_theme_apply 会在每次 ui_init 后按 UI_ON/UI_OFF 重算）
T_SYM_OK='●'
T_SYM_OFF='○'
T_SYM_ARROW='❯'
T_SYM_DIA='◆'
T_SYM_ELL='…'

_ui_theme_apply() {
    T_PRIMARY="${CYAN:-}"
    T_SUCCESS="${GREEN:-}"
    T_WARNING="${YELLOW:-}"
    T_DANGER="${RED:-}"
    T_INFO="${BLUE:-}"
    T_MUTED="${GRAY:-}"
    T_ACCENT="${PURPLE:-}"
    T_TEXT="${WHITE:-}"
    T_BOLD="${BOLD:-}"
    T_DIM="${DIM:-}"
    T_RESET="${PLAIN:-}"
    T_SYM_OK="${UI_ON:-●}"
    T_SYM_OFF="${UI_OFF:-○}"
    T_SYM_ARROW="${UI_ARROW:-❯}"
    T_SYM_DIA="${UI_DIA:-◆}"
    T_SYM_ELL="${UI_ELL:-…}"
}
