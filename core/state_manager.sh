#!/usr/bin/env bash
# core/state_manager.sh — 状态文件管理（含并发安全）
#
# 并发策略：所有状态写入操作必须通过 _state_lock 获取 flock 文件锁，
# 锁文件为 ${SB_STATE}.lock，超时 10 秒。锁在函数返回时自动释放
# （通过 trap 和文件描述符管理）。

# 状态锁文件描述符（全局，避免重复打开）
_STATE_LOCK_FD=""
_STATE_LOCK_HELD=0
_STATE_LOCK_DEPTH=0

# 获取状态锁（阻塞最多 10 秒，可重入）
# 用法：_state_lock || return 1
# 深度计数：最外层获取 flock，嵌套调用只增加深度计数
_state_lock() {
    # 已持有锁，只增加深度计数（可重入）
    if [[ "$_STATE_LOCK_HELD" == "1" ]]; then
        _STATE_LOCK_DEPTH=$((_STATE_LOCK_DEPTH + 1))
        return 0
    fi
    local lock_file="${SB_STATE}.lock"
    # 确保锁文件存在且权限正确
    mkdir -p "$(dirname "$lock_file")" 2>/dev/null || return 1
    # 以读写方式打开锁文件（不存在则创建），分配 fd 200
    # 注意：此处绝不能加 2>/dev/null——exec 无命令时重定向作用于当前 shell，
    # 会把整个 shell 的 stderr 永久指向 /dev/null，导致所有 read -rp 提示
    # （pause、确认框等）不可见（2026-11-15 子菜单"卡住"调查确认）。
    exec 200>"$lock_file" || return 1
    chmod 600 "$lock_file" 2>/dev/null || true
    # 尝试获取排他锁，超时 10 秒
    if ! flock -w 10 -x 200 2>/dev/null; then
        log_err "获取状态锁超时（10 秒），可能有其他进程正在操作状态文件。"
        exec 200>&- || true
        return 1
    fi
    _STATE_LOCK_FD="200"
    _STATE_LOCK_HELD=1
    _STATE_LOCK_DEPTH=1
    return 0
}

# 释放状态锁（深度计数归零时才真正释放 flock）
_state_unlock() {
    if [[ "$_STATE_LOCK_HELD" == "1" ]]; then
        _STATE_LOCK_DEPTH=$((_STATE_LOCK_DEPTH - 1))
        if [[ "$_STATE_LOCK_DEPTH" -le 0 ]]; then
            flock -u 200 2>/dev/null || true
            exec 200>&- || true
            _STATE_LOCK_FD=""
            _STATE_LOCK_HELD=0
            _STATE_LOCK_DEPTH=0
        fi
    fi
}

# 状态 Schema 版本（结构变化时递增，并提供迁移函数）
# v1: 初始结构（version, installed_protocols, meta, protocols）
# v2: 增加 schema_version、app_version、updated_at 字段
STATE_SCHEMA_VERSION=2

# 状态迁移：从旧版本迁移到当前版本
# 用法：_migrate_state <当前版本>
# 返回：0=迁移成功或无需迁移，1=迁移失败
_migrate_state() {
    local current_ver="$1"
    if [[ "$current_ver" -ge "$STATE_SCHEMA_VERSION" ]]; then
        return 0
    fi
    log_info "正在迁移状态文件（schema v${current_ver} → v${STATE_SCHEMA_VERSION}）..."
    # 迁移前备份
    local bak="${SB_STATE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -f "$SB_STATE" "$bak" 2>/dev/null || {
        log_err "状态迁移前备份失败，拒绝迁移。"
        return 1
    }
    chmod 600 "$bak" 2>/dev/null || true

    local tmp
    tmp=$(mktemp "${SB_STATE}.XXXXXX") || return 1
    # v1 → v2：增加 schema_version、app_version、updated_at
    if [[ "$current_ver" -lt 2 ]]; then
        if ! jq --argjson ver "$STATE_SCHEMA_VERSION" --arg app "$SBM_VERSION" \
            --argjson ts "$(date +%s)" \
            '.schema_version = $ver | .app_version = $app | .updated_at = $ts' \
            "$SB_STATE" > "$tmp" 2>/dev/null; then
            log_err "状态迁移失败，已保留备份：$bak"
            rm -f "$tmp"
            return 1
        fi
        mv -f "$tmp" "$SB_STATE" || { rm -f "$tmp"; return 1; }
        chmod 600 "$SB_STATE"
    fi
    # 验证迁移后结构
    if ! jq -e 'type == "object" and (.protocols | type == "object") and (.installed_protocols | type == "array") and (.schema_version | type == "number")' "$SB_STATE" >/dev/null 2>&1; then
        log_err "迁移后状态文件验证失败，正在恢复备份..."
        cp -f "$bak" "$SB_STATE" 2>/dev/null || true
        return 1
    fi
    log_info "状态迁移完成（备份：$bak）。"
    return 0
}

