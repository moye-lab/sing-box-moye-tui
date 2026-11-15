#!/usr/bin/env bash
# =====================================================================
#  core/ui/compatibility.sh — 旧接口兼容层
#  职责：凡是新模块未直接提供的旧函数名，在此做薄包装转发。
#  旧接口归属（全部签名不变，业务模块零改动）：
#    init.sh:       ui_init
#    terminal.sh:   ui_strip ui_cw ui_vwidth ui_fit ui_clear
#    layout.sh:     ui_top ui_mid ui_bot ui_rule ui_line ui_split ui_section
#    components.sh: ui_kv ui_kv2 ui_item ui_proto_row ui_proto_status
#                   ui_proto_detail ui_menu_head ui_prompt_str ui_hint
#                   ui_banner ui_node_card
#    dialog.sh:     ui_confirm（TTY 下升级为带边框确认框，签名/默认 N 不变）
#    本文件:        ui_box_top ui_box_mid ui_box_bot（旧版即为 ui_top 等的别名）
# =====================================================================

ui_box_top() { ui_top; }     # 兼容旧接口
ui_box_mid() { ui_mid; }
ui_box_bot() { ui_bot; }

_ui_compat_check() {   # 自检：全部旧接口是否都已定义；缺失时列出并返回 1
    local missing=() fn
    for fn in ui_top ui_mid ui_bot ui_box_top ui_box_mid ui_box_bot ui_line \
        ui_split ui_section ui_kv ui_kv2 ui_item ui_proto_row ui_proto_status \
        ui_proto_detail ui_menu_head ui_prompt_str ui_confirm ui_hint ui_banner \
        ui_node_card ui_clear ui_init ui_rule ui_strip ui_cw ui_vwidth ui_fit; do
        declare -F "$fn" >/dev/null 2>&1 || missing+=("$fn")
    done
    if (( ${#missing[@]} > 0 )); then
        printf 'ui: 缺少旧接口: %s\n' "${missing[*]}" >&2
        return 1
    fi
    return 0
}
