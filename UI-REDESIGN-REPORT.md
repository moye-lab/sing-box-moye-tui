# UI-REDESIGN-REPORT.md — sing-box-moye TUI 重构最终报告

- 完成日期：2026-11-15
- 基线：sing-box-moye v1.7.0（含第二轮复审整改），工作目录 `/tmp/tui_work`（实验仓库，未推送）
- 版本号：未改动，仍为 1.7.0（`tests/version_check.sh` 通过）
- 状态：**实验性 UI 重构，未合主线**。业务零改动已由逐函数审计证实（见第七节）；
  真机终端验证（iPhone Termius / Xshell）仍待用户验收。

## 一、新旧 UI 架构对照

### 旧架构（v1.7.0）

```
core/ui.sh        # 248 行单文件：初始化 + 宽度计算 + 边框 + 组件 + 交互全在一起
```

- 宽度固定 58~78 列；低于 58 强制 58，窄终端会越界；无 40 列以下降级
- 全部交互是 `read -rp` 行输入，无方向键、无确认框组件、无输入/进度组件
- `ui_line` 不截断超长内容，超长域名/节点名会顶出右边框
- 15 个页面各写各的菜单循环，`read` + `case` 重复 13 处

### 新架构（Phase 1–4）

```
core/ui.sh                # 36 行统一入口：按顺序加载 core/ui/*.sh，末尾 ui_init
core/ui/init.sh           # 68 行  UI 初始化、环境检测、宽度模式、边框字符集
core/ui/theme.sh          # 47 行  主题变量 T_*（映射 env.sh 颜色）与状态符号
core/ui/terminal.sh       # 109 行 宽度计算、含 ANSI 安全截断、清屏
core/ui/layout.sh         # 52 行  面板/分区/排版
core/ui/components.sh     # 148 行 键值/菜单项/协议状态/菜单头/提示/横幅/节点卡
core/ui/input.sh          # 86 行  输入组件（新）
core/ui/navigation.sh     # 305 行 菜单导航 ui_menu_select（新，Phase 4 含两位数缓冲与行模式截断）
core/ui/dialog.sh         # 41 行  消息框/确认框（新），含升级后的 ui_confirm
core/ui/progress.sh       # 50 行  阶段提示与 spinner（新）
core/ui/status.sh         # 23 行  状态药丸（新）
core/ui/dashboard.sh      # 30 行  仪表盘渲染辅助（新）
core/ui/compatibility.sh  # 33 行  旧接口兼容层（ui_box_* 包装 + 自检）
```

- UI 代码 248 行 → 1028 行（含注释与新组件）；模块依赖单向，无循环引用
- `install.sh` 是整树 `cp -a`，`core/ui/` 自动随包发布，无需改安装器
- 旧接口 30 个签名全部不变（`ui_top`/`ui_kv`/`ui_item`/`ui_proto_row`/
  `ui_confirm` 等），`UI_W`/`UI_IW`/`UI_BC` 及边框字符变量全部保留
- 函数总数 146 → 179：新增 33 个全部为 UI 层，零删除（见第七节审计）

### 宽度模式（替代固定 58~78）

| 终端列数 | UI_W | UI_MODE | 行为 |
|---|---|---|---|
| ≥120 | 100 | wide | 宽屏面板 |
| 100~119 | 96 | wide | 宽屏面板 |
| 80~99 | 78 | normal | 与旧版一致（默认） |
| 60~79 | cols-2 | compact | 紧凑面板 |
| 40~59 | cols-2 | narrow | `ui_kv2` 退化为两行单列；标签列 8、标题列 12 |
| <40 | cols | plain | 边框函数为空操作；纯文本输出 |

- `SBM_COLS=N` 仍可覆盖；非法值回退 80；无 `tput` 时默认 80
- `_ui_truncate_ansi`：含 ANSI 码文本按可视宽度安全截断，任何内容永不越界
- `ui_menu_select` 行模式列表同样按 `UI_W` 截断描述（Phase 4 补齐，见第六节）

## 二、设计规范落实情况

