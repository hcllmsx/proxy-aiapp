# Proxy-AiApp

面向 Windows 平台的 AI 客户端透明网络代理注入工具（`version.dll`），目前已原生支持 **Google Gemini Desktop (`Gemini.exe`)**、**Antigravity (`Antigravity.exe`)** 与 **Antigravity IDE (`Antigravity IDE.exe`)**，后续规划扩展支持更多桌面 AI 客户端。

## 项目特性

- **一处构建，三端通用**：同时适配 Google Gemini 桌面端（原生 Chromium 非阻塞 `WSAEventSelect` 套接字）与 Antigravity / Antigravity IDE（Electron + Go Language Server）。
- **FakeIP 域名透明还原**：接管 DNS 解析并阻断 Chromium 内置直连 UDP 53 查询，将目标域名以 `Domain` 类型完整封装进 SOCKS5 握手或 HTTP CONNECT 请求，无需开启 TUN/虚拟网卡即可正常分流。
- **简单 / 高级双模式配置器**：内置可视化配置器 `config-web.html`，默认提供「简单模式」，连接本地服务后支持在网页内直接保存配置并一键安装到目标软件。
- **交互式安装工具**：通过 `install.bat` 自动检测本机已安装的 Gemini、Antigravity 与 Antigravity IDE 路径，支持一键全部安装、按软件自定义安装、卸载与检查更新。

## 快速使用

### 1. 使用 `install.bat` 一键配置与安装（推荐）

解压发布包后，双击运行 `install.bat`，脚本会自动扫描本机已安装的 **Google Gemini**、**Antigravity** 和 **Antigravity IDE** 状态：

- **`[1] 打开网页配置`（直接按回车默认执行）**：
  - 自动启动本地直写服务并在浏览器打开配置页面（页面顶部显示「本地直写服务已连接」）。
  - 在默认的 **简单模式** 下选择代理预设（如 V2RayN `10808` / Clash `7890`）或填写自定义端口。
  - 点击右下角 **「保存并一键安装到勾选软件」**，即可直接将 `config.json` 与 `version.dll` 部署到对应软件目录；或点击 **「直接保存 config.json」** 仅更新当前目录配置文件。
- **`[2] 一键安装全部`**：将当前目录的 `version.dll` 与 `config.json` 一键安装到本机所有已检测到的目标软件。
- **`[3] 自定义安装`**：进入二级菜单，单独选择安装到 Google Gemini、Antigravity 或 Antigravity IDE（按 `0` 返回主菜单）。
- **`[4] 卸载已安装代理`**：进入二级菜单，支持一键全部卸载或按软件单独卸载（按 `0` 返回主菜单）。
- **`[5] 检查更新`**：检查 GitHub 仓库最新发布版本。
- **`[0] 退出`**：关闭安装工具。

### 2. 手动部署（可选）

如果不使用脚本，也可以直接将 `version.dll` 与配置好的 `config.json` 复制到目标软件可执行文件所在目录：
- **Google Gemini**：`%LOCALAPPDATA%\Google\Gemini\app-<版本号>\`
- **Antigravity**：`%LOCALAPPDATA%\Programs\Antigravity\`
- **Antigravity IDE**：`%LOCALAPPDATA%\Programs\Antigravity IDE\`

## 致谢

- **[antigravity-proxy](https://github.com/yuaotian/antigravity-proxy)**：本项目的核心 C++ 代理注入底座直接衍生（Fork）自该项目，在此基础上扩展了 Google Gemini 桌面端（Chromium `NetworkService` 与非阻塞 `WSAEventSelect` 套接字）支持及双模式直写配置器，特此致谢。
- **[AntigravityProxyLauncher](https://github.com/OpsinTech/AntigravityProxyLauncher)**：在适配 Gemini 桌面端非阻塞连接状态伪装与 DNS 拦截方案时参考了其设计思路。

## 开源许可

本项目采用 [GPL-3.0](LICENSE) 开源协议发布。
