# PHASE1-REPORT.md — TUI 重构 Phase 1：UI 底层架构

- 完成日期：2026-11-15
- 基线：sing-box-moye v1.7.0（含第二轮复审整改），工作目录 `/tmp/tui_work`（实验仓库，已删除 `.git`，未推送）
- 盘点文档：`UI-BASELINE.md`、`UI-FUNCTION-INVENTORY.md`、`UI-COMPATIBILITY.md`（Phase 0）
- 注意：原 `PHASE1-REPORT.md` 是 v1.7.0 第一阶段审查报告，已原样归档为
  `PHASE1-REPORT-v170-review.md`，本文档为 TUI 重构 Phase 1 的交付报告。

## 一、新旧架构对照

### 旧架构（v1.7.0）

```
core/ui.sh        # 248 行单文件：初始化 + 宽度计算 + 边框 + 组件 + 交互全在一起
```

- 宽度固定 58~78 列；低于 58 强制 58，窄终端会越界；无 40 列以下降级
- 全部交互是 `read -rp` 行输入，无方向键、无确认框组件、无输入/进度组件
- `ui_line` 不截断超长内容，超长域名/节点名会顶出右边框

### 新架构（Phase 1）

```
core/ui.sh                # 36 行统一入口：按顺序加载 core/ui/*.sh，末尾 ui_init
core/ui/init.sh           # 68 行  UI 初始化、环境检测、宽度模式、边框字符集
core/ui/theme.sh          # 47 行  主题变量 T_*（映射 env.sh 颜色）与状态符号
core/ui/terminal.sh       # 109 行 宽度计算、含 ANSI 安全截断、清屏
core/ui/layout.sh         # 52 行  面板/分区/排版
core/ui/components.sh     # 148 行 键值/菜单项/协议状态/菜单头/提示/横幅/节点卡
core/ui/input.sh          # 86 行  输入组件（新）
core/ui/navigation.sh     # 233 行 菜单导航 ui_menu_select（新）
core/ui/dialog.sh         # 41 行  消息框/确认框（新），含升级后的 ui_confirm
core/ui/progress.sh       # 50 行  阶段提示与 spinner（新）
core/ui/status.sh         # 23 行  状态药丸（新）
core/ui/dashboard.sh      # 30 行  仪表盘渲染辅助（新）
core/ui/compatibility.sh  # 33 行  旧接口兼容层（ui_box_* 包装 + 自检）
```

- UI 代码 248 行 → 956 行（含注释与新组件）；测试 `tests/ui_test.sh` 361 行
- 模块依赖单向：`init → theme → terminal → layout → components → input /
  navigation / dialog / progress / status / dashboard → compatibility`，无循环引用
- 加载方式：`core/ui.sh` 按 `BASH_SOURCE` 定位 `core/ui/` 目录（`APP_HOME` 兜底），
  缺模块时打印错误并返回非零；`install.sh` 是整树 `cp -a`，`core/ui/` 自动随包发布，
  无需改安装器
- `env.sh` 颜色定义、版本号（1.7.0）、全部业务文件（`sbx.sh`、`protocols/`、
  `utils/`、`core/engine.sh` 等）一律未动；与 `/tmp/v17_work` 的 diff 证实仅
  `core/ui.sh` 改动 + `core/ui/`、`tests/ui_test.sh` 新增

### 旧接口归属（30 个，签名全部不变）

| 模块 | 接口 |
|---|---|
| init.sh | `ui_init` |
| terminal.sh | `ui_strip` `ui_cw` `ui_vwidth` `ui_fit` `ui_clear` |
| layout.sh | `ui_top` `ui_mid` `ui_bot` `ui_rule` `ui_line` `ui_split` `ui_section` |
| components.sh | `ui_kv` `ui_kv2` `ui_item` `ui_proto_row` `ui_proto_status` `ui_proto_detail` `ui_menu_head` `ui_prompt_str` `ui_hint` `ui_banner` `ui_node_card` |
| dialog.sh | `ui_confirm`（TTY 下升级为带边框确认框，签名与默认 N 不变） |
| compatibility.sh | `ui_box_top` `ui_box_mid` `ui_box_bot`（薄包装转发） |

