# UI-TEST-REPORT.md — TUI 重构测试结果汇总（Phase 4）

- 完成日期：2026-11-15
- 基线：sing-box-moye v1.7.0（`/tmp/v17_work`），实验仓库 `/tmp/tui_work`，未推送
- 版本号：1.7.0 未变

## 总结果

| 范围 | 可计数断言 | 通过 | 失败 |
|---|---|---|---|
| Phase 4 新增回归（两位数快捷键、CLI、模式、信号） | 99 | 99 | 0 |
| Phase 4 重跑既有套件（ui_test、round2） | 87 | 87 | 0 |
| Phase 3 harness 重跑（3a/3b/3c，验证 Phase 4 改动无回归） | 244 | 244 | 0 |
| **可计数断言合计** | **430** | **430** | **0** |
| 套件级（smoke/warp/export/install_all/anytls/version_check/bash -n） | 7 项 | 7 通过 | 0 |
| 业务零改动审计（`declare -f` 逐函数比对） | 1 项 | 通过 | 0 |

**回归总结果：430/430 可计数断言通过，7/7 套件级通过，业务零改动审计通过，0 失败。**

测试 harness 均在 `/tmp/p4/`（未进仓库，保持仓库干净）；仓库内测试为
`tests/ui_test.sh` 与新增的 `tests/ui_twokey_test.sh`。全部捕获输出在
`/tmp/p4/out/`（CLI 对照、宽度校验、模式输出、信号输出、套件日志）。

## 一、Phase 4 新增：两位数快捷键（Task 1）

修复：`core/ui/navigation.sh` 的 `_ui_menu_select_tty` 数字键 0.4 秒缓冲
（见 `UI-REDESIGN-REPORT.md` §六）。

### 1.1 组件级 PTY 测试（仓库内，`tests/ui_twokey_test.sh`）：9/9

| # | 用例 | 结果 |
|---|---|---|
| 1 | 快按 `1` `2` 选中 12/d | PASS |
| 2 | 快按 `1` `3` 选中 13/w | PASS |
| 3 | 快按 `1` `0` 选中 10/o | PASS |
| 4 | 快按 `1` `1` 选中 11/s | PASS |
| 5 | 按 `1` 停顿 0.8 秒选中 1/r | PASS |
| 6 | 快按 `1` `9`（无 19）回落 1/r | PASS |
| 7 | 字母键 `d` 立即选中 12/d | PASS |
| 8 | 按 `2` 停顿选中 2/h | PASS |
| 9 | 快按 `9` `q` 时首位 9/n 优先选中 | PASS |

每例均校验 `stty -g` 前后一致。复现：`bash tests/ui_twokey_test.sh`。

### 1.2 主菜单级 PTY 验证（`/tmp/p4/twokey_main_test.sh`）：4/4

| # | 按键 | 期望 | 结果 |
|---|---|---|---|
| A | 快按 `1` `2` | 进入诊断（12/d），不进 Reality | PASS |
| B | 按 `1` 停顿 1.0 秒 | 进入 Reality（1/r），不进诊断 | PASS |
| C | 快按 `1` `0` | 进入调优（10/o） | PASS |
| D | 字母 `w` | 进入 WARP（13/w） | PASS |

子菜单全部打桩为 MARKER，主菜单在子 shell 中跑，退出码 0 且 `stty` 恢复。
证据：`/tmp/p4/out/twokey-{A,B,C,D}.txt`。

### 1.3 `ui_test.sh` 未破坏：74/74

改动 `navigation.sh` 前后各跑一次，均为 `UI TEST SUMMARY: PASS=74 FAIL=0 SKIP=0`
（含 9 个 PTY 用例：↓↓回车/回车/Esc/q/快捷键 h/Ctrl+C/反显+光标/confirm y/n）。

## 二、CLI 兼容性（Task 2.1）：40/40

方法：`/tmp/p4/cli_test.sh` + `/tmp/p4/cli_drive.sh`。同一用例在 `/tmp/tui_work` 与
`/tmp/v17_work` 各跑一次，stdout+stderr+退出码逐字节 diff；隔离 state/路径固定，
业务函数打桩记录调用（`MODE=stub`），另有 `all-real`（真实 `install_all_protocols`）
与 `rename-real`（真实 `set_custom_node_prefix` + `export_all_nodes`，隔离 state）。

