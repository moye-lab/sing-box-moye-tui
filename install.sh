#!/usr/bin/env bash
set -e

SBX_VERSION="v1.7.0"
# TUI 实验分支：远程安装必须从本实验仓库拉包，不得指向主线仓库
# （2026-11-15 实测：此前 URL 写死 sing-box-moye，一键安装装的是主线代码，
# 用户在 RN 上跑的根本不是 TUI，方向键自然无效）。
SBX_REPO="sing-box-moye-tui"
SBX_TAG="v1.7.0-tui"

# 远程一键安装引导：当通过 bash <(wget -qO- ...) / curl ... | bash 方式执行时，
# BASH_SOURCE 指向 /dev/fd/63 等非真实路径，身边没有 core/env.sh，
# 此时先下载发布包到临时目录再转交执行。
_SCRIPT_SRC="${BASH_SOURCE[0]}"
if [[ "$_SCRIPT_SRC" == /dev/fd/* ]] || [[ ! -f "$(dirname "$_SCRIPT_SRC")/core/env.sh" ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo "请使用 root 权限执行一键安装！"
        exit 1
    fi
    _TMPD="$(mktemp -d)"
    trap 'rm -rf "$_TMPD"' EXIT
    _URL="https://github.com/moye-lab/${SBX_REPO}/archive/refs/tags/${SBX_TAG}.tar.gz"
    echo "正在下载 ${SBX_REPO} ${SBX_TAG} ..."
    if command -v wget >/dev/null 2>&1; then
        wget -qO "${_TMPD}/pkg.tar.gz" "$_URL"
    else
        curl -fsSL -o "${_TMPD}/pkg.tar.gz" "$_URL"
    fi
    tar -xzf "${_TMPD}/pkg.tar.gz" -C "$_TMPD"
    exec bash "${_TMPD}/${SBX_REPO}-${SBX_TAG#v}/install.sh" "$@"
fi
unset _SCRIPT_SRC _TMPD _URL

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 权限执行 install.sh！"
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/usr/local/etc/sbx"

source "${SRC_DIR}/core/env.sh"
command -v systemctl >/dev/null 2>&1 || {
    echo "当前系统未检测到 systemd/systemctl；本项目目前要求 systemd 环境。"
    exit 1
}
install_deps

mkdir -p "$TARGET_DIR"
if [[ "$SRC_DIR" != "$TARGET_DIR" ]]; then
    cp -a "${SRC_DIR}/." "$TARGET_DIR"/
fi
chmod +x "$TARGET_DIR/sbx.sh" "$TARGET_DIR/install.sh"
chmod +x "$TARGET_DIR"/core/*.sh "$TARGET_DIR"/protocols/*.sh "$TARGET_DIR"/utils/*.sh

# 清理旧版 sbm 残留（命令更名升级衔接）
systemctl stop sbm-hop 2>/dev/null || true
systemctl disable sbm-hop 2>/dev/null || true
rm -f /etc/systemd/system/sbm-hop.service
systemctl stop sbm-subscription.service 2>/dev/null || true
systemctl disable sbm-subscription.service 2>/dev/null || true
rm -f /etc/systemd/system/sbm-subscription.service
rm -f /usr/local/bin/sbm
if [[ "$SRC_DIR" != "/usr/local/etc/sb-modular" ]]; then
    rm -rf /usr/local/etc/sb-modular
fi
systemctl daemon-reload 2>/dev/null || true

# 设置全局指令: sbx
ln -sf "$TARGET_DIR/sbx.sh" /usr/local/bin/sbx

log_ok "sing-box-moye (v${SBM_VERSION}) 已安装！以后输入 'sbx' 即可随时启动管理面板。"
if [[ -t 0 && -t 1 ]]; then
    /usr/local/bin/sbx
else
    echo "安装完成。请在终端执行：sbx"
fi
