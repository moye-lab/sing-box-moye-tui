# WARP 出口验证状态持久化修复报告

**日期**：2026-11-15
**分支**：sing-box-moye-tui（TUI 实验分支），版本保持 1.7.0
**状态**：已完成，全部验证通过，未推送

---

## 一、问题（用户真机实测，2026-11-15 19:16）

在 RN 上运行 WARP 健康检查 `[1/c]`，五层全部通过：

```
[5/5] 实际流量测试 ...
      · 测试域名 www.cloudflare.com 已临时加入分流（测试后自动移除）
      ✓ 出口 IP 104.28.195.192，WARP 状态：on
✓ WARP 隧道连接正常，流量已走 Cloudflare 出口。
```

但返回 WARP 菜单后，顶部状态区仍显示：

```
出口验证  ● 未验证  选 [1/c] 检测实时出口
```

健康检查结果没有持久化，菜单状态不更新。

## 二、根因

`protocols/warp.sh` 两处脱节：

1. `warp_check()` 执行完测试后没有把结果保存到 state（只打印日志、返回退出码）。
2. WARP 菜单渲染代码（`menu_warp` 约 628–635 行）写死了“未验证”：
   ```bash
   if ! state_has_proto "socks5"; then
       verify_txt="无法验证 未安装 SOCKS5"
   elif (( WARP_M_DOMAINS == 0 )); then
       verify_txt="无法验证 分流列表为空"
   else
       verify_txt="未验证 选 [1/c] 检测实时出口"  # 永远显示未验证
   fi
   ```
   菜单渲染没有读取任何验证状态字段。

## 三、修复方案

### 1. `warp_check()` 持久化验证结果（`protocols/warp.sh`）

新增两个辅助函数：

- `_warp_save_verification <ip>`：保存 `verified_at`（当前 Unix 时间戳）与 `verified_ip`（出口 IP）到 state 的 `protocols.warp` 段。
- `_warp_clear_verification()`：清空上述两个字段。

各返回路径的处理：

| 返回码 | 场景 | 处理 |
|---|---|---|
| 0 | 隧道正常（warp=on 或 Cloudflare IP 段） | 保存验证结果 |
| 1 | WARP 未安装 / 配置中无 warp 端点 | 清除验证状态 |
| 2 | sing-box 服务未运行 | 清除验证状态 |
| 3 | 隧道不通（trace 失败 / 非 Cloudflare 出口 / 临时域名添加失败 / 第 2 层结构异常伴随无 SOCKS5 或无分流域名） | 清除验证状态 |
| 4 | UNKNOWN（无 SOCKS5 或分流列表为空，且前 4 层无失败） | 不改动（保持原值） |

设计说明：

- 返回 1/2 时清除：端点缺失或服务停运意味着隧道确定不可用，旧的“已验证”已过期，继续显示会误导用户。任务书只明确了 0/3/4 的处理，1/2 按同一原则（确定性失败清除、不确定性保留）处理。
- 返回 4 时保留：UNKNOWN 表示“无法验证”，不是“验证失败”，旧结果仍有参考价值。
- 成功/失败的保存与清除放在 `warp_check` 末尾单返回点（临时分流列表恢复之后），与现有的单返回点结构一致。

### 2. 菜单渲染读取验证状态

- `_warp_menu_status()` 新增 `WARP_M_VERIFIED_AT` / `WARP_M_VERIFIED_IP` 两个全局变量，从 state 读取 `verified_at` / `verified_ip`。
- `menu_warp()` 的 `verify_txt` 构造增加已验证分支：
  - SOCKS5 未装或分流为空 → “无法验证（原因）”（优先级高于已验证状态，因为此时的“无法验证”结论比过期的验证结果更准确）
  - `verified_at` 与 `verified_ip` 均非空 → `已验证 <IP>（<相对时间>）`，绿色 ok 药丸
  - 否则 → “未验证 选 [1/c] 检测实时出口”（保持原样）
- 新增 `_warp_format_ago <时间戳>`：把 Unix 时间戳转成友好中文相对时间——<60 秒“刚刚”、<1 小时“N 分钟前”、<1 天“N 小时前”、否则“N 天前”；无效输入或未来时间返回“刚刚”。
- 卸载 WARP 时验证状态随 `state_del_proto "warp"` 一并清除（整个 warp 段删除，无需额外处理）。
- 分流域名变更时不清除验证状态：验证的是隧道本身（出口 IP）是否可用，与分流列表内容无关。

### 3. 注释同步

- `_warp_menu_status` 上方的注释更新：从“出口恒标未验证”改为“显示上次 [1/c] 检测的持久化结果”。
- CHANGELOG 中 TUI 页面重构条目同步更新（原“出口恒标‘未验证’”）。

## 四、测试结果