| 规范 | 落实 |
|---|---|
| 方向键导航（↑↓ + 回车 + Esc + q） | 全部 15 个页面统一经 `ui_menu_select`（主菜单非 TTY 保留原有 `read`，见下） |
| 两位数快捷键 10–13（TTY） | Phase 4 修复：数字键 0.4 秒缓冲，快按 `1` `2` 选中 12，停顿按首位匹配（`tests/ui_twokey_test.sh` 9/9） |
| 宽度自适应 120–30 列，0 越界 | 主菜单 + reality/warp/订阅中心在 120/100/80/60/40/30 六档逐行校验，0 越界（Phase 4） |
| `NO_COLOR=1` 去色 | 主菜单 + 6 个子菜单输出零 ANSI 码（Phase 4） |
| `SBM_ASCII=1` ASCII 边框 | 主菜单 + 3 个子菜单无 Unicode 边框字符（Phase 4） |
| 非 TTY 降级 | 管道输入可完成主菜单→子菜单→返回→退出全流程；EOF 直接退出（Phase 4） |
| 危险操作确认强度不降低 | 卸载单次 `ui_dialog_confirm` 默认取消，与旧版 `ui_confirm` 同强度；WARP 卸载同样 |
| 状态诚实（不虚构成功） | 仪表盘三态来自实测；WARP 菜单头出口恒标“未验证/无法验证”，实测结论只出自 `[1/c]` 五层检测；调优页区分“已配置”与“实际生效” |
| 标签列规范（kv 10 / 标题 16） | 正常宽度保持不变，仅窄屏按比例收紧（8/12）；40 列下 `CORE STATE`/`PUBLIC IP` 截断为 `CORE ST…`/`PUBLIC …`，值完整（已知限制） |
| CLI 接口零改动 | 40 条 CLI 用例与 v1.7.0 基线逐字节一致（Phase 4，见 UI-COMPATIBILITY-REPORT.md） |
| 业务零改动 | `declare -f` 逐函数审计：118 个函数逐字节一致，28 个不同函数全部在 UI 允许清单内（见第七节） |

### 有意的行为差异（采用 `ui_menu_select` 的固有语义）

1. **无效输入由“直接返回”改为“重问”**：旧子菜单任意无效输入走 `*)` 返回上一级；
   新行模式打印提示并重问，TTY 下忽略未知按键停留菜单。主菜单非 TTY 路径保留旧行为
   （无效输入警告 + 重绘循环）。
2. **主菜单非 TTY 不走 `ui_menu_select`**：面板已完整展示全部选项与键位，再由选择器
   重打一遍 15 行列表是纯噪声；非 TTY 保留原有 `read -rp` 行输入（提示串与 `case`
   分发原样）。
3. **卸载/危险项标红丢失**：`ui_menu_select` 无单项颜色参数，危险性现由确认框文案承载。
4. **空输入默认选中“返回”**：各子菜单默认下标一律为末项（空输入返回），避免回车误触安装。
5. **WARP 菜单未展示的字母键不再响应**：旧版 `1|i|I|c|C` 同分支，新版按安装状态只展示
   对应 entry（`1/i` 或 `1/c`），菜单上看不到的键本就不该有行为。

## 三、全部页面清单与状态

15 个交互入口全部完成重构（基线见 `UI-BASELINE.md` §4）：

| # | 页面 | 函数 | 文件 | 状态 |
|---|---|---|---|---|
| 1 | 主菜单（运维控制台） | `main_menu` | sbx.sh | ✔ 品牌头 + 仪表盘 + 四组导航 + 页脚，方向键导航 |
| 2 | 内核服务维护 | `menu_maintenance` | sbx.sh | ✔ 分组 + 摘要行 + 方向键导航 |
| 3 | 运行环境诊断 | `run_diagnostics` | sbx.sh | ✔ 结构化分组 + 结果药丸 + 失败建议 |
| 4 | VLESS-Reality | `menu_reality` | protocols/reality.sh | ✔ 状态面板 + 选择器，安装/修改/卸载消息框 |
| 5 | Hysteria 2 | `menu_hysteria2` | protocols/hysteria2.sh | ✔ 同上（3 项） |
| 6 | TUIC v5 | `menu_tuic` | protocols/tuic.sh | ✔ 同上（3 项） |
| 7 | AnyTLS | `menu_anytls` | protocols/anytls.sh | ✔ 同上（3 项） |
| 8 | Cloudflare Argo | `menu_argo` | protocols/argo.sh | ✔ 同上（6 项，隧道服务行保留） |
| 9 | SOCKS5 | `menu_socks5` / `show_socks5_params` | protocols/socks5.sh | ✔ 同上（3 项）；参数面板错误提示改 `ui_msg_*`，文案/返回值不变 |
| 10 | WARP 与域名分流 | `menu_warp` | protocols/warp.sh | ✔ 只读状态探针 + 8/2 条件选项，出口恒标未验证 |
| 11 | 节点命名中心 | `menu_node_naming` | utils/export.sh | ✔ 自动探测摘要 + 自定义前缀改 `ui_read_text` |
| 12 | 节点订阅中心 | `show_export_menu` | utils/export.sh | ✔ 只读节点统计 + 协议药丸，SOCKS5 不计入节点数 |
| 13 | 在线订阅服务 | `menu_subscription_service` | utils/subscription.sh | ✔ 服务三态 + 令牌只显状态不显值；启用输入改 `ui_read_text` |
| 14 | 系统网络调优 | `sysctl_menu` | utils/sysctl.sh | ✔ “已配置 vs 实际生效”两栏对照，跳跃输入改 `ui_read_text` |
| 15 | 彻底卸载 | `uninstall_all` | core/engine.sh | ✔ 危险页面（删除/保留清单）+ 单次确认 + 四阶段执行报告 |

