#!/usr/bin/env bash
# core/json_builder.sh — sing-box 配置构建（含统一事务管理）

# 配置锁（独立于状态锁，防止多进程同时修改配置）
_CONFIG_LOCK_FD=""
_CONFIG_LOCK_HELD=0
_CONFIG_LOCK_DEPTH=0

_config_lock() {
    if [[ "$_CONFIG_LOCK_HELD" == "1" ]]; then
        _CONFIG_LOCK_DEPTH=$((_CONFIG_LOCK_DEPTH + 1))
        return 0
    fi
    local lock_file="${SB_CONFIG}.lock"
    mkdir -p "$(dirname "$lock_file")" 2>/dev/null || return 1
    exec 201>"$lock_file" 2>/dev/null || return 1
    chmod 600 "$lock_file" 2>/dev/null || true
    if ! flock -w 10 -x 201 2>/dev/null; then
        log_err "获取配置锁超时（10 秒），可能有其他进程正在修改配置。"
        exec 201>&- 2>/dev/null || true
        return 1
    fi
    _CONFIG_LOCK_FD="201"
    _CONFIG_LOCK_HELD=1
    _CONFIG_LOCK_DEPTH=1
    return 0
}

_config_unlock() {
    if [[ "$_CONFIG_LOCK_HELD" == "1" ]]; then
        _CONFIG_LOCK_DEPTH=$((_CONFIG_LOCK_DEPTH - 1))
        if [[ "$_CONFIG_LOCK_DEPTH" -le 0 ]]; then
            flock -u 201 2>/dev/null || true
            exec 201>&- 2>/dev/null || true
            _CONFIG_LOCK_FD=""
            _CONFIG_LOCK_HELD=0
            _CONFIG_LOCK_DEPTH=0
        fi
    fi
}

# 跨文件事务机制：同时修改状态和配置时的统一事务
# 锁获取顺序固定为：状态锁 → 配置锁（防止死锁）
# 用法：
#   operation_transaction_begin || return 1
#   # ... 修改状态和配置 ...
#   operation_transaction_commit || { operation_transaction_rollback; return 1; }
# 或使用 trap 自动回滚：
#   operation_transaction_begin || return 1
#   trap 'operation_transaction_rollback' ERR
_OP_TX_STATE_BAK=""
_OP_TX_CONFIG_BAK=""
_OP_TX_ACTIVE=0

operation_transaction_begin() {
    # 固定顺序：先状态锁，后配置锁
    _state_lock || return 1
    if ! _config_lock; then
        _state_unlock
        return 1
    fi
    # 备份状态和配置
    _OP_TX_STATE_BAK=$(mktemp "${SB_STATE}.tx.XXXXXX") || { _config_unlock; _state_unlock; return 1; }
    _OP_TX_CONFIG_BAK=$(mktemp "${SB_CONFIG}.tx.XXXXXX") || { rm -f "$_OP_TX_STATE_BAK"; _config_unlock; _state_unlock; return 1; }
    cp -f "$SB_STATE" "$_OP_TX_STATE_BAK" 2>/dev/null || true
    cp -f "$SB_CONFIG" "$_OP_TX_CONFIG_BAK" 2>/dev/null || true
    chmod 600 "$_OP_TX_STATE_BAK" "$_OP_TX_CONFIG_BAK" 2>/dev/null || true
    _OP_TX_ACTIVE=1
    return 0
}

operation_transaction_commit() {
    if [[ "$_OP_TX_ACTIVE" != "1" ]]; then
        log_err "没有活动的跨文件事务。"
        return 1
    fi
    rm -f "$_OP_TX_STATE_BAK" "$_OP_TX_CONFIG_BAK"
    _OP_TX_STATE_BAK=""
    _OP_TX_CONFIG_BAK=""
    _OP_TX_ACTIVE=0
    _config_unlock
    _state_unlock
    return 0
}

operation_transaction_rollback() {
    if [[ "$_OP_TX_ACTIVE" != "1" ]]; then
        return 0
    fi
    # 恢复状态和配置
    if [[ -f "$_OP_TX_STATE_BAK" ]]; then
        cp -f "$_OP_TX_STATE_BAK" "$SB_STATE" 2>/dev/null || log_err "状态回滚失败，请手动检查。"
    fi
    if [[ -f "$_OP_TX_CONFIG_BAK" ]]; then
        cp -f "$_OP_TX_CONFIG_BAK" "$SB_CONFIG" 2>/dev/null || log_err "配置回滚失败，请手动检查。"
        # 配置回滚后重载服务
        systemctl reload sing-box 2>/dev/null || systemctl restart sing-box 2>/dev/null || true
    fi
    rm -f "$_OP_TX_STATE_BAK" "$_OP_TX_CONFIG_BAK"
    _OP_TX_STATE_BAK=""
    _OP_TX_CONFIG_BAK=""
    _OP_TX_ACTIVE=0
    _config_unlock
    _state_unlock
    return 0
}