全局变量 `UI_W` / `UI_IW` / `UI_BC` 及边框字符变量 `UI_TL`/`UI_TR`/`UI_BL`/`UI_BR`/
`UI_H`/`UI_V`/`UI_ML`/`UI_MR`/`UI_ON`/`UI_OFF`/`UI_ARROW`/`UI_DIA`/`UI_ELL` 全部保留
（`sbx.sh` 的 `get_telemetry` 用到的 `UI_ON`/`UI_OFF` 不受影响）。
新增全局：`UI_MODE`（wide/normal/compact/narrow/plain）、`UI_COLS`（检测列数）、
`UI_KV_LAB` / `UI_ITEM_TITLE`（列宽规范，正常 10/16，窄屏收紧为 8/12）。

## 二、宽度模式（替代固定 58~78）

| 终端列数 | UI_W | UI_MODE | 行为 |
|---|---|---|---|
| ≥120 | 100 | wide | 宽屏面板 |
| 100~119 | 96 | wide | 宽屏面板 |
| 80~99 | 78 | normal | 与旧版一致（默认） |
| 60~79 | cols-2 | compact | 紧凑面板 |
| 40~59 | cols-2 | narrow | `ui_kv2` 退化为两行单列；`ui_item`/`ui_proto_row` 描述空间不足时省略；标签列 8、标题列 12 |
| <40 | cols | plain | 边框函数为空操作；`ui_line` 输出去色截断纯文本；`ui_item` 输出 `[key] label - desc` |

- `SBM_COLS=N` 仍可覆盖；非法值回退 80；无 `tput` 时默认 80
- 宽度计算排除 ANSI 码（沿用 `ui_strip`）
- 新增 `_ui_truncate_ansi`（terminal.sh）：含 ANSI 码文本按可视宽度安全截断，
  转义序列原样透传、超长以 `UI_ELL` 收尾；`ui_line` 以此兜底，**任何内容永不越界**
  （旧版 `ui_line` 不截断是越界根因之一）
- `ui_kv` 标签列 10、`ui_item` 标题列 16 的用户规范在正常宽度下保持不变，
  仅窄屏下按比例收紧

## 三、新增 API 说明

### 导航：`ui_menu_select`（Phase 2/3 依赖，navigation.sh）

```
ui_menu_select <prompt> <default_index> <entry...>
# entry 格式："key|label|desc"（key 如 "1/r"，desc 可空）
# 返回：0=选中，1=返回(Esc)，2=退出(q)，3=EOF/中断
# 结果：UI_SEL_IDX（0 起下标）、UI_SEL_KEY（选中项 key 字段，如 "1/r"）
```

- TTY：方向键高亮列表（反显 + `❯` 双通道），↑/↓ 移动，回车确认，Esc 返回，
  q 退出，数字/字母快捷键直接选中（匹配 key 中 `,` 或 `/` 分隔的任一快捷符，
  字母不区分大小写，与现有菜单 `1|r|R` 行为一致）；`SBM_MENU_LINE=1` 或
  `TERM=dumb` 时强制行输入模式
- 非 TTY：打印列表 + `ui_prompt_str` + 行输入；空输入选中默认项；`q` 返回 2；
  EOF 返回 3；无效输入重问
- 终端安全：`stty -g` 保存/恢复；EXIT/INT/TERM trap 兜底；退出时恢复光标与回显；
  调用方原有 trap 在退出时恢复（不吞 trap）
- 实现要点（均为沙箱实测后定案，见第五节）：
  - `read` 必须加 `-d ''`，否则 `\n` 被当行分隔符吞掉，Enter 永远读不到
  - Esc 序列用两次单字节 `read -rsn1 -t 0.05` 区分，`read -n2` 在 VMIN=1 下
    可能只返回 1 字节，不可靠
  - 信号 trap 只置标志、不碰终端——bash 的 `read -n` 会在返回时把自己保存的
    termios 写回去，覆盖 trap 里的恢复；恢复必须由主循环在 `read` 返回后做

### 确认框升级：`ui_confirm`（dialog.sh）

- 签名 `ui_confirm "提示"` 不变，返回 0 仅当 y/Y，默认 N
- TTY 下渲染带边框确认框（`ui_dialog_confirm`，含"默认取消"提示行）；
  非 TTY 退化为原有行内 `[y/N]` 提示
- 新增消息框：`ui_msg_ok` / `ui_msg_warn` / `ui_msg_err` / `ui_msg_info`
  （带边框单行消息，plain 模式退化为纯文本行）

### 输入组件（input.sh）

