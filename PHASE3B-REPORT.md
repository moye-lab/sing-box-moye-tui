# PHASE3B-REPORT.md — TUI 重构 Phase 3b：订阅中心、命名中心、WARP 页面重构

- 完成日期：2026-11-15
- 基线：sing-box-moye v1.7.0（TUI Phase 1 已完成），工作目录 `/tmp/tui_work`（实验仓库，未推送）
- 修改文件（仅 3 个，其他文件未碰）：`utils/export.sh`、`utils/subscription.sh`、`protocols/warp.sh`
- 版本号未动：`SBM_VERSION="1.7.0"`（`core/env.sh:21`，`tests/version_check.sh` 通过）

## 一、改动总览

四个菜单全部从 `read -rp` + `case` 改为 `ui_menu_select` 导航（TTY 下方向键高亮 +
快捷键，非 TTY 降级行输入），页面结构统一为：标题（`ui_menu_head`）→ 状态摘要区 →
操作列表 → `ui_menu_select`。业务函数（导出、命名、订阅启停、WARP 安装/卸载/健康
检查）一律未动；只改菜单渲染与交互。

### 结构性决策（与任务书字面表述的取舍，需评审确认）

任务书说“操作列表（ui_item，…）→ 用 ui_menu_select 导航”。实际落地时，操作列表
由 `ui_menu_select` 自身渲染（TTY 下为可高亮交互列表，非 TTY 下打印列表 + 行提示），
面板内不再重复画一遍 `ui_item` 行——否则同一列表会在两种模式下都出现两次（面板内
静态一份 + 导航组件一份），是明确的重复渲染。`ui_menu_select` 的 entry 与原 `ui_item`
行保持完全一致的 key / 名称 / 说明（见第二节对照表），选项与快捷键无任何增减。
面板内只保留标题 + 状态摘要区。

### 通用行为

- Esc / q / EOF 一律 `return 0`（与旧版按 q 返回 0 一致；旧版 WARP 菜单在 EOF 下会
  无限循环报“无效选项”，新版直接返回，不挂死）。
- 危险确认默认取消：`ui_confirm` / `ui_dialog_confirm` 仅 y/Y 确认。
- 不引入新依赖，不用 Emoji 做布局。

## 二、页面改动说明

### 任务 1：节点订阅中心（`utils/export.sh`：`show_export_menu`）

- 新增只读统计助手 `_export_node_stats` / `_export_proto_pill`（不写状态）：
  - `可导出节点`：Reality/Hy2/TUIC/AnyTLS 各计 1，Argo 按 `cf_ip` 逗号切分计实际
    地址数；**SOCKS5 不计入节点数**（仅参数，不参与导出）。
  - `已安装协议`：如 `Reality · Hy2 · Argo×2`；无协议时显示 `未安装任何协议`。
  - 三行 `ui_kv2` 协议状态药丸：Reality/Hy2、TUIC/AnyTLS、Argo（`N 个节点`或
    `地址缺失`）/SOCKS5（`已安装 · 仅参数`）。
  - 面板底部一行说明：`SOCKS5 仅提供手动配置参数，不参与节点导出`。
- 导航：`ui_menu_select`，7 个 entry 与原 `ui_item` 一致（见对照表）。
- 分发逻辑与旧版逐行一致：`1/v` 直接 `export_all_nodes`；`5/u` 进订阅服务菜单；
  `6/p` 展示 SOCKS5 参数；`2/r/3/c/4/s` 先静默 `export_all_nodes` 再展示。
- 二维码分支原样保留：`qrencode` 缺失时 `log_warn` 并返回，文字链接仍在
  `links.txt`（本轮沙箱无 qrencode，实测走的就是该分支，见测试 D）。
- `export_all_nodes` / `ui_node_card` / 各格式导出一律未动：链接仍不入框、不断行，
  便于整行复制；SOCKS5 仍只走 `show_socks5_params` 手动参数展示，未加入任何导出
  （测试 C 断言三份导出文件均不含 socks5）。

### 任务 2：节点命名中心（`utils/export.sh`：`menu_node_naming`）

