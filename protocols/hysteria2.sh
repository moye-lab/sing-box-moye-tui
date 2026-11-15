#!/usr/bin/env bash

install_hysteria2() {
    ensure_singbox_installed || return 1
    ui_banner "配置 Hysteria 2 协议"

    local port password cert_info _cert_type cert_path key_path sni insecure hop_range
    port=$(prompt_port) || return 1
    password=$("$SB_BIN" generate rand --hex 12)

    cert_info=$(select_or_create_cert) || { log_err "证书配置失败，已中止。"; return 1; }
    [[ -n "$cert_info" ]] || { log_err "证书配置为空，已中止。"; return 1; }
    IFS='|' read -r _cert_type cert_path key_path sni insecure <<< "$cert_info"

    if [[ -z "${SBX_AUTO:-}" ]]; then
        read -rp " 是否开启 UDP 端口跳跃？(如填 20000:40000，留空不开启): " hop_range
    fi
    if [[ -n "$hop_range" ]]; then
        hop_range=$(normalize_hop_range "$hop_range") || {
            log_warn "端口段格式无效，已忽略端口跳跃。"; hop_range=""; }
    fi

    local inbound_json
    inbound_json=$(jq -n \
        --argjson port "$port" \
        --arg pwd "$password" \
        --arg cert "$cert_path" \
        --arg key "$key_path" '{
        type: "hysteria2",
        tag: "hy2-in",
        listen: "::",
        listen_port: $port,
        users: [ { password: $pwd } ],
        tls: {
            enabled: true,
            alpn: ["h3"],
            certificate_path: $cert,
            key_path: $key
        }
    }')

    if apply_inbound "add" "hy2-in" "$inbound_json"; then
        remove_port_hopping >/dev/null 2>&1 || true      # 重装时先清旧规则
        if [[ -n "$hop_range" ]]; then
            add_port_hopping "$hop_range" "$port" || hop_range=""
        fi
        local state_data
        state_data=$(jq -n \
            --argjson port "$port" \
            --arg pwd "$password" \
            --arg sni "$sni" \
            --arg cert "$cert_path" \
            --arg key "$key_path" \
            --argjson insecure "$insecure" \
            --arg hop "$hop_range" '{
            port: $port, password: $pwd, sni: $sni,
            cert_path: $cert, key_path: $key,
            insecure: $insecure, hop_range: $hop
        }')
        if state_set_proto "hysteria2" "$state_data"; then
            log_ok "Hysteria 2 安装并启动成功！"
        else
            log_err "状态写入失败，正在回滚配置..."
            apply_inbound "del" "hy2-in" >/dev/null 2>&1 || true
            return 1
        fi
        export_all_nodes
    fi
}

uninstall_hysteria2() {
    if apply_inbound "del" "hy2-in"; then
        remove_port_hopping
        if state_del_proto "hysteria2"; then
            log_ok "Hysteria 2 协议已卸载。"
        else
            log_warn "配置已删除，但状态清理失败（可忽略）。"
        fi
    fi
}

menu_hysteria2() {
    ui_menu_head "Hysteria 2" "PROTOCOLS › HYSTERIA2"
    ui_proto_status hysteria2
    ui_bot
    # 选项列表由 ui_menu_select 渲染（字母立即、数字需回车；非 TTY 行输入）；
    # 默认选中最后一项“返回主菜单”：空输入沿旧行为返回，避免回车误触安装。
    ui_menu_select "请选择" 2 \
        "1/i|安装 / 重置|支持自签 / ACME 证书与 UDP 端口跳跃" \
        "2/x|卸载协议|移除入站并清理端口跳跃规则" \
        "0/q|返回主菜单|"
    local rc=$?
    if (( rc != 0 )); then return 0; fi   # Esc / q / EOF / 中断 → 返回上一级
    case "$UI_SEL_KEY" in
        "1/i")
            if install_hysteria2; then
                ui_msg_ok "Hysteria 2 安装完成"
            else
                ui_msg_err "Hysteria 2 安装失败，请查看上方日志"
            fi
            ;;
        "2/x")
            if uninstall_hysteria2; then
                ui_msg_ok "Hysteria 2 已卸载"
            else
                ui_msg_err "Hysteria 2 卸载失败，请查看上方日志"
            fi
            ;;
        *) return 0 ;;
    esac
}
