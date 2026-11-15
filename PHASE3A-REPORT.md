# PHASE3A-REPORT.md — TUI 重构 Phase 3a：协议管理页面统一重构

- 完成日期：2026-11-15
- 工作目录：`/tmp/tui_work`（实验仓库，未推送）
- 基线：sing-box-moye v1.7.0（含第二轮复审整改）+ TUI Phase 1 新 UI 架构
- 版本号：未改动，仍为 1.7.0（`version_check.sh` 通过）
- 改动文件（仅 6 个）：`protocols/reality.sh`、`protocols/hysteria2.sh`、
  `protocols/tuic.sh`、`protocols/anytls.sh`、`protocols/argo.sh`、
  `protocols/socks5.sh`
- 改动范围验证：与 `/tmp/v17_work`（v1.7.0 基线）逐文件 diff，
  全部 hunk 落在 `menu_*` 函数内，另加 `show_socks5_params` 两行
  （log→ui_msg，文案与返回值不变）；
  `install_*` / `uninstall_*` / `modify_reality` / `argo_refresh_domain` /
  `argo_change_ips` 等业务函数逐字节一致，零改动。

## 一、统一模式

6 个 `menu_*` 统一为同一结构（以 reality 为例，其余同构）：

```bash
menu_reality() {
    ui_menu_head "VLESS-Reality" "PROTOCOLS › REALITY"   # 1. 标题 + 面包屑
    ui_proto_status reality                              # 2. 当前协议状态
    ui_bot                                               #    状态面板收尾
    ui_menu_select "请选择" 3 \                          # 3/4. 选项列表 + 导航
        "1/i|安装 / 重置|生成全新的 UUID 与密钥对" \
        "2/m|修改端口与域名|保留原密钥，仅调整端口与伪装 SNI" \
        "3/x|卸载协议|移除入站并清理状态" \
        "0/q|返回主菜单|"
    local rc=$?
    if (( rc != 0 )); then return 0; fi   # Esc / q / EOF / 中断 → 返回上一级
    case "$UI_SEL_KEY" in                                # 5. 结果消息框
        "1/i")
            if install_reality; then
                ui_msg_ok "VLESS-Reality 安装完成"
            else
                ui_msg_err "VLESS-Reality 安装失败，请查看上方日志"
            fi
            ;;
        ...
    esac
}
```

### 设计决策（均有据可查，非随意取舍）

1. **面板与选项列表分离渲染**：`ui_menu_head` + `ui_proto_status` 仍在
   `ui_top/ui_bot` 面板内；选项列表改由 `ui_menu_select` 在面板下方渲染。
   原因：TTY 下 `ui_menu_select` 需用光标上移逐键重绘列表，若同时在面板内
   用 `ui_item` 再渲染一份，两份列表会重复且重绘错位。行模式下
   `ui_menu_select` 的输出格式（`[key] label  desc`）与旧版 `ui_item`
   的 plain 形态一致，视觉等价。
2. **默认选中最后一项“返回主菜单”**：旧菜单空输入（直接回车）走 `*)` 返回
   上一级；`ui_menu_select` 空输入选中默认项。为保旧行为、避免回车误触
   安装，默认下标一律为末项（reality 3、argo 5，其余 2）。TTY 下初始高亮
   同样落在“返回主菜单”，与行模式语义一致。
3. **按 `UI_SEL_KEY` 分发**：key 字段（`"1/i"` 等）即原快捷键组合，显式匹配，
   不依赖下标，顺序调整也不影响分发。
4. **结果消息策略**：
   - 安装 / 卸载 / 修改：按真实返回值 `ui_msg_ok` / `ui_msg_err`
     （与 `install_all_protocols` 依赖同一返回信号；见“已知限制 2”）。
   - argo 刷新域名 / 更换优选 IP：**仅失败时**补 `ui_msg_err`。两者成功路径
     已有带详情的业务 log，且“非 quick 模式”（刷新）与“未做更改”（换 IP）
     同样返回 0，一律补 ok 会虚构成功。
   - argo 查看状态：`systemctl status … || true` 原样保留，不包装（输出本身
     就是结果）。
5. **安装流程内的参数输入一律保留原有 `read` 行为**：hysteria2 端口跳跃、
   argo 模式/优选 IP/Token（`read -s` 静默）/域名、reality SNI、
   socks5 用户名均在业务函数内，任务约束“业务函数一律不动”优先于
   “或改用 ui_read_text”的许可；验证规则零风险。本次不做输入组件迁移，
   如需统一可另立任务。

