# Changelog

## v1.7.0 — 2026-11-15（第二轮复审整改）

### TUI 实验分支（实验性 UI 重构，未合主线）

> 本条目仅存在于 TUI 实验分支，版本号保持 1.7.0 不变；主线 v1.7.0 不含以下改动。

- **新 UI 架构**：`core/ui.sh` 248 行单文件拆为 12 个模块（`core/ui/`：初始化/主题/终端/布局/组件/输入/导航/对话框/进度/状态/仪表盘/兼容层），共 1028 行；30 个旧 UI 接口签名全部不变。
- **方向键导航**：新增 `ui_menu_select`（TTY 下 ↑↓ 高亮 + 回车确认 + Esc 返回 + q 退出，数字/字母快捷键直达，两位数快捷键 10–13 快按支持；非 TTY 自动降级行输入）；15 个页面全部统一为该导航模式。
- **主界面升级**：运维控制台主菜单（品牌头 + 状态仪表盘 + 四组导航 + 页脚）、分组维护菜单、结构化诊断（结果药丸 + 失败建议）。
- **页面重构**：6 个协议菜单、WARP 菜单（只读状态探针，出口验证显示上次 [1/c] 检测的持久化结果）、订阅中心（只读节点统计）、命名中心、在线订阅服务、网络调优（“已配置 vs 实际生效”两栏）、彻底卸载（删除/保留清单 + 四阶段执行报告）。
- **宽度自适应**：120/100/80/60/40/30 六档（wide/normal/compact/narrow/plain），面板内容永不越界；`NO_COLOR`/`SBM_ASCII`/`SBM_COLS` 行为保留，新增 `SBM_MENU_LINE`（强制行输入）与 `SBM_NO_ANIM`（禁用动画）。
- **业务零改动**：`declare -f` 逐函数审计——118 个函数逐字节一致，28 个不同函数全部在 UI 允许清单内，新增 33 个函数全部为 UI 层；CLI 40 条用例与 v1.7.0 基线逐字节一致。
- **测试**：新增 `tests/ui_test.sh`（74 项）与 `tests/ui_twokey_test.sh`（9 项 PTY）；Phase 4 回归总计 430/430 可计数断言通过。详见 `UI-REDESIGN-REPORT.md`、`UI-TEST-REPORT.md`、`UI-COMPATIBILITY-REPORT.md`；展示样本见 `docs/ui-samples/`。
- **Termius 方向键修复（2026-11-15）**：根因是本分支 `install.sh` 下载地址仍指向主线仓库，一键安装装的是主线代码（纯 `read -rp` 菜单，无方向键支持）。修复：①引导地址改指 `sing-box-moye-tui` 仓库 + `v1.7.0-tui` tag；②TTY 判定不再以 TERM 为硬性条件（新增 `ui_tty_ready` + `SBM_DEBUG_MENU=1` 调试输出）；③行模式降级在 TTY 下逐字节读键，方向键可导航且不漏出 `^[[` 回显（新增 `_ui_menu_line_keys` / `ui_menu_read_key`，主菜单与维护菜单降级分支改用）；④`stty sane` 重试一次后再降级；⑤快捷命令提示按终端宽度自适应（≥96 单行 / 60–95 两行 / <60 短格式）。新增 `tests/termius_fix_test.sh`（30 项，含 PTY 实测）。详见 `TERMIUS-FIX-REPORT.md`。
- **面板内导航修复（2026-11-15）**：主菜单先画仪表盘（含全部 15 项），再调 `ui_menu_select` 又在下方重画一遍列表，用户反馈“更麻烦了”。修复：新增面板导航 API（`ui_panel_begin/add/add_menu/add_hint/print/redraw` + `ui_menu_select_panel`），主菜单与维护菜单改为逐行捕获面板、方向键在面板内移动高亮（反显整行），不再另画列表；entries 按面板视觉顺序排列（13/w 在 11/s 之前），↓ 沿视觉顺序移动；NO_COLOR 下用 `»` 标记选中行（无 ANSI），非 TTY 输出无高亮 ANSI；行模式降级与 `SBM_MENU_LINE=1`/`SBM_DEBUG_MENU=1` 行为不变。子菜单（协议/WARP/调优等）面板只含状态信息、选项本就由选择器单独渲染，无重复问题，未动。新增 `tests/panel_nav_test.sh`（39 项，含主菜单/维护菜单 PTY 端到端）。详见 `PANEL-NAV-FIX-REPORT.md`。
- **WARP 分流 sbx_owner 修复（2026-11-15，紧急）**：第二轮复审给 WARP 路由规则加了 `sbx_owner="warp"` 标识字段，但 sing-box 配置 schema 不认未知字段，`sing-box check` 报 `unknown field "sbx_owner"`，真机上 AI 分流应用失败（RN 实测）。修复：从 config.json 中彻底移除 `sbx_owner`，改用结构识别——出站规则按 tag 匹配，resolve 规则按 domain_suffix 与 WARP 出站规则完全一致匹配；写入时清理裸 sniff 规则（避免积累），清空时保留裸 sniff（通用无害）；用户自定义规则（其他出站、其他域名的 resolve）一律保留。新增 `tests/warp_sbx_owner_fix_test.sh`（18 项，含真实 sing-box 1.14.4 check + run 验证）。详见 `WARP-SBX-OWNER-FIX-REPORT.md`。
- **WARP 健康检查误报修复（2026-11-15）**：`warp_check` 第 5 层读取了 `test_domain` 却未使用，硬编码测试 `www.cloudflare.com/cdn-cgi/trace`，而该域名不在分流列表中（28 个 AI 域名不含它），trace 流量走直连，必然返回原生 IP + warp=off，真机上误报“隧道不通”（RN 实测：前 4 层全过，第 5 层失败）。修复：测试前检查 trace 域名是否在分流列表中，不在则临时加入（`warp_set_domains`，状态+配置原子提交），测试后恢复原列表；单返回点结构保证所有路径都执行恢复，另设 RETURN trap 安全网（`_warp_check_restore_temp_domains`，调用 `warp_set_domains` 后重新安装，因其内部会覆盖 RETURN trap）；trace 域名已在列表中时不做任何改动（无多余服务重载）。新增 `tests/warp_healthcheck_fix_test.sh`（36 项，含伪造 curl 的 warp=on/off/失败三态、28 域名端到端、真实 sing-box 1.14.4 check + run 验证）。详见 `WARP-HEALTHCHECK-FIX-REPORT.md`。
- **WARP 出口验证状态持久化（2026-11-15）**：`[1/c]` 健康检查五层全过、显示“WARP 状态：on”后，返回菜单顶部仍显示“出口验证 ● 未验证”。根因：`warp_check` 未把测试结果保存到 state，菜单渲染写死了“未验证”。修复：检查成功时保存 `verified_at`（Unix 时间戳）与 `verified_ip`（出口 IP）到 state，失败（配置缺失/服务停运/隧道不通）时清除，UNKNOWN（无 SOCKS5/分流为空）时保持原值；`_warp_menu_status` 读取验证状态，菜单显示“已验证 <IP>（<相对时间>）”（绿色 ok 药丸，相对时间由 `_warp_format_ago` 生成：刚刚/分钟前/小时前/天前）；SOCKS5 未装或分流为空时“无法验证”仍优先于旧的已验证状态；卸载 WARP 时验证状态随 `state_del_proto` 一并清除。新增 `tests/warp_verify_persist_test.sh`（48 项）。详见 `WARP-VERIFY-PERSIST-FIX-REPORT.md`。
- **WARP 健康检查临时域名清理修复（2026-11-15，紧急）**：`[1/c]` 健康检查第 5 层超时失败后，用户在恢复阶段按 Ctrl+C（sing-box 重载耗时较长，误以为卡死），分流域名从 28 个变成 29 个（`www.cloudflare.com` 临时测试域名未移除），分流模式从“精简模式”变成“自定义”。根因：显式恢复先清除 RETURN trap 与状态标志，再调用 `warp_set_domains`，恢复期间被中断时安全网已撤。修复（五层防御）：①恢复顺序调换——先恢复、成功后再清标志/trap，失败时保持标志，RETURN trap 在函数返回时再试一次；②第 5 层全程安装 INT/TERM trap，Ctrl+C 时先恢复临时域名再以 130 退出（退出窗口时恢复调用方旧 trap）；③恢复验证——`warp_set_domains` 返回后用 jq 深比较确认列表确实恢复，失败时明确报错提示手动移除；④超时保护——sing-box 重载走 `_systemctl_timed`（默认 15 秒，`SBX_SYSTEMCTL_TIMEOUT` 可覆盖；测试 mock 为函数时直接调用）；⑤幂等入口清理——state 中的 `temp_trace_added` 标记（临时添加前设置、恢复成功后清除）识别上次残留，下次 `warp_check` 入口先清理，用户手动添加的测试域名无标记不会被误删。新增 `tests/warp_temp_cleanup_test.sh`（53 项，含 `set -m` + 进程组 SIGINT 真实模拟 Ctrl+C 中断、恢复失败注入、入口清理三态）。详见 `WARP-TEMP-CLEANUP-FIX-REPORT.md`。测试中发现的遗留问题（未修，另行跟踪）：`warp_set_domains` 等混合函数泄漏状态锁——`config_transaction` 覆盖了 RETURN trap，`_state_unlock` 未触发，单进程内无影响（锁可重入），多进程并发时会互相阻塞 10 秒。
- **子菜单方向键失效修复（2026-11-15）**：用户真机反馈子菜单方向键回显 `^[[A` 且无法导航、字母直输需回车、q+回车后卡住。调查：EXPORT 截图是主线行为（主线无方向键支持，属预期）；Reality 截图确为 TUI 列表模式故障，但沙箱（bash 5.2）三轮忠实复现均无法复现，故障依赖 RN 环境（bash 5.1 的 `read -n` termios 保存/恢复行为差异为最可疑机制）；"卡住"则是 `state_manager.sh` 的 `exec 200>... 2>/dev/null` 永久吞掉整个 shell stderr、致 `pause` 提示不可见（`UI-TEST-REPORT.md` §八已知未修项）。修复：①菜单逐字节读改用 `dd`（不碰 termios）+ stty raw 模式，终端在整个菜单期间保持 raw，彻底消除 bash 版本差异；超时读用 VMIN=0 + VTIME（`timeout` 命令会让 dd 收 SIGTTIN，实测不可用；VMIN=1 + VTIME 对"无输入超时"无效）；`_ui_menu_tty_enter` 抽出为共享函数；stty 完全失效时回落 bash `read -n`（兜底，方向键仍可用）；②去掉三处 `exec` 的 `2>/dev/null`，stderr 恢复，pause 与全部 `read -rp` 提示可见；③数字键/字母键规则（用户 2026-11-15 21:57 明确）：字母键立即执行、无需回车，数字键只缓存回显、必须回车确认才执行（否则输两位数如 10 会误入 1），退格可删缓存，无效数字回车后提示并留在菜单；旧 0.4 秒数字缓冲删除。新增 `tests/submenu_nav_test.sh`（23 项，含真实主菜单→子菜单 PTY 端到端、字母直输、stderr 根因级检查、子菜单数字键回车确认），`tests/ui_twokey_test.sh` 按新规则重写（12 项）。详见 `SUBMENU-NAV-FIX-REPORT.md`。真机验证待用户在 RN 上重装后实测。
- **方向键导航移除（2026-11-15，用户决定）**：方向键在 iPhone Termius 上不常用（字母快捷键更快），且是 bug 重灾区（三轮修复全因它：Termius 回显、面板导航、子菜单 dd 重写）。移除：`_ui_menu_select_tty`（方向键列表）、`ui_menu_select_panel`（面板内高亮移动）、`ui_panel_redraw`/`_ui_panel_highlight`（高亮重画）、`_ui_menu_read_byte`/`_ui_menu_read_byte_timed` 的 dd 字节读、`_ui_menu_tty_enter`/`_ui_menu_cleanup`/`_ui_menu_on_signal`（stty termios + trap 管理）；菜单逐字节读改回 bash `read -n`（自行切非规范模式，不再调用 stty、不碰终端状态，退出后 stty 天然不变）。保留：TUI 视觉呈现（仪表盘、面板、颜色、状态显示、菜单布局）、字母键立即执行、数字键回车确认、Esc 返回、q 退出、stderr 修复（`state_manager.sh` 的 `2>/dev/null` 去除）。方向键等转义序列到达时整段忽略且不回显 `^[[`；Ctrl+C 经 INT trap + 0.2 秒短超时轮询返回 3（trap 执行后 `read` 不提前返回，实测确认）。`ui_menu_select`/`ui_menu_read_key` 签名与返回码不变；主菜单/维护菜单改调 `ui_menu_read_key`；提示文字改为"字母直接进入 · 数字+回车确认 · Esc 返回 · q 退出"。测试：`tests/ui_test.sh` 75 项、`tests/termius_fix_test.sh` 30 项、`tests/panel_nav_test.sh` 44 项、`tests/submenu_nav_test.sh` 21 项、`tests/ui_twokey_test.sh` 12 项全部通过。详见 `ARROW-KEY-REMOVAL-REPORT.md`。

