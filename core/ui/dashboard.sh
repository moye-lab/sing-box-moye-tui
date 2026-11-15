#!/usr/bin/env bash
# =====================================================================
#  core/ui/dashboard.sh — 仪表盘渲染辅助（新增，供 Phase 2 主界面使用）
#  职责：仪表盘双列键值行（标签列 10，与 ui_kv 一致）与分区标题。
#  窄屏/plain 模式下自动退化为两行单列 ui_kv。
# =====================================================================

ui_dash_row() {    # 双列：标签1 值1 颜色1 标签2 值2 颜色2（同 ui_kv2 签名）
    if [[ "${UI_MODE:-}" == "plain" || "${UI_MODE:-}" == "narrow" ]]; then
        ui_kv "$1" "$2" "$3"
        ui_kv "$4" "$5" "$6"
        return
    fi
    local total=$(( UI_IW - 4 ))
    local lw=$(( total / 2 )) rw=$(( total - total / 2 )) a b c d
    if (( lw - 12 < 1 || rw - 11 < 1 )); then
        ui_kv "$1" "$2" "$3"
        ui_kv "$4" "$5" "$6"
        return
    fi
    ui_fit "$1" 10;             a="$UI_FIT"
    ui_fit "$2" $(( lw - 12 )); b="$UI_FIT"
    ui_fit "$4" 10;             c="$UI_FIT"
    ui_fit "$5" $(( rw - 11 )); d="$UI_FIT"
    ui_line "${GRAY}${a}${PLAIN} ${3}${b}${PLAIN} ${GRAY}${c}${PLAIN} ${6}${d}${PLAIN}"
}

ui_dash_title() {  # 仪表盘分区标题（语义化入口，复用 ui_section）
    ui_section "$1" "${2:-}"
}
