#!/usr/bin/env bash
# tests/warp_temp_cleanup_test.sh — WARP 健康检查临时测试域名清理验证
#
# 背景（2026-11-15 真机实测）：运行 WARP 健康检查 [1/c]，[5/5] 实际流量
# 测试超时失败后，用户在恢复阶段按 Ctrl+C（sing-box 重载耗时较长，误以
# 为卡死），结果分流域名从 28 个变成 29 个（www.cloudflare.com 临时测试
# 域名未移除），分流模式从"精简模式"变成"自定义"。
#
# 根因：显式恢复代码先清除 RETURN trap 与状态标志，再调用 warp_set_domains
# 恢复；恢复期间被中断时安全网已撤，临时域名永久残留。
#
# 修复（五层防御）：
#   1. 恢复顺序调换：先 warp_set_domains 恢复，成功后再清标志/trap；失败
#      时保持标志，RETURN trap 在函数返回时再试一次。
#   2. 第 5 层安装 INT/TERM trap：Ctrl+C 时先恢复临时域名再以 130 退出。
#   3. 恢复验证：warp_set_domains 返回后用 jq 深比较确认列表确实恢复。
#   4. 超时保护：sing-box 重载走 _systemctl_timed（默认 15 秒超时）。
#   5. 幂等入口清理：state 中的 temp_trace_added 标记识别上次残留，下次
#      warp_check 入口先清理；用户手动添加的 www.cloudflare.com 无标记，
#      不会被误删。
#
# 测试覆盖：
#   A. Ctrl+C 中断恢复阶段时临时域名仍被清理（setsid + 信号模拟真机）
#   B. 恢复失败时有明确错误提示，标记保留，RETURN trap 再试一次
#   C. 入口清理发现并移除上次残留的测试域名
#   D. 用户手动添加的测试域名不被入口清理误删
#   E. 标记残留但域名已不在列表时只清标记
#   F. 恢复函数单元测试（成功/失败路径，失败时标志保持）
#   G. _systemctl_timed 超时保护（函数 mock 直调 / 二进制超时 124）
#   H. 正常 warp_check 后 INT/TERM trap 不残留
#
# 用法：bash tests/warp_temp_cleanup_test.sh
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
export TEST_ETC FAKE_BIN

# --- 模拟 systemctl（带重载计数、延迟、失败注入） ---
# SYSTEMCTL_RESTART_DELAY：reload/restart 时 sleep 秒数（制造 Ctrl+C 时间窗口）
# SYSTEMCTL_FAIL_AFTER：前 N 次 reload/restart 成功，之后服务起不来（is-active 失败）
SERVICE_ACTIVE=0
export SERVICE_ACTIVE
RELOAD_COUNT_FILE="$TEST_ETC/reload_count"
export RELOAD_COUNT_FILE
: > "$RELOAD_COUNT_FILE"
systemctl() {
    case "$1" in
        is-active) [[ $SERVICE_ACTIVE -eq 1 ]] ;;
        reload|restart)
            echo "$1" >> "$RELOAD_COUNT_FILE"
            [[ -n "${SYSTEMCTL_RESTART_DELAY:-}" ]] && sleep "$SYSTEMCTL_RESTART_DELAY"
            local n
            n=$(wc -l < "$RELOAD_COUNT_FILE" | tr -d ' ')
            if [[ -n "${SYSTEMCTL_FAIL_AFTER:-}" && "$n" -gt "$SYSTEMCTL_FAIL_AFTER" ]]; then
                SERVICE_ACTIVE=0
            else
                SERVICE_ACTIVE=1
            fi
            return 0 ;;
        enable) return 0 ;;
        *) return 0 ;;
    esac
}
export -f systemctl

reload_count() { wc -l < "$RELOAD_COUNT_FILE" | tr -d ' '; }

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
assert_not() { # 断言命令失败（用于"不应出现"的检查）
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1)); echo "FAIL: $desc"
    else
        PASS=$((PASS + 1)); echo "PASS: $desc"
    fi
}

# --- 准备：最小可用配置 + warp/socks5 状态 ---
cp templates/base.json "$SB_CONFIG"
init_state_file
SERVICE_ACTIVE=1