### 第二轮 P0 修复

- **SHA256 校验失败即终止**：checksums.txt 下载失败、找不到目标校验值、校验值格式无效（非 64 位十六进制）、匹配不唯一时一律终止安装，不再跳过校验。
- **配置事务并发锁**：`config_transaction` 新增独立配置锁（flock，fd 201），全程持锁，读取、备份、修改、提交、服务重载、回滚全部纳入锁保护。
- **WARP 路由规则归属**：WARP 规则带 `sbx_owner="warp"` 标识，只删除自己的规则，保留用户自定义规则和其他模块的 sniff/resolve 规则。**（2026-11-15 紧急修正：sing-box 不认 `sbx_owner` 自定义字段，`sing-box check` 报错致分流失败；已改为结构识别，见 TUI 分支条目）**。
- **状态锁嵌套修复**：引入深度计数器，最外层获取 flock，嵌套只增深度，最外层退出才释放；移除 `trap - RETURN` 覆盖问题。
- **WARP 健康检查**：无 SOCKS5 时返回 UNKNOWN（4）而非成功；不再依赖 api.ipify.org 在分流列表中，改用 Cloudflare trace 服务验证 warp=on 状态；区分配置正常、隧道正常、实际出口正常。
- **WARP 事务加固**：移除 `|| true` 隐藏失败；`warp_set_domains` 失败时恢复原状态；卸载时路由清理失败中止并报错。
- **升级锁安全**：改用 `/run/lock/sbx-upgrade.lock`，检查符号链接，权限 600。
- **状态迁移锁保护**：`init_state_file` 和 `_migrate_state` 纳入状态锁管理，迁移期间防并发写入。
- **systemd 原子替换**：`write_singbox_unit` 改为临时文件 + mv 原子替换，避免半写文件。
- **跨文件事务**：新增 `operation_transaction`（状态锁 → 配置锁固定顺序），支持状态+配置联合备份与回滚。

