# UI-COMPATIBILITY-REPORT.md — TUI 重构兼容性报告（Phase 4）

- 完成日期：2026-11-15
- 基线：sing-box-moye v1.7.0（`/tmp/v17_work`），实验仓库 `/tmp/tui_work`，未推送
- 版本号：1.7.0 未变

## 一、CLI 兼容性：40/40，与基线逐字节一致

方法：`/tmp/p4/cli_test.sh` + `/tmp/p4/cli_drive.sh`。同一用例在 `/tmp/tui_work` 与
`/tmp/v17_work` 各跑一次，stdout+stderr+退出码逐字节 diff（`cmp`）；隔离 state 与
路径固定，业务函数打桩记录调用；另有两项真实逻辑验证（见表末）。
`sbx_main` 本身在两树中逐字节一致（`declare -f` 审计），本节是执行层面的实证。

### 逐条结果

| # | 命令 | 行为（两树一致） | 结果 |
|---|---|---|---|
| 1 | `sbx`（无参） | 进入 `main_menu` | PASS |
| 2 | `sbx version` | 输出 `sing-box-moye v1.7.0`，退出 0 | PASS |
| 3 | `sbx -v` | 同上 | PASS |
| 4 | `sbx --version` | 同上 | PASS |
| 5 | `sbx doctor` | 分发到 `run_diagnostics` | PASS |
| 6 | `sbx check` | 同上（别名） | PASS |
| 7 | `sbx rename US-vps01` | `set_custom_node_prefix US-vps01` → `export_all_nodes` | PASS |
| 8 | `sbx rename`（无参） | 进入 `menu_node_naming` | PASS |
| 9 | `sbx n US-vps01` | 同 7（别名） | PASS |
| 10 | `sbx e` | 分发到 `export_all_nodes` | PASS |
| 11 | `sbx export` | 同上 | PASS |
| 12 | `sbx info` | 同上（别名） | PASS |
| 13 | `sbx o` | 分发到 `enable_bbr_and_udp_tuning` | PASS |
| 14 | `sbx bbr` | 同上 | PASS |
| 15 | `sbx subscription enable` | 分发到 `subscription_enable` | PASS |
| 16 | `sbx subscription disable` | 分发到 `subscription_disable` | PASS |
| 17 | `sbx subscription`（无参） | 分发到 `subscription_status` | PASS |
| 18 | `sbx sub start` | 分发到 `subscription_enable`（别名） | PASS |
| 19 | `sbx sub stop` | 分发到 `subscription_disable`（别名） | PASS |
| 20 | `sbx sub`（无参） | 分发到 `subscription_status`（别名） | PASS |
| 21 | `sbx h del` | 分发到 `uninstall_hysteria2` | PASS |
| 22 | `sbx r` | 分发到 `install_reality` | PASS |
| 23 | `sbx reality del` | 分发到 `uninstall_reality` | PASS |
| 24 | `sbx hy2` | 分发到 `install_hysteria2` | PASS |
| 25 | `sbx hysteria2 del` | 分发到 `uninstall_hysteria2` | PASS |
| 26 | `sbx t` | 分发到 `install_tuic` | PASS |
| 27 | `sbx tuic del` | 分发到 `uninstall_tuic` | PASS |
| 28 | `sbx a` | 分发到 `install_anytls` | PASS |
| 29 | `sbx anytls del` | 分发到 `uninstall_anytls` | PASS |
| 30 | `sbx p` | 分发到 `install_argo` | PASS |
| 31 | `sbx argo del` | 分发到 `uninstall_argo` | PASS |
| 32 | `sbx y` | 分发到 `install_socks5` | PASS |
| 33 | `sbx socks5 del` | 分发到 `uninstall_socks5` | PASS |
| 34 | `sbx w` | 进入 `menu_warp`（非直接安装） | PASS |
| 35 | `sbx warp del` | 分发到 `uninstall_warp` | PASS |
| 36 | `sbx all` | 分发到 `install_all_protocols` | PASS |
| 37 | `sbx frobnicate` | 打印用法文本，退出 0 | PASS |
| 38 | `sbx reality bogus` | 第二参数非 `del`，走安装分支 | PASS |
| 39 | `sbx all`（真实逻辑） | 顺序 reality→hy2→tuic→anytls；fixture 中 reality/hy2 已装跳过，tuic/anytls 安装，事后调 `export_all_nodes`；汇总“新增 2 个，跳过 2 个，失败 0 个”，退出 0 | PASS |
| 40 | `sbx rename US-vps01`（真实逻辑） | 隔离 state 写入 `custom_prefix=US-vps01`，`links.txt`/`mihomo_proxies.yaml`/`singbox_outbounds.json` 三文件再生；事后隔离目录已清理 | PASS |