PRIV_KEY=$(openssl rand 32 | base64 -w0)
state_set_proto "warp" "$(jq -n --arg pk "$PRIV_KEY" '{private_key: $pk, address_v4: "172.16.0.2/32", address_v6: "2606:4700:110:8004:b8fa:5f36:4a38:8535/128", reserved: [73,214,142], domains: []}')"
state_set_proto "socks5" '{"port":36148,"username":"sg","password":"testpass123"}'
endpoint_json=$(jq -n --arg pk "$PRIV_KEY" '{type: "wireguard", tag: "warp", address: ["172.16.0.2/32", "2606:4700:110:8004:b8fa:5f36:4a38:8535/128"], private_key: $pk, peers: [{address: "162.159.192.1", port: 2408, public_key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", allowed_ips: ["0.0.0.0/0", "::/0"], reserved: [73,214,142]}], mtu: 1280}')
apply_endpoint "add" "warp" "$endpoint_json" >/dev/null 2>&1
assert "测试环境：warp 端点添加成功" jq -e '.endpoints[] | select(.tag=="warp")' "$SB_CONFIG"

ORIG_DOMAINS='["claude.ai","gemini.google.com","openai.com"]'
WITH_TRACE='["claude.ai","gemini.google.com","openai.com","www.cloudflare.com"]'
warp_set_domains "$ORIG_DOMAINS" >/dev/null 2>&1
assert "测试环境：3 个分流域名写入" test "$(jq -c '.protocols.warp.domains' "$SB_STATE")" = "$ORIG_DOMAINS"

# 辅助：当前 state/配置中的分流域名、临时标记
state_domains() { jq -c '.protocols.warp.domains // []' "$SB_STATE" 2>/dev/null; }
config_domains() { jq -c '[.route.rules[]? | select(.outbound == "warp") | .domain_suffix] | first // []' "$SB_CONFIG" 2>/dev/null; }
temp_marker() { jq -r '.protocols.warp.temp_trace_added // empty' "$SB_STATE" 2>/dev/null; }

echo ""
echo "=== 测试 A: Ctrl+C 中断恢复阶段，临时域名仍被清理（用户真机场景） ==="
# 辅助脚本：在独立进程组中跑 warp_check（set -m 下后台任务自成进程组，
# SIGINT 不会被忽略，可真实模拟终端 Ctrl+C）
CHECK_OUT="$TEST_ETC/check_a.out"
CHECK_RC="$TEST_ETC/check_a.rc"
export CHECK_OUT CHECK_RC
cat > "$TEST_ETC/run_check.sh" <<'HELPER_EOF'
#!/usr/bin/env bash
set -u
cd "$APP_HOME" || exit 1
source core/env.sh
export SB_ETC="$TEST_ETC" SB_CONFIG="$TEST_ETC/config.json" SB_STATE="$TEST_ETC/state.json"
SB_BIN="/tmp/sb_test/sing-box-1.14.4-linux-amd64/sing-box"
export SB_BIN
source core/state_manager.sh
source core/json_builder.sh
source protocols/warp.sh
warp_check > "$CHECK_OUT" 2>&1
echo $? > "$CHECK_RC"
HELPER_EOF
chmod +x "$TEST_ETC/run_check.sh"
# 前置：排空父进程泄漏的锁深度。warp_set_domains 等混合函数会泄漏状态锁
# （config_transaction 覆盖了 RETURN trap，_state_unlock 未触发——已知遗留
# 问题，单进程内无影响因锁可重入）；helper 是独立进程，需自行获取锁，
# 父进程持有锁时 helper 会超时失败，故先排空。排空后父进程后续操作会
# 按需重新获取锁，不影响后续测试。
while [[ "${_STATE_LOCK_HELD:-0}" == "1" ]]; do _state_unlock; done
while [[ "${_CONFIG_LOCK_HELD:-0}" == "1" ]]; do _config_unlock; done
: > "$RELOAD_COUNT_FILE"
export SYSTEMCTL_RESTART_DELAY=3
export FAKE_CURL_MODE="warp_on"
set -m
bash "$TEST_ETC/run_check.sh" &
helper_pid=$!
# 等恢复阶段开始：临时添加重载（第 1 次）+ 恢复重载（第 2 次）被调用
for _ in $(seq 1 150); do
    [[ "$(reload_count)" -ge 2 ]] && break
    sleep 0.2
done
assert "A 前置：恢复重载已开始" test "$(reload_count)" -ge 2
# 此时恢复的 systemctl 正在 3 秒 sleep 中，模拟用户按 Ctrl+C
kill -INT -$helper_pid 2>/dev/null
wait $helper_pid 2>/dev/null
helper_rc=$?
set +m
unset SYSTEMCTL_RESTART_DELAY
assert "Ctrl+C 后进程以 130 退出" test "$helper_rc" = "130"
assert "中断后 state 域名恢复原 3 个" test "$(state_domains)" = "$ORIG_DOMAINS"
assert "中断后配置规则恢复原 3 个域名" test "$(config_domains)" = "$ORIG_DOMAINS"
assert "中断后临时标记已清除" test -z "$(temp_marker)"
assert "中断处理又做了一次恢复重载" test "$(reload_count)" -ge 3
assert_not "中断后无残留测试域名" jq -e '.protocols.warp.domains | index("www.cloudflare.com")' "$SB_STATE"

