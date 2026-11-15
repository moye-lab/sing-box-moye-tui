#!/usr/bin/env bash
# =====================================================================
#  core/ui/components.sh — 业务展示组件
#  职责：键值行、菜单项、协议状态行、菜单头、提示、横幅、节点卡片。
#  窄屏（40~59 列）：ui_kv2 退化为两行单列 ui_kv；ui_item 描述空间不足
#  时省略描述；标签列/标题列按 UI_KV_LAB/UI_ITEM_TITLE 收紧。
#  plain 模式（<40 列）：全部输出纯文本行。
# =====================================================================

ui_kv() {      # 标签  值  [颜色]
    local lab="$1" val="$2" clr="${3:-$WHITE}" L V
    if [[ "${UI_MODE:-}" == "plain" ]]; then
        _ui_plain_line "${lab} ${val}"
        return
    fi
    ui_fit "$lab" "$UI_KV_LAB"; L="$UI_FIT"
    ui_fit "$val" $(( UI_IW - 4 - UI_KV_LAB - 1 )); V="$UI_FIT"
    ui_line "${GRAY}${L}${PLAIN} ${clr}${V}${PLAIN}"
}

ui_kv2() {     # 双列：标签1 值1 颜色1 标签2 值2 颜色2
    if [[ "${UI_MODE:-}" == "plain" || "${UI_MODE:-}" == "narrow" ]]; then
        ui_kv "$1" "$2" "$3"
        ui_kv "$4" "$5" "$6"
        return
    fi
    local total=$(( UI_IW - 4 ))
    local lw=$(( total / 2 )) rw=$(( total - total / 2 )) a b c d
    ui_fit "$1" 8;            a="$UI_FIT"
    ui_fit "$2" $(( lw - 10 )); b="$UI_FIT"
    ui_fit "$4" 8;            c="$UI_FIT"
    ui_fit "$5" $(( rw - 9 ));  d="$UI_FIT"
    ui_line "${GRAY}${a}${PLAIN} ${3}${b}${PLAIN} ${GRAY}${c}${PLAIN} ${6}${d}${PLAIN}"
}

ui_item() {    # 键位  名称  说明  [名称颜色]
    local key="$1" label="$2" desc="${3:-}" lclr="${4:-$WHITE}" K L D dw
    if [[ "${UI_MODE:-}" == "plain" ]]; then
        if [[ -n "$desc" ]]; then
            _ui_plain_line "[${key}] ${label} - ${desc}"
        else
            _ui_plain_line "[${key}] ${label}"
        fi
        return
    fi
    dw=$(( UI_IW - 4 - 7 - 1 - UI_ITEM_TITLE - 1 ))
    (( dw < 8 )) && desc=""   # 窄屏描述空间不足时省略描述
    ui_fit "[${key}]" 7;  K="$UI_FIT"
    ui_fit "$label" "$UI_ITEM_TITLE";   L="$UI_FIT"
    ui_fit "$desc" "$dw"; D="$UI_FIT"
    ui_line "${CYAN}${BOLD}${K}${PLAIN} ${lclr}${BOLD}${L}${PLAIN} ${GRAY}${D}${PLAIN}"
}

# ---------- 协议状态 ----------
ui_proto_detail() {   # → UI_DETAIL（纯文本）
    local p="$1" port sni hop mode
    case "$p" in
        reality)
            port=$(state_get_field "reality" "port"); sni=$(state_get_field "reality" "sni")
            UI_DETAIL="TCP · ${port} · ${sni}" ;;
        hysteria2)
            port=$(state_get_field "hysteria2" "port"); hop=$(state_get_field "hysteria2" "hop_range")
            UI_DETAIL="UDP · ${port}${hop:+ · Hop $hop}" ;;
        tuic)
            port=$(state_get_field "tuic" "port")
            UI_DETAIL="UDP · ${port} · BBR" ;;
        argo)
            mode=$(state_get_field "argo" "mode")
            UI_DETAIL="WS · ${mode^}" ;;
        socks5)
            port=$(state_get_field "socks5" "port")
            UI_DETAIL="TCP+UDP · ${port}" ;;
        anytls)
            port=$(state_get_field "anytls" "port")
            UI_DETAIL="TCP · ${port} · TLS" ;;
        *) UI_DETAIL="" ;;
    esac
}