### 第二轮测试

- 新增 `tests/round2_regression.sh`（13 项回归测试：锁嵌套、配置并发、规则归属、事务回滚等）
- 新增 `tests/version_check.sh`（版本一致性检查）

---

## v1.7.0 — 2026-11-15（第一轮）

架构升级与全面质量整改版本。

### P0 安全与可靠性修复

- **状态并发安全**：引入 `flock` 进程级文件锁，所有状态写入操作受锁保护，超时 10 秒，可重入设计支持嵌套调用。多终端同时操作不再丢失状态。
- **配置与状态事务一致性**：所有协议安装/卸载函数检查状态写入返回值，状态失败时回滚配置，杜绝"配置存在但状态缺失"的不一致情况。
- **内核升级回滚**：升级前备份 systemd 服务文件，引入升级锁（5 分钟超时），检查磁盘空间（至少 100MB），`write_singbox_unit`/`daemon-reload`/服务启动失败时完整回滚旧内核与旧服务配置。
- **供应链安全**：sing-box 下载后验证 SHA256（从官方 Release 的 checksums.txt 获取），验证版本号与目标一致，验证二进制可执行（架构匹配）。校验失败拒绝安装。
- **WARP 健康检查**：`warp_check` 改为 5 层分层检查（配置存在 → 结构合法 → 服务运行 → 分流规则 → 实际流量测试），通过 SOCKS5 实测出口 IP 是否为 Cloudflare 段。无法验证时明确标记，不虚报成功。
- **WARP API 验证**：严格检查 HTTP 状态码（区分 429 限流、500 服务器错误、网络超时），验证 client_id 格式（4 字符 base64）、IPv4/IPv6 地址、公钥/私钥格式、Reserved 解码结果（3 字节）。异常数据拒绝继续安装。
- **AI 分流三模式**：精简模式（28 个 AI 专用域名，不含 google.com 等通用域名，普通 Google 服务不受影响）与兼容模式（33 个域名，含 Google 通用域名）可选，非交互环境默认精简模式。

