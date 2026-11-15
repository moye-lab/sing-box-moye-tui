#!/usr/bin/env bash
# =====================================================================
#  core/ui/terminal.sh — 终端能力：宽度计算、清屏
#  职责：ANSI 去除、CJK/Emoji 显示宽度计算、纯文本截断/补齐、含 ANSI
#        文本的安全截断、清屏。宽度计算必须排除 ANSI 码（沿用 ui_strip）。
# =====================================================================

shopt -s globasciiranges 2>/dev/null || true

ui_strip() {   # 去除 ANSI 颜色码 → UI_STRIPPED
    local s="$1" re=$'\033\\[[0-9;]*m'
    if [[ "$s" == *$'\033'* ]]; then
        while [[ "$s" =~ $re ]]; do s="${s/"${BASH_REMATCH[0]}"/}"; done
    fi
    UI_STRIPPED="$s"
}

ui_cw() {      # 码点 → 显示宽度 UI_CW
    local cp="$1"
    if (( cp < 32 || (cp >= 127 && cp < 160) || cp == 0x200b || cp == 0x200c || cp == 0x200d || cp == 0x20e3 || (cp >= 0xfe00 && cp <= 0xfe0f) )); then
        UI_CW=0
    elif (( (cp >= 0x1100 && cp <= 0x115f) || cp == 0x26a1 || cp == 0x2705 || cp == 0x274c || cp == 0x2b50 \
         || (cp >= 0x2e80 && cp <= 0xa4cf) || (cp >= 0xac00 && cp <= 0xd7a3) || (cp >= 0xf900 && cp <= 0xfaff) \
         || (cp >= 0xfe30 && cp <= 0xfe6f) || (cp >= 0xff00 && cp <= 0xff60) || (cp >= 0xffe0 && cp <= 0xffe6) \
         || (cp >= 0x1f300 && cp <= 0x1f64f) || (cp >= 0x1f680 && cp <= 0x1f6ff) || (cp >= 0x1f900 && cp <= 0x1f9ff) \
         || (cp >= 0x20000 && cp <= 0x3fffd) )); then
        UI_CW=2
    else
        UI_CW=1
    fi
}

ui_vwidth() {  # 字符串（可含颜色码）的显示宽度 → UI_VW
    ui_strip "$1"
    local s="$UI_STRIPPED"
    case "$s" in
        *[!\ -~]*) ;;
        *) UI_VW=${#s}; return ;;
    esac
    local i c cp w=0 n=${#s}
    for (( i = 0; i < n; i++ )); do
        c="${s:i:1}"
        printf -v cp '%d' "'$c"
        ui_cw "$cp"
        (( w += UI_CW ))
    done
    UI_VW=$w
}

ui_fit() {     # 纯文本截断/补齐到 w 列 → UI_FIT
    local s="$1" w="$2" out="" i c cp tot=0 n pad
    (( w < 1 )) && { UI_FIT=""; return; }
    ui_vwidth "$s"
    if (( UI_VW <= w )); then
        printf -v pad '%*s' $(( w - UI_VW )) ''
        UI_FIT="${s}${pad}"
        return
    fi
    n=${#s}
    for (( i = 0; i < n; i++ )); do
        c="${s:i:1}"
        printf -v cp '%d' "'$c"
        ui_cw "$cp"
        (( tot + UI_CW > w - 1 )) && break
        out+="$c"
        (( tot += UI_CW ))
    done
    out+="$UI_ELL"; (( tot += 1 ))
    printf -v pad '%*s' $(( w - tot )) ''
    UI_FIT="${out}${pad}"
}

_ui_truncate_ansi() {  # 含 ANSI 码文本截断到 max 可见列 → UI_TRUNC（不补齐）
    # ANSI 转义序列原样透传、可视字符按显示宽度计数，超长时以 UI_ELL 收尾。
    # 未超长时原样返回。调用方负责在截断后补 PLAIN 复位（ui_line 已做）。
    local s="$1" max="$2" out="" vis=0 i=0 n c cp j ch
    (( max < 1 )) && { UI_TRUNC=""; return; }
    ui_vwidth "$s"
    if (( UI_VW <= max )); then UI_TRUNC="$s"; return; fi
    n=${#s}
    while (( i < n )); do
        c="${s:i:1}"
        if [[ "$c" == $'\033' && "${s:i+1:1}" == "[" ]]; then
            j=$(( i + 2 ))
            while (( j < n )); do
                ch="${s:j:1}"
                j=$(( j + 1 ))
                [[ "$ch" =~ [A-Za-z] ]] && break
            done
            out+="${s:i:j-i}"
            i=$j
            continue
        fi
        printf -v cp '%d' "'$c"
        ui_cw "$cp"
        if (( vis + UI_CW > max - 1 )); then break; fi
        out+="$c"
        (( vis += UI_CW ))
        i=$(( i + 1 ))
    done
    out+="${UI_ELL:-…}"
    UI_TRUNC="$out"
}

# ---------- 清屏 ----------
ui_clear() {
    ui_init
    if [[ -t 1 ]]; then printf '\033[H\033[2J\033[3J'; fi
}
