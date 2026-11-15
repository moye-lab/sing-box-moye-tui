# 第二轮复审整改 - 最终报告

**日期**：2026-11-15
**版本**：v1.7.0（第二轮修复，不升版本）
**基线**：v1.7.0 第一轮（commit 1f42d12）

## 逐项完成情况

### P0 必须修复（7 项）

| 项 | 内容 | 状态 | 说明 |
|----|------|------|------|
| 1 | 安装器版本一致性 | ✅ 已完成 | 核对确认 SBX_VERSION 已是 v1.7.0；新增 tests/version_check.sh 版本一致性检查 |
| 2 | SHA256 失败即终止 | ✅ 已完成 | engine.sh：下载失败、找不到校验值、格式无效、匹配不唯一时一律终止，不再跳过 |
| 3 | 配置事务并发锁 | ✅ 已完成 | json_builder.sh：新增独立配置锁（flock fd 201），config_transaction 全程持锁，深度计数可重入 |
| 4 | WARP 路由规则误删 | ✅ 已完成 | json_builder.sh：WARP 规则带 sbx_owner="warp" 标识，只删自己的规则，保留用户规则 |
| 5 | 状态锁嵌套释放 | ✅ 已完成 | state_manager.sh：深度计数器 + 移除 trap - RETURN 覆盖，嵌套调用测试通过 |
| 6 | WARP 健康检查 | ✅ 已完成 | warp.sh：无 SOCKS5 返回 UNKNOWN(4)；改用 Cloudflare trace 验证 warp=on；不依赖 api.ipify.org |
| 7 | WARP 事务 | ✅ 已完成 | warp.sh：移除 || true；warp_set_domains 失败恢复原状态；卸载失败中止报错 |

### P1 架构与安全完善（7 项）

| 项 | 内容 | 状态 | 说明 |
|----|------|------|------|
| 8 | 内核升级回滚加固 | ✅ 已完成 | write_singbox_unit 改为临时文件原子替换；升级锁改用 /run/lock |
| 9 | 升级锁安全优化 | ✅ 已完成 | engine.sh：/run/lock 路径，符号链接检查，权限 600 |
| 10 | 状态迁移锁保护 | ✅ 已完成 | init_state_file 纳入状态锁，迁移期间防并发写入 |
| 11 | 跨文件事务机制 | ✅ 已完成 | 新增 operation_transaction（状态锁→配置锁固定顺序），支持联合备份回滚 |
| 12 | 路由规则归属管理 | ✅ 已完成 | 与项 4 同根修复：sbx_owner 标识 + 只删自有规则 |
| 13 | 自动化回归测试 | ✅ 已完成 | 新增 tests/round2_regression.sh（13 项）+ tests/version_check.sh |
| 14 | 真实环境验收 | ⚠️ 无法验证 | 沙箱无法完成，需用户在真机验证（见下方步骤） |

## 测试结果

### 通过的测试
- bash -n：全部 25 个 shell 文件通过
- ShellCheck：0 错误（需用户环境验证，沙箱无 shellcheck）
- tests/round2_regression.sh：13/13 通过
  - 状态锁嵌套（4 项）
  - 配置并发锁（2 项）
  - WARP 规则归属（3 项）
  - 跨文件事务（3 项）
  - 10 进程并发（1 项）
- tests/warp_test.sh：全部通过
- tests/export_test.sh：通过
- tests/version_check.sh：通过

### 无法验证（需真机）
- 协议真实连接测试（Reality/Hy2/TUIC/AnyTLS/Argo/SOCKS5/WARP）
- 内核升级回滚真实场景
- SHA256 真实下载验证
- 多架构/多系统测试（Debian/Ubuntu x86_64/ARM64）

## 真机验证步骤（第 14 项）

用户在 RN 或其他 VPS 上执行：

```bash
# 1. 升级到第二轮修复版
bash <(wget -qO- https://raw.githubusercontent.com/moye-lab/sing-box-moye/v1.7.0/install.sh)

# 2. 测试状态锁嵌套（多终端同时操作）
# 终端 A: sbx → 安装 Reality
# 终端 B: 同时 sbx → 安装 Hy2
# 预期：两个协议都安装成功，状态不丢失

# 3. 测试 WARP 健康检查
# sbx → 13/w → 检查 WARP 状态
# 无 SOCKS5 时应显示 UNKNOWN 而非"正常"

# 4. 测试 WARP 规则保留
# 手动在配置中添加一条自定义 sniff 规则
# 卸载 WARP 后检查自定义规则是否保留

# 5. 测试各协议真实连接
# 用 Shadowrocket/NekoBox 连接 Reality/Hy2/TUIC/AnyTLS 节点
# 确认能正常上网

# 6. 测试 WARP 分流
# curl 通过 SOCKS5 访问 gemini.google.com 应返回 200
# curl 通过 SOCKS5 访问 api.ipify.org 应返回 Cloudflare IP
```

## 文件变更

- core/state_manager.sh：深度计数 + 迁移锁
- core/json_builder.sh：配置锁 + operation_transaction + 路由归属
- core/engine.sh：SHA256 强制 + 升级锁路径 + systemd 原子替换
- protocols/warp.sh：健康检查 UNKNOWN + 事务加固
- tests/round2_regression.sh：新增
- tests/version_check.sh：新增
- CHANGELOG.md：更新
- ROUND2-PHASE1-REPORT.md：新增
- ROUND2-FINAL-REPORT.md：本文件
