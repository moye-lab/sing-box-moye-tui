#!/usr/bin/env bash
# tests/warp_sbx_owner_fix_test.sh — WARP 分流 sbx_owner 修复验证
#
# 背景（2026-11-15 真机实测）：第二轮复审给 WARP 路由规则加了 sbx_owner
# 字段，sing-box check 报 unknown field，分流应用失败。
# 修复：移除 sbx_owner，改用结构识别（outbound tag + domain_suffix 匹配）。
#
# 测试覆盖：
#   1. apply_route_rules 生成的 JSON 不含 sbx_owner
#   2. 生成的配置能通过真实 sing-box check（需 SB_BIN 指向真实二进制）
#   3. 写入/更新/清空三态正确，用户规则保留
#   4. 重复写入不积累裸 sniff 规则

set -u
cd "$(dirname "$0")/.." || exit 1

# 加载核心模块（与 round2_regression.sh 相同的沙箱模式）
export SB_CONFIG="/tmp/warp_fix_test_config.json"
export SB_STATE="/tmp/warp_fix_test_state.json"
export SB_BIN="${SB_BIN:-/tmp/sb_test/sing-box-1.14.4-linux-amd64/sing-box}"
export SB_ETC="/tmp/warp_fix_test_etc"
mkdir -p "$SB_ETC"

# 模拟 systemctl（config_transaction 会调用服务重载）
systemctl() { return 0; }
export -f systemctl

source core/env.sh
source core/ui.sh
source core/state_manager.sh
source core/json_builder.sh

# 覆盖 env.sh 硬编码的路径（必须在 source 之后，且强制覆盖）
SB_CONFIG="/tmp/warp_fix_test_config.json"
SB_STATE="/tmp/warp_fix_test_state.json"
SB_BIN="/tmp/sb_test/sing-box-1.14.4-linux-amd64/sing-box"
SB_ETC="/tmp/warp_fix_test_etc"

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

# 初始化最小配置
init_config() {
    cat > "$SB_CONFIG" << 'EOF'
{
  "log": {"level": "info"},
  "inbounds": [{"type": "direct", "tag": "direct-in", "listen": "127.0.0.1", "listen_port": 1080}],
  "outbounds": [{"type": "direct", "tag": "direct"}, {"type": "block", "tag": "block"}],
  "route": {"rules": []}
}
EOF
    echo '{"schema_version": 2, "protocols": {}}' > "$SB_STATE"
}

echo "=== 测试 1: 写入 WARP 规则不含 sbx_owner ==="
init_config
apply_route_rules '["gemini.google.com", "openai.com"]' "warp"
no_owner=$(jq '[.route.rules[]? | select(has("sbx_owner"))] | length' "$SB_CONFIG")
assert "规则中无 sbx_owner 字段" test "$no_owner" = "0"
rule_count=$(jq '.route.rules | length' "$SB_CONFIG")
assert "写入 3 条规则（sniff+resolve+outbound）" test "$rule_count" = "3"
has_sniff=$(jq '[.route.rules[]? | select(.action == "sniff")] | length' "$SB_CONFIG")
assert "含 sniff 规则" test "$has_sniff" = "1"
has_resolve=$(jq '[.route.rules[]? | select(.action == "resolve")] | length' "$SB_CONFIG")
assert "含 resolve 规则" test "$has_resolve" = "1"
has_outbound=$(jq '[.route.rules[]? | select(.outbound == "warp")] | length' "$SB_CONFIG")
assert "含 warp 出站规则" test "$has_outbound" = "1"

echo ""
echo "=== 测试 2: 真实 sing-box check 通过 ==="
if [[ -x "$SB_BIN" ]]; then
    assert "sing-box check 通过" "$SB_BIN" check -c "$SB_CONFIG"
    # 短暂启动验证无 FATAL
    timeout 3 "$SB_BIN" run -c "$SB_CONFIG" >/tmp/warp_fix_run.log 2>&1 || true
    if grep -q "FATAL" /tmp/warp_fix_run.log 2>/dev/null; then
        FAIL=$((FAIL + 1))
        echo "FAIL: sing-box run 无 FATAL 错误"
    else
        PASS=$((PASS + 1))
        echo "PASS: sing-box run 无 FATAL 错误"
    fi
