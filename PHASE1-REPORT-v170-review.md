# sing-box-moye v1.7.0 第一阶段审查报告

**审查日期**：2026-11-15
**基线版本**：v1.6.9 (commit 1f42d12)
**审查范围**：23 个 shell 文件，2597 行代码

## 一、项目结构

```
sing-box-moye/
├── sbx.sh                  # 主入口，菜单系统 (10782 字节)
├── install.sh              # 安装器 (2499 字节)
├── core/
│   ├── env.sh              # 环境变量、工具函数
│   ├── ui.sh               # 终端 UI 组件
│   ├── state_manager.sh    # 状态文件管理
│   ├── json_builder.sh     # sing-box 配置构建
│   └── engine.sh           # 内核安装/升级/卸载
├── protocols/
│   ├── reality.sh          # VLESS-Reality
│   ├── hysteria2.sh        # Hysteria 2
│   ├── tuic.sh             # TUIC v5
│   ├── anytls.sh           # AnyTLS
│   ├── argo.sh             # Cloudflare Argo
│   ├── socks5.sh           # SOCKS5
│   └── warp.sh             # WARP + 域名分流
├── utils/
│   ├── cert.sh             # 证书管理
│   ├── export.sh           # 节点导出
│   ├── subscription.sh     # 订阅服务
│   └── sysctl.sh           # 系统调优
├── templates/
│   └── base.json           # 基础配置模板
└── tests/
    ├── smoke.sh            # 冒烟测试
    ├── warp_test.sh        # WARP 测试
    ├── export_test.sh      # 导出测试
    ├── install_all_test.sh # 一键全装测试
    └── anytls_test.sh      # AnyTLS 测试（已损坏，硬编码 /tmp/review/ 路径）
```

## 二、P0 问题清单（已确认的真实缺陷）

### 2.1 状态管理并发安全（严重）

**文件**：`core/state_manager.sh`

**问题**：
- 所有状态写入函数（`state_set_proto`、`state_del_proto`、`state_set_field`、`ensure_node_meta`、`set_custom_node_prefix` 等）都使用 `mktemp + jq + mv` 原子替换，但**没有文件锁**。
- 两个终端同时操作时，后写入的会覆盖先写入的，导致状态丢失。
- `init_state_file` 的进程内缓存（`_SB_INIT_DONE`）在多进程场景下无效。

**影响**：多终端同时安装不同协议时，可能丢失其中一个协议的状态。

**修复方案**：
- 引入 `flock` 进程级文件锁，锁文件 `${SB_STATE}.lock`
- 所有状态写入必须获取锁（超时 10 秒）
- 锁文件权限 600，属主 root
- 使用 `trap` 确保异常退出时释放锁

### 2.2 协议配置与状态写入事务不一致（严重）

**文件**：所有 `protocols/*.sh`

**问题**：
以 `reality.sh` 为例：
```bash
if apply_inbound "add" "reality-in" "$inbound_json"; then
    state_set_proto "reality" "$state_data"  # ← 如果这步失败，配置已生效但状态缺失
    log_ok "VLESS-Reality 安装并启动成功！"
fi
```

- `apply_inbound` 成功后，`state_set_proto` 失败时，函数仍然返回成功（没有检查返回值）
- 导致配置存在但状态缺失，菜单显示"未安装"但实际端口在监听
- 反之，`state_del_proto` 失败时，卸载会报告成功但状态残留

**影响**：配置与状态不一致，用户无法管理已安装的协议。

**修复方案**：
- 所有 `state_set_proto`/`state_del_proto` 调用必须检查返回值
- 状态写入失败时，回滚配置（删除刚添加的 inbound/outbound/endpoint）
- 统一事务接口：`proto_install_complete` 和 `proto_uninstall_complete`

### 2.3 sing-box 内核升级回滚不完整（中等）

**文件**：`core/engine.sh` (`install_singbox_core`)

**问题**：
- 备份了旧内核（`${SB_BIN}.bak`），但**没有备份 systemd 服务文件**
- `write_singbox_unit` 失败时没有回滚（函数没有返回值检查）
- `systemctl daemon-reload` 失败时直接 `return 1`，没有恢复旧内核
- 没有升级锁，两个终端同时升级会互相干扰
- 没有磁盘空间检查
- 没有 SHA256 校验（见 2.4）

**影响**：升级中途失败可能留下半升级状态，服务无法启动。

