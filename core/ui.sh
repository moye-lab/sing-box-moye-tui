#!/usr/bin/env bash
# =====================================================================
#  core/ui.sh — 终端 UI 组件库（统一入口，Phase 1 模块化重构）
#  · 宽度模式：≥120→100列 / 100~119→96 / 80~99→78 / 60~79→cols-2 /
#    40~59→cols-2（窄屏）/ <40→plain 纯文本降级
#  · CJK / Emoji 显示宽度精确对齐，右侧边框不再错位；行输出永不越界
#  · NO_COLOR / 非 TTY 自动去色；非 UTF-8 终端自动降级为 ASCII 边框
#  环境变量: SBM_ASCII=1 强制 ASCII | NO_COLOR=1 关闭颜色
#            SBM_FORCE_COLOR=1 强制颜色 | SBM_COLS=N 覆盖终端宽度
#            SBM_MENU_LINE=1 强制行输入菜单 | SBM_NO_ANIM=1 禁用动画
#            SBM_DEBUG_MENU=1 打印菜单 TTY 检测详情
#  若边框在 Xshell/PuTTY 等终端右侧错位，请把"不明宽度字符"设为"窄(Narrow)"
#
#  模块（core/ui/，依赖单向，无循环引用）：
#    init → theme → terminal → layout → components → input / navigation /
#    dialog / progress / status / dashboard → compatibility
#  旧接口全部保留（见 core/ui/compatibility.sh 的归属表），业务模块零改动。
#  加载顺序：core/env.sh（颜色）必须在 core/ui.sh 之前 source（sbx.sh 已如此）。
# =====================================================================

shopt -s globasciiranges 2>/dev/null || true

_UI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/ui" 2>/dev/null && pwd || true)"
if [[ -z "$_UI_DIR" || ! -f "$_UI_DIR/init.sh" ]]; then
    _UI_DIR="${APP_HOME:-/usr/local/etc/sbx}/core/ui"
fi
for _ui_mod in init theme terminal layout components input navigation dialog progress status dashboard compatibility; do
    if [[ ! -f "$_UI_DIR/$_ui_mod.sh" ]]; then
        echo "ui: 缺少模块 $_UI_DIR/$_ui_mod.sh" >&2
        return 1 2>/dev/null || exit 1
    fi
    # shellcheck source=/dev/null
    source "$_UI_DIR/$_ui_mod.sh"
done
unset _ui_mod _UI_DIR

ui_init
