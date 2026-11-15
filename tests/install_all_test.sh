#!/usr/bin/env bash
# 一键全装（sbx all）回归测试：SBX_AUTO 非交互模式 + 编排逻辑 + SOCKS5/Argo 排除
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/fakebin"
cat > "$tmp/fakebin/sing-box" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "generate" ]]; then
    case "$2" in
        uuid) echo "11111111-2222-3333-4444-555555555555" ;;
        reality-keypair) printf 'PrivateKey aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nPublicKey bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
        rand) echo "abcd1234" ;;
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
export APP_HOME="$ROOT"
export SB_ETC="$tmp/etc" SB_CERT_DIR="$tmp/etc/certs" SB_EXPORT_DIR="$tmp/etc/export"
export SB_STATE="$tmp/etc/state.json" SB_CONFIG="$tmp/etc/config.json"
export SB_BIN="$tmp/fakebin/sing-box" SBM_VERSION="test"
source "$ROOT/core/state_manager.sh"
source "$ROOT/core/ui.sh"
source "$ROOT/core/json_builder.sh"
source "$ROOT/core/engine.sh"
source "$ROOT/utils/export.sh"
source "$ROOT/protocols/reality.sh"

is_port_used() { return 1; }
init_state_file || fail "state init"

# 1. SBX_AUTO 下 prompt_port 免询问返回随机端口
_p=$(SBX_AUTO=1 prompt_port) || fail "AUTO prompt_port 失败"
[[ "$_p" =~ ^[0-9]+$ ]] && (( _p >= 1 && _p <= 65535 )) || fail "AUTO prompt_port 应返回随机端口"
unset _p

# 2. SBX_AUTO 下 install_reality 全程无阻塞（stdin 关闭）
SBX_AUTO=1 install_reality < /dev/null >/dev/null 2>&1 || fail "AUTO install_reality 失败"
state_has_proto reality || fail "reality 未写入 state"

# 3. install_all_protocols：跳过已安装、安装缺失、排除 SOCKS5
install_hysteria2() { state_set_proto hysteria2 '{"port":8443}'; }
install_tuic() { state_set_proto tuic '{"port":9443}'; }
install_argo() { state_set_proto argo '{"local_port":18080}'; }  # 不应被调用
install_anytls() { state_set_proto anytls '{"port":443}'; }
export_all_nodes() { :; }
eval "$(sed -n '/^install_all_protocols() {/,/^}/p' "$ROOT/sbx.sh")"
declare -f install_all_protocols >/dev/null || fail "install_all_protocols 未提取到"
install_all_protocols < /dev/null >/dev/null 2>&1 || fail "install_all_protocols 失败"
state_has_proto hysteria2 || fail "hy2 未安装"
state_has_proto tuic || fail "tuic 未安装"
! state_has_proto argo || fail "Argo 不应被一键全装安装"
state_has_proto anytls || fail "anytls 应被一键全装安装"
state_has_proto reality || fail "reality 不应被删除"
! state_has_proto socks5 || fail "SOCKS5 不应被一键全装安装"

echo "PASS: install-all AUTO mode, orchestration, SOCKS5/Argo exclusion"
