# PHASE3C-REPORT.md — TUI 重构 Phase 3c：网络调优与卸载页面重构

- 完成日期：2026-11-15
- 基线：sing-box-moye v1.7.0（TUI Phase 1 新 UI 架构），工作目录 `/tmp/tui_work`（实验仓库，未推送）
- 修改文件（仅 2 个）：`utils/sysctl.sh`（仅 `sysctl_menu`）、`core/engine.sh`（仅 `uninstall_all`）
- 版本号：未动，仍为 1.7.0（`core/env.sh` `SBM_VERSION` 已核对）
- 改动范围核对：与 `/tmp/v17_work` 基线 diff，`sysctl.sh` 全部 diff 落在 79 行起的
  `sysctl_menu` 内，`engine.sh` 全部 diff 落在 254 行起的 `uninstall_all` 内；
  其余函数逐个 diff 均为逐字节一致：
  `enable_bbr_and_udp_tuning`、`normalize_hop_range`、`add_port_hopping`、
  `remove_port_hopping`、`get_installed_sb_version`、`write_singbox_unit`、
  `install_singbox_core`、`ensure_singbox_installed`。

## 一、任务 1：系统网络调优（`utils/sysctl.sh` 的 `sysctl_menu`）

### 改动说明

- 状态区改为两栏对照，明确区分「已配置」与「实际生效」：
  - 「已配置」（本工具写入的配置）：
    - 调优配置：`/etc/sysctl.d/99-singbox-tune.conf` 存在即「已配置」，否则「未配置」
    - 端口跳跃：状态记录 `hop_range` 为准，显示 `端口段 → 监听端口`（端口未知时显示
      `→ Hysteria2`，与改前一致）；状态缺失但 `sbx-hop.service` 单元文件存在时如实标注
      「已配置（单元文件存在，端口段未知）」
  - 「实际生效」（内核实时检测值，只读 `sysctl -n` / `systemctl is-active`）：
    - 拥塞控制：实时算法名（`bbr`/`cubic`/…）
    - BBR 状态：`bbr`→已生效，其他已知算法→未生效
    - 队列算法：实时 `default_qdisc` 值；FQ 状态：`fq`→已启用，其他→未启用
    - UDP 缓冲区：`rmem_max … · wmem_max …` 实测数值；UDP 最小值：
      `udp_rmem_min … · udp_wmem_min …` 实测数值（任一读不到即整行未知，不拼凑半行数据）
    - 跳跃规则：仅已配置时检测 `systemctl is-active sbx-hop`，已生效/未生效；
      无 `systemctl` 时为未知；未配置时显示「未配置」
  - 检测失败（无 `sysctl`、无权限、无 `systemctl`）一律显示「未知」，不虚构为正常。
- 导航改用 `ui_menu_select`（方向键 + 快捷键，TTY；非 TTY 自动降级行输入）：
  entry 为 `1/b|BBR + UDP 缓冲区|…`、`2/h|UDP 端口跳跃|…`、`0/q|返回主菜单|`，
  选项与改前 `0-2 / b h q` 完全一致，业务调用不变（`1/b`→`enable_bbr_and_udp_tuning`，
  `2/h`→端口跳跃流程，Esc/q/EOF/其他一律返回主菜单）。
- 默认选中下标为 2（返回主菜单），理由有二：与改前行为一致（改前空输入走 `*) return`，
  直接返回）；避免 TTY 下误按回车触发 BBR 调优（写配置的真实动作）。
- 端口跳跃的两次输入改用 `ui_read_text`（端口段、监听端口），不传默认值（空输入即空串，
  与改前 `read` 行为一致）；验证规则未动，仍由 `add_port_hopping` /
  `normalize_hop_range` 执行；监听端口仅在状态无端口时才追问（逻辑与改前一致）；
  EOF 时静默返回（改前 EOF 会走到校验报错；现按新 UI 的 EOF 惯例直接返回）。
- 仍为单次操作后返回（改前同样是单次，无循环，未加循环）。
- BBR/UDP/端口跳跃业务函数一律未动（已逐字节核对）。

### 渲染样例（stub：bbr+fq 已生效、跳跃已配置已生效；沙箱无 UTF-8 locale 故为 ASCII 边框，是设计好的降级）

```
+----------------------------------------------------------------------------+
|  系统网络调优                                    SING-BOX MOYE › TUNING  |
+----------------------------------------------------------------------------+
|  # 已配置  本工具写入的配置                                                |
|  调优配置   o 未配置                                                       |
|  端口跳跃 * 20000:40000 → 8443                                           |
+----------------------------------------------------------------------------+
|  # 实际生效  内核实时检测值                                                   |
|  拥塞控制   bbr                                                            |
|  BBR 状态    已生效                                                          |
|  队列算法     fq                                                             |
|  FQ 状态     已启用                                                        |
|  UDP 缓冲区 rmem_max 33554432 · wmem_max 33554432                         |
|  UDP 最小值  udp_rmem_min 16384 · udp_wmem_min 16384                       |
|  跳跃规则   已生效                                                          |
+----------------------------------------------------------------------------+
  [1/b] BBR + UDP 缓冲区  一键开启 BBR 并扩容 QUIC/UDP 缓冲区
  [2/h] UDP 端口跳跃  为 Hysteria2 设置跳跃端口段
  [0/q] 返回主菜单
```

