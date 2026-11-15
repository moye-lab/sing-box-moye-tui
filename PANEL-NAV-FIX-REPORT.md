# PANEL-NAV-FIX-REPORT.md — 主菜单重复显示修复报告

- 完成日期：2026-11-15
- 分支：sing-box-moye-tui（实验分支，版本保持 1.7.0，未推送）
- 工作目录：`~/workspace/tui_work`（`/tmp/tui_work` 为符号链接）

## 一、问题（用户真机反馈 2026-11-15 16:25）

用户在 RN 上装好 TUI 版后截图：主菜单显示了两遍内容——上面是仪表盘面板
（品牌头 + SYSTEM OVERVIEW + 四组导航，含全部 15 个选项），下面
`ui_menu_select` 又重复列了一遍 15 个选项，带绿色高亮条。用户反馈
“感觉是不是更麻烦了一点”：手机屏幕小，两遍加起来占满屏，看着乱。

## 二、根因

`sbx.sh` 的 `main_menu` 先用 `ui_proto_row`/`ui_item` 直接把 15 个选项画进
仪表盘面板，随后又调用 `ui_menu_select`，后者在 TTY 模式下会在面板下方
再画一份同样的选项列表（`_ui_menu_draw`）用于方向键高亮导航。同一份选项
因此出现两次。

同类问题只存在于主菜单与维护菜单（`menu_maintenance` 面板里同样先画了
4 个 `ui_item` 再调 `ui_menu_select`）。协议子菜单、WARP、调优、订阅等
面板只含状态信息（`ui_kv` 状态行），选项本就由选择器单独渲染，无重复，
本次未动。

## 三、修复方案

新增面板内导航：方向键直接在已渲染的面板内移动高亮，不再另画列表。

### 1. 新增面板 API（`core/ui/navigation.sh`）

| 函数 | 作用 |
|---|---|
| `ui_panel_begin` | 重置面板（行数组 + 菜单映射 + 提示行） |
| `ui_panel_add <文本>` | 追加已渲染文本，按换行拆分，记为非菜单行 |
| `ui_panel_add_menu <idx> <单行>` | 追加菜单行，记下 entry 下标供高亮定位 |
| `ui_panel_add_hint <文本>` | 追加面板下方提示行（计入光标回移行数） |
| `ui_panel_print <sel>` | 打印面板 + 提示，选中行高亮；记录总行数 |
| `ui_panel_redraw <sel>` | 光标上移总行数后重画面板（选中项变化时调用） |
| `ui_menu_select_panel` | 面板模式选择器：只做按键循环，不画列表 |

关键设计点：

- **逐行捕获而非固定行号**：窄屏下 `ui_dash_row` 会退化为两行（`ui_kv2`
  单列），面板总行数随宽度变化，固定行号不可靠。改为渲染时逐个捕获
  `ui_*` 调用的输出（`ui_panel_add "$(ui_top)"` 形式），菜单行显式记下标。
- **高亮实现**：行内已有颜色码（首个 PLAIN 会取消反显），先 `ui_strip`
  去色再整体包 `\033[7m…\033[0m` 反显整行（含边框）。
- **NO_COLOR**：不用任何 ANSI，用 `»` 标记选中行（替换左边框后的两格
  边距，宽度不变；plain 无边框模式则前缀 `»` 后截断到 UI_W）。
- **非 TTY**：`ui_panel_print` 在 stdout 非 TTY 时强制无高亮，管道输出
  保持纯文本。
- **重画策略**：仅选中项变化时重画（39 行全重画，内容相同仅两行不同，
  无闪烁感）；无变化按键（越界方向键、无关按键）不刷屏。

### 2. `_ui_menu_select_tty` 增加面板模式

`_UI_MENU_DRAW_MODE=panel` 时：不打印提示与列表（面板已由调用方打印），
循环底部仅在 `sel` 变化时调 `ui_panel_redraw`。列表模式（子菜单用）行为
逐字节不变。`ui_menu_select` 入口防御性复位 `_UI_MENU_DRAW_MODE=list`。

`ui_menu_select_panel` 的降级链与 `ui_menu_select` 一致：TTY 不可用时
`stty sane` 重试一次，仍失败则走 `_ui_menu_line_keys`（面板已打印，不重画
列表；TTY 下仍支持方向键 + 单行指示）。数字序号定位禁用（仅 key 匹配，
与 `ui_menu_read_key` 同理，避免输入 14 选中卸载项）。

