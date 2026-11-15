#!/usr/bin/env bash

# YAML strings are emitted as JSON-quoted scalars; JSON string quoting is a
# valid YAML subset and prevents names/credentials from injecting YAML keys.
yaml_quote() { jq -Rn --arg value "$1" '$value'; }

urlencode_path() {
    python3 -c 'import sys; from urllib.parse import quote; print(quote(sys.argv[1], safe="/"), end="")' "$1"
}

node_name() {
    local protocol="$1" index="${2:-}" short_protocol
    case "${protocol,,}" in
        vless-reality|vless) short_protocol="Reality" ;;
        hysteria2|hysteria-2|hy2) short_protocol="Hy2" ;;
        tuic|tuic-v5) short_protocol="TUIC" ;;
        vless-ws) short_protocol="Argo" ;;
        anytls) short_protocol="AnyTLS" ;;
        socks5|socks) short_protocol="SOCKS5" ;;
        *) short_protocol="$(printf '%s' "$protocol" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9-')" ;;
    esac
    if [[ -n "$index" ]]; then
        printf '%s-%s-%d' "$(get_node_prefix)" "$short_protocol" "$index"
    else
        printf '%s-%s' "$(get_node_prefix)" "$short_protocol"
    fi
}

export_all_nodes() {
    ensure_node_meta
    local ip host_ip prefix
    ip=$(get_public_ip)
    if [[ "$ip" == "-" ]] && (( $(jq '.installed_protocols | length' "$SB_STATE" 2>/dev/null || echo 0) > 0 )); then
        log_err "无法获取有效公网 IP，已停止生成节点配置，避免导出 127.0.0.1 或无效地址。请检查 VPS 网络后重试。"
        return 1
    fi
    host_ip="$ip"
    [[ "$ip" =~ : ]] && host_ip="[${ip}]"
    prefix=$(get_node_prefix)

    local links_file="${SB_EXPORT_DIR}/links.txt"
    local mihomo_file="${SB_EXPORT_DIR}/mihomo_proxies.yaml"
    local sb_client_file="${SB_EXPORT_DIR}/singbox_outbounds.json"

    : > "$links_file"
    echo "proxies:" > "$mihomo_file"
    local sb_outbounds="[]"

    echo ""
    ui_top
    ui_split "${BOLD}${CYAN}节点配置与订阅交付中心${PLAIN}" "${GRAY}EXPORT${PLAIN}"
    ui_kv "命名规范" "${prefix}-<协议>" "$WHITE"
    ui_bot

    if state_has_proto "reality"; then
        local r_port r_uuid r_sni r_pub r_sid r_name r_enc_name r_link
        r_port=$(state_get_field "reality" "port")
        r_uuid=$(state_get_field "reality" "uuid")
        r_sni=$(state_get_field "reality" "sni")
        r_pub=$(state_get_field "reality" "public_key")
        r_sid=$(state_get_field "reality" "short_id")

        r_name="$(node_name VLESS-Reality)"
        r_enc_name=$(urlencode "$r_name")
        r_link="vless://${r_uuid}@${host_ip}:${r_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${r_sni}&fp=chrome&pbk=${r_pub}&sid=${r_sid}&type=tcp#${r_enc_name}"
        echo "$r_link" >> "$links_file"

        ui_node_card "${r_name}" "TCP · ${r_port} · ${r_sni}" "${r_link}"

        cat <<EOF >> "$mihomo_file"
  - name: $(yaml_quote "$r_name")
    type: vless
    server: $(yaml_quote "$ip")
    port: ${r_port}
    uuid: $(yaml_quote "$r_uuid")
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $(yaml_quote "$r_sni")
    reality-opts:
      public-key: $(yaml_quote "$r_pub")
      short-id: $(yaml_quote "$r_sid")
    client-fingerprint: chrome
EOF

        sb_outbounds=$( echo "$sb_outbounds" | jq \
            --arg name "$r_name" --arg srv "$ip" --argjson port "$r_port" --arg uuid "$r_uuid" \
            --arg sni "$r_sni" --arg pub "$r_pub" --arg sid "$r_sid" '. + [{
            type: "vless",
            tag: $name,
            server: $srv,
            server_port: $port,
            uuid: $uuid,
            flow: "xtls-rprx-vision",
            packet_encoding: "xudp",
            tls: {
                enabled: true,
                server_name: $sni,
                utls: { enabled: true, fingerprint: "chrome" },
                reality: { enabled: true, public_key: $pub, short_id: $sid }
            }
        }]' )
    fi

    if state_has_proto "hysteria2"; then
        local h_port h_pwd h_sni h_ins h_hop h_ins_num h_name h_enc_name h_link
        h_port=$(state_get_field "hysteria2" "port")
        h_pwd=$(state_get_field "hysteria2" "password")
        h_sni=$(state_get_field "hysteria2" "sni")
        h_ins=$(jq -r '.protocols.hysteria2.insecure // false' "$SB_STATE")
        h_hop=$(state_get_field "hysteria2" "hop_range")
        h_ins_num=$([[ "$h_ins" == "true" ]] && echo 1 || echo 0)

        h_name="$(node_name Hysteria2)"
        h_enc_name=$(urlencode "$h_name")
        local h_mport=""
        [[ -n "$h_hop" ]] && h_mport="&mport=${h_hop/:/-}"
        h_link="hysteria2://$(urlencode "$h_pwd")@${host_ip}:${h_port}?sni=${h_sni}&insecure=${h_ins_num}${h_mport}#${h_enc_name}"
        echo "$h_link" >> "$links_file"

        ui_node_card "${h_name}" "UDP · ${h_port}${h_hop:+ · Hop $h_hop}" "${h_link}"

        cat <<EOF >> "$mihomo_file"
  - name: $(yaml_quote "$h_name")
    type: hysteria2
    server: $(yaml_quote "$ip")
    port: ${h_port}
    password: $(yaml_quote "$h_pwd")
    sni: $(yaml_quote "$h_sni")
    skip-cert-verify: ${h_ins}
