# 更新日志

## v26.11.28

- 新增：支持微软商店版 WhatsApp（`WhatsApp.Root.exe`）。其安装目录位于 `WindowsApps` 下受系统写保护，无法像其它客户端那样投放 `version.dll`，改为随包提供 `ProxyLauncher.exe` 启动器：激活应用后立即注入代理，并按后代链追踪注入承载聊天界面与网络栈的 WebView2 进程，**无需开启 TUN 模式或手动切换系统代理，只要本机代理软件在运行即可正常收发消息**。
- 新增：支持微软商店版 ChatGPT（`ChatGPT.exe` + `codex.exe`）。同样因包目录写保护而走启动器注入，Electron 的网络服务进程与负责 API 通信的 `codex.exe` 都会被纳入注入范围，`chatgpt.com` / `ws.chatgpt.com` / `codex-cloud-backend.chatgpt.com` 等域名均走本地代理。
- 优化：启动器由「写死 WhatsApp」改为按目标通用，支持 `--target whatsapp|chatgpt` 选择目标，多个商店应用共用同一个 `ProxyLauncher.exe`；卸载其中一个目标时不会误删共用启动器与其它目标的快捷方式。
- 优化：配置器新增 ChatGPT 卡片，与 WhatsApp 一样以「启动器注入」方式成对开关其进程条目。
- 修复：ChatGPT 点登录报 `failed to start login server ... (os error 10013)` 的问题。ChatGPT 登录时会在本机启动 OAuth 回调服务器（`http://localhost:1455`，候选端口 `1455` / `1457` 写死在应用内），若这些端口被系统排除（Hyper-V / WSL / 容器等虚拟化组件会按 100 个一组动态预留低端口区）则 bind 失败、登录必然报错——**该故障与代理注入无关，不注入同样失败**。安装工具与配置页现会自动检测此类端口冲突，并在安装时直接给出可执行的修复命令。

## v26.11.26

- 修复：Antigravity 与 Antigravity IDE 的内置浏览器（Chromium `NetworkService` 子进程）纳入全量代理 Hook，无需额外添加 `--proxy-server` 启动参数即可与 AI 对话共用同一代理；本地回环通信继续走早期直连旁路。
- 优化：安装工具主菜单第 3 项由「自定义安装」改为「仅安装未安装软件」，可一键为尚未注入代理的目标软件补装，无需逐个选择。
- 优化：安装工具的新版本提示画面、取消更新后主界面的新版本提示行及手动检查更新的新版本提示统一改为红色高亮，并支持在提示画面按 `Esc` / `N` 取消更新直接进入主界面。

## v26.11.24

- 优化：安装工具的软件列表中，「未安装」状态改为黄色高亮显示，便于快速识别尚未注入代理的目标软件。

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
