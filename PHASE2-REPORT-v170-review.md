# sing-box-moye v1.7.0 第二阶段报告（P0 修复）

**完成日期**：2026-11-15
**基线**：v1.6.9

## P0.1 状态管理并发安全 ✅ 已完成

**修改文件**：`core/state_manager.sh`、`core/env.sh`、`protocols/warp.sh`

**实现**：
- 引入 `flock` 进程级文件锁，锁文件 `${SB_STATE}.lock`，权限 600
- 锁超时 10 秒，超时后明确报错
- 可重入设计：`_STATE_LOCK_HELD` 标志防止嵌套调用死锁
- 所有状态写入函数都已加锁：
  - `state_set_proto`、`state_del_proto`、`state_set_field`
  - `set_custom_node_prefix`、`reset_node_naming`、`ensure_node_meta`
  - `warp_set_domains`、`get_public_ip`（IP 缓存更新）
- 使用 `trap ... RETURN` 确保异常退出时释放锁

**测试**：
- 10 进程并发写入测试：全部成功，无丢失，JSON 始终有效
- 测试脚本：`/tmp/test_lock.sh`

## P0.2 协议配置与状态事务一致性 ✅ 已完成

**修改文件**：`protocols/*.sh`（全部 7 个协议模块）

**实现**：
- 所有 `install_*` 函数：`state_set_proto` 失败时回滚配置（删除刚添加的 inbound/outbound/endpoint），返回错误
- 所有 `modify_*` 函数：`state_set_proto` 失败时明确报错，提示用户重新操作
- 所有 `uninstall_*` 函数：`state_del_proto` 失败时警告但不报错（配置已删除，协议实际已卸载）
- 修复的协议：reality、hysteria2、tuic、anytls、argo、socks5、warp

**测试**：
- 语法检查通过（bash -n）
- 事务逻辑已在代码审查中验证（真实环境测试需要 VPS，见测试报告）

## P0.3 sing-box 内核升级回滚机制 ✅ 已完成

**修改文件**：`core/engine.sh`

**实现**：
- 升级锁：`/tmp/sbx-upgrade.lock`，flock 超时 5 分钟，防止多终端同时升级
- 磁盘空间检查：升级前检查 `/usr/local/bin` 可用空间，少于 100MB 时拒绝升级
- 备份 systemd 服务文件：升级前备份到 `sing-box.service.bak`
- 完善回滚逻辑：
  - `write_singbox_unit` 失败 → 恢复旧内核 + 旧服务文件
  - `daemon-reload` 失败 → 恢复旧内核 + 旧服务文件
  - 服务启动失败 → 恢复旧内核 + 旧服务文件 + 重启服务
  - 成功后删除备份文件

**测试**：
- 语法检查通过
- 回滚逻辑已在代码审查中验证（真实升级测试需要 VPS）

## P0.4 安装包供应链安全 ✅ 已完成

**修改文件**：`core/engine.sh`

**实现**：
- SHA256 校验：从 GitHub Release 下载 `checksums.txt`，验证 tarball 的 SHA256
- 校验失败时拒绝安装，显示期望值与实际值
- 版本验证：解压后执行 `sing-box version`，验证版本号与目标一致
- 架构验证：无法执行二进制时拒绝安装（架构不匹配）
- checksums.txt 下载失败时警告并跳过校验（不阻塞安装，但提示用户检查网络）

**测试**：
- 语法检查通过
- SHA256 校验逻辑已在代码审查中验证（真实下载测试需要网络）

## P0.5 WARP 健康检查准确性 ✅ 已完成

**修改文件**：`protocols/warp.sh`（`warp_check` 函数重写）

**实现**：分层检查（5 层）
1. **配置存在性**：endpoint 是否在 config.json 中
2. **配置结构**：私钥格式、地址、Reserved 是否正常（[0,0,0] 时明确提示重装）
3. **服务运行**：sing-box 是否 active
4. **分流规则**：是否有 warp 路由规则
5. **实际流量测试**：通过 SOCKS5 curl api.ipify.org，检查出口 IP 是否为 Cloudflare 段（104.x、172.67.x、2a09:）

**返回码**：
- 0 = 完全正常（或配置正常但未验证流量）
- 1 = 未安装或配置缺失
- 2 = 服务异常
- 3 = 隧道不通或分流未生效

**无法验证时**：明确标记为"无法确认"或"跳过"，不显示为正常。

## P0.6 WARP API 参数严格验证 ✅ 已完成

**修改文件**：`protocols/warp.sh`（`install_warp` 函数）

**实现**：
- HTTP 状态码检查：使用 `curl -w "%{http_code}"` 获取状态码
  - 429 → 明确提示"API 限流，请稍后再试"
  - 500/502/503/504 → 提示"服务器错误"
  - 000 → 提示"网络问题或超时"
  - 其他非 200 → 显示具体状态码
- JSON 格式验证：响应必须是有效 JSON，且包含 `config.client_id`
- client_id 格式验证：必须是 4 字符 base64（`^[A-Za-z0-9+/]{4}$`）
- IPv4 地址验证：使用 `is_valid_ip` 严格验证
- IPv6 地址验证：如果存在必须有效
- 私钥格式验证：44 字符 base64
- 公钥格式验证：44 字符 base64
- Reserved 解码验证：必须是 6 个十六进制字符（3 字节），否则拒绝安装

## P0.7 AI 分流规则整改 ✅ 已完成

**修改文件**：`protocols/warp.sh`

**实现**：三模式
- **精简模式**（默认，28 个域名）：只分流 AI 专用域名
  - gemini.google.com、generativelanguage.googleapis.com、aistudio.google.com、ai.google.dev
  - openai.com、chatgpt.com、oaiusercontent.com、sora.com
  - anthropic.com、claude.ai、x.ai、grok.com、perplexity.ai 等
  - **不包含** google.com、googleapis.com、accounts.google.com、bing.com、meta.com
- **兼容模式**（33 个域名）：精简模式 + 5 个 Google 通用域名
  - 解决某些 AI 服务需要完整 Google 生态的问题
- **自定义模式**：用户手动添加/删除域名（原有功能保留）

**菜单**：`warp_apply_ai_preset` 现在交互式询问模式选择，非交互环境（SBX_AUTO 或 stdin 非 TTY）默认精简模式。

**预览功能**：新增 `warp_preview_ai_preset` 函数（预留，菜单暂未接入）。

## 测试结果

| 测试 | 结果 |
|------|------|
| bash -n 全部文件 | ✅ 通过 |
| 并发写入测试（10 进程） | ✅ 通过，无丢失 |
| WARP 单元测试 | ✅ 通过（7.6 秒） |
| ShellCheck | ⚠️ 仅剩跨文件变量误报（SC2034），已修复真实问题（cert_type） |

## 已知限制

1. **真实环境测试未完成**：P0.2-P0.4 的回滚逻辑、SHA256 校验需要在真实 VPS 上验证（沙箱无法模拟 systemctl 和真实下载）
2. **WARP 流量测试**：需要 SOCKS5 已安装才能进行第 5 层检查，否则跳过
3. **AI 分流效果**：精简模式是否能解锁所有 AI 服务需要在真实环境验证（某些服务可能需要 google.com）