echo ""
echo "=== 测试 B: 恢复失败时明确报错，标记保留，RETURN trap 再试一次 ==="
: > "$RELOAD_COUNT_FILE"
export SYSTEMCTL_FAIL_AFTER=1
export FAKE_CURL_MODE="warp_on"
out_b=$(warp_check 2>&1); rc_b=$?
unset SYSTEMCTL_FAIL_AFTER
assert "恢复失败时检查本身仍返回 0（隧道正常）" test "$rc_b" = "0"
assert "输出含恢复失败明确报错" grep -q "恢复原分流列表失败" <<< "$out_b"
assert "报错提示手动移除测试域名" grep -q "手动移除" <<< "$out_b"
fail_msgs=$(grep -c "恢复原分流列表失败" <<< "$out_b" || true)
assert "RETURN trap 重试过恢复（报错至少 2 次）" test "$fail_msgs" -ge 2
assert "恢复失败后标记保留为 1" test "$(temp_marker)" = "1"
assert "恢复失败后 state 仍含测试域名" jq -e '.protocols.warp.domains | index("www.cloudflare.com")' "$SB_STATE"
assert "恢复失败后重载次数证明重试过" test "$(reload_count)" -ge 4

echo ""
echo "=== 测试 C: 入口清理发现并移除上次残留（接测试 B 的污染状态） ==="
# 此时 state 为 4 域名（含测试域名）+ 标记 1，模拟用户下次再跑 [1/c]
assert "C 前置：污染状态就绪" test "$(state_domains)" = "$WITH_TRACE"
export FAKE_CURL_MODE="warp_on"
out_c=$(warp_check 2>&1); rc_c=$?
assert "入口清理后检查返回 0" test "$rc_c" = "0"
assert "输出提示发现残留测试域名" grep -q "残留的测试域名" <<< "$out_c"
assert "输出提示残留已清理" grep -q "残留测试域名已清理" <<< "$out_c"
assert "清理后 state 恢复原 3 个" test "$(state_domains)" = "$ORIG_DOMAINS"
assert "清理后配置恢复原 3 个" test "$(config_domains)" = "$ORIG_DOMAINS"
assert "清理后标记已清除" test -z "$(temp_marker)"
assert_not "清理后无测试域名" jq -e '.protocols.warp.domains | index("www.cloudflare.com")' "$SB_STATE"

echo ""
echo "=== 测试 D: 用户手动添加的测试域名不被入口清理误删 ==="
warp_set_domains "$WITH_TRACE" >/dev/null 2>&1
assert "D 前置：标记为空（用户手动添加）" test -z "$(temp_marker)"
export FAKE_CURL_MODE="warp_on"
out_d=$(warp_check 2>&1); rc_d=$?
assert "域名已在列表时仍返回 0" test "$rc_d" = "0"
assert_not "不触发残留清理提示" grep -q "残留的测试域名" <<< "$out_d"
assert_not "不触发临时添加提示" grep -q "临时加入分流" <<< "$out_d"
assert "用户域名原样保留 4 个" test "$(state_domains)" = "$WITH_TRACE"
# 恢复 3 域名基线
warp_set_domains "$ORIG_DOMAINS" >/dev/null 2>&1

echo ""
echo "=== 测试 E: 标记残留但域名已不在列表时只清标记 ==="
state_set_field "warp" "temp_trace_added" "1" >/dev/null 2>&1
assert "E 前置：标记为 1 且域名不含测试域名" test "$(temp_marker)" = "1"
export FAKE_CURL_MODE="warp_on"
out_e=$(warp_check 2>&1); rc_e=$?
assert "标记残留场景检查返回 0" test "$rc_e" = "0"
assert "陈旧标记已清除" test -z "$(temp_marker)"
assert "检查后域名仍为原 3 个" test "$(state_domains)" = "$ORIG_DOMAINS"