- 状态摘要区新增自动探测结果（只读 `jq` 取 `.meta.*`，口径与 `ensure_node_meta` 一致）：
  `当前前缀` / `命名来源`（自动探测 / 自定义前缀）/ `厂商探测` / `国家代码` /
  `主机名`（`hostname -s`，同款清洗截断）/ `自动前缀`（厂商优先，否则 `国家-主机名`）
  / `客户端预览`；原有格式说明与示例两行保留。
- 导航：`ui_menu_select`，5 个 entry 与原 `ui_item` 一致。
- 自定义前缀输入改用 `ui_read_text`（无默认值，空输入跳过）；校验仍在
  `set_custom_node_prefix`（非空 / ≤64 字符 / 无控制字符），未动。
- 选项 1 与选项 2 在旧版中本就是同一行为（`reset_node_naming && export_all_nodes`），
  本轮原样保留，未做“修正”。
- 命名规则与持久化行为未动：`reset_node_naming` / `set_custom_node_prefix` /
  `ensure_node_meta` 均未修改。

### 任务 3：在线订阅服务（`utils/subscription.sh`：`menu_subscription_service`）

- 状态摘要区（只读）：`服务状态`（运行中 / 已停止 / 未配置，`systemctl is-active`
  探测）、`监听地址`、`端口`、`访问令牌`（只显示“已配置/未配置”，**不打印令牌值**）；
  监听为 `127.0.0.1` / `::1` 时附一行原有防呆提示。
- 导航：`ui_menu_select`，4 个 entry 与原 `ui_item` 一致。
- `subscription_enable` 内两处输入改用 `ui_read_text`（任务书明确许可的唯一业务函数
  内改动）：
  - 监听地址提示保留防呆文案“公网访问请显式填写 0.0.0.0”，默认值仍为已存值或
    `127.0.0.1`；端口默认值仍为已存值或 `8765`。
  - EOF / 空输入 / 无尾换行等边界语义与旧 `read` 完全一致：`ui_read_text … || true`
    后用 `${UI_INPUT:-<默认值>}` 回落（测试 S 覆盖 stdin 立即 EOF 仍走默认启用）。
  - 后续端口格式校验与监听地址 `ipaddress` 校验未动（测试 T 覆盖非法端口拒绝）。
- `subscription_enable` / `subscription_disable` / `subscription_status` 其余逻辑未动；
  选项 2 仍打印完整含令牌订阅地址（原有行为，测试 P 覆盖）。

### 任务 4：WARP 与域名分流（`protocols/warp.sh`：`menu_warp`，重点）

- 新增只读状态探针 `_warp_menu_status`（写 `WARP_M_*` 全局变量，不做网络请求、不写状态）：
  - `WARP 状态`：已安装 · IPv4 / 未安装。
  - `WARP 出站`：配置中存在 warp 端点（与 `warp_check` 第 1 层同口径）→ 已配置 / 配置缺失。
  - `sing-box`：服务运行状态（仅代表服务本身）。
  - `分流规则`：配置中 warp 路由规则条数（`warp_check` 第 4 层同口径）。
  - `出口验证`：**菜单渲染不做实时流量测试**，始终标注 `未验证`（提示选 `[1/c]` 检测）
    或 `无法验证`（原因：未安装 SOCKS5 / 分流列表为空，与 `warp_check` 第 5 层的
    UNKNOWN 分支同口径）。面板底部另有一行：`服务运行中不等于出口正常，出口状态以
    [1/c] 实时检测为准`。
  - `分流模式`：当前域名集合与两档预设逐项比对 → 精简模式（28 个 AI 域名）/
    兼容模式（33 个域名）/ 自定义 / 未配置。
  - `AI 预设`：精简预设 28 个域名中的覆盖数 → 已应用（28/28）/ 部分应用（N/28）/ 未应用。
  - `分流域名`：数量 + 前 3 项摘要（如 `28 个：ai.google.dev, aistudio.google.com, …`），
    完整列表仍走选项 5 `warp_show_domains`。
- 导航：`ui_menu_select`；已安装时 8 个 entry，未安装时 2 个 entry（`1/i` 安装 + 返回），
  与旧版条件选项一致。循环 + `pause` 结构保留。
