#!/usr/bin/env bash

show_socks5_params() {
    if ! state_has_proto "socks5"; then
        ui_msg_warn "SOCKS5 尚未安装，当前没有可展示的代理参数。"
        return 1
    fi

    local ip port username password
    ip=$(get_public_ip)
    if [[ -z "$ip" || "$ip" == "127.0.0.1" ]]; then
        ip="<公网IP未获取>"
    fi
    port=$(state_get_field "socks5" "port")
    username=$(state_get_field "socks5" "username")
    password=$(state_get_field "socks5" "password")

    if [[ -z "$port" || -z "$username" || -z "$password" ]]; then
        ui_msg_err "SOCKS5 状态数据不完整，请尝试重新安装或重置。"
        return 1
    fi

    echo ""
    ui_top
    ui_split "${BOLD}${CYAN}SOCKS5 代理参数${PLAIN}" "${GRAY}APP CONFIG${PLAIN}"
    ui_kv "服务器" "$ip" "$WHITE"
    ui_kv "端口" "$port" "$WHITE"
    ui_kv "用户名" "$username" "$WHITE"
    ui_kv "密码" "$password" "$WHITE"
    ui_mid
    ui_line "Telegram → 设置 → 数据与存储 → 代理 → 添加 SOCKS5，按以上填写"
    ui_mid
    ui_line "${YELLOW}注意：SOCKS5 无加密，仅供 App 填参数，勿当节点直连${PLAIN}"
    ui_bot
}

install_socks5() {
    ensure_singbox_installed || return 1
    ui_banner "配置 SOCKS5 入站"
    local port username password inbound_json state_data
    port=$(prompt_port) || return 1
    read -rp " SOCKS5 用户名 [默认自动生成]: " username
    username="${username:-sbx$(openssl rand -hex 3)}"
    if [[ ! "$username" =~ ^[A-Za-z0-9_.-]{1,64}$ ]]; then
        log_err "用户名仅允许字母、数字、点、下划线和连字符（最多 64 位）"
        return 1
    fi
    password=$(openssl rand -hex 16) || return 1
    inbound_json=$(jq -n --argjson port "$port" --arg user "$username" --arg pass "$password" '{
        type:"socks", tag:"socks5-in", listen:"::", listen_port:$port,
        users:[{username:$user,password:$pass}]
    }')
    if apply_inbound add socks5-in "$inbound_json"; then
        state_data=$(jq -n --argjson port "$port" --arg user "$username" --arg pass "$password" \
            '{port:$port,username:$user,password:$pass,udp:true}')
        if state_set_proto socks5 "$state_data"; then
            log_ok "SOCKS5 入站已启用（强制用户名密码认证）"
            log_warn "请在防火墙中仅向可信来源开放 TCP/UDP ${port}，不要暴露无认证代理。"
            show_socks5_params
        else
            log_err "状态写入失败，正在回滚配置..."
            apply_inbound del socks5-in >/dev/null 2>&1 || true
            return 1
        fi
    fi
}

uninstall_socks5() {
    if apply_inbound del socks5-in; then
        if state_del_proto socks5; then
            log_ok "SOCKS5 入站已卸载"
        else
            log_warn "配置已删除，但状态清理失败（可忽略）。"
        fi
    fi
}

menu_socks5() {
    ui_menu_head "SOCKS5" "PROTOCOLS › SOCKS5"
    ui_proto_status socks5
    ui_bot
    # 选项列表由 ui_menu_select 渲染（字母立即、数字需回车；非 TTY 行输入）；
    # 默认选中最后一项“返回主菜单”：空输入沿旧行为返回，避免回车误触安装。
    # 注意：本文件现有菜单只有安装/卸载/返回三项，未设“查看参数”入口
    # （show_socks5_params 仅在安装成功后与订阅菜单中调用），此处不新增选项。
    ui_menu_select "请选择" 2 \
        "1/i|安装 / 重装|强制认证 · TCP + UDP" \
        "2/x|卸载协议|删除入站并清理状态" \
        "0/q|返回主菜单|"
    local rc=$?
    if (( rc != 0 )); then return 0; fi   # Esc / q / EOF / 中断 → 返回上一级
    case "$UI_SEL_KEY" in
        "1/i")
            if install_socks5; then
                ui_msg_ok "SOCKS5 安装完成"
            else
                ui_msg_err "SOCKS5 安装失败，请查看上方日志"
            fi
            ;;
        "2/x")
            if uninstall_socks5; then
                ui_msg_ok "SOCKS5 已卸载"
            else
                ui_msg_err "SOCKS5 卸载失败，请查看上方日志"
            fi
            ;;
        *) return 0 ;;
    esac
}