**修复方案**：
- 备份 systemd 服务文件到 `/etc/systemd/system/sing-box.service.bak`
- `write_singbox_unit` 和 `daemon-reload` 失败时恢复旧内核和旧服务文件
- 引入升级锁 `${SB_BIN}.upgrade.lock`，超时 5 分钟
- 升级前检查磁盘空间（至少 100MB 可用）
- 增加 SHA256 校验（见 2.4）

### 2.4 安装包供应链安全缺失（严重）

**文件**：`core/engine.sh`、`install.sh`、`core/env.sh`

**问题**：
- `install_singbox_core` 下载 sing-box tarball 后，**只检查 tar 格式和路径穿越，没有 SHA256 校验**
- 没有验证下载文件的架构是否匹配
- 没有验证版本号与目标版本是否一致
- `install.sh` 的远程引导下载 tarball 后直接解压执行，**没有任何完整性验证**
- GitHub API 限流时没有明确提示

**影响**：中间人攻击或 CDN 污染可能导致安装恶意二进制。

**修复方案**：
- 从 GitHub Release 下载 `checksums.txt`，验证 SHA256
- 校验失败时拒绝安装
- 验证解压后的二进制架构（`file` 命令或 `sing-box version` 输出）
- 验证版本号与预期一致
- `install.sh` 引导下载时验证 tarball SHA256（从 GitHub API 获取）
- GitHub API 限流时显示明确错误和重试建议

### 2.5 WARP 健康检查不准确（中等）

**文件**：`protocols/warp.sh` (`warp_check`)

**问题**：
```bash
warp_check() {
    if jq -e '.endpoints[] | select(.tag == "warp")' "$SB_CONFIG" >/dev/null 2>&1; then
        log_ok "WARP 端点已在配置中。"  # ← 仅检查配置存在，不代表隧道通
        return 0
    fi
}
```

- 只检查配置中是否存在 endpoint，不能证明隧道已建立
- 不能证明流量实际走 WARP
- 不能证明出口 IP 是 Cloudflare

**影响**：用户看到"正常"但实际分流不工作（v1.6.5-v1.6.8 的教训）。

**修复方案**：
建立分层检查：
1. 配置存在性（endpoint 在 config.json 中）
2. 服务运行状态（systemctl is-active）
3. 端口监听检查（SOCKS5 入站是否监听）
4. 实际流量测试（通过 SOCKS5 curl api.ipify.org，检查返回 IP 是否为 Cloudflare 段）
5. 分流规则检查（route.rules 中是否有 warp 规则）

无法验证的状态明确标记为"无法确认"，不显示为正常。

### 2.6 WARP API 参数验证不严格（中等）

**文件**：`protocols/warp.sh` (`install_warp`)

**问题**：
- 只检查 `jq -e '.config.client_id'`，不检查 HTTP 状态码
- 不验证 client_id 格式（应为 4 字符 base64）
- 不验证 IPv4/IPv6 地址格式
- 不验证 Reserved 解码结果长度（应为 3 字节）
- API 超时、限流时没有区分错误类型
- 临时文件权限未明确设置（openssl 生成的密钥在内存中，相对安全）

**影响**：API 返回异常数据时可能生成无效配置，或用错误数据继续安装。

**修复方案**：
- 使用 `curl -w "%{http_code}"` 检查 HTTP 状态码（200 才继续）
- 验证 client_id 匹配 `^[A-Za-z0-9+/]{4}$`（4 字符 base64）
- 验证 IPv4/IPv6 地址格式（用 `is_valid_ip`）
- 验证 Reserved 解码后为 6 个十六进制字符（3 字节）
- 区分 429（限流）、500（服务器错误）、超时等不同错误
- 敏感数据不输出到日志

### 2.7 AI 分流规则过于宽泛（中等）

**文件**：`protocols/warp.sh` (`WARP_AI_DOMAINS`)

**问题**：
当前 33 个域名中包含：
- `google.com` — 整个 Google 主域名，所有 Google 服务都走 WARP
- `googleapis.com` — 所有 Google API
- `accounts.google.com` — Google 账号服务

这导致普通 Google 搜索、Gmail、YouTube 等也走 WARP，影响正常使用。

**影响**：用户只想解锁 Gemini，但所有 Google 流量都被分流。

