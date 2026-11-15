#!/usr/bin/env bash
set -uo pipefail
# 使用脚本所在目录的父目录作为项目根目录（不再硬编码 /tmp/review）
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/fakebin"
cat > "$tmp/fakebin/sing-box" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "version" ]]; then echo "sing-box version 1.12.0"; exit 0; fi
if [[ "$1" == "generate" ]]; then
    case "$2" in
        uuid) echo "11111111-2222-3333-4444-555555555555" ;;
        rand) echo "abcd1234abcd1234abcd1234" ;;
    esac
    exit 0
fi
exit 0
EOF
chmod +x "$tmp/fakebin/sing-box"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/fakebin/systemctl"
chmod +x "$tmp/fakebin/systemctl"
export PATH="$tmp/fakebin:$PATH"
source "$ROOT/core/env.sh"
export APP_HOME="$ROOT" SB_ETC="$tmp/etc" SB_CERT_DIR="$tmp/etc/certs" SB_EXPORT_DIR="$tmp/etc/export"
export SB_STATE="$tmp/etc/state.json" SB_CONFIG="$tmp/etc/config.json"
export SB_BIN="$tmp/fakebin/sing-box" SBM_VERSION="test"
source "$ROOT/core/state_manager.sh" && source "$ROOT/core/ui.sh"
source "$ROOT/core/json_builder.sh" && source "$ROOT/core/engine.sh"
source "$ROOT/utils/cert.sh" && source "$ROOT/utils/export.sh"
source "$ROOT/protocols/anytls.sh"
is_port_used() { return 1; }
init_state_file || fail "state init"

# 1. 版本门控：1.12.0 通过
require_anytls_version || fail "1.12.0 应通过版本门控"
echo "PASS: 版本门控 1.12.0"

# 2. SBX_AUTO 安装全程无阻塞
SBX_AUTO=1 install_anytls < /dev/null >/dev/null 2>&1 || fail "AUTO install_anytls 失败"
state_has_proto anytls || fail "anytls 未写入 state"
_ap=$(state_get_field anytls port)
[[ "$_ap" =~ ^[0-9]+$ ]] && (( _ap >= 1 && _ap <= 65535 )) || fail "anytls 端口无效: $_ap"
unset _ap
[[ -n "$(state_get_field anytls password)" ]] || fail "anytls 密码为空"
echo "PASS: install_anytls AUTO"

# 3. 导出生成 anytls:// 链接
get_public_ip() { echo "203.0.113.9"; }
ensure_node_meta() { :; }
get_node_prefix() { echo "US-RN"; }
export_all_nodes >/dev/null 2>&1
grep -q "^anytls://" "$tmp/etc/export/links.txt" || fail "links.txt 缺少 anytls://"
grep -q "type: anytls" "$tmp/etc/export/mihomo_proxies.yaml" || fail "mihomo 缺少 anytls"
grep -q '"type": "anytls"' "$tmp/etc/export/singbox_outbounds.json" || fail "singbox 缺少 anytls"
link=$(grep "^anytls://" "$tmp/etc/export/links.txt" | head -1)
echo "链接样例: ${link:0:60}..."
[[ "$link" == *"US-RN-AnyTLS"* ]] || fail "节点名应为 US-RN-AnyTLS"
echo "PASS: 导出格式"

# 4. 卸载
uninstall_anytls >/dev/null 2>&1
! state_has_proto anytls || fail "anytls 未清理"
echo "PASS: uninstall_anytls"

echo ""
echo "ALL ANYTLS TESTS PASSED"