（注：上例「调优配置 未配置」而 BBR 已生效，是真实可能出现的混合状态——BBR 由其他
途径开启，正是「已配置 vs 实际生效」两栏要区分的情况。）

## 二、任务 2：彻底卸载页面（`core/engine.sh` 的 `uninstall_all`）

### 改动说明

- 改为独立危险操作页面：`ui_menu_head "彻底卸载" "UNINSTALL"` 开头，分「将删除以下内容」
  （红 ✖ 逐项）与「将保留」（绿 ✔）两区，清单与下方执行代码逐项对应（见第三节对照表）。
- 管理脚本 sbx 自身的去留按现有实际行为如实展示：页面顶部先按原条件
  `[[ "$APP_HOME" == "/usr/local/etc/sbx" && -L /usr/local/bin/sbx ]]` 求值一次
  （存入 `_sbx_self`，渲染与执行共用同一结果）：
  - 条件成立 → 删除清单含「管理脚本 /usr/local/bin/sbx 与 /usr/local/etc/sbx」，
    保留区仅「其他系统文件与用户数据」；
  - 条件不成立 → 保留区显示「管理脚本 sbx（非标准安装路径，本次不删除）」。
- 确认流程（见第四节）：单次 `ui_dialog_confirm`，默认取消。
- 执行过程用 `ui_stage` 分 4 阶段展示；阶段划分按实际执行顺序映射（见下），
  每阶段按真实返回值报告成功/失败，不虚构成功：
  - `[1/4] 正在停止服务并移除服务单元...`：`remove_port_hopping`、三个服务的
    stop/disable 与单元文件删除、cloudflared 日志删除
  - `[2/4] 正在删除内核、配置与调优文件...`：`daemon-reload`、删二进制与备份、
    `rm -rf $SB_ETC`、调优文件删除（如存在）+ `sysctl --system`
  - `[3/4] 正在清理管理脚本...`：仅标准路径时删 sbx 链接与 `$APP_HOME`，否则提示保留
  - `[4/4] 完成`：按分支打印改前原句 `log_ok`（「…与管理脚本已彻底清理。」/
    「…已彻底清理。」），随后 `exit 0`
  - 返回值记录手法：原先 `|| true` 的地方改为 `|| _sN_rc=1`（失败仍继续，行为不变）；
    原先裸命令（`daemon-reload`、`rm -f`、`rm -rf`）追加 `|| _sN_rc=1`（本项目
    `sbx.sh`/`core`/`utils` 均无 `set -e`，失败本来就继续，行为不变）。
    阶段失败时打印 `log_warn` 说明并继续（与改前 best-effort 语义一致），
    如阶段 1 的失败提示注明「服务可能未安装或已停止」——服务本就不存在时
    `systemctl stop` 返回非零属正常，不应误报为卸载失败。
  - 阶段名与任务书「停止服务 → 删除文件 → 清理服务 → 完成」的对应说明：
    实际代码中服务单元删除与停止交错在前（二进制删除在后），「顺序不动」的硬约束
    优先于字面阶段名，故阶段 1 涵盖「停止 + 单元移除」，阶段 3 为「管理脚本清理」；
    未为迎合阶段名而调整任何删除顺序。
- 唯一文案位置变化：改前「…与管理脚本已彻底清理。」打印在 `rm -f sbx` 之后、
  `rm -rf $APP_HOME` 之前（删目录失败也已报成功）；现改为阶段 4 在全部删除完成后打印，
  文案逐字不变，更诚实。删除命令、文件列表与顺序其余全部未动。

### 渲染样例（非标准路径，管道输入 n 取消）