EOF
        [[ -n "$h_hop" ]] && echo "    ports: ${h_hop/:/-}" >> "$mihomo_file"

        sb_outbounds=$( echo "$sb_outbounds" | jq \
            --arg name "$h_name" --arg srv "$ip" --argjson port "$h_port" --arg pwd "$h_pwd" \
            --arg sni "$h_sni" --argjson ins "$h_ins" --arg hop "$h_hop" '. + [({
            type: "hysteria2",
            tag: $name,
            server: $srv,
            server_port: $port,
            password: $pwd,
            tls: { enabled: true, server_name: $sni, insecure: $ins, alpn: ["h3"] }
        } + (if $hop != "" then {server_ports: [$hop]} else {} end))]' )
    fi

    if state_has_proto "tuic"; then
        local t_port t_uuid t_pwd t_sni t_ins t_ins_num t_name t_enc_name t_link
        t_port=$(state_get_field "tuic" "port")
        t_uuid=$(state_get_field "tuic" "uuid")
        t_pwd=$(state_get_field "tuic" "password")
        t_sni=$(state_get_field "tuic" "sni")
        t_ins=$(jq -r '.protocols.tuic.insecure // false' "$SB_STATE")
        t_ins_num=$([[ "$t_ins" == "true" ]] && echo 1 || echo 0)

        t_name="$(node_name TUIC)"
        t_enc_name=$(urlencode "$t_name")
        t_link="tuic://${t_uuid}:$(urlencode "$t_pwd")@${host_ip}:${t_port}?congestion_control=bbr&alpn=h3&sni=${t_sni}&allow_insecure=${t_ins_num}#${t_enc_name}"
        echo "$t_link" >> "$links_file"

        ui_node_card "${t_name}" "UDP · ${t_port} · BBR" "${t_link}"

        cat <<EOF >> "$mihomo_file"
  - name: $(yaml_quote "$t_name")
    type: tuic
    server: $(yaml_quote "$ip")
    port: ${t_port}
    uuid: $(yaml_quote "$t_uuid")
    password: $(yaml_quote "$t_pwd")
    alpn: [h3]
    congestion-controller: bbr
    sni: $(yaml_quote "$t_sni")
    skip-cert-verify: ${t_ins}
    udp-relay-mode: native
EOF

        sb_outbounds=$( echo "$sb_outbounds" | jq \
            --arg name "$t_name" --arg srv "$ip" --argjson port "$t_port" --arg uuid "$t_uuid" \
            --arg pwd "$t_pwd" --arg sni "$t_sni" --argjson ins "$t_ins" '. + [{
            type: "tuic",
            tag: $name,
            server: $srv,
            server_port: $port,
            uuid: $uuid,
            password: $pwd,
            congestion_control: "bbr",
            tls: { enabled: true, server_name: $sni, insecure: $ins, alpn: ["h3"] }
        }]' )
    fi

    if state_has_proto "anytls"; then
        local y_port y_pwd y_sni y_ins y_ins_num y_name y_enc_name y_link
        y_port=$(state_get_field "anytls" "port")
        y_pwd=$(state_get_field "anytls" "password")
        y_sni=$(state_get_field "anytls" "sni")
        y_ins=$(jq -r '.protocols.anytls.insecure // false' "$SB_STATE")
        y_ins_num=$([[ "$y_ins" == "true" ]] && echo 1 || echo 0)

        y_name="$(node_name AnyTLS)"
        y_enc_name=$(urlencode "$y_name")
        y_link="anytls://$(urlencode "$y_pwd")@${host_ip}:${y_port}?sni=${y_sni}&insecure=${y_ins_num}#${y_enc_name}"
        echo "$y_link" >> "$links_file"

        ui_node_card "${y_name}" "TCP · ${y_port} · TLS" "${y_link}"

        cat <<EOF >> "$mihomo_file"
  - name: $(yaml_quote "$y_name")
    type: anytls
    server: $(yaml_quote "$ip")
    port: ${y_port}
