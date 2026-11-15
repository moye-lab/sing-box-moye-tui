# 子菜单方向键失效修复报告

日期：2026-11-15
分支：sing-box-moye-tui（TUI 实验分支，版本保持 1.7.0）
触发：用户 2026-11-15 21:25–21:27 真机实测（RN + Termius）

## 一、用户报告

> "现在好像出问题了不可以方向键选择直接输入，也不会自动进入，
> 还要回车输入q回车卡住再次回车才能回到主页"

两张截图：

- 21:25（VLESS-Reality 子菜单）：列表已画出，`› 请选择` + 高亮在 `[0/q]`，
  下方回显 `^[[A^[[A`——方向键未导航。
- 21:27（节点订阅中心 EXPORT）：选项在边框面板内，无 `› 请选择` 头、无高亮，
  下方回显裸 `q`。

## 二、调查结论：两张截图是两个不同的安装 + 两个不同的根因

### 2.1 截图 21:27（EXPORT）是主线，不是 TUI bug

逐行对照代码确认：主线 `utils/export.sh` 的 `show_export_menu` 用 `ui_item`
把选项画在面板内、再用 `read -rp` 读整行，与截图逐行一致；TUI 的 EXPORT
菜单是 `ui_menu_select`（面板外列表 + `› 请选择` + 高亮），与截图不符。
结论：用户在 21:25–21:27 之间把 RN 切到了主线（或混合安装），EXPORT 的
"无方向键、需回车"是主线预期行为。

但其中"卡住需再按回车"是真实 bug：子菜单返回后主菜单调 `pause()`
（`core/env.sh`：`read -rp " 按回车返回菜单..."`），其提示走 stderr，
而 stderr 被状态锁永久吞没（见 §2.3），用户看不到提示，误以为卡死。

### 2.2 截图 21:25（Reality）是真实的 TUI 问题，但沙箱无法复现

该截图确为 TUI 列表模式（`› 请选择` + 高亮均由 `_ui_menu_select_tty` 画出），
`^[[A` 回显说明按键到达时终端处于规范模式 + 回显开启。

已排除的假设（均有实测证据）：

- 子 shell EXIT trap：实测 `$(...)` 不执行父 shell 的 EXIT trap；且读循环
  路径上无命令替换（`ui_fit`/`ui_strip`/`ui_vwidth` 均为纯 bash）。
- stdin 重定向：全仓库 grep 无 `exec <` / `<&0` / `</dev/null`（stdin 方向）。
- 状态函数吃 stdin：`state_get_field` 等均用 jq 文件参数，不读 stdin。
- 子菜单调用上下文：`menu_reality` 由主菜单 `case` 直接调用，无子 shell/管道。
- 按键时机：忠实复现（真实 `main_menu` → `menu_reality`，PTY 下提前 0.15s
  按键）仍正常导航、无回显。
- `SBM_MENU_LINE`：未设置（否则无 `› 请选择`/高亮）。

沙箱（bash 5.2.21）三轮忠实复现全部通过，故障依赖 RN 环境（bash 5.1.16 /
Termius PTY）。机制上最可疑的是 bash `read -n` 的 termios 保存/恢复行为：
实测 bash 5.2 的 `read -n` 在读取期间设非规范模式、返回后恢复调用前状态；
若 bash 5.1 在此处的实现有差异，读与读之间会出现规范+回显窗口，按键落入
窗口即回显 `^[[A` 且滞留行缓冲（无换行不交付），表现为"方向键失效"。
无法在沙箱拿到 bash 5.1 验证，故修复走防御纵深：彻底消除对 bash `read`
termios 行为的依赖（见 §三）。

### 2.3 根因二（已证实）：`state_manager.sh` 永久吞掉整个 shell 的 stderr

`core/state_manager.sh:26`：

```bash
exec 200>"$lock_file" 2>/dev/null || return 1
```

