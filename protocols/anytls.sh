#!/usr/bin/env bash

# AnyTLS 需要 sing-box >= 1.12.0；版本不足时自动升级内核
require_anytls_version() {
    local ver
    ver=$(get_installed_sb_version)
    if [[ "$ver" == "未安装" ]]; then
        return 0  # ensure_singbox_installed 会装最新版
    fi
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
        log_warn "无法解析 sing-box 版本（${ver}），跳过版本检查。"
        return 0
    fi
    if (( major < 1 || (major == 1 && minor < 12) )); then
        log_warn "AnyTLS 需要 sing-box >= 1.12.0，当前 v${ver}，正在升级内核..."
        install_singbox_core "latest" || { log_err "内核升级失败，无法安装 AnyTLS。"; return 1; }
    fi
}

install_anytls() {
    ensure_singbox_installed || return 1
    require_anytls_version || return 1
    ui_banner "配置 AnyTLS 协议"

    local port password cert_info _cert_type cert_path key_path sni insecure
    port=$(prompt_port) || return 1
    password=$("$SB_BIN" generate rand --hex 12)

    cert_info=$(select_or_create_cert) || { log_err "证书配置失败，已中止。"; return 1; }
    [[ -n "$cert_info" ]] || return 1
    IFS='|' read -r _cert_type cert_path key_path sni insecure <<< "$cert_info"

    local inbound_json
    inbound_json=$(jq -n \
        --argjson port "$port" \
        --arg pwd "$password" \
        --arg cert "$cert_path" \
        --arg key "$key_path" \
        --arg sni "$sni" '{
        type: "anytls",
        tag: "anytls-in",
        listen: "::",
        listen_port: $port,
        users: [
            {
                name: "anytls",
                password: $pwd,
            }
        ],
        tls: {
            enabled: true,
            server_name: $sni,
            certificate_path: $cert,
            key_path: $key
        }
    }')

    if apply_inbound "add" "anytls-in" "$inbound_json"; then
        local state_data
        state_data=$(jq -n \
            --argjson port "$port" \
            --arg pwd "$password" \
            --arg sni "$sni" \
            --argjson insecure "$insecure" '{
            port: $port,
            password: $pwd,
            sni: $sni,
            insecure: $insecure
        }')
        if state_set_proto "anytls" "$state_data"; then
            log_ok "AnyTLS 安装并启动成功！"
        else
            log_err "状态写入失败，正在回滚配置..."
            apply_inbound "del" "anytls-in" >/dev/null 2>&1 || true
            return 1
        fi
        export_all_nodes
    fi
}

uninstall_anytls() {
    if apply_inbound "del" "anytls-in"; then
        if state_del_proto "anytls"; then
            log_ok "AnyTLS 协议已卸载。"
        else
            log_warn "配置已删除，但状态清理失败（可忽略）。"
        fi
    fi
}

menu_anytls() {
    ui_menu_head "AnyTLS" "PROTOCOLS › ANYTLS"
    ui_proto_status anytls
    ui_bot
    # 选项列表由 ui_menu_select 渲染（字母立即、数字需回车；非 TTY 行输入）；
    # 默认选中最后一项“返回主菜单”：空输入沿旧行为返回，避免回车误触安装。
    ui_menu_select "请选择" 2 \
        "1/i|安装 / 重置|TCP · TLS 伪装" \
        "2/x|卸载协议|移除入站并清理状态" \
        "0/q|返回主菜单|"
    local rc=$?
    if (( rc != 0 )); then return 0; fi   # Esc / q / EOF / 中断 → 返回上一级
    case "$UI_SEL_KEY" in
        "1/i")
            if install_anytls; then
                ui_msg_ok "AnyTLS 安装完成"
            else
                ui_msg_err "AnyTLS 安装失败，请查看上方日志"
            fi
            ;;
        "2/x")
            if uninstall_anytls; then
                ui_msg_ok "AnyTLS 已卸载"
            else
                ui_msg_err "AnyTLS 卸载失败，请查看上方日志"
            fi
            ;;
        *) return 0 ;;
    esac
}
