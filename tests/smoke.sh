#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

while IFS= read -r -d '' f; do
    bash -n "$f" || fail "bash syntax: $f"
done < <(find "$ROOT" -type f -name '*.sh' -print0)

jq -e . "$ROOT/templates/base.json" >/dev/null || fail "base JSON invalid"
if sed -n '/^export_all_nodes() {/,/^}/p' "$ROOT/utils/export.sh" | grep -qi 'socks5'; then
    fail "SOCKS5 must not be included in node export generation"
fi
grep -q 'refresh_legacy_exports' "$ROOT/utils/export.sh" || fail "legacy SOCKS5 export migration missing"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
source "$ROOT/core/env.sh"
export APP_HOME="$ROOT"
export SB_ETC="$tmp/etc"
export SB_CERT_DIR="$SB_ETC/certs"
export SB_EXPORT_DIR="$SB_ETC/export"
export SB_STATE="$SB_ETC/state.json"
export SBM_VERSION="test"
log_err() { :; }
source "$ROOT/core/state_manager.sh"
source "$ROOT/core/json_builder.sh"
source "$ROOT/utils/export.sh"

is_valid_ip "1.1.1.1" || fail "valid IPv4 rejected"
is_valid_ip "2606:4700:4700::1111" || fail "valid IPv6 rejected"
! is_valid_ip "999.999.999.999" || fail "invalid IPv4 accepted"
! is_valid_ip "not-an-ip" || fail "invalid IP accepted"
valid_domain_name "example.com" || fail "valid domain rejected"
! valid_domain_name "bad..example" || fail "invalid domain accepted"
valid_host_or_ip "1.1.1.1" || fail "valid IPv4 rejected"
! valid_host_or_ip "bad host" || fail "invalid host accepted"
! valid_host_or_ip "999.999.999.999" || fail "invalid IPv4 accepted"
is_port_used() { return 1; }
if printf 'q\\n' | prompt_port >/dev/null 2>&1; then
    fail "port prompt cancellation should fail"
fi
# 无默认时回车应返回随机端口（1-65535）
_p=$(printf '\n' | prompt_port 2>/dev/null) || fail "port prompt random failed"
[[ "$_p" =~ ^[0-9]+$ ]] && (( _p >= 1 && _p <= 65535 )) || fail "random port out of range: $_p"
# 手动输入端口
[[ "$(printf '8443\n' | prompt_port 2>/dev/null)" == "8443" ]] || fail "manual port input failed"
# 带默认时回车用默认（修改场景）
[[ "$(printf '\n' | prompt_port 9443 2>/dev/null)" == "9443" ]] || fail "default port not honored"
unset _p

init_state_file || fail "state init"
[[ "$(stat -c '%a' "$SB_STATE" 2>/dev/null || stat -f '%Lp' "$SB_STATE")" == "600" ]] || fail "state permissions"
state_set_proto reality '{"port":443,"uuid":"test"}' || fail "state write"
[[ "$(state_get_field reality port)" == "443" ]] || fail "state read"
state_set_field reality port 8443 || fail "field update"
[[ "$(state_get_field reality port)" == "8443" ]] || fail "field read after update"
state_del_proto reality || fail "state delete"
! state_has_proto reality || fail "protocol should be deleted"
set_custom_node_prefix "Test-Node" || fail "safe prefix rejected"
set_custom_node_prefix 'Node "quoted" \\ path' || fail "quoted custom prefix rejected"
! set_custom_node_prefix "$(printf 'x%.0s' {1..65})" || fail "overlong custom prefix accepted"
# A pre-v2 auto-generated prefix must migrate; explicit custom names must survive.
jq '.meta.node_prefix = "🇺🇸 US-RN-LAX" | .meta.custom_prefix = "🇺🇸 US-RN-LAX" | del(.meta.naming_version)' "$SB_STATE" > "$SB_STATE.tmp" && mv "$SB_STATE.tmp" "$SB_STATE"
# Avoid network during this migration test by mocking the metadata provider.
curl() { printf '{"success":true,"ip":"203.0.113.9","country_code":"US","city":"Los Angeles","connection":{"isp":"Example","org":"Example","asn":"AS64500"}}'; }
ensure_node_meta || fail "legacy naming migration"
[[ "$(jq -r '.meta.node_prefix' "$SB_STATE")" =~ ^US-[a-z0-9-]+$ ]] || fail "legacy automatic prefix not migrated"
[[ "$(jq -r '.meta.naming_version' "$SB_STATE")" == "3" ]] || fail "naming schema version missing"
set_custom_node_prefix "My-Manual-Node" || fail "custom prefix setup"
jq 'del(.meta.naming_version)' "$SB_STATE" > "$SB_STATE.tmp" && mv "$SB_STATE.tmp" "$SB_STATE"
ensure_node_meta || fail "custom naming migration"
[[ "$(jq -r '.meta.node_prefix' "$SB_STATE")" == "My-Manual-Node" ]] || fail "manual custom prefix was not preserved"
get_node_prefix() { echo "US-vps01"; }
[[ "$(node_name VLESS-Reality)" == "US-vps01-Reality" ]] || fail "compact VLESS node naming format"
[[ "$(node_name Hysteria2)" == "US-vps01-Hy2" ]] || fail "compact HY2 node naming format"
[[ "$(node_name TUIC)" == "US-vps01-TUIC" ]] || fail "compact TUIC node naming format"
[[ "$(node_name VLESS-WS 2)" == "US-vps01-Argo-2" ]] || fail "indexed node naming format"
[[ "$(yaml_quote 'a:b')" == '"a:b"' ]] || fail "YAML scalar escaping"
! set_custom_node_prefix $'bad\nname' || fail "multiline prefix accepted"

export SB_CONFIG="$SB_ETC/config.json"
export SB_BIN="$tmp/no-sing-box"
ensure_base_config || fail "base config creation"
reload_singbox_service() { return 0; }
apply_inbound add test-in '{"type":"socks","tag":"test-in","listen":"127.0.0.1","listen_port":12345}' || fail "inbound add"
[[ "$(jq -r '.inbounds[0].tag' "$SB_CONFIG")" == "test-in" ]] || fail "inbound missing after add"
[[ "$(stat -c '%a' "$SB_CONFIG" 2>/dev/null || stat -f '%Lp' "$SB_CONFIG")" == "600" ]] || fail "config permissions"
apply_inbound del test-in || fail "inbound delete"
[[ "$(jq '.inbounds | length' "$SB_CONFIG")" == "0" ]] || fail "inbound not removed"

printf '{broken' > "$SB_STATE"
if init_state_file; then fail "corrupt state must be rejected"; fi

if command -v python3 >/dev/null 2>&1; then
    python3 "$ROOT/tests/subscription_test.py" || fail "subscription endpoint test"
    bash "$ROOT/tests/export_test.sh" || fail "export regression test"
    python3 -m py_compile "$ROOT/utils/subscription_server.py" || fail "subscription server syntax"
fi

echo "PASS: shell syntax, base JSON, state CRUD, permissions, corruption guard"