### P1 架构升级

- **统一配置事务管理器**：新增 `config_transaction` 函数，`apply_inbound`/`apply_outbound`/`apply_endpoint`/`apply_route_rules` 统一调用，消除 69 行重复代码（json_builder.sh 从 236 行精简到 167 行）。
- **状态 Schema 版本管理**：新增 `schema_version` 字段（当前 v2），提供 `_migrate_state` 迁移函数，迁移前自动备份，迁移后验证，失败自动恢复。拒绝未知高版本状态文件。
- **Shell 代码规范**：修复 ShellCheck 警告（删除未使用的 `cert_type` 变量），修复 `tests/anytls_test.sh` 硬编码路径问题。

### 测试

- 新增并发写入测试（10 进程同时写状态，无丢失）
- WARP 单元测试更新（适配 AI 分流三模式与非交互默认）
- 全部测试通过：bash -n、WARP 测试、ShellCheck

## v1.6.9 — 2026-11-15
- 改用直接 API 注册 WARP，弃用 wgcf：wgcf 在 RN 上被 Cloudflare 限流报 500 错误，注册失败致 Reserved 字节为 [0,0,0]、隧道不通。现用 openssl 生成密钥对、直接 POST 到 Cloudflare API 注册（甬哥 sing-box-yg 同款做法），实测可用。

