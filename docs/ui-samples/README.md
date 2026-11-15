# UI 展示样本（TUI 重构 Phase 4 捕获）

捕获方式：`source` 实验仓库 `sbx.sh` + fixture 状态（Reality/Hy2/WARP 已装，
公网 IP `203.0.113.9` 为 TEST-NET-3 测试地址），管道输入 `q`（渲染后立即退出），
不执行任何业务操作。捕获脚本见 Phase 4  harness `/tmp/p4/samples.sh`。

- `*-ansi.txt`：`SBM_FORCE_COLOR=1` 下的原始输出（含 ANSI 颜色码，用 `cat` 查看即有颜色）。
- `*.txt`：同一份输出 strip ANSI 后的纯文本版。
- `main-80col-nocolor.txt`：`NO_COLOR=1` 下的主菜单（无 ANSI 码，单文件）。

| 文件 | 内容 |
|---|---|
| `main-80col` | 主菜单，80 列（默认 normal 模式） |
| `main-60col` | 主菜单，60 列（compact 模式） |
| `main-40col` | 主菜单，40 列（narrow 模式，仪表盘退化单列） |
| `main-120col` | 主菜单，120 列（wide 模式） |
| `reality-80col` | VLESS-Reality 子菜单，80 列 |
| `warp-80col` | WARP 与域名分流子菜单，80 列 |
| `export-80col` | 节点订阅中心子菜单，80 列 |
| `main-80col-nocolor` | 主菜单 80 列，`NO_COLOR=1` |
| `main-80col-ascii` | 主菜单 80 列，`SBM_ASCII=1`（ASCII 边框） |