## 二、各菜单改动说明

| 菜单 | 函数位置 | 改动 |
|---|---|---|
| reality | `protocols/reality.sh:155` | 面包屑 `REALITY` → `PROTOCOLS › REALITY`；`ui_item` 列表 → `ui_menu_select`（4 项，默认 3）；`read`+数字 case → `UI_SEL_KEY` 分发；安装/修改/卸载加返回值消息框 |
| hysteria2 | `protocols/hysteria2.sh:82` | 同上（3 项，默认 2）；安装流程内端口跳跃 `read` 未动 |
| tuic | `protocols/tuic.sh:77` | 同上（3 项，默认 2） |
| anytls | `protocols/anytls.sh:94` | 同上（3 项，默认 2）；原 `*) log_warn "无效选项"` 分支被 `ui_menu_select` 的重问机制取代（见第四节） |
| argo | `protocols/argo.sh:205` | 同上（6 项，默认 5）；隧道服务 `ui_kv` 行保留在状态面板内；查看状态原样保留；刷新/换 IP 仅失败补 err 框；安装流程内模式/Token/域名 `read` 未动 |
| socks5 | `protocols/socks5.sh:78` / `:3` | 菜单同上（3 项，默认 2）；面包屑 `PROTOCOL` → `PROTOCOLS › SOCKS5`；`show_socks5_params` 参数面板逐行未动，仅两处错误提示由 `log_warn`/`log_err` 改为同文案的 `ui_msg_warn`/`ui_msg_err`（返回值仍为 1；该函数亦被 `utils/export.sh:375` 调用，语义不变） |

**socks5“查看参数”说明（任务书与文件现状不一致，已按文件为准）**：
任务书列 socks5 有“查看参数”选项，但现有文件菜单只有安装/卸载/返回三项，
`show_socks5_params` 仅在安装成功后与订阅菜单中调用，没有对应菜单入口与快捷键。
按“核对各文件现状”与“不得发明快捷键/选项顺序”约束，**未新增选项**。
如需把“查看参数”加入菜单（需新编号与字母键），请产品定键位后另做。

参数摘要：`ui_proto_status` 内部已通过 `ui_proto_detail` 嵌入参数摘要
（端口/SNI/跳跃段/模式等），经测试确认已安装时正常展示，故未另补一行；
argo 另保留原有的隧道服务行。

## 三、快捷键对照表（改前 = 改后）

数字、字母、顺序、业务调用全部未变；字母大小写均可（`ui_menu_select`
与旧 `case` 同为大小写不敏感）。

### reality（`menu_reality`）

| 按键 | 操作 | 业务调用 | 改前 | 改后 |
|---|---|---|---|---|
| 1 / i | 安装 / 重置 | `install_reality` | ✔ | ✔ 同 |
| 2 / m | 修改端口与域名 | `modify_reality` | ✔ | ✔ 同 |
| 3 / x | 卸载协议 | `uninstall_reality` | ✔ | ✔ 同 |
| 0 / q | 返回主菜单 | return | ✔ | ✔ 同 |

### hysteria2（`menu_hysteria2`）

| 按键 | 操作 | 业务调用 | 改前 | 改后 |
|---|---|---|---|---|
| 1 / i | 安装 / 重置 | `install_hysteria2` | ✔ | ✔ 同 |
| 2 / x | 卸载协议 | `uninstall_hysteria2` | ✔ | ✔ 同 |
| 0 / q | 返回主菜单 | return | ✔ | ✔ 同 |

### tuic（`menu_tuic`）

| 按键 | 操作 | 业务调用 | 改前 | 改后 |
|---|---|---|---|---|
| 1 / i | 安装 / 重置 | `install_tuic` | ✔ | ✔ 同 |
| 2 / x | 卸载协议 | `uninstall_tuic` | ✔ | ✔ 同 |
| 0 / q | 返回主菜单 | return | ✔ | ✔ 同 |

### anytls（`menu_anytls`）

| 按键 | 操作 | 业务调用 | 改前 | 改后 |
|---|---|---|---|---|
| 1 / i | 安装 / 重置 | `install_anytls` | ✔ | ✔ 同 |
| 2 / x | 卸载协议 | `uninstall_anytls` | ✔ | ✔ 同 |
| 0 / q | 返回主菜单 | return | ✔ | ✔ 同 |

### argo（`menu_argo`）

