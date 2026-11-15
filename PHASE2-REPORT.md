# PHASE2-REPORT.md — TUI 重构 Phase 2：主界面升级

- 完成日期：2026-11-15
- 基线：sing-box-moye v1.7.0 + TUI Phase 1（新 UI 架构），工作目录 `/tmp/tui_work`（实验仓库，未推送）
- 注意：原 `PHASE2-REPORT.md` 是 v1.7.0 第二阶段审查报告，已原样归档为
  `PHASE2-REPORT-v170-review.md`，本文档为 TUI 重构 Phase 2 的交付报告。

## 一、改动范围

**只改了一个文件：`sbx.sh`（282 行 → 439 行）。** 版本号保持 1.7.0，未推送。
其他文件（`core/ui/*`、`protocols/*`、`utils/*` 等）一律未动——
`protocols/reality.sh`、`protocols/hysteria2.sh` 已有其他 worker 在改（已用上
`ui_menu_select`），本次刻意避开。

重构的函数（业务逻辑零改动，只改 UI 呈现与交互）：

| 函数 | 改动 |
|---|---|
| `get_telemetry()` | 扩展：新增状态字段（见第二节），现有输出变量名 `CORE_TXT`/`CORE_CLR`/`RES_TXT`/`RES_CLR`/`BBR_TXT`/`BBR_CLR` 全部保留，业务语义不变 |
| `main_menu()` | 重构为现代运维控制台主界面（品牌头 + 仪表盘 + 四组导航 + 页脚，方向键导航） |
| `menu_maintenance()` | 分组 + 摘要行 + 方向键导航 |
| `run_diagnostics()` | 结构化分组诊断 + 结果药丸 + 失败建议 |
| 新增辅助 | `_ui_menu_tty_ready`、`_sbx_proto_desc`、`_sbx_ver_text`（sbx.sh 内私有辅助） |

未改动（diff 验证）：文件头（shebang/locale/全部 source）与
`install_all_protocols()`、`sbx_main()` 及其后内容逐字节一致；
`sbx_main` CLI 分发、`install_all_protocols`、状态/config 逻辑全部 untouched。

## 二、改动说明

### 2.1 `get_telemetry()` 扩展

现有 6 个输出变量名与赋值逻辑原样保留，新增只读字段供仪表盘使用：

| 新增变量 | 取值 | 来源 |
|---|---|---|
| `CORE_STATE` | `running` / `stopped` / `not_installed` | 与原有三分支判定同一条件 |
| `CORE_VER` | 版本号或 `未安装` | `get_installed_sb_version` |
| `CORE_PID` / `CORE_MEM` | PID / `x.xMB`，未运行时为 `-` | 原有 `systemctl show` + `/proc` 读取 |
| `BBR_STATE` / `BBR_ALGO` | `bbr`/`other` + 拥塞算法名 | 原有 `sysctl` 读取 |
| `WARP_STATE` | `connected` / `disconnected` / `not_installed` / `unknown` | 见下 |
| `WARP_TXT` / `WARP_CLR` | 显示文本与颜色 | 与 `CORE_TXT` 同风格 |

**WARP 状态（只读本地检测，零网络请求）：** 调用现有 `warp_installed()`
（= `state_has_proto warp`）；已安装 + 服务运行中 + 配置中存在 `tag == "warp"`
的端点（`jq` 本地读 `$SB_CONFIG`，即 `warp_check` 第 1 层）→ `connected`；
已安装但任一条件不满足 → `disconnected`；未安装 → `not_installed`；
`warp_installed` 函数不存在时 → `unknown`（显示"未知"，不伪装正常）。
注意：这里的"已连接"是本地证据推断，真实连通性仍以 `warp_check` 五层检测
（含流量验证）为准，见第八节。

### 2.2 `main_menu()`：运维控制台主界面

渲染结构（每循环：刷新遥测 → 渲染 → 选择 → 执行 → `pause` 返回，与旧版一致）：