- 域名增删输入改用 `ui_read_text`；校验仍在 `warp_add_domains`（`valid_domain_name`），未动。
- 卸载确认改用 `ui_dialog_confirm`，文案“确定卸载 WARP？将删除 WARP 配置与全部 WARP
  分流规则。”，默认取消；清空规则仍用原 `ui_confirm`。
- `install_warp` / `uninstall_warp` / `warp_check` / `warp_add/remove/clear_domains` /
  `warp_apply_ai_preset` / `warp_show_domains` 一律未动。

#### 关于“调用 warp_check 分层检查结果”的取舍（需评审确认）

任务书要求状态区分已安装 / 已连接 / 隧道正常 / 出口已验证 / 未验证 / 检测失败，并注明
“调用现有 warp_check 分层检查结果，只读展示”。`warp_check` 是交互式命令：它会打印
15 行左右的分层输出，且第 5 层是经 SOCKS5 的实时 `curl`（超时 10 秒）。每次菜单渲染
都调用它会让菜单每次重绘都卡顿数秒（隧道故障时 10 秒），且输出会冲散面板。因此本轮
采用等价做法：菜单头只用 `warp_check` 第 1/3/4 层的同口径廉价只读探针（jq 查端点、
`systemctl is-active`、jq 计数规则），出口验证恒标注“未验证/无法验证”并指向 `[1/c]`；
真正的分层检测（含实时流量验证）仍保留在选项 1 `warp_check` 中，行为未动。菜单永远
不会在未经实时测试的情况下宣称“出口正常”，满足“服务运行中 ≠ 出口正常”的硬要求。

## 三、快捷键对照表

`ui_menu_select` 的字母快捷键不区分大小写；数字按 key 匹配，另有按位置的数字回落
（组件既有行为）。Esc 返回，q 退出，空输入选中默认项（第 1 项）。

### 节点订阅中心（`show_export_menu`）

| 快捷键 | 选项 | 行为（未变） |
|---|---|---|
| 1 / v | 分享链接 | `export_all_nodes`，打印节点卡片 |
| 2 / r | 二维码 | 静默导出后 `qrencode` 逐条扫码；缺 `qrencode` 时警告，文字链接在 `links.txt` |
| 3 / c | Mihomo 配置 | 静默导出后打印 `mihomo_proxies.yaml` |
| 4 / s | Sing-box 出站 | 静默导出后打印 `singbox_outbounds.json` |
| 5 / u | 在线订阅服务 | 进入 `menu_subscription_service` |
| 6 / p | SOCKS5 代理参数 | `show_socks5_params`（仅手动参数，不导出） |
| 0 / q | 返回主菜单 | 返回 |

### 节点命名中心（`menu_node_naming`）

| 快捷键 | 选项 | 行为（未变） |
|---|---|---|
| 1 | 自动命名（推荐） | `reset_node_naming && export_all_nodes` |
| 2 | 重置为自动命名 | `reset_node_naming && export_all_nodes`（与 1 相同，旧版即如此） |
| 3 | 手动设置节点前缀 | `ui_read_text` 输入 → `set_custom_node_prefix && export_all_nodes` |
| 4 | 重新探测国家信息 | `reset_node_naming && ensure_node_meta true && export_all_nodes` |
| 0 / q | 返回上级菜单 | 返回 |

### 在线订阅服务（`menu_subscription_service`）

| 快捷键 | 选项 | 行为（未变） |
|---|---|---|
| 1 | 启用 / 更新 | `subscription_enable`（监听地址/端口改走 `ui_read_text`，默认值与校验未变） |
| 2 | 查看订阅地址 | `subscription_status`（打印完整含令牌地址） |
| 3 | 停止服务 | `subscription_disable`（撤销令牌） |
| 0 / q | 返回 | 返回 |

### WARP 与域名分流（`menu_warp`，循环菜单）

