# UI-BASELINE.md — 现状盘点与基线（Phase 0）

- 基线版本：sing-box-moye v1.7.0（含第二轮复审整改，代码 3146 行）
- 基线来源：`/tmp/v17_work` 复制到 `/tmp/tui_work`，已删除 `.git`（实验仓库，不动主线）
- 盘点日期：2026-11-15

## 1. 入口与 UI 相关文件

| 文件 | 行数 | UI 职责 |
|---|---|---|
| `sbx.sh` | 282 | 主入口、主菜单 `main_menu`、遥测 `get_telemetry`、维护菜单、诊断、CLI 分发 |
| `core/ui.sh` | 248 | 终端 UI 组件库（本次核心重构对象） |
| `core/env.sh` | 283 | 颜色、日志、路径、版本、`pause`、`prompt_port`、GeoIP/IP 缓存 |
| `core/state_manager.sh` | — | 状态管理（UI 改造不得改业务行为） |
| `core/json_builder.sh` | — | 配置生成（保持原样） |
| `core/engine.sh` | — | 内核安装/升级/服务管理、`uninstall_all`（253 行） |
| `protocols/*.sh` | — | 7 个协议模块，各含 `menu_*` |
| `utils/*.sh` | — | 证书、网络调优、导出、订阅 |

## 2. 现有 core/ui.sh 能力（已相当成熟）

- 自适应宽度 58~78 列（`UI_W`/`UI_IW`），`SBM_COLS` 可覆盖
- CJK/Emoji 显示宽度精确计算（`ui_vwidth`/`ui_cw`/`ui_fit`），右侧边框对齐
- NO_COLOR / 非 TTY 自动去色；非 UTF-8 自动降级 ASCII 边框；`SBM_ASCII=1` 强制 ASCII；`SBM_FORCE_COLOR=1` 强制颜色
- 颜色变量在 `core/env.sh` 定义（256 色）：RED/GREEN/YELLOW/BLUE/CYAN/PURPLE/GRAY/WHITE/BOLD/DIM/PLAIN

## 3. 现有 UI 接口清单（全部必须保留）

`ui_top` `ui_mid` `ui_bot` `ui_box_top` `ui_box_mid` `ui_box_bot` `ui_line`
`ui_split` `ui_section` `ui_kv` `ui_kv2` `ui_item` `ui_proto_row` `ui_proto_status`
`ui_proto_detail` `ui_menu_head` `ui_prompt_str` `ui_confirm` `ui_hint` `ui_banner`
`ui_node_card` `ui_clear` `ui_init` `ui_rule` `ui_strip` `ui_cw` `ui_vwidth` `ui_fit`

调用统计（全项目）：`ui_item` 64、`ui_kv` 33、`ui_bot` 20、`ui_mid` 19、`ui_line` 17、
`ui_prompt_str` 13、`ui_menu_head` 13、`ui_top` 9、`ui_banner` 9、`ui_split` 7、
`ui_proto_status` 7、`ui_proto_row` 7、`ui_node_card` 7、`ui_kv2` 4、`ui_confirm` 4、
`ui_section` 3、`ui_hint` 2。

## 4. 菜单/页面清单（15 个交互入口）

| 入口 | 函数 | 文件 |
|---|---|---|
| 主菜单 | `main_menu` | sbx.sh:124 |
| 内核服务维护 | `menu_maintenance` | sbx.sh:60 |
| 运行环境诊断 | `run_diagnostics` | sbx.sh:78 |
| Reality | `menu_reality` | protocols/reality.sh:155 |
| Hysteria 2 | `menu_hysteria2` | protocols/hysteria2.sh:82 |
| TUIC | `menu_tuic` | protocols/tuic.sh:77 |
| AnyTLS | `menu_anytls` | protocols/anytls.sh:94 |
| Argo | `menu_argo` | protocols/argo.sh:205 |
| SOCKS5 | `menu_socks5` / `show_socks5_params` | protocols/socks5.sh:78/3 |
| WARP | `menu_warp` | protocols/warp.sh:483 |
| 节点命名 | `menu_node_naming` | utils/export.sh:326 |
| 节点订阅中心 | `show_export_menu` | utils/export.sh:360 |
| 在线订阅服务 | `menu_subscription_service` | utils/subscription.sh:112 |
| 网络调优 | `sysctl_menu` | utils/sysctl.sh:78 |
| 彻底卸载 | `uninstall_all` | core/engine.sh:253 |

## 5. 输入点盘点

- 菜单选择 `read -rp "$(ui_prompt_str ...)"`：13 处（主菜单 + 各子菜单）
- 业务参数 `read -rp`（裸提示，无 ui 包装）：约 20 处
  - reality SNI、hysteria2 端口跳跃段、argo 模式/优选 IP/Token（`read -rsp` 静默）/域名、
    socks5 用户名、warp 模式选择/域名增删、sysctl 跳跃端口段、subscription 监听地址/端口、
    export 命名方案/自定义前缀、cert 证书路径/域名、env `prompt_port`/`pause`
- 无 `select` 语句；无方向键交互；无 ncurses 依赖
- `log_info/log_ok/log_warn/log_err` 调用 218 处（env.sh 定义，`ℹ ✔ ⚠ ✖` 前缀）

## 6. 主菜单现状（sbx.sh main_menu）

- 顶部：品牌 + 版本 + 描述；遥测三行 `ui_kv2`（节点标识/公网地址、核心状态/资源占用、网络引擎/自治域号）
- `PROTOCOLS` 区：6 个 `ui_proto_row` + 一键全装 `ui_item`
- `OPERATIONS` 区：订阅中心、命名规则、网络调优、内核维护、诊断、WARP、彻底卸载、退出
- 每次循环调用 `get_public_ip`（6 小时缓存，见 env.sh）与 `get_telemetry`；`get_telemetry` 每次 `systemctl` + `/proc` 读取
- 输入：`read -rp` 数字/字母；`pause` 回车返回

## 7. 终端输出基线（非 TTY 渲染示例）

主菜单在 80 列非 TTY 下渲染为单层 Unicode 边框面板（`╭─╮│╰─╯`），
标题列 16、kv 标签列 10；无颜色时 `NO_COLOR` 或非 TTY 自动去色。
（真实终端截图需在真机验证，沙箱以 `script`/管道捕获输出为准。）