```
+----------------------------------------------------------------------------+
|  彻底卸载                                    SING-BOX MOYE › UNINSTALL  |
+----------------------------------------------------------------------------+
|  # 将删除以下内容  此操作不可恢复                                         |
|  ✖ 端口跳跃规则与服务单元 sbx-hop.service（如已配置）                       |
|  ✖ 订阅服务单元 /etc/systemd/system/sbx-subscription.service                  |
|  ✖ sing-box 服务单元 /etc/systemd/system/sing-box.service                     |
|  ✖ cloudflared 服务单元 cloudflared-sb.service                                |
|  ✖ cloudflared 日志 /var/log/cloudflared-sb.log                            |
|  ✖ 内核二进制 /usr/local/bin/sing-box                                      |
|  ✖ 内核备份 /usr/local/bin/sing-box.bak                                   |
|  ✖ cloudflared 二进制 /usr/local/bin/cloudflared                           |
|  ✖ 配置目录 /etc/sing-box                                                  |
|    （含配置、状态、证书、导出文件）                                          |
|  ✖ 调优参数文件 /etc/sysctl.d/99-singbox-tune.conf（如存在）                |
+----------------------------------------------------------------------------+
|  # 将保留                                                                   |
|  ✔ 管理脚本 sbx（非标准安装路径，本次不删除）                               |
|  ✔ 其他系统文件与用户数据（本次卸载不触碰）                           |
+----------------------------------------------------------------------------+
 ℹ 已取消卸载。
```

## 三、卸载删除清单对照（改前 = 改后）

执行顺序即下表顺序，改前改后一致。路径变量：`SB_BIN=/usr/local/bin/sing-box`、
`CF_BIN=/usr/local/bin/cloudflared`、`SB_ETC=/etc/sing-box`（含
`SB_CERT_DIR=/etc/sing-box/certs` 证书与 `SB_EXPORT_DIR=/etc/sing-box/export` 导出文件，
均随 `rm -rf $SB_ETC` 删除）。

| # | 改前执行（原 `uninstall_all`） | 改后执行 | 页面清单行 |
|---|---|---|---|
| 1 | `remove_port_hopping`（停 sbx-hop、删单元、清 iptables 规则） | 相同（阶段 1） | 端口跳跃规则与服务单元 sbx-hop.service（如已配置） |
| 2 | `systemctl disable --now sbx-subscription.service` + 删单元文件 | 相同（阶段 1） | 订阅服务单元 /etc/systemd/system/sbx-subscription.service |
| 3 | `systemctl stop/disable sing-box` + 删单元文件 | 相同（阶段 1） | sing-box 服务单元 /etc/systemd/system/sing-box.service |
| 4 | `systemctl stop/disable cloudflared-sb` + 删单元文件 + 删 `/var/log/cloudflared-sb.log` | 相同（阶段 1） | cloudflared 服务单元 cloudflared-sb.service；cloudflared 日志 /var/log/cloudflared-sb.log |
| 5 | `systemctl daemon-reload` | 相同（阶段 2） | —（无文件删除，不列入清单） |
| 6 | `rm -f $SB_BIN ${SB_BIN}.bak $CF_BIN` | 相同（阶段 2） | 内核二进制；内核备份；cloudflared 二进制 |
| 7 | `rm -rf $SB_ETC`（配置、状态、证书、导出文件） | 相同（阶段 2） | 配置目录 $SB_ETC（含配置、状态、证书、导出文件） |
| 8 | 如存在则删 `/etc/sysctl.d/99-singbox-tune.conf` + `sysctl --system` | 相同（阶段 2） | 调优参数文件 …（如存在） |
| 9 | 仅标准路径时：`rm -f /usr/local/bin/sbx` + `rm -rf $APP_HOME` | 相同（阶段 3） | 标准路径时列入删除清单，否则列入保留清单 |
| — | 其余系统文件与用户数据 | 未触碰 | 保留区「其他系统文件与用户数据（本次卸载不触碰）」 |

删除范围结论：改前 = 改后，无增无减；页面清单与执行代码逐项对应。

## 四、确认流程说明

- 改前：单次 `ui_confirm "确定要彻底卸载 Sing-box 及其所有配置吗？"`，默认 N；
  无二次确认。
- 改后：单次 `ui_dialog_confirm "确定要彻底卸载 Sing-box 及其所有配置吗？此操作不可恢复！"`，
  默认取消（空输入 / EOF / 非 y 均为取消）。`ui_confirm` 本身就是 `ui_dialog_confirm` 的
  薄包装（`core/ui/dialog.sh`），因此确认强度与改前完全相等，未弱化；改前无二次确认，
  故不补第二次（任务书：现有实现如有二次确认则保留两次——实际只有一次）。
- 取消时打印改前原句 `log_info "已取消卸载。"` 并返回主菜单，不执行任何删除动作
  （测试验证：取消后零系统调用，见第五节场景 F/F2）。
- TTY 下确认框为带边框对话框（含「默认取消，输入 y 确认」提示行）；非 TTY 降级为
  行内 `[y/N]` 提示——均为 `ui_dialog_confirm` 的已有行为。

## 五、测试方法与结果

### 5.1 语法与现有套件

- `bash -n utils/sysctl.sh core/engine.sh`：通过；`tests/ui_test.sh` 亦含全项目 `bash -n`。
- `bash tests/ui_test.sh`：`UI TEST SUMMARY: PASS=74 FAIL=0 SKIP=0`（改动前后一致，未破坏）。
- 版本号：`SBM_VERSION` 仍为 1.7.0。