| # | 命令 | 验证点 | 结果 |
|---|---|---|---|
| 1 | `sbx`（无参） | 分发到 `main_menu` | PASS |
| 2–4 | `sbx version` / `-v` / `--version` | 输出 `sing-box-moye v1.7.0` | PASS |
| 5–6 | `sbx doctor` / `check` | 分发到 `run_diagnostics` | PASS |
| 7–9 | `sbx rename US-vps01` / `rename` / `n US-vps01` | 前缀写入 / 无参进命名菜单 | PASS |
| 10–12 | `sbx e` / `export` / `info` | 分发到 `export_all_nodes` | PASS |
| 13–14 | `sbx o` / `bbr` | 分发到 `enable_bbr_and_udp_tuning` | PASS |
| 15–20 | `subscription enable/disable/（无参）`、`sub start/stop/（无参）` | 启停/状态分发 | PASS |
| 21–35 | `r/h/t/a/p/y/w` 各协议 + `del` 变体 | 安装/卸载分发（`w` 进 `menu_warp`） | PASS |
| 36 | `sbx all`（stub） | 分发到 `install_all_protocols` | PASS |
| 37–38 | `sbx frobnicate` / `sbx reality bogus` | 用法文本 / 非 del 走安装 | PASS |
| 39 | `sbx all`（all-real） | 顺序 reality→hy2→tuic→anytls；已装跳过 2、新增 2、失败 0；事后调 `export_all_nodes`；汇总行一致 | PASS |
| 40 | `sbx rename US-vps01`（rename-real） | 隔离 state 写入 `custom_prefix=US-vps01`，导出三文件再生 | PASS |

注：CLI 合计 40 项（38 stub + 2 real）。
证据：`/tmp/p4/out/cli-tui-*.txt` 与 `/tmp/p4/out/cli-v17-*.txt`（逐对 `cmp` 一致）。
逐条详情见 `UI-COMPATIBILITY-REPORT.md`。

## 三、模式回归（Task 2.2）

### 3.1 NO_COLOR / ASCII / 非 TTY / 宽度 / 密码（`/tmp/p4/modes_test.sh`）：43/43

| 分组 | 用例 | 结果 |
|---|---|---|
| NO_COLOR=1 | 主菜单 + menu_reality/menu_warp/show_export_menu/sysctl_menu/menu_maintenance/run_diagnostics，输出零 ANSI 码 | 7/7 PASS |
| SBM_ASCII=1 | 主菜单 + reality/warp/订阅中心，无 Unicode 边框字符 | 4/4 PASS |
| 非 TTY 全流程 | F1 主菜单→Reality→返回→退出；F2 主菜单→诊断→返回→退出；F3 主菜单→WARP→返回→退出；F4 主菜单→订阅中心→返回→退出；F5 无效输入警告后退出；F6 stdin EOF 直接退出 | 6/6 PASS |
| 六档宽度 | 120/100/80/60/40/30 ×（主菜单 + reality/warp/订阅中心），逐行 `ui_vwidth ≤ UI_W`，0 越界 | 24/24 PASS |
| 密码输入 | argo Token 行仍为 `read -rsp`，与基线逐行一致；全项目 `read -[a-z]*s` 出现点与基线一致 | 2/2 PASS |

证据：`/tmp/p4/out/nocolor-*.txt`、`/tmp/p4/out/ascii-*.txt`、`/tmp/p4/out/flow-f*.txt`、
`/tmp/p4/out/width-*-{120,100,80,60,40,30}.txt` 与同名 `.check` 文件。

**回归中发现并修复的真问题**：首轮宽度测试 12 项失败——行模式选项列表不截断，
60 列下 warp/订阅中心各 1 行越界，40/30 列下多行越界（最长 65 列）。已在
`_ui_menu_select_line` 中补截断（描述按 `UI_W-2` 截断，80 列输出逐字节不变），
重跑后 24/24 通过。另有两处测试脚本自身缺陷已修正（ASCII 检测的 grep 字符类在
C locale 下按字节误匹配 CJK；`read -s` 检测的宽松模式误匹配含字母 s 的 `read -rp` 行），
修正后复测通过，代码无问题。

### 3.2 终端异常退出（`/tmp/p4/signal_test.sh`）：3/3

| # | 场景 | 结果 |
|---|---|---|
| 1 | 主菜单 PTY 下 Ctrl+C（0x03 字节，菜单已进 raw 模式） | PASS：退出 0，`stty` 恢复，无子菜单进入 |
| 2 | 主菜单 PTY 下外部 SIGTERM（定向 kill 菜单子进程） | PASS：退出 0，`stty` 恢复，无子菜单进入 |
| 3 | 主菜单 PTY 下外部 SIGINT | PASS：退出 0，`stty` 恢复，无子菜单进入 |

三例均先断言输出含 `请选择功能`（证明确实走了 TTY 选择器路径，而非行输入 EOF 退出）。
证据：`/tmp/p4/out/signal-{ctrlc,term,int}.txt`。

**测试教训**：首版信号驱动用 `( main_menu ) &` 后台运行，无作业控制时 bash 会把后台
命令的 stdin 重定向到 `/dev/null`，主菜单静默走了非 TTY 路径、读到 EOF 退出 0，
测试“通过”却是空心的（输出无 `请选择功能`）。已改为前台子 shell（Ctrl+C）与
父子进程模式（kill 类），并以 `请选择功能` 作为 TTY 路径断言。

## 四、业务零改动核对（Task 2.3）

