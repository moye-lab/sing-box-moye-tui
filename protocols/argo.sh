#!/usr/bin/env bash

CF_LOG="/var/log/cloudflared-sb.log"
CF_ENV="${SB_ETC}/cloudflared.env"

# 优选 IP/域名：支持英文逗号分隔多个；逐个校验，返回去空格后的规范化串
normalize_cf_ips() {
    local raw="$1" item clean out=""
    local -a items
    IFS=',' read -ra items <<< "$raw"
    for item in "${items[@]}"; do
        clean="${item//[[:space:]]/}"
        [[ -n "$clean" ]] || return 1
        valid_host_or_ip "$clean" || return 1
        out="${out:+$out,}${clean}"
    done
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

ensure_cloudflared() {
    [[ -x "$CF_BIN" ]] && return 0
    local a
    a=$(detect_arch) || return 1
    [[ "$a" == "armv7" ]] && a="armhf"   # cloudflared 的资源命名（以 release 页面为准）
    log_info "正在下载官方 cloudflared 客户端..."
    if ! download_file "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${a}" "$CF_BIN"; then
        log_err "cloudflared 下载失败"
        return 1
    fi
    chmod +x "$CF_BIN"
    log_ok "cloudflared 安装完成！"
}

write_argo_unit() {
    local exec_cmd="$1" env_line=""
    [[ -f "$CF_ENV" ]] && env_line="EnvironmentFile=${CF_ENV}"
    cat > /etc/systemd/system/cloudflared-sb.service <<EOF
[Unit]
Description=Cloudflare Argo Tunnel for Sing-box
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=simple
${env_line}
ExecStart=${exec_cmd}
Restart=always
RestartSec=5s
UMask=0077
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
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=/var/log

[Install]
WantedBy=multi-user.target
EOF
}

install_argo() {
    ensure_singbox_installed || return 1
    ensure_cloudflared || return 1
    ui_banner "配置 Cloudflare Argo 隧道 (VLESS-WS 本地回环穿透)"
    echo "   1. 临时隧道模式 (免账号生成 *.trycloudflare.com，适合临时应急)"
    echo "   2. 固定隧道模式 (Token 绑定自定义域名，长期稳定)"
    local mode_opt
    read -rp " 请选择隧道模式 [默认: 1]: " mode_opt
    mode_opt="${mode_opt:-1}"

    local local_port uuid ws_path cf_ip tunnel_domain="" cf_token mode_name
    local_port=$(prompt_port) || return 1
    uuid=$("$SB_BIN" generate uuid)
    ws_path="/argo-$("$SB_BIN" generate rand --hex 3)"

    read -rp " 请输入客户端连接使用的优选 IP 或域名，多个用英文逗号分隔 [默认: 104.16.80.1]: " cf_ip
    cf_ip="${cf_ip:-104.16.80.1}"
    cf_ip=$(normalize_cf_ips "$cf_ip") || { log_err "优选 IP 或域名格式无效。"; return 1; }

    rm -f "$CF_ENV"
    if [[ "$mode_opt" == "2" ]]; then
        mode_name="token"
        read -rsp " 请输入 Cloudflare Zero Trust 隧道 Token: " cf_token; echo
        read -rp " 请输入你在 Cloudflare 后台绑定的完整域名 (如 argo.example.com): " tunnel_domain
        if [[ -z "$cf_token" || -z "$tunnel_domain" ]]; then
            log_err "固定隧道的 Token 和绑定域名不能为空！"
            return 1
        fi
        if [[ ${#cf_token} -lt 32 || ${#cf_token} -gt 4096 || ! "$cf_token" =~ ^[A-Za-z0-9._=-]+$ ]]; then
            log_err "Cloudflare Token 格式无效；请粘贴完整 Token，不要包含空格或换行。"
            return 1
        fi
        valid_domain_name "$tunnel_domain" || { log_err "Cloudflare 隧道域名格式无效。"; return 1; }
        log_warn "请确保 Cloudflare 隧道后台 Public Hostname 已指向 -> HTTP://127.0.0.1:${local_port}"
    else
        mode_name="quick"
    fi

    local inbound_json
    inbound_json=$(jq -n \
        --argjson port "$local_port" \
        --arg uuid "$uuid" \
        --arg path "$ws_path" '{
        type: "vless",
        tag: "argo-in",
        listen: "127.0.0.1",
        listen_port: $port,
        users: [ { uuid: $uuid } ],
        transport: { type: "ws", path: $path }
    }')

    apply_inbound "add" "argo-in" "$inbound_json" || return 1

    local exec_cmd
    if [[ "$mode_name" == "token" ]]; then
        printf 'TUNNEL_TOKEN=%s\n' "$cf_token" > "$CF_ENV"   # Token 不再出现在 unit / 进程列表里
        chmod 600 "$CF_ENV"
        exec_cmd="${CF_BIN} tunnel --no-autoupdate run"
    else
        rm -f "$CF_LOG"
        exec_cmd="${CF_BIN} tunnel --no-autoupdate --url http://127.0.0.1:${local_port} --logfile ${CF_LOG}"
    fi

    write_argo_unit "$exec_cmd"
    systemctl daemon-reload
    systemctl enable cloudflared-sb >/dev/null 2>&1
    systemctl restart cloudflared-sb

    if [[ "$mode_name" == "quick" ]]; then
        log_info "正在等待 Cloudflare 分配临时隧道域名 (约 5-10 秒)..."
        for _ in {1..15}; do
            sleep 1
            tunnel_domain=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | tail -n1 | sed 's|https://||')
            [[ -n "$tunnel_domain" ]] && break
        done
        if [[ -z "$tunnel_domain" ]]; then
            log_err "未能从日志提取到临时域名，请检查 journalctl -u cloudflared-sb"
            return 1
        fi
        log_ok "已获取临时 Argo 域名: ${tunnel_domain}"
        log_warn "临时隧道每次重启域名都会变化，变化后请用 Argo 菜单的 [4/r] 刷新。"
    fi

    local state_data
    state_data=$(jq -n \
        --arg mode "$mode_name" \
        --argjson port "$local_port" \
        --arg uuid "$uuid" \
        --arg path "$ws_path" \
        --arg domain "$tunnel_domain" \
        --arg cf_ip "$cf_ip" '{
        mode: $mode, local_port: $port, uuid: $uuid,
        path: $path, domain: $domain, cf_ip: $cf_ip
    }')
    if state_set_proto "argo" "$state_data"; then
        log_ok "Cloudflare Argo 隧道部署完成！（本地回环端口: 127.0.0.1:${local_port}）"
    else
        log_err "状态写入失败，隧道已启动但状态未保存，请重新安装。"
        return 1
    fi
    export_all_nodes
}

argo_refresh_domain() {
    if [[ "$(state_get_field "argo" "mode")" != "quick" ]]; then
        log_info "仅临时隧道模式需要刷新域名。"
        return
    fi
    local d
    d=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | tail -n1 | sed 's|https://||')
    if [[ -z "$d" ]]; then
        log_err "日志中未找到临时域名，请检查 journalctl -u cloudflared-sb"
        return 1
    fi
    state_set_field "argo" "domain" "$d"
    log_ok "临时域名已刷新: ${d}"
    export_all_nodes
}

uninstall_argo() {
    systemctl stop cloudflared-sb 2>/dev/null || true
    systemctl disable cloudflared-sb 2>/dev/null || true
    rm -f /etc/systemd/system/cloudflared-sb.service "$CF_LOG" "$CF_ENV"
    systemctl daemon-reload

    if apply_inbound "del" "argo-in"; then
        if state_del_proto "argo"; then
            log_ok "Cloudflare Argo 隧道与本地入站已卸载。"
        else
            log_warn "配置已删除，但状态清理失败（可忽略）。"
        fi
    fi
}

menu_argo() {
    ui_menu_head "Cloudflare Argo" "PROTOCOLS › ARGO"
    ui_proto_status argo
    if systemctl is-active --quiet cloudflared-sb 2>/dev/null; then
        ui_kv "隧道服务" "${UI_ON} cloudflared 运行中" "$GREEN"
    else
        ui_kv "隧道服务" "${UI_OFF} cloudflared 未运行" "$GRAY"
    fi
    ui_bot
    # 选项列表由 ui_menu_select 渲染（字母立即、数字需回车；非 TTY 行输入）；
    # 默认选中最后一项“返回主菜单”：空输入沿旧行为返回，避免回车误触安装。
    ui_menu_select "请选择" 5 \
        "1/i|安装 / 重新配置|固定 Token 隧道 或 临时隧道" \
        "2/s|查看隧道状态|systemctl status cloudflared-sb" \
        "3/x|卸载隧道|停止服务并移除本地入站" \
        "4/r|刷新临时域名|临时隧道重启后域名会变化" \
        "5/c|更换优选 IP|只换客户端连接地址，不重建隧道" \
        "0/q|返回主菜单|"
    local rc=$?
    if (( rc != 0 )); then return 0; fi   # Esc / q / EOF / 中断 → 返回上一级
    case "$UI_SEL_KEY" in
        "1/i")
            if install_argo; then
                ui_msg_ok "Cloudflare Argo 隧道部署完成"
            else
                ui_msg_err "Cloudflare Argo 安装失败，请查看上方日志"
            fi
            ;;
        "2/s") systemctl status cloudflared-sb --no-pager || true ;;
        "3/x")
            if uninstall_argo; then
                ui_msg_ok "Cloudflare Argo 隧道已卸载"
            else
                ui_msg_err "Cloudflare Argo 卸载失败，请查看上方日志"
            fi
            ;;
        # 刷新/更换成功时业务函数已打印带详情的 log（非 quick 模式或未做更改时
        # 同样返回 0），此处只在真实失败时补一条错误框，不虚构成功消息。
        "4/r")
            if ! argo_refresh_domain; then
                ui_msg_err "临时域名刷新失败，请查看上方日志"
            fi
            ;;
        "5/c")
            if ! argo_change_ips; then
                ui_msg_err "优选 IP 更换失败，请查看上方日志"
            fi
            ;;
        *) return 0 ;;
    esac
}

# 仅更换客户端连接的优选 IP/域名，不重建隧道、不动 sing-box 配置
argo_change_ips() {
    state_has_proto "argo" || { log_err "Argo 尚未安装，请先安装。"; return 1; }
    local cur new
    cur=$(state_get_field "argo" "cf_ip")
    echo " 当前优选 IP/域名: ${cur:-未设置}"
    read -rp " 请输入新的优选 IP 或域名，多个用英文逗号分隔 [回车保持不变]: " new
    [[ -z "$new" ]] && { log_info "未做更改。"; return 0; }
    new=$(normalize_cf_ips "$new") || { log_err "优选 IP 或域名格式无效。"; return 1; }
    state_set_field "argo" "cf_ip" "$new" || { log_err "状态更新失败。"; return 1; }
    log_ok "优选 IP 已更新为: ${new}"
    export_all_nodes
}