证据：`/tmp/p4/out/cli-tui-*.txt` 与 `/tmp/p4/out/cli-v17-*.txt`（逐对 `cmp` 一致）。

### 结论

CLI 分发、用法文本、版本号输出、真实业务逻辑（`install_all_protocols` 调用顺序与
跳过逻辑、`rename` 持久化）在新 UI 下与 v1.7.0 基线完全一致。`sbx` 无参进主菜单
（管道 `q` 退出）亦在模式回归中覆盖（见第三节）。

## 二、终端 / 宽度 / 颜色模式矩阵

### 2.1 宽度矩阵（逐行 `ui_vwidth ≤ UI_W`，0 越界）

| SBM_COLS | UI_W / 模式 | 主菜单 | Reality | WARP | 订阅中心 |
|---|---|---|---|---|---|
| 120 | 100 / wide | PASS | PASS | PASS | PASS |
| 100 | 96 / wide | PASS | PASS | PASS | PASS |
| 80 | 78 / normal | PASS | PASS | PASS | PASS |
| 60 | 58 / compact | PASS | PASS | PASS | PASS |
| 40 | 38 / narrow | PASS | PASS | PASS | PASS |
| 30 | 30 / plain | PASS | PASS | PASS | PASS |

24/24 通过。方法：`/tmp/p4/modes_test.sh` + `/tmp/p2/width_check.py`（去 ANSI 后按
East Asian Width 计算可视宽度；排除 `ui_hint` 长行与面板外 log 行，与 Phase 1/2 口径一致）。
证据：`/tmp/p4/out/width-*-{120,100,80,60,40,30}.txt` 与同名 `.check`。

注：首轮测试曾在 60/40/30 列下发现行模式选项列表越界（最长 65 列），已在 Phase 4 内
修复（`_ui_menu_select_line` 描述截断），重跑后 24/24 通过。见 `UI-TEST-REPORT.md` §三。

### 2.2 颜色 / 字符集矩阵

| 模式 | 主菜单 | Reality | WARP | 订阅中心 | 调优 | 维护 | 诊断 |
|---|---|---|---|---|---|---|---|
| 默认（非 TTY） | 去色 ✔ | 去色 ✔ | 去色 ✔ | 去色 ✔ | 去色 ✔ | 去色 ✔ | 去色 ✔ |
| `NO_COLOR=1` | 零 ANSI ✔ | 零 ANSI ✔ | 零 ANSI ✔ | 零 ANSI ✔ | 零 ANSI ✔ | 零 ANSI ✔ | 零 ANSI ✔ |
| `SBM_ASCII=1` | ASCII 边框 ✔ | ASCII 边框 ✔ | ASCII 边框 ✔ | ASCII 边框 ✔ | — | — | — |
| `SBM_FORCE_COLOR=1`（非 TTY） | 强制颜色 ✔ | — | — | — | — | — | — |
| UTF-8（默认） | Unicode 边框 ✔ | Unicode 边框 ✔ | Unicode 边框 ✔ | Unicode 边框 ✔ | Unicode 边框 ✔ | Unicode 边框 ✔ | Unicode 边框 ✔ |

- `NO_COLOR=1` 优先于 `SBM_FORCE_COLOR`（`ui_test.sh` 覆盖）；`SBM_FORCE_COLOR=1`
  非 TTY 下强制颜色（`ui_test.sh` 覆盖）。
- `SBM_ASCII=1` 下边框为 `+---+`/`|`；内容中的 `·`/`›` 等符号不受影响（非边框字符）。
- 展示样本：`docs/ui-samples/`（`main-80col-nocolor.txt`、`main-80col-ascii.txt` 等）。

### 2.3 交互模式矩阵

