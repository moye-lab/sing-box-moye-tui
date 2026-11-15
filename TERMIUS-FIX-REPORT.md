# Termius 方向键失效修复报告

- 日期：2026-11-15
- 分支：TUI 实验分支（`moye-lab/sing-box-moye-tui`，tag `v1.7.0-tui`）
- 版本：保持 1.7.0

## 一、问题现象

用户在 RN（Ubuntu 22.04）上通过 iPhone Termius 运行 sbx，主菜单按四个方向键后，
终端底部出现原始转义序列 `^[[D^[[A^[[B^[[C`，菜单不导航。同时底部快捷命令提示行
把 `export` 截成 `expor` / `t` 两行。

## 二、根因（已证实，不是 TUI 方向键逻辑 bug）

**用户当时运行的根本不是 TUI 代码，而是主线 v1.7.0。**

证据链：

1. 用户截图的面板与 TUI 代码不符：截图是中文仪表盘标签（节点标识/核心状态/
   网络引擎/公网地址/资源占用/自治域号）+ 两组（PROTOCOLS / OPERATIONS），无
   `NETWORK MANAGEMENT CONSOLE` 行、无页脚提示行；TUI 代码是英文标签
   （CORE STATE/VERSION/…）+ 四组（01 PROTOCOL MANAGEMENT 等）+ 页脚。
2. 截图面板与主线 `moye-lab/sing-box-moye` v1.7.0 的 `sbx.sh` 逐行一致
   （`ui_kv2 "节点标识"`、`ui_section "PROTOCOLS"`、`ui_section "OPERATIONS"`）。
3. TUI 仓库 `install.sh` 第 17 行下载地址写死主线仓库：
   `https://github.com/moye-lab/sing-box-moye/archive/refs/tags/v1.7.0.tar.gz`。
   用户用一键命令安装 TUI 时，实际下载安装的是主线代码。
4. 主线主菜单用纯 `read -rp` 读选项（`sbx.sh:163`），无任何方向键处理；规范模式
   下回显开着，方向键转义序列原样回显为 `^[[D…`——这是主线菜单的预期行为，
   不是 TUI bug。
5. 截图里看不到 `请输入选项` 提示，是已知业务 bug 的副作用：`state_manager.sh`
   的 `_state_lock` 用 `exec 200>"$lock_file" 2>/dev/null` 永久吞掉整个 shell
   的 stderr，而 `read -p` 的提示写 stderr（已记录在 UI-TEST-REPORT.md §八，
   本次未修——属业务逻辑 bug，不混入本次修复）。

## 三、修复内容

### 1. install.sh：引导地址指向 TUI 仓库（根因修复）

- 新增 `SBX_REPO="sing-box-moye-tui"`、`SBX_TAG="v1.7.0-tui"`。
- 下载 URL 改为 `.../moye-lab/${SBX_REPO}/archive/refs/tags/${SBX_TAG}.tar.gz`。
- 转交路径改为 `${_TMPD}/${SBX_REPO}-${SBX_TAG#v}/install.sh`，与 GitHub
  tarball 实际顶层目录 `sing-box-moye-tui-1.7.0-tui/` 一致（已实测验证）。
- `SBX_VERSION` 保持 `v1.7.0`，`SBM_VERSION` 保持 `1.7.0`，
  `tests/version_check.sh` 不变即通过。

### 2. TTY 判定更健壮 + 可调试（方案 1）

`core/ui/navigation.sh` 新增公共判定 `ui_tty_ready()`（`ui_menu_select` 与
`sbx.sh` 的 `_ui_menu_tty_ready` 共用）：

- 判定条件：stdin/stdout 均为 TTY 且 `stty` 可用即尝试 TTY 模式。
- `TERM=dumb`/未设置不再硬性拦截（Termius 等终端可能误报 TERM，但实际支持 ANSI；
  真 dumb 终端可用 `SBM_MENU_LINE=1` 强制行模式）。
- 新增 `SBM_DEBUG_MENU=1`：打印每项检测结果（`SBM_MENU_LINE` / `TERM` /
  `stdin_tty` / `stdout_tty` / `stty`）与最终判定。调试输出优先写 `/dev/tty`
  （state 锁吞 stderr 时仍可见），无控制终端时回落 stderr。
- `_ui_menu_select_tty` 两个返回 4 的路径（`stty -g` 为空、`stty -icanon` 失败）
  也加调试输出。

### 3. 行模式降级支持方向键（方案 2，核心兜底）

