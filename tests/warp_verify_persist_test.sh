#!/usr/bin/env bash
# tests/warp_verify_persist_test.sh — WARP 出口验证状态持久化验证
#
# 背景（2026-11-15 真机实测）：运行 WARP 健康检查 [1/c]，五层全部通过，
# 显示“出口 IP 104.28.195.192，WARP 状态：on”，但返回 WARP 菜单后顶部
# 状态区仍显示“出口验证 ● 未验证”。根因：warp_check() 执行完测试后没有
# 把结果保存到 state，菜单渲染代码写死了“未验证”。
#
# 修复：warp_check 成功时保存 verified_at/verified_ip 到 state，失败时清除；
# 菜单渲染读取验证状态，显示“已验证 <IP>（<时间>前）”。
#
# 测试覆盖：
#   1. _warp_format_ago 时间格式化（刚刚/分钟/小时/天/无效输入/未来时间）
#   2. warp_check 成功（warp=on）后 state 中有 verified_at 和 verified_ip
#   3. warp_check 失败（warp=off）后 verified_at/verified_ip 被清除
#   4. warp_check 失败（curl 超时）后验证状态被清除
#   5. UNKNOWN（无 SOCKS5）时不改动已有的验证状态
#   6. UNKNOWN（分流列表为空）时不改动已有的验证状态
#   7. 服务未运行时清除验证状态（返回 2）
#   8. _warp_menu_status 能读取验证状态到 WARP_M_VERIFIED_* 变量
#   9. 菜单渲染逻辑：已验证时显示 IP 和相对时间；无验证时显示未验证；
#      SOCKS5 未装/分流为空时“无法验证”优先于旧的已验证状态
#  10. 卸载 WARP 后验证状态随 state_del_proto 一并清除
#
# 用法：bash tests/warp_verify_persist_test.sh
set -u
cd "$(dirname "$0")/.." || exit 1
APP_HOME="$PWD"
export APP_HOME

TEST_ETC=$(mktemp -d)
FAKE_BIN=$(mktemp -d)
export SB_ETC="$TEST_ETC"
export SB_CONFIG="$TEST_ETC/config.json"
export SB_STATE="$TEST_ETC/state.json"
export SB_BIN="${SB_BIN:-/tmp/sb_test/sing-box-1.14.4-linux-amd64/sing-box}"
export FAKE_CURL_PROBE="$TEST_ETC/curl_probe.log"
export FAKE_CURL_MODE="warp_on"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

cleanup() { rm -rf "$TEST_ETC" "$FAKE_BIN"; }
trap cleanup EXIT

# --- 模拟 systemctl ---
SERVICE_ACTIVE=1
systemctl() {
    case "$1" in
        is-active) [[ $SERVICE_ACTIVE -eq 1 ]] ;;
        reload|restart) SERVICE_ACTIVE=1; return 0 ;;
        enable) return 0 ;;
        *) return 0 ;;
    esac
}
export -f systemctl

# --- 伪造 curl（timeout 调用外部命令，shell 函数 mock 无效，必须用 PATH 中的可执行文件） ---
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_CURL_MODE:-warp_on}" in
    warp_on)
        printf 'fl=1\nip=104.28.195.192\nwarp=on\n'
        ;;
    warp_off)
        printf 'fl=1\nip=107.175.220.79\nwarp=off\n'
        ;;
    fail)
        exit 7
        ;;
esac
exit 0
EOF
chmod +x "$FAKE_BIN/curl"
export PATH="$FAKE_BIN:$PATH"

# shellcheck source=/dev/null
source core/env.sh
# shellcheck source=/dev/null
source core/ui.sh
# shellcheck source=/dev/null
source core/state_manager.sh
# shellcheck source=/dev/null
source core/json_builder.sh
# shellcheck source=/dev/null
source protocols/warp.sh

