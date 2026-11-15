#!/usr/bin/env bash

HOP_UNIT="/etc/systemd/system/sbx-hop.service"

enable_bbr_and_udp_tuning() {
    log_info "正在写入 BBR 与高并发 UDP 缓冲区内核参数..."
    modprobe tcp_bbr 2>/dev/null || true
    cat > /etc/sysctl.d/99-singbox-tune.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF
    sysctl --system >/dev/null 2>&1 || true
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
        log_ok "BBR 与 UDP Buffer 调优已生效！"
    else
        log_warn "参数已写入，但 BBR 未生效（内核不支持，或处于 LXC/OpenVZ 容器中）。"
    fi
}

# 统一为 iptables 的 a:b 格式并校验，结果输出到 stdout
normalize_hop_range() {
    local r="${1//-/:}" a b
    [[ "$r" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    a="${r%%:*}"; b="${r##*:}"
    (( a >= 1 && b <= 65535 && a < b )) || return 1
    echo "$r"
}

add_port_hopping() {
    local range target="$2" ipt ip6t
    range=$(normalize_hop_range "$1") || { log_err "端口段格式无效（示例 20000:40000）"; return 1; }
    [[ "$target" =~ ^[0-9]+$ ]] && (( target >= 1 && target <= 65535 )) || {
        log_err "目标端口无效（必须为 1-65535 的整数）"; return 1;
    }
    ipt=$(command -v iptables) || { log_err "未找到 iptables"; return 1; }
    ip6t=$(command -v ip6tables || true)

    remove_port_hopping >/dev/null 2>&1 || true   # 先清掉旧规则

    {
        printf '[Unit]\nDescription=sbx UDP port hopping\nAfter=network-online.target\nWants=network-online.target\n\n'
        printf '[Service]\nType=oneshot\nRemainAfterExit=yes\n'
        printf 'ExecStart=%s -t nat -A PREROUTING -p udp --dport %s -j REDIRECT --to-ports %s\n' "$ipt" "$range" "$target"
        printf 'ExecStop=-%s -t nat -D PREROUTING -p udp --dport %s -j REDIRECT --to-ports %s\n' "$ipt" "$range" "$target"
        if [[ -n "$ip6t" ]]; then
            printf 'ExecStart=-%s -t nat -A PREROUTING -p udp --dport %s -j REDIRECT --to-ports %s\n' "$ip6t" "$range" "$target"
            printf 'ExecStop=-%s -t nat -D PREROUTING -p udp --dport %s -j REDIRECT --to-ports %s\n' "$ip6t" "$range" "$target"
        fi
        printf '\n[Install]\nWantedBy=multi-user.target\n'
    } > "$HOP_UNIT"

    systemctl daemon-reload
    systemctl enable sbx-hop >/dev/null 2>&1 || true
    if systemctl start sbx-hop; then
        log_ok "已配置 UDP 端口跳跃（开机自动恢复）: ${range} -> ${target}"
    else
        log_err "端口跳跃规则应用失败，请检查 iptables。"
        return 1
    fi
}

remove_port_hopping() {
    if [[ -f "$HOP_UNIT" ]]; then
        systemctl stop sbx-hop 2>/dev/null || true
        systemctl disable sbx-hop >/dev/null 2>&1 || true
        rm -f "$HOP_UNIT"
        systemctl daemon-reload
        log_info "已清理端口跳跃规则"
    fi
}

sysctl_menu() {
    # ---- 只读检测：实时内核值（实际生效）与本工具写入的配置（已配置） ----
    # 检测失败（无 sysctl / 无权限 / 无 systemctl）时显示"未知"，不得虚构为正常。
    local cc qdisc rmem_max wmem_max udp_rmin udp_wmin
    local tune_txt tune_clr hop hop_port hop_txt hop_clr hop_eff hop_eff_clr
    local cc_txt cc_clr bbr_txt bbr_clr qdisc_txt qdisc_clr fq_txt fq_clr
    local udp_txt udp_clr udp_min_txt udp_min_clr

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null)
    wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null)
    udp_rmin=$(sysctl -n net.ipv4.udp_rmem_min 2>/dev/null)
    udp_wmin=$(sysctl -n net.ipv4.udp_wmem_min 2>/dev/null)

    # 已配置：调优参数文件是否存在（enable_bbr_and_udp_tuning 写入）
    if [[ -f /etc/sysctl.d/99-singbox-tune.conf ]]; then
        tune_txt="${UI_ON} 已配置"
        tune_clr="$GREEN"
    else
        tune_txt="${UI_OFF} 未配置"
        tune_clr="$GRAY"
    fi

    # 已配置：端口跳跃（状态记录为准；状态缺失但单元文件存在时如实标注）
    hop=$(state_get_field "hysteria2" "hop_range")
    hop_port=$(state_get_field "hysteria2" "port")
    if [[ -n "$hop" ]]; then
        hop_txt="${UI_ON} ${hop} → ${hop_port:-Hysteria2}"
        hop_clr="$GREEN"
    elif [[ -f "$HOP_UNIT" ]]; then
        hop_txt="${UI_ON} 已配置（单元文件存在，端口段未知）"
        hop_clr="$YELLOW"
    else
        hop_txt="${UI_OFF} 未配置"
        hop_clr="$GRAY"
    fi

    # 实际生效：拥塞控制算法与 BBR 状态
    if [[ -z "$cc" ]]; then
        cc_txt="未知"; cc_clr="$GRAY"
        bbr_txt="未知"; bbr_clr="$GRAY"
    else
        cc_txt="$cc"
        if [[ "$cc" == "bbr" ]]; then
            cc_clr="$GREEN"; bbr_txt="已生效"; bbr_clr="$GREEN"
        else
            cc_clr="$YELLOW"; bbr_txt="未生效"; bbr_clr="$YELLOW"
        fi
    fi

    # 实际生效：队列算法与 FQ 状态
    if [[ -z "$qdisc" ]]; then
        qdisc_txt="未知"; qdisc_clr="$GRAY"
        fq_txt="未知"; fq_clr="$GRAY"
    else
        qdisc_txt="$qdisc"
        if [[ "$qdisc" == "fq" ]]; then
            qdisc_clr="$GREEN"; fq_txt="已启用"; fq_clr="$GREEN"
        else
            qdisc_clr="$YELLOW"; fq_txt="未启用"; fq_clr="$YELLOW"
        fi
    fi

    # 实际生效：UDP 缓冲区参数（任一读不到即整行未知，不拼凑半行数据）
    if [[ -n "$rmem_max" && -n "$wmem_max" ]]; then
        udp_txt="rmem_max ${rmem_max} · wmem_max ${wmem_max}"
        udp_clr="$WHITE"
    else
        udp_txt="未知"; udp_clr="$GRAY"
    fi
    if [[ -n "$udp_rmin" && -n "$udp_wmin" ]]; then
        udp_min_txt="udp_rmem_min ${udp_rmin} · udp_wmem_min ${udp_wmin}"
        udp_min_clr="$WHITE"
    else
        udp_min_txt="未知"; udp_min_clr="$GRAY"
    fi

    # 实际生效：跳跃规则（仅已配置时检测；无 systemctl 时为未知）
    if [[ -z "$hop" && ! -f "$HOP_UNIT" ]]; then
        hop_eff="未配置"; hop_eff_clr="$GRAY"
    elif ! command -v systemctl >/dev/null 2>&1; then
        hop_eff="未知"; hop_eff_clr="$GRAY"
    elif systemctl is-active --quiet sbx-hop 2>/dev/null; then
        hop_eff="已生效"; hop_eff_clr="$GREEN"
    else
        hop_eff="未生效"; hop_eff_clr="$YELLOW"
    fi

    ui_menu_head "系统网络调优" "TUNING"
    ui_section "已配置" "本工具写入的配置"
    ui_kv "调优配置" "$tune_txt" "$tune_clr"
    ui_kv "端口跳跃" "$hop_txt" "$hop_clr"
    ui_mid
    ui_section "实际生效" "内核实时检测值"
    ui_kv "拥塞控制" "$cc_txt" "$cc_clr"
    ui_kv "BBR 状态" "$bbr_txt" "$bbr_clr"
    ui_kv "队列算法" "$qdisc_txt" "$qdisc_clr"
    ui_kv "FQ 状态" "$fq_txt" "$fq_clr"
    ui_kv "UDP 缓冲区" "$udp_txt" "$udp_clr"
    ui_kv "UDP 最小值" "$udp_min_txt" "$udp_min_clr"
    ui_kv "跳跃规则" "$hop_eff" "$hop_eff_clr"
    ui_bot

    # 默认选中"返回主菜单"：与改前行为一致，空输入直接返回，且避免误触 BBR 调优
    ui_menu_select "请选择操作" 2 \
        "1/b|BBR + UDP 缓冲区|一键开启 BBR 并扩容 QUIC/UDP 缓冲区" \
        "2/h|UDP 端口跳跃|为 Hysteria2 设置跳跃端口段" \
        "0/q|返回主菜单|"
    local rc=$?
    (( rc != 0 )) && return
    case "$UI_SEL_KEY" in
        1/b) enable_bbr_and_udp_tuning ;;
        2/h)
            local rng dst
            dst="$hop_port"
            ui_read_text "请输入外部跳跃端口段（如 20000:40000）" || return
            rng="$UI_INPUT"
            if [[ -z "$dst" ]]; then
                ui_read_text "请输入 Hysteria2 监听端口" || return
                dst="$UI_INPUT"
            fi
            if add_port_hopping "$rng" "$dst"; then
                if state_has_proto "hysteria2"; then
                    state_set_field "hysteria2" "hop_range" "$(normalize_hop_range "$rng")"
                    export_all_nodes
                fi
            fi
            ;;
        *) return ;;
    esac
}
