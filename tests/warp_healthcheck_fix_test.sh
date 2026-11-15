#!/usr/bin/env bash
# tests/warp_healthcheck_fix_test.sh — WARP 健康检查误报修复验证
#
# 背景（2026-11-15 真机实测）：WARP 已安装、分流规则已应用（28 个 AI
# 域名），运行健康检查 [1/c] 时第 5 层报"出口 IP 不是 Cloudflare，
# WARP 状态：off"。根因：warp_check 第 5 层读取了 test_domain 却未使用，
# 硬编码测试 https://www.cloudflare.com/cdn-cgi/trace，而
# www.cloudflare.com 不在分流列表中，流量走直连，必然返回原生 IP。
#
# 修复：测试前将 www.cloudflare.com 临时加入分流列表，测试后恢复原列表。
#
# 测试覆盖：
#   1. warp=on 时健康检查返回 0，且测试期间 trace 域名在分流规则内
#   2. warp=off 时返回 3（真实不通，非测试方法误报），列表恢复
#   3. curl 失败/超时时返回 3，列表恢复
#   4. trace 域名已在列表中时不做临时添加/恢复（无多余重载）
#   5. 28 域名精简模式端到端（用户真实场景）+ 真实 sing-box check/run
#   6. 无分流域名时仍返回 UNKNOWN(4)，不调用 curl
#
# 用法：bash tests/warp_healthcheck_fix_test.sh
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

# --- 模拟 systemctl（带重载计数） ---
SERVICE_ACTIVE=0
RELOAD_COUNT_FILE="$TEST_ETC/reload_count"
: > "$RELOAD_COUNT_FILE"
systemctl() {
    case "$1" in
        is-active) [[ $SERVICE_ACTIVE -eq 1 ]] ;;
        reload|restart) echo "$1" >> "$RELOAD_COUNT_FILE"; SERVICE_ACTIVE=1; return 0 ;;
        enable) return 0 ;;
        *) return 0 ;;
    esac
}
export -f systemctl

reload_count() { wc -l < "$RELOAD_COUNT_FILE" | tr -d ' '; }

# --- 伪造 curl（timeout 调用外部命令，shell 函数 mock 无效，必须用 PATH 中的可执行文件） ---
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
# 记录调用瞬间 www.cloudflare.com 是否在 warp 分流规则内
probe_file="${FAKE_CURL_PROBE:-/tmp/fake_curl_probe}"
if [[ -n "${SB_CONFIG:-}" && -f "$SB_CONFIG" ]]; then
    if jq -e '[.route.rules[]? | select(.outbound == "warp") | .domain_suffix[]?] | index("www.cloudflare.com")' "$SB_CONFIG" >/dev/null 2>&1; then
        echo "TRACE_DOMAIN_IN_RULES=yes" >> "$probe_file"
    else
        echo "TRACE_DOMAIN_IN_RULES=no" >> "$probe_file"
    fi
fi
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
# env.sh 硬设路径，必须强制覆盖（${VAR:-default} 无法覆盖已设的值）
export SB_ETC="$TEST_ETC" SB_CONFIG="$TEST_ETC/config.json" SB_STATE="$TEST_ETC/state.json"
SB_BIN="/tmp/sb_test/sing-box-1.14.4-linux-amd64/sing-box"
export SB_BIN
# shellcheck source=/dev/null
source core/state_manager.sh
# shellcheck source=/dev/null
source core/json_builder.sh
# shellcheck source=/dev/null
source protocols/warp.sh

PASS=0
FAIL=0
assert() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo "PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc"
    fi
}

# --- 准备：最小可用配置 + warp/socks5 状态 ---
cp templates/base.json "$SB_CONFIG"
init_state_file
SERVICE_ACTIVE=1

# 生成真实有效的 WireGuard 私钥（32 字节 base64，44 字符）
PRIV_KEY=$(openssl rand 32 | base64 -w0)
state_set_proto "warp" "$(jq -n --arg pk "$PRIV_KEY" '{private_key: $pk, address_v4: "172.16.0.2/32", address_v6: "2606:4700:110:8004:b8fa:5f36:4a38:8535/128", reserved: [73,214,142], domains: []}')"
state_set_proto "socks5" '{"port":36148,"username":"sg","password":"testpass123"}'
endpoint_json=$(jq -n --arg pk "$PRIV_KEY" '{type: "wireguard", tag: "warp", address: ["172.16.0.2/32", "2606:4700:110:8004:b8fa:5f36:4a38:8535/128"], private_key: $pk, peers: [{address: "162.159.192.1", port: 2408, public_key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", allowed_ips: ["0.0.0.0/0", "::/0"], reserved: [73,214,142]}], mtu: 1280}')
apply_endpoint "add" "warp" "$endpoint_json" >/dev/null 2>&1
assert "测试环境：warp 端点添加成功" jq -e '.endpoints[] | select(.tag=="warp")' "$SB_CONFIG"

