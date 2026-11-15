#!/usr/bin/env bash
# =====================================================================
#  core/ui/status.sh — 状态展示（新增）
#  职责：状态药丸（颜色 + 文字双通道，色盲/去色终端仍可读）。
#  ui_status_pill 输出不带换行，便于嵌入 ui_kv 等行内使用。
# =====================================================================

ui_status_pill() {   # <状态> [显示文本]，如 ui_status_pill running → ● RUNNING
    local st="${1,,}" label="${2:-${1^^}}" clr sym
    case "$st" in
        running|ok|up|enabled|on|active)
            clr="${GREEN:-}"; sym="${UI_ON:-●}" ;;
        stopped|down|off|disabled|inactive)
            clr="${GRAY:-}"; sym="${UI_OFF:-○}" ;;
        error|failed|fail)
            clr="${RED:-}"; sym="${UI_ON:-●}" ;;
        warn|warning|degraded)
            clr="${YELLOW:-}"; sym="${UI_ON:-●}" ;;
        *)
            clr="${GRAY:-}"; sym="${UI_OFF:-○}" ;;
    esac
    printf '%s%s %s%s' "$clr" "$sym" "$label" "${PLAIN:-}"
}
