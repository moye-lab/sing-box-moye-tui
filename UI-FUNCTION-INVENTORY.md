# UI-FUNCTION-INVENTORY.md — 现有功能清单（Phase 0）

全部功能必须在 UI 重构后保留。来源：sbx.sh CLI 分发 + 各菜单函数。

## 协议管理（6 + 1）

| 协议 | 安装 | 卸载 | 修改参数 | 特殊能力 |
|---|---|---|---|---|
| VLESS-Reality | ✓ | ✓ | SNI 修改 | UUID/私钥自动生成 |
| Hysteria 2 | ✓ | ✓ | — | 证书（自签/ACME/已有）、UDP 端口跳跃 |
| TUIC v5 | ✓ | ✓ | — | 证书 |
| AnyTLS | ✓ | ✓ | — | 需 sing-box ≥ 1.12.0（自动升级） |
| Cloudflare Argo | ✓ | ✓ | 优选 IP（多 IP 逗号分隔）、模式切换 | 临时隧道（默认）/固定 Token 隧道 |
| SOCKS5 | ✓ | ✓ | 参数查看 | 参数-only，不进节点导出、不进订阅 |
| 一键全装 | Reality+Hy2+TUIC+AnyTLS | — | — | 已安装跳过；SOCKS5/Argo 不在内 |

## 节点与订阅

- 节点订阅中心：分享链接、二维码（qrencode 可选依赖）、Mihomo YAML、Sing-box JSON、Base64 聚合订阅
- 在线订阅服务：启停、监听地址（默认 127.0.0.1，显式 opt-in 0.0.0.0）、端口（默认 8765）、令牌
- 节点命名：自动命名（ASN 厂商识别 Oracle/Google/AWS/Azure/Cloudflare；未知用 `{CC}-{hostname}`）、手动前缀、重新探测、当前前缀展示
- 节点导出：URI / Base64 / 二维码；`export_all_nodes` 刷新导出文件

## 网络与路由

- WARP：安装（直接调 Cloudflare API 注册）、卸载、健康检查（5 层）、AI 解锁分流（精简 28 域 / 兼容 33 域）、自定义域名增删、清空规则
- 网络调优：BBR 启用、UDP 缓冲区、Hy2 端口跳跃配置/恢复/清理

## 系统管理

- 内核服务维护：升级内核（SHA256 校验、失败回滚）、重启服务、实时日志（journalctl -n 30）
- 运行环境诊断：依赖、状态文件、配置校验、内核、服务状态
- 彻底卸载：销毁所有配置与系统服务（危险操作，需确认）

## CLI（硬性兼容）

```
sbx | sbx r | sbx h | sbx t | sbx a | sbx p | sbx y | sbx w | sbx all
sbx rename "US-vps01" | sbx e | sbx o | sbx version | sbx doctor
sbx subscription enable | sbx subscription disable | sbx h del
```

另有：`sbx <proto> del`（各协议卸载）、`sbx subscription`（状态）、`sbx export|info`、
`sbx bbr`、`sbx check`、`sbx -v|--version`。用法文本见 sbx.sh `sbx_main`。