### 5.2 stub 渲染测试（`/tmp/phase3c_harness.sh`，未进仓库）

方法：`source` 真实 `core/env.sh` + `core/ui.sh` + `utils/sysctl.sh` + `core/engine.sh`，
以 shell 函数桩覆盖状态层（`state_get_field` / `state_has_proto` / `state_set_field` /
`export_all_nodes`）、系统层（`sysctl` / `systemctl`，按场景返回调优值 / 失败 / 不可达）
与危险业务函数（`enable_bbr_and_udp_tuning` / `add_port_hopping`，仅记录调用）；
管道输入驱动菜单与确认框；断言输出文本、调用日志、哨兵文件存亡与 stderr 为空。
卸载确认场景（y）在子 shell 中执行（`exit 0` 不杀 harness），`SB_BIN`/`CF_BIN`/
`SB_ETC`/`APP_HOME` 全部重定向到临时目录，真实 `rm` 只删临时哨兵文件。

结果：`PHASE3C HARNESS SUMMARY: PASS=69 FAIL=0`，场景如下：

| 场景 | 输入 | 验证要点 | 结果 |
|---|---|---|---|
| A 调优渲染（已调优） | `0` | 两栏状态全对（bbr/fq/UDP 数值/跳跃已生效）；调优文件临时创建验证「已配置」分支后删除；无业务调用；最大行宽 78 ≤ 80；无 stderr | 通过 |
| B 调优渲染（全未知） | `q` | sysctl 全失败时显示「未知」，不出现「正常」；空 PATH 下无 stderr | 通过 |
| B2 混合状态 | `0` | cubic 显示「未生效」、pfifo_fast 显示「未启用」；已配置但无 systemctl 时跳跃规则为「未知」 | 通过 |
| C 跳跃流程 | `2` + 端口段 + 监听端口 | 状态无端口时追问监听端口；`add_port_hopping` 收到正确参数；状态写入规范化端口段；成功后导出节点 | 通过 |
| C2 校验未改 | `2` + 非法端口段 | 用真实 `add_port_hopping` 验证「端口段格式无效」拒绝，失败后无状态写入 | 通过 |
| D BBR 调用 | `1` | `enable_bbr_and_udp_tuning` 被调用 | 通过 |
| E EOF | 空 stdin | 静默返回，无报错 | 通过 |
| F 卸载取消 | `n` | 删除/保留清单 12 项断言全过；「已取消卸载」；零系统调用；6 个哨兵文件完好；最大行宽 78；无 stderr | 通过 |
| F2 默认取消 | 空行 | 空输入即取消，零系统调用 | 通过 |
| G 卸载确认 | `y`（子 shell） | 退出码 0；`[1/4]`~`[4/4]` 齐全；两阶段成功报告；哨兵二进制与配置目录均真删除；最终文案为改前原句 | 通过 |
| H 标准路径渲染 | `n` | 临时建 `/usr/local/bin/sbx` 链接 + `/usr/local/etc/sbx`，验证管理脚本列入删除清单、保留区无管理脚本；用完清理，无残留 | 通过 |

测试中发现并修复的真问题：配置目录清单行在长路径下会被 `ui_line` 截断，
导致「导出文件」不可见；已拆为两行（目录行 + 灰色说明行），任意路径长度下
证书/导出文件说明均可见。修复后 harness 从 67/69 升至 69/69。

## 六、已知限制

- TTY 真机验证待做：方向键高亮、反显、确认框边框在 iPhone Termius / Xshell 等
  真实终端上的观感未验证（与 Phase 1 相同限制；PTY 层面的方向键行为由
  `tests/ui_test.sh` 覆盖，`ui_menu_select` 本身未改）。
- 窄屏（<60 列）下卸载清单的长路径行会被 `ui_line` 安全截断（加省略号），
  不会越界，但尾部可能看不全；80 列正常宽度下全部完整显示（已验证最大行宽 78）。
- 调优页「已配置」以调优文件存在为准，不解析文件内容；若文件被手动清空，
  仍显示「已配置」（与卸载逻辑的「文件存在即删除」口径一致）。
- 跳跃规则「已生效」以 `systemctl is-active sbx-hop` 为准；若用户手动用 iptables
  加了等效规则但未走本工具的服务，显示为「未生效」——这是按本工具管理范围的诚实表述，
  不是对 iptables 全表的检测。
- 卸载阶段 1 的失败提示是汇总式警告（不逐条列出哪个命令失败）；如需逐条诊断，
  需另加日志，本轮未做（保持改前 best-effort 语义，不改变行为）。
- `ui_menu_select` 不可重入、临时接管 trap 等 Phase 1 已知限制同样适用本页。