# 覆盖 env.sh 硬编码的 SB_*（必须在 source 之后）
export SB_ETC="$TEST_ETC"
export SB_CONFIG="$TEST_ETC/config.json"
export SB_STATE="$TEST_ETC/state.json"

# --- 构造最小可用环境：WARP 端点 + SOCKS5 + 分流域名 ---
# 按 warp_healthcheck_fix_test.sh 的模式：init_state_file + state_set_proto
# （手写 state.json 易缺 installed_protocols 等字段，触发“状态文件损坏”）
setup_env() {
    # 注意：默认值含双引号时不能写 ${1:-["a","b"]}，bash 会吃掉内层引号
    # 生成无效 JSON；必须先存入变量再做默认展开（同 ${3:-{}} 裸大括号教训）
    local default_domains='["ai.google.dev","gemini.google.com"]'
    local domains_json="${1:-$default_domains}"
    SERVICE_ACTIVE=1
    rm -f "$SB_CONFIG" "$SB_STATE"
    cp templates/base.json "$SB_CONFIG"
    init_state_file
    # 生成真实有效的 WireGuard 私钥（32 字节 base64，44 字符）
    local priv_key endpoint_json
    priv_key=$(openssl rand 32 | base64 -w0)
    state_set_proto "warp" "$(jq -n --arg pk "$priv_key" '{private_key: $pk, address_v4: "172.16.0.2/32", address_v6: "2606:4700:110:8004:b8fa:5f36:4a38:8535/128", reserved: [73,214,142], domains: []}')"
    state_set_proto "socks5" '{"port":36148,"username":"sg","password":"testpass123"}'
    endpoint_json=$(jq -n --arg pk "$priv_key" '{type: "wireguard", tag: "warp", address: ["172.16.0.2/32", "2606:4700:110:8004:b8fa:5f36:4a38:8535/128"], private_key: $pk, peers: [{address: "162.159.192.1", port: 2408, public_key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", allowed_ips: ["0.0.0.0/0", "::/0"], reserved: [73,214,142]}], mtu: 1280}')
    apply_endpoint "add" "warp" "$endpoint_json" >/dev/null 2>&1
    warp_set_domains "$domains_json" >/dev/null 2>&1 || true
}

get_verified_at() { state_get_field "warp" "verified_at" 2>/dev/null || true; }
get_verified_ip() { state_get_field "warp" "verified_ip" 2>/dev/null || true; }

echo "== 1. _warp_format_ago 时间格式化 =="
now=$(date +%s)
check "刚刚（0 秒前）"   '[[ "$(_warp_format_ago "$now")" == "刚刚" ]]'
check "刚刚（30 秒前）"  '[[ "$(_warp_format_ago "$((now-30))")" == "刚刚" ]]'
check "1 分钟前"         '[[ "$(_warp_format_ago "$((now-60))")" == "1 分钟前" ]]'
check "5 分钟前"         '[[ "$(_warp_format_ago "$((now-300))")" == "5 分钟前" ]]'
check "59 分钟前"        '[[ "$(_warp_format_ago "$((now-3540))")" == "59 分钟前" ]]'
check "1 小时前"         '[[ "$(_warp_format_ago "$((now-3600))")" == "1 小时前" ]]'
check "2 小时前"         '[[ "$(_warp_format_ago "$((now-7200))")" == "2 小时前" ]]'
check "23 小时前"        '[[ "$(_warp_format_ago "$((now-82800))")" == "23 小时前" ]]'
check "1 天前"           '[[ "$(_warp_format_ago "$((now-86400))")" == "1 天前" ]]'
check "3 天前"           '[[ "$(_warp_format_ago "$((now-259200))")" == "3 天前" ]]'
check "无效输入返回刚刚" '[[ "$(_warp_format_ago "abc")" == "刚刚" ]]'
check "空输入返回刚刚"   '[[ "$(_warp_format_ago "")" == "刚刚" ]]'
check "未来时间返回刚刚" '[[ "$(_warp_format_ago "$((now+3600))")" == "刚刚" ]]'