**修复方案**：
建立三模式：
- **精简模式**（默认）：只分流 AI 专用域名（gemini.google.com、generativelanguage.googleapis.com、aistudio.google.com、ai.google.dev、openai.com、chatgpt.com 等），不包含 google.com/googleapis.com/accounts.google.com
- **兼容模式**：包含 google.com 等大域名（解决某些 AI 服务需要完整 Google 生态的问题）
- **自定义模式**：用户手动添加/删除域名

菜单中提供模式选择和预览功能。

## 三、P1 问题清单

### 3.1 配置事务逻辑重复

**文件**：`core/json_builder.sh`

`apply_inbound`、`apply_outbound`、`apply_endpoint`、`apply_route_rules` 四个函数有大量重复代码：
- 创建 tmp_cfg/bak_cfg
- cp 备份
- chmod 600
- jq 处理
- 调用 `_commit_config`

**修复**：抽取统一的 `config_transaction` 函数，接受一个 jq 过滤器参数。

### 3.2 状态 Schema 无版本管理

**文件**：`core/state_manager.sh`

- 状态文件有 `version` 字段（存 SBM_VERSION），但没有独立的 `schema_version`
- 结构变化时没有迁移机制
- 旧版本状态文件可能被新版本直接覆盖

**修复**：
- 增加 `schema_version` 字段（当前为 1）
- 每次结构变化时递增版本号并提供迁移函数
- 迁移前自动备份，迁移后验证，失败恢复

### 3.3 协议模块接口不统一

**文件**：`protocols/*.sh`

- 各协议的 `install_*`、`uninstall_*`、`modify_*` 函数签名不一致
- 错误处理方式不同（有的 return 1，有的直接 exit）
- 状态写入方式不同

**修复**：建立协议模块规范文档，统一接口约定（不强制重构现有代码，避免引入回归）。

### 3.4 ShellCheck 警告

运行 ShellCheck v0.10.0（-S warning）：
- 15 个 SC2034 警告（变量看似未使用，实际是跨文件使用，误报）
- 1 个 SC2120 警告（`ensure_node_meta` 引用参数但从未传递，实际有默认值，误报）
- 3 个 SC2034 警告（`cert_type` 变量未使用，真实问题，可删除）

**修复**：删除未使用的 `cert_type` 变量；其他 SC2034 添加 `# shellcheck disable=SC2034` 注释说明。

### 3.5 其他 P1 问题

- **日志系统**：没有统一错误码，没有日志轮转，敏感数据可能泄露到日志
- **输入验证**：部分用户输入未严格验证（如 Argo Token、订阅 Token）
- **文件权限**：临时文件权限基本正确，但部分路径未明确设置
- **订阅服务**：Token 生成使用 `openssl rand -hex 32`（安全），但没有限流
- **systemd 安全**：sing-box 服务已有基本沙箱（NoNewPrivileges、CapabilityBoundingSet），可进一步加固
- **文档**：AUDIT_REPORT.md 停留在 v1.5.1，与当前 v1.6.9 不一致；README 需要更新 WARP 功能说明

## 四、测试现状

- `tests/smoke.sh`：基础测试，通过
- `tests/warp_test.sh`：WARP 测试，通过
- `tests/export_test.sh`：导出测试，通过
- `tests/install_all_test.sh`：一键全装测试，通过
- `tests/anytls_test.sh`：**已损坏**，硬编码 `/tmp/review/` 路径，需要修复

**缺失的测试**：
- 并发写入测试
- 配置事务回滚测试
- 内核升级回滚测试
- 异常注入测试（磁盘满、权限错误、网络中断等）
- 多架构测试（仅 amd64 有测试）

## 五、审查结论

项目基础扎实，核心功能稳定。P0 问题主要集中在：
1. 并发安全（无文件锁）
2. 事务一致性（配置与状态可能不一致）
3. 供应链安全（无 SHA256 校验）
4. WARP 健康检查（只查配置不查实际连通性）

这些问题都是真实存在的，需要在 v1.7.0 中修复。P1 问题以架构优化和文档完善为主。

**建议实施顺序**：
1. P0.1 状态锁（flock）
2. P0.2 事务一致性（检查返回值 + 回滚）
3. P0.4 SHA256 校验
4. P0.3 内核升级回滚
5. P0.6 WARP API 验证
6. P0.5 WARP 健康检查
7. P0.7 AI 分流三模式
8. P1 架构优化
9. 测试体系完善
10. 文档更新
