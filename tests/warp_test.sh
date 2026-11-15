#!/usr/bin/env bash
# tests/warp_test.sh — WARP 出站与分流路由的单元测试
# 用法：bash tests/warp_test.sh
set -u
cd "$(dirname "$0")/.." || exit 1
APP_HOME="$PWD"
export APP_HOME

# 模拟环境
TEST_ETC=$(mktemp -d)
export SB_ETC="$TEST_ETC"
export SB_CONFIG="$TEST_ETC/config.json"
export SB_STATE="$TEST_ETC/state.json"
export SB_BIN="$TEST_ETC/fake_singbox.sh"
cat > "$SB_BIN" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SB_BIN"
cp templates/base.json "$SB_CONFIG"

SERVICE_ACTIVE=0
systemctl() {
    case "$1" in
        is-active) [[ $SERVICE_ACTIVE -eq 1 ]] ;;
        restart|reload|enable) SERVICE_ACTIVE=1; return 0 ;;
        *) return 0 ;;
    esac
}
export -f systemctl

# shellcheck source=/dev/null
source core/env.sh
# env.sh 硬设路径，重新覆盖
export SB_ETC="$TEST_ETC" SB_CONFIG="$TEST_ETC/config.json" SB_STATE="$TEST_ETC/state.json" SB_BIN="$TEST_ETC/fake_singbox.sh"
# shellcheck source=/dev/null
source core/state_manager.sh
# shellcheck source=/dev/null
source core/json_builder.sh
# shellcheck source=/dev/null
source protocols/warp.sh

fail=0
assert() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc"
        fail=1
    fi
}

# 准备：模拟已安装 warp 状态
init_state_file
state_set_proto "warp" '{"private_key":"test","address_v4":"172.16.0.2/32","address_v6":"2606:4700:110:8004:b8fa:5f36:4a38:8535/128","reserved":[1,2,3],"domains":[]}'

# 1. 添加端点（单字符串 IPv4 地址，兼容全版本）
endpoint_json='{"type":"wireguard","tag":"warp","address":["172.16.0.2/32","2606:4700:110:8004:b8fa:5f36:4a38:8535/128"],"private_key":"YJc7v8J9K0L1M2N3O4P5Q6R7S8T9U0V1W2X3Y4Z5A6E=","peers":[{"address":"162.159.192.1","port":2408,"public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=","allowed_ips":["0.0.0.0/0","::/0"],"reserved":[1,2,3]}],"mtu":1280}'
apply_endpoint "add" "warp" "$endpoint_json" >/dev/null 2>&1
assert "warp 端点添加后存在于配置" jq -e '.endpoints[] | select(.tag=="warp")' "$SB_CONFIG"

# 2. 添加域名并同步路由
warp_add_domains google.com openai.com >/dev/null 2>&1
domain_count=$(warp_get_domains | wc -l)
assert "域名写入 state" bash -c "[[ $domain_count -eq 2 ]]"
assert "路由规则同步到配置" jq -e '.route.rules[] | select(.outbound=="warp" and (.domain_suffix | length == 2))' "$SB_CONFIG"

# 3. 重复添加去重
warp_add_domains google.com >/dev/null 2>&1
domain_count=$(warp_get_domains | wc -l)
assert "重复域名去重" bash -c "[[ $domain_count -eq 2 ]]"

# 4. 无效域名拒绝
warp_add_domains 'invalid..domain' >/dev/null 2>&1 || true
domain_count=$(warp_get_domains | wc -l)
assert "无效域名被拒绝" bash -c "[[ $domain_count -eq 2 ]]"

# 5. AI 预设（非交互默认精简模式，28 个域名）
warp_apply_ai_preset >/dev/null 2>&1
preset_count=$(warp_get_domains | wc -l)
assert "AI 预设域名数 ≥ 28" bash -c "[[ $preset_count -ge 28 ]]"

# 6. 删除域名
warp_remove_domains openai.com >/dev/null 2>&1
domain_count=$(warp_get_domains | wc -l)
assert "删除域名后数量减少" bash -c "[[ $domain_count -eq $((preset_count - 1)) ]]"

# 7. 清空
warp_clear_domains >/dev/null 2>&1
domain_list=$(warp_get_domains)
assert "清空后 state 无域名" bash -c "[[ -z \"$domain_list\" ]]"
rule_count=$(jq '[.route.rules[]? | select(.outbound=="warp")] | length' "$SB_CONFIG")
assert "清空后配置无 warp 规则" bash -c "[[ $rule_count -eq 0 ]]"

# 8. 删除端点
apply_endpoint "del" "warp" >/dev/null 2>&1
endpoint_count=$(jq '[.endpoints[]? | select(.tag=="warp")] | length' "$SB_CONFIG")
assert "删除端点后配置无 warp" bash -c "[[ $endpoint_count -eq 0 ]]"

rm -rf "$TEST_ETC"
if [[ $fail -eq 0 ]]; then
    echo "PASS: WARP 出站、分流域名管理与路由同步"
else
    echo "FAIL: WARP 测试有失败项"
    exit 1
fi