| 快捷键 | 选项 | 出现条件 | 行为（未变） |
|---|---|---|---|
| 1 / i | 安装 WARP | 未安装时 | `install_warp` |
| 1 / c | 检测 WARP 出口 | 已安装时 | `warp_check`（五层检测） |
| 2 / a | AI 解锁分流 | 已安装时 | `warp_apply_ai_preset`（精简/兼容选择） |
| 3 / n | 添加分流域名 | 已安装时 | `ui_read_text` 输入 → `warp_add_domains` |
| 4 / r | 删除分流域名 | 已安装时 | `ui_read_text` 输入 → `warp_remove_domains` |
| 5 / l | 查看分流列表 | 已安装时 | `warp_show_domains` |
| 6 / d | 清空分流规则 | 已安装时 | `ui_confirm` 后 `warp_clear_domains` |
| 7 / x | 卸载 WARP | 已安装时 | `ui_dialog_confirm`（默认取消）后 `uninstall_warp` |
| 0 / q | 返回主菜单 | 始终 | 返回 |

注：旧版 `1|i|I|c|C` 是同一分支（按是否安装分流到安装/检测）；新版按安装状态只展示
对应的 entry（`1/i` 或 `1/c`），未展示的字母键不再响应——菜单上看不到的键本就不该
有行为，无用户可见回归。

## 四、测试方法与结果

### 4.1 渲染测试（source + stub，管道输入）

一次性脚本 `/tmp/phase3b_render.sh`（不进仓库）：按 `sbx.sh` 顺序 source 全部模块，
临时目录隔离 `SB_ETC/SB_STATE/SB_CONFIG/SB_EXPORT_DIR`；桩：`systemctl`（`restart/
reload/enable` 后 `is-active` 为真，与 `tests/warp_test.sh` 同款）、`get_public_ip`
（固定 `203.0.113.10`）、`curl`（固定返回 Oracle ASN 的 ipwho.is JSON，使命名重探测
确定且不走真实网络）、`sleep`（空操作加速）、`SUB_UNIT` 重定向到临时目录（绝不碰
`/etc/systemd`）。每个菜单用文件重定向 stdin 喂入按键序列，断言输出内容、返回码与
状态文件变化，并检查输出无 `command not found / unbound variable / syntax error`。

结果：**37/37 通过**（`PHASE3B RENDER: PASS=37 FAIL=0`，约 20 秒）。覆盖：

- 四个菜单满状态 / 空状态渲染 + `q` / `0` 退出无报错（A、B、I、J、M、N、O、U、V、W、X）；
- 订阅中心全部 6 个选项：导出 6 条链接且 SOCKS5 不入导出文件（C）、无 qrencode 警告
  分支（D）、Mihomo/Sing-box 输出（E、F）、SOCKS5 参数（G）、进入订阅菜单（H）；
- 命名中心：自定义前缀持久化（K）、空输入跳过（K2）、重置为自动命名（L）；
- 订阅服务：运行中/已停止/未配置三态、令牌只显状态不显值（N）、选项 2 完整地址（P）、
  启用默认 `127.0.0.1:8765`（Q）、显式 `0.0.0.0:9999`（R）、stdin EOF 走默认（S）、
  非法端口拒绝（T）；
- WARP：未验证/无法验证标注（V、W）、精简预设识别与摘要（X）、查看列表（Y）、增删域
  名与无效域名拒绝（Z、AA、AB）、清空确认 n/y（AC、AD）、卸载确认 n/y（AE、AF）、
  选项 1 分层检测输出（AG）、stdin EOF 不挂死（AH）；
- 窄屏 40 列与 plain 30 列下三菜单渲染退出正常。

### 4.2 PTY 测试（方向键 + TTY 确认框）

一次性脚本 `/tmp/phase3b_pty.sh` + 驱动 `/tmp/phase3b_pty_driver.sh`（复用
`tests/ui_test.sh` 的 `run_pty` 模式：按键延迟 0.6 秒投递，`TERM=xterm`）。

结果：**6/6 通过**（`PHASE3B PTY: PASS=6 FAIL=0`）：订阅中心 `↓↓回车` 选中 Mihomo
配置（PTY-1）、订阅中心 `q`（PTY-2）、WARP 按 `7` 弹出确认框且文案含“将删除 WARP
配置与全部 WARP 分流规则”、`n` 取消后 WARP 保留（PTY-3）、WARP `Esc` 返回（PTY-4）、
订阅服务 `↓回车` 选中查看地址并打印完整订阅链接（PTY-5）、命名中心 `q`（PTY-6）。
六例 `stty` 前后一致。