ORIG_DOMAINS='["claude.ai","gemini.google.com","openai.com"]'
warp_set_domains "$ORIG_DOMAINS" >/dev/null 2>&1
assert "测试环境：3 个分流域名写入" test "$(jq -c '.protocols.warp.domains' "$SB_STATE")" = "$ORIG_DOMAINS"

# 辅助：当前 state/配置中的分流域名（规范化 JSON）
state_domains() { jq -c '.protocols.warp.domains // []' "$SB_STATE" 2>/dev/null; }
config_domains() { jq -c '[.route.rules[]? | select(.outbound == "warp") | .domain_suffix] | first // []' "$SB_CONFIG" 2>/dev/null; }

echo ""
echo "=== 测试 A: warp=on 时健康检查通过，且 trace 域名临时在规则内 ==="
: > "$FAKE_CURL_PROBE"
export FAKE_CURL_MODE="warp_on"
rc_before=$(reload_count)
out_a=$(warp_check 2>&1); rc_a=$?
rc_after=$(reload_count)
assert "warp=on 返回 0" test "$rc_a" = "0"
assert "输出含 WARP 状态：on" grep -q "WARP 状态：on" <<< "$out_a"
assert "测试期间 trace 域名在分流规则内" grep -q "TRACE_DOMAIN_IN_RULES=yes" "$FAKE_CURL_PROBE"
assert "检查后 state 域名恢复原 3 个" test "$(state_domains)" = "$ORIG_DOMAINS"
assert "检查后配置规则恢复原 3 个域名" test "$(config_domains)" = "$ORIG_DOMAINS"
assert "临时添加+恢复共触发 2 次重载" test "$((rc_after - rc_before))" = "2"

echo ""
echo "=== 测试 B: warp=off 时返回 3（真实不通），列表恢复 ==="
: > "$FAKE_CURL_PROBE"
export FAKE_CURL_MODE="warp_off"
out_b=$(warp_check 2>&1); rc_b=$?
assert "warp=off 返回 3" test "$rc_b" = "3"
assert "输出含 不是 Cloudflare" grep -q "不是 Cloudflare" <<< "$out_b"
assert "测试期间 trace 域名在规则内（阴性结果可信）" grep -q "TRACE_DOMAIN_IN_RULES=yes" "$FAKE_CURL_PROBE"
assert "检查后 state 域名恢复" test "$(state_domains)" = "$ORIG_DOMAINS"
assert "检查后配置规则恢复" test "$(config_domains)" = "$ORIG_DOMAINS"

echo ""
echo "=== 测试 C: curl 失败时返回 3，列表恢复 ==="
: > "$FAKE_CURL_PROBE"
export FAKE_CURL_MODE="fail"
out_c=$(warp_check 2>&1); rc_c=$?
assert "curl 失败返回 3" test "$rc_c" = "3"
assert "输出含 超时或失败" grep -q "超时或失败" <<< "$out_c"
assert "失败后 state 域名恢复" test "$(state_domains)" = "$ORIG_DOMAINS"
assert "失败后配置规则恢复" test "$(config_domains)" = "$ORIG_DOMAINS"

echo ""
echo "=== 测试 D: trace 域名已在列表中时不做临时添加 ==="
WITH_TRACE='["claude.ai","gemini.google.com","openai.com","www.cloudflare.com"]'
warp_set_domains "$WITH_TRACE" >/dev/null 2>&1
state_before=$(state_domains)
rules_before=$(jq -c '.route.rules' "$SB_CONFIG")
rc_before=$(reload_count)
: > "$FAKE_CURL_PROBE"
export FAKE_CURL_MODE="warp_on"
out_d=$(warp_check 2>&1); rc_d=$?
rc_after=$(reload_count)
assert "域名已在列表时仍返回 0" test "$rc_d" = "0"
if grep -q "临时加入分流" <<< "$out_d"; then
    FAIL=$((FAIL + 1)); echo "FAIL: 不触发临时添加提示"
else
    PASS=$((PASS + 1)); echo "PASS: 不触发临时添加提示"
