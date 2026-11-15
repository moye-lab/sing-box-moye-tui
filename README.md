# sing-box-moye

轻量、状态驱动的 sing-box 多协议一键管理脚本。

一个命令装好 VLESS-Reality / Hysteria 2 / TUIC / AnyTLS / Cloudflare Argo，jq 状态机记住所有参数，重装不丢配置；节点命名、订阅导出、系统调优一气呵成。

## 功能

- **五类节点协议**：VLESS-Reality-Vision、Hysteria 2、TUIC v5、Cloudflare Argo、AnyTLS
- **SOCKS5 参数管理**：独立管理 sing-box SOCKS5 入站，仅展示服务器、端口、用户名、密码，面向 Telegram 等 App 手动配置；不作为节点导出
- **状态机驱动**：`/etc/sing-box/state.json` 持久化已装协议与参数，安装幂等、卸载干净，随时可看随时可改
- **智能节点命名**：首次运行自动 GeoIP 探测；识别到 Oracle/Google/AWS/Azure/Cloudflare 直接用厂商全名（如 `Oracle-Reality`），其他用「国家-主机名-协议」（如 `US-RN-Reality`，主机名保留原始大小写）；命名中心（菜单 `9`）支持自动命名、手动前缀与重新探测，`sbx rename "前缀"` 一行搞定
- **多格式导出**：标准 URI 链接、Base64 聚合订阅、Mihomo YAML、Sing-box outbounds JSON、终端二维码；新增带随机令牌的在线订阅 HTTP 服务
- **遥测仪表盘**：核心版本与运行状态、PID / 内存占用、BBR 状态、公网 IP / ASN 一屏尽览
- **系统调优**：一键开启 BBR + QUIC/UDP 缓冲区扩容，Hy2 端口跳跃一键配置
- **WARP 与域名分流**：VPS 原生 IP 被 AI 服务封锁时，一键安装 Cloudflare WARP 出站，把 Gemini / ChatGPT 等域名走 WARP 出口绕过封锁；内置 AI 解锁预设域名，也可自定义分流列表
- **快捷键操作**：主菜单数字与字母双通道（`1/r` `2/h` `3/t` `4/a` `5/p` `6/y` `7/i` `8/e` `9/n` `10/o` `11/s` `12/d` `13/w` `x` `0/q`）

## 环境要求

- root 权限，使用 systemd 的 Linux 发行版
- 支持架构：x86_64、aarch64/arm64、armv7（具体二进制可用性以 sing-box/cloudflared 上游发布为准）
- Debian / Ubuntu（apt）、Fedora/RHEL 系（dnf/yum）可自动安装基础依赖；其他发行版需手动准备依赖
- 必需依赖：bash、curl、jq、openssl、tar、python3、iptables、systemd；qrencode 为可选依赖
- sing-box 内核缺失时自动下载最新正式版；下载仅允许 HTTPS，并检查压缩包格式与路径
- 本项目依赖 systemd 管理服务，不支持 OpenWrt procd、Alpine OpenRC 或无 systemd 容器直接部署

## 安装

### 方式一：一键安装（推荐）

```bash
bash <(wget -qO- https://raw.githubusercontent.com/moye-lab/sing-box-moye/v1.7.0/install.sh)
```