## v1.6.8 — 2026-11-15
- 修复 WARP 隧道握手失败（RN 实测根因）：Reserved 字节不能随机生成，必须从 wgcf-account.toml 的 client_id 解码（base64 解码得 3 字节）。随机值导致 Cloudflare 拒绝握手、流量超时。

## v1.6.7 — 2026-11-15
- 修复 WARP 隧道不通（RN 实测）：端点 address 改回 v4+v6 双地址数组（甬哥 sing-box-yg 同款）。v1.6.2 起只用 IPv4 单地址，虽能通过 `sing-box check`，但真机上隧道握手失败、流量超时。

## v1.6.6 — 2026-11-15
- 修复 WARP 分流不生效（RN 实测，根因）：路由规则缺少 `sniff` 与 `resolve` 动作，sing-box 不知道流量要访问哪个域名，`domain_suffix` 规则永远匹配不上。现写入分流规则时自动在头部插入 `sniff` 与 `resolve` 规则（参照甬哥 sing-box-yg 的做法）。

## v1.6.5 — 2026-11-15
- 修复 WARP 隧道不通（RN 实测）：`engage.cloudflareclient.com` 在 RN 上只解析出 IPv6 地址，与 IPv4 隧道不匹配致握手失败。改用 Cloudflare WARP 固定 IPv4 地址 `162.159.192.1`。

## v1.6.4 — 2026-11-15
- 修复 WARP 安装失败（RN 实测）：私钥解析混入多余字符，sing-box 报 `decode private key: illegal base64 data at input byte 40`。改用 grep+cut 提取并用 `tr -d '[:space:]'` 去除所有空白字符，新增私钥格式校验（44 字符 base64，不符则明确报错而非写入坏配置）。

## v1.6.3 — 2026-11-15
- 修复 WARP 安装失败（RN 实测，根因）：wgcf 配置的 Address 字段解析错误。原 awk 用 `/\./` 匹配 IPv4，当 v4/v6 在同一行逗号分隔时，`addr_v4` 会拿到整行逗号连接串（`172.16.0.2/32,2606:.../128`），导致 sing-box 校验失败。改用先按逗号拆行、再按冒号区分 v4/v6 的稳健解析，分行与逗号两种格式都验证通过。

## v1.6.2 — 2026-11-15
- 修复 WARP 安装失败（RN 实测）：Endpoint 的 `address` 字段在不同 sing-box 版本间类型不一致，数组格式在 RN 上报 `cannot unmarshal array into Go value of type **netip.Prefix`。改用 IPv4 单字符串地址，1.11/1.12/1.13/1.14 四版本真机校验通过。