echo "== 2. warp_check 成功后保存验证状态 =="
setup_env
export FAKE_CURL_MODE="warp_on"
warp_check >/dev/null 2>&1
rc=$?
check "warp=on 时返回 0" '[[ $rc -eq 0 ]]'
check "verified_at 已保存（非空数字）" '[[ "$(get_verified_at)" =~ ^[0-9]+$ ]]'
check "verified_ip 为 Cloudflare IP" '[[ "$(get_verified_ip)" == "104.28.195.192" ]]'
check "verified_at 接近当前时间（5 秒内）" '[[ $(( $(date +%s) - $(get_verified_at) )) -le 5 ]]'

echo "== 3. warp_check 失败（warp=off）后清除验证状态 =="
# 先制造一个已验证状态，再跑失败的检查
_warp_save_verification "104.28.195.192"
check "预置验证状态成功" '[[ -n "$(get_verified_at)" ]]'
export FAKE_CURL_MODE="warp_off"
warp_check >/dev/null 2>&1
rc=$?
check "warp=off 时返回 3" '[[ $rc -eq 3 ]]'
check "verified_at 已清除" '[[ -z "$(get_verified_at)" ]]'
check "verified_ip 已清除" '[[ -z "$(get_verified_ip)" ]]'

echo "== 4. warp_check 失败（curl 超时）后清除验证状态 =="
_warp_save_verification "104.28.195.192"
export FAKE_CURL_MODE="fail"
warp_check >/dev/null 2>&1
rc=$?
check "curl 失败时返回 3" '[[ $rc -eq 3 ]]'
check "verified_at 已清除" '[[ -z "$(get_verified_at)" ]]'
check "verified_ip 已清除" '[[ -z "$(get_verified_ip)" ]]'

echo "== 5. UNKNOWN（无 SOCKS5）时不改动已有验证状态 =="
setup_env
_warp_save_verification "104.28.195.192"
saved_at=$(get_verified_at)
# 删除 SOCKS5 状态
state_del_proto "socks5" >/dev/null 2>&1
export FAKE_CURL_MODE="warp_on"
warp_check >/dev/null 2>&1
rc=$?
check "无 SOCKS5 时返回 4（UNKNOWN）" '[[ $rc -eq 4 ]]'
check "verified_at 保持不变" '[[ "$(get_verified_at)" == "$saved_at" ]]'
check "verified_ip 保持不变" '[[ "$(get_verified_ip)" == "104.28.195.192" ]]'

echo "== 6. UNKNOWN（分流列表为空）时不改动已有验证状态 =="
setup_env '[]'
_warp_save_verification "104.28.195.192"
saved_at=$(get_verified_at)
export FAKE_CURL_MODE="warp_on"
warp_check >/dev/null 2>&1
rc=$?
check "分流为空时返回 4（UNKNOWN）" '[[ $rc -eq 4 ]]'
check "verified_at 保持不变" '[[ "$(get_verified_at)" == "$saved_at" ]]'
check "verified_ip 保持不变" '[[ "$(get_verified_ip)" == "104.28.195.192" ]]'

echo "== 7. 服务未运行时清除验证状态 =="
setup_env
_warp_save_verification "104.28.195.192"
SERVICE_ACTIVE=0
warp_check >/dev/null 2>&1
rc=$?
check "服务未运行时返回 2" '[[ $rc -eq 2 ]]'
check "verified_at 已清除" '[[ -z "$(get_verified_at)" ]]'
check "verified_ip 已清除" '[[ -z "$(get_verified_ip)" ]]'
SERVICE_ACTIVE=1