- `declare -f` 逐函数审计（`/tmp/p4/func_audit.py`）：**PASS**
  - v17 函数 146 个，tui 函数 179 个；零删除；新增 33 个全部为 UI 层
  - 定义不同的 28 个函数全部在 UI 允许清单内；118 个函数逐字节一致
    （含 `sbx_main`、`install_all_protocols`、全部 `install_*`/`uninstall_*`、
    `warp_check`、`export_all_nodes`、全部 `state_*`）
  - 证据：`/tmp/p4/out/funcdump-v17.txt`、`/tmp/p4/out/funcdump-tui.txt`
- hunk→函数映射审计（`/tmp/p4/diff_audit.py`）交叉验证：13 个改动 `.sh` 文件的
  全部改动行均落在允许的 UI 函数内；两处新增全局变量/注释块落在函数间空隙，
  `declare -f` 证实相邻业务函数（`warp_show_domains`、`refresh_legacy_exports`）
  逐字节一致，属映射口径假阳性，已排除。
- 完整变更文件清单见 `UI-REDESIGN-REPORT.md` §五。

## 五、现有测试套件全跑（Task 2.4）

| 套件 | tui_work 结果 | v17 基线对照 | 结论 |
|---|---|---|---|
| `tests/ui_test.sh` | PASS=74 FAIL=0 SKIP=0 | —（Phase 1 新增，基线无） | 通过 |
| `tests/ui_twokey_test.sh`（新增） | PASS=9 FAIL=0 SKIP=0 | —（Phase 4 新增） | 通过 |
| `tests/smoke.sh` | rc=0（3 PASS） | rc=0（3 PASS） | 通过，与基线一致 |
| `tests/round2_regression.sh` | 通过: 13, 失败: 0 | 通过: 13, 失败: 0 | 通过，与基线一致 |
| `tests/warp_test.sh` | rc=0（11 PASS） | rc=0（11 PASS） | 通过，与基线一致 |
| `tests/export_test.sh` | rc=0（1 PASS） | rc=0（1 PASS） | 通过，与基线一致 |
| `tests/install_all_test.sh` | rc=0（1 PASS） | rc=0（1 PASS） | 通过，与基线一致 |
| `tests/anytls_test.sh` | ALL ANYTLS TESTS PASSED | rc=0 | 通过，与基线一致 |
| `tests/version_check.sh` | 通过（1.7.0 未变） | rc=0 | 通过，与基线一致 |
| `bash -n` 全项目 | 通过 | — | 通过 |

日志：`/tmp/p4/out/suites/*.tui.log` 与 `*.v17.log`。**零失败项，无需基线对照定性。**

## 六、Phase 3 harness 重跑（验证 Phase 4 的 `navigation.sh` 改动无回归）

| Harness | 结果 | 备注 |
|---|---|---|
| Phase 3a `/tmp/phase3a_test/run_tests.sh` | PASS=132 FAIL=0 | 6 协议菜单全量 |
| Phase 3b `/tmp/phase3b_render.sh` | PASS=37 FAIL=0 | 订阅/命名/WARP 渲染 |
| Phase 3b `/tmp/phase3b_pty.sh` | PASS=6 FAIL=0 | 方向键 + TTY 确认框 |
| Phase 3c `/tmp/phase3c_harness.sh` | PASS=69 FAIL=0 | 调优 + 卸载 |

合计 244/244。日志：`/tmp/p4/out/suites/phase3*-rerun.log`。
（Phase 2 的 PTY/宽度结论由本阶段 modes/signal/twokey 测试覆盖，不再单独重跑；
Phase 1 的 74 项即 `tests/ui_test.sh`，已在第五节重跑。）

## 七、失败项清单

**无。** 本阶段全部 430 项可计数断言 + 7 项套件级 + 1 项业务审计全部通过。
回归过程中发现的两个真问题（两位数快捷键、行模式窄屏越界）均已在 Phase 4 内修复
并重跑验证；两处测试脚本自身缺陷已修正（见第三节）。

## 八、已知限制 / 未解决问题（摘要）

完整清单见 `UI-REDESIGN-REPORT.md` §八，此处只列与测试直接相关的两项：

1. **既有业务 bug（v1.7.0 基线已有，只记录不修）**：`core/state_manager.sh:26`
   `_state_lock` 的 `exec 200>"$lock_file" 2>/dev/null` 会永久吞掉整个 shell 的 stderr
   （同文件 :31、:46 另有两处同类写法），导致所有 `read -rp` 提示在生产中不可见
   （含主菜单与全部子菜单的行模式提示、“无效选项”提示、确认框文案）。`log_*`（stdout）
   与 TTY 方向键模式（`printf` 到 stdout）不受影响，旧菜单同样受影响。
   修复建议：去掉三处 `exec` 行的 `2>/dev/null`，改为 `exec 200>"$lock_file" || return 1`，
   并对 31/46 行的 `exec 200>&- 2>/dev/null` 同样处理；或改用 `{fd}>"$lock_file"` 动态分配。
2. **真机验证待做**：iPhone Termius / Xshell 等真实终端下的方向键、反显、边框对齐与
   各宽度实际观感仍需用户真机验证（沙箱只有 `script` 伪终端）。