password: $(yaml_quote "$y_pwd")
    sni: $(yaml_quote "$y_sni")
    skip-cert-verify: ${y_ins}
EOF

        sb_outbounds=$( echo "$sb_outbounds" | jq \
            --arg name "$y_name" --arg srv "$ip" --argjson port "$y_port" --arg pwd "$y_pwd" \
            --arg sni "$y_sni" --argjson ins "$y_ins" '. + [{
            type: "anytls",
            tag: $name,
            server: $srv,
            server_port: $port,
            password: $pwd,
            tls: { enabled: true, server_name: $sni, insecure: $ins }
        }]' )
    fi

    if state_has_proto "argo"; then
        local a_uuid a_path a_domain a_cfip a_mode a_name a_enc_name a_link
        a_uuid=$(state_get_field "argo" "uuid")
        a_path=$(state_get_field "argo" "path")
        a_domain=$(state_get_field "argo" "domain")
        a_cfip=$(state_get_field "argo" "cf_ip")
                a_mode=$(state_get_field "argo" "mode")

        local -a a_ips
        IFS=',' read -ra a_ips <<< "$a_cfip"
        local a_ip a_uri_host a_idx=0 a_total=${#a_ips[@]}
        local enc_path
        enc_path=$(urlencode_path "$a_path")
        for a_ip in "${a_ips[@]}"; do
            a_uri_host="$a_ip"
            [[ "$a_ip" == *:* ]] && a_uri_host="[${a_ip}]"
            a_idx=$((a_idx+1))
            if (( a_total > 1 )); then
                a_name="$(node_name VLESS-WS "$a_idx")"
            else
                a_name="$(node_name VLESS-WS)"
            fi
            a_enc_name=$(urlencode "$a_name")
            a_link="vless://${a_uuid}@${a_uri_host}:443?encryption=none&security=tls&sni=${a_domain}&fp=chrome&type=ws&host=${a_domain}&path=${enc_path}#${a_enc_name}"
            echo "$a_link" >> "$links_file"

            ui_node_card "${a_name}" "WS · ${a_mode} · ${a_domain}" "${a_link}"

            cat <<EOF >> "$mihomo_file"
  - name: $(yaml_quote "$a_name")
    type: vless
    server: $(yaml_quote "$a_ip")
    port: 443
    uuid: $(yaml_quote "$a_uuid")
    network: ws
    tls: true
    udp: true
    servername: $(yaml_quote "$a_domain")
    client-fingerprint: chrome
    ws-opts:
      path: $(yaml_quote "$a_path")
      headers:
        Host: $(yaml_quote "$a_domain")
EOF

        sb_outbounds=$( echo "$sb_outbounds" | jq \
            --arg name "$a_name" --arg srv "$a_ip" --arg uuid "$a_uuid" \
            --arg dom "$a_domain" --arg path "$a_path" '. + [{
            type: "vless",
            tag: $name,
            server: $srv,
            server_port: 443,
            uuid: $uuid,
            tls: {
                enabled: true,
                server_name: $dom,
                utls: { enabled: true, fingerprint: "chrome" }
            },
            transport: {
                type: "ws",
                path: $path,
                headers: { Host: $dom }
            }
        }]' )
        done
    fi



    echo "$sb_outbounds" | jq '.' > "$sb_client_file"

    echo ""
    ui_top
    ui_line "${GRAY}导出文件已同步落盘${PLAIN}"
    ui_kv "标准链接" "$links_file" "$YELLOW"
    ui_kv "Mihomo" "$mihomo_file" "$YELLOW"
    ui_kv "Sing-box" "$sb_client_file" "$YELLOW"
    ui_bot
}