展示样本：`docs/ui-samples/`（主菜单 80/60/40/120 列、reality/warp/订阅中心 80 列、
NO_COLOR 与 ASCII 主菜单各 80 列，含 ANSI 原始版与纯文本版，见该目录 `README.md`）。

## 四、新增 API

### 导航

```
ui_menu_select <prompt> <default_index> <entry...>
# entry 格式："key|label|desc"（key 如 "1/r"，desc 可空）
# 返回：0=选中，1=返回(Esc)，2=退出(q)，3=EOF/中断
# 结果：UI_SEL_IDX（0 起下标）、UI_SEL_KEY（选中项 key 字段，如 "1/r"）
```

- TTY：方向键高亮列表（反显 + `❯` 双通道），↑/↓ 移动，回车确认，Esc 返回，
  q 退出，数字/字母快捷键直接选中（字母不区分大小写）；数字键带 0.4 秒缓冲
  支持两位数快捷键（Phase 4）；`SBM_MENU_LINE=1` 或 `TERM=dumb` 时强制行输入模式
- 非 TTY：打印列表（描述按 `UI_W` 截断，Phase 4）+ 行输入；空输入选中默认项；
  `q` 返回 2；EOF 返回 3；无效输入重问
- 终端安全：`stty -g` 保存/恢复；EXIT/INT/TERM trap 兜底；信号 trap 只置标志，
  恢复由主循环在 `read` 返回后做；调用方原有 trap 在退出时恢复

### 确认框与消息框（dialog.sh）

- `ui_confirm "提示"`：签名不变，TTY 下带边框确认框，默认 N
- `ui_dialog_confirm "提示"`：带边框确认框本体（`ui_confirm` 的薄包装）
- `ui_msg_ok` / `ui_msg_warn` / `ui_msg_err` / `ui_msg_info`：带边框单行消息

### 输入组件（input.sh）

| 函数 | 行为 |
|---|---|
| `ui_read_text "提示" "默认值"` | 读入 `UI_INPUT`；空输入返回默认值 |
| `ui_read_secret "提示"` | 静默读入（`read -s`），`UI_INPUT` |
| `ui_read_port "提示" "默认值"` | 仅格式提示（1-65535），不做业务校验 |
| `ui_read_choice "提示" "选项1\|选项2\|..." "默认下标"` | 数字选择，`UI_INPUT` 为 0 起下标 |

全部支持 EOF 返回非零；stdin 非 TTY 时直接读行，不渲染装饰。

### 进度 / 状态 / 仪表盘

- `ui_stage <当前> <总数> <描述>`：如 `[1/3] 正在下载内核...`
- `ui_spinner_start "提示"` / `ui_spinner_stop "[完成提示]"`：仅 TTY 且未禁用动画时
  转圈（`SBM_NO_ANIM=1` 禁用），非 TTY 降级为普通 log 行
- `ui_status_pill <状态> [显示文本]`：状态药丸，颜色 + 文字双通道
- `ui_dash_row` / `ui_dash_title`：仪表盘行与分区标题（窄屏自动退化）

### 主题（theme.sh）

`T_PRIMARY`/`T_SUCCESS`/`T_WARNING`/`T_DANGER`/`T_INFO`/`T_MUTED`/`T_ACCENT`/`T_TEXT`
映射 env.sh 颜色；`T_SYM_*` 状态符号随字符集重算。

### 环境变量（新增）

