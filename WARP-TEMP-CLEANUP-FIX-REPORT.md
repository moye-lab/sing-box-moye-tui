# WARP 健康检查临时域名清理修复报告

- 日期：2026-11-15
- 分支：TUI 实验分支（`sing-box-moye-tui`，v1.7.0-tui），主线 v1.7.0 同样受影响，需另行修复
- 修改文件：`protocols/warp.sh`、`core/json_builder.sh`、`CHANGELOG.md`
- 新增测试：`tests/warp_temp_cleanup_test.sh`（53 项）

## 一、问题（RN 真机实测，2026-11-15 19:29）

用户运行 WARP 健康检查 `[1/c]`，`[5/5]` 实际流量测试超时失败后，在恢复
阶段按 Ctrl+C（sing-box 重载耗时较长，误以为卡死），结果：

1. 分流域名从 28 个变成 29 个（`www.cloudflare.com` 临时测试域名未移除），
   分流模式从“精简模式”变成“自定义”；
2. 用户按 Ctrl+C 后 sbx 退出到 shell；
3. 用户 19:31 重新安装了 WARP（状态显示“未安装”，原因未定位，见 §七）。

```text
[5/5] 实际流量测试 ...
      ✗ 流量测试超时或失败（隧道可能不通）
^C
root@RN:~#
```

## 二、根因

`protocols/warp.sh` 的显式恢复代码（修前约 429–433 行）顺序错误：

```bash
if (( temp_added )); then
    trap - RETURN                    # 先清 trap
    _WARP_CHECK_TEMP_ADDED=0         # 先清标志
    _WARP_CHECK_ORIG_DOMAINS=""      # 先清原列表
    if ! warp_set_domains "$cur_domains_json" >/dev/null 2>&1; then
        log_err "恢复原分流列表失败..."
```

恢复代码先清除 trap 和状态标志，再调用 `warp_set_domains`。而
`warp_set_domains` 内部要走配置事务 + `systemctl reload/restart`（耗时较长，
且旧代码无超时保护），用户容易误以为卡死而按 Ctrl+C。此时安全网已经撤掉：

- RETURN trap 已清除，函数返回时不再重试恢复；
- `_WARP_CHECK_TEMP_ADDED` 已清零，恢复函数即使被调用也是空操作；
- `_WARP_CHECK_ORIG_DOMAINS` 已清空，原列表丢失；
- 临时域名永久留在分流列表中（28 → 29 个），且没有任何持久化标记能让
  下次检查识别出这是残留。

`_warp_check_restore_temp_domains` 本身也有同样的顺序问题（先清标志再恢复）。

## 三、修复方案（五层防御）

### 1. 恢复顺序调换（`_warp_check_restore_temp_domains` 重写）

先调用 `warp_set_domains` 恢复，成功后才清除 state 标记、内存标志与 trap：

```bash
if ! warp_set_domains "$orig" >/dev/null 2>&1; then
    log_err "恢复原分流列表失败，测试域名 ... 可能仍在列表中，请进分流菜单手动移除。"
    return 1
fi
# 恢复验证（见 §三.3）...
state_set_field "warp" "temp_trace_added" "" 2>/dev/null || true
_WARP_CHECK_TEMP_ADDED=0
_WARP_CHECK_ORIG_DOMAINS=""
trap - RETURN
return 0
```

失败时返回 1 且保持标志，`warp_check` 的显式恢复处据此记录
`restore_failed=1`，在函数返回前重新安装 RETURN trap（验证持久化会覆盖
它，故放在最后），安全网再试一次。state 中的 `temp_trace_added` 标记保留，
下次检查入口清理还会再试。

### 2. INT/TERM trap（`_warp_check_on_interrupt`）

第 5 层域名变更窗口（入口清理 → 临时添加 → 测试 → 恢复）全程安装
INT/TERM trap，保存调用方旧 trap：

```bash
_warp_check_on_interrupt() {
    trap - INT TERM
    _warp_check_restore_temp_domains
    exit 130
}
```

Ctrl+C 时先恢复临时域名，再按惯例以 130 退出（与旧行为一致：用户按
Ctrl+C 后回到 shell）。处理函数开头先重置信号 trap，第二次 Ctrl+C 立即
退出。恢复走 `warp_set_domains`（含 15 秒超时保护的服务重载），有界不会
无限等待；若恢复仍失败，state 标记保留，下次检查入口清理再试。

