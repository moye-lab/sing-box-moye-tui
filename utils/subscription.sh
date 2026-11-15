#!/usr/bin/env bash
SUB_UNIT="/etc/systemd/system/sbx-subscription.service"
SUB_ENV="${SB_ETC}/subscription.env"
SUB_SERVER="${APP_HOME}/utils/subscription_server.py"

subscription_display_host() {
    local bind_addr="$1" host
    case "$bind_addr" in
        0.0.0.0|::) host=$(get_public_ip) ;;
        *) host="$bind_addr" ;;
    esac
    [[ "$host" == *:* ]] && host="[${host}]"
    printf '%s\n' "$host"
}

subscription_enable() {
    command -v python3 >/dev/null 2>&1 || { log_err "需要 Python 3"; return 1; }
    mkdir -p "$SB_ETC" "$SB_EXPORT_DIR"
    export_all_nodes >/dev/null || return 1
    local token="" port="" bind_addr="" ip
    if [[ -f "$SUB_ENV" ]]; then
        token=$(sed -n 's/^SUB_TOKEN=//p' "$SUB_ENV" | head -n1)
        port=$(sed -n 's/^SUB_PORT=//p' "$SUB_ENV" | head -n1)
        bind_addr=$(sed -n 's/^SUB_BIND=//p' "$SUB_ENV" | head -n1)
    fi
    token="${token:-$(openssl rand -hex 32)}"
    # 输入组件只换读取方式：默认值、空输入回落、EOF 回落与后续校验一律不变。
    # 防呆文案保留：默认 127.0.0.1 仅本机可访问，公网访问须显式填 0.0.0.0。
    ui_read_text "订阅服务监听地址（公网访问请显式填写 0.0.0.0）" "${bind_addr:-127.0.0.1}" || true
    bind_addr="${UI_INPUT:-${bind_addr:-127.0.0.1}}"
    ui_read_text "订阅服务端口" "${port:-8765}" || true
    port="${UI_INPUT:-${port:-8765}}"
    [[ "$port" =~ ^[0-9]+$ ]] && ((port>0 && port<65536)) || { log_err "端口无效"; return 1; }
    python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$bind_addr" >/dev/null 2>&1 || {
        log_err "监听地址必须是有效的 IPv4 或 IPv6 地址"; return 1;
    }
    printf 'SUB_TOKEN=%s\nSUB_PORT=%s\nSUB_BIND=%s\n' "$token" "$port" "$bind_addr" > "$SUB_ENV"
    chmod 600 "$SUB_ENV"
    cat > "$SUB_UNIT" <<EOF