`exec` 无命令时重定向作用于当前 shell：`2>/dev/null` 把整个 shell 的
stderr 永久指向 /dev/null（同文件 :31、:46 两处 `exec 200>&- 2>/dev/null`
同理）。后果：所有 `read -rp` 提示（pause、确认框、端口/SNI 输入提示）与
`log_warn`/`log_err` 在生产中不可见。此 bug 在 `UI-TEST-REPORT.md` §八已
记录为"已知未修"，本次调查确认它是用户"卡住"症状的直接根因。

## 三、修复

### 修复 1：菜单逐字节读改用 dd（`core/ui/navigation.sh`）

新增 `_ui_menu_read_byte` / `_ui_menu_read_byte_timed`：

- `dd bs=1 count=1` 只做一次 `read()` 系统调用，绝不改 termios；配合
  `_ui_menu_tty_enter` 事先用 stty 设好的 raw 模式（`-icanon -echo -isig`），
  终端在整个菜单期间保持 raw，逐字节读不再受 bash 版本差异影响。
- 输出经 `od -An -tx1` 转十六进制再 `printf -v` 还原为字符，确保 LF
  （Enter）等字节不被命令替换剥掉；EOF/错误返回 1。
- 超时读用 termios 的 VMIN=0 + VTIME（0.05s→VTIME=1 即 0.1s，
  仅用于 Esc 转义序列后续字节的等待），不用 `timeout` 命令——实测 GNU
  `timeout` 会把子进程放入新的后台进程组，dd 读终端时收 SIGTTIN 被挂起，
  `timeout 2 dd` 仍读不到已在队列中的字节。（另注意：VMIN=1 + VTIME>0 时
  VTIME 计时从首字节到达后开始，对"无输入超时"无效；必须用 VMIN=0。）
- `_ui_menu_tty_enter` 从 `_ui_menu_select_tty` 抽出为共享函数，供
  `_ui_menu_select_tty` 与 `_ui_menu_line_keys` 共用；`_ui_menu_line_keys`
  的 TTY 分支此前依赖 bash `read -n` 自行切模式，现改为先进入 raw 再 dd 读，
  全部退出路径调 `_ui_menu_cleanup` 恢复终端。
- stty 完全失效时的兜底：`_ui_menu_line_keys` 在 `_ui_menu_tty_enter` 失败
  后回落 bash `read -n`（`_UI_MENU_READ_MODE=read`），方向键仍可导航——
  保留 termius 测试的 nostty 用例行为（stty 被 mock 掉时 ↓ 回车仍选中）。
- Ctrl+C 语义变化：dd 不重开 ISIG（bash `read -n` 会），键盘 Ctrl+C 因
  `-isig` 以 0x03 字节入队，由主循环 `$'\003'` 分支处理；INT/TERM trap
  只作外部信号兜底（仍只置标志，不碰终端）。

### 修复 2：stderr 吞没（`core/state_manager.sh`，3 行）

去掉三处 `exec` 行的 `2>/dev/null`：

```bash
exec 200>"$lock_file" || return 1          # :26
exec 200>&- || true                         # :31（锁超时清理）
exec 200>&- || true                         # :46（_state_unlock）
```

`flock`/`mkdir`/`chmod` 等外部命令的 `2>/dev/null` 不动（只作用于该进程，
不影响 shell）。修复后 `pause` 提示、`log_warn`/`log_err`、确认框文案全部可见。

### 修复 3：数字键回车确认、字母键立即执行（`core/ui/navigation.sh`）

用户 2026-11-15 21:57 补充明确要求：字母键（r/h/t/a/p/y/w/q 等）按下去
立即执行，不需要回车；数字键（1/2/10/13 等）必须按回车确认才执行。
原因：如果数字也直接进入，输入两位数（如 10、13）时会误入一位数选项
（输入 "1" 立即进入第 1 项，无法输入 "10"）。这是原有 `read -rp` 行模式
的行为，也是旧 0.4 秒数字缓冲的设计初衷。

实现（`_ui_menu_select_tty` 与 `_ui_menu_line_keys` 的 TTY 分支，同一规则）：