init_state_file() {
    # 同一进程内、同路径、同 mtime 已验证过时直接返回：主菜单每次渲染触发数十次
    # 状态访问，省掉重复的 mkdir/chmod/jq 全量校验（单次约 10ms）。
    # 文件被改写（mtime 变化）则重新走全量校验，损坏文件依然会被拦下。
    local _cur_mtime
    _cur_mtime=$(stat -c '%y' "$SB_STATE" 2>/dev/null || echo "none")
    if [[ "${_SB_INIT_DONE:-}" == "${SB_STATE}@${_cur_mtime}" && "$_cur_mtime" != "none" ]]; then
        return 0
    fi
    # 迁移与初始化必须在锁保护下进行（防止并发创建/迁移竞态）
    _state_lock || return 1
    trap '_state_unlock' RETURN
    mkdir -p "$SB_ETC" "$SB_CERT_DIR" "$SB_EXPORT_DIR"
    chmod 700 "$SB_ETC" "$SB_EXPORT_DIR" 2>/dev/null || true
    if [[ -f "$SB_STATE" ]] && ! jq -e 'type == "object" and (.protocols | type == "object") and (.installed_protocols | type == "array")' "$SB_STATE" >/dev/null 2>&1; then
        log_err "状态文件损坏：$SB_STATE。为避免覆盖协议凭据，已停止操作。"
        return 1
    fi
    if [[ ! -f "$SB_STATE" ]]; then
        cat <<EOF > "$SB_STATE"
{
  "schema_version": ${STATE_SCHEMA_VERSION},
  "version": "${SBM_VERSION}",
  "app_version": "${SBM_VERSION}",
  "installed_protocols": [],
  "meta": {},
  "protocols": {},
  "updated_at": $(date +%s)
}
EOF
        chmod 600 "$SB_STATE"
    else
        chmod 600 "$SB_STATE" 2>/dev/null || return 1
        # 检查并迁移旧版本状态文件
        local cur_schema
        cur_schema=$(jq -r '.schema_version // 1' "$SB_STATE" 2>/dev/null || echo 1)
        if [[ ! "$cur_schema" =~ ^[0-9]+$ ]]; then
            log_err "状态文件 schema_version 无效，拒绝操作。"
            return 1
        fi
        if [[ "$cur_schema" -gt "$STATE_SCHEMA_VERSION" ]]; then
            log_err "状态文件版本（v$cur_schema）高于当前程序支持的版本（v$STATE_SCHEMA_VERSION），请升级程序。"
            return 1
        fi
        if [[ "$cur_schema" -lt "$STATE_SCHEMA_VERSION" ]]; then
            _migrate_state "$cur_schema" || return 1
        fi
    fi
    _SB_INIT_DONE="${SB_STATE}@$(stat -c '%y' "$SB_STATE" 2>/dev/null || echo 0)"
}

# 知名厂商识别：只收录识别可靠的大厂，ASN 精确匹配优先，org/isp 关键字兜底
# 识别不到返回空，调用方用"国家-主机名"兜底
detect_vendor() {
    local isp="$1" org="$2" asn="$3"
    case "$asn" in
        31898) echo "Oracle"; return 0 ;;
        15169|396982|36040) echo "Google"; return 0 ;;
        16509|14618) echo "AWS"; return 0 ;;
        8075) echo "Azure"; return 0 ;;
        13335) echo "Cloudflare"; return 0 ;;
    esac
    local lower="${isp} ${org}"
    lower="${lower,,}"
    case "$lower" in
        *oracle*) echo "Oracle" ;;
        *google*) echo "Google" ;;
        *amazon*|*aws*) echo "AWS" ;;
        *microsoft*|*azure*) echo "Azure" ;;
        *cloudflare*) echo "Cloudflare" ;;
        *) echo "" ;;
    esac
}