else
    echo "SKIP: 未找到真实 sing-box 二进制 ($SB_BIN)"
fi

echo ""
echo "=== 测试 3: 更新规则（旧规则清除，新规则写入） ==="
apply_route_rules '["claude.ai"]' "warp"
old_resolve=$(jq '[.route.rules[]? | select(.action == "resolve" and (.domain_suffix | index("gemini.google.com")))] | length' "$SB_CONFIG")
assert "旧 resolve 规则清除" test "$old_resolve" = "0"
new_resolve=$(jq '[.route.rules[]? | select(.action == "resolve" and (.domain_suffix | index("claude.ai")))] | length' "$SB_CONFIG")
assert "新 resolve 规则写入" test "$new_resolve" = "1"
sniff_count=$(jq '[.route.rules[]? | select(. == {action: "sniff"})] | length' "$SB_CONFIG")
assert "裸 sniff 规则只有 1 条（不积累）" test "$sniff_count" = "1"
rule_count=$(jq '.route.rules | length' "$SB_CONFIG")
assert "总规则数仍为 3" test "$rule_count" = "3"

echo ""
echo "=== 测试 4: 清空规则（WARP 规则清除，用户规则保留） ==="
# 先加用户规则（用有效字段：direct 出站 + 不同域名的 resolve）
jq '.route.rules += [{domain_suffix: ["user.com"], outbound: "direct"}, {action: "resolve", domain_suffix: ["other.com"], strategy: "prefer_ipv4"}]' "$SB_CONFIG" > "${SB_CONFIG}.tmp" && mv "${SB_CONFIG}.tmp" "$SB_CONFIG"
apply_route_rules '[]' "warp"
warp_out=$(jq '[.route.rules[]? | select(.outbound == "warp")] | length' "$SB_CONFIG")
assert "WARP 出站规则清除" test "$warp_out" = "0"
warp_res=$(jq '[.route.rules[]? | select(.action == "resolve" and (.domain_suffix | index("claude.ai")))] | length' "$SB_CONFIG")
assert "WARP resolve 规则清除" test "$warp_res" = "0"
user_direct=$(jq '[.route.rules[]? | select(.outbound == "direct")] | length' "$SB_CONFIG")
assert "用户 direct 规则保留" test "$user_direct" = "1"
user_resolve=$(jq '[.route.rules[]? | select(.action == "resolve" and (.domain_suffix | index("other.com")))] | length' "$SB_CONFIG")
assert "用户 resolve 规则保留" test "$user_resolve" = "1"

echo ""
echo "=== 测试 5: 重复写入不积累 ==="
init_config
apply_route_rules '["a.com"]' "warp"
apply_route_rules '["b.com"]' "warp"
apply_route_rules '["c.com"]' "warp"
rule_count=$(jq '.route.rules | length' "$SB_CONFIG")
assert "三次写入后总规则数仍为 3" test "$rule_count" = "3"
sniff_count=$(jq '[.route.rules[]? | select(. == {action: "sniff"})] | length' "$SB_CONFIG")
assert "裸 sniff 只有 1 条" test "$sniff_count" = "1"

echo ""
echo "=== 测试 6: 清空后 sing-box check 仍通过 ==="
apply_route_rules '[]' "warp"
if [[ -x "$SB_BIN" ]]; then
    assert "清空后 sing-box check 通过" "$SB_BIN" check -c "$SB_CONFIG"
else
    echo "SKIP: 未找到真实 sing-box 二进制"
fi

echo ""
echo "=============================="
echo "WARP SBX_OWNER FIX TEST SUMMARY: PASS=$PASS FAIL=$FAIL"
echo "=============================="

# 清理
rm -f "$SB_CONFIG" "$SB_STATE" /tmp/warp_fix_run.log
rm -rf "$SB_ETC"

[[ "$FAIL" -eq 0 ]]