- 旧的 `_pending`/`_key2` 与 0.4 秒数字缓冲逻辑删除，改为数字缓存
  `_digit_buf`：数字键只追加缓存并回显，不执行、不重画；退格
  （`$'\177'`/`$'\010'`）删最后一位并重显缓存。
- 回车时：缓存非空 → `_ui_menu_key_match` 匹配，命中即执行；无匹配则在
  回显行打印 `无效选项：<缓存>，请重新输入`（不换行）、清空缓存、留在菜单；
  缓存为空 → 执行当前高亮项（原有语义不变）。
- 其余按键（方向键、Esc、Ctrl+C/D、q/Q、字母键）先清回显行 + 丢弃缓存，
  再按原有语义处理——数字后跟字母/q 时数字不生效。
- 回显行清理顺序是关键：列表模式下回显行位于列表下方，清行后
  `\033[nA` 上移量不变；面板模式下清行后 `ui_panel_redraw` 上移
  `_UI_PANEL_TOTAL` 行仍对齐（面板模式实测：按 `1` 后 ↓ 清掉回显、高亮
  正确移到 `[2/h]`、回车进入 Hy2 子菜单，无残留数字行、无 `^[[` 回显）。
- `_ui_menu_read_byte_timed` 的 `0.4) vtime=4` 分支已无调用者，随之删除；
  文件头"数字键带 0.4 秒缓冲"注释同步改写。

### 未动的部分

- 主菜单面板模式逻辑未动（只换了底层读字节实现 + 数字键规则）；子菜单
  调用点、entries、默认选中项、Esc/q/Enter 语义全部不变。
- 主线（mainline）未动：EXPORT 主线的"无方向键"是设计如此；stderr 修复
  与 dd 读字节如需同步主线，另行任务处理。

## 四、测试

### 新增 `tests/submenu_nav_test.sh`（23 项，全过）

| 组 | 内容 | 结果 |
|---|---|---|
| A（7 项）| 真实 `main_menu` → `menu_reality`，PTY：Enter 进入子菜单、↑ 高亮到 [3/x]、↓ 回到 [0/q]、无 `^[[` 回显、pause 提示可见、回到主菜单、q 干净退出 rc=0 | 7/7 |
| B（3 项）| 子菜单字母直输：q 无回车立即返回；m 无回车立即进修改流程（端口提示出现）；q 取消后 stderr 提示可见 | 3/3 |
| C（4 项）| EXPORT 子菜单：主菜单 e 无回车直达、↓ 高亮到 [2/r]、无 `^[[` 回显、q 无回车返回 | 4/4 |
| D（3 项）| stderr 可见性（非 PTY）：状态锁操作后 stderr 可见、fd 2 未指向 /dev/null（根因级）、多次 lock/unlock 后仍可见 | 3/3 |
| E（4 项）| `_ui_menu_read_byte` 单元（PTY）：方向键三字节 1b/5b/41、超时读无输入返回 1（116ms）、LF 读为 0a、q 读为 71 | 4/4 |
| F（2 项）| 子菜单数字键回车确认：Reality 子菜单按 2 + 回车进入修改流程；按 2 不回车停顿 1.0 秒不执行、再按 q 返回主菜单 | 2/2 |

### `tests/ui_twokey_test.sh` 按新规则重写（12 项，全过）

旧版测试的是已废弃的 0.4 秒缓冲行为（快按两位选中、单按停顿后按首位匹配、
无匹配回落首位），新版按"字母立即、数字需回车"重写：12/13/10/11 + 回车
选中两位数项、1/2 + 回车选中一位数项、19 + 回车显示无效提示后可继续输入、
字母 d 立即选中 12/d、12 不回车停顿 1.0 秒不执行（q 退出 RC=2）、9 后跟 q
时缓存丢弃（q 退出 RC=2）、9 后跟 d 时缓存丢弃（d 立即选中 12/d）、19 退格
改 12 回车选中 12/d。

### 现有套件（全过）

