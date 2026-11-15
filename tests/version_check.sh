#!/usr/bin/env bash
# tests/version_check.sh — 版本一致性检查
# 验证 install.sh、core/env.sh、README.md、CHANGELOG.md 中的版本号一致

set -u
cd "$(dirname "$0")/.." || exit 1

FAIL=0

# 从 core/env.sh 获取基准版本
BASE_VER=$(grep -m1 'SBM_VERSION=' core/env.sh | sed 's/.*"\([^"]*\)".*/\1/')
if [[ -z "$BASE_VER" ]]; then
    echo "FAIL: 无法从 core/env.sh 读取 SBM_VERSION"
    exit 1
fi
echo "基准版本: $BASE_VER"

# 检查 install.sh
INSTALL_VER=$(grep -m1 'SBX_VERSION=' install.sh | sed 's/.*"\([^"]*\)".*/\1/' | sed 's/^v//')
if [[ "$INSTALL_VER" != "$BASE_VER" ]]; then
    echo "FAIL: install.sh 版本 $INSTALL_VER 与基准 $BASE_VER 不一致"
    FAIL=1
else
    echo "PASS: install.sh 版本一致 ($INSTALL_VER)"
fi

# 检查 README.md 中的安装链接
README_VERS=$(grep -o 'sing-box-moye/v[0-9.]*' README.md | sort -u)
for v in $README_VERS; do
    ver_num="${v#sing-box-moye/v}"
    if [[ "$ver_num" != "$BASE_VER" ]]; then
        echo "FAIL: README.md 包含旧版本链接 $v"
        FAIL=1
    fi
done
if [[ $FAIL -eq 0 ]]; then
    echo "PASS: README.md 版本链接一致"
fi

# 检查 CHANGELOG.md 顶部版本
CHANGELOG_VER=$(grep -m1 '^## v' CHANGELOG.md | sed 's/## v\([0-9.]*\).*/\1/')
if [[ "$CHANGELOG_VER" != "$BASE_VER" ]]; then
    echo "FAIL: CHANGELOG.md 顶部版本 $CHANGELOG_VER 与基准 $BASE_VER 不一致"
    FAIL=1
else
    echo "PASS: CHANGELOG.md 顶部版本一致 ($CHANGELOG_VER)"
fi

if [[ $FAIL -eq 0 ]]; then
    echo "版本一致性检查全部通过"
    exit 0
else
    echo "版本一致性检查失败"
    exit 1
fi
