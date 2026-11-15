# 方向键导航移除报告

**日期**：2026-11-15
**分支**：sing-box-moye-tui（实验分支，版本保持 1.7.0）
**决策**：用户 2026-11-15 22:18 决定移除方向键导航

## 一、为什么移除

1. **用不上**：用户主要在 iPhone Termius 上操作，方向键要切特殊键盘才能按；字母快捷键（r/h/t/a/p/y/w/q）按一下直接进，更快更顺手。
2. **bug 重灾区**：方向键是 2026-11-15 当天三轮修复的全部根因——Termius 回显 `^[[A`、面板内导航重画、子菜单 dd 重写，全是方向键的 termios/转义序列处理惹的祸。
3. **TUI 的价值不在方向键**：仪表盘、面板、颜色、状态显示这些视觉呈现不受影响，只是导航方式简化为字母/数字键。

## 二、移除内容

`core/ui/navigation.sh` 734 行 → 388 行（-346 行）：

| 移除项 | 说明 |
|---|---|
| `_ui_menu_select_tty` | 方向键高亮列表（TTY 主路径） |
| `ui_menu_select_panel` | 面板内方向键高亮移动（主菜单/维护菜单用） |
| `ui_panel_redraw` / `_ui_panel_highlight` | 面板高亮重画与反显逻辑 |
| `_ui_menu_draw` | 方向键列表重绘 |
| `_ui_menu_line_indicator` | 行模式方向键单行选择指示 |
| `_ui_menu_read_byte` / `_ui_menu_read_byte_timed`（dd 版） | dd 字节读（方向键专用，不再需要） |
| `_ui_menu_tty_enter` / `_ui_menu_cleanup` / `_ui_menu_on_signal` | stty termios 保存/恢复 + EXIT/INT/TERM trap 管理 |
| `_UI_MENU_STTY` / `_UI_MENU_ACTIVE` / `_UI_MENU_INTERRUPTED`（旧）/ `_UI_MENU_OLD_TRAP_*` / `_UI_MENU_READ_MODE` / `_UI_MENU_DRAW_MODE` / `_UI_PANEL_TOTAL` | 方向键支持的状态变量 |

配套改动：

- `sbx.sh`（480 → 457 行）：删除 `_ui_menu_tty_ready` 分支判断，主菜单/维护菜单直接调 `ui_menu_read_key` 读键；面板提示行改为"字母直接进入 · 数字+回车确认 · Esc 返回 · Q 退出"；`ui_panel_print 0` → `ui_panel_print`（无高亮参数）。
- `core/ui.sh`：删除"定位方向键失效时用"注释。
- `protocols/*.sh`（6 个）：注释"TTY 方向键高亮"改为"字母立即、数字需回车"。
- `ui_tty_ready` 简化：不再要求 stty 可用（本文件已不调用 stty），仅判断 stdin 是否为 TTY + `SBM_MENU_LINE`。

## 三、新的输入模型

```
TTY（stdin 为 TTY）：
  字母键 ──→ 立即匹配执行，无需回车
  数字键 ──→ 只缓存 + 回显，必须回车确认（否则输 10 会误入 1）
  回车（无缓存）──→ 选中默认项
  退格 ──→ 删数字缓存最后一位
  Esc ──→ 返回（单独 Esc；转义序列整段忽略）
  q ──→ 退出（丢弃数字缓存）
  方向键等转义序列 ──→ 整段忽略，不导航，不回显 ^[[
  Ctrl+C ──→ 返回 3（调用方作返回处理）

非 TTY 或 SBM_MENU_LINE=1：
  read -rp 整行读，语义与 v1.7.0 一致（空行=默认项，数字序号定位仅 ui_menu_select 可用）
```

实现要点：

- **逐字节读改回 bash `read -n`**：`read -n` 会自行切非规范模式，无需 stty/dd，不碰终端状态，退出后 stty 天然不变（测试 STTY_OK 全部通过）。方向键移除后不再需要解析三字节转义序列，`read -n` 在读与读之间恢复 termios 的窗口不再构成问题——单字节按键（字母/数字/回车）在读期间即被消费，`-s` 静默保证不回显；方向键序列即使有个别字节落在窗口内，也只是极轻微的视觉噪声，且后续字节仍会被短超时读吞掉（实测无 `^[[` 漏出）。
- **Esc 与转义序列区分**：读到 `0x1b` 后用 0.05 秒短超时读后续字节；有后续字节说明是转义序列，整段忽略；无后续字节才是单独 Esc。
- **Ctrl+C 处理**：沙箱实测确认，trap 执行后 `read` 不会提前返回（trap 在 0.5 秒时触发，`read -t 3` 仍等满 3 秒才返回 rc=142）。因此用 0.2 秒短超时轮询 `read -t 0.2`，每轮检查 INT trap 置位的 `_UI_MENU_INTERRUPTED` 标志；有按键时 `read` 立即返回，无额外延迟；Ctrl+C 最多 0.2 秒后返回 3。行模式下不设 trap，Ctrl+C 按默认行为终止脚本（与主线一致）。
- **公共接口不变**：`ui_menu_select` / `ui_menu_read_key` 签名与返回码（0=选中，1=Esc，2=q，3=EOF/中断）不变；`ui_panel_begin/add/add_menu/add_hint/print` 保留（`ui_panel_add_menu` 的下标仅作行属性记录，不再用于高亮）。

