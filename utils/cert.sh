#!/usr/bin/env bash

generate_self_signed_cert() {
    local domain="${1:-www.bing.com}"
    local cert_path="${SB_CERT_DIR}/self_${domain}.pem"
    local key_path="${SB_CERT_DIR}/self_${domain}.key"
    mkdir -p "$SB_CERT_DIR"

    if [[ -s "$cert_path" && -s "$key_path" ]]; then
        log_info "复用已有自签证书: ${cert_path}"
        return 0
    fi

    log_info "正在生成 ECC (prime256v1) 自签名证书 (域名: ${domain})..."
    openssl ecparam -genkey -name prime256v1 -out "$key_path" 2>/dev/null || return 1
    if ! openssl req -new -x509 -days 3650 -key "$key_path" -out "$cert_path" \
        -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1; then
        rm -f "$cert_path" "$key_path"
        log_err "自签证书生成失败"
        return 1
    fi
    chmod 600 "$key_path"
    chmod 644 "$cert_path"
    log_ok "自签名证书已生成: ${cert_path}"
}

issue_acme_cert() {
    local domain="$1"
    local acme="$HOME/.acme.sh/acme.sh"
    local cert_path="${SB_CERT_DIR}/${domain}.pem"
    local key_path="${SB_CERT_DIR}/${domain}.key"
    mkdir -p "$SB_CERT_DIR"

    if is_port_used 80; then
        log_err "80 端口已被占用，standalone 模式无法完成验证，请先释放 80 端口。"
        return 1
    fi

    if [[ ! -f "$acme" ]]; then
        log_info "正在安装 acme.sh ..."
        curl -fsSL https://get.acme.sh | sh -s email="admin@${domain}" || return 1
    fi

    log_info "正在通过 HTTP (80端口) 申请域名证书: ${domain} ..."
    local rc=0
    "$acme" --issue -d "$domain" --standalone --keylength ec-256 || rc=$?
    # 返回码 2 表示证书仍在有效期内被跳过，可继续安装
    if [[ $rc -ne 0 && $rc -ne 2 ]]; then
        log_err "证书申请失败 (acme.sh 返回码 $rc)"
        return 1
    fi
    "$acme" --install-cert -d "$domain" --ecc \
        --fullchain-file "$cert_path" \
        --key-file "$key_path" \
        --reloadcmd "systemctl try-restart sing-box" || return 1

    chmod 600 "$key_path"
    chmod 644 "$cert_path"
    log_ok "ACME 证书申请成功（已配置续期后自动重载）: ${cert_path}"
}

select_or_create_cert() {
    # SBX_AUTO=1（一键全装）时免询问：直接生成自签证书
    if [[ -n "${SBX_AUTO:-}" ]]; then
        local sni="www.bing.com"
        generate_self_signed_cert "$sni" >&2 || return 1
        echo "self_signed|${SB_CERT_DIR}/self_${sni}.pem|${SB_CERT_DIR}/self_${sni}.key|${sni}|true"
        return 0
    fi
    echo -e "\n 请选择证书模式:" >&2
    echo "   1. 生成/复用 ECC 自签名证书 (无需域名，客户端开启跳过证书验证)" >&2
    echo "   2. 使用 ACME 申请真实域名证书 (需解析域名并放行 80 端口)" >&2
    echo "   3. 指定已有证书路径" >&2
    local choice
    read -rp " 请输入选项 [默认: 1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        2)
            local domain
            read -rp " 请输入已解析到本机的域名: " domain
            if ! valid_domain_name "$domain"; then
                log_err "域名为空或格式无效！" >&2
                return 1
            fi
            issue_acme_cert "$domain" >&2 || return 1
            echo "acme|${SB_CERT_DIR}/${domain}.pem|${SB_CERT_DIR}/${domain}.key|${domain}|false"
            ;;
        3)
            local c_path k_path sni
            read -rp " 请输入公钥证书路径 (.pem/.crt): " c_path
            read -rp " 请输入私钥文件路径 (.key): " k_path
            read -rp " 请输入对应域名 (SNI): " sni
            if [[ ! -r "$c_path" || ! -r "$k_path" ]] || ! valid_domain_name "$sni"; then
                log_err "证书/私钥文件不可读，或 SNI 域名无效！" >&2
                return 1
            fi
            if ! openssl x509 -in "$c_path" -noout >/dev/null 2>&1 || ! openssl pkey -in "$k_path" -noout >/dev/null 2>&1; then
                log_err "证书或私钥格式无效！" >&2
                return 1
            fi
            local cert_pub key_pub
            cert_pub=$(openssl x509 -in "$c_path" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
            key_pub=$(openssl pkey -in "$k_path" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
            if [[ -z "$cert_pub" || "$cert_pub" != "$key_pub" ]]; then
                log_err "证书与私钥不匹配！" >&2
                return 1
            fi
            echo "custom|${c_path}|${k_path}|${sni}|false"
            ;;
        *)
            local sni
            read -rp " 请输入自签伪装域名 [默认: www.bing.com]: " sni
            sni="${sni:-www.bing.com}"
            if ! valid_domain_name "$sni"; then
                log_err "域名格式无效！" >&2
                return 1
            fi
            generate_self_signed_cert "$sni" >&2 || return 1
            echo "self_signed|${SB_CERT_DIR}/self_${sni}.pem|${SB_CERT_DIR}/self_${sni}.key|${sni}|true"
            ;;
    esac
}
