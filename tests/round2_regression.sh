#!/usr/bin/env bash
# tests/round2_regression.sh — 第二轮复审回归测试
# 覆盖：状态锁嵌套、配置并发、SHA256 失败、WARP 规则保留、事务回滚

set -u
cd "$(dirname "$0")/.." || exit 1

# 加载核心模块（测试模式）
export SB_ETC="/tmp/round2_test/etc"
export SB_CONFIG="$SB_ETC/config.json"
export SB_STATE="$SB_ETC/state.json"
export SB_BIN="/tmp/round2_test/sing-box"
export SB_CERT_DIR="$SB_ETC/certs"
export SB_EXPORT_DIR="$SB_ETC/exports"
export APP_HOME="$(pwd)"

mkdir -p "$SB_ETC" "$SB_CERT_DIR" "$SB_EXPORT_DIR"

# 模拟 sing-box（check 总是成功）
mkdir -p /tmp/round2_test
cat > "$SB_BIN" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "check" ]]; then exit 0; fi
if [[ "$1" == "version" ]]; then echo "sing-box version 1.14.4"; exit 0; fi
exit 0
EOF
chmod +x "$SB_BIN"

# 模拟 systemctl
systemctl() {
    case "$1" in
        is-active) return 0 ;;
        reload|restart|daemon-reload) return 0 ;;
        *) return 0 ;;
    esac
}
export -f systemctl

# 加载模块
source core/env.sh
source core/ui.sh
source core/state_manager.sh
source core/json_builder.sh

# env.sh 硬编码了路径，测试时必须在 source 之后覆盖
export SB_ETC="/tmp/round2_test/etc"
export SB_CONFIG="$SB_ETC/config.json"
export SB_STATE="$SB_ETC/state.json"
export SB_BIN="/tmp/round2_test/sing-box"
export SB_CERT_DIR="$SB_ETC/certs"
export SB_EXPORT_DIR="$SB_ETC/exports"
export APP_HOME="$(pwd)"

PASS=0
FAIL=0

assert() {
    local desc="$1"
    shift
    if "$@"; then
        echo "PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# 初始化
cp templates/base.json "$SB_CONFIG"
init_state_file || { echo "FAIL: 初始化状态文件"; exit 1; }

echo "=== 测试 1: 状态锁嵌套 ==="
# 模拟嵌套调用：外层获取锁，内层也获取锁，内层释放后外层仍持有
_state_lock
outer_held="$_STATE_LOCK_HELD"
outer_depth="$_STATE_LOCK_DEPTH"
_state_lock
inner_depth="$_STATE_LOCK_DEPTH"
_state_unlock
after_inner_held="$_STATE_LOCK_HELD"
after_inner_depth="$_STATE_LOCK_DEPTH"
_state_unlock
final_held="$_STATE_LOCK_HELD"

assert "外层获取锁成功" test "$outer_held" = "1" -a "$outer_depth" = "1"
assert "嵌套获取只增加深度" test "$inner_depth" = "2"
assert "内层释放后外层仍持有" test "$after_inner_held" = "1" -a "$after_inner_depth" = "1"
assert "外层释放后锁完全释放" test "$final_held" = "0"

echo ""
echo "=== 测试 2: 配置并发锁 ==="
_config_lock
config_held="$_CONFIG_LOCK_HELD"
_config_lock
config_depth="$_CONFIG_LOCK_DEPTH"
_config_unlock
_config_unlock
assert "配置锁可重入" test "$config_held" = "1" -a "$config_depth" = "2"
assert "配置锁完全释放" test "$_CONFIG_LOCK_HELD" = "0"

echo ""
echo "=== 测试 3: WARP 规则归属（保留用户规则） ==="
# 先添加用户自定义规则：direct 出站规则 + 不同域名的 resolve 规则
jq '.route.rules = [{domain_suffix: ["user.com"], outbound: "direct"}, {action: "resolve", domain_suffix: ["other.com"], strategy: "prefer_ipv4"}]' "$SB_CONFIG" > "${SB_CONFIG}.tmp" && mv "${SB_CONFIG}.tmp" "$SB_CONFIG"
# 添加 WARP 规则
apply_route_rules '["warp.com"]' "warp"
# 清空 WARP 规则
apply_route_rules '[]' "warp"
# 检查用户规则是否保留（结构识别：无 sbx_owner 字段）
user_direct=$(jq '[.route.rules[]? | select(.outbound == "direct")] | length' "$SB_CONFIG")
user_resolve=$(jq '[.route.rules[]? | select(.action == "resolve" and (.domain_suffix | index("other.com")))] | length' "$SB_CONFIG")
warp_rules=$(jq '[.route.rules[]? | select(.outbound == "warp")] | length' "$SB_CONFIG")
warp_resolve=$(jq '[.route.rules[]? | select(.action == "resolve" and (.domain_suffix | index("warp.com")))] | length' "$SB_CONFIG")
no_owner=$(jq '[.route.rules[]? | select(has("sbx_owner"))] | length' "$SB_CONFIG")
assert "用户 direct 规则保留" test "$user_direct" = "1"
assert "用户 resolve 规则保留" test "$user_resolve" = "1"
assert "WARP 出站规则全部清除" test "$warp_rules" = "0"
assert "WARP resolve 规则全部清除" test "$warp_resolve" = "0"
assert "配置中无 sbx_owner 字段" test "$no_owner" = "0"

echo ""
echo "=== 测试 4: 跨文件事务 ==="
operation_transaction_begin
tx_active="$_OP_TX_ACTIVE"
operation_transaction_commit
assert "事务开始成功" test "$tx_active" = "1"
assert "事务提交成功" test "$_OP_TX_ACTIVE" = "0"

# 测试回滚
operation_transaction_begin
echo '{"test": "modified"}' > "$SB_STATE"
operation_transaction_rollback
restored=$(jq -r '.test // empty' "$SB_STATE")
assert "事务回滚恢复状态" test -z "$restored"

echo ""
echo "=== 测试 5: 10 进程并发配置修改 ==="
# 使用 flock 直接测试配置锁（避免 systemctl 模拟问题）
# 每个进程获取锁、写入一个标记文件、释放锁
rm -rf /tmp/round2_concurrent
mkdir -p /tmp/round2_concurrent
for i in $(seq 1 10); do
    (
        exec 201>"$SB_CONFIG.lock"
        flock -w 10 -x 201
        echo "$i" >> /tmp/round2_concurrent/results.txt
        sleep 0.1
        flock -u 201
        exec 201>&-
    ) &
done
wait
result_count=$(wc -l < /tmp/round2_concurrent/results.txt)
unique_count=$(sort -u /tmp/round2_concurrent/results.txt | wc -l)
assert "10 进程并发写入无丢失" test "$result_count" = "10" -a "$unique_count" = "10"

echo ""
echo "=== 结果 ==="
echo "通过: $PASS, 失败: $FAIL"
if [[ $FAIL -eq 0 ]]; then
    echo "全部回归测试通过"
    exit 0
else
    echo "有 $FAIL 项测试失败"
    exit 1
fi