```
品牌头部：SING-BOX MOYE + v1.7.0 + NETWORK MANAGEMENT CONSOLE + 描述行
          + HOST <hostname> · NODE <get_node_prefix>
SYSTEM OVERVIEW 仪表盘（ui_dash_title + 5 行 ui_dash_row，双列）：
  CORE STATE 药丸 | VERSION      PROCESS | MEMORY
  PUBLIC IP       | LOCATION     ASN     | PREFIX
  NETWORK 药丸    | WARP 药丸
01 PROTOCOL MANAGEMENT：1/r～6/y 六行 ui_proto_row（已启用/未安装 + 参数摘要）
                        + 7/i 一键全装
02 NODE & SUBSCRIPTION：8/e 订阅中心、9/n 命名规则
03 NETWORK & ROUTING：  10/o 网络调优、13/w WARP 与域名分流
04 SYSTEM MANAGEMENT：  11/s 内核维护、12/d 诊断、x 彻底卸载、0/q 退出
页脚：↑↓ 选择 · Enter 确认 · Esc 返回 · Q 退出
      快捷键 1-13 · r h t a p y i e n o s d w
```

- 全部 13 项 + 卸载 + 退出都在，数字/字母快捷键不变；`ui_proto_row`/`ui_section`
  按任务书使用；原有 `ui_hint`（`sbx [...]` 快捷命令）保留在面板下方。
- **状态诚实**：核心状态三态（运行中/已停止/未安装）来自 `get_telemetry` 实际检测；
  遥测调用加 `|| true`，遥测失败不阻塞主菜单；各元数据读取均有兜底默认值。
- **公网 IP 仍走 `get_public_ip` 的 6 小时缓存**，不每次重绘请求 API；
  LOCATION（`国家·城市码`，如 `US·LAX`）与 ASN 均读状态文件缓存的元数据，
  由 `map_city_code` 转换，无新增网络请求。
- **标签适配（有意为之）**：`ui_dash_row` 标签列固定 10 列，任务书原名
  `CORE STATUS`（11 列）与 `NODE PREFIX`（11 列）会截断成 `CORE STAT…` /
  `NODE PREFI…`，故用等义短标签 `CORE STATE`（恰 10 列）与 `PREFIX`；
  其余 8 个标签与任务书一致。

**交互（TTY / 非 TTY 双路径）：**

- TTY（`_ui_menu_tty_ready`，与 `ui_menu_select` 内部判定一致：非 dumb、
  stdin/stdout 均为 TTY、`stty` 可用、`SBM_MENU_LINE` 未设置）→
  `ui_menu_select "请选择功能" 0 <15 个 entry>`：方向键高亮 + 回车确认 +
  单键快捷键直达；选择器 entry 的 desc 对协议项带**实时状态摘要**
  （`_sbx_proto_desc`：`已启用 · TCP · 443 · …` / `未安装`），与面板信息一致。
  返回 0 时取 `UI_SEL_KEY` 首段进原有 `case` 分发；Esc（1）/ q（2）/
  EOF·中断（3）在主菜单一律等同退出（`echo ""; exit 0`，与旧版 q 行为一致）。
- 非 TTY → **原有 `read -rp` 行输入**（提示串与 `case` 分发、无效输入
  `log_warn` + `sleep 1` + 重绘循环全部原样）。刻意不调用 `ui_menu_select` 的
  行输入模式：面板已完整展示全部选项与键位，再由它重打一遍 15 行列表是纯噪声；
  任务书"非 TTY 自动降级为现有 read 行为"即按此实现。

### 2.3 `menu_maintenance()`：内核服务维护

- 顶部摘要行（只读检测）：`内核版本` + `核心状态`（复用 `get_telemetry` 的
  `CORE_TXT`/`CORE_CLR`，`_sbx_ver_text` 处理"未安装"不加 `v` 前缀）。
- `ui_menu_head` + `ui_section` 分组：KERNEL（1/u 升级内核）、SERVICE（2/r 重启服务）、
  LOGS（3/l 查看实时日志），0/q 返回主菜单置于分隔线后。
- TTY 下 `ui_menu_select` 导航（Esc/q/EOF/中断均返回）；非 TTY 走原有 `read`。
- 四个选项的业务调用原样：`install_singbox_core "latest"`、
  `systemctl restart sing-box` + `status`、`journalctl -u sing-box -n 30`。

### 2.4 `run_diagnostics()`：结构化诊断

- 三组 `ui_section`：DEPENDENCIES（依赖检查）/ CONFIG（状态与配置）/ SERVICE（服务状态）。
- 每项用 `ui_status_pill` 显示结果：`● 通过` / `● 缺失` / `● 校验失败` /
  `● 运行中` / `○ 未运行` / `● 未安装`（颜色 + 文字双通道）。
- 保留全部现有检查项与返回值语义（`failures > 0` 返回 1；服务未运行、
  内核未安装仍不计入 failures，与旧版一致）；配置校验失败时原始错误输出
  仍原样打印（`head -n 12`，在面板外，与旧版一致）；汇总行保留。
