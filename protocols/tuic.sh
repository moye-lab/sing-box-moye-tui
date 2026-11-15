#!/usr/bin/env bash

install_tuic() {
    ensure_singbox_installed || return 1
    ui_banner "配置 TUIC v5 协议"

    local port uuid password cert_info _cert_type cert_path key_path sni insecure
    port=$(prompt_port) || return 1
    uuid=$("$SB_BIN" generate uuid)
    password=$("$SB_BIN" generate rand --hex 8)

    cert_info=$(select_or_create_cert) || { log_err "证书配置失败，已中止。"; return 1; }
    [[ -n "$cert_info" ]] || return 1
    IFS='|' read -r _cert_type cert_path key_path sni insecure <<< "$cert_info"

    local inbound_json
    inbound_json=$(jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg pwd "$password" \
        --arg cert "$cert_path" \
        --arg key "$key_path" '{
        type: "tuic",
        tag: "tuic-in",
        listen: "::",
        listen_port: $port,
        users: [
            {
                uuid: $uuid,
                password: $pwd
            }
        ],
        congestion_control: "bbr",
        tls: {
            enabled: true,
            alpn: ["h3"],
            certificate_path: $cert,
            key_path: $key
        }
    }')

    if apply_inbound "add" "tuic-in" "$inbound_json"; then
        local state_data
        state_data=$(jq -n \
            --argjson port "$port" \
            --arg uuid "$uuid" \
            --arg pwd "$password" \
            --arg sni "$sni" \
            --argjson insecure "$insecure" '{
            port: $port,
            uuid: $uuid,
            password: $pwd,
            sni: $sni,
            insecure: $insecure
        }')
        if state_set_proto "tuic" "$state_data"; then
            log_ok "TUIC v5 安装并启动成功！"
        else
            log_err "状态写入失败，正在回滚配置..."
            apply_inbound "del" "tuic-in" >/dev/null 2>&1 || true
            return 1
        fi
        export_all_nodes
    fi
}

uninstall_tuic() {
    if apply_inbound "del" "tuic-in"; then
        if state_del_proto "tuic"; then
            log_ok "TUIC v5 协议已卸载。"
        else
            log_warn "配置已删除，但状态清理失败（可忽略）。"
        fi
    fi
}

menu_tuic() {
    ui_menu_head "TUIC v5" "PROTOCOLS › TUIC"
    ui_proto_status tuic
    ui_bot
    # 选项列表由 ui_menu_select 渲染（字母立即、数字需回车；非 TTY 行输入）；
    # 默认选中最后一项“返回主菜单”：空输入沿旧行为返回，避免回车误触安装。
    ui_menu_select "请选择" 2 \
        "1/i|安装 / 重置|QUIC · BBR 拥塞控制" \
        "2/x|卸载协议|移除入站并清理状态" \
        "0/q|返回主菜单|"
    local rc=$?
    if (( rc != 0 )); then return 0; fi   # Esc / q / EOF / 中断 → 返回上一级
    case "$UI_SEL_KEY" in
        "1/i")
            if install_tuic; then
                ui_msg_ok "TUIC v5 安装完成"
            else
                ui_msg_err "TUIC v5 安装失败，请查看上方日志"
            fi
            ;;
        "2/x")
            if uninstall_tuic; then
                ui_msg_ok "TUIC v5 已卸载"
            else
                ui_msg_err "TUIC v5 卸载失败，请查看上方日志"
            fi
            ;;
        *) return 0 ;;
    esac
}
