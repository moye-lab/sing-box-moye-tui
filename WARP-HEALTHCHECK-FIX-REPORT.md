# WARP 健康检查误报修复报告

- 日期：2026-11-15
- 分支：TUI 实验分支（`sing-box-moye-tui`，v1.7.0-tui），主线 v1.7.0 同样受影响，需另行修复
- 修改文件：`protocols/warp.sh`
- 新增测试：`tests/warp_healthcheck_fix_test.sh`（36 项）

## 一、问题（RN 真机实测，2026-11-15 17:28）

WARP 已安装，分流规则已应用（28 个 AI 域名，精简模式），运行健康检查
`[1/c]`，前 4 层全部通过，第 5 层失败：

```
[1/5] 配置存在性 ...  ✓ WARP 端点已在配置中
[2/5] 配置结构 ...    ✓ 私钥格式正常，地址 172.16.0.2/32，Reserved [73,214,142]
[3/5] 服务运行 ...    ✓ sing-box 服务运行中
[4/5] 分流规则 ...    ✓ 找到 1 条 WARP 分流规则
[5/5] 实际流量测试 ...
      ✗ 出口 IP 107.175.220.79 不是 Cloudflare，WARP 状态：off
        可能原因：分流未生效，或隧道不通
```

## 二、根因

`protocols/warp.sh` 的 `warp_check()` 第 5 层逻辑错误（修前代码）：

1. 第 294–295 行从 state 读取 `test_domain`（分流列表第一个域名），
   但后续代码完全没用上这个变量；
2. 第 311 行硬编码测试 `https://www.cloudflare.com/cdn-cgi/trace`；
3. `www.cloudflare.com` 不在 28 个 AI 分流域名列表中，trace 请求走直连
   （不经过 WARP），Cloudflare trace 必然返回 RN 原生 IP 和 `warp=off`；
4. 健康检查据此误报“隧道不通”，实际上是测试方法错误，与隧道状态无关。

## 三、修复方案（方案 A：临时加入测试域名）

测试前检查 `www.cloudflare.com` 是否在分流列表中：

- **不在**：临时加入（`warp_set_domains`，状态 + 配置原子提交，
  失败时该函数内部已回滚），测试后恢复原列表；
- **已在**：不做任何改动，不触发多余的服务重载。

关键实现细节（`protocols/warp.sh`）：

1. **单返回点结构**：第 5 层测试结果先存入 `rc` 变量，所有分支走完后
   统一执行恢复再 `return $rc`，保证每条路径都恢复原列表。
2. **RETURN trap 安全网**：新增 `_warp_check_restore_temp_domains`
   （用 `_WARP_CHECK_TEMP_ADDED` / `_WARP_CHECK_ORIG_DOMAINS` 两个全局
   变量记录状态，可重复调用、无临时添加时为空操作），在临时添加前安装
   为 RETURN trap。注意 `warp_set_domains` 内部会把 RETURN trap 覆盖为
   `_state_unlock`，所以每次调用它之后都必须重新安装恢复 trap。
3. **显式恢复优先**：正常路径下先 `trap - RETURN` 清除 trap、清零标志，
   再调用 `warp_set_domains` 恢复；恢复失败时明确报错（提示手动移除
   测试域名），不静默。
4. **临时添加失败**：清除 trap、清零标志，直接返回 3（`warp_set_domains`
   内部已回滚状态，无需额外恢复）。
5. **无分流域名时行为不变**：仍返回 UNKNOWN(4)，不调用 curl。
6. 临时添加/恢复各触发一次服务重载（`warp_set_domains` 经
   `config_transaction` 重载 sing-box），每次健康检查最多 2 次额外重载；
   trace 域名已在列表中时 0 次。

## 四、测试结果

新增 `tests/warp_healthcheck_fix_test.sh`（36/36 通过）：

| 场景 | 断言 |
|---|---|
| A. warp=on | 返回 0；输出含 warp=on；伪造 curl 调用瞬间 trace 域名在规则内；检查后 state/配置恢复原 3 域名；临时添加+恢复共 2 次重载 |
| B. warp=off | 返回 3；输出含“不是 Cloudflare”；测试期间 trace 域名在规则内（阴性结果可信，非测试方法问题）；state/配置恢复 |
| C. curl 失败 | 返回 3；输出含“超时或失败”；state/配置恢复 |
| D. trace 域名已在列表 | 返回 0；无“临时加入”提示；0 次重载；state 与配置规则字节一致 |
| E. 28 域名精简模式端到端 | warp=on 返回 0；trace 域名临时在规则内；检查后恢复 28 个；`www.cloudflare.com` 已移除；真实 sing-box 1.14.4 check 通过 + run 无 FATAL |
| F. 无分流域名 | 返回 4；curl 未被调用 |
| G. RETURN trap 安全网 | 恢复函数直接验证：恢复 state/配置、标志清零、重复调用为空操作 |

测试方法说明：

- `warp_check` 经 `timeout 10 curl` 发请求，`timeout` 是外部命令，
  shell 函数 mock 无效，因此测试用 PATH 中的伪造 `curl` 可执行文件，
  行为由 `FAKE_CURL_MODE`（warp_on / warp_off / fail）控制；伪造 curl
  在每次调用时检查 `$SB_CONFIG`，记录 trace 域名是否在 warp 规则内。
- 真实 sing-box 1.14.4 二进制验证配置有效性（check + run 无 FATAL）。

既有套件全过：ui_test 74/74、round2_regression 15/15、
termius_fix 30/30、panel_nav 39/39、warp_sbx_owner_fix 18/18、
warp_test 通过、export/anytls/smoke/install_all/version_check/ui_twokey
全部通过；全项目 `bash -n` 通过。

## 五、用户侧验证（RN 上重装后）

```bash
bash <(wget -qO- https://raw.githubusercontent.com/moye-lab/sing-box-moye-tui/v1.7.0-tui/install.sh)
```

重装后进 WARP 菜单选 `[1/c] 检测 WARP 出口`：第 5 层应显示
“测试域名 www.cloudflare.com 已临时加入分流”，随后返回
“出口 IP 104.x.x.x，WARP 状态：on”（隧道正常时）。检查后分流列表应
仍为原来的 28 个 AI 域名（`[5/l] 查看分流列表` 验证，不应多出
`www.cloudflare.com`）。

## 六、已知限制

1. 健康检查在 trace 域名不在列表时触发 2 次 sing-box 服务重载
   （临时添加 + 恢复），每次约 1 秒；检查总耗时增加约 2 秒。
2. 若恢复步骤本身失败（极端情况，如磁盘写满），state 与配置可能短暂
   不一致（state 已恢复、配置仍含测试域名），下一次分流操作会纠正；
   失败时已明确报错提示手动检查。
3. 主线 v1.7.0 存在同一 bug，本次只修 TUI 分支，需另行同步到主线。