## v1.6.1 — 2026-11-15
- 修复 WARP 安装失败：sing-box 1.11+ 已废弃 WireGuard 出站（`server` 字段不存在），改用 Endpoint 方式（`endpoints` 数组，`address`/`peers[].address` 字段）。真 sing-box 1.12.0 校验通过。

## v1.6.0 — 2026-11-15
- 新增 WARP 与域名分流：主菜单 `[13/w]` / `sbx w`。VPS 原生 IP 被 AI 服务封锁时，一键安装 Cloudflare WARP 出站（wgcf 注册 WireGuard 配置），把指定域名走 WARP 出口绕过封锁。
- AI 解锁预设：一键应用 33 个 AI 域名（Gemini/ChatGPT/Claude 等，含 google.com / googleapis.com / accounts.google.com 等关联域名——实测只分流主域名不够，必须连同关联域名一起分流）。
- 分流管理：自定义添加/删除域名（空格分隔，后缀匹配），查看列表，清空规则；WARP 卸载时自动清除全部规则。
- 安装器：`install.sh` 支持 `bash <(wget -qO- ...)` 一键远程安装（检测到管道执行时自动下载发布包）。

## 2026-11-04（未发版）
- 去重：SOCKS5 子菜单「卸载 SOCKS5」→「卸载协议」（与另4个子菜单统一；子菜单标题已含协议名；补红色警示）。
- 全量UI截断扫描：修复 ui_kv 4处超长标签（诊断区 sing-box 配置→配置校验、sing-box 内核→内核状态；命名菜单 当前节点 ID→当前前缀）。
- 子菜单标签精简：标题列收紧到 16 后，6 个子菜单标签超长被截断（SOCKS5「安装 / 重装 SOCKS5」等），精简为 16 内（子菜单标题已含协议名，不重复）。
- 代码审查修复（资深标准）：①一键全装帮助文本菜单号过时（SOCKS5 5/p→6/y、Argo 4/a→5/p）；②Argo Token 输入改用 `read -s` 静默（防肩窥）；③清理 3 处死代码（ui.sh 的 dom、export.sh 的 a_lport、menu_node_naming 的 cc/city/city_code）。
- UI 收紧：菜单标题列 20→16（`Cloudflare Argo` 为最长 15），右侧不再稀疏；Argo 菜单行只显示 `WS · Quick` 不带长域名（域名在 Argo 子菜单看）；一键全装长描述不再被截断。
- 主菜单重编号：1-13 顺序排列，每项数字+字母双通道（AnyTLS `6/y`、一键全装 `7/i`、订阅中心 `8/e`、命名 `9/n`、调优 `10/o`、维护 `11/s`、卸载 `12/x`、诊断 `13/d`，`0/q` 退出不变）。
- 主菜单按用户方案调整：协议按常用度重排（AnyTLS `4/a`、Argo `5/p`、SOCKS5 `6/y`）；彻底卸载单列 `[x]` 不配数字（防误触）；诊断 `12/d`。CLI 快捷字母同步（`a`→anytls、`p`→argo、`y`→socks5）。
- 端口输入去固定默认值：安装时不再预设 443/8443/9443 等，回车=随机生成，输数字=手动指定（修改现有端口时回车=保持不变）。
- 新增 AnyTLS 协议：主菜单 `[y]` / `sbx anytls`，TCP+TLS 伪装，密码认证；需 sing-box ≥ 1.12.0（版本不足自动升级）；已纳入一键全装与三格式导出（URI/Mihomo/sing-box）。
- 卸载改为彻底自清理：`x` 卸载完成后删除管理脚本目录与快捷命令，直接退出不再返回菜单。
- 新增一键全装：主菜单 `[i]` / `sbx all`，按默认配置依次安装 Reality+Hy2+TUIC（已安装自动跳过；SOCKS5 与 Argo 不在内，需单独安装，Argo 优选 IP 需手动选择）。
- 性能：`init_state_file` 加进程内 mtime 感知缓存，主菜单渲染时状态访问快约 3 倍。
- 订阅提示改直白：127.0.0.1 监听时明确告知手机/电脑连不上、改填 0.0.0.0。

