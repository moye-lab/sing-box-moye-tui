#!/usr/bin/env bash

install_reality() {
    ensure_singbox_installed || return 1
    ui_banner "配置 VLESS-Reality-Vision 协议"

    local port sni uuid key_pair priv_key pub_key short_id
    port=$(prompt_port) || return 1
    if [[ -z "${SBX_AUTO:-}" ]]; then
        read -rp " 请输入伪装偷取域名 SNI [默认: itunes.apple.com]: " sni
    fi
    sni="${sni:-itunes.apple.com}"
    valid_domain_name "$sni" || { log_err "SNI 域名格式无效。"; return 1; }

    uuid=$("$SB_BIN" generate uuid)
    key_pair=$("$SB_BIN" generate reality-keypair)
    priv_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}')
    pub_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}')
    short_id=$("$SB_BIN" generate rand --hex 4)

    local inbound_json
    inbound_json=$(jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg priv "$priv_key" \
        --arg sid "$short_id" '{
        type: "vless",
        tag: "reality-in",
        listen: "::",
        listen_port: $port,
        users: [
            {
                uuid: $uuid,
                flow: "xtls-rprx-vision"
            }
        ],
        tls: {
            enabled: true,
            server_name: $sni,
            reality: {
                enabled: true,
                handshake: {
                    server: $sni,
                    server_port: 443
                },
                private_key: $priv,
                short_id: [$sid]
            }
        }
    }')

    if apply_inbound "add" "reality-in" "$inbound_json"; then
        local state_data
        state_data=$(jq -n \
            --argjson port "$port" \
            --arg uuid "$uuid" \
            --arg sni "$sni" \
            --arg priv "$priv_key" \
            --arg pub "$pub_key" \
            --arg sid "$short_id" '{
            port: $port,
            uuid: $uuid,
            sni: $sni,
            private_key: $priv,
            public_key: $pub,
            short_id: $sid
        }')
        if state_set_proto "reality" "$state_data"; then
            log_ok "VLESS-Reality 安装并启动成功！"
            export_all_nodes
        else
            log_err "状态写入失败，正在回滚配置..."
            apply_inbound "del" "reality-in" >/dev/null 2>&1 || true
            return 1
        fi
    fi
}

modify_reality() {
    if ! state_has_proto "reality"; then
        log_warn "尚未安装 VLESS-Reality！"
        return
    fi
    local cur_port cur_sni uuid priv_key pub_key short_id
    cur_port=$(state_get_field "reality" "port")
    cur_sni=$(state_get_field "reality" "sni")
    uuid=$(state_get_field "reality" "uuid")
    priv_key=$(state_get_field "reality" "private_key")
    pub_key=$(state_get_field "reality" "public_key")
    short_id=$(state_get_field "reality" "short_id")

    local new_port new_sni
    new_port=$(prompt_port "$cur_port") || return 1
    read -rp " 请输入新的伪装 SNI [当前: ${cur_sni}]: " new_sni
    new_sni="${new_sni:-$cur_sni}"
    valid_domain_name "$new_sni" || { log_err "SNI 域名格式无效。"; return 1; }

    local inbound_json
    inbound_json=$(jq -n \
        --argjson port "$new_port" \
        --arg uuid "$uuid" \
        --arg sni "$new_sni" \
        --arg priv "$priv_key" \
        --arg sid "$short_id" '{
        type: "vless",
        tag: "reality-in",
        listen: "::",
        listen_port: $port,
        users: [{ uuid: $uuid, flow: "xtls-rprx-vision" }],
        tls: {
            enabled: true,
            server_name: $sni,
            reality: {
                enabled: true,
                handshake: { server: $sni, server_port: 443 },
                private_key: $priv,
                short_id: [$sid]
            }
        }
    }')

    if apply_inbound "add" "reality-in" "$inbound_json"; then
        local state_data
        state_data=$(jq -n \
            --argjson port "$new_port" \
            --arg uuid "$uuid" \
            --arg sni "$new_sni" \
            --arg priv "$priv_key" \
            --arg pub "$pub_key" \
            --arg sid "$short_id" '{
            port: $port, uuid: $uuid, sni: $sni,
            private_key: $priv, public_key: $pub, short_id: $sid
        }')
        if state_set_proto "reality" "$state_data"; then
            log_ok "VLESS-Reality 参数已更新！"
            export_all_nodes
        else
            log_err "状态写入失败！配置已更新但状态未同步，请重新修改一次。"
            return 1
        fi
    fi
}

uninstall_reality() {
    if apply_inbound "del" "reality-in"; then
        if state_del_proto "reality"; then
            log_ok "VLESS-Reality 协议已卸载。"
        else
            log_warn "配置已删除，但状态清理失败（可忽略，状态会在下次操作时自动修复）。"
        fi
    fi
}

menu_reality() {
    ui_menu_head "VLESS-Reality" "PROTOCOLS › REALITY"
    ui_proto_status reality
    ui_bot
    # 选项列表由 ui_menu_select 渲染（字母立即、数字需回车；非 TTY 行输入）；
    # 默认选中最后一项“返回主菜单”：空输入沿旧行为返回，避免回车误触安装。
    ui_menu_select "请选择" 3 \
        "1/i|安装 / 重置|生成全新的 UUID 与密钥对" \
        "2/m|修改端口与域名|保留原密钥，仅调整端口与伪装 SNI" \
        "3/x|卸载协议|移除入站并清理状态" \
        "0/q|返回主菜单|"
    local rc=$?
    if (( rc != 0 )); then return 0; fi   # Esc / q / EOF / 中断 → 返回上一级
    case "$UI_SEL_KEY" in
        "1/i")
            if install_reality; then
                ui_msg_ok "VLESS-Reality 安装完成"
            else
                ui_msg_err "VLESS-Reality 安装失败，请查看上方日志"
            fi
            ;;
        "2/m")
            if modify_reality; then
                ui_msg_ok "VLESS-Reality 参数已更新"
            else
                ui_msg_err "VLESS-Reality 修改失败，请查看上方日志"
            fi
            ;;
        "3/x")
            if uninstall_reality; then
                ui_msg_ok "VLESS-Reality 已卸载"
            else
                ui_msg_err "VLESS-Reality 卸载失败，请查看上方日志"
            fi
            ;;
        *) return 0 ;;
    esac
}
