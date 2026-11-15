#!/usr/bin/env bash
# =====================================================================
#  core/ui/input.sh — 输入组件（新增）
#  职责：统一的业务参数输入。全部把结果写入 UI_INPUT，EOF 返回非零。
#  非交互（stdin 非 TTY）时直接读行，不渲染装饰；TTY 下用 ui_prompt_str
#  风格的提示。只做格式提示，不做业务校验（业务校验仍在 prompt_port 等
#  调用方）。
# =====================================================================

UI_INPUT=""

ui_read_text() {   # <提示> [默认值] → UI_INPUT；空输入返回默认值
    local prompt="$1" def="${2:-}"
    if [[ -t 0 ]]; then
        IFS= read -rp "$(ui_prompt_str "$prompt" "$def")" UI_INPUT || return 1
    else
        IFS= read -r UI_INPUT || return 1
    fi
    [[ -z "$UI_INPUT" ]] && UI_INPUT="$def"
    return 0
}

ui_read_secret() { # <提示> → UI_INPUT（静默读入，不回显）
    local prompt="$1"
    if [[ -t 0 ]]; then
        IFS= read -rsp "$(ui_prompt_str "$prompt" "")" UI_INPUT || return 1
        printf '\n'
    else
        IFS= read -r UI_INPUT || return 1
    fi
    return 0
}

ui_read_port() {   # <提示> [默认值] → UI_INPUT；仅格式提示，不做业务校验
    local prompt="$1" def="${2:-}"
    if [[ -t 0 ]]; then
        IFS= read -rp "$(ui_prompt_str "${prompt} (1-65535)" "$def")" UI_INPUT || return 1
    else
        IFS= read -r UI_INPUT || return 1
    fi
    [[ -z "$UI_INPUT" ]] && UI_INPUT="$def"
    return 0
}

ui_read_choice() { # <提示> <选项1|选项2|...> [默认下标 0 起] → UI_INPUT 为选中下标
    local prompt="$1" opts="$2" def="${3:-0}"
    local -a items=()
    local i input
    IFS='|' read -r -a items <<< "$opts"
    local n=${#items[@]}
    (( n == 0 )) && return 1
    [[ "$def" =~ ^[0-9]+$ ]] || def=0
    (( def >= n )) && def=$(( n - 1 ))
    if [[ -t 0 && -t 1 ]]; then
        for (( i = 0; i < n; i++ )); do
            if (( i == def )); then
                printf '  %s[%d]%s %s%s%s %s(默认)%s\n' "${CYAN:-}" $(( i + 1 )) "${PLAIN:-}" "${WHITE:-}" "${items[$i]}" "${PLAIN:-}" "${GRAY:-}" "${PLAIN:-}"
            else
                printf '  %s[%d]%s %s\n' "${CYAN:-}" $(( i + 1 )) "${PLAIN:-}" "${items[$i]}"
            fi
        done
    fi
    while :; do
        if [[ -t 0 ]]; then
            IFS= read -rp "$(ui_prompt_str "$prompt" "1-${n}")" input || return 1
        else
            IFS= read -r input || return 1
        fi
        input="${input#"${input%%[![:space:]]*}"}"
        input="${input%"${input##*[![:space:]]}"}"
        if [[ -z "$input" ]]; then
            UI_INPUT=$def
            return 0
        fi
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= n )); then
            UI_INPUT=$(( input - 1 ))
            return 0
        fi
        # TTY 下无效输入重问；非 TTY 下单次读取失败即返回非零，避免管道空转
        if [[ -t 0 ]]; then
            printf ' %s无效选择，请输入 1-%s%s\n' "${YELLOW:-}" "$n" "${PLAIN:-}" >&2
        else
            return 1
        fi
    done
}