## v1.5.1 — 2026-11-04
- 项目更名为 sing-box-moye，快捷命令由 `sbm` 改为 `sbx`（升级自动清理旧命令与旧 systemd 服务）。
- 节点命名定版：识别到 Oracle/Google/AWS/Azure/Cloudflare（ASN 精确匹配优先）直接用厂商全名（如 `Oracle-Reality`）；其他用国家代码-主机名（如 `US-RN-Reality`），主机名保留原始大小写。
- 协议短名统一为 Reality / Hy2 / TUIC / Argo；Argo 多优选 IP 按 `-1`、`-2` 编号（不补零）。
- 节点命名 Schema v3，保留用户自定义前缀；命名仅在命名中心重新探测时刷新。


## v1.5.0 — 2026-11-03

### 节点命名重构
- 新命名格式：`国家-地区-节点短 ID / 协议名称`，例如 `US-LAX-7F3A / VLESS-Reality`。
- 移除默认命名中的国旗与供应商缩写，避免终端字体兼容问题、运营商信息变化和名称冗长。
- 节点短 ID 根据首次探测到的公网 IP 生成并持久化；协议名统一、Argo 多地址使用两位序号。
- 命名菜单改为自动命名、地区命名、自定义前缀和重新探测四项；旧菜单预设命名自动迁移，明显的手动自定义前缀继续保留。

### 导出安全
- Mihomo YAML 字符串统一使用 JSON 字符串转义（JSON 是 YAML 兼容子集），防止节点名、凭据或路径中的特殊字符破坏 YAML 结构。
- 自定义前缀允许普通引号和反斜杠，由导出层安全转义；限制长度并拒绝控制字符。
- 修复 TLS 校验布尔值为 `false` 时被当成空值，导致 Hy2/TUIC Sing-box JSON 导出失败的问题。
- Hy2/TUIC URI 密码进行 URL 编码，Argo WebSocket 路径进行保留斜杠的路径编码；Argo IPv6 地址在 URI 中使用方括号。
- 订阅服务限制并发工作线程；Cloudflared systemd 服务增加沙箱与权限收敛。
- 内核升级包解压前校验成员路径、拒绝符号链接/硬链接及特殊文件，仅接受预期目录下的普通文件和目录。

### 测试
- 增加新节点命名格式、Argo 序号与 YAML 标量转义回归测试。


## v1.4.3 — 2026-11-03

### 修复
- 公网 IP 缓存和探测结果改用标准 IP 地址解析校验，拒绝 `999.999.999.999` 等仅匹配外观正则的无效地址。
- 公网 IP 查询失败时不再伪造 `127.0.0.1` 作为服务器地址；节点导出会明确中止，避免生成看似成功但不可用的客户端配置。
- 修复首次安装 Sing-box 内核后没有强制启动并验证服务的问题。
- 内核升级/安装失败时增加二进制回滚路径；成功后清理旧版本备份，避免备份文件长期残留。
- 安装器复制项目时包含隐藏文件，避免遗漏仓库配置文件。

### 测试
- 增加 IPv4、IPv6 有效地址及伪造/非法地址回归测试。
- 重新执行 Shell 语法、状态管理、配置构建和订阅服务测试。


## v1.4.2 — 安全与部署兼容性修复
- 移除 README 中绑定个人域名的仓库克隆地址，改为通用仓库地址占位符
- 首次 GeoIP 查询改为 HTTPS 服务，并补充数据用途与网络请求说明
- 公网 IP 查询优先获取最新地址，缓存值仅作为网络不可用时的回退，避免长期使用过期地址
- 所有下载强制 HTTPS/TLS 1.2，拒绝非 HTTPS 下载
- sing-box 压缩包增加格式与路径安全检查，避免解压异常内容
- 监听端口被占用时不再仅警告后继续安装；增加重新选择与取消入口
- sing-box 配置、备份文件权限收紧，配置更新使用唯一临时文件并清理备份
- systemd 服务补充运行用户、umask、文件描述符限制，移除不可靠的 HUP reload 指令
- 安装器增加 systemd 前置检查，并支持非交互执行完成后不阻塞在菜单
- 在线订阅服务默认仅监听 127.0.0.1，避免首次启用即暴露公网\n- 补充发行版支持边界、防火墙和隐私说明