| 函数 | 行为 |
|---|---|
| `ui_read_text "提示" "默认值"` | 读入 `UI_INPUT`；空输入返回默认值 |
| `ui_read_secret "提示"` | 静默读入（`read -s`），`UI_INPUT` |
| `ui_read_port "提示" "默认值"` | 仅格式提示（1-65535），不做业务校验（校验仍在 `prompt_port`） |
| `ui_read_choice "提示" "选项1\|选项2\|..." "默认下标"` | 数字选择，`UI_INPUT` 为 0 起下标；TTY 下打印编号列表并重问无效输入 |

全部支持 EOF 返回非零；stdin 非 TTY 时直接读行，不渲染装饰。

### 进度 / 状态 / 仪表盘

- `ui_stage <当前> <总数> <描述>`：如 `[1/3] 正在下载内核...`
- `ui_spinner_start "提示"` / `ui_spinner_stop "[完成提示]"`：仅 TTY 且未禁用动画时
  转圈（`SBM_NO_ANIM=1` 禁用），非 TTY 降级为普通 log 行；spinner 子进程以
  `kill -0 $PPID` 自检，父进程退出后自动停止，不留孤儿
- `ui_status_pill <状态> [显示文本]`：状态药丸，如 `● RUNNING`（颜色 + 文字双通道，
  去色终端仍可读）；输出不带换行，可嵌入 `ui_kv` 等行内使用；未知状态回退为灰色
- `ui_dash_row`（与 `ui_kv2` 同签名，标签列 10）与 `ui_dash_title`（语义化分区标题）：
  供 Phase 2 主界面使用；窄屏/plain 自动退化为两行单列 `ui_kv`

### 主题（theme.sh）

`T_PRIMARY`（青）/ `T_SUCCESS`（绿）/ `T_WARNING`（黄）/ `T_DANGER`（红）/
`T_INFO`（蓝）/ `T_MUTED`（灰）/ `T_ACCENT`（紫）/ `T_TEXT`（白），映射到 env.sh
颜色变量；`T_SYM_OK`/`T_SYM_OFF`/`T_SYM_ARROW`/`T_SYM_DIA`/`T_SYM_ELL` 状态符号
随 `ui_init` 按字符集重算。业务代码可优先用 `T_*`，旧代码继续用裸颜色变量不受影响。

### 环境变量（新增）

| 变量 | 作用 |
|---|---|
| `SBM_MENU_LINE=1` | `ui_menu_select` 强制行输入模式 |
| `SBM_NO_ANIM=1` | 禁用 spinner 动画（降级为 log 行） |

原有 `NO_COLOR` / `SBM_FORCE_COLOR` / `SBM_ASCII` / `SBM_COLS` 行为全部保留
（测试覆盖）。

## 四、测试结果

测试：`tests/ui_test.sh`（`bash tests/ui_test.sh`，约 10 秒）

```
UI TEST SUMMARY: PASS=74 FAIL=0 SKIP=0
```

| 分组 | 用例 | 结果 |
|---|---|---|
| bash -n 全项目 | 1 | 通过 |
| 兼容自检（30 个旧接口）+ 主题变量 | 2 | 通过 |
| 宽度模式 120/100/80/60/40/30 渲染不越界 | 6 | 通过（每行 `ui_vwidth ≤ UI_W`） |
| SBM_COLS 非法/空值、窄屏 kv2 退化、plain 格式 | 5 | 通过 |
| 宽度计算（CJK/Emoji/ANSI/截断/空串） | 9 | 通过 |
| NO_COLOR / FORCE_COLOR / ASCII / UTF-8（全新子 shell） | 5 | 通过 |
| 旧接口回归（28 个渲染/屏幕接口 + detail + init） | 3 | 通过 |
| ui_menu_select 行降级（数字/字母/大小写/q/EOF/默认/重问） | 7 | 通过 |
| ui_confirm / ui_dialog_confirm（y/Y/n/空行/EOF） | 7 | 通过 |
| 输入组件（text/secret/port/choice，含默认值与 EOF） | 10 | 通过 |
| 新组件（stage/spinner/pill×5/dash×2/消息框） | 10 | 通过 |
| 全模块联加载（sbx.sh 的 source 顺序 + 面板渲染） | 1 | 通过 |
| PTY（script）：↓↓回车/回车/Esc/q/快捷键/Ctrl+C/反显+光标/confirm y/n | 9 | 通过，每例 stty 前后一致 |