| 套件 | 结果 |
|---|---|
| **新增 `tests/warp_verify_persist_test.sh`** | **48/48** |
| ui_test.sh | 74/74 |
| round2_regression.sh | 15/15 |
| termius_fix_test.sh | 30/30 |
| panel_nav_test.sh | 39/39 |
| warp_sbx_owner_fix_test.sh | 18/18 |
| warp_healthcheck_fix_test.sh | 36/36 |
| warp_test.sh / export_test.sh / anytls_test.sh / smoke.sh / install_all_test.sh / version_check.sh / ui_twokey_test.sh | 全部通过 |
| bash -n 全项目 | 通过 |

新增测试覆盖（48 项，分 10 组）：

1. `_warp_format_ago` 时间格式化（13 项：刚刚/分钟/小时/天边界、无效输入、空输入、未来时间）
2. warp_check 成功（warp=on）后 state 中有 verified_at（数字、5 秒内）与 verified_ip（104.28.195.192）
3. warp_check 失败（warp=off）后验证状态被清除（返回 3）
4. warp_check 失败（curl 超时）后验证状态被清除（返回 3）
5. UNKNOWN（无 SOCKS5）时不改动已有验证状态（返回 4）
6. UNKNOWN（分流列表为空）时不改动已有验证状态（返回 4）
7. 服务未运行时清除验证状态（返回 2）
8. `_warp_menu_status` 能读取验证状态到 WARP_M_VERIFIED_* 变量，清除后为空
9. 菜单渲染逻辑：已验证时显示 IP 和相对时间；无验证时显示未验证；SOCKS5 未装/分流为空时“无法验证”优先于旧的已验证状态；5 分钟前的验证显示“5 分钟前”
10. 卸载 WARP 后验证状态随 state 删除而清除

测试方法：沿用 `warp_healthcheck_fix_test.sh` 的模式——PATH 中的伪造 `curl` 可执行文件（`FAKE_CURL_MODE` 控制 warp_on/warp_off/fail 三态）、mock `systemctl`、真实 sing-box 1.14.4 做配置校验（`_commit_config` 内 `sing-box check`）。

### 测试中发现并修复的两个测试代码 bug

1. **state.json 手写缺字段**：最初手写 state.json 缺 `installed_protocols` 数组，`init_state_file` 报“状态文件损坏”。改用 `init_state_file` + `state_set_proto` 构建状态（与现有测试一致）。
2. **`${1:-["a","b"]}` 引号吞没**：`setup_env` 的默认值 `${1:-["ai.google.dev","gemini.google.com"]}` 被 bash 解析时吃掉内层双引号，生成无效 JSON `[ai.google.dev,gemini.google.com]`，`warp_set_domains` 静默失败（被 `|| true` 掩盖），分流列表始终为空，warp_check 返回 UNKNOWN(4)。改用变量存默认值再展开（与项目已记录的 `${3:-{}}` 裸大括号教训同类）。测试文件内已加注释说明。

## 五、修改文件（`~/workspace/tui_work`，版本保持 1.7.0，未推送）

- `protocols/warp.sh`：新增 `_warp_format_ago`、`_warp_save_verification`、`_warp_clear_verification`；`warp_check` 各返回路径保存/清除验证状态；`_warp_menu_status` 读取验证状态；`menu_warp` 渲染已验证分支
- `tests/warp_verify_persist_test.sh`：新增（48 项）
- `CHANGELOG.md`：增加修复条目 + 修正 WARP 菜单旧描述
- `WARP-VERIFY-PERSIST-FIX-REPORT.md`：本报告

## 六、用户侧验证步骤（RN）

1. 重装 TUI 分支：
   ```bash
   bash <(wget -qO- https://raw.githubusercontent.com/moye-lab/sing-box-moye-tui/v1.7.0-tui/install.sh)
   ```
2. 进 WARP 菜单，顶部应显示“出口验证 ● 未验证”（首次，未检测过）。
3. 选 `[1/c]` 检测 WARP 出口，五层通过后返回菜单，顶部应显示：
   ```
   出口验证  ● 已验证  104.28.195.192（刚刚）
   ```
4. 退出 sbx 再重新进入，仍应显示已验证（持久化）与相对时间（几分钟后变为“N 分钟前”）。

## 七、注意事项

1. **主线 v1.7.0 存在同一 bug**（主线菜单也有写死的“未验证”），本次只修 TUI 分支，需另行同步到主线。
2. 验证状态是“上次检测结果”，不是实时状态：隧道在两次检测之间断开时，菜单仍显示旧的已验证结果，直到下次 `[1/c]` 检测。这是设计取舍（菜单渲染不做耗时流量测试），菜单底部仍保留“服务运行中不等于出口正常，出口状态以 [1/c] 实时检测为准”的提示。
3. `verified_at`/`verified_ip` 存储在 state 的 `protocols.warp` 段，随 WARP 卸载一并删除；重装 WARP 后需重新检测。