ensure_node_meta() {
    init_state_file || return 1
    local force="${1:-false}" cur_prefix
    cur_prefix=$(jq -r '.meta.node_prefix // empty' "$SB_STATE" 2>/dev/null || true)
    if [[ -n "$cur_prefix" && "$cur_prefix" != "null" && "$force" != "true" ]] &&
       [[ "$(jq -r '.meta.naming_version // 0' "$SB_STATE" 2>/dev/null)" -ge 3 ]]; then
        return 0
    fi

    local geo_json ip="" cc="US" city="" isp="" org="" as_num="" city_code node_id auto_prefix host_label vendor
    # GeoIP is optional. The display name deliberately avoids flags and vendor labels:
    # compact, sortable and stable across protocol exports.
    geo_json=$(curl --proto '=https' --tlsv1.2 -fsm5 -4 \
        "https://ipwho.is/?fields=success,ip,country_code,city,connection.isp,connection.org,connection.asn" || true)

    if [[ "$(echo "$geo_json" | jq -r '.success // false' 2>/dev/null)" == "true" ]]; then
        ip=$(echo "$geo_json" | jq -r '.ip // empty')
        cc=$(echo "$geo_json" | jq -r '.country_code // "US"')
        city=$(echo "$geo_json" | jq -r '.city // ""')
        isp=$(echo "$geo_json" | jq -r '.connection.isp // ""')
        org=$(echo "$geo_json" | jq -r '.connection.org // ""')
        as_num=$(echo "$geo_json" | jq -r '.connection.asn // ""')
    else
        ip=$(curl --proto '=https' --tlsv1.2 -fsS4m4 https://api.ipify.org 2>/dev/null || true)
        as_num="AS-Direct"
    fi
    ip="${ip//[$'\r\n ']/}"
    [[ "$cc" =~ ^[A-Za-z]{2}$ ]] || cc="ZZ"
    cc="${cc^^}"
    city_code=$(map_city_code "$city")
    [[ "$city_code" =~ ^[A-Z0-9]{2,6}$ ]] || city_code="LOC"
    node_id=$(jq -r '.meta.node_id // empty' "$SB_STATE" 2>/dev/null || true)
    if [[ ! "$node_id" =~ ^[A-F0-9]{4}$ ]]; then
        if [[ -n "$ip" ]] && command -v sha256sum >/dev/null 2>&1; then
            node_id=$(printf '%s' "$ip" | sha256sum | cut -c1-4 | tr '[:lower:]' '[:upper:]')
        else
            node_id="NODE"
        fi
    fi
    host_label=$(hostname -s 2>/dev/null | tr -cd 'A-Za-z0-9-' | cut -c1-16)
    [[ -n "$host_label" ]] || host_label="vps"
    # 知名厂商直接用厂商名（如 Oracle-Reality），识别不到用国家-主机名兜底
    vendor=$(detect_vendor "$isp" "$org" "$as_num")
    if [[ -n "$vendor" ]]; then
        auto_prefix="$vendor"
    else
        auto_prefix="${cc}-${host_label}"
    fi

    # 网络探测完成后才获取锁（避免长时间持有锁阻塞其他进程）
    _state_lock || return 1
    trap '_state_unlock' RETURN
    local tmp
    tmp=$(mktemp "${SB_STATE}.XXXXXX") || return 1
    jq --arg ip "$ip" --arg cc "$cc" --arg city "$city" \
       --arg asn "${as_num:-Direct}" \
       --arg node_id "$node_id" \
       --arg vendor "$vendor" \
       --arg prefix "$auto_prefix" '
       .meta = (.meta // {}) |
       .meta.ip = (if $ip != "" then $ip else (.meta.ip // "") end) |
       .meta.country = $cc |
       .meta.city = $city |
       .meta.asn = $asn |
       .meta.vendor = $vendor |
       .meta.node_id = (if ((.meta.node_id // "") | test("^[A-F0-9]{4}$")) then .meta.node_id else $node_id end) |
       .meta.custom_prefix = (if ((.meta.naming_version // 0) < 2 and
           ((.meta.custom_prefix // "") | test("^.{2} [A-Z]{2}-(RN|OCI|GCP|AWS|DMIT|BWG|Vultr|HZ|DO|CTB|Linode|Dedi|[A-Z]{2,6})(-[A-Z]{2,6})?$")))
           then null else .meta.custom_prefix end) |
       .meta.naming_version = 3 |
       .meta.node_prefix = (if (.meta.custom_prefix // "") != "" then .meta.custom_prefix else $prefix end)
    ' "$SB_STATE" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$SB_STATE" || { rm -f "$tmp"; return 1; }
}

get_node_prefix() {
    ensure_node_meta
    jq -r '.meta.node_prefix // "sbx-node"' "$SB_STATE"
}

set_custom_node_prefix() {
    local new_prefix="$1"
    if [[ -z "$new_prefix" || ${#new_prefix} -gt 64 || "$new_prefix" == *$'\n'* || "$new_prefix" == *$'\r'* || "$new_prefix" == *$'\t'* ]]; then
        log_err "节点前缀不能为空、不得超过 64 个字符，且不能包含控制字符。"
        return 1
    fi
    init_state_file || return 1
    _state_lock || return 1
    trap '_state_unlock' RETURN
    local tmp
    tmp=$(mktemp "${SB_STATE}.XXXXXX") || return 1
    jq --arg p "$new_prefix" '
        .meta = (.meta // {}) |
        .meta.custom_prefix = $p |
        .meta.node_prefix = $p
    ' "$SB_STATE" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$SB_STATE" || { rm -f "$tmp"; return 1; }
}

reset_node_naming() {
    init_state_file || return 1
    _state_lock || return 1
    trap '_state_unlock' RETURN
    local tmp
    tmp=$(mktemp "${SB_STATE}.XXXXXX") || return 1
    jq 'del(.meta.custom_prefix) | del(.meta.node_prefix) | .meta.naming_version = 3' "$SB_STATE" > "$tmp" &&
        chmod 600 "$tmp" && mv -f "$tmp" "$SB_STATE" || { rm -f "$tmp"; return 1; }
    ensure_node_meta
}

state_has_proto() {
    local proto="$1"
    init_state_file || return 1
    jq -e --arg p "$proto" '.installed_protocols | index($p) != null' "$SB_STATE" >/dev/null 2>&1
}

state_set_proto() {
    local proto="$1"
    local data_json="$2"
    init_state_file || return 1
    _state_lock || return 1
    trap '_state_unlock' RETURN
    local tmp
    tmp=$(mktemp "${SB_STATE}.XXXXXX") || return 1
    jq --arg p "$proto" --argjson d "$data_json" '
        .protocols[$p] = $d |
        if (.installed_protocols | index($p)) == null then
            .installed_protocols += [$p]
        else
            .
        end
    ' "$SB_STATE" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$SB_STATE" || { rm -f "$tmp"; return 1; }
}

state_del_proto() {
    local proto="$1"
    init_state_file || return 1
    _state_lock || return 1
    trap '_state_unlock' RETURN
    local tmp
    tmp=$(mktemp "${SB_STATE}.XXXXXX") || return 1
    jq --arg p "$proto" '
        del(.protocols[$p]) |
        .installed_protocols = (.installed_protocols - [$p])
    ' "$SB_STATE" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$SB_STATE" || { rm -f "$tmp"; return 1; }
}

state_get_proto() {
    local proto="$1"
    init_state_file || return 1
    jq -r --arg p "$proto" '.protocols[$p] // empty' "$SB_STATE"
}

state_get_field() {
    local proto="$1"
    local field="$2"
    init_state_file || return 1
    jq -r --arg p "$proto" --arg f "$field" '.protocols[$p][$f] // empty' "$SB_STATE"
}

state_set_field() {
    local proto="$1" field="$2" value="$3" tmp
    init_state_file || return 1
    _state_lock || return 1
    trap '_state_unlock' RETURN
    tmp=$(mktemp "${SB_STATE}.XXXXXX") || return 1
    jq --arg p "$proto" --arg f "$field" --arg v "$value" \
        '.protocols[$p][$f] = $v' "$SB_STATE" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$SB_STATE" || { rm -f "$tmp"; return 1; }
}

state_get_meta() {
    init_state_file || return 1
    jq -r --arg k "$1" '.meta[$k] // empty' "$SB_STATE" 2>/dev/null || true
}