fi
assert "无多余服务重载" test "$((rc_after - rc_before))" = "0"
assert "state 内容完全不变" test "$(state_domains)" = "$state_before"
assert "配置规则完全不变" test "$(jq -c '.route.rules' "$SB_CONFIG")" = "$rules_before"
# 恢复 3 域名基线
warp_set_domains "$ORIG_DOMAINS" >/dev/null 2>&1

echo ""
echo "=== 测试 E: 28 域名精简模式端到端（用户真实场景） ==="
# shellcheck disable=SC2086
MINIMAL_JSON=$(printf '%s\n' $WARP_AI_DOMAINS_MINIMAL | jq -R . | jq -s 'sort')
warp_set_domains "$MINIMAL_JSON" >/dev/null 2>&1
min_count=$(jq -r '.protocols.warp.domains | length' "$SB_STATE")
assert "精简模式 28 个域名写入" test "$min_count" = "28"
: > "$FAKE_CURL_PROBE"
export FAKE_CURL_MODE="warp_on"
out_e=$(warp_check 2>&1); rc_e=$?
assert "28 域名场景 warp=on 返回 0" test "$rc_e" = "0"
assert "28 域名场景 trace 域名临时在规则内" grep -q "TRACE_DOMAIN_IN_RULES=yes" "$FAKE_CURL_PROBE"
assert "28 域名场景检查后恢复 28 个" test "$(jq -r '.protocols.warp.domains | length' "$SB_STATE")" = "28"
if jq -e '.protocols.warp.domains | index("www.cloudflare.com")' "$SB_STATE" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "FAIL: 28 域名场景 www.cloudflare.com 已移除"
else
    PASS=$((PASS + 1)); echo "PASS: 28 域名场景 www.cloudflare.com 已移除"
fi
if [[ -x "$SB_BIN" ]]; then
    assert "真实 sing-box check 通过" "$SB_BIN" check -c "$SB_CONFIG"
    timeout 3 "$SB_BIN" run -c "$SB_CONFIG" >"$TEST_ETC/run.log" 2>&1 || true
    if grep -q "FATAL" "$TEST_ETC/run.log" 2>/dev/null; then
        FAIL=$((FAIL + 1)); echo "FAIL: sing-box run 无 FATAL 错误"
    else
        PASS=$((PASS + 1)); echo "PASS: sing-box run 无 FATAL 错误"
    fi
else
    echo "SKIP: 未找到真实 sing-box 二进制 ($SB_BIN)"
fi
# 恢复 3 域名基线
warp_set_domains "$ORIG_DOMAINS" >/dev/null 2>&1

echo ""
echo "=== 测试 F: 无分流域名时返回 UNKNOWN(4)，不调用 curl ==="
warp_set_domains "[]" >/dev/null 2>&1
rm -f "$FAKE_CURL_PROBE"
export FAKE_CURL_MODE="warp_on"
out_f=$(warp_check 2>&1); rc_f=$?
assert "无分流域名返回 4" test "$rc_f" = "4"
assert "无分流域名时不调用 curl" test ! -f "$FAKE_CURL_PROBE"

echo ""
echo "=== 测试 G: RETURN trap 安全网（恢复函数直接验证） ==="
# 模拟异常路径：临时添加已发生，但显式恢复未执行，trap 处理函数必须能恢复
warp_set_domains "$ORIG_DOMAINS" >/dev/null 2>&1
_WARP_CHECK_ORIG_DOMAINS="$ORIG_DOMAINS"
_WARP_CHECK_TEMP_ADDED=1
warp_set_domains '["claude.ai","gemini.google.com","openai.com","www.cloudflare.com"]' >/dev/null 2>&1
assert "模拟：临时域名已加入" jq -e '.protocols.warp.domains | index("www.cloudflare.com")' "$SB_STATE"
_warp_check_restore_temp_domains
assert "trap 处理函数恢复 state 列表" test "$(state_domains)" = "$ORIG_DOMAINS"
assert "trap 处理函数恢复配置规则" test "$(config_domains)" = "$ORIG_DOMAINS"
assert "trap 处理函数后标志清零" test "$_WARP_CHECK_TEMP_ADDED" = "0"
# 重复调用为空操作
_warp_check_restore_temp_domains
assert "重复调用恢复函数为空操作" test "$(state_domains)" = "$ORIG_DOMAINS"

# 清理
rm -rf "$TEST_ETC" "$FAKE_BIN"
echo ""
echo "=============================="
echo "WARP HEALTHCHECK FIX TEST SUMMARY: PASS=$PASS FAIL=$FAIL"
echo "=============================="
[[ $FAIL -eq 0 ]]