## v1.4.1 — SOCKS5 参数定位调整
- SOCKS5 从协议矩阵移至「交付与系统运维」，菜单名称调整为「SOCKS5 代理参数」
- 移除 SOCKS5 的 URI、Mihomo 与 Sing-box 客户端出站导出，不再混入节点订阅
- 安装完成后直接展示服务器、端口、用户名、密码及 Telegram 手动配置路径
- 新增随时从 state 查看 SOCKS5 参数的菜单项
- 保留强制认证、用户名格式校验、入站安装/卸载/重装、状态管理与防火墙提示

## v1.4.0 — 在线订阅与 SOCKS5
- 新增带 256-bit 随机令牌的在线 Base64 订阅端点、systemd 服务管理与撤销功能
- 新增 SOCKS5 入站，强制用户名密码认证，支持 TCP/UDP，并纳入三种客户端格式导出
- 增加 Python 3 依赖检测，完整卸载时清理订阅服务
- 更新菜单入口、CLI 命令、文档与测试覆盖
- 安全提示：订阅端点为 HTTP，生产环境应通过 HTTPS 反向代理并限制来源 IP


## v1.3.0 — 全新终端界面
- 新增 `core/ui.sh` UI 组件库：圆角边框、分区标题、双列状态面板、键位菜单项、状态点（● / ○）
- 精确的 CJK / Emoji 显示宽度计算，中文与国旗 Emoji 下右侧边框也能严格对齐
- 自适应终端宽度（58~78 列），超长内容自动以省略号截断
- 非 TTY / `NO_COLOR` 自动去色；非 UTF-8 终端自动降级为 ASCII 边框；`SBM_ASCII=1` 可强制 ASCII
- 所有子菜单（Reality / Hy2 / TUIC / Argo / 调优 / 命名 / 订阅 / 内核维护）统一风格，顶部显示协议当前状态
- 订阅导出页：节点卡片 + 整行链接（不入框，便于复制），文件落盘信息单独成块
- 主菜单每次操作后暂停并清屏重绘；新增 `sbm version`
- `sbm.sh` 被 source 时不再自动启动（便于测试）
- 颜色变量改为真实 ESC 字节，`read -p` / `printf` 均可直接使用
- 终端若出现边框错位，请将"不明宽度字符"设为"窄(Narrow)"，或使用 `SBM_ASCII=1`

## v1.2.1
### 安全
- 全局 `umask 077`，state.json / config.json / export 文件权限收紧为 600，/etc/sing-box 为 700
- Argo Token 改用 `EnvironmentFile`（600），不再写入 systemd unit 与进程参数
- 自签证书去掉 "Apple Inc." 主体，增加 SAN，并按域名复用
### 修复
- 下载统一使用 `download_file`（curl -f + 临时文件 + 原子替换），404 不再产生"假二进制"
- cloudflared armv7 资源名映射
- 获取公网 IP 失败时不再把 127.0.0.1 缓存进 state
- ACME 续期后自动重载 sing-box，去掉 `--force`，申请前检查 80 端口
- 端口跳跃改用 systemd 单元持久化（开机恢复），重装/卸载/uninstall_all 均会清理，手动设置同步写入 state
- CLI 的 `A && B || C` 误触发安装
- 去掉 `set -e`，避免交互菜单因任一非零返回而整体退出；每次操作后暂停
- `apply_inbound` 在服务未能运行时自动回滚配置
- 内核升级：先用新版本校验现有配置，失败不升级；升级后重启并在失败时回滚旧二进制
- `APP_HOME` 可被外部覆盖，源码目录可直接运行
- 证书路径/域名输入校验，证书配置失败时中止安装
### 改进
- Hy2 分享链接增加 `mport`，sing-box 出站增加 `server_ports`（客户端需 1.11+）
- vless Reality 出站增加 `packet_encoding: xudp`
- Argo 菜单新增 [4/r] 刷新临时隧道域名
- qrencode 改为可选依赖，移除无 systemd 的 apk 分支
- systemd unit 去除多余 capability，增加 NoNewPrivileges 与 network-online 依赖
