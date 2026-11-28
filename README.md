# Proxy-AiApp

## ⚠️ 我可能发现了一些比较离谱的问题

### 1. 请下载发行版使用，不要直接克隆本仓库

本仓库**不包含编译好的 `version.dll` 等二进制文件**，直接克隆后运行 `install.bat` 是用不了的。如果你是新手小白，只想开箱即用：

1. 扫描下方二维码，下载发布版压缩包（免编译、开箱即用）；
2. 解压到任意目录；
3. 双击运行 `install.bat`，按菜单提示操作即可。

> 发布包内含编译好的 `version.dll`、`install.bat`、配置器等全部文件，解压即可使用。

<p align="center">
  <img src="docs/media/quark-proxy-aiapp.jpeg" alt="夸克网盘下载二维码" width="200">
</p>

### 2. 本项目不是「梯子」，不能翻墙

- **Proxy-AiApp 只是一个「代理注入器」**：它的作用是把 AI 客户端（Google Gemini、Antigravity、Claude Desktop）与聊天客户端（WhatsApp 等）的网络请求，转发到你**本机已经在运行的代理软件**（如 V2RayN、Clash 的 SOCKS5 / HTTP 端口）上。
- **你必须自备可用的代理软件并保持运行**，本项目本身不提供任何代理节点或翻墙能力。
- 没有梯子的情况下，装上本项目也**无法直连** Google Gemini、Claude 等需要特殊网络环境的服务。

---

面向 Windows 平台的 AI 客户端透明网络代理注入工具（`version.dll`），目前已原生支持以下客户端：

| 客户端 | 进程名 | 形态 / 备注 |
| --- | --- | --- |
| Google Gemini Desktop | `Gemini.exe` | 原生 Chromium，非阻塞 `WSAEventSelect` 套接字 |
| Antigravity | `Antigravity.exe` | Electron + Go Language Server |
| Antigravity IDE | `Antigravity IDE.exe` | Electron + Go Language Server |
| Claude Desktop | `Claude.exe` | 微软商店版（Electron / Chromium 包应用） |
| WhatsApp | `WhatsApp.Root.exe` | 微软商店版（.NET + WinUI + WebView2），需用启动器快捷方式启动 |
| Antigravity CLI | `agy.exe`、`antigravity-cli.exe` | 终端命令版，安装时自动识别其所在目录并投放 |

## 项目特性

- **一处构建，多端通用**：同时适配 Google Gemini 桌面端（原生 Chromium 非阻塞 `WSAEventSelect` 套接字）、Antigravity / Antigravity IDE（Electron + Go Language Server）、商店版 Claude Desktop（Electron/Chromium 包应用）与商店版 WhatsApp（.NET + WinUI + WebView2）。
- **FakeIP 域名透明还原**：接管 DNS 解析并阻断 Chromium 内置直连 UDP 53 查询，将目标域名以 `Domain` 类型完整封装进 SOCKS5 握手或 HTTP CONNECT 请求，无需开启 TUN/虚拟网卡即可正常分流。
- **商店应用自动识别**：安装时动态定位 `%ProgramFiles%\WindowsApps` 下的商店包目录（包名带版本号且随更新变化），无需手工填写路径。
- **WhatsApp 免切换代理**：商店版 WhatsApp 的包目录不可写，改由 `ProxyLauncher.exe` 在启动瞬间完成运行时注入，**不需要开 TUN，也不需要手动切系统代理**，本机代理软件保持运行即可。
- **简单 / 高级双模式配置器**：内置可视化配置器 `index.html`，默认提供「简单模式」，连接本地服务后支持在网页内直接保存配置并一键安装到目标软件。
- **交互式安装工具**：通过 `install.bat` 自动检测本机已安装的各目标软件路径，支持一键全部安装、仅安装未安装软件、卸载与检查更新；安装 Antigravity 时若本机装有 CLI 版，会一并投放到命令所在目录；投放前自动关闭对应应用并在完成后重新拉起，应用更新后重新执行一次安装即等于重新注入。

## 快速使用

### 1. 使用 `install.bat` 一键配置与安装（推荐）

