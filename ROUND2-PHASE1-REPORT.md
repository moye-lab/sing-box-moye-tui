# 第二轮复审 - 第一阶段审查报告

**日期**：2026-11-15
**基线**：v1.7.0（SBM_VERSION="1.7.0"，SBX_VERSION="v1.7.0"）

## 逐项核对结果

| 项 | 内容 | 核对结果 |
|----|------|----------|
| 1 | 安装器版本不一致 | ✅ 已正确：SBX_VERSION="v1.7.0"，README 指向 v1.7.0。需补充：版本一致性检查、发布包 SHA256、安装后版本验证测试 |
| 2 | SHA256 校验失败即终止 | ❌ 真实缺陷：core/engine.sh:102,105 用 log_warn 跳过校验，继续安装 |
| 3 | 配置事务并发锁 | ❌ 真实缺陷：core/json_builder.sh 的 config_transaction 无任何锁 |
| 4 | WARP 路由规则误删 | ❌ 真实缺陷：json_builder.sh:157,164 全局删除所有 sniff/resolve 规则 |
| 5 | 状态锁嵌套释放 | ❌ 真实缺陷：state_manager.sh 用 `trap '_state_unlock; trap - RETURN' RETURN`，嵌套调用会覆盖外层 trap 导致提前解锁 |
| 6 | WARP 健康检查 | ❌ 真实缺陷：warp.sh:287 依赖 api.ipify.org 在分流列表中，无 SOCKS5 时逻辑不完整 |
| 7 | WARP 事务 || true | ❌ 真实缺陷：warp.sh:193,206 用 `|| true` 隐藏关键操作失败 |
| 8 | 内核升级回滚加固 | ⚠️ 部分：需检查 systemd 备份失败处理、原子替换 |
| 9 | 升级锁 /tmp 路径 | ❌ 真实缺陷：engine.sh:44 用 `/tmp/sbx-upgrade.lock` 固定路径 |
| 10 | 状态迁移锁保护 | ❌ 真实缺陷：init_state_file 和 _migrate_state 不在锁保护下，存在竞态 |
| 11 | 跨文件事务机制 | 🆕 新功能：operation_transaction 未实现 |
| 12 | 路由规则归属管理 | ❌ 与项 4 同根：无归属标识 |
| 13 | 自动化回归测试 | 🆕 需新增 14 类测试 |
| 14 | 真实环境验收 | ⚠️ 沙箱无法验证，需标注并提供真机验证步骤 |

## 修复计划

按 P0 → P1 顺序执行，全部修改配对应测试。
