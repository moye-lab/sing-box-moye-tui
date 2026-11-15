#!/usr/bin/env bash

get_installed_sb_version() {
    if [[ -x "$SB_BIN" ]]; then
        "$SB_BIN" version | awk '/sing-box version/ {print $3}'
    else
        echo "未安装"
    fi
}

write_singbox_unit() {
    # 原子替换：先写临时文件，再 mv 覆盖，避免中途失败留下半写文件
    local tmp_unit
    tmp_unit=$(mktemp /etc/systemd/system/sing-box.service.XXXXXX) || return 1
    chmod 644 "$tmp_unit"
    cat > "$tmp_unit" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
UMask=0077
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_DAC_READ_SEARCH
NoNewPrivileges=true
ExecStart="${SB_BIN}" run -c "${SB_CONFIG}"
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s
KillSignal=SIGINT
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    if ! mv -f "$tmp_unit" /etc/systemd/system/sing-box.service; then
        rm -f "$tmp_unit"
        return 1
    fi
    return 0
}

install_singbox_core() {
    local target_ver="${1:-latest}" arch release_tag
    arch=$(detect_arch) || return 1

    # 升级锁：防止多终端同时升级（超时 5 分钟）
    # 使用 /run/lock（tmpfs，重启自动清理），不用 /tmp 固定路径（防符号链接攻击）
    local upgrade_lock="/run/lock/sbx-upgrade.lock"
    mkdir -p /run/lock 2>/dev/null || { log_err "无法创建 /run/lock 目录"; return 1; }
    # 检查锁文件类型：拒绝符号链接
    if [[ -L "$upgrade_lock" ]]; then
        log_err "升级锁文件是符号链接，拒绝操作（可能遭受攻击）。"
        return 1
    fi
    exec 201>"$upgrade_lock" 2>/dev/null || return 1
    chmod 600 "$upgrade_lock" 2>/dev/null || true
    if ! flock -w 300 -x 201 2>/dev/null; then
        log_err "获取升级锁超时（5 分钟），可能有其他进程正在升级。"
        exec 201>&- 2>/dev/null || true
        return 1
    fi
    # 函数退出时释放锁（fd 关闭自动释放 flock）
    trap 'exec 201>&- 2>/dev/null; trap - RETURN' RETURN

    # 磁盘空间检查：至少需要 100MB 可用空间
    local avail_kb
    avail_kb=$(df -k /usr/local/bin 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -n "$avail_kb" && "$avail_kb" -lt 102400 ]]; then
        log_err "磁盘空间不足：/usr/local/bin 可用空间仅 $((avail_kb / 1024))MB，需要至少 100MB。"
        return 1
    fi

    log_info "正在查询 Sing-box (${target_ver}) 版本信息..."
    if [[ "$target_ver" == "latest" ]]; then
        release_tag=$(curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 30 \
            https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name // empty')
    else
        release_tag="$target_ver"
    fi
    if [[ ! "$release_tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
        log_err "Sing-box 版本号无效或获取失败：${release_tag:-空值}"
        return 1
    fi

    local ver_num="${release_tag#v}"
    local pkg_name="sing-box-${ver_num}-linux-${arch}"
    local url="https://github.com/SagerNet/sing-box/releases/download/${release_tag}/${pkg_name}.tar.gz"
    local checksum_url="https://github.com/SagerNet/sing-box/releases/download/${release_tag}/checksums.txt"
    local tmp_dir new_bin
    tmp_dir=$(mktemp -d) || return 1

    log_info "正在下载: ${url}"
    if ! download_file "$url" "${tmp_dir}/sb.tar.gz"; then
        log_err "下载 Sing-box 失败！"
        rm -rf "$tmp_dir"; return 1
    fi

    # SHA256 完整性校验：从官方 Release 下载 checksums.txt 并验证
    # 失败即终止，不允许跳过校验作为降级方案（供应链安全硬要求）
    log_info "正在验证安装包完整性 (SHA256) ..."
    if ! download_file "$checksum_url" "${tmp_dir}/checksums.txt" 2>/dev/null; then
        log_err "无法下载 checksums.txt，拒绝安装（无法验证安装包完整性）。"
        rm -rf "$tmp_dir"; return 1
    fi
    local expected_sha actual_sha match_count
    match_count=$(grep -c "${pkg_name}.tar.gz" "${tmp_dir}/checksums.txt" 2>/dev/null || echo 0)
    if [[ "$match_count" -ne 1 ]]; then
        log_err "checksums.txt 中 ${pkg_name}.tar.gz 的校验值不唯一（找到 $match_count 条），拒绝安装。"
        rm -rf "$tmp_dir"; return 1
    fi
    expected_sha=$(grep "${pkg_name}.tar.gz" "${tmp_dir}/checksums.txt" 2>/dev/null | awk '{print $1}')
    if [[ -z "$expected_sha" ]]; then
        log_err "checksums.txt 中未找到 ${pkg_name}.tar.gz 的校验值，拒绝安装。"
        rm -rf "$tmp_dir"; return 1
    fi
    if [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
        log_err "校验值格式无效（非 64 位十六进制），拒绝安装。"
        rm -rf "$tmp_dir"; return 1
    fi
    actual_sha=$(sha256sum "${tmp_dir}/sb.tar.gz" 2>/dev/null | awk '{print $1}')
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        log_err "SHA256 校验失败！安装包可能被篡改，已拒绝安装。"
        log_err "期望: $expected_sha"
        log_err "实际: ${actual_sha:-无法计算}"
        rm -rf "$tmp_dir"; return 1
    fi
    log_info "SHA256 校验通过。"

    if ! tar -tzf "${tmp_dir}/sb.tar.gz" >/dev/null 2>&1; then
        log_err "下载文件不是有效的 tar.gz 压缩包。"
        rm -rf "$tmp_dir"
        return 1
    fi
    local archive_members
    archive_members=$(tar -tzf "${tmp_dir}/sb.tar.gz") || {
        log_err "无法读取压缩包目录。"; rm -rf "$tmp_dir"; return 1;
    }
    while IFS= read -r member; do
        if [[ "$member" == /* || "$member" =~ (^|/)\.\.(/|$) || "$member" != "${pkg_name}/"* ]]; then
            log_err "压缩包包含不安全或非预期路径，已拒绝解压。"
            rm -rf "$tmp_dir"
            return 1
        fi
    done <<< "$archive_members"
    # Only regular files/directories are accepted; reject symlinks and hardlinks
    # to prevent archive entries from redirecting extraction outside the temp dir.
    if ! tar -tvzf "${tmp_dir}/sb.tar.gz" | awk 'substr($1,1,1) != "-" && substr($1,1,1) != "d" { bad=1 } END { exit bad }'; then
        log_err "压缩包包含链接或特殊文件，已拒绝解压。"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! tar -xzf "${tmp_dir}/sb.tar.gz" --no-same-owner --no-same-permissions -C "$tmp_dir"; then
        log_err "Sing-box 压缩包解压失败。"
        rm -rf "$tmp_dir"
        return 1
    fi
    new_bin="${tmp_dir}/${pkg_name}/sing-box"
    if [[ ! -f "$new_bin" || -L "$new_bin" ]]; then
        log_err "压缩包内容异常，未找到 sing-box 可执行文件。"
        rm -rf "$tmp_dir"; return 1
    fi
    chmod +x "$new_bin"

    # 验证版本号与目标一致，架构匹配
    local actual_ver
    actual_ver=$("$new_bin" version 2>/dev/null | awk '/sing-box version/ {print $3}')
    if [[ -z "$actual_ver" ]]; then
        log_err "无法执行新内核或获取版本号，可能是架构不匹配。"
        rm -rf "$tmp_dir"; return 1
    fi
    if [[ "$actual_ver" != "$ver_num" ]]; then
        log_err "版本号不匹配：期望 $ver_num，实际 $actual_ver，已拒绝安装。"
        rm -rf "$tmp_dir"; return 1
    fi
    log_info "版本验证通过：sing-box $actual_ver"

    # 用新版本校验现有配置，不通过则不升级
    if [[ -s "$SB_CONFIG" ]] && ! "$new_bin" check -c "$SB_CONFIG" >/dev/null 2>&1; then
        log_err "新版内核无法通过现有配置校验，已取消升级："
        "$new_bin" check -c "$SB_CONFIG" || true
        rm -rf "$tmp_dir"; return 1
    fi

    if [[ -x "$SB_BIN" ]]; then
        install -m 700 "$SB_BIN" "${SB_BIN}.bak" || { rm -rf "$tmp_dir"; return 1; }
    fi
    # 备份 systemd 服务文件
    local unit_file="/etc/systemd/system/sing-box.service"
    local unit_bak="${unit_file}.bak"
    if [[ -f "$unit_file" ]]; then
        cp -f "$unit_file" "$unit_bak" 2>/dev/null || true
    fi
    if ! install -m 755 "$new_bin" "$SB_BIN"; then
        log_err "安装新内核文件失败，保留原版本。"
        [[ -f "${SB_BIN}.bak" ]] && install -m 755 "${SB_BIN}.bak" "$SB_BIN"
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"

    if ! ensure_base_config || ! init_state_file; then
        log_err "初始化配置或状态失败，正在回滚内核。"
        [[ -f "${SB_BIN}.bak" ]] && install -m 755 "${SB_BIN}.bak" "$SB_BIN"
        [[ -f "$unit_bak" ]] && cp -f "$unit_bak" "$unit_file" 2>/dev/null || true
        return 1
    fi
    if ! write_singbox_unit; then
        log_err "写入 systemd 服务文件失败，正在回滚。"
        [[ -f "${SB_BIN}.bak" ]] && install -m 755 "${SB_BIN}.bak" "$SB_BIN"
        [[ -f "$unit_bak" ]] && cp -f "$unit_bak" "$unit_file" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        return 1
    fi
    if ! systemctl daemon-reload; then
        log_err "systemctl daemon-reload 失败，正在回滚。"
        [[ -f "${SB_BIN}.bak" ]] && install -m 755 "${SB_BIN}.bak" "$SB_BIN"
        [[ -f "$unit_bak" ]] && cp -f "$unit_bak" "$unit_file" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        return 1
    fi
    systemctl enable sing-box >/dev/null 2>&1 || true

    # 首次安装也必须启动并验证服务；升级时同样验证失败回滚。
    if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
        log_err "新内核启动失败，正在回滚旧版本..."
        if [[ -f "${SB_BIN}.bak" ]]; then
            install -m 755 "${SB_BIN}.bak" "$SB_BIN"
            [[ -f "$unit_bak" ]] && cp -f "$unit_bak" "$unit_file" 2>/dev/null || true
            systemctl daemon-reload 2>/dev/null || true
            systemctl restart sing-box || true
        else
            rm -f "$SB_BIN"
        fi
        return 1
    fi
    rm -f "${SB_BIN}.bak" "$unit_bak"
    log_ok "Sing-box 内核 (${release_tag}) 安装完成！"
}

ensure_singbox_installed() {
    if [[ ! -x "$SB_BIN" ]]; then
        log_warn "检测到尚未安装 Sing-box 内核，正在自动安装最新正式版..."
        install_singbox_core "latest" || return 1
    fi
}

uninstall_all() {
    # 管理脚本自身是否删除，取决于标准安装路径判定（与下方执行共用同一条件）：
    # 仅当 APP_HOME 为 /usr/local/etc/sbx 且 /usr/local/bin/sbx 为符号链接时才删除。
    local _sbx_self=0
    if [[ "$APP_HOME" == "/usr/local/etc/sbx" && -L /usr/local/bin/sbx ]]; then
        _sbx_self=1
    fi

    # ---- 危险操作页面：删除清单与保留清单，与下方执行代码逐项对应 ----
    ui_menu_head "彻底卸载" "UNINSTALL"
    ui_section "将删除以下内容" "此操作不可恢复"
    ui_line "${RED}✖${PLAIN} 端口跳跃规则与服务单元 sbx-hop.service（如已配置）"
    ui_line "${RED}✖${PLAIN} 订阅服务单元 /etc/systemd/system/sbx-subscription.service"
    ui_line "${RED}✖${PLAIN} sing-box 服务单元 /etc/systemd/system/sing-box.service"
    ui_line "${RED}✖${PLAIN} cloudflared 服务单元 cloudflared-sb.service"
    ui_line "${RED}✖${PLAIN} cloudflared 日志 /var/log/cloudflared-sb.log"
    ui_line "${RED}✖${PLAIN} 内核二进制 ${SB_BIN}"
    ui_line "${RED}✖${PLAIN} 内核备份 ${SB_BIN}.bak"
    ui_line "${RED}✖${PLAIN} cloudflared 二进制 ${CF_BIN}"
    ui_line "${RED}✖${PLAIN} 配置目录 ${SB_ETC}"
    ui_line "  ${GRAY}（含配置、状态、证书、导出文件）${PLAIN}"
    ui_line "${RED}✖${PLAIN} 调优参数文件 /etc/sysctl.d/99-singbox-tune.conf（如存在）"
    if (( _sbx_self )); then
        ui_line "${RED}✖${PLAIN} 管理脚本 /usr/local/bin/sbx 与 ${APP_HOME}"
    fi
    ui_mid
    ui_section "将保留" ""
    if (( _sbx_self )); then
        ui_line "${GREEN}✔${PLAIN} 其他系统文件与用户数据（本次卸载不触碰）"
    else
        ui_line "${GREEN}✔${PLAIN} 管理脚本 sbx（非标准安装路径，本次不删除）"
        ui_line "${GREEN}✔${PLAIN} 其他系统文件与用户数据（本次卸载不触碰）"
    fi
    ui_bot

    # 确认强度与改前一致：单次确认，默认取消（空输入/EOF 均为取消）。
    # ui_dialog_confirm 即改前 ui_confirm 的底层实现（dialog.sh）。
    if ! ui_dialog_confirm "确定要彻底卸载 Sing-box 及其所有配置吗？此操作不可恢复！"; then
        log_info "已取消卸载。"
        return
    fi

    # ---- 执行：删除命令、文件列表与顺序与改前完全一致 ----
    # 仅增加阶段展示与返回值记录：原先 || true 的地方改为 || _rc=1（失败仍继续，
    # 行为不变），原先裸命令的地方追加 || _rc=1（本项目无 set -e，失败本来就继续）。
    # 每阶段按真实返回值报告成功/失败，不虚构成功。
    local _s1_rc=0 _s2_rc=0 _s3_rc=0
    ui_stage 1 4 "正在停止服务并移除服务单元..."
    remove_port_hopping >/dev/null 2>&1 || _s1_rc=1
    systemctl disable --now sbx-subscription.service 2>/dev/null || _s1_rc=1
    rm -f /etc/systemd/system/sbx-subscription.service || _s1_rc=1
    systemctl stop sing-box 2>/dev/null || _s1_rc=1
    systemctl disable sing-box 2>/dev/null || _s1_rc=1
    rm -f /etc/systemd/system/sing-box.service || _s1_rc=1
    systemctl stop cloudflared-sb 2>/dev/null || _s1_rc=1
    systemctl disable cloudflared-sb 2>/dev/null || _s1_rc=1
    rm -f /etc/systemd/system/cloudflared-sb.service /var/log/cloudflared-sb.log || _s1_rc=1
    if (( _s1_rc == 0 )); then
        log_ok "服务已停止，服务单元已移除。"
    else
        log_warn "部分服务命令返回失败（服务可能未安装或已停止），继续卸载。"
    fi

    ui_stage 2 4 "正在删除内核、配置与调优文件..."
    systemctl daemon-reload || _s2_rc=1
    rm -f "$SB_BIN" "${SB_BIN}.bak" "$CF_BIN" || _s2_rc=1
    rm -rf "$SB_ETC" || _s2_rc=1
    if [[ -f /etc/sysctl.d/99-singbox-tune.conf ]]; then
        rm -f /etc/sysctl.d/99-singbox-tune.conf || _s2_rc=1
        sysctl --system >/dev/null 2>&1 || _s2_rc=1
    fi
    if (( _s2_rc == 0 )); then
        log_ok "内核、配置与调优文件已删除。"
    else
        log_warn "部分删除命令返回失败，请检查上方输出。"
    fi

    ui_stage 3 4 "正在清理管理脚本..."
    if (( _sbx_self )); then
        rm -f /usr/local/bin/sbx || _s3_rc=1
        # 函数体已在内存中，删目录后立即 exit 无需再读脚本文件
        rm -rf "$APP_HOME" || _s3_rc=1
        if (( _s3_rc == 0 )); then
            log_ok "管理脚本已清理。"
        else
            log_warn "管理脚本清理命令返回失败。"
        fi
    else
        log_info "非标准安装路径，保留管理脚本。"
    fi

    ui_stage 4 4 "完成"
    if (( _sbx_self )); then
        log_ok "Sing-box、相关配置与管理脚本已彻底清理。"
    else
        log_ok "Sing-box 与相关配置已彻底清理。"
    fi
    exit 0
}