| 场景 | 行为 | 结果 |
|---|---|---|
| TTY 方向键 | ↑/↓ 高亮 + 回车确认，Esc 返回，q 退出，反显 + `❯` 双通道 | PASS（`ui_test.sh` 9 PTY 用例 + Phase 3b PTY 6 例） |
| TTY 数字快捷键 1–9 | 单按（停顿）按首位匹配 | PASS（`ui_twokey_test.sh`） |
| TTY 两位数快捷键 10–13 | 快按两位选中，停顿按首位匹配 | PASS（`ui_twokey_test.sh` 9/9 + 主菜单级 4/4） |
| TTY 字母快捷键 | 立即匹配，大小写不敏感 | PASS |
| TTY Ctrl+C / SIGTERM / SIGINT | trap 置标志 → 清理 → 退出 0，`stty` 前后一致 | PASS（主菜单 3/3） |
| `SBM_MENU_LINE=1` / `TERM=dumb` | 强制行输入模式 | PASS（组件设计，`ui_test.sh` 行降级 7 例覆盖行模式） |
| 非 TTY 管道 | 主菜单→子菜单→返回→退出全流程；EOF 直接退出；无效输入警告后可继续 | PASS（6 流程） |
| 无 `stty` | 自动降级行输入 | 设计如此（`ui_menu_select` 返回 4 → 行输入） |

### 2.4 环境变量兼容

| 变量 | v1.7.0 行为 | TUI 行为 | 结论 |
|---|---|---|---|
| `NO_COLOR=1` | 关闭颜色 | 相同 | 保留 |
| `SBM_FORCE_COLOR=1` | 非 TTY 强制颜色 | 相同 | 保留 |
| `SBM_ASCII=1` | 强制 ASCII 边框 | 相同 | 保留 |
| `SBM_COLS=N` | 覆盖终端宽度 | 相同（非法值回退 80） | 保留 |
| `SBX_AUTO=1` | 一键全装端口免询问 | 相同（业务未动） | 保留 |
| `SBM_MENU_LINE=1` | —（新增） | 强制行输入模式 | 新增 |
| `SBM_NO_ANIM=1` | —（新增） | 禁用 spinner 动画 | 新增 |

### 2.5 不可变约束核对（`UI-COMPATIBILITY.md`）

| 约束 | 状态 |
|---|---|
| 状态文件 schema（`state.json` v2）不得改 | ✔ 未动（`core/state_manager.sh` 逐字节一致） |
| 配置结构、sing-box 配置生成逻辑不得改 | ✔ 未动（`core/json_builder.sh` 逐字节一致） |
| 协议参数与默认值不得改 | ✔ 未动（全部 `install_*` 逐字节一致） |
| CLI 接口不得改 | ✔ 40/40 与基线一致 |
| SOCKS5 不进节点导出/订阅 | ✔ 订阅中心统计明确排除 SOCKS5；导出函数逐字节一致 |
| WARP 分流规则实际行为不得改 | ✔ `warp_check` 等业务函数逐字节一致；菜单只做只读探针 |
| 卸载确认强度不得降低 | ✔ 单次 `ui_dialog_confirm` 默认取消，与旧版同强度 |

## 三、已知限制

完整清单见 `UI-REDESIGN-REPORT.md` §八。此处只列兼容性视角的关键项：

1. **既有业务 bug（v1.7.0 基线已有，只记录不修）**：`core/state_manager.sh:26`
   `_state_lock` 的 `exec 200>"$lock_file" 2>/dev/null` 会永久吞掉整个 shell 的 stderr
   （同文件 :31、:46 另有两处），导致所有 `read -rp` 提示在生产中不可见。旧菜单同样
   受影响，非本次引入。修复建议：去掉三处 `exec` 行的 `2>/dev/null`，改为
   `exec 200>"$lock_file" || return 1`，并对 31/46 行同样处理。
2. **真机验证待做**：iPhone Termius / Xshell / PuTTY 下的方向键、反显、边框对齐与
   各宽度实际观感仍需用户真机验证（沙箱只有 `script` 伪终端）。
3. **无效输入语义变化**：子菜单无效输入由“直接返回”改为“重问”（`ui_menu_select` 固有语义）；
   主菜单非 TTY 路径保留旧行为。
4. **TTY 下主菜单面板与选择器列表同时显示**（约 47 行），24 行高的矮终端上方面板会滚出视野。
5. **40 列窄屏两个仪表盘标签截断**（`CORE STATE`/`PUBLIC IP`），值完整，属窄屏降级设计。
6. **`ui_hint` 长行与 `ui_node_card` 链接不截断**（有意取舍：前者为既有行为，后者为可复制性优先）。
7. **非 TTY 下确认框文案不可见**（既有行为，`read -p` 仅在终端显示提示；TTY 下带边框确认框正常）。
8. **`ui_menu_select` 不可重入**；临时接管调用方 trap（退出时恢复）；Esc 判定依赖 0.05 秒超时。