| 按键 | 操作 | 业务调用 | 改前 | 改后 |
|---|---|---|---|---|
| 1 / i | 安装 / 重新配置 | `install_argo` | ✔ | ✔ 同 |
| 2 / s | 查看隧道状态 | `systemctl status cloudflared-sb --no-pager` | ✔ | ✔ 同 |
| 3 / x | 卸载隧道 | `uninstall_argo` | ✔ | ✔ 同 |
| 4 / r | 刷新临时域名 | `argo_refresh_domain` | ✔ | ✔ 同 |
| 5 / c | 更换优选 IP | `argo_change_ips` | ✔ | ✔ 同 |
| 0 / q | 返回主菜单 | return | ✔ | ✔ 同 |

### socks5（`menu_socks5`）

| 按键 | 操作 | 业务调用 | 改前 | 改后 |
|---|---|---|---|---|
| 1 / i | 安装 / 重装 | `install_socks5` | ✔ | ✔ 同 |
| 2 / x | 卸载协议 | `uninstall_socks5` | ✔ | ✔ 同 |
| 0 / q | 返回主菜单 | return | ✔ | ✔ 同 |

## 四、有意的行为差异（采用 `ui_menu_select` 的固有语义）

1. **无效输入由“直接返回”改为“重问”**：旧菜单任意无效输入走 `*)` 返回
   主菜单；新行模式打印提示并重问，TTY 下忽略未知按键停留菜单。这是
   Phase 1 `ui_menu_select` 的设计，与主菜单等后续统一页一致。
2. **anytls 的 `log_warn "无效选项"` 消失**：被重问机制取代，无功能损失。
3. **行模式位置数字 1..n 可选中**：`ui_menu_select` 内置；落点与旧行为一致
   （如 reality 输入 4、hy2 输入 3 均选中“返回主菜单”，旧 `*)` 同样返回）。
4. **卸载项不再标红**：旧 `ui_item` 给卸载项传了 `$RED` 名称色；
   `ui_menu_select` 无单项颜色参数，新列表统一配色。危险操作本身仍有
   业务层确认/日志，无安全降级。
5. **空输入 / EOF / Esc / q 的结果与旧行为一致**：均返回上一级，不执行业务
   （测试覆盖）。

## 五、测试方法与结果

### 5.1 测试 harness（`/tmp/phase3a_test/`，仓库外，不污染实验仓）

- `setup.sh`：source 最小集合（`core/env.sh`、`core/ui.sh`、
  `core/state_manager.sh` + 6 个协议文件，不加载 `sbx.sh`，避免与其他
  worker 在改的文件互相干扰）；状态目录（`SB_STATE`/`SB_ETC`/`SB_CERT_DIR`/
  `SB_EXPORT_DIR`）指向临时目录，不碰真实 `/etc/sing-box`；业务函数 stub
  化（只打印 `STUB-CALLED:<名>`，`STUB_FAIL=<名>` 可令其返回 1）；
  `systemctl` 与 `get_public_ip` 同样 stub，不做真实操作、不走网络。
- `harness.sh`：管道模式单用例驱动；`pty_drive.sh`：伪终端驱动
  （复用 Phase 1 的 `script` + 延迟 0.6s 投递技巧，含 stty 前后一致校验）。
- `run_tests.sh`：断言驱动，`bash /tmp/phase3a_test/run_tests.sh`。

### 5.2 结果：132/132 通过

```
PHASE3A TEST SUMMARY: PASS=132 FAIL=0
```

| 分组 | 用例 | 结果 |
|---|---|---|
| 六菜单 q 退出渲染（标题/面包屑/“未安装”/返回码/无业务调用/无 shell 错误） | 18 | 通过 |
| 六菜单 0 / 空输入 / EOF 返回且不执行业务 | 36 | 通过 |
| 无效输入重问（行为证明：`9→1` 仍安装、`z→5` 仍换 IP；`9→q` 退出；含 `ui_menu_select` 独立文案验证 1 例） | 16 | 通过 |
| 数字/字母分发 + 成功 ok / 失败 err（含大写字母；含 argo 全部 6 项） | 43 | 通过 |
| 已安装状态摘要（端口/SNI/跳跃段/模式/隧道行） | 6 | 通过 |
| `show_socks5_params`（未安装 warn+rc1 / 面板展示 / 数据不完整 err+rc1） | 4 | 通过 |
| PTY（tuic ↓↓回车返回、↑回车选中卸载、快捷键 i、reality Esc、argo q；stty 恢复 + 反显） | 9 | 通过 |

渲染样本（argo，已安装状态，管道模式）：