echo "== 8. _warp_menu_status 读取验证状态 =="
setup_env
_warp_save_verification "104.28.195.192"
_warp_menu_status
check "WARP_M_VERIFIED_AT 非空" '[[ -n "$WARP_M_VERIFIED_AT" ]]'
check "WARP_M_VERIFIED_IP 正确" '[[ "$WARP_M_VERIFIED_IP" == "104.28.195.192" ]]'
# 清除后重新读取
_warp_clear_verification
_warp_menu_status
check "清除后 WARP_M_VERIFIED_AT 为空" '[[ -z "$WARP_M_VERIFIED_AT" ]]'
check "清除后 WARP_M_VERIFIED_IP 为空" '[[ -z "$WARP_M_VERIFIED_IP" ]]'

echo "== 9. 菜单渲染逻辑（verify_txt 构造） =="
# 复现 menu_warp 中 verify_txt 的构造逻辑，验证各分支输出
render_verify_txt() {
    local verify_txt
    if ! state_has_proto "socks5"; then
        verify_txt="$(ui_status_pill warn "无法验证") 未安装 SOCKS5，无法探测出口"
    elif (( WARP_M_DOMAINS == 0 )); then
        verify_txt="$(ui_status_pill warn "无法验证") 分流列表为空，无域名可测试"
    elif [[ -n "$WARP_M_VERIFIED_AT" && -n "$WARP_M_VERIFIED_IP" ]]; then
        verify_txt="$(ui_status_pill ok "已验证") ${WARP_M_VERIFIED_IP}（$(_warp_format_ago "$WARP_M_VERIFIED_AT")）"
    else
        verify_txt="$(ui_status_pill warn "未验证") 选 [1/c] 检测实时出口"
    fi
    printf '%s' "$verify_txt"
}
setup_env
_warp_save_verification "104.28.195.192"
_warp_menu_status
txt=$(render_verify_txt)
check "已验证时显示 IP" '[[ "$txt" == *"104.28.195.192"* ]]'
check "已验证时显示相对时间" '[[ "$txt" == *"刚刚"* ]]'
check "已验证时含已验证字样" '[[ "$txt" == *"已验证"* ]]'
# 无验证状态
_warp_clear_verification
_warp_menu_status
txt=$(render_verify_txt)
check "无验证时显示未验证" '[[ "$txt" == *"未验证"* ]]'
check "无验证时提示检测" '[[ "$txt" == *"[1/c]"* ]]'
# 旧验证 + SOCKS5 被删：无法验证优先
_warp_save_verification "104.28.195.192"
state_del_proto "socks5" >/dev/null 2>&1
_warp_menu_status
txt=$(render_verify_txt)
check "无 SOCKS5 时无法验证优先于旧验证" '[[ "$txt" == *"无法验证"* && "$txt" != *"已验证"* ]]'
# 旧验证 + 分流被清空：无法验证优先
setup_env '[]'
_warp_save_verification "104.28.195.192"
_warp_menu_status
txt=$(render_verify_txt)
check "分流为空时无法验证优先于旧验证" '[[ "$txt" == *"无法验证"* && "$txt" != *"已验证"* ]]'
# 旧验证 + 5 分钟前的时间显示
setup_env
state_set_field "warp" "verified_at" "$(( $(date +%s) - 300 ))" 2>/dev/null
state_set_field "warp" "verified_ip" "104.28.195.192" 2>/dev/null
_warp_menu_status
txt=$(render_verify_txt)
check "5 分钟前的验证显示 5 分钟前" '[[ "$txt" == *"5 分钟前"* ]]'

echo "== 10. 卸载 WARP 后验证状态清除 =="
setup_env
_warp_save_verification "104.28.195.192"
check "卸载前验证状态存在" '[[ -n "$(get_verified_at)" ]]'
uninstall_warp >/dev/null 2>&1
check "卸载后 warp 段已删除" '! state_has_proto "warp"'
check "卸载后 verified_at 为空" '[[ -z "$(get_verified_at)" ]]'

echo ""
echo "=============================="
echo "WARP VERIFY PERSIST TEST SUMMARY: PASS=$PASS FAIL=$FAIL"
echo "=============================="
[[ $FAIL -eq 0 ]]
