#!/usr/bin/env bash
# protocols/warp.sh — Cloudflare WARP 出站 + 域名分流
#
# 用途：VPS 原生 IP 被某些服务（如 Gemini / ChatGPT）封锁时，
# 把指定域名走 WARP 出口（Cloudflare IP），绕过封锁。
#
# 实现：直接调 Cloudflare API 注册 WARP 账号（不用 wgcf，
# wgcf 在 RN 上被 Cloudflare 限流报 500），以 sing-box 原生
# wireguard 端点接入，分流用 route 规则。

WARP_PEER_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
WARP_ENDPOINT="162.159.192.1"
WARP_PORT=2408
WARP_API_URL="https://api.cloudflareclient.com/v0a2158/reg"

# AI 解锁预设域名（三模式）
# 精简模式：只分流 AI 专用域名，不影响普通 Google 服务
WARP_AI_DOMAINS_MINIMAL="gemini.google.com generativelanguage.googleapis.com aistudio.google.com ai.google.dev openai.com chatgpt.com oaiusercontent.com sora.com anthropic.com claude.ai x.ai grok.com perplexity.ai meta.ai copilot.microsoft.com deepseek.com mistral.ai cohere.com poe.com huggingface.co hf.co midjourney.com suno.com runwayml.com leonardo.ai groq.com together.ai muse.ai"
# 兼容模式：精简模式 + Google 通用域名（解决某些 AI 服务需要完整 Google 生态的问题）
WARP_AI_DOMAINS_COMPAT="$WARP_AI_DOMAINS_MINIMAL google.com googleapis.com accounts.google.com bing.com meta.com"
# 保留旧变量名以兼容（指向兼容模式）
WARP_AI_DOMAINS="$WARP_AI_DOMAINS_COMPAT"

warp_installed() {
    state_has_proto "warp"
}