| 变量 | 作用 |
|---|---|
| `SBM_MENU_LINE=1` | `ui_menu_select` 强制行输入模式 |
| `SBM_NO_ANIM=1` | 禁用 spinner 动画（降级为 log 行） |

原有 `NO_COLOR` / `SBM_FORCE_COLOR` / `SBM_ASCII` / `SBM_COLS` / `SBX_AUTO` 行为全部保留。

## 五、变更文件清单

与 `/tmp/v17_work`（v1.7.0 基线）逐文件 diff（`diff -rq` + `declare -f` 逐函数审计，
审计脚本 `/tmp/p4/func_audit.py`，结果 `FUNC AUDIT: PASS`）：

### 新增文件

| 文件 | 说明 |
|---|---|
| `core/ui/*.sh`（12 个模块） | 新 UI 架构（见第一节） |
| `tests/ui_test.sh` | Phase 1 UI 回归测试（74 项） |
| `tests/ui_twokey_test.sh` | Phase 4 两位数快捷键 PTY 测试（9 项） |
| `docs/ui-samples/`（18 个文件） | 展示样本 + README |
| `UI-BASELINE.md` / `UI-FUNCTION-INVENTORY.md` / `UI-COMPATIBILITY.md` | Phase 0 盘点文档 |
| `UI-REDESIGN-REPORT.md` / `UI-TEST-REPORT.md` / `UI-COMPATIBILITY-REPORT.md` | Phase 4 最终报告（本文档与姊妹篇） |
| `PHASE1-REPORT.md` / `PHASE2-REPORT.md` / `PHASE3A-REPORT.md` / `PHASE3B-REPORT.md` / `PHASE3C-REPORT.md` | 各阶段交付报告（原 v1.7.0 审查报告已归档为 `PHASE1-REPORT-v170-review.md` / `PHASE2-REPORT-v170-review.md`） |

### 修改文件（仅 UI 层）

| 文件 | 改动范围 |
|---|---|
| `core/ui.sh` | 248 行单文件 → 36 行加载器 |
| `core/ui/navigation.sh` | Phase 4：数字键 0.4 秒缓冲（两位数快捷键）+ 行模式列表截断 |
| `sbx.sh` | `get_telemetry` 扩展（只读字段）+ `main_menu`/`menu_maintenance`/`run_diagnostics` 重构 + 3 个私有辅助；`sbx_main`/`install_all_protocols`/文件头逐字节一致 |
| `core/engine.sh` | 仅 `uninstall_all`（危险页面 + 四阶段报告） |
| `protocols/reality.sh` 等 6 个协议文件 | 仅各 `menu_*`（+ socks5 的 `show_socks5_params` 两行 log→ui_msg） |
| `protocols/warp.sh` | `menu_warp` + 新增只读探针 `_warp_menu_status` |
| `utils/export.sh` | `menu_node_naming`/`show_export_menu` + 新增只读统计助手 |
| `utils/subscription.sh` | `menu_subscription_service` + `subscription_enable` 内两处输入改 `ui_read_text` |
| `utils/sysctl.sh` | 仅 `sysctl_menu`（含两处输入改 `ui_read_text`） |
| `README.md` | 新增一节 `Modern TUI`（其余不动） |
| `CHANGELOG.md` | v1.7.0 下新增 `TUI 实验分支`条目 |

### 未改动（逐字节一致）

`core/env.sh`、`core/state_manager.sh`、`core/json_builder.sh`、`utils/cert.sh`、
`utils/subscription_server.py`、`templates/`、`install.sh`、全部既有测试文件。
`utils/__pycache__/subscription_server.cpython-312.pyc` 字节有差异，但仅因内嵌的
源文件路径不同（`/tmp/v17_work/...` vs `/tmp/tui_work/...`），`.py` 源码逐字节一致，
属构建产物而非源码改动。

## 六、Phase 4 修复的两个新 UI 层 bug

1. **TTY 两位数快捷键无法输入**（Phase 2 报告第八节第 1 条）：
   `ui_menu_select` 单字符立即匹配，按 `1` 立即进 Reality，无法输入 10–13。
   修复：数字键读到后等 0.4 秒看是否有第二位到达；两位组合匹配则选中两位数，
   否则按首位匹配；第二位按键永不丢失（无匹配时存入 `_pending` 下一轮重处理）。
   字母键仍立即匹配。验证：`tests/ui_twokey_test.sh` 9/9 + 主菜单级 PTY 4/4，
   `tests/ui_test.sh` 仍 74/74。