解压发布包后，双击运行 `install.bat`，脚本会自动扫描本机已安装的 **Google Gemini**、**Antigravity**、**Antigravity IDE**、**Claude Desktop** 和 **WhatsApp** 状态：

- **`[1] 打开网页配置`（直接按回车默认执行）**：
  - 自动启动本地直写服务并在浏览器打开配置页面（页面顶部显示「本地直写服务已连接」）。
  - 在默认的 **简单模式** 下选择代理预设（如 V2RayN `10808` / Clash `7890`）或填写自定义端口。
  - 点击右下角 **「保存并一键安装到勾选软件」**，即可直接将 `config.json` 与 `version.dll` 部署到对应软件目录；或点击 **「直接保存 config.json」** 仅更新当前目录配置文件。
- **`[2] 一键安装全部`**：将 `core/` 目录下的 `version.dll` 与 `config.json` 一键安装到本机所有已检测到的目标软件。
- **`[3] 仅安装未安装软件`**：自动筛选本机已检测到但尚未注入代理的目标软件并一键补装（不会重复关闭已安装软件）。
- **`[4] 卸载已安装代理`**：进入二级菜单，支持一键全部卸载或按软件单独卸载，同时清理日志目录（按 `0` 返回主菜单）。
- **`[5] 检查更新`**：检查 GitHub 仓库最新发布版本。
- **`[0] 退出`**：关闭安装工具。

> 安装过程会关闭对应软件窗口并写入文件，请先保存未提交的内容；商店应用（Claude Desktop）更新后代理会失效，重新运行一次安装即可。

### 3. 商店版 WhatsApp：用快捷方式启动

微软商店版 WhatsApp 的安装目录在 `%ProgramFiles%\WindowsApps\` 下，受系统写保护，**无法把 `version.dll` 直接投放进去**。本项目为它单独提供了 `core\ProxyLauncher.exe` 启动器，走的是「运行时注入」：

- 安装时勾选 **WhatsApp**（或在网页配置页勾选后点「保存并一键安装到勾选软件」），脚本会创建 **「WhatsApp（代理）」** 快捷方式（开始菜单 + 桌面），并把检测到的应用标识写回 `config.json`。
- **请务必用这个快捷方式启动 WhatsApp**。启动器会在应用起来的瞬间注入代理，并追踪注入承载聊天界面与网络栈的 WebView2 进程。
- 效果：**不用开 TUN 模式，也不用手动切换系统代理**，只要本机代理软件（V2RayN / Clash 等）保持运行，WhatsApp 就能正常收发消息。
- 启动器与代理的运行日志位于 `core\logs\`（`launcher-*.log` 与 `proxy-*.log`），排查问题时先看这里。

> 直接从开始菜单启动原版 WhatsApp 是不会走代理的——它没有注入任何东西。

### 2. 手动部署（可选）

如果不使用脚本，也可以直接将 `core/` 目录下的 `version.dll` 与配置好的 `config.json` 复制到目标软件可执行文件所在目录：
- **Google Gemini**：`%LOCALAPPDATA%\Google\Gemini\app-<版本号>\`
- **Antigravity**：`%LOCALAPPDATA%\Programs\Antigravity\`
- **Antigravity IDE**：`%LOCALAPPDATA%\Programs\Antigravity IDE\`
- **Claude Desktop**：`%ProgramFiles%\WindowsApps\Claude_<版本号>_x64__pzs8sxrjxfjjc\app\`

> 商店版 WhatsApp 无法手动部署，请使用上面的「WhatsApp（代理）」快捷方式。

## 致谢

- **[antigravity-proxy](https://github.com/yuaotian/antigravity-proxy)**：本项目的核心 C++ 代理注入底座直接衍生（Fork）自该项目，在此基础上扩展了 Google Gemini 桌面端（Chromium `NetworkService` 与非阻塞 `WSAEventSelect` 套接字）支持及双模式直写配置器，特此致谢。
- **[AntigravityProxyLauncher](https://github.com/OpsinTech/AntigravityProxyLauncher)**：在适配 Gemini 桌面端非阻塞连接状态伪装与 DNS 拦截方案时参考了其设计思路。

## 开源许可

本项目采用 [GPL-3.0](LICENSE) 开源协议发布。