ensure_base_config() {
    mkdir -p "$SB_ETC"
    if [[ ! -f "$SB_CONFIG" ]]; then
        install -m 600 "$APP_HOME/templates/base.json" "$SB_CONFIG"
    else
        chmod 600 "$SB_CONFIG" 2>/dev/null || return 1
    fi
}

# 统一配置事务管理器
# 用法：config_transaction <jq_filter> [jq_args...]
#   jq_filter: jq 程序字符串（如 '.inbounds += [$item]'）
#   jq_args: 传递给 jq 的 --arg/--argjson 参数
# 流程：获取配置锁 → 备份 → jq 处理 → JSON 验证 → sing-box check → 原子替换 → 服务重载 → 失败回滚 → 释放锁
# 返回：0=成功，1=失败（已回滚）
config_transaction() {
    local jq_filter="$1"; shift
    _config_lock || return 1
    trap '_config_unlock' RETURN
    ensure_base_config || return 1

    local tmp_cfg bak_cfg
    tmp_cfg=$(mktemp "${SB_CONFIG}.XXXXXX") || return 1
    bak_cfg=$(mktemp "${SB_CONFIG}.bak.XXXXXX") || { rm -f "$tmp_cfg"; return 1; }
    cp -f "$SB_CONFIG" "$bak_cfg" || { rm -f "$tmp_cfg" "$bak_cfg"; return 1; }
    chmod 600 "$tmp_cfg" "$bak_cfg"

    if ! jq "$@" "$jq_filter" "$SB_CONFIG" > "$tmp_cfg" 2>/dev/null; then
        log_err "jq 配置处理失败，请检查传入的参数格式！"
        rm -f "$tmp_cfg" "$bak_cfg"
        return 1
    fi

    _commit_config "$tmp_cfg" "$bak_cfg"
}

apply_inbound() {
    local action="$1"
    local tag="$2"
    local default_json="{}"
    local inbound_json="${3:-$default_json}"

    if [[ "$action" == "add" ]]; then
        config_transaction \
            '.inbounds = ((.inbounds // []) | map(select(.tag != $tag)) + [$item])' \
            --arg tag "$tag" --argjson item "$inbound_json"
    elif [[ "$action" == "del" ]]; then
        config_transaction \
            '.inbounds = ((.inbounds // []) | map(select(.tag != $tag)))' \
            --arg tag "$tag"
    else
        log_err "未知的构建动作: $action"
        return 1
    fi
}

reload_singbox_service() {
    if systemctl is-active --quiet sing-box; then
        _systemctl_timed reload sing-box 2>/dev/null || _systemctl_timed restart sing-box
    else
        systemctl enable sing-box >/dev/null 2>&1 || true
        _systemctl_timed restart sing-box
    fi
    sleep 1
    systemctl is-active --quiet sing-box
}

# 带超时保护的 systemctl 调用（默认 15 秒，可用 SBX_SYSTEMCTL_TIMEOUT 覆盖）。
# 背景（2026-11-15 真机教训）：systemctl restart 在某些环境下会长时间挂起，
# 用户误以为卡死按 Ctrl+C，导致上层事务（如 WARP 健康检查的临时域名恢复）
# 被中断、状态残留。超时后返回 124，调用方按失败处理（回滚/报错），不再无限等待。
# 注意：测试环境 systemctl 常被 mock 为 shell 函数，timeout 是外部命令调不到
# 函数，故函数 mock 或系统无 timeout 命令时直接调用。
_systemctl_timed() {
    if [[ "$(type -t systemctl)" == "function" ]] || ! command -v timeout >/dev/null 2>&1; then
        systemctl "$@"
    else
        timeout "${SBX_SYSTEMCTL_TIMEOUT:-15}" systemctl "$@"
    fi
}

# 通用配置写回：把 jq 处理后的临时配置校验、生效、失败回滚
# 用法：_commit_config "$tmp_cfg" "$bak_cfg"
_commit_config() {
    local tmp_cfg="$1" bak_cfg="$2"
    if ! jq empty "$tmp_cfg" >/dev/null 2>&1; then
        log_err "生成的配置文件不是合法的 JSON 格式！"
        rm -f "$tmp_cfg" "$bak_cfg"
        return 1
    fi
    if [[ -x "$SB_BIN" ]]; then
        if ! "$SB_BIN" check -c "$tmp_cfg" >/dev/null 2>&1; then
            log_err "Sing-box 配置语法校验未通过！已放弃本次更改。"
            "$SB_BIN" check -c "$tmp_cfg" || true
            rm -f "$tmp_cfg" "$bak_cfg"
            return 1
        fi
    fi
    mv -f "$tmp_cfg" "$SB_CONFIG" || { rm -f "$bak_cfg"; return 1; }
    chmod 600 "$SB_CONFIG"
    if ! reload_singbox_service; then
        log_err "服务未能正常运行，已回滚到修改前的配置。"
        mv -f "$bak_cfg" "$SB_CONFIG"
        chmod 600 "$SB_CONFIG"
        reload_singbox_service || true
        return 1
    fi
    rm -f "$bak_cfg"
    return 0
}