或（无 wget 时用 curl）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/moye-lab/sing-box-moye/v1.7.0/install.sh)
```

### 方式二：源码克隆安装

```bash
git clone https://github.com/moye-lab/sing-box-moye.git
cd sing-box-moye
sudo bash install.sh
```

### 方式三：发布包安装（无需 git）

```bash
curl -fsSL https://github.com/moye-lab/sing-box-moye/archive/refs/tags/v1.7.0.tar.gz -o sing-box-moye.tar.gz
tar -xzf sing-box-moye.tar.gz
cd sing-box-moye
sudo bash install.sh
```

安装完成后，交互式终端会进入管理面板；非交互环境会直接结束安装。之后随时输入 `sbx` 即可打开。

## 使用

### Modern TUI

管理面板是方向键驱动的现代终端界面（无需鼠标、无 ncurses 依赖）：

- **主界面**：顶部品牌头 + `SYSTEM OVERVIEW` 状态仪表盘（核心状态/版本/进程/内存、公网 IP/归属地/ASN、网络引擎、WARP 状态），下方分四组导航：协议矩阵（Reality/Hy2/TUIC/AnyTLS/Argo/SOCKS5/一键全装）、节点与订阅、网络与路由、系统管理。协议行带实时状态与参数摘要（如 `已启用 · TCP · 443 · www.microsoft.com`）。
- **方向键导航**：`↑`/`↓` 移动高亮，`Enter` 确认，`Esc` 返回，`q` 退出；数字/字母快捷键仍可直达（`1`–`13`、`r h t a p y i e n o s d w`），两位数快捷键快按两位即可（如连按 `1` `2` 进诊断，单按 `1` 停顿则进 Reality）。
- **宽度自适应**：120 列以上宽屏、80 列默认、60 列紧凑、40 列窄屏（仪表盘退化单列）、30 列以下纯文本降级，面板内容永不越界。可用 `SBM_COLS=100 sbx` 强制指定宽度。
- **颜色与字符集**：`NO_COLOR=1` 关闭颜色（也优先于强制颜色）；`SBM_ASCII=1` 强制 ASCII 边框（非 UTF-8 终端自动降级）；`SBM_FORCE_COLOR=1` 在非 TTY 下强制颜色。非 TTY（管道/脚本）自动降级为行输入模式，菜单行为与交互式一致。
- **确认与进度**：危险操作（彻底卸载、WARP 卸载）用带边框确认框，默认取消；耗时操作有阶段提示与状态药丸（`● 运行中` / `○ 未安装`，颜色 + 文字双通道）。

### 节点命名

命名规则：识别到知名云厂商（Oracle/Google/AWS/Azure/Cloudflare，以 ASN 精确匹配优先、运营商名称兜底）时，前缀直接用厂商全名，如 `Oracle-Reality`；识别不到时用「国家代码-主机名」，如 `US-RN-Reality`。主机名读取系统 `hostname -s` 并保留原始大小写。协议短名统一为 `Reality` / `Hy2` / `TUIC` / `Argo`；Argo 多优选 IP 按 `-1`、`-2` 编号。节点名仅在命名中心（菜单 `9`）选「重新探测」时刷新；也可以 `sbx rename "前缀"` 手动指定前缀（协议短名自动追加）。


| 命令 | 说明 |
|------|------|
| `sbx` | 打开管理面板 |
| `sbx r` | 安装 / 管理 VLESS-Reality |
| `sbx h` | 安装 / 管理 Hysteria 2 |
| `sbx t` | 安装 / 管理 TUIC v5 |
| `sbx a` | 安装 / 管理 AnyTLS（需 sing-box ≥ 1.12.0，版本不足自动升级） |
| `sbx p` | 安装 / 管理 Cloudflare Argo（含临时隧道域名刷新） |
| `sbx y` | 安装 / 管理 SOCKS5（仅参数展示，不进节点导出） |
| `sbx w` | WARP 与域名分流（解锁 AI 服务） |
| `sbx all` | 一键安装常用节点协议（Reality+Hy2+TUIC+AnyTLS，默认配置；不含 SOCKS5·Argo） |
| `sbx rename "US-vps01"` | 设置自定义节点前缀（协议短名自动追加） |
| `sbx e` | 重新生成并查看所有节点导出 |
| `sbx o` | 一键开启 BBR + UDP 缓冲区调优 |
| `sbx version` | 查看当前版本 |
| `sbx doctor` | 检查依赖、状态文件与 sing-box 配置 |
| `sbx subscription enable` / `disable` | 启停在线订阅服务 |
| `sbx <协议> del` | 卸载指定协议（如 `sbx h del`） |

节点协议安装后可导出链接、Base64 聚合订阅、二维码、Mihomo 配置块与 Sing-box 配置到 `/etc/sing-box/export/`。SOCKS5 不属于节点体系，不会进入任何节点导出或在线订阅内容。

### WARP 与域名分流

有些 VPS 的原生 IP 被 AI 服务封锁（如 Gemini 提示地区不可用），此时可通过 WARP 绕过：

1. 主菜单选 `13/w` 进入「WARP 与域名分流」，选 `1` 安装 WARP（自动注册 Cloudflare 账号，生成 WireGuard 出站）
2. 选 `2` 应用「AI 解锁分流」预设，选择分流模式：
   - **精简模式**（推荐，28 个域名）：只分流 AI 专用域名（gemini.google.com、openai.com、claude.ai 等），普通 Google 搜索、Gmail、YouTube 不受影响
   - **兼容模式**（33 个域名）：精简模式 + google.com/googleapis.com/accounts.google.com，解决某些 AI 服务需要完整 Google 生态的问题
3. 也可手动添加自定义域名（空格分隔，后缀匹配，子域名自动覆盖）
4. 选 `1/c` 可进行 5 层健康检查（配置 → 服务 → 分流规则 → 实际流量测试），验证 WARP 是否真正连通

原理：WARP 是 Cloudflare 的免费 VPN 出口，IP 信誉好，AI 服务一般不拦。分流只对列表里的域名生效，其他流量仍走 VPS 直连，不影响节点速度。

注意：Claude（anthropic.com/claude.ai）会屏蔽 Cloudflare WARP IP，如需使用请将其从分流列表中移除，走 VPS 原生 IP。

## 彻底卸载

主菜单选 `x`，一次确认后删除 sing-box 内核、全部协议配置与系统服务，管理命令 `sbx` 本体保留。

## 自检与测试

运行 `sbx doctor` 可检查基础依赖、状态文件结构、sing-box 配置与服务状态。开发者可执行 `bash tests/smoke.sh` 运行 Shell 语法、状态管理、订阅服务、Mihomo YAML / Sing-box JSON 导出及 URL 编码回归测试（需要 jq、Python 3 和 PyYAML）。

## 项目结构

```
core/        # env（配色/日志/工具函数）、state_manager（jq 状态机）、json_builder（配置合成）、engine（内核安装/卸载）、ui（终端 UI 组件库）
protocols/   # reality / hysteria2 / tuic / argo 节点模块；socks5 参数管理模块
utils/       # cert（自签/ACME 证书）、sysctl（BBR/端口跳跃）、export（多格式导出）
templates/   # base.json 基础配置模板
sbx.sh       # 管理面板主入口
install.sh   # 一键安装脚本
```

## 说明

- Reality / Hy2 / TUIC 默认监听端口可自定义，支持输入 `r` 随机生成
- Hy2 / TUIC 默认生成 ECC 自签名证书（客户端开启「跳过证书验证」即可用），也可走 ACME 申请真实域名证书
- Hy2 端口跳跃规则通过 systemd 持久化，开机自动恢复；重装与卸载时自动清理
- Argo 固定隧道 Token 以 600 权限的 EnvironmentFile 存放，不再出现在 systemd unit 与进程参数中
- Argo 临时隧道：VPS 或进程重启后域名变更，面板启动与订阅导出时自动同步最新域名（菜单也有手动刷新）
- Argo 固定隧道需在 Cloudflare Zero Trust 后台将 Public Hostname 指向 `HTTP://127.0.0.1:<本地回环端口>`


