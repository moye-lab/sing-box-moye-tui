#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
source "$ROOT/core/env.sh"
SB_ETC="$TMP/etc"
SB_CERT_DIR="$SB_ETC/certs"
SB_EXPORT_DIR="$SB_ETC/export"
SB_STATE="$SB_ETC/state.json"
SB_CONFIG="$SB_ETC/config.json"
source "$ROOT/core/state_manager.sh"
source "$ROOT/utils/export.sh"
ensure_node_meta() { :; }
get_public_ip() { printf '203.0.113.10\n'; }
get_node_prefix() { printf 'US-LAX "LAB": #1\n'; }
ui_top() { :; }; ui_split() { :; }; ui_kv() { :; }; ui_bot() { :; }
ui_line() { :; }; ui_node_card() { :; }
init_state_file
state_set_proto reality '{"port":443,"uuid":"uuid:value","sni":"example.com","public_key":"public:key","short_id":"a1b2"}'
state_set_proto hysteria2 '{"port":8443,"password":"deadbeef0123456789abcdef","sni":"example.com","insecure":false,"hop_range":""}'
state_set_proto argo '{"uuid":"12345678-1234-1234-1234-123456789abc","path":"/ws?a=1&b=2","domain":"tunnel.example.com","cf_ip":"2001:db8::1,104.16.80.1","local_port":12345,"mode":"quick"}'
export_all_nodes >/dev/null
python3 - "$SB_EXPORT_DIR/mihomo_proxies.yaml" "$SB_EXPORT_DIR/singbox_outbounds.json" "$SB_EXPORT_DIR/links.txt" <<'PY'
import json, sys
from pathlib import Path
import yaml
proxies = yaml.safe_load(Path(sys.argv[1]).read_text())['proxies']
assert len(proxies) == 4, proxies
assert proxies[0]['name'] == 'US-LAX "LAB": #1-Reality', proxies[0]
assert proxies[0]['uuid'] == 'uuid:value'
assert proxies[1]['password'] == 'deadbeef0123456789abcdef'
outbounds = json.loads(Path(sys.argv[2]).read_text())
links = Path(sys.argv[3]).read_text().splitlines()
assert any('@[2001:db8::1]:443?' in link for link in links), links
assert any('path=/ws%3Fa%3D1%26b%3D2' in link for link in links), links
assert len(outbounds) == 4
assert proxies[2]['name'].endswith('-Argo-1')
assert proxies[3]['name'].endswith('-Argo-2')
assert proxies[2]['server'] == '2001:db8::1'
assert proxies[2]['ws-opts']['path'] == '/ws?a=1&b=2'
PY
[[ "$(urlencode_path '/ws?a=1&b=2')" == '/ws%3Fa%3D1%26b%3D2' ]] || { echo 'FAIL: websocket path encoding' >&2; exit 1; }
echo 'PASS: Mihomo YAML escaping, Sing-box JSON export and WebSocket path encoding'