[Unit]
Description=sbx authenticated subscription server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
UMask=0077
EnvironmentFile=${SUB_ENV}
ExecStart=/usr/bin/python3 ${SUB_SERVER}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6
CapabilityBoundingSet=
AmbientCapabilities=
ReadOnlyPaths=${SUB_SERVER}
ReadOnlyPaths=${SB_EXPORT_DIR}/links.txt

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sbx-subscription.service || return 1
    systemctl restart sbx-subscription.service || return 1
    ip=$(subscription_display_host "$bind_addr")
    log_ok "订阅服务已启动：${bind_addr}:${port}"
    if [[ "$bind_addr" == "127.0.0.1" || "$bind_addr" == "::1" ]]; then
        echo "  本机订阅地址: http://${ip}:${port}/sub/${token}"
        echo "  注意：127.0.0.1 只能在 VPS 本机打开，手机/电脑填这个地址连不上。"
        echo "  手机要用 → 重新启用，监听地址填 0.0.0.0（将显示公网地址）；或用 HTTPS 反向代理转发。"
    elif [[ "$ip" == "127.0.0.1" ]]; then
        echo "  订阅地址: http://<服务器公网IP>:${port}/sub/${token}"
    else
        echo "  订阅地址: http://${ip}:${port}/sub/${token}"
    fi
    log_warn "令牌等同密码；HTTP 会明文传输。生产环境请使用 HTTPS 反向代理并限制来源 IP。"
}
subscription_disable() {
    systemctl disable --now sbx-subscription.service 2>/dev/null || true
    rm -f "$SUB_UNIT" "$SUB_ENV"
    systemctl daemon-reload
    log_ok "订阅服务已停止，访问令牌已删除"
}
subscription_status() {
    if [[ -f "$SUB_ENV" ]]; then
        local token port bind_addr ip
        token=$(sed -n 's/^SUB_TOKEN=//p' "$SUB_ENV" | head -n1)
        port=$(sed -n 's/^SUB_PORT=//p' "$SUB_ENV" | head -n1)
        bind_addr=$(sed -n 's/^SUB_BIND=//p' "$SUB_ENV" | head -n1)
        ip=$(subscription_display_host "$bind_addr")
        if [[ "$bind_addr" == "127.0.0.1" || "$bind_addr" == "::1" ]]; then
            echo "本机订阅地址: http://${ip}:${port}/sub/${token}"
            echo "注意：127.0.0.1 只能在 VPS 本机打开；手机/电脑要用请重新启用，监听地址填 0.0.0.0"
        elif [[ "$ip" == "127.0.0.1" ]]; then
            echo "订阅地址: http://<服务器公网IP>:${port}/sub/${token}"
        else
            echo "订阅地址: http://${ip}:${port}/sub/${token}"
        fi
        systemctl is-active sbx-subscription.service || true
    else
        echo "订阅服务未配置"
    fi
}
menu_subscription_service() {
    # 只读状态摘要：令牌只展示“已配置/未配置”，不打印令牌本身；
    # 完整订阅地址（含令牌）仍只在选项 2 subscription_status 里展示。
    local sub_state sub_bind sub_port sub_token
    sub_state="未配置"; sub_bind="—"; sub_port="—"; sub_token="未配置"
    if [[ -f "$SUB_ENV" ]]; then
        sub_token=$(sed -n 's/^SUB_TOKEN=//p' "$SUB_ENV" | head -n1)
        sub_port=$(sed -n 's/^SUB_PORT=//p' "$SUB_ENV" | head -n1)
        sub_bind=$(sed -n 's/^SUB_BIND=//p' "$SUB_ENV" | head -n1)
        [[ -n "$sub_bind" ]] || sub_bind="127.0.0.1"
        [[ -n "$sub_port" ]] || sub_port="8765"
        if systemctl is-active --quiet sbx-subscription.service 2>/dev/null; then
            sub_state="运行中"
        else
            sub_state="已停止"
        fi
        if [[ -n "$sub_token" ]]; then sub_token="已配置"; else sub_token="未配置"; fi
    fi
    ui_menu_head "在线订阅服务" "SUBSCRIPTION"
    case "$sub_state" in
        运行中) ui_kv "服务状态" "$(ui_status_pill running "运行中")" "$WHITE" ;;
        已停止) ui_kv "服务状态" "$(ui_status_pill stopped "已停止")" "$WHITE" ;;
        *) ui_kv "服务状态" "$(ui_status_pill stopped "未配置")" "$WHITE" ;;
    esac
    ui_kv "监听地址" "$sub_bind" "$WHITE"
    ui_kv "端口" "$sub_port" "$WHITE"
    ui_kv "访问令牌" "$sub_token" "$WHITE"
    if [[ "$sub_bind" == "127.0.0.1" || "$sub_bind" == "::1" ]]; then
        ui_line "${GRAY}127.0.0.1 仅本机可访问；手机/电脑要用请重新启用，监听地址填 0.0.0.0${PLAIN}"
    fi
    ui_bot
    ui_menu_select "请选择" 0 \
        "1|启用 / 更新|生成高强度随机令牌" \
        "2|查看订阅地址|令牌链接可直接导入客户端" \
        "3|停止服务|撤销当前订阅令牌" \
        "0/q|返回|" || return 0
    case "$UI_SEL_KEY" in
        1) subscription_enable ;;
        2) subscription_status ;;
        3) subscription_disable ;;
    esac
}