# 出站管理（与 apply_inbound 对称，用于 WARP 等出站）
# 用法：apply_outbound add|del <tag> [outbound_json]
apply_outbound() {
    local action="$1"
    local tag="$2"
    local default_json="{}"
    local outbound_json="${3:-$default_json}"

    if [[ "$action" == "add" ]]; then
        config_transaction \
            '.outbounds = ((.outbounds // []) | map(select(.tag != $tag)) + [$item])' \
            --arg tag "$tag" --argjson item "$outbound_json"
    elif [[ "$action" == "del" ]]; then
        config_transaction \
            '.outbounds = ((.outbounds // []) | map(select(.tag != $tag)))' \
            --arg tag "$tag"
    else
        log_err "未知的构建动作: $action"
        return 1
    fi
}

# 端点管理（与 apply_outbound 对称，用于 WARP 等 WireGuard 端点）
# sing-box 1.11+ 起 WireGuard 出站已废弃，改用 Endpoint 方式。
# 用法：apply_endpoint add|del <tag> [endpoint_json]
apply_endpoint() {
    local action="$1"
    local tag="$2"
    local default_json="{}"
    local endpoint_json="${3:-$default_json}"

    if [[ "$action" == "add" ]]; then
        config_transaction \
            '.endpoints = ((.endpoints // []) | map(select(.tag != $tag)) + [$item])' \
            --arg tag "$tag" --argjson item "$endpoint_json"
    elif [[ "$action" == "del" ]]; then
        config_transaction \
            '.endpoints = ((.endpoints // []) | map(select(.tag != $tag)))' \
            --arg tag "$tag"
    else
        log_err "未知的构建动作: $action"
        return 1
    fi
}

# 分流路由规则管理：把指定域名列表指向指定出站
# 用法：apply_route_rules '<domains_json_array>' <outbound_tag>
# 域名列表为空时删除该出站的规则；非空时写入/更新一条 domain_suffix 规则。
# 规则归属（结构识别，不写自定义字段到配置）：
#   WARP 的三条规则是：sniff → resolve[domain_suffix=X] → outbound[domain_suffix=X]。
#   删除时按结构识别：outbound 规则按 tag 匹配；resolve 规则按 domain_suffix
#   与 WARP 出站规则的 domain_suffix 完全一致匹配；裸 sniff 规则（仅 action
#   字段）在写入时清理、清空时保留（通用无害）。用户自定义规则（带额外字段
#   的 sniff、其他 domain_suffix 的 resolve、其他出站的规则）一律保留。
# 注意：sing-box 配置 schema 不认自定义字段，sbx_owner 等标识绝不能写入
# config.json（2026-11-15 实测：sing-box check 报 unknown field 致分流失败）。
apply_route_rules() {
    local domains_json="$1"
    local outbound_tag="$2"

    local count
    count=$(echo "$domains_json" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$count" -eq 0 ]]; then
        # 清空：删除 WARP 出站规则 + 与其 domain_suffix 匹配的 resolve 规则；
        # 裸 sniff 保留（通用无害，下次写入时清理）。
        config_transaction \
            '(.route.rules // []) as $r
            | ([$r[] | select(.outbound == $ob) | .domain_suffix]) as $wd
            | .route.rules = [$r[] | select(
                .outbound != $ob
                and (.action != "resolve" or ((.domain_suffix) as $ds | ($wd | any(. == $ds)) | not))
              )]' \
            --arg ob "$outbound_tag"
    else
        # 写入/更新：先删旧 WARP 规则（出站 + 匹配的 resolve + 裸 sniff），
        # 再在头部插入 sniff + resolve + 出站规则。
        # sniff 必须在最前面，否则 sing-box 不知道流量要访问哪个域名，
        # domain_suffix 规则永远匹配不上（实测教训：RN 上不加 sniff 分流失效）。
        config_transaction \
            '(.route.rules // []) as $r
            | ([$r[] | select(.outbound == $ob) | .domain_suffix]) as $wd
            | ([$r[] | select(
                .outbound != $ob
                and (.action != "resolve" or ((.domain_suffix) as $ds | ($wd | any(. == $ds)) | not))
                and (. != {action: "sniff"})
              )]) as $clean
            | .route.rules = ([{action: "sniff"}, {action: "resolve", domain_suffix: $domains, strategy: "prefer_ipv4"}, {domain_suffix: $domains, outbound: $ob}] + $clean)' \
            --arg ob "$outbound_tag" --argjson domains "$domains_json"
    fi
}