### 3. `sbx.sh` 主菜单与维护菜单重构

- 主菜单：39 次 `ui_*` 渲染全部改为逐行捕获进面板数组，菜单行记下标；
  `_sbx_cli_hint` 输出捕获为提示行；`ui_panel_print 0` 打印初始高亮后调
  `ui_menu_select_panel`。
- **entries 按面板视觉顺序排列**：面板里 03 组是 10/o、13/w，04 组是
  11/s、12/d——视觉顺序是 13/w 在 11/s 之前。entries 数组相应调整为
  `… 10/o, 13/w, 11/s, 12/d, x, 0/q`，方向键 ↓ 沿视觉顺序移动；快捷键按
  key 匹配，与顺序无关；`opt="${UI_SEL_KEY%%/*}"` 的 case 分发不受影响。
- 维护菜单：同样改为面板捕获 + `ui_menu_select_panel`（`ui_menu_head`
  拆为 `ui_clear` + 捕获 `ui_top`/`ui_split`，内容逐字相同）。
- 行模式降级分支（非 TTY / `SBM_MENU_LINE=1`）仍用 `ui_menu_read_key`，
  行为不变。

## 四、测试结果

新增 `tests/panel_nav_test.sh`：**39/39 通过**，含：

- 静态检查 8 项：主菜单/维护菜单调用 `ui_menu_select_panel` 且不再调用
  `ui_menu_select`；entries 视觉顺序（13/w 在 11/s 前）；面板下标映射
  （13/w→10、11/s→11、0/q→14）。
- 面板 API 单元测试 8 项：多行拆分、菜单映射、总行数、单次渲染、
  非 TTY 无 ANSI、高亮（颜色去色反显 / NO_COLOR `»` 标记 / plain 前缀）。
- PTY 机制测试 13 项（小面板）：仅回车时每项出现 1 次；↓↓回车选中下标 2；
  重画光标上移 9 行（8 面板行 + 1 提示行）；↑ 首项不越界；字母 h；Esc/q；
  行模式方向键；无 `^[[` 漏出；stty 恢复。
- PTY 主菜单端到端 8 项（mock 状态，无网络）：仅 q 时 `[1/r]`、`[13/w]`、
  `[11/s]`、`SYSTEM OVERVIEW`、`SING-BOX MOYE` 各出现 1 次；初始高亮含反显；
  ↓回车进 Hysteria 2 子菜单再 Esc→pause→q 正常退出；**↓×10 回车进 WARP
  菜单（视觉顺序端到端验证）**。
- PTY 维护菜单 2 项：仅 q 时 `[1/u]`/`[2/r]` 各 1 次，q 正常返回。

既有套件全过（改动后复跑）：ui_test 74/74、ui_twokey 9/9、round2 13/13、
termius_fix 30/30、warp/export/anytls/smoke/install_all/version_check 全部
通过；全项目 `bash -n` 通过。

目视验证（PTY 捕获，mock 两个已安装协议）：单面板布局与改前逐行一致，
初始反显正好落在 `[1/r] VLESS-Reality` 行；按 ↓ 后反显移到 `[2/h]`，
重画上移 41 行（39 面板行 + 2 提示行）；60 列窄屏下每项仍只出现 1 次，
面板 58 宽无越界。

## 五、用户侧验证（RN 上重装后）

```bash
bash <(wget -qO- https://raw.githubusercontent.com/moye-lab/sing-box-moye-tui/v1.7.0-tui/install.sh)
```

重装后 `sbx` 应只显示一个仪表盘面板，`[1/r]` 行初始反显；按 ↓ 高亮在
面板内逐行下移（经过 10/o 后是 13/w，再往下是 11/s）；数字/字母快捷键
照常直达；q 退出。

## 六、已知限制

- 面板高于终端可视行数时（如小屏横屏），光标上移重画会对不齐（与旧版
  列表模式的同类限制一致；iPhone Termius 竖屏约 60 行可完整容纳 41 行面板）。
- NO_COLOR 下选中行只用 `»` 标记（无反显），与旧版列表模式在 NO_COLOR
  下无任何高亮相比已有改善，但不如颜色模式醒目。
- `state_manager.sh` 的 stderr 吞没 bug（`exec 200>... 2>/dev/null`）仍未修，
  与本次无关，另见 UI-TEST-REPORT.md §八。
