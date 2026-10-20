# 更新日志

## v26.10.21

- 新增：全面支持 Google Gemini 桌面客户端（`Gemini.exe`）、`Antigravity.exe` 与 `Antigravity IDE.exe` 统一代理。
- 修复：修复 Chromium `NetworkService` 非阻塞 `connect()` 同步返回 `0` 触发 `TCPSocketWin::DoConnect()` 断点崩溃（`0x80000003`）的问题。
- 新增：补齐 `ioctlsocket`、`WSAEventSelect`、`WSAEnumNetworkEvents`、`getpeername`、`GetAddrInfoExW` Hook，完整保持非阻塞套接字与事件通知语义。
- 优化：启用 FakeIP 时自动拦截进程内绕过系统解析器的自定义 53 端口探测，促使 Chromium `NetworkService` 自动回退至 `GetAddrInfoW` 走 FakeIP 域名映射。
- 新增：全新设计的可视化配置页面，默认采用极简模式（一键选择 V2RayN / Clash 预设或填写地址端口即可生成配置），支持一键切换高级模式。
- 新增：支持一键自动检测本机已安装的 Antigravity、Antigravity IDE 与 Google Gemini 桌面版目录，实现一键部署、更新配置与卸载。