2. **行模式选项列表在窄屏越界**（Phase 4 宽度回归新发现）：
   `_ui_menu_select_line` 原样打印 `[key] label  desc` 不截断，60 列下 warp/订阅中心
   各 1 行越界，40/30 列下 reality/warp/订阅中心多行越界（最长 65 列）。
   修复：描述按 `UI_W-2` 截断（加省略号），key/label 完整保留；80 列下输出与改前
   逐字节一致。验证：六档宽度 × 4 个菜单 24/24 零越界；Phase 3a/3b/3c 全部 harness
   重跑仍全过（132+37+6+69）。

## 七、业务零改动审计

方法：`source` 两树全部模块，用 `declare -f` 导出每个函数的规范定义并逐函数比对
（脚本 `/tmp/p4/func_dump.sh` + `/tmp/p4/func_audit.py`）：

- v17 函数 146 个，tui 函数 179 个；**零删除**
- 新增 33 个函数全部为 UI 层（`ui_*`/`_ui_*`/`_sbx_*`/`_warp_menu_status`/`_export_*`）
- 定义不同的 28 个函数全部在 UI 允许清单内（15 个菜单函数 + `get_telemetry` +
  `show_socks5_params` + `subscription_enable` + 10 个旧 UI 组件重实现）
- **118 个函数逐字节一致**，含 `sbx_main`、`install_all_protocols`、全部
  `install_*`/`uninstall_*`（除 UI 页面的 `uninstall_all`）、`warp_check`、
  `export_all_nodes`、全部 `state_*` 与配置生成函数
- 另有 hunk→函数映射审计（`/tmp/p4/diff_audit.py`）交叉验证：13 个改动 `.sh`
  文件的全部改动行均落在允许的 UI 函数内（另有两处新增全局变量/注释块落在函数间
  空隙，`declare -f` 证实相邻业务函数逐字节一致，属映射口径假阳性，已排除）

## 八、未解决问题清单

### 既有业务 bug（只记录，不修——按任务书第十三节，业务 bug 单独记录）

1. **`core/state_manager.sh` 的 `_state_lock` 永久吞掉整个 shell 的 stderr**（v1.7.0 基线已有）：
   - **现象**：`sbx_main` 开头即调 `init_state_file` → `_state_lock`，之后整个生产会话的
     stderr 再无输出。行模式下 `read -p` 提示行与 `ui_menu_select` 的“无效选项”提示
     （均走 stderr）在生产中**不可见**（用户仍可盲输，功能不受影响）；`log_*` 走 stdout
     不受影响；TTY 方向键模式用 `printf` 走 stdout，亦不受影响。
   - **根因**：`state_manager.sh:26` 的 `exec 200>"$lock_file" 2>/dev/null` 是无命令的
     `exec`，按 bash 语义会把**当前 shell 自身的 stderr 永久重定向到 /dev/null**；
     同文件 :31、:46 另有两处同类写法（`exec 200>&- 2>/dev/null`）。已用独立脚本实测证实：
     `_state_lock` 后 stderr 再无输出；`/tmp/v17_work` 基线同样存在，旧菜单同样受影响，
     非本次 TUI 重构引入。
   - **影响范围**：所有行模式提示（含主菜单与全部子菜单的输入提示、确认框文案、无效选项提示）。
   - **修复建议**（另立任务，改 `state_manager.sh`）：去掉三处 `exec` 行的 `2>/dev/null`，
     改为 `exec 200>"$lock_file" || return 1`（失败已有 `return 1` 处理，错误信息留在
     stderr 是期望行为），并对 31/46 行的 `exec 200>&- 2>/dev/null` 同样处理；或改用
     `{fd}>"$lock_file"` 动态分配。修好后“无效选项”等文案在完整菜单流程里即可见。
2. **业务函数返回值口径（既有）**：`install_*` / `uninstall_*` 末尾是无 else 的
   `if apply_inbound …; fi`，`apply_inbound` 失败时函数仍返回 0。此时 `ui_msg_ok` 会按
   返回值呈现成功，但 `config_transaction` 已在上方打印 `log_err`，用户可见真实错误。
   彻底修好需给业务函数补显式 `else return 1`（`install_all_protocols` 依赖同一信号，同样受益）。