- 失败项给出简短建议：缺失依赖汇总一行（`→ 建议：缺失依赖 tar，请运行
  install.sh 补齐`）、配置失败（检查 `$SB_CONFIG` 语法或用备份恢复）、
  状态文件损坏（备份 `$SB_STATE` 后删除重建）；未运行/未安装项给灰色提示行。
- 不把未执行的检测显示为通过：内核不存在时配置校验不执行，显示"内核状态 未安装"
  而非通过。

## 三、各宽度渲染示例

测试方式：source + stub 驱动（`/tmp/p2/drive.sh`，见第九节），fixture 为
运行中场景（内核 v1.12.0、Reality/Hy2/WARP 已安装），`printf 'q\n'` 管道输入。
宽度校验：逐行去 ANSI 后按 East Asian Width 计算可视宽度（`/tmp/p2/width_check.py`），
排除 `ui_hint` 长行与行输入提示（Phase 1 已知限制）及面板外 log 行。

| SBM_COLS | UI_W / 模式 | 结果 |
|---|---|---|
| 120 | 100 / wide | 0 越界行，仪表盘双列宽展开 |
| 100 | 96 / wide | 0 越界行 |
| 80 | 78 / normal | 0 越界行（默认布局） |
| 60 | 58 / compact | 0 越界行，仪表盘仍双列，描述以 … 截断 |
| 40 | 38 / narrow | 0 越界行，仪表盘退化单列 |
| 30 | 30 / plain | 0 越界行，纯文本 |

### 80 列（默认，完整主菜单）

```
╭────────────────────────────────────────────────────────────────────────────╮
│  SING-BOX MOYE                                                     v1.7.0  │
│  NETWORK MANAGEMENT CONSOLE                                                │
│  Lightweight · State-Driven · Multi-Protocol Manager                       │
│  HOST htch-runtime  NODE US-vps01                                          │
├────────────────────────────────────────────────────────────────────────────┤
│  ◆ SYSTEM OVERVIEW  系统状态仪表盘                                         │
│  CORE STATE ● 运行中                 VERSION    v1.12.0                    │
│  PROCESS    PID 32965                MEMORY     6.6MB                      │
│  PUBLIC IP  203.0.113.9              LOCATION   US·LAX                     │
│  ASN        AS64500                  PREFIX     US-vps01                   │
│  NETWORK    ● cubic                  WARP       ● 已连接                   │
├────────────────────────────────────────────────────────────────────────────┤
│  ◆ 01 PROTOCOL MANAGEMENT  协议矩阵                                        │
│  [1/r]   VLESS-Reality    ● 已启用  TCP · 443 · www.microsoft.com          │
│  [2/h]   Hysteria 2       ● 已启用  UDP · 8443 · Hop 10000-20000           │
│  [3/t]   TUIC v5          ○ 未安装                                         │
│  [4/a]   AnyTLS           ○ 未安装                                         │
│  [5/p]   Cloudflare Argo  ○ 未安装                                         │
│  [6/y]   SOCKS5           ○ 未安装                                         │
│  [7/i]   一键全装         Reality·Hy2·TUIC·AnyTLS（不含 SOCKS5·Argo）      │
├────────────────────────────────────────────────────────────────────────────┤
│  ◆ 02 NODE & SUBSCRIPTION  节点与订阅                                      │
│  [8/e]   节点订阅中心     分享链接 · 二维码 · Mihomo · Sing-box            │
│  [9/n]   节点命名规则     当前前缀: US-vps01                               │
├────────────────────────────────────────────────────────────────────────────┤
│  ◆ 03 NETWORK & ROUTING  网络与路由                                        │
│  [10/o]  系统网络调优     BBR · UDP 缓冲区 · 端口跳跃                      │
│  [13/w]  WARP 与域名分流  解锁 AI 服务 · 域名走 WARP 出口                  │
├────────────────────────────────────────────────────────────────────────────┤
│  ◆ 04 SYSTEM MANAGEMENT  系统管理                                          │
│  [11/s]  内核服务维护     升级内核 · 重启服务 · 实时日志                   │
│  [12/d]  运行环境诊断     检查依赖、状态文件与 sing-box 配置               │
│  [x]     彻底卸载清理     销毁所有配置与系统服务                           │
│  [0/q]   退出管理面板                                                      │
├────────────────────────────────────────────────────────────────────────────┤
│  ↑↓ 选择 · Enter 确认 · Esc 返回 · Q 退出                                  │
│  快捷键 1-13 · r h t a p y i e n o s d w                                   │
╰────────────────────────────────────────────────────────────────────────────╯
 快捷命令: sbx [reality|hy2|tuic|anytls|argo|socks5|warp|all|subscription|export|rename|bbr]
```

