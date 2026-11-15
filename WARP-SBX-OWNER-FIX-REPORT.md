# WARP 分流 sbx_owner 修复报告

- 修复日期：2026-11-15
- 触发：用户真机实测（RN，2026-11-15 16:50）
- 影响：WARP AI 分流应用失败（精简模式 28 域名、兼容模式 33 域名均受影响）
- 版本：1.7.0（TUI 分支，未升版本）

## 一、问题现象

用户在 RN 上进入 WARP 菜单 → AI 解锁分流 → 精简模式（28 个 AI 域名），报错：

```
Sing-box 配置语法校验未通过！已放弃本次更改。
路由规则更新失败，正在恢复原状态...
```

分流规则应用失败，WARP 分流功能完全不可用。

## 二、根因（已证实）

第二轮复审整改（P0 第 4 项）在 `core/json_builder.sh` 的 `apply_route_rules` 函数中，给 WARP 路由规则添加了 `sbx_owner: "warp"` 字段，用于标识规则归属：

```json
{"action": "sniff", "sbx_owner": "warp"}
{"action": "resolve", "domain_suffix": [...], "strategy": "prefer_ipv4", "sbx_owner": "warp"}
{"domain_suffix": [...], "outbound": "warp", "sbx_owner": "warp"}
```

但 sing-box 的配置 schema 使用严格 JSON 解码，不认未知字段。实测（sing-box 1.14.4）：

```
FATAL[0000] decode config: route.rules[0].sbx_owner: json: unknown field "sbx_owner"
```

`sing-box check` 失败 → `config_transaction` 回滚 → 分流应用失败。

**教训**：sing-box 配置中绝不能写入任何自定义字段。规则归属标识必须用结构特征（outbound tag、domain_suffix 匹配），不能靠自定义字段。

## 三、修复方案

### 3.1 移除 sbx_owner

`apply_route_rules` 写入 config.json 的规则中不再包含任何自定义字段：

```json
{"action": "sniff"}
{"action": "resolve", "domain_suffix": [...], "strategy": "prefer_ipv4"}
{"domain_suffix": [...], "outbound": "warp"}
```

### 3.2 结构识别替代方案

删除 WARP 规则时按结构特征识别：

| 规则类型 | 识别方式 |
|---|---|
| 出站规则 | `.outbound == "warp"`（tag 匹配） |
| resolve 规则 | `action == "resolve"` 且 `domain_suffix` 与任一 WARP 出站规则的 `domain_suffix` 完全一致（数组深比较，用 `any(. == $ds)`，不用 `index`——jq 的 `index` 对数组元素无效） |
| sniff 规则 | 写入时删除所有裸 `{action: "sniff"}`（避免重复写入积累），清空时保留（通用无害，下次写入时清理） |

### 3.3 用户规则保护

以下规则一律保留：

- 其他出站的规则（如 `outbound: "direct"`）
- 其他域名的 resolve 规则（如 `domain_suffix: ["other.com"]`）
- 带额外字段的 sniff 规则（WARP 的 sniff 是裸 `{action: "sniff"}`，用户自定义的 sniff 若有额外字段则不受影响）

### 3.4 jq 实现要点

```jq
# 收集 WARP 出站规则的 domain_suffix 集合
(.route.rules // []) as $r
| ([$r[] | select(.outbound == $ob) | .domain_suffix]) as $wd
| .route.rules = [$r[] | select(
    .outbound != $ob
    and (.action != "resolve" or ((.domain_suffix) as $ds | ($wd | any(. == $ds)) | not))
  )]
```

注意：`index` 对数组元素返回 null，必须用 `any(. == $ds)` 做数组深比较。

## 四、测试结果

### 4.1 新增测试

`tests/warp_sbx_owner_fix_test.sh`：**18/18 通过**

- 写入 WARP 规则不含 sbx_owner（5 项）
- 真实 sing-box 1.14.4 check 通过 + run 无 FATAL（2 项）
- 更新规则：旧清除、新写入、裸 sniff 不积累（4 项）
- 清空规则：WARP 清除、用户规则保留（4 项）
- 重复写入不积累（2 项）
- 清空后 sing-box check 仍通过（1 项）

### 4.2 端到端验证

模拟用户真实场景（28 个 AI 域名精简模式）：

- `apply_route_rules` 成功
- sbx_owner 字段数：0
- sing-box check 通过
- sing-box run 无 FATAL
- 规则数：3，域名数：28

### 4.3 既有套件全过

| 套件 | 结果 |
|---|---|
| ui_test.sh | 74/74 |
| round2_regression.sh | 15/15（原 13 项 + 2 新增断言） |
| termius_fix_test.sh | 30/30 |
| panel_nav_test.sh | 39/39 |
| warp_test.sh | 通过 |
| export_test.sh | 通过 |
| bash -n 全项目 | 通过 |

### 4.4 round2 测试更新

`tests/round2_regression.sh` 测试 3 已更新为结构识别：

- 移除 `sbx_owner` 断言，改为检查 `.outbound == "warp"` 和 domain_suffix 匹配
- 新增断言：配置中无 `sbx_owner` 字段
- 用户规则测试数据改用有效字段（原 `sniff_override_destination` 不是 route rule 的有效字段，会导致 sing-box check 失败）

## 五、修改文件

| 文件 | 改动 |
|---|---|
| `core/json_builder.sh` | `apply_route_rules` 重写：移除 sbx_owner，改用结构识别 |
| `tests/round2_regression.sh` | 测试 3 更新为结构识别断言 |
| `tests/warp_sbx_owner_fix_test.sh` | 新增（18 项） |
| `CHANGELOG.md` | 增加修复条目 + 修正第二轮 P0 条目 |
| `WARP-SBX-OWNER-FIX-REPORT.md` | 本报告 |

## 六、注意事项

1. **主线同样受影响**：该 bug 同时存在于主线 v1.7.0（moye-lab/sing-box-moye），因为第二轮整改同时推到了两边。本次只修 TUI 分支，主线修复由主代理另行处理。
2. **已部署机器**：RN 等已装 v1.7.0 的机器上，若之前尝试应用分流失败，配置未被修改（事务回滚保护），直接升级到修复版即可。无需手动清理。
3. **孤儿 sniff 规则**：清空分流后会留下一条裸 sniff 规则（通用无害），下次写入分流时会自动清理。
