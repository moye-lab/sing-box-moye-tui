#!/usr/bin/env bash

RED=$'\033[38;5;196m'
GREEN=$'\033[38;5;48m'
YELLOW=$'\033[38;5;220m'
BLUE=$'\033[38;5;39m'
CYAN=$'\033[38;5;51m'
PURPLE=$'\033[38;5;141m'
GRAY=$'\033[38;5;242m'
WHITE=$'\033[38;5;255m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
PLAIN=$'\033[0m'

# 非 TTY / NO_COLOR 时自动去色（SBM_FORCE_COLOR=1 可强制开启）
if [[ -n "${NO_COLOR:-}" || ( ! -t 1 && -z "${SBM_FORCE_COLOR:-}" ) ]]; then
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; PURPLE=''
    GRAY=''; WHITE=''; BOLD=''; DIM=''; PLAIN=''
fi

SBM_VERSION="1.7.0"

SB_ETC="/etc/sing-box"
SB_CERT_DIR="/etc/sing-box/certs"
SB_EXPORT_DIR="/etc/sing-box/export"
SB_CONFIG="/etc/sing-box/config.json"
SB_STATE="/etc/sing-box/state.json"
SB_BIN="/usr/local/bin/sing-box"
CF_BIN="/usr/local/bin/cloudflared"
APP_HOME="${APP_HOME:-/usr/local/etc/sbx}"

log_info()  { echo -e " ${CYAN}ℹ${PLAIN} $*"; }
log_ok()    { echo -e " ${GREEN}✔${PLAIN} $*"; }
log_warn()  { echo -e " ${YELLOW}⚠${PLAIN} $*"; }
log_err()   { echo -e " ${RED}✖${PLAIN} $*"; }


check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "请使用 root 权限运行此脚本！"
        exit 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*) echo "armv7" ;;
        *) log_err "不支持的 CPU 架构: $(uname -m)"; exit 1 ;;
    esac
}

download_file() {
    local url="$1" dest="$2" tmp
    tmp=$(mktemp "${dest}.XXXXXX") || return 1
    case "$url" in
        https://*) ;;
        *) log_err "拒绝非 HTTPS 下载地址: $url"; rm -f "$tmp"; return 1 ;;
    esac
    if curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --connect-timeout 10 --max-time 300 "$url" -o "$tmp"; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$dest"
    else
        rm -f "$tmp"; return 1
    fi
}

pause() { read -rp " 按回车返回菜单..." _ || true; }

pkg_install() {
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@"
    else
        return 1
    fi
}

install_deps() {
    local missing=() optional=() cmd
    for cmd in curl jq openssl tar iptables python3; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ! command -v ss >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
        missing+=(lsof)
    fi
    command -v qrencode >/dev/null 2>&1 || optional+=(qrencode)

    if command -v apt-get >/dev/null 2>&1 && [[ ${#missing[@]} -gt 0 || ${#optional[@]} -gt 0 ]]; then
        apt-get update -y
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "正在安装基础依赖: ${missing[*]} ..."
        pkg_install "${missing[@]}" ca-certificates || {
            log_err "依赖安装失败，请手动安装: ${missing[*]}"; exit 1; }
    fi
    if [[ ${#optional[@]} -gt 0 ]]; then
        pkg_install "${optional[@]}" >/dev/null 2>&1 || log_warn "可选依赖 ${optional[*]} 安装失败（仅二维码功能不可用）"
    fi
}

is_valid_ip() {
    local value="$1"
    [[ -n "$value" ]] || return 1
    python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$value" >/dev/null 2>&1
}

get_public_ip() {
    local cached_ip="" cached_at="" now="" detected=""
    cached_ip=$(jq -r '.meta.ip // empty' "$SB_STATE" 2>/dev/null || true)
    cached_at=$(jq -r '.meta.ip_updated // 0' "$SB_STATE" 2>/dev/null || echo 0)
    now=$(date +%s 2>/dev/null || echo 0)

    # Keep the dashboard responsive: reuse a validated cache for six hours.
    if is_valid_ip "$cached_ip"; then
        if [[ "$cached_at" =~ ^[0-9]+$ ]] && (( now >= cached_at && now - cached_at < 21600 )); then
            echo "$cached_ip"
            return 0
        fi
    fi

    detected=$(curl --proto '=https' --tlsv1.2 -fsS4m4 https://api.ipify.org 2>/dev/null || true)
    if ! is_valid_ip "$detected"; then
        detected=$(curl --proto '=https' --tlsv1.2 -fsS6m4 https://api64.ipify.org 2>/dev/null || true)
    fi
    if is_valid_ip "$detected"; then
        if [[ -f "$SB_STATE" ]] && jq -e . "$SB_STATE" >/dev/null 2>&1; then
            # 如果状态锁可用则使用（state_manager.sh 已加载时）
            if declare -F _state_lock >/dev/null 2>&1; then
                _state_lock 2>/dev/null || true
                trap '_state_unlock 2>/dev/null; trap - RETURN' RETURN
            fi
            local tmp
            tmp=$(mktemp "${SB_STATE}.XXXXXX") || tmp=""
            if [[ -n "$tmp" ]]; then
                jq --arg ip "$detected" --argjson ts "$now" '.meta.ip = $ip | .meta.ip_updated = $ts' "$SB_STATE" > "$tmp" &&
                    chmod 600 "$tmp" && mv -f "$tmp" "$SB_STATE" || rm -f "$tmp"
            fi
        fi
        echo "$detected"
    elif [[ -n "$cached_ip" && "$cached_ip" != "null" ]]; then
        echo "$cached_ip"
    else
        echo "-"
    fi
}

map_city_code() {
    local city="$1"
    case "$city" in
        *"Los Angeles"*) echo "LAX" ;;
        *"San Jose"*|*"Silicon"*|*"Santa Clara"*) echo "SJC" ;;
        *"Seattle"*) echo "SEA" ;;
        *"Dallas"*) echo "DFW" ;;
        *"Chicago"*) echo "ORD" ;;
        *"New York"*|*"Newark"*|*"Secaucus"*|*"Buffalo"*) echo "NYC" ;;
        *"Miami"*) echo "MIA" ;;
        *"Atlanta"*) echo "ATL" ;;
        *"Ashburn"*) echo "IAD" ;;
        *"Phoenix"*) echo "PHX" ;;
        *"Salt Lake"*) echo "SLC" ;;
        *"Portland"*) echo "PDX" ;;
        *"Tokyo"*) echo "NRT" ;;
        *"Osaka"*) echo "KIX" ;;
        *"Hong Kong"*) echo "HKG" ;;
        *"Singapore"*) echo "SIN" ;;
        *"Frankfurt"*) echo "FRA" ;;
        *"Amsterdam"*) echo "AMS" ;;
        *"London"*) echo "LHR" ;;
        *"Seoul"*) echo "ICN" ;;
        *"Taipei"*) echo "TPE" ;;
        *)
            local clean
            clean=$(echo "$city" | tr -cd 'A-Za-z' | tr '[:lower:]' '[:upper:]')
            echo "${clean:0:3}"
            ;;
    esac
}