| 套件 | 结果 |
|---|---|
| `tests/ui_test.sh` | 74/74 |
| `tests/round2_regression.sh` | 15/15 |
| `tests/termius_fix_test.sh` | 30/30（含 stty 失效降级用例——初版 dd 改造曾使该用例失败，因 `_ui_menu_line_keys` 的 TTY 分支新增了 stty 依赖；补 `read` 模式兜底后恢复；其中 `$'2\n'` 用例覆盖行输入降级路径的数字回车确认） |
| `tests/panel_nav_test.sh` | 39/39 |
| `tests/warp_sbx_owner_fix_test.sh` | 15/15（PASS 计数；任务书称 18 项为含真实 sing-box 条件断言的总数，沙箱无真实二进制时 2 项跳过） |
| `tests/warp_healthcheck_fix_test.sh` | 34/34（同上，36 项为含条件断言的总数） |
| `tests/warp_verify_persist_test.sh` | 48/48 |
| `tests/warp_temp_cleanup_test.sh` | 53/53 |

全部修改的 Shell 文件通过 `bash -n`。

### 修复过程中的两次实测教训（已写入代码注释）

1. `timeout <秒> dd` 读终端永远失败（SIGTTIN）：`timeout` 把子进程放入
   新的后台进程组，dd 读控制终端被内核挂起。超时读必须用 VMIN=0 + VTIME。
2. VMIN=1 + VTIME>0 时 VTIME 计时从首字节到达后开始，"无输入超时"无效；
   必须用 VMIN=0 + VTIME。

## 五、遗留与建议

1. **真机验证待用户做**：沙箱无法复现原故障（bash 5.2），dd 改造的最终
   验证需用户在 RN 上重装 TUI 后实测子菜单方向键。建议验证点：Reality
   子菜单 ↑↓ 导航无 `^[[A` 回显；q/m 直输无需回车；pause 提示可见；
   数字键规则——主菜单输 `12` + 回车进诊断、输 `1` 不回车不执行、字母
   d 无需回车进诊断、输 `19` + 回车显示无效提示后可继续输入。
2. **主线同步建议**：stderr 吞没 bug 主线同样存在（`core/state_manager.sh`
   同源），主线用户同样会遇到 pause 提示不可见；dd 读字节改造主线无
   方向键菜单用不上，但 stderr 修复值得同步（另行任务）。
3. **已知未修（既有）**：`warp_set_domains` 等混合函数泄漏状态锁
   （见 `WARP-TEMP-CLEANUP-FIX-REPORT.md` §六）；"Ctrl+C 后 WARP 显示未安装"
   未定位（同报告 §七）。本次未动。
4. **计数口径说明**：warp 两个套件的 PASS 数（15/34）小于任务书数字
   （18/36），差额为依赖真实 sing-box 二进制的条件断言（沙箱无二进制时
   跳过），FAIL 均为 0，非回归。

## 六、改动文件

- `core/ui/navigation.sh`：新增 `_ui_menu_read_byte`、`_ui_menu_read_byte_timed`、
  `_ui_menu_tty_enter`、`_UI_MENU_BYTE`、`_UI_MENU_READ_MODE`；`_ui_menu_select_tty`
  与 `_ui_menu_line_keys` 改用 dd 读字节；`_ui_menu_on_signal` 注释更新；
  数字键改回车确认、字母键立即执行（删除旧 0.4 秒缓冲 `_pending`/`_key2`，
  `_ui_menu_read_byte_timed` 删除 `0.4) vtime=4` 分支，文件头注释同步）。
- `core/state_manager.sh`：三处 `exec` 去掉 `2>/dev/null`。
- `tests/submenu_nav_test.sh`：新增（23 项，含 F 组数字键回车确认 2 项）。
- `tests/ui_twokey_test.sh`：按新规则重写（12 项；旧版测 0.4 秒缓冲，已废弃）。
- `CHANGELOG.md`：新增条目。
- `SUBMENU-NAV-FIX-REPORT.md`：本报告。