3. **卸载时状态清理失败按业务口径视为成功**：业务函数自认“可忽略，状态会在下次操作时
   自动修复”且返回 0，`ui_msg_ok` 与之口径一致，未另行判错。

### TUI 已知限制（设计取舍或待真机验证）

4. **真机验证待做**：iPhone Termius / Xshell / PuTTY 下的方向键、反显、边框对齐与各宽度
   实际观感仍需用户真机验证（沙箱只有 `script` 伪终端）。
5. **TTY 下主菜单面板与选择器列表同时显示**：合计约 47 行，24 行高的矮终端上方面板会滚出视野；
   选择器 desc 带实时状态可部分弥补。
6. **40 列窄屏两个仪表盘标签截断**：`CORE STATE` → `CORE ST…`、`PUBLIC IP` → `PUBLIC …`
   （标签列收紧为 8，值完整），与窄屏其他标签的截断行为一致，属窄屏降级设计。
7. **`ui_hint` 长行不截断**：面板下方“快捷命令: sbx […]”约 90 列，在窄屏/plain 下超出面板宽度
   （Phase 1 已知限制；宽度校验时按既定口径排除）。
8. **`ui_node_card` 的链接故意不截断**（截断会破坏复制），超长链接在窄屏/plain 下可能越界——
   可复制性优先于对齐的有意取舍；`ui_hint` 单行长文本同样不截断。
9. **WARP「已连接」是本地证据推断**（已安装 + 服务运行 + 端点在配置中），不是流量验证；
   隧道实际不通时仪表盘仍显示已连接。权威检测仍是 WARP 菜单的 `warp_check`（五层，含流量验证）。
10. **非 TTY 下确认框文案不可见（既有行为）**：`ui_dialog_confirm` / `ui_confirm` 在非 TTY 下用
    `read -p` 行内提示，bash 仅在 stdin 为终端时显示提示——管道输入时用户看不到确认文案，
    只能凭上下文输入 y/n。v1.7.0 的旧 `ui_confirm` 同样如此。TTY 下带边框确认框正常显示文案。
    如需修，应改 `core/ui/dialog.sh`，在非 TTY 下先 `echo` 文案再读入。
11. **`ui_menu_select` 行模式提示为通用 `1-N / q`**（如订阅中心显示 `1-7 / q`），与实际键位
    `0-6 / v r c s u p q` 不完全对应；列表本身已展示真实键位，组件既有行为。
12. **`ui_menu_select` 不可重入**（使用全局 `_UI_MENU_*` 状态）；同一时刻只能有一个菜单。
    它会临时接管调用方的 EXIT/INT/TERM trap，退出时恢复。
13. **Esc 判定依赖 0.05 秒超时**：终端延迟极高时，方向键首字节可能被误判为单独 Esc
    （实测本地终端无此问题）。
14. **窄屏（<60 列）下卸载清单的长路径行会被 `ui_line` 安全截断**（加省略号），不会越界，
    但尾部可能看不全；80 列正常宽度下全部完整显示。
15. **socks5“查看参数”未加入菜单**：任务书曾列该选项，但现有文件菜单只有安装/卸载/返回三项，
    `show_socks5_params` 仅在安装成功后与订阅菜单中调用，无对应菜单入口与快捷键；
    按“不得发明快捷键/选项顺序”约束未新增。如需加入，需产品定键位后另做。
16. **spinner 只在 stdout 为 TTY 时转圈**；输出重定向到文件时降级为 log 行。
    `ui_menu_select` 的 TTY 路径要求 `stty` 可用；无 `stty` 时自动降级行输入。

## 九、各阶段报告索引

- `PHASE1-REPORT.md` — UI 底层架构（12 模块 + `ui_menu_select` + 74 项测试）
- `PHASE2-REPORT.md` — 主界面升级（运维控制台 + 维护菜单 + 结构化诊断）
- `PHASE3A-REPORT.md` — 协议管理页面统一重构（6 个协议菜单，132/132）
- `PHASE3B-REPORT.md` — 订阅中心、命名中心、WARP 页面重构（37+6）
- `PHASE3C-REPORT.md` — 网络调优与卸载页面重构（69/69）
- `UI-TEST-REPORT.md` — 全部测试结果汇总（Phase 4）
- `UI-COMPATIBILITY-REPORT.md` — CLI 兼容性与终端矩阵（Phase 4）
- `UI-BASELINE.md` / `UI-FUNCTION-INVENTORY.md` / `UI-COMPATIBILITY.md` — Phase 0 盘点