## 协议与订阅功能说明

### SOCKS5 代理参数
- sing-box 原生 SOCKS5 inbound，默认端口 1080，支持 TCP 与 UDP associate。
- 强制用户名密码认证；每次安装生成高强度随机密码，用户名限制为安全字符集。
- 主菜单 `[6/y] SOCKS5`（协议矩阵）支持安装、重装、卸载；「节点订阅中心」内可随时查看手动配置参数。
- 安装完成后立即显示服务器、端口、用户名、密码，并提示 Telegram 的手动添加路径。
- SOCKS5 不属于节点体系：不进入 `links.txt`、Base64 在线订阅、Mihomo YAML 或 Sing-box 客户端 outbounds。
- 建议通过防火墙限制来源地址，不要将代理端口直接暴露给整个公网。

### 在线订阅链接
- 在“节点订阅中心 → 在线订阅服务”启用；也可执行 `sbx subscription enable`。
- 使用 256-bit 随机令牌作为订阅路径凭据；错误令牌返回 404，响应禁止缓存。
- 订阅内容动态读取最新 `links.txt` 并以 Base64 返回，新增/删除节点后无需重启订阅服务。
- 默认监听 `127.0.0.1:8765`，避免未经配置就暴露公网。需要直接远程访问时可显式绑定 `0.0.0.0`，但 HTTP 不加密；**生产环境必须通过 HTTPS 反向代理访问**，并建议加防火墙来源限制；订阅 URL 本身等同密码，勿公开分享。
- `sbx subscription disable` 会停止服务并撤销令牌；完整卸载也会清理订阅服务。

### 安全说明
订阅服务是轻量只读交付端点，不是通用 Web 面板。请勿将明文 HTTP 订阅地址用于不可信网络。SOCKS5 用户名密码及协议私钥保存在权限受限的 `/etc/sing-box` 状态文件中。


## 开发与安全

- 许可证：MIT（见 `LICENSE`）。
- 贡献流程：`CONTRIBUTING.md`。
- 安全问题处理：`SECURITY.md`。请勿公开提交凭据、私钥或订阅令牌。


## 部署边界与隐私

- 首次初始化会向 `ipwho.is` 请求公网 IP、国家/城市、ASN 及运营商（isp/org）信息，用于厂商识别、节点命名与仪表盘展示；公网 IP 查询也会访问 `api.ipify.org`。这些请求是可选的网络探测，但当前版本尚未提供完全离线的 GeoIP 开关。
- 管理器以 root 运行 sing-box，以便监听低端口并读取证书；状态文件、订阅令牌和配置文件应保持仅 root 可读。
- 安装器不会自动修改系统防火墙规则。部署前请自行确认云厂商安全组与主机防火墙已按协议放行 TCP/UDP 端口。
- Reality / Hy2 / TUIC 的证书、SNI、端口以及服务器公网地址必须符合实际网络环境；成功生成配置不等于公网链路已连通。
- 订阅服务默认绑定 `127.0.0.1`；若确需公网监听，必须显式选择 `0.0.0.0`，并使用 HTTPS 反代与来源访问控制。