valid_domain_name() {
    local value="$1"
    [[ ${#value} -le 253 && "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    [[ "$value" != *..* ]] || return 1
    local label
    local -a _labels=()
    IFS='.' read -r -a _labels <<< "$value"
    for label in "${_labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

valid_host_or_ip() {
    local value="$1" a b c d part
    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r a b c d <<< "$value"
        for part in "$a" "$b" "$c" "$d"; do
            (( 10#$part <= 255 )) || return 1
        done
        return 0
    fi
    if [[ "$value" == *:* ]]; then
        # 含冒号按 IPv6 字面量严格校验（拒绝 1::2::3 这类畸形输入）
        is_valid_ip "$value"
        return
    fi
    valid_domain_name "$value"
}

urlencode() {
    printf '%s' "$1" | jq -sRr @uri
}

is_port_used() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn | grep -qE ":${port}[[:space:]]"
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" >/dev/null 2>&1
    else
        return 1
    fi
}

random_port() {
    local port
    while true; do
        port=$(shuf -i 10000-60000 -n 1)
        if ! is_port_used "$port"; then
            echo "$port"
            return
        fi
    done
}

prompt_port() {
    # 用法：prompt_port [默认端口]。安装时不传参，回车=随机；修改时可传当前端口，回车=保持不变。
    local default_port="${1:-}"
    local input_port prompt_text
    # SBX_AUTO=1（一键全装）时免询问：直接随机
    if [[ -n "${SBX_AUTO:-}" ]]; then
        random_port
        return
    fi
    if [[ -n "$default_port" ]]; then
        prompt_text=" 请输入监听端口 [默认: ${default_port}，输入 r 随机生成，输入 q 取消]: "
    else
        prompt_text=" 请输入监听端口 [默认随机生成，直接输入端口号手动指定，输入 q 取消]: "
    fi
    while true; do
        read -rp "$prompt_text" input_port || return 1
        if [[ "$input_port" == "q" || "$input_port" == "Q" ]]; then
            log_warn "已取消端口配置。" >&2
            return 1
        elif [[ "$input_port" == "r" || "$input_port" == "R" ]]; then
            input_port=$(random_port) || return 1
            log_info "已分配随机端口: $input_port" >&2
        elif [[ -z "$input_port" ]]; then
            if [[ -n "$default_port" ]]; then
                input_port="$default_port"
            else
                input_port=$(random_port) || return 1
                log_info "已分配随机端口: $input_port" >&2
            fi
        fi

        if ! [[ "$input_port" =~ ^[0-9]+$ ]] || (( input_port < 1 || input_port > 65535 )); then
            log_warn "端口必须是 1-65535 的整数，请重新输入。" >&2
            continue
        fi
        if is_port_used "$input_port"; then
            log_warn "端口 ${input_port} 已被占用，请重新选择。" >&2
            continue
        fi
        printf '%s\n' "$input_port"
        return 0
    done
}