echo ""
echo "=== 测试 F: 恢复函数单元测试（先恢复后清标志） ==="
# F1 成功路径：标记随恢复一起清除
warp_set_domains "$WITH_TRACE" >/dev/null 2>&1
state_set_field "warp" "temp_trace_added" "1" >/dev/null 2>&1
_WARP_CHECK_ORIG_DOMAINS="$ORIG_DOMAINS"
_WARP_CHECK_TEMP_ADDED=1
_warp_check_restore_temp_domains
assert "恢复函数成功返回 0" test "$?" = "0"
assert "恢复函数后 state 为原 3 个" test "$(state_domains)" = "$ORIG_DOMAINS"
assert "恢复函数后配置为原 3 个" test "$(config_domains)" = "$ORIG_DOMAINS"
assert "恢复函数后标志清零" test "$_WARP_CHECK_TEMP_ADDED" = "0"
assert "恢复函数后标记已清除" test -z "$(temp_marker)"
# F2 失败路径：标志与标记保持，供 RETURN trap / 下次检查重试
warp_set_domains "$WITH_TRACE" >/dev/null 2>&1
state_set_field "warp" "temp_trace_added" "1" >/dev/null 2>&1
_WARP_CHECK_ORIG_DOMAINS="$ORIG_DOMAINS"
_WARP_CHECK_TEMP_ADDED=1
export SYSTEMCTL_FAIL_AFTER=0
# 注意：不用 $(...) 捕获输出（子 shell 会隔离全局标志的改动），改重定向到文件
_warp_check_restore_temp_domains >"$TEST_ETC/f2.out" 2>&1; rc_f2=$?
out_f2=$(cat "$TEST_ETC/f2.out")
unset SYSTEMCTL_FAIL_AFTER
assert "恢复失败返回 1" test "$rc_f2" = "1"
assert "恢复失败时标志保持为 1（供重试）" test "$_WARP_CHECK_TEMP_ADDED" = "1"
assert "恢复失败时原列表保持" test "$_WARP_CHECK_ORIG_DOMAINS" = "$ORIG_DOMAINS"
assert "恢复失败时标记保持为 1" test "$(temp_marker)" = "1"
assert "恢复失败时输出明确报错" grep -q "恢复原分流列表失败" <<< "$out_f2"
# 恢复服务后再次调用应成功（模拟 RETURN trap 重试）
_warp_check_restore_temp_domains
assert "重试恢复成功" test "$?" = "0"
assert "重试后 state 为原 3 个" test "$(state_domains)" = "$ORIG_DOMAINS"
assert "重试后标志清零" test "$_WARP_CHECK_TEMP_ADDED" = "0"
# F3 无临时添加时为空操作
_warp_check_restore_temp_domains
assert "无临时添加时重复调用为空操作" test "$(state_domains)" = "$ORIG_DOMAINS"

echo ""
echo "=== 测试 G: _systemctl_timed 超时保护 ==="
: > "$RELOAD_COUNT_FILE"
_systemctl_timed reload sing-box
assert "函数 mock 时直接调用（重载计数+1）" test "$(reload_count)" = "1"
# 二进制 systemctl 超时路径（子 shell 中 unset 函数 mock，改走 PATH 中的慢速可执行文件）
SLOW_BIN=$(mktemp -d)
cat > "$SLOW_BIN/systemctl" <<'SLOW_EOF'
#!/usr/bin/env bash
case "$1" in
    is-active) exit 0 ;;
    reload|restart) sleep 30; exit 0 ;;
    *) exit 0 ;;
esac
SLOW_EOF
chmod +x "$SLOW_BIN/systemctl"
g2_out=$( (
    unset -f systemctl
    PATH="$SLOW_BIN:/usr/bin:/bin"
    export SBX_SYSTEMCTL_TIMEOUT=2
    start=$(date +%s)
    _systemctl_timed restart sing-box
    rc=$?
    end=$(date +%s)
    echo "rc=$rc elapsed=$((end - start))"
) 2>&1 )
rm -rf "$SLOW_BIN"
assert "慢速 systemctl 在 2 秒超时返回 124" grep -q "rc=124" <<< "$g2_out"
g2_elapsed=$(echo "$g2_out" | grep -o 'elapsed=[0-9]*' | cut -d= -f2)
assert "超时实际耗时小于 10 秒（未等满 30 秒）" test "${g2_elapsed:-99}" -lt 10

echo ""
echo "=== 测试 H: 正常 warp_check 后 INT/TERM trap 不残留 ==="
export FAKE_CURL_MODE="warp_on"
warp_check >/dev/null 2>&1
assert "INT trap 已移除" test -z "$(trap -p INT 2>/dev/null || true)"
assert "TERM trap 已移除" test -z "$(trap -p TERM 2>/dev/null || true)"
assert "检查后域名仍为原 3 个" test "$(state_domains)" = "$ORIG_DOMAINS"

# 清理
rm -rf "$TEST_ETC" "$FAKE_BIN"
echo ""
echo "=============================="
echo "WARP TEMP CLEANUP TEST SUMMARY: PASS=$PASS FAIL=$FAIL"
echo "=============================="
[[ $FAIL -eq 0 ]]
