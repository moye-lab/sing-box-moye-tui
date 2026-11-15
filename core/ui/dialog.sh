#!/usr/bin/env bash
# =====================================================================
#  core/ui/dialog.sh — 消息框 / 确认框（新增）
#  职责：带边框的消息提示与确认框。ui_confirm 保留旧签名，TTY 下改用
#  带边框确认框渲染，非 TTY 退化为原有行内 [y/N] 提示；默认一律为 N
#  （取消），危险操作的确认强度不得降低。
# =====================================================================

_ui_msg_box() {   # <图标> <颜色> <消息>
    local icon="$1" clr="$2" msg="$3"
    if [[ "${UI_MODE:-}" == "plain" ]]; then
        _ui_plain_line "${icon} ${msg}"
        return
    fi
    ui_top
    ui_line "${clr}${icon}${PLAIN} ${msg}"
    ui_bot
}

ui_msg_ok()   { _ui_msg_box "✔" "${GREEN:-}" "$1"; }
ui_msg_warn() { _ui_msg_box "⚠" "${YELLOW:-}" "$1"; }
ui_msg_err()  { _ui_msg_box "✖" "${RED:-}" "$1"; }
ui_msg_info() { _ui_msg_box "ℹ" "${CYAN:-}" "$1"; }

ui_dialog_confirm() { # <提示> → 0=y/Y 确认，其余（含空输入/EOF）均为取消
    local msg="$1" a
    if [[ -t 0 && -t 1 ]]; then
        ui_top
        ui_line "${YELLOW:-}!${PLAIN:-} ${msg}"
        ui_line "${GRAY:-}默认取消，输入 y 确认${PLAIN:-}"
        ui_bot
        IFS= read -rp "$(printf ' %s%s%s [y/N]: ' "${CYAN:-}" "${UI_ARROW:-»}" "${PLAIN:-}")" a || return 1
    else
        IFS= read -rp "$(printf ' %s!%s %s %s[y/N]%s: ' "${YELLOW:-}" "${PLAIN:-}" "$msg" "${GRAY:-}" "${PLAIN:-}")" a || return 1
    fi
    [[ "$a" == "y" || "$a" == "Y" ]]
}

ui_confirm() {    # 旧接口：签名不变，TTY 下用带边框确认框，非 TTY 用行内提示
    ui_dialog_confirm "$1"
}