## 四、保留的功能

- TUI 视觉呈现：仪表盘、面板、颜色、状态显示、菜单布局全部保留。
- 字母键立即执行、数字键回车确认（2026-11-15 21:57 用户定）。
- Esc 返回、q 退出。
- stderr 修复（`core/state_manager.sh` 三处 `exec` 的 `2>/dev/null` 去除，pause 提示可见）——本次未动，测试 D1–D3 持续覆盖。

## 五、测试结果

| 套件 | 结果 | 说明 |
|---|---|---|
| `tests/ui_test.sh` | **75/75** | PTY 段改写：数字 3+回车、方向键忽略无回显、提示行检查 |
| `tests/termius_fix_test.sh` | **30/30** | PTY 段改写：TERM 场景用字母/数字键；行模式用整行输入；stty 失效改为"菜单不依赖 stty" |
| `tests/panel_nav_test.sh` | **44/44** | 全面改写：静态检查改 `ui_menu_read_key`；高亮单测改为无反显检查；PTY 机制/主菜单端到端改字母/数字导航 |
| `tests/submenu_nav_test.sh` | **21/21** | 删除 dd 字节读单测（E 段改为移除静态检查）；A/C 段方向键导航改为字母/数字导航 + 方向键忽略 |
| `tests/ui_twokey_test.sh` | **12/12** | 未改逻辑（仅注释），字母/数字规则不变 |
| `tests/round2_regression.sh` | **15/15** | 未动 |
| `tests/warp_sbx_owner_fix_test.sh` | **15/15** | 未动（沙箱无真实 sing-box 时 3 项条件断言跳过，计 15） |
| `tests/warp_healthcheck_fix_test.sh` | **34/34** | 未动（同上，计 34） |
| `tests/warp_verify_persist_test.sh` | **48/48** | 未动 |
| `tests/warp_temp_cleanup_test.sh` | **53/53** | 未动 |
| `tests/warp_test.sh` / `export_test.sh` / `anytls_test.sh` / `install_all_test.sh` / `version_check.sh` / `smoke.sh` | 全部通过 | 未动 |

另做 8 项 PTY 冒烟验证（新菜单逻辑）：字母 h、数字 3+回车、仅回车默认、Esc、q、方向键忽略、无效数字提示后继续、Ctrl+C 返回 3，全部通过，stty 前后一致，无 `^[[` 漏出。

`bash -n` 全项目通过。

## 六、改动文件

```
core/ui/navigation.sh     | 592 ++++------------------------------------  (734 → 388 行)
sbx.sh                    |  69 ++----
core/ui.sh                |   2 +-
protocols/{anytls,argo,hysteria2,reality,socks5,tuic}.sh | 各 2 +-
tests/panel_nav_test.sh   | 210 +++++++++-------
tests/submenu_nav_test.sh | 127 ++++------
tests/termius_fix_test.sh |  70 +++---
tests/ui_test.sh          |  22 +-
tests/ui_twokey_test.sh   |   2 +-
CHANGELOG.md              | 新增方向键移除条目
ARROW-KEY-REMOVAL-REPORT.md | 新增（本文件）
```

总计：15 个文件，373 行新增，734 行删除。

## 七、未动事项

- `warp_set_domains` 状态锁泄漏（`WARP-TEMP-CLEANUP-FIX-REPORT.md` §六）本次未动。
- "Ctrl+C 后 WARP 显示未安装"（同报告 §七）本次未动。
- 主线同步建议（未立项）：stderr 吞没 bug 主线同样存在（同源文件），值得另行同步；方向键移除仅针对 TUI 分支，主线本就无方向键菜单。
- RN 真机验证：沙箱 PTY 已覆盖全部按键路径，但 Termius 真机仍建议用户重装后抽查：主菜单字母 h 进 Hy2、数字 13+回车进 WARP、子菜单 q 直返、pause 提示可见。
