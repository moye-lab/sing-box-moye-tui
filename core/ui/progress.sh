#!/usr/bin/env bash
# =====================================================================
#  core/ui/progress.sh — 进度 / 阶段（新增）
#  职责：多阶段任务的阶段提示与旋转加载指示。动画仅在 TTY 且未禁用时
#  生效（SBM_NO_ANIM=1 禁用）；非 TTY 自动降级为普通 log 行。
#  spinner 子进程以 kill -0 $PPID 自检，父进程退出后自动停止，不留孤儿。
# =====================================================================

UI_SPINNER_PID=""
UI_SPINNER_MSG=""

ui_stage() {   # <当前> <总数> <描述>，如 ui_stage 1 3 "正在下载内核..."
    printf ' %s[%s/%s]%s %s\n' "${CYAN:-}" "$1" "$2" "${PLAIN:-}" "$3"
}

ui_spinner_start() {   # <提示>：TTY 下启动旋转指示，非 TTY 打印一行 log
    local msg="$1"
    UI_SPINNER_MSG="$msg"
    UI_SPINNER_PID=""
    if [[ -t 1 && -z "${SBM_NO_ANIM:-}" ]]; then
        (
            _sp_frames='|/-\'
            _sp_i=0
            while kill -0 "$PPID" 2>/dev/null; do
                printf '\r %s %s' "${_sp_frames:_sp_i%4:1}" "$msg"
                sleep 0.1
                _sp_i=$(( _sp_i + 1 ))
            done
        ) &
        UI_SPINNER_PID=$!
    else
        if declare -F log_info >/dev/null 2>&1; then log_info "$msg"; else printf ' %s\n' "$msg"; fi
    fi
}

ui_spinner_stop() {    # [完成提示]：停转并清行；有完成提示时打印一行成功 log
    local done_msg="${1:-}"
    if [[ -n "$UI_SPINNER_PID" ]]; then
        kill "$UI_SPINNER_PID" 2>/dev/null || true
        wait "$UI_SPINNER_PID" 2>/dev/null || true
        UI_SPINNER_PID=""
        printf '\r\033[2K'
        if [[ -n "$done_msg" ]]; then
            if declare -F log_ok >/dev/null 2>&1; then log_ok "$done_msg"; else printf ' %s\n' "$done_msg"; fi
        fi
    elif [[ -n "$done_msg" ]]; then
        if declare -F log_ok >/dev/null 2>&1; then log_ok "$done_msg"; else printf ' %s\n' "$done_msg"; fi
    fi
    UI_SPINNER_MSG=""
}