```
╭────────────────────────────────────────────────────────────────────────────╮
│  Cloudflare Argo                         SING-BOX MOYE › PROTOCOLS › ARGO  │
├────────────────────────────────────────────────────────────────────────────┤
│  当前状态   ● 已启用 · WS · Quick                                          │
│  隧道服务   ○ cloudflared 未运行                                           │
╰────────────────────────────────────────────────────────────────────────────╯
  [1/i] 安装 / 重新配置  固定 Token 隧道 或 临时隧道
  [2/s] 查看隧道状态  systemctl status cloudflared-sb
  [3/x] 卸载隧道  停止服务并移除本地入站
  [4/r] 刷新临时域名  临时隧道重启后域名会变化
  [5/c] 更换优选 IP  只换客户端连接地址，不重建隧道
  [0/q] 返回主菜单
```

### 5.3 回归套件（均在 `/tmp/tui_work` 运行）

- `bash -n` 全项目：通过（含 6 个修改文件）。
- `tests/ui_test.sh`：`PASS=74 FAIL=0 SKIP=0`（与 Phase 1 报告一致）。
- `tests/round2_regression.sh`：13/13 通过。
- `tests/version_check.sh`：通过（1.7.0 未变）。
- `tests/smoke.sh`：通过（0 行 FAIL）。

## 六、已知限制

1. **既有 stderr 吞没 bug（v1.7.0 已有，不在本阶段改动范围）**：
   `core/state_manager.sh:26` `_state_lock` 中的
   `exec 200>"$lock_file" 2>/dev/null` 是无命令的 `exec`，按 bash 语义会把
   **当前 shell 自身的 stderr 永久重定向到 /dev/null**（沙箱实测确认；
   同文件 :31、:46 另有两处同类写法；`/tmp/v17_work` 基线同样存在）。
   `sbx_main` 开头即调 `init_state_file`，故生产会话中 stderr 在第一个菜单
   出现前已被吞没。后果：行模式下 `read -p` 提示行与 `ui_menu_select` 的
   “无效选项”提示（均走 stderr）在生产中**不可见**（用户仍可盲输，功能不受
   影响；旧菜单同样受影响，非本次引入）。`log_*` 走 stdout，不受影响；
   TTY 方向键模式用 `printf` 走 stdout，亦不受影响。
   建议修复（另立任务，改 `state_manager.sh`）：去掉三处 `exec` 行的
   `2>/dev/null`（失败已有 `|| return 1` 处理，错误信息留在 stderr 是期望行为），
   或改用 `{fd}>"$lock_file"` 动态分配。修好后本节 5.2 的“无效选项”文案在
   完整菜单流程里即可见（组件本身已由独立用例验证正确）。
2. **业务函数返回值口径（既有）**：`install_*` / `uninstall_*` 末尾是无 else
   的 `if apply_inbound …; fi`，`apply_inbound` 失败时函数仍返回 0。此时
   `ui_msg_ok` 会按返回值呈现成功，但 `config_transaction` 已在上方打印
   `log_err`（jq 失败行），用户可见真实错误。本阶段按任务要求以真实返回值为
   准、不动业务函数；彻底修好需给业务函数补显式 `else return 1`，建议后续
   整改任务处理（`install_all_protocols` 依赖同一信号，同样受益）。
3. **卸载时状态清理失败按业务口径视为成功**：业务函数自认“可忽略，状态会在
   下次操作时自动修复”且返回 0，故 `ui_msg_ok` 与之口径一致，未另行判错。
4. **卸载项标红丢失**：见第四节第 4 条（`ui_menu_select` 无单项颜色参数）。
5. **真机验证待做**：iPhone Termius / Xshell 等真实终端下的方向键、反显、
   边框对齐仍需用户真机验证（沙箱仅以 `script` 伪终端验证）。
6. Phase 1 已知限制沿用：`ui_menu_select` 不可重入、临时接管调用方 trap
   （退出时恢复）、Esc 判定依赖 0.05 秒超时、无 `stty` 时降级行输入。

## 七、交接

- Phase 2 主菜单 / Phase 3b 其余页面可复用本阶段模式：状态面板
  （`ui_menu_head` + 状态行 + `ui_bot`）与 `ui_menu_select` 分离渲染，
  默认选中末项（空输入返回），按 `UI_SEL_KEY` 分发，结果按真实返回值
  呈现 `ui_msg_*`。
- 建议优先处理第六节第 1 条 stderr 吞没 bug：它影响**所有**行模式提示
  （含主菜单与全部子菜单），且修复仅三行。
- socks5“查看参数”是否加入菜单、以及第 2 条业务函数返回值收紧，待产品决定。