（注：非 TTY 下 `read -p` 的提示行 bash 不打印，故捕获输出无提示行；真实终端上有提示。这是 bash 行为，v1.7.0 亦然。）

### 120 列（宽屏，仪表盘区）

```
│  ◆ SYSTEM OVERVIEW  系统状态仪表盘                                                               │
│  CORE STATE ● 运行中                            VERSION    v1.12.0                               │
│  PROCESS    PID 32738                           MEMORY     6.6MB                                 │
│  PUBLIC IP  203.0.113.9                         LOCATION   US·LAX                                │
│  ASN        AS64500                             PREFIX     US-vps01                              │
│  NETWORK    ● cubic                             WARP       ● 已连接                              │
```

### 60 列（紧凑，仪表盘仍双列）

```
│  CORE STATE ● 运行中       VERSION    v1.12.0          │
│  PROCESS    PID 33074      MEMORY     6.7MB            │
│  PUBLIC IP  203.0.113.9    LOCATION   US·LAX           │
```

### 40 列（最小，仪表盘退化单列）

```
│  ◆ SYSTEM OVERVIEW  系统状态仪表盘 │
│  CORE ST… ● 运行中                 │
│  VERSION  v1.12.0                  │
│  PROCESS  PID 33183                │
│  MEMORY   6.7MB                    │
│  PUBLIC … 203.0.113.9              │
│  LOCATION US·LAX                   │
```

（窄屏标签列收紧为 8，`CORE STATE`/`PUBLIC IP` 截断为 `CORE ST…`/`PUBLIC …`，
值完整；与窄屏其他标签如 `VLESS-Reali…` 的截断行为一致，见第八节。）

### 30 列（plain 纯文本降级）

```
SING-BOX MOYE  v1.7.0
  NETWORK MANAGEMENT CONSOLE
  HOST htch-runtime  NODE US-…
  ◆ SYSTEM OVERVIEW  系统状态…
CORE STATE ● 运行中
VERSION v1.12.0
PUBLIC IP 203.0.113.9
LOCATION US·LAX
WARP ● 已连接
  ◆ 01 PROTOCOL MANAGEMENT  …
[1/r] VLESS-Reality ● 已启用 …
[3/t] TUIC v5 ○ 未安装
[0/q] 退出管理面板
```

### 仪表盘状态对照（80 列，四场景）

| 场景 | CORE STATE | VERSION | PROCESS | WARP |
|---|---|---|---|---|
| 服务运行中 | ● 运行中 | v1.12.0 | PID 32965 / 6.6MB | ● 已连接 |
| 服务已停止 | ● 已停止 | v1.12.0 | - | ● 未连接 |
| 内核未安装 | ● 未安装 | 未安装 | - | ● 未连接（状态有 WARP 但无内核，隧道不可能通） |
| WARP 未安装 | ● 运行中 | v1.12.0 | PID 33812 / 6.6MB | ○ 未安装 |

### 维护菜单与诊断（80 列）

```
╭─ 内核服务维护 ── SING-BOX MOYE › SERVICE ─╮
│  内核版本   v1.12.0                        │
│  核心状态   ● 运行中 v1.12.0               │
│  ◆ KERNEL  内核                            │
│  [1/u]   升级内核         校验现有配置，失败自动回滚
│  ◆ SERVICE  服务                           │
│  [2/r]   重启服务         systemctl restart + status
│  ◆ LOGS  日志                              │
│  [3/l]   查看实时日志     journalctl -u sing-box -n 30
│  [0/q]   返回主菜单                        │
╰────────────────────────────────────────────╯
```