# Upgrade migration: regenerate legacy exports once if they still contain a SOCKS5 node.
# SOCKS5 inbound credentials remain in state; only stale client-node artifacts are removed.
refresh_legacy_exports() {
    local file
    for file in "${SB_EXPORT_DIR}/links.txt" \
                "${SB_EXPORT_DIR}/mihomo_proxies.yaml" \
                "${SB_EXPORT_DIR}/singbox_outbounds.json"; do
        [[ -f "$file" ]] || continue
        if grep -Eqi 'socks5://|type:[[:space:]]*socks5|"type"[[:space:]]*:[[:space:]]*"socks"' "$file"; then
            log_info "检测到旧版 SOCKS5 节点导出，正在迁移为仅参数管理..."
            export_all_nodes >/dev/null 2>&1 || log_warn "旧版导出迁移失败，请手动打开节点订阅中心重新生成。"
            return 0
        fi
    done
}


# ---------- 节点订阅中心：只读统计（供菜单展示用，不写状态） ----------
# SOCKS5 仅提供手动配置参数，不参与节点导出，因此不计入节点数。
EXPORT_NODE_COUNT=0
EXPORT_PROTO_SUMMARY=""

_export_node_stats() {
    EXPORT_NODE_COUNT=0
    local parts=() p
    for p in reality hysteria2 tuic anytls; do
        if state_has_proto "$p"; then
            EXPORT_NODE_COUNT=$((EXPORT_NODE_COUNT + 1))
            case "$p" in
                reality) parts+=("Reality") ;;
                hysteria2) parts+=("Hy2") ;;
                tuic) parts+=("TUIC") ;;
                anytls) parts+=("AnyTLS") ;;
            esac
        fi
    done
    if state_has_proto "argo"; then
        local cf_ip n=0 a_ip
        cf_ip=$(state_get_field "argo" "cf_ip")
        local -a ips=()
        IFS=',' read -ra ips <<< "$cf_ip"
        for a_ip in "${ips[@]}"; do [[ -n "$a_ip" ]] && n=$((n + 1)); done
        if (( n > 0 )); then
            EXPORT_NODE_COUNT=$((EXPORT_NODE_COUNT + n))
            if (( n > 1 )); then parts+=("Argo×${n}"); else parts+=("Argo"); fi
        else
            parts+=("Argo（地址缺失）")
        fi
    fi
    if (( ${#parts[@]} == 0 )); then
        EXPORT_PROTO_SUMMARY="未安装任何协议"
    else
        local IFS=' · '
        EXPORT_PROTO_SUMMARY="${parts[*]}"
    fi
}

_export_proto_pill() { # $1 协议 → 已安装/未安装药丸（只读）
    if state_has_proto "$1"; then ui_status_pill ok "已安装"; else ui_status_pill stopped "未安装"; fi
}

menu_node_naming() {
    ensure_node_meta
    local cur_prefix stored_custom vendor country host_label auto_prefix naming_src
    cur_prefix=$(get_node_prefix)
    stored_custom=$(jq -r '.meta.custom_prefix // empty' "$SB_STATE" 2>/dev/null || true)
    vendor=$(jq -r '.meta.vendor // empty' "$SB_STATE" 2>/dev/null || true)
    country=$(jq -r '.meta.country // empty' "$SB_STATE" 2>/dev/null || true)
    # 主机名口径与 ensure_node_meta 一致（hostname -s，非法字符剔除，截 16 位）
    host_label=$(hostname -s 2>/dev/null | tr -cd 'A-Za-z0-9-' | cut -c1-16)
    [[ -n "$host_label" ]] || host_label="vps"
    if [[ -n "$vendor" ]]; then
        auto_prefix="$vendor"
    else
        auto_prefix="${country:-ZZ}-${host_label}"
    fi
    if [[ -n "$stored_custom" ]]; then
        naming_src="自定义前缀"
    else
        naming_src="自动探测"
    fi

    ui_menu_head "节点命名规则" "NAMING V3"
    ui_kv "当前前缀" "$cur_prefix" "$GREEN$BOLD"
    ui_kv "命名来源" "$naming_src" "$WHITE"
    ui_kv "厂商探测" "${vendor:-未识别}" "$WHITE"
    ui_kv "国家代码" "${country:-未知}" "$WHITE"
    ui_kv "主机名" "$host_label" "$WHITE"
    ui_kv "自动前缀" "$auto_prefix" "$WHITE"
    ui_kv "客户端预览" "${cur_prefix}-Reality、${cur_prefix}-Hy2" "$WHITE"
    ui_line "格式：知名厂商用厂商名（如 Oracle-Reality）；其他用国家-主机名-协议"
    ui_line "示例：Oracle-Reality · US-RN-Reality · US-RS-Hy2（主机名取 hostname -s）"
    ui_bot
    ui_menu_select "请选择命名方案" 0 \
        "1|自动命名（推荐）|厂商优先；无厂商用国家-主机名-协议" \
        "2|重置为自动命名|恢复自动命名规则" \
        "3|手动设置节点前缀|协议名称由系统自动追加" \
        "4|重新探测国家信息|更新国家代码并重新生成节点名称" \
        "0/q|返回上级菜单|" || return 0
    case "$UI_SEL_KEY" in
        1) reset_node_naming && export_all_nodes ;;
        2)
            reset_node_naming && export_all_nodes
            ;;
        3)
            # 输入组件只换读取方式；空输入跳过、前缀校验仍在 set_custom_node_prefix
            ui_read_text "输入自定义前缀（例如 US-vps01）" || true
            if [[ -n "$UI_INPUT" ]]; then set_custom_node_prefix "$UI_INPUT" && export_all_nodes; fi
            ;;
        4)
            reset_node_naming && ensure_node_meta true && export_all_nodes
            ;;
        *) return ;;
    esac
}