- `_ui_menu_select_line` 拆出 `_ui_menu_line_keys`：
  - stdin 为 TTY 时逐字节读（`read -rsn1 -d ''`，bash 会自行切非规范模式，
    无需 stty）：↑↓ 导航（单行选择指示 `_ui_menu_line_indicator`，<60 列用短格式）、
    回车确认、Esc 返回、q 退出、数字键 0.4 秒缓冲（两位数快捷键）、字母键立即匹配；
    `-s` 静默使转义序列不再以 `^[[A` 形式漏出。
  - stdin 非 TTY（管道/脚本）时仍用 `read -rp` 整行读，原有语义逐行保留。
- 新增 `ui_menu_read_key`：不打印列表的行模式单次按键选择，供主菜单与维护菜单
  的降级分支使用（面板已展示，不重复打印列表）。禁用数字序号定位，仅 key 匹配——
  否则主菜单输入 14 会选中序号 14 的卸载项，而旧版行模式里 14 是无效输入。
- 主菜单与维护菜单的降级分支由裸 `read -rp` 改为 `ui_menu_read_key`；
  entries 数组提升到 if/else 之前，两分支共用。

### 4. stty 失效重试（方案 3）

`ui_menu_select` 中 `_ui_menu_select_tty` 返回 4 时，先 `stty sane` 后重试一次，
仍为 4 才降级行模式。

### 5. 快捷命令提示宽度自适应

`sbx.sh` 新增 `_sbx_cli_hint()`（替代原 92 列长行直写）：

- ≥96 列：完整单行（92 列）。
- 60–95 列：分两行，第二行 `[` 与第一行 `[` 显示列对齐（均在第 16 列）。
- <60 列：短格式 `快捷命令: sbx <协议>|all|export`（32 列）。

## 四、测试结果

新增 `tests/termius_fix_test.sh`：**30/30 通过**（0 失败，0 跳过）。

| 组 | 用例 | 结果 |
|---|---|---|
| install.sh 引导 | 仓库/tag/URL 变量/无主线地址/转交路径/GitHub tarball 实测顶层目录 | 6/6 |
| ui_tty_ready | 非 TTY 返回 1、调试输出格式 | 2/2 |
| 提示宽度 | 120/80/60/40 列不越界、export 不截断、两行 `[` 对齐 | 5/5 |
| PTY（script） | TERM=dumb、TERM 未设置、行模式 ↓↓/Esc/q/字母/数字/回车、ui_menu_read_key ↓/回车/字母、stty 失效降级、SBM_DEBUG_MENU 两种判定 | 15/15 |
| 管道行为保持 | 管道 2 选中、ui_menu_read_key 输入 14 被拒绝 | 2/2 |

既有套件全过（无回归）：

| 套件 | 结果 |
|---|---|
| tests/ui_test.sh | 74/74 |
| tests/ui_twokey_test.sh | 9/9 |
| tests/round2_regression.sh | 13/13 |
| tests/warp_test.sh | 通过 |
| tests/export_test.sh | 通过 |
| tests/anytls_test.sh | 通过 |
| tests/smoke.sh | 通过 |
| tests/install_all_test.sh | 通过 |
| tests/version_check.sh | 通过 |
| bash -n 全项目 | 通过 |

## 五、用户侧验证步骤（RN 上）

```bash
bash <(wget -qO- https://raw.githubusercontent.com/moye-lab/sing-box-moye-tui/v1.7.0-tui/install.sh)
```

安装后 `sbx` 应显示 TUI 主菜单（英文仪表盘标签 + 四组导航 + 页脚提示行，
与之前截图的中文两组面板不同）。方向键应可导航；如仍有问题，执行
`SBM_DEBUG_MENU=1 sbx` 并贴出 `[menu-debug]` 行。

## 六、已知限制（本次未改）

- `state_manager.sh` 的 stderr 吞没 bug（`exec 200>... 2>/dev/null`）未修：
  `read -rp` 提示在生产中不可见，影响新旧菜单；建议另立任务修复。
- `protocols/warp.sh:433`（AI 分流模式选择）、`utils/cert.sh:75`（证书方式选择）
  等单选提示仍用裸 `read -rp`，方向键在那里仍会回显转义序列；属数据输入类提示，
  不在本次菜单导航修复范围内。
- 行模式方向键指示行在极窄终端（<40 列 plain 模式）下仍使用短格式指示，
  未做进一步压缩。