### 4.3 现有套件回归（改动后复测）

| 套件 | 结果 |
|---|---|
| `bash -n` 全项目 | 通过 |
| `tests/ui_test.sh` | `PASS=74 FAIL=0 SKIP=0` |
| `tests/warp_test.sh` | 通过（WARP 出站、分流域名管理与路由同步） |
| `tests/export_test.sh` | 通过（Mihomo YAML 转义、Sing-box JSON 导出、WS 路径编码） |
| `tests/smoke.sh` | 通过 |
| `tests/round2_regression.sh` | 13/13 通过 |
| `tests/version_check.sh` | 通过（1.7.0 未变） |

### 4.4 目视检查

`/tmp/phase3b_show.sh` 打印四个菜单在 80 列下的实际渲染：面板边框对齐，状态药丸、
kv2 双列、域名摘要、提示行均正常；订阅菜单令牌不显值；WARP 菜单“未验证”与服务
“运行中”分行展示，无混淆。

## 五、已知限制

1. **非 TTY 下确认框文案不可见（既有行为，非本轮引入）**：`ui_dialog_confirm` /
   `ui_confirm` 在非 TTY 下用 `read -p` 行内提示，而 bash 的 `read -p` 仅在 stdin
   为终端时才显示提示——管道输入时用户看不到确认文案，只能凭上下文输入 y/n。v1.7.0
   的旧 `ui_confirm` 同样如此。TTY 下带边框确认框正常显示文案（PTY-3 已验证）。
   如需修，应改 `core/ui/dialog.sh`（非本轮文件），在非 TTY 下先 `echo` 文案再读入。
2. **选项颜色丢失**：旧版 WARP 菜单的“清空分流规则”（黄）、“卸载 WARP”（红）用
   `ui_item` 第 4 参数着色；`ui_menu_select` 的 entry 无颜色参数，危险性现由确认框
   文案承载。如需恢复，需扩展导航组件。
3. **`ui_menu_select` 行模式提示为通用 `1-N / q`**（如订阅中心显示 `1-7 / q`），与
   实际键位 `0-6 / v r c s u p q` 不完全对应；列表本身已展示真实键位，组件既有行为。
4. **WARP 出口状态在菜单头恒为“未验证/无法验证”**：菜单渲染不做实时流量测试（见
   第二节取舍说明）；用户必须按 `[1/c]` 才能得到“出口正常/隧道不通”的实测结论。
   这是刻意的准确性取舍，不是缺失。
5. **真机验证待做**：iPhone Termius / Xshell 等真实终端下的方向键、反显、边框对齐
   与窄屏观感仍需用户真机验证（与 Phase 1 已知限制一致）。
6. **渲染测试桩的覆盖边界**：`curl` 桩使命名重探测确定性地返回 Oracle ASN，未覆盖
   真实网络失败/慢速时的 `ensure_node_meta` 回落路径；`warp_check` 第 5 层真实流量
   测试未在沙箱跑通（需真实 sing-box + SOCKS5 + 外网），只覆盖了缺 SOCKS5 的
   UNKNOWN 短路分支。

## 六、文件清单

- `utils/export.sh`（495 行）：新增 `_export_node_stats` / `_export_proto_pill`；
  重写 `menu_node_naming`、`show_export_menu`；其余函数未动。
- `utils/subscription.sh`（155 行）：`subscription_enable` 内两处输入改 `ui_read_text`；
  重写 `menu_subscription_service`；其余函数未动。
- `protocols/warp.sh`（649 行）：新增 `_warp_menu_status` 及 `WARP_M_*` 状态变量；
  重写 `menu_warp`；其余函数未动。
- 本报告：`/tmp/tui_work/PHASE3B-REPORT.md`。
- 一次性验证脚本（`/tmp`，不进仓库）：`/tmp/phase3b_render.sh`、
  `/tmp/phase3b_pty.sh`、`/tmp/phase3b_pty_driver.sh`、`/tmp/phase3b_show.sh`；
  渲染日志 `/tmp/phase3b_render.log`。