退出窗口的所有正常路径（SOCKS5 缺失、分流为空、临时添加失败、正常完成）
都调用 `_warp_check_remove_interrupt_trap` 恢复调用方旧 trap，不残留进
菜单循环。状态锁与配置锁均为深度计数可重入，中断处理函数中再次调用
`warp_set_domains` 不会死锁；进程退出时 fd 关闭，flock 由内核释放。

### 3. 恢复验证

`warp_set_domains` 返回成功后，用 jq 深比较确认 state 中的分流列表确实
回到原值（防并发改写/静默失败）：

```bash
if ! jq -e --argjson orig "$orig" '.protocols.warp.domains == $orig' "$SB_STATE" >/dev/null 2>&1; then
    log_err "恢复验证失败：原分流 ${orig_count} 个域名，当前 ${cur_count} 个，..."
    return 1
fi
```

验证失败时返回 1（保持标志，走与恢复失败相同的重试链），并打印原/当前
域名数量，提示手动移除。

### 4. 超时保护（`core/json_builder.sh` 新增 `_systemctl_timed`）

`reload_singbox_service` 的 reload/restart 改走带超时保护的调用，默认
15 秒（`SBX_SYSTEMCTL_TIMEOUT` 可覆盖）：

```bash
_systemctl_timed() {
    if [[ "$(type -t systemctl)" == "function" ]] || ! command -v timeout >/dev/null 2>&1; then
        systemctl "$@"
    else
        timeout "${SBX_SYSTEMCTL_TIMEOUT:-15}" systemctl "$@"
    fi
}
```

超时返回 124，调用方按失败处理（回滚/报错），不再无限等待。测试环境
systemctl 常被 mock 为 shell 函数，`timeout` 是外部命令调不到函数，故函数
mock 或系统无 `timeout` 命令时直接调用。此改动位于共享的
`reload_singbox_service`，所有配置事务（不止 WARP）都受益。

### 5. 幂等入口清理（`_warp_check_cleanup_stale_trace_domain`）

state 中新增 `temp_trace_added` 标记：临时添加前设置（在调用
`warp_set_domains` 之前先写标记，中断发生在任何一步都能被识别），恢复
成功后清除。每次 `warp_check` 进入第 5 层时先检查：

- 标记为 1 且测试域名在列表中 → 移除该域名（`warp_set_domains`），清标记；
- 标记为 1 但域名已不在列表（上次恢复成功、清标记时被中断）→ 只清标记；
- 标记为空 → 不做任何事（用户手动添加的 `www.cloudflare.com` 无标记，
  不会被误删）。

清理放在 SOCKS5 检查之前：清理只依赖 `warp_set_domains`，不依赖 SOCKS5，
未装 SOCKS5 时也能把残留清掉。清理失败时保留标记、打印错误，本次检查仍
可继续（测试域名已在列表中，无需临时添加），下次检查再试。

## 四、测试

新增 `tests/warp_temp_cleanup_test.sh`（53 项，全部通过），分 8 组：

| 组 | 内容 | 关键断言 |
|---|---|---|
| A | Ctrl+C 中断恢复阶段（用户真机场景） | `set -m` + 进程组 SIGINT 真实模拟；进程以 130 退出；state/配置恢复原 3 个；标记清除；中断处理又做了一次恢复重载 |
| B | 恢复失败注入（`SYSTEMCTL_FAIL_AFTER=1`） | 明确报错含“手动移除”；报错至少 2 次（显式 + RETURN trap 重试）；标记保持 1；重载次数证明重试过 |
| C | 入口清理（接 B 的污染状态） | 输出“残留的测试域名”“残留测试域名已清理”；state/配置恢复原 3 个；标记清除 |
| D | 用户手动添加的测试域名 | 不触发残留清理；不触发临时添加；4 个域名原样保留 |
| E | 标记残留但域名已不在列表 | 只清标记；检查正常返回 0 |
| F | 恢复函数单元测试 | 成功路径返回 0、标志/标记清零；失败路径返回 1、标志与标记保持、输出明确报错；服务恢复后重试成功 |
| G | `_systemctl_timed` 超时 | 函数 mock 时直接调用；慢速二进制 systemctl 在 2 秒超时返回 124，实际耗时 < 10 秒 |
| H | trap 不残留 | 正常检查后 `trap -p INT/TERM` 为空 |

测试方法说明：

