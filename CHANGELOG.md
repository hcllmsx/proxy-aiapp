# 更新日志

## v26.11.6

- 修复：Gemini 版本目录改为按版本号逐级比较选取，避免版本号位数变化（如 `app-1.9.0` 与 `app-1.10.0`）时误指向旧版本目录。
- 新增：卸载时自动清理 Gemini 升级后遗留的旧版本目录中的代理文件，只删除本工具投放过的文件，不影响应用自身内容。
- 优化：安装或卸载后自动重启应用时，应用日志改为写入临时日志文件，不再混入安装工具终端；操作完成后的「按回车继续」提示独立提行显示。
- 优化：CLI 代理目录定位改为按文件名精确过滤，明显缩短 Antigravity 安装与卸载的耗时。
- 优化：启动时检测到新版本会先显示独立提示画面并列出更新要点，按任意键直接打开下载页面，避免提示被主界面刷新带走。

## v26.11.1

- 新增：支持微软商店版 Claude Desktop（`Claude.exe`），安装脚本按包名动态定位 `WindowsApps` 下的商店包目录，无需手工填写路径。
- 新增：安装与卸载前自动关闭对应应用进程（先尝试优雅关闭窗口），投放完成后自动重新拉起；卸载同时清理日志目录。
- 新增：加载成功弹窗提示「软件每次更新后，需要重新注入」。
- 新增：安装脚本启动时自动检查一次更新，配置页面同步静默检查，发现新版本时在页脚提示；版本一律以已发布的 Release 为准。
- 新增：安装 Antigravity 时自动识别同机的 CLI 版（`agy.exe` / `antigravity-cli.exe`）并就位投放代理，卸载时同步清理；未安装 CLI 时不做任何改动。
- 优化：配置页「生效目标软件」增加 Claude 卡片并展示商店包实际安装路径，界面图标改用应用真实图标。
- 优化：`target_processes` 默认值补充 `Claude.exe`、`cowork-svc.exe`，商店应用的常驻子进程同样纳入注入范围。
- 修复：安装脚本检查更新改为按版本号逐级比较，仅在确实存在新版本时提示，下载地址固定展示 GitHub 官方 Releases 页面。

## v26.10.21

- 新增：全面支持 Google Gemini 桌面客户端（`Gemini.exe`）、`Antigravity.exe` 与 `Antigravity IDE.exe` 统一代理。
- 修复：修复 Chromium `NetworkService` 非阻塞 `connect()` 同步返回 `0` 触发 `TCPSocketWin::DoConnect()` 断点崩溃（`0x80000003`）的问题。
- 新增：补齐 `ioctlsocket`、`WSAEventSelect`、`WSAEnumNetworkEvents`、`getpeername`、`GetAddrInfoExW` Hook，完整保持非阻塞套接字与事件通知语义。
- 优化：启用 FakeIP 时自动拦截进程内绕过系统解析器的自定义 53 端口探测，促使 Chromium `NetworkService` 自动回退至 `GetAddrInfoW` 走 FakeIP 域名映射。
- 新增：全新设计的可视化配置页面，默认采用极简模式（一键选择 V2RayN / Clash 预设或填写地址端口即可生成配置），支持一键切换高级模式。
- 新增：支持一键自动检测本机已安装的 Antigravity、Antigravity IDE 与 Google Gemini 桌面版目录，实现一键部署、更新配置与卸载。