show_export_menu() {
    _export_node_stats
    local argo_txt socks_txt
    if state_has_proto "argo"; then
        local cf_ip n=0 a_ip
        cf_ip=$(state_get_field "argo" "cf_ip")
        local -a _ips=()
        IFS=',' read -ra _ips <<< "$cf_ip"
        for a_ip in "${_ips[@]}"; do [[ -n "$a_ip" ]] && n=$((n + 1)); done
        if (( n > 0 )); then
            argo_txt="$(ui_status_pill ok "${n} 个节点")"
        else
            argo_txt="$(ui_status_pill warn "地址缺失")"
        fi
    else
        argo_txt="$(ui_status_pill stopped "未安装")"
    fi
    if state_has_proto "socks5"; then
        socks_txt="$(ui_status_pill ok "已安装 · 仅参数")"
    else
        socks_txt="$(ui_status_pill stopped "未安装")"
    fi
    ui_menu_head "节点订阅中心" "EXPORT"
    ui_kv "可导出节点" "${EXPORT_NODE_COUNT} 个" "$GREEN$BOLD"
    ui_kv "已安装协议" "$EXPORT_PROTO_SUMMARY" "$WHITE"
    ui_kv2 "Reality" "$(_export_proto_pill reality)" "$WHITE" "Hy2" "$(_export_proto_pill hysteria2)" "$WHITE"
    ui_kv2 "TUIC" "$(_export_proto_pill tuic)" "$WHITE" "AnyTLS" "$(_export_proto_pill anytls)" "$WHITE"
    ui_kv2 "Argo" "$argo_txt" "$WHITE" "SOCKS5" "$socks_txt" "$WHITE"
    ui_line "${GRAY}SOCKS5 仅提供手动配置参数，不参与节点导出${PLAIN}"
    ui_bot
    ui_menu_select "请选择" 0 \
        "1/v|分享链接|Shadowrocket · v2rayN · NekoBox" \
        "2/r|二维码|终端扫码直连" \
        "3/c|Mihomo 配置|Clash.Meta proxies YAML 片段" \
        "4/s|Sing-box 出站|客户端 outbounds JSON" \
        "5/u|在线订阅服务|生成带令牌的 HTTP 订阅地址" \
        "6/p|SOCKS5 代理参数|SOCKS5 无加密，仅供 App 填参数，请勿直连" \
        "0/q|返回主菜单|" || return 0
    local c="$UI_SEL_KEY"
    case "$c" in
        1/v) export_all_nodes; return ;;
        5/u) menu_subscription_service; return ;;
        6/p) show_socks5_params; return ;;
        2/r|3/c|4/s) export_all_nodes >/dev/null 2>&1 ;;
        *) return ;;
    esac
    case "$c" in
        2/r)
            if ! command -v qrencode >/dev/null 2>&1; then
                log_warn "未安装 qrencode，无法生成二维码（apt install qrencode）"
                return
            fi
            local line raw_remark dec_remark
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                raw_remark="${line#*#}"
                dec_remark=$(printf '%b' "${raw_remark//%/\\x}")
                printf '\n  %s%s%s %s%s%s%s\n' "$GREEN" "$UI_ON" "$PLAIN" "$WHITE" "$BOLD" "$dec_remark" "$PLAIN"
                qrencode -t ansiutf8 "$line"
            done < "${SB_EXPORT_DIR}/links.txt"
            ;;
        3/c)
            echo ""
            cat "${SB_EXPORT_DIR}/mihomo_proxies.yaml"
            ;;
        4/s)
            echo ""
            cat "${SB_EXPORT_DIR}/singbox_outbounds.json"
            ;;
    esac
}