```
│  ◆ DEPENDENCIES  依赖检查                  │
│  bash       ● 通过                         │
│  tar        ● 缺失                         │  ← 缺失依赖场景
│  → 建议：缺失依赖 tar，请运行 install.sh 补齐
│  ◆ CONFIG  状态与配置                      │
│  配置校验   ● 校验失败                     │  ← 配置损坏场景
FATAL: test config error at line 3: invalid outbound tag   ← 原始错误输出保留
│  → 建议：检查 /tmp/p2/fixture/config.json 语法，或用备份恢复配置
│  状态文件   ● 缺失或损坏                   │  ← 状态损坏场景
│  → 建议：备份 /tmp/p2/fixture/state-bad.json 后删除，重新运行 sbx 重建
│  ◆ SERVICE  服务状态                       │
│  服务状态   ● 运行中                       │
│  发现 1 项需要处理的问题。                 │  ← FUNC_RC=1
```

## 四、方向键与快捷键测试结果

PTY 测试（`script` 伪终端，`TERM=xterm`，延迟投递按键，`stty -g` 前后对比，
驱动 `/tmp/p2/pty_main.sh`，主菜单在子 shell 中运行以便退出后校验终端状态）：

| # | 按键序列 | 结果 |
|---|---|---|
| T1 | `q` | 退出，MAIN_RC=0，STTY_OK，仪表盘渲染正常 |
| T2 | `Esc` | 退出（Esc 等同 q），MAIN_RC=0，STTY_OK |
| T3 | `↓↓` + `q` | 退出，MAIN_RC=0，STTY_OK，输出含 `\033[7m` 反显（选中行高亮） |
| T4 | `d` → 诊断 → `Enter` → `q` | 诊断渲染 1 次（"基础诊断未发现阻断性问题"），主菜单重绘 2 次，MAIN_RC=0，STTY_OK |
| T5 | `s` → 维护菜单 → `q` → `Enter` → `q` | 维护菜单渲染，主菜单重绘 2 次，MAIN_RC=0，STTY_OK |
| T6 | `h` → Hy2 子菜单 → `q` → `Enter` → `q` | 子菜单往返正常，MAIN_RC=0，STTY_OK |
| T7 | `1` 再 `0` | `1` 立即选中 Reality 进入子菜单，sysctl 子菜单未打开——证实 TTY 下两位数快捷键无法逐键输入（见第八节） |

PTY 下选择器列表实测渲染于面板下方，协议项 desc 带实时状态：

```
 ❯ 请选择功能
 ↑↓ 移动 · 回车确认 · Esc 返回 · q 退出
 ❯ [1/r] VLESS-Reality  已启用 · TCP · 443 · www.microsoft.com   （反显）
   [2/h] Hysteria 2  已启用 · UDP · 8443 · Hop 10000-20000
```

非 TTY（管道输入）测试：

| 输入 | 结果 |
|---|---|
| `q` | 退出 0，无 stderr |
| `12` + `Enter` + `q` | 诊断运行 1 次，主菜单重绘 2 次——两位数行输入正常 |
| `13` + `q` + `Enter` + `q` | WARP 子菜单打开并返回，主菜单重绘 2 次 |
| `zz` + `q` | 打印"无效选项，请输入对应数字或快捷字母"，重绘后继续循环，退出 0 |
| 维护菜单 `q` | 渲染 + 返回，FUNC_RC=0（80/40 列均过） |

## 五、诊断失败语义测试

| 场景 | 现象 | 返回值 |
|---|---|---|
| 全部正常 | 全部 `● 通过`，"基础诊断未发现阻断性问题。" | 0 |
| 状态文件损坏（非法 JSON） | `状态文件 ● 缺失或损坏` + 重建建议，"发现 1 项需要处理的问题。" | 1 |
| 配置校验失败（fake 内核返回错误） | `配置校验 ● 校验失败` + 原始 FATAL 行保留 + 建议 | 1 |
| 缺失依赖（PATH 剔除 `tar`） | `tar ● 缺失` + "缺失依赖 tar，请运行 install.sh 补齐" | 1 |

## 六、真实入口测试

沙箱有 root 且 `systemctl` 可用，但无 sing-box 二进制、`/etc/sing-box/state.json`
为空（meta 全 null）。直接运行真实入口：

```
printf 'q\n' | SBM_COLS=80 timeout 90 bash sbx.sh   → exit 0，stderr 0 字节，0 越界行
```

实测 `ensure_node_meta` 的 GeoIP 查询经沙箱代理成功，仪表盘显示真实探测值：
`PUBLIC IP 104.29.194.187`、`LOCATION US·ATL`、`ASN 13335`、`PREFIX Cloudflare`
（厂商识别），`CORE STATE ● 未安装`、`WARP ○ 未安装`。测试后已将沙箱
`/etc/sing-box/state.json` 恢复为备份，沙箱状态无残留修改。