现有套件回归（未改业务文件，仍全过）：`tests/smoke.sh` 通过、
`tests/round2_regression.sh` 13/13 通过、`tests/version_check.sh` 通过（1.7.0 未变）。

ShellCheck：沙箱无 `shellcheck` 命令，未执行；`bash -n` 全项目通过已作为替代。
真机终端（iPhone Termius / Xshell 等）的方向键与渲染效果仍需用户真机验证。

## 五、实测教训（Phase 1 过程中发现，已写入代码注释）

1. **`read -n1` 会吞 Enter**：`read` 把 `\n` 当行分隔符，`-n1` 读到 `\n` 时返回空变量
   而不是 `$'\n'`。单键读取必须加 `-d ''`（NUL 分隔）。症状：Enter 永远无效，
   循环读到 EOF 才返回 3。
2. **`read -n2` 在 VMIN=1 下不可靠**：底层 `read()` 有 1 字节就返回，`-n2` 可能只
   拿到 `[` 而丢 `B`。Esc 序列必须分两次单字节 `read -rsn1 -t 0.05`。
3. **信号 trap 里不要恢复 stty**：bash 的 `read -n` 在返回时会把自己保存的 termios
   写回去，覆盖 trap 里的恢复，终端最终残留 raw 模式（`stty -g` 前后 diff 实锤）。
   正确做法是 trap 只置标志，主循环在 `read` 返回后统一恢复。
4. **bash 的 `read -n` 会重开 ISIG**：即使 `stty -isig`，`read` 阻塞期间的 Ctrl+C
   仍以 SIGINT 到达（不是 0x03 字节）；`$'\003'` 分支只是两次 read 间隙的安全网。
5. **PTY 测试必须延迟投递按键**：`printf | script` 瞬时投递时，按键可能在菜单进入
   raw 模式前到达（规范模式下 `0x03` 成真实 SIGINT、`\n` 成行分隔），测试驱动需
   `sleep 0.6` 后投递、尾部 `sleep` 保持管道打开。
6. **沙箱 `TERM=dumb`**：`script` 子进程继承 dumb，触发 dumb 终端降级；PTY 测试
   驱动内必须 `export TERM=xterm`。
7. **C locale 会切坏 UTF-8**：`${s:i:1}` 在 C locale 下按字节切分；宽度计算依赖
   UTF-8 locale（`sbx.sh` 入口已强制 `C.UTF-8`；测试脚本同样 `export LC_ALL=C.utf8`）。

## 六、已知限制

- `ui_node_card` 的链接故意不截断（截断会破坏复制），超长链接在窄屏/plain 下
  可能越界——可复制性优先于对齐的有意取舍；`ui_hint` 单行长文本同样不截断。
- `ui_menu_select` 不可重入（使用全局 `_UI_MENU_*` 状态）；同一时刻只能有一个菜单。
- `ui_menu_select` 会临时接管调用方的 EXIT/INT/TERM trap，退出时恢复；若调用方
  在菜单运行期间依赖自己的 trap 立即生效，需注意此窗口。
- 方向键支持 `ESC [ A/B` 与 `ESC O A/B` 两种序列；`ESC` 单独按键的判定依赖 0.05 秒
  超时（终端延迟极高时，方向键首字节可能被误判为单独 Esc——实测本地终端无此问题）。
- spinner 只在 stdout 为 TTY 时转圈；输出重定向到文件时降级为 log 行。
- `ui_menu_select` 的 TTY 路径要求 `stty` 可用；无 `stty` 时自动降级行输入。
- 真机验证待做：iPhone Termius / Xshell / PuTTY 下的方向键、反显、边框对齐与
  plain/narrow 模式的实际观感；`ui_confirm` 带边框确认框在真机上的显示效果。

## 七、Phase 2 交接

- Phase 2 主界面可直接用：`ui_menu_select`（主菜单导航）、`ui_dash_row` /
  `ui_dash_title`（仪表盘区）、`ui_status_pill`（状态展示）、`ui_stage` /
  `ui_spinner_*`（耗时操作）。
- 菜单 entry 建议沿用现有 key 格式（如 `"1/r|VLESS-Reality|描述"`），快捷键行为
  与现有菜单一致（数字/字母、大小写不敏感）。
- 危险操作（彻底卸载）确认请用 `ui_dialog_confirm`，默认取消的强度已与旧版一致。