ui_proto_row() {      # 键位  名称  协议标识
    local key="$1" title="$2" p="$3" K T S D dw
    if [[ "${UI_MODE:-}" == "plain" ]]; then
        if state_has_proto "$p"; then
            ui_proto_detail "$p"
            _ui_plain_line "[${key}] ${title} ${UI_ON} 已启用 ${UI_DETAIL}"
        else
            _ui_plain_line "[${key}] ${title} ${UI_OFF} 未安装"
        fi
        return
    fi
    ui_fit "[${key}]" 7; K="$UI_FIT"
    ui_fit "$title" "$UI_ITEM_TITLE";  T="$UI_FIT"
    if state_has_proto "$p"; then
        ui_proto_detail "$p"
        ui_fit "${UI_ON} 已启用" 9; S="$UI_FIT"
        dw=$(( UI_IW - 4 - 7 - 1 - UI_ITEM_TITLE - 1 - 9 - 1 ))
        (( dw < 8 )) && UI_DETAIL=""
        ui_fit "$UI_DETAIL" "$dw"; D="$UI_FIT"
        ui_line "${CYAN}${BOLD}${K}${PLAIN} ${WHITE}${BOLD}${T}${PLAIN} ${GREEN}${S}${PLAIN} ${GRAY}${D}${PLAIN}"
    else
        ui_fit "${UI_OFF} 未安装" 9; S="$UI_FIT"
        ui_line "${CYAN}${BOLD}${K}${PLAIN} ${GRAY}${T} ${S}${PLAIN}"
    fi
}

ui_proto_status() {   # 子菜单顶部的当前状态行
    local p="$1"
    if state_has_proto "$p"; then
        ui_proto_detail "$p"
        ui_kv "当前状态" "${UI_ON} 已启用 · ${UI_DETAIL}" "$GREEN"
    else
        ui_kv "当前状态" "${UI_OFF} 未安装" "$GRAY"
    fi
}

# ---------- 屏幕 / 交互 ----------
ui_menu_head() {      # 标题  面包屑
    ui_clear
    ui_top
    ui_split "${BOLD}${CYAN}${1}${PLAIN}" "${GRAY}SING-BOX MOYE › ${2}${PLAIN}"
    ui_mid
}

ui_prompt_str() {     # 提示文字  可选项
    printf '\n %s%s%s %s %s[%s]%s: ' "$CYAN" "$UI_ARROW" "$PLAIN" "$1" "$GRAY" "${2:-}" "$PLAIN"
}

ui_hint() { printf ' %s%s%s\n' "$GRAY" "$1" "$PLAIN"; }

ui_banner() {         # 安装流程的小标题
    local bar title
    if [[ "${UI_MODE:-}" == "plain" ]]; then
        printf '\n'
        _ui_plain_line "$1"
        return
    fi
    _ui_truncate_ansi "$1" $(( UI_W - 6 ))
    title="$UI_TRUNC"
    printf -v bar '%*s' $(( UI_W - 4 )) ''
    printf '\n  %s%s▌ %s%s\n  %s%s%s\n' "$CYAN" "$BOLD" "$title" "$PLAIN" "$GRAY" "${bar// /$UI_H}" "$PLAIN"
}

ui_node_card() {      # 名称  说明  链接（链接不入框，便于整行复制）
    # 注意：链接故意不截断（截断会破坏复制），超长链接在窄屏下可能越界，
    # 这是可复制性优先于对齐的有意取舍。
    printf '\n  %s%s%s %s%s%s%s  %s%s%s\n' "$GREEN" "$UI_ON" "$PLAIN" "$WHITE" "$BOLD" "$1" "$PLAIN" "$GRAY" "$2" "$PLAIN"
    printf '  %s%s%s\n' "$CYAN" "$3" "$PLAIN"
}