- **Ctrl+C 真实模拟**：`set -m`（作业控制）下后台任务自成进程组且 SIGINT
  不被忽略（无作业控制时 bash 会把后台任务的 SIGINT 设为忽略，`trap - INT`
  也无法恢复，沙箱实测确认）；用延迟 3 秒的 mock systemctl 制造恢复时间窗
  口，轮询重载计数到 2（恢复重载已开始）后 `kill -INT -<pgid>`，完整复现
  用户操作。
- **恢复失败注入**：mock systemctl 的 `SYSTEMCTL_FAIL_AFTER=N` 让前 N 次
  reload/restart 成功、之后服务起不来（`is-active` 失败 → 事务回滚 →
  `warp_set_domains` 失败）。
- **锁排空前置**：测试 A 启动 helper 子进程前，先排空父进程泄漏的锁深度
  （见 §六），否则子进程拿不到状态锁。

回归（全部通过）：

| 套件 | 结果 |
|---|---|
| ui_test.sh | 74/74 |
| round2_regression.sh | 15/15 |
| termius_fix_test.sh | 30/30 |
| panel_nav_test.sh | 39/39 |
| warp_sbx_owner_fix_test.sh | 18/18 |
| warp_healthcheck_fix_test.sh | 36/36 |
| warp_verify_persist_test.sh | 48/48 |
| warp_temp_cleanup_test.sh（新增） | 53/53 |
| bash -n 全项目 | 通过 |

## 五、用户侧验证（RN）

```bash
bash <(wget -qO- https://raw.githubusercontent.com/moye-lab/sing-box-moye-tui/v1.7.0-tui/install.sh)
```

1. 进 WARP 菜单跑 `[1/c]`：若上次残留的 `www.cloudflare.com` 还在列表中，
   应先看到“发现上次检查残留的测试域名 …，正在清理…”和“残留测试域名已
   清理”，分流恢复 28 个、模式回“精简模式”；
2. 正常跑完 `[1/c]` 后，分流列表仍为 28 个，不多出测试域名；
3. （可选）第 5 层测试期间按 Ctrl+C：应退出到 shell，下次再跑 `[1/c]`
   时入口清理自动处理残留，分流列表不再多出测试域名。

## 六、测试中发现的遗留问题（未修，另行跟踪）

**状态锁泄漏**（`warp_set_domains` 等混合函数）：`warp_set_domains` 设置
`RETURN` trap 为 `_state_unlock`，随后调用的 `config_transaction` 将其覆盖
为 `_config_unlock`，函数返回时只触发了 `_config_unlock`，`_state_unlock`
永不触发，状态锁（fd 200 + flock）泄漏，深度计数永久 +1。沙箱实测：
`warp_set_domains` 后 `_STATE_LOCK_HELD=1 _STATE_LOCK_DEPTH=1`，fd 200 仍
打开，子进程拿锁阻塞超时。

影响：单进程内无影响（锁可重入，深度只增不减）；多进程并发（如两个终端
同时跑 sbx）时会互相阻塞 10 秒。所有混合状态+配置的函数（各协议安装/卸载）
都有同样问题，属系统性遗留问题，不在本次任务范围内，建议另开任务统一
修复（例如 `config_transaction` 返回前恢复调用方 trap，或改用显式 unlock
而非 RETURN trap）。

## 七、未定位：Ctrl+C 后 WARP 显示“未安装”

用户 19:29 截图后、19:31 截图显示 WARP 状态为“未安装”，随后重新安装了
WARP。本次修复未定位该现象的原因。已知信息：

- state 写入是原子的（临时文件 + `mv`），Ctrl+C 不可能写坏 state.json；
- `init_state_file` 遇损坏 state 时拒绝操作、不会重置为空，不会造成
  “未安装”；
- 临时域名残留本身不影响 `warp_installed` 判定（只看 warp 端点与协议）。

可能与用户在两次截图之间的其他操作有关，或与重装过程中的状态有关。
如再次出现，需用户提供当时的 `jq . /etc/sing-box/state.json` 与
`jq .endpoints /etc/sing-box/config.json` 输出定位。

## 八、注意事项

1. **主线 v1.7.0 存在同一 bug**，本次只修 TUI 分支，需另行同步到主线。
2. 验证状态是“上次检测结果”而非实时状态（见 WARP-VERIFY-PERSIST-FIX-REPORT.md
   §注意事项 2），本次修复不改变该设计。
3. 健康检查在 trace 域名不在列表时触发 2 次 sing-box 服务重载（临时添加 +
   恢复），每次重载现均有 15 秒超时保护；入口清理如触发，会额外增加 1 次
   重载。