## 七、回归测试

```
bash -n sbx.sh                       通过
bash -n 全项目（find . -name '*.sh'） 通过
tests/ui_test.sh                     UI TEST SUMMARY: PASS=74 FAIL=0 SKIP=0
tests/smoke.sh                       通过
tests/round2_regression.sh           通过: 13, 失败: 0
tests/version_check.sh               通过（1.7.0 未变）
```

## 八、已知限制

1. **TTY 下两位数快捷键 10–13 无法逐键输入**（Phase 1 `ui_menu_select` 的
   单字符立即匹配特性，T7 实测证实：按 `1` 立即选中 Reality）。
   替代路径：字母快捷键 `o`/`s`/`d`/`w` 或方向键 + 回车；非 TTY 行输入
   不受影响（`12`/`13` 实测正常）。如需 TTY 下支持多字符数字输入，需 Phase 1
   的 `navigation.sh` 增加按键缓冲/超时聚合——超出本次 sbx.sh-only 范围，
   建议 Phase 3 评估。
2. **TTY 下主菜单面板与选择器列表同时显示**：面板是信息展示（含协议状态与参数摘要），
   下方列表是交互选择器（Phase 1 导航组件的设计形态）。合计约 47 行，
   24 行高的矮终端上方面板会滚出视野；选择器 desc 带实时状态可部分弥补。
3. **40 列窄屏两个仪表盘标签截断**：`CORE STATE` → `CORE ST…`、
   `PUBLIC IP` → `PUBLIC …`（标签列收紧为 8，值完整）。与窄屏其他标签
   （如 `VLESS-Reali…`、`systemc…`）的截断行为一致，属窄屏降级设计。
4. **`ui_hint` 长行不截断**（Phase 1 已知限制）：面板下方"快捷命令: sbx […]"
   约 90 列，在窄屏/plain 下超出面板宽度；宽度校验时按 Phase 1 口径排除。
5. **WARP「已连接」是本地证据推断**（已安装 + 服务运行 + 端点在配置中），
   不是流量验证；隧道实际不通时（如握手失败）仪表盘仍显示已连接。
   权威检测仍是 WARP 菜单的 `warp_check`（五层，含流量验证）。
6. **真机验证待做**：iPhone Termius / Xshell 下的方向键、反显、边框对齐
   与各宽度实际观感仍需用户真机验证（沙箱只有 `script` PTY）。
7. `menu_hysteria2` / `menu_reality` 等子菜单已由其他 worker 改为
   `ui_menu_select` 模式（面板仅留头部，选项由选择器渲染）；本次维护菜单
   采用"面板内分组 + 选择器"模式，两者形态略有差异，属各任务书的要求不同，
   后续如需统一由 Phase 3 协调。

## 九、测试证据与复现

测试脚手架在 `/tmp/p2/`（未进实验仓库，保持仓库干净）：

- `fixture/`：临时 state.json（meta 完整、Reality/Hy2/WARP 已装）、config.json
  （含 warp 端点）、fake `sing-box`（`version` → 1.12.0，`check` 成功/失败两个版本）、
  `state-nowarp.json`、`state-bad.json`
- `drive.sh`：source sbx.sh + 指向 fixture + 按 `SCENARIO` stub `systemctl`
  （running/stopped/notinstalled/nowarp/badstate/badconfig），执行指定函数
- `pty_main.sh`：PTY 驱动（主菜单在子 shell 中跑，校验 `stty -g` 前后一致）
- `width_check.py`：逐行可视宽度校验（去 ANSI + East Asian Width）
- `out/`：全部捕获输出（`menu-{120,100,80,60,40,30}.txt`、
  `menu-{stopped,notinstalled,nowarp}.txt`、`maint-*.txt`、`diag-*.txt`、
  `pty-*.txt`、`direct-80.txt`）

复现示例：

```bash
printf 'q\n' | SCENARIO=running FUNC=main_menu SBM_COLS=80 bash /tmp/p2/drive.sh
python3 /tmp/p2/width_check.py /tmp/p2/out/menu-80.txt 78
SCENARIO=running FUNC=run_diagnostics SBM_COLS=80 bash /tmp/p2/drive.sh < /dev/null
```

沙箱原始 `sbx.sh` 备份：`/tmp/sbx.sh.v170-orig`；沙箱 `/etc/sing-box/state.json`
备份：`/tmp/sbx-state-backup.json`（已恢复原状）。
