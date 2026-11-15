# 运维与故障恢复

## 部署前检查

1. 确认系统使用 systemd，且当前架构受上游 sing-box 发布包支持。
2. 确认 80/443/8443/9443 等计划使用的端口没有被其他服务占用。
3. 在云安全组和主机防火墙中分别放行对应协议的 TCP 或 UDP 端口。
4. 为生产环境准备可信 TLS 证书；自签证书需要客户端明确允许跳过验证。
5. 备份 `/etc/sing-box/`，其中包含配置、状态、私钥和证书。

## 更新与回滚

- 管理面板的内核升级会先下载到临时目录，再用新内核检查现有配置。
- 新内核替换后若服务无法启动，会尝试恢复旧二进制。
- 升级前仍建议手动备份：`cp -a /etc/sing-box /etc/sing-box.backup`。
- 若服务异常，先执行 `sbx doctor`，再查看 `journalctl -u sing-box -n 100 --no-pager`。
- 不要在未备份的情况下手工删除 `/etc/sing-box/state.json` 或证书目录。

## 常用检查

```bash
sbx doctor
systemctl status sing-box --no-pager
journalctl -u sing-box -n 100 --no-pager
sing-box check -c /etc/sing-box/config.json
ss -tulpn
```

## 卸载

菜单中的“彻底卸载”会删除 sing-box、管理器相关服务、配置、证书和状态数据。它不会清理用户自行配置的云安全组/主机防火墙规则，也不会自动删除 `~/.acme.sh` 中的 ACME 账户与证书缓存。执行前请备份需要保留的数据。