install_warp() {
    ensure_singbox_installed || return 1
    ui_banner "安装 Cloudflare WARP 出站"

    if warp_installed; then
        log_warn "WARP 已安装。如需重新注册请先卸载。"
        return 0
    fi

    log_info "正在生成 WireGuard 密钥对 ..."
    local keypair priv_key pub_key
    keypair=$(openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -text -noout 2>/dev/null)
    if [[ -z "$keypair" ]]; then
        log_err "生成 WireGuard 密钥失败（openssl 不可用）。"
        return 1
    fi
    priv_key=$(echo "$keypair" | awk '/priv:/{flag=1; next} /pub:/{flag=0} flag' | tr -d '[:space:]' | xxd -r -p 2>/dev/null | base64 -w0)
    pub_key=$(echo "$keypair" | awk '/pub:/{flag=1} flag' | tr -d '[:space:]' | xxd -r -p 2>/dev/null | base64 -w0)
    if [[ -z "$priv_key" || -z "$pub_key" ]]; then
        log_err "解析 WireGuard 密钥失败。"
        return 1
    fi

    log_info "正在向 Cloudflare 注册 WARP 账号 ..."
    local response http_code
    # 使用 -w 获取 HTTP 状态码，区分不同错误类型
    response=$(curl -sL --tlsv1.3 --connect-timeout 5 --max-time 15 \
        -w "\n%{http_code}" \
        -X POST "$WARP_API_URL" \
        -H 'CF-Client-Version: a-7.21-0721' \
        -H 'Content-Type: application/json' \
        -d "{\"key\": \"$pub_key\", \"tos\": \"$(date -u +'%Y-%m-%dT%H:%M:%S.000Z')\"}" 2>/dev/null)
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')

    # 检查 HTTP 状态码
    if [[ "$http_code" != "200" ]]; then
        case "$http_code" in
            429) log_err "WARP 注册失败：Cloudflare API 限流（429），请稍后再试。" ;;
            500|502|503|504) log_err "WARP 注册失败：Cloudflare 服务器错误（HTTP $http_code），请稍后再试。" ;;
            000) log_err "WARP 注册失败：无法连接到 Cloudflare API（网络问题或超时）。" ;;
            *) log_err "WARP 注册失败：Cloudflare API 返回 HTTP $http_code。" ;;
        esac
        return 1
    fi

    # 验证响应 JSON 格式
    if [[ -z "$response" ]] || ! echo "$response" | jq -e . >/dev/null 2>&1; then
        log_err "WARP 注册失败：API 返回无效 JSON。"
        return 1
    fi
    if ! echo "$response" | jq -e '.config.client_id' >/dev/null 2>&1; then
        log_err "WARP 注册失败：API 响应缺少 client_id 字段。"
        return 1
    fi

    # 从 API 响应解析配置
    local client_id addr_v4 addr_v6
    client_id=$(echo "$response" | jq -r '.config.client_id')
    addr_v4=$(echo "$response" | jq -r '.config.interface.addresses.v4')
    addr_v6=$(echo "$response" | jq -r '.config.interface.addresses.v6')

    # 严格验证 client_id（4 字符 base64）
    if [[ ! "$client_id" =~ ^[A-Za-z0-9+/]{4}$ ]]; then
        log_err "WARP 注册失败：client_id 格式异常（应为 4 字符 base64）。"
        return 1
    fi

    # 严格验证 IPv4 地址
    if ! is_valid_ip "$addr_v4"; then
        log_err "WARP 注册失败：IPv4 地址无效（$addr_v4）。"
        return 1
    fi
    # IPv6 地址可选，但如果存在必须有效
    if [[ -n "$addr_v6" && "$addr_v6" != "null" ]] && ! is_valid_ip "$addr_v6"; then
        log_err "WARP 注册失败：IPv6 地址无效（$addr_v6）。"
        return 1
    fi

    # 地址需要加子网掩码
    addr_v4="${addr_v4}/32"
    if [[ -n "$addr_v6" && "$addr_v6" != "null" ]]; then
        addr_v6="${addr_v6}/128"
    else
        addr_v6=""
    fi

    # 校验私钥格式
    if [[ -z "$priv_key" || -z "$addr_v4" || "$addr_v4" == "/32" ]]; then
        log_err "解析 WARP 配置失败（私钥或 IPv4 地址为空）。"
        return 1
    fi
    if [[ ! "$priv_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        log_err "WARP 私钥格式异常（长度 ${#priv_key}，应为 44 字符 base64），请重试。"
        return 1
    fi
    # 校验公钥格式
    if [[ ! "$pub_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        log_err "WARP 公钥格式异常，请重试。"
        return 1
    fi

    # 解析 Reserved 字节：client_id 是 base64 编码的 3 字节
    local r1 r2 r3
    r1=0; r2=0; r3=0
    local reserved_hex
    reserved_hex=$(echo "$client_id" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n')
    # 严格验证解码结果：必须是 6 个十六进制字符（3 字节）
    if [[ ${#reserved_hex} -ne 6 || ! "$reserved_hex" =~ ^[0-9a-f]{6}$ ]]; then
        log_err "WARP 注册失败：client_id 解码异常（无法得到 3 字节 Reserved）。"
        return 1
    fi
    r1=$((16#${reserved_hex:0:2}))
    r2=$((16#${reserved_hex:2:2}))
    r3=$((16#${reserved_hex:4:2}))

    # 注意：endpoint 的 address 用 v4+v6 双地址数组（甬哥 sing-box-yg 同款，
    # 实测单 IPv4 地址时 WARP 隧道握手失败、流量超时）。
    local addrs_json
    if [[ -n "${addr_v6:-}" ]]; then
        addrs_json=$(jq -n --arg v4 "$addr_v4" --arg v6 "$addr_v6" '[$v4, $v6]')
    else
        addrs_json=$(jq -n --arg v4 "$addr_v4" '[$v4]')
    fi
    local outbound_json
    outbound_json=$(jq -n \
        --arg priv "$priv_key" \
        --arg peer "$WARP_PEER_KEY" \
        --arg server "$WARP_ENDPOINT" \
        --argjson port "$WARP_PORT" \
        --argjson addrs "$addrs_json" \
        --argjson r1 "$r1" --argjson r2 "$r2" --argjson r3 "$r3" '{
        type: "wireguard",
        tag: "warp",
        address: $addrs,
        private_key: $priv,
        peers: [
            {
                address: $server,
                port: $port,
                public_key: $peer,
                allowed_ips: ["0.0.0.0/0", "::/0"],
                reserved: [$r1, $r2, $r3]
            }
        ],
        mtu: 1280
    }')

    if apply_endpoint "add" "warp" "$outbound_json"; then
        local state_data
        state_data=$(jq -n \
            --arg priv "$priv_key" \
            --arg v4 "$addr_v4" \
            --arg v6 "${addr_v6:-}" \
            --argjson r1 "$r1" --argjson r2 "$r2" --argjson r3 "$r3" '{
            private_key: $priv,
            address_v4: $v4,
            address_v6: $v6,
            reserved: [$r1, $r2, $r3],
            domains: []
        }')
        if state_set_proto "warp" "$state_data"; then
            log_ok "WARP 出站安装成功！IPv4: ${addr_v4%%/*}"
        else
            log_err "状态写入失败，正在回滚配置..."
            if ! apply_endpoint "del" "warp" >/dev/null 2>&1; then
                log_err "回滚失败：配置中的 warp 端点未删除，请手动检查配置。"
            fi
            return 1
        fi
        log_info "下一步：在分流菜单里添加域名（如 AI 解锁预设），指定域名即走 WARP 出口。"
    fi
}

uninstall_warp() {
    if ! warp_installed; then
        log_warn "WARP 未安装。"
        return 0
    fi
    # 先清分流规则，再删端点
    if ! apply_route_rules "[]" "warp" >/dev/null 2>&1; then
        log_err "清除分流规则失败，卸载中止。"
        return 1
    fi
    if apply_endpoint "del" "warp"; then
        if state_del_proto "warp"; then
            log_ok "WARP 已卸载，分流规则已清除。"
        else
            log_err "配置已删除，但状态清理失败。配置与状态不一致，请检查。"
            return 1
        fi
    else
        log_err "删除 warp 端点失败，卸载中止。"
        return 1
    fi
}

# warp_check 第 5 层 trace 测试域名（须在分流列表中，流量才走 WARP；
# 不在时临时加入、测完恢复）。www.cloudflare.com 提供 /cdn-cgi/trace
# 端点（返回 ip= 与 warp=）。
WARP_TRACE_DOMAIN="www.cloudflare.com"

# warp_check 临时测试域名的恢复状态（RETURN trap 安全网用）。
# warp_check 第 5 层测试时，若 www.cloudflare.com 不在分流列表中，
# 会临时加入（否则 trace 流量走直连，必然误报 warp=off）；测试完成
# 后必须恢复原列表。_WARP_CHECK_TEMP_ADDED=1 表示本次检查临时添加过。
_WARP_CHECK_TEMP_ADDED=0
_WARP_CHECK_ORIG_DOMAINS=""
# warp_check 安装 INT/TERM trap 前保存的调用方旧 trap（退出第 5 层时恢复）。
_WARP_CHECK_OLD_TRAP_INT=""
_WARP_CHECK_OLD_TRAP_TERM=""

# 恢复 warp_check 临时添加的测试域名（可重复调用，无临时添加时为空操作）。
# 用作 warp_check 的 RETURN trap 安全网：即使测试中途因异常路径返回，
# 也能保证原分流列表被恢复。注意 warp_set_domains 内部会覆盖 RETURN
# trap（设为 _state_unlock），所以调用方每次调用 warp_set_domains 后
# 都必须重新安装本 trap。
#
# 顺序关键（2026-11-15 真机教训）：必须先调用 warp_set_domains 恢复，
# 成功后再清除标志与 trap。旧代码先清标志/trap 再恢复，恢复期间用户
# 按 Ctrl+C 时安全网已撤，临时域名永久残留（分流 28 个变 29 个）。
# 返回：0=恢复成功或无须恢复，1=恢复失败（标志保留，调用方返回时
# RETURN trap 再试一次；state 中的 temp_trace_added 标记保留，下次
# warp_check 入口清理会再次尝试）。
_warp_check_restore_temp_domains() {
    if [[ "${_WARP_CHECK_TEMP_ADDED:-0}" != "1" || -z "${_WARP_CHECK_ORIG_DOMAINS:-}" ]]; then
        _WARP_CHECK_ORIG_DOMAINS=""
        return 0
    fi
    local orig="$_WARP_CHECK_ORIG_DOMAINS"
    if ! warp_set_domains "$orig" >/dev/null 2>&1; then
        log_err "恢复原分流列表失败，测试域名 ${WARP_TRACE_DOMAIN} 可能仍在列表中，请进分流菜单手动移除。"
        return 1
    fi
    # 恢复验证：确认 state 中的分流列表确实回到原值（防并发改写/静默失败）
    if ! jq -e --argjson orig "$orig" '.protocols.warp.domains == $orig' "$SB_STATE" >/dev/null 2>&1; then
        local orig_count cur_count
        orig_count=$(echo "$orig" | jq 'length' 2>/dev/null || echo "?")
        cur_count=$(jq -r '.protocols.warp.domains | length' "$SB_STATE" 2>/dev/null || echo "?")
        log_err "恢复验证失败：原分流 ${orig_count} 个域名，当前 ${cur_count} 个，测试域名 ${WARP_TRACE_DOMAIN} 可能仍在列表中，请进分流菜单手动移除。"
        return 1
    fi
    # 恢复成功后才清除 state 标记、内存标志与 trap
    state_set_field "warp" "temp_trace_added" "" 2>/dev/null || true
    _WARP_CHECK_TEMP_ADDED=0
    _WARP_CHECK_ORIG_DOMAINS=""
    trap - RETURN
    return 0
}

# warp_check 第 5 层期间的中断处理（INT/TERM trap）。
# Ctrl+C/终止信号时尽力恢复临时测试域名，再按惯例以 130 退出。
# 恢复走 warp_set_domains（含 15 秒超时保护的服务重载），有界不会无限
# 等待；若恢复仍失败，state 中的 temp_trace_added 标记保留，下次
# warp_check 入口清理会再次尝试。处理函数开头先重置信号 trap，第二
# 次 Ctrl+C 立即退出（用户明确要走时不拖延）。
_warp_check_on_interrupt() {
    trap - INT TERM
    _warp_check_restore_temp_domains
    exit 130
}

# 移除 warp_check 第 5 层安装的 INT/TERM trap，恢复调用方旧 trap。
# warp_check 退出第 5 层的所有正常路径都必须调用（否则 trap 残留进菜单循环）。
_warp_check_remove_interrupt_trap() {
    trap - INT TERM 2>/dev/null || true
    [[ -n "${_WARP_CHECK_OLD_TRAP_INT:-}" ]] && eval "$_WARP_CHECK_OLD_TRAP_INT" 2>/dev/null || true
    [[ -n "${_WARP_CHECK_OLD_TRAP_TERM:-}" ]] && eval "$_WARP_CHECK_OLD_TRAP_TERM" 2>/dev/null || true
    _WARP_CHECK_OLD_TRAP_INT=""
    _WARP_CHECK_OLD_TRAP_TERM=""
}

# 清理上次 warp_check 异常退出残留的临时测试域名（幂等入口清理）。
# 判据是 state 中的 temp_trace_added 标记（临时添加前设置、恢复成功后
# 清除），而非域名本身在不在列表中——用户手动添加的 www.cloudflare.com
# 无标记，不会被误删。返回 0=无残留或清理成功，1=清理失败（标记保留，
# 下次检查再试；本次检查仍可继续，因测试域名已在列表中）。
_warp_check_cleanup_stale_trace_domain() {
    local marker
    marker=$(state_get_field "warp" "temp_trace_added" 2>/dev/null || echo "")
    [[ "$marker" == "1" ]] || return 0
    local cur_domains cleaned_domains
    cur_domains=$(jq -c '.protocols.warp.domains // []' "$SB_STATE" 2>/dev/null || echo "[]")
    if ! echo "$cur_domains" | jq -e --arg d "$WARP_TRACE_DOMAIN" 'any(. == $d)' >/dev/null 2>&1; then
        # 标记残留但域名已不在列表（上次恢复成功、清标记时被中断）：只清标记
        state_set_field "warp" "temp_trace_added" "" 2>/dev/null || true
        return 0
    fi
    echo "        · 发现上次检查残留的测试域名 ${WARP_TRACE_DOMAIN}，正在清理..."
    cleaned_domains=$(echo "$cur_domains" | jq -c --arg d "$WARP_TRACE_DOMAIN" 'map(select(. != $d))')
    if ! warp_set_domains "$cleaned_domains" >/dev/null 2>&1; then
        log_err "清理残留测试域名失败，${WARP_TRACE_DOMAIN} 仍在分流列表中，请手动移除。"
        return 1
    fi
    state_set_field "warp" "temp_trace_added" "" 2>/dev/null || true
    echo "        ✓ 残留测试域名已清理"
    return 0
}

# 把 Unix 时间戳转成友好的中文相对时间（如“刚刚”“3 分钟前”“2 小时前”“1 天前”）。
# 参数：$1=Unix 时间戳；输出：相对时间字符串；时间戳无效或未来时返回“刚刚”。
_warp_format_ago() {
    local ts="$1" now diff
    [[ "$ts" =~ ^[0-9]+$ ]] || { echo "刚刚"; return 0; }
    now=$(date +%s)
    diff=$(( now - ts ))
    (( diff < 0 )) && diff=0
    if (( diff < 60 )); then
        echo "刚刚"
    elif (( diff < 3600 )); then
        echo "$(( diff / 60 )) 分钟前"
    elif (( diff < 86400 )); then
        echo "$(( diff / 3600 )) 小时前"
    else
        echo "$(( diff / 86400 )) 天前"
    fi
}

# 保存 WARP 出口验证结果到 state（供菜单渲染读取）。
# 参数：$1=出口 IP。verified_at 为当前 Unix 时间戳。
_warp_save_verification() {
    local ip="$1"
    state_set_field "warp" "verified_at" "$(date +%s)" 2>/dev/null || true
    state_set_field "warp" "verified_ip" "$ip" 2>/dev/null || true
}

# 清除 WARP 出口验证结果（隧道不通/配置缺失/服务停运时调用，
# 避免菜单显示过期的“已验证”状态误导用户）。
_warp_clear_verification() {
    state_set_field "warp" "verified_at" "" 2>/dev/null || true
    state_set_field "warp" "verified_ip" "" 2>/dev/null || true
}

# 检查 WARP 出口是否可用（分层检查）
# 返回码：0=完全正常，1=未安装或配置缺失，2=服务异常，3=隧道不通，4=无法验证（UNKNOWN）
warp_check() {
    if ! warp_installed; then
        log_warn "WARP 未安装。"
        _warp_clear_verification
        return 1
    fi

    local failures=0

    # 第 1 层：配置存在性检查
    echo "  [1/5] 配置存在性 ..."
    if jq -e '.endpoints[] | select(.tag == "warp")' "$SB_CONFIG" >/dev/null 2>&1; then
        echo "        ✓ WARP 端点已在配置中"
    else
        echo "        ✗ 配置中找不到 warp 端点（可能被外部修改）"
        _warp_clear_verification
        return 1
    fi

    # 第 2 层：配置结构合法性检查
    echo "  [2/5] 配置结构 ..."
    local priv_key addr_v4 reserved
    priv_key=$(jq -r '.endpoints[] | select(.tag == "warp") | .private_key // empty' "$SB_CONFIG" 2>/dev/null)
    addr_v4=$(jq -r '.endpoints[] | select(.tag == "warp") | .address[0] // .address // empty' "$SB_CONFIG" 2>/dev/null)
    reserved=$(jq -c '.endpoints[] | select(.tag == "warp") | .peers[0].reserved // empty' "$SB_CONFIG" 2>/dev/null)
    if [[ "$priv_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] && [[ -n "$addr_v4" ]] && [[ "$reserved" != "[0,0,0]" ]]; then
        echo "        ✓ 私钥格式正常，地址 $addr_v4，Reserved $reserved"
    else
        echo "        ✗ 配置结构异常（私钥/地址/Reserved 有问题）"
        [[ "$reserved" == "[0,0,0]" ]] && echo "          提示：Reserved 为 [0,0,0] 说明注册时 client_id 解析失败，请重装 WARP"
        ((failures++))
    fi

    # 第 3 层：服务运行检查
    echo "  [3/5] 服务运行 ..."
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        echo "        ✓ sing-box 服务运行中"
    else
        echo "        ✗ sing-box 服务未运行"
        _warp_clear_verification
        return 2
    fi

    # 第 4 层：分流规则检查
    echo "  [4/5] 分流规则 ..."
    local rule_count
    rule_count=$(jq '[.route.rules[]? | select(.outbound == "warp")] | length' "$SB_CONFIG" 2>/dev/null || echo 0)
    if [[ "$rule_count" -gt 0 ]]; then
        echo "        ✓ 找到 $rule_count 条 WARP 分流规则"
    else
        echo "        ⚠ 无 WARP 分流规则（WARP 已安装但未配置分流域名）"
    fi

    # 第 5 层：实际流量测试（需要 SOCKS5 入站和分流域名）
    echo "  [5/5] 实际流量测试 ..."
    # 以下进入第 5 层域名变更窗口（入口清理、临时添加、测试、恢复），
    # 全程安装 INT/TERM trap：用户按 Ctrl+C 时先恢复临时域名再退出，
    # 不留残留。退出本窗口的所有正常路径都必须调用
    # _warp_check_remove_interrupt_trap 恢复调用方旧 trap。
    _WARP_CHECK_OLD_TRAP_INT="$(trap -p INT 2>/dev/null || true)"
    _WARP_CHECK_OLD_TRAP_TERM="$(trap -p TERM 2>/dev/null || true)"
    trap '_warp_check_on_interrupt' INT TERM

    # 幂等入口清理：上次检查异常退出可能残留临时测试域名（state 标记
    # temp_trace_added=1），先清理再开始本次测试。放在 SOCKS5 检查之
    # 前：清理只依赖 warp_set_domains，不依赖 SOCKS5，未装 SOCKS5 时
    # 也能把残留清掉。
    _warp_check_cleanup_stale_trace_domain || true

    local socks_port socks_user socks_pass
    socks_port=$(state_get_field "socks5" "port" 2>/dev/null)
    if [[ -z "$socks_port" ]]; then
        echo "        ? 未安装 SOCKS5，无法验证实际流量"
        echo "          提示：安装 SOCKS5 后可验证实际出口 IP"
        _warp_check_remove_interrupt_trap
        if [[ $failures -eq 0 ]]; then
            echo ""
            log_warn "WARP 配置正常，但实际流量未验证（UNKNOWN）。"
            return 4
        else
            _warp_clear_verification
            return 3
        fi
    fi

    # 分流列表必须非空，否则无从验证实际流量
    local cur_domains_json domain_count
    cur_domains_json=$(jq -c '.protocols.warp.domains // []' "$SB_STATE" 2>/dev/null || echo "[]")
    domain_count=$(echo "$cur_domains_json" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$domain_count" -eq 0 ]]; then
        echo "        ? 分流列表为空，无法验证实际流量"
        _warp_check_remove_interrupt_trap
        if [[ $failures -eq 0 ]]; then
            echo ""
            log_warn "WARP 配置正常，但无分流域名可测试（UNKNOWN）。"
            return 4
        else
            _warp_clear_verification
            return 3
        fi
    fi

    socks_user=$(state_get_field "socks5" "username" 2>/dev/null)
    socks_pass=$(state_get_field "socks5" "password" 2>/dev/null)

    # trace 测试域名必须是分流列表中的域名，否则流量走直连，
    # trace 必然返回原生 IP + warp=off，造成"隧道不通"误报
    # （2026-11-15 真机教训：www.cloudflare.com 不在 28 个 AI 域名中）。
    # www.cloudflare.com 提供 /cdn-cgi/trace 端点（返回 ip= 与 warp=），
    # 若不在分流列表中则临时加入，测试后恢复原列表。
    local trace_domain="$WARP_TRACE_DOMAIN"
    local temp_added=0 has_trace_domain
    has_trace_domain=$(echo "$cur_domains_json" | jq --arg d "$trace_domain" 'any(. == $d)' 2>/dev/null || echo false)
    if [[ "$has_trace_domain" != "true" ]]; then
        _WARP_CHECK_ORIG_DOMAINS="$cur_domains_json"
        _WARP_CHECK_TEMP_ADDED=1
        trap '_warp_check_restore_temp_domains' RETURN
        # 先在 state 中记下临时添加标记（恢复成功后清除）：若本次检查
        # 被中断/恢复失败，下次 warp_check 入口清理可据此识别残留。
        state_set_field "warp" "temp_trace_added" "1" 2>/dev/null || true
        # state_set_field 内部覆盖了 RETURN trap，重新安装恢复 trap
        trap '_warp_check_restore_temp_domains' RETURN
        local tmp_domains_json
        tmp_domains_json=$(echo "$cur_domains_json" | jq -c --arg d "$trace_domain" '. + [$d] | unique | sort')
        if warp_set_domains "$tmp_domains_json" >/dev/null 2>&1; then
            temp_added=1
            # warp_set_domains 内部覆盖了 RETURN trap，重新安装恢复 trap
            trap '_warp_check_restore_temp_domains' RETURN
            echo "        · 测试域名 ${trace_domain} 已临时加入分流（测试后自动移除）"
        else
            trap - RETURN
            _WARP_CHECK_TEMP_ADDED=0
            _WARP_CHECK_ORIG_DOMAINS=""
            state_set_field "warp" "temp_trace_added" "" 2>/dev/null || true
            _warp_check_remove_interrupt_trap
            echo "        ✗ 无法临时添加测试域名，流量测试中止"
            _warp_clear_verification
            return 3
        fi
    fi

    # 通过 Cloudflare trace 服务验证出口 IP（该域名走 WARP 时返回 Cloudflare IP 与 warp=on）
    local trace_result test_ip warp_status rc=3
    trace_result=$(timeout 10 curl -s -x "socks5://${socks_user}:${socks_pass}@127.0.0.1:${socks_port}" "https://${trace_domain}/cdn-cgi/trace" 2>/dev/null)
    test_ip=$(echo "$trace_result" | grep -m1 '^ip=' | cut -d'=' -f2)
    if [[ -z "$test_ip" ]]; then
        echo "        ✗ 流量测试超时或失败（隧道可能不通）"
        rc=3
    else
        # 检查 warp 状态（trace 返回 warp=on 说明经过 WARP）
        warp_status=$(echo "$trace_result" | grep -m1 '^warp=' | cut -d'=' -f2)
        if [[ "$warp_status" == "on" ]]; then
            echo "        ✓ 出口 IP $test_ip，WARP 状态：on"
            echo ""
            log_ok "WARP 隧道连接正常，流量已走 Cloudflare 出口。"
            rc=0
        elif [[ "$test_ip" =~ ^104\. || "$test_ip" =~ ^172\.67\. || "$test_ip" =~ ^2a09: ]]; then
            echo "        ✓ 出口 IP $test_ip（Cloudflare 段）"
            echo ""
            log_ok "WARP 隧道连接正常，流量已走 Cloudflare 出口。"
            rc=0
        else
            echo "        ✗ 出口 IP $test_ip 不是 Cloudflare，WARP 状态：${warp_status:-未知}"
            echo "          可能原因：分流未生效，或隧道不通"
            rc=3
        fi
    fi

    # 恢复原分流列表（显式恢复；先恢复、成功后再清标志，见
    # _warp_check_restore_temp_domains）。失败时保持标志，函数返回前
    # 重新安装 RETURN trap，安全网再试一次；state 中的
    # temp_trace_added 标记保留，下次检查入口清理还会再试。
    local restore_failed=0
    if (( temp_added )); then
        if ! _warp_check_restore_temp_domains; then
            restore_failed=1
        fi
    fi
    _warp_check_remove_interrupt_trap
    # 持久化验证结果供菜单渲染读取：成功时保存时间戳与出口 IP，
    # 失败时清除旧验证状态（避免菜单显示过期的“已验证”）。
    if (( rc == 0 )); then
        _warp_save_verification "$test_ip"
    else
        _warp_clear_verification
    fi
    # 恢复失败时重新安装 RETURN trap（验证持久化会覆盖它，故放在最后），
    # 函数返回时安全网再试一次。
    if (( restore_failed )); then
        trap '_warp_check_restore_temp_domains' RETURN
    fi
    return $rc
}

# --- 分流域名管理 ---

warp_get_domains() {
    init_state_file || return 1
    jq -r '.protocols.warp.domains[]? // empty' "$SB_STATE" 2>/dev/null || true
}

warp_set_domains() {
    # 参数：域名数组 JSON（如 ["a.com","b.com"]）
    local domains_json="$1"
    init_state_file || return 1
    _state_lock || return 1
    trap '_state_unlock' RETURN
    # 备份原状态，路由规则修改失败时恢复
    local bak_state
    bak_state=$(mktemp "${SB_STATE}.bak.XXXXXX") || return 1
    cp -f "$SB_STATE" "$bak_state" || { rm -f "$bak_state"; return 1; }
    chmod 600 "$bak_state"
    local tmp
    tmp=$(mktemp "${SB_STATE}.XXXXXX") || { rm -f "$bak_state"; return 1; }
    if ! jq --argjson d "$domains_json" '.protocols.warp.domains = $d' "$SB_STATE" > "$tmp"; then
        rm -f "$tmp" "$bak_state"
        return 1
    fi
    chmod 600 "$tmp" && mv -f "$tmp" "$SB_STATE" || { rm -f "$tmp" "$bak_state"; return 1; }
    # 同步到 sing-box 路由规则，失败时恢复原状态
    if ! apply_route_rules "$domains_json" "warp"; then
        log_err "路由规则更新失败，正在恢复原状态..."
        cp -f "$bak_state" "$SB_STATE" 2>/dev/null || log_err "状态恢复失败，请手动检查。"
        rm -f "$bak_state"
        return 1
    fi
    rm -f "$bak_state"
    return 0
}

warp_add_domains() {
    # 参数：空格分隔的域名列表
    local new_domains=("$@")
    local valid=() d
    for d in "${new_domains[@]}"; do
        d="${d,,}"; d="${d#.}"
        if valid_domain_name "$d"; then
            valid+=("$d")
        else
            log_warn "跳过无效域名: $d"
        fi
    done
    if [[ ${#valid[@]} -eq 0 ]]; then
        log_warn "没有有效的域名可添加。"
        return 1
    fi
    local cur_json new_json
    cur_json=$(jq -c '.protocols.warp.domains // []' "$SB_STATE" 2>/dev/null || echo "[]")
    new_json=$(printf '%s\n' "${valid[@]}" | jq -R . | jq -s --argjson cur "$cur_json" '($cur + .) | unique | sort')
    if warp_set_domains "$new_json"; then
        log_ok "已添加 ${#valid[@]} 个域名到分流（去重后共 $(echo "$new_json" | jq 'length') 个）。"
    fi
}

warp_remove_domains() {
    # 参数：空格分隔的域名列表
    local rm_domains=("$@")
    local cur_json new_json
    cur_json=$(jq -c '.protocols.warp.domains // []' "$SB_STATE" 2>/dev/null || echo "[]")
    new_json=$(printf '%s\n' "${rm_domains[@]}" | jq -R . | jq -s --argjson cur "$cur_json" '($cur - .) | unique | sort')
    if warp_set_domains "$new_json"; then
        log_ok "已移除指定域名，剩余 $(echo "$new_json" | jq 'length') 个。"
    fi
}

warp_clear_domains() {
    if warp_set_domains "[]"; then
        log_ok "分流域名已全部清空（WARP 出站保留，规则移除）。"
    fi
}

warp_apply_ai_preset() {
    if ! warp_installed; then
        log_warn "请先安装 WARP。"
        return 1
    fi
    local choice
    # 非交互环境（SBX_AUTO 或 stdin 非 TTY）默认使用精简模式
    if [[ -n "${SBX_AUTO:-}" || ! -t 0 ]]; then
        choice="1"
    else
        echo ""
        echo "  请选择 AI 分流模式："
        echo "    1) 精简模式（推荐）：只分流 AI 专用域名，普通 Google 服务不受影响"
        echo "       包含：gemini.google.com、openai.com、claude.ai 等 28 个 AI 域名"
        echo "    2) 兼容模式：精简模式 + google.com/googleapis.com/accounts.google.com"
        echo "       包含：33 个域名（解决某些 AI 服务需要完整 Google 生态的问题）"
        echo "    3) 取消"
        echo ""
        read -rp "  请选择 [1/2/3，默认 1]: " choice
        choice="${choice:-1}"
    fi
    case "$choice" in
        1)
            log_info "正在应用精简模式（28 个 AI 域名）..."
            # shellcheck disable=SC2086
            warp_add_domains $WARP_AI_DOMAINS_MINIMAL
            ;;
        2)
            log_info "正在应用兼容模式（33 个域名，含 Google 通用域名）..."
            # shellcheck disable=SC2086
            warp_add_domains $WARP_AI_DOMAINS_COMPAT
            ;;
        *)
            log_info "已取消。"
            return 0
            ;;
    esac
}

# 预览 AI 预设域名（不实际应用）
warp_preview_ai_preset() {
    echo ""
    echo "  精简模式域名（28 个）："
    echo "$WARP_AI_DOMAINS_MINIMAL" | tr ' ' '\n' | sed 's/^/    · /'
    echo ""
    echo "  兼容模式额外域名（5 个）："
    echo "    · google.com"
    echo "    · googleapis.com"
    echo "    · accounts.google.com"
    echo "    · bing.com"
    echo "    · meta.com"
}

warp_show_domains() {
    local domains
    domains=$(warp_get_domains)
    if [[ -z "$domains" ]]; then
        echo "  （当前无分流域名）"
        return
    fi
    local count
    count=$(echo "$domains" | wc -l)
    echo "  当前分流域名（${count} 个，走 WARP 出口）："
    echo "$domains" | while read -r d; do
        [[ -n "$d" ]] && echo "    · $d"
    done
}

# ---------- WARP 菜单状态探针（只读，不做网络请求、不写状态） ----------
# 结果写入 WARP_M_* 全局变量，供 menu_warp 展示用。
# 注意：出口验证（warp_check 第 5 层）需要实时流量测试，耗时且依赖
# SOCKS5/分流域名，不在菜单渲染时执行；菜单显示上次 [1/c] 检测的
# 持久化结果（verified_at/verified_ip，见 warp_check 末尾），无结果
# 时显示“未验证”，SOCKS5 未装或分流为空时显示“无法验证（原因）”。
# “服务运行中”不等于“WARP 出口正常”，两者必须分开展示。
WARP_M_INSTALLED=0
WARP_M_V4=""
WARP_M_ENDPOINT="missing"
WARP_M_SERVICE="stopped"
WARP_M_RULES=0
WARP_M_DOMAINS=0
WARP_M_MODE="none"
WARP_M_PRESET_N=0
WARP_M_PREVIEW="无分流域名"
WARP_M_VERIFIED_AT=""
WARP_M_VERIFIED_IP=""

_warp_menu_status() {
    WARP_M_INSTALLED=0; WARP_M_V4=""; WARP_M_ENDPOINT="missing"
    WARP_M_SERVICE="stopped"; WARP_M_RULES=0; WARP_M_DOMAINS=0
    WARP_M_MODE="none"; WARP_M_PRESET_N=0; WARP_M_PREVIEW="无分流域名"
    WARP_M_VERIFIED_AT=""; WARP_M_VERIFIED_IP=""
    warp_installed || return 0
    WARP_M_INSTALLED=1
    local v4 domains preview cur_sorted min_sorted compat_sorted
    v4=$(state_get_field "warp" "address_v4")
    WARP_M_V4="${v4%%/*}"
    # 上次出口验证结果（warp_check 成功时写入，失败时清除）
    WARP_M_VERIFIED_AT=$(state_get_field "warp" "verified_at" 2>/dev/null || true)
    WARP_M_VERIFIED_IP=$(state_get_field "warp" "verified_ip" 2>/dev/null || true)
    # 第 1 层（与 warp_check 同口径）：配置中存在 warp 端点
    if jq -e '.endpoints[] | select(.tag == "warp")' "$SB_CONFIG" >/dev/null 2>&1; then
        WARP_M_ENDPOINT="ok"
    fi
    # 第 3 层：sing-box 服务运行状态（仅代表服务本身，不代表出口正常）
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        WARP_M_SERVICE="running"
    fi
    # 第 4 层：配置中的 WARP 分流规则条数
    WARP_M_RULES=$(jq '[.route.rules[]? | select(.outbound == "warp")] | length' "$SB_CONFIG" 2>/dev/null || echo 0)
    domains=$(warp_get_domains)
    [[ -n "$domains" ]] || return 0
    WARP_M_DOMAINS=$(printf '%s\n' "$domains" | grep -c . || true)
    preview=$(printf '%s\n' "$domains" | head -n 3 | paste -sd',' - | sed 's/,/, /g')
    if (( WARP_M_DOMAINS > 3 )); then
        WARP_M_PREVIEW="${WARP_M_DOMAINS} 个：${preview}${UI_ELL:-…}"
    else
        WARP_M_PREVIEW="${WARP_M_DOMAINS} 个：${preview}"
    fi
    # 分流模式：当前域名集合与两档预设集合逐项比对
    cur_sorted=$(printf '%s\n' "$domains" | sort)
    # shellcheck disable=SC2086
    min_sorted=$(printf '%s\n' $WARP_AI_DOMAINS_MINIMAL | sort)
    # shellcheck disable=SC2086
    compat_sorted=$(printf '%s\n' $WARP_AI_DOMAINS_COMPAT | sort)
    if [[ "$cur_sorted" == "$min_sorted" ]]; then
        WARP_M_MODE="minimal"
    elif [[ "$cur_sorted" == "$compat_sorted" ]]; then
        WARP_M_MODE="compat"
    else
        WARP_M_MODE="custom"
    fi
    # AI 预设覆盖数：精简预设 28 个域名中有几个已在分流列表中
    # shellcheck disable=SC2086
    WARP_M_PRESET_N=$(comm -12 <(printf '%s\n' "$domains" | sort) <(printf '%s\n' $WARP_AI_DOMAINS_MINIMAL | sort) | grep -c . || true)
}

menu_warp() {
    local c svc_txt ep_txt verify_txt mode_txt preset_txt
    while true; do
        _warp_menu_status
        ui_menu_head "WARP 与域名分流" "WARP"
        if (( WARP_M_INSTALLED )); then
            if [[ "$WARP_M_SERVICE" == "running" ]]; then
                svc_txt="$(ui_status_pill running "运行中")"
            else
                svc_txt="$(ui_status_pill stopped "未运行")"
            fi
            if [[ "$WARP_M_ENDPOINT" == "ok" ]]; then
                ep_txt="$(ui_status_pill ok "已配置")"
            else
                ep_txt="$(ui_status_pill error "配置缺失")"
            fi
            ui_kv "WARP 状态" "$(ui_status_pill ok "已安装 · ${WARP_M_V4}")" "$WHITE"
            ui_kv "WARP 出站" "$ep_txt" "$WHITE"
            ui_kv "sing-box" "$svc_txt" "$WHITE"
            ui_kv "分流规则" "${WARP_M_RULES} 条" "$WHITE"
            # 出口验证：菜单渲染不做实时流量测试，显示上次 [1/c] 检测的
            # 持久化结果；SOCKS5 未装或分流为空时无法验证（优先于旧结果，
            # 因为此时的“无法验证”结论比过期的验证结果更准确）
            if ! state_has_proto "socks5"; then
                verify_txt="$(ui_status_pill warn "无法验证") 未安装 SOCKS5，无法探测出口"
            elif (( WARP_M_DOMAINS == 0 )); then
                verify_txt="$(ui_status_pill warn "无法验证") 分流列表为空，无域名可测试"
            elif [[ -n "$WARP_M_VERIFIED_AT" && -n "$WARP_M_VERIFIED_IP" ]]; then
                verify_txt="$(ui_status_pill ok "已验证") ${WARP_M_VERIFIED_IP}（$(_warp_format_ago "$WARP_M_VERIFIED_AT")）"
            else
                verify_txt="$(ui_status_pill warn "未验证") 选 [1/c] 检测实时出口"
            fi
            ui_kv "出口验证" "$verify_txt" "$WHITE"
            case "$WARP_M_MODE" in
                minimal) mode_txt="精简模式（28 个 AI 域名）" ;;
                compat) mode_txt="兼容模式（33 个域名）" ;;
                custom) mode_txt="自定义" ;;
                *) mode_txt="未配置" ;;
            esac
            if (( WARP_M_PRESET_N >= 28 )); then
                preset_txt="已应用（28/28）"
            elif (( WARP_M_PRESET_N > 0 )); then
                preset_txt="部分应用（${WARP_M_PRESET_N}/28）"
            else
                preset_txt="未应用"
            fi
            ui_kv "分流模式" "$mode_txt" "$WHITE"
            ui_kv "AI 预设" "$preset_txt" "$WHITE"
            ui_kv "分流域名" "$WARP_M_PREVIEW" "$WHITE"
            ui_line "${GRAY}服务运行中不等于出口正常，出口状态以 [1/c] 实时检测为准${PLAIN}"
        else
            ui_kv "WARP 状态" "$(ui_status_pill stopped "未安装")" "$WHITE"
            ui_kv "分流域名" "需先安装 WARP" "$GRAY"
            ui_line "${GRAY}WARP 可为指定域名提供 Cloudflare 出口，绕过原生 IP 封锁${PLAIN}"
        fi
        ui_bot
        if (( WARP_M_INSTALLED )); then
            ui_menu_select "请选择" 0 \
                "1/c|检测 WARP 出口|确认出站配置有效" \
                "2/a|AI 解锁分流|精简/兼容两模式可选（Gemini/ChatGPT 等）" \
                "3/n|添加分流域名|空格分隔，支持子域名后缀匹配" \
                "4/r|删除分流域名|空格分隔，移除指定域名" \
                "5/l|查看分流列表|显示当前所有分流域名" \
                "6/d|清空分流规则|保留 WARP，仅移除分流" \
                "7/x|卸载 WARP|移除出站与全部规则" \
                "0/q|返回主菜单|" || return 0
        else
            ui_menu_select "请选择" 0 \
                "1/i|安装 WARP|注册 Cloudflare WARP 账号" \
                "0/q|返回主菜单|" || return 0
        fi
        c="$UI_SEL_KEY"
        case "$c" in
            1/c|1/i)
                if warp_installed; then warp_check; else install_warp; fi
                ;;
            2/a) warp_apply_ai_preset ;;
            3/n)
                # 输入组件只换读取方式；域名校验仍在 warp_add_domains
                ui_read_text "请输入域名（空格分隔，如 openai.com claude.ai）" || true
                if [[ -n "$UI_INPUT" ]]; then
                    # shellcheck disable=SC2086
                    warp_add_domains $UI_INPUT
                fi
                ;;
            4/r)
                ui_read_text "请输入要删除的域名（空格分隔）" || true
                if [[ -n "$UI_INPUT" ]]; then
                    # shellcheck disable=SC2086
                    warp_remove_domains $UI_INPUT
                fi
                ;;
            5/l) warp_show_domains ;;
            6/d)
                if ui_confirm "确定清空全部 WARP 分流规则？"; then
                    warp_clear_domains
                fi
                ;;
            7/x)
                if ui_dialog_confirm "确定卸载 WARP？将删除 WARP 配置与全部 WARP 分流规则。"; then
                    uninstall_warp
                fi
                ;;
            0/q) return ;;
            *) log_warn "无效选项"; sleep 1; continue ;;
        esac
        pause
    done
}
