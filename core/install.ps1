param(
    [switch]$Web,
    [switch]$Status,
    [switch]$CheckUpdate,
    [switch]$InstallAll,
    [switch]$UninstallAll,
    # 开发工具复用：只处理 Antigravity CLI 代理，不触碰任何目标应用
    [switch]$CliInstall,
    [switch]$CliUninstall,
    [string[]]$CliSlotKeys = @()
)

# Proxy-AiApp 安装工具 · 基于 GPL-3.0 协议开源
# 作者：莫莫先生 (hcllmsx) · B站：https://space.bilibili.com/255947051

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$CoreDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppRoot = Split-Path -Parent $CoreDir
Set-Location $AppRoot

$ConfigFile = Join-Path $CoreDir "config.json"
$WebFile    = Join-Path $AppRoot "index.html"
$GithubRepo = "hcllmsx/proxy-aiapp"
$CurrentVer = "26.11.6"

# ---------------------------------------------------------------------------
# 微软商店（MSIX / UWP）应用目标
# 包目录名带版本号且随更新变化，运行时通过 Get-AppxPackage 动态发现，
# 应用自更新后重新执行一次安装即等于重新注入。
# ---------------------------------------------------------------------------
$MsixApps = @(
    [PSCustomObject]@{
        Key          = "claude"
        Name         = "Claude Desktop"
        ExeName      = "Claude.exe"
        PackageNames = @("Claude")
        SubDir       = "app"
        ProcessNames = @("Claude")
    }
)

function Get-DllSourcePath {
    $coreDll = Join-Path $CoreDir "version.dll"
    if (Test-Path $coreDll) { return $coreDll }
    $buildDll = Join-Path $AppRoot "_temp\build-x64\Release\version.dll"
    if (Test-Path $buildDll) { return $buildDll }
    $rootDll = Join-Path $AppRoot "version.dll"
    if (Test-Path $rootDll) { return $rootDll }
    return $null
}

# 取商店包的应用目录（多版本并存时取版本最高者）
function Get-MsixSlotDirectory {
    param(
        [string[]]$PackageNames,
        [string]$SubDir
    )
    $best = $null
    foreach ($name in $PackageNames) {
        $pkgs = @()
        try { $pkgs = @(Get-AppxPackage -Name $name -ErrorAction Stop) } catch { $pkgs = @() }
        if ($pkgs.Count -eq 0) {
            # 个别环境 -Name 精确匹配失败，退回全量列举后自行过滤
            try { $pkgs = @(Get-AppxPackage -ErrorAction Stop | Where-Object { $_.Name -eq $name }) } catch { $pkgs = @() }
        }
        foreach ($p in $pkgs) {
            if ([string]::IsNullOrWhiteSpace($p.InstallLocation)) { continue }
            $dir = if ($SubDir) { Join-Path $p.InstallLocation $SubDir } else { $p.InstallLocation }
            if (-not (Test-Path $dir)) { continue }
            $ver = [version]"0.0"
            if ($p.Version) { [void][version]::TryParse([string]$p.Version, [ref]$ver) }
            if (-not $best -or $ver -gt $best.Version) {
                $best = [PSCustomObject]@{ Directory = $dir; Version = $ver }
            }
        }
    }
    if ($best) { return $best.Directory }

    # 兜底：Get-AppxPackage 不可用（如被裁剪的 Appx 模块）时直接扫描 WindowsApps
    $root = Join-Path $env:SystemRoot "Program Files\WindowsApps"
    foreach ($name in $PackageNames) {
        $cands = @(Get-ChildItem -Path $root -Directory -Filter "$name*" -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        foreach ($c in $cands) {
            $dir = if ($SubDir) { Join-Path $c.FullName $SubDir } else { $c.FullName }
            if (Test-Path $dir) { return $dir }
        }
    }
    return $null
}

# 关闭该应用正在运行的进程：投放 version.dll 前必须释放文件占用。
# 返回 $true 表示确实关掉了进程（调用方据此决定是否重新拉起）。
function Stop-SlotProcesses {
    param([PSCustomObject]$Slot)
    $names = @($Slot.ProcessNames)
    if ($names.Count -eq 0) { return $false }
    $targets = @()
    foreach ($n in $names) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            $src = ""
            try { $src = [string]$p.Path } catch { $src = "" }
            # 能取到路径时只处理本应用目录内的进程，避免误杀同名程序（例如 claude CLI、codex CLI）
            if ($src -and $Slot.Directory) {
                if (-not $src.StartsWith(($Slot.Directory + "\"), [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            }
            $targets += $p
        }
    }
    if ($targets.Count -eq 0) { return $false }
    Write-Host ("  [*] 关闭 {0}：{1} 个进程（先优雅关闭窗口，未保存的内容请先自行保存）" -f $Slot.Name, $targets.Count) -ForegroundColor DarkGray
    foreach ($p in $targets) {
        try { $null = $p.CloseMainWindow() } catch {}
    }
    Start-Sleep -Seconds 3
    foreach ($p in $targets) {
        try { if (-not $p.HasExited) { $null = $p.Kill() } } catch {}
    }
    Start-Sleep -Seconds 2
    return $true
}

# 菜单里所有「按回车继续」统一走这里：先空行 + 分隔线，避免提示被
# 刚刚重新拉起的应用日志挤在同一行，让用户误以为脚本卡死。
function Wait-ForReturn {
    param([string]$Message = "按回车返回...")
    Write-Host ""
    Write-Host "  ----------------------------------------------------------" -ForegroundColor DarkGray
    Read-Host "  $Message" | Out-Null
}

function Start-SlotApp {
    param([PSCustomObject]$Slot)
    $exe = Join-Path $Slot.Directory $Slot.ExeName
    if (-not (Test-Path $exe)) {
        Write-Host "  [!] 未找到可执行文件，已跳过自动启动：$exe" -ForegroundColor Yellow
        return $false
    }
    Write-Host "  [*] 重新启动 $($Slot.Name)..." -ForegroundColor DarkGray
    try {
        if ($Slot.Kind -eq "msix") {
            # 商店包必须走 ShellExecute 才能正常激活，保持原有启动方式
            $null = Start-Process -FilePath $exe -WorkingDirectory $Slot.Directory
        } else {
            # Electron 桌面版会继承控制台句柄，把 DevTools / AutoUpdater 等
            # 自身日志 dumped 到安装终端，看起来像「卸载要联网」。
            # 这里重定向到临时文件：菜单输出干净，日志仍可查。
            $logDir = Join-Path $env:TEMP "ProxyAiApp"
            if (-not (Test-Path $logDir)) {
                $null = New-Item -ItemType Directory -Path $logDir -Force
            }
            # 每次启动用独立文件名，避免上个进程仍持有写句柄导致本次启动失败
            Get-ChildItem -Path $logDir -Filter "*.log" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-3) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            $tag = $Slot.Key -replace '[^a-zA-Z0-9_-]', '_'
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
            $outLog = Join-Path $logDir "$tag-$stamp.out.log"
            $errLog = Join-Path $logDir "$tag-$stamp.err.log"
            try {
                $null = Start-Process -FilePath $exe -WorkingDirectory $Slot.Directory `
                            -RedirectStandardOutput $outLog -RedirectStandardError $errLog
                Write-Host "      应用日志已重定向到: $logDir" -ForegroundColor DarkGray
            } catch {
                # 个别启动器不接受输出重定向，退回原方式，保证应用仍能拉起
                $null = Start-Process -FilePath $exe -WorkingDirectory $Slot.Directory
                Write-Host "      [!] 日志重定向不可用，已按原方式启动（应用日志可能出现在终端）" -ForegroundColor Yellow
            }
        }
        Start-Sleep -Seconds 1
        return $true
    } catch {
        Write-Host "  [!] 自动启动失败，请手动打开 $($Slot.Name)：$($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

# 统一构造接口/界面所需的槽位摘要
function Convert-SlotToApiObject {
    param([PSCustomObject]$Slot)
    return @{
        key       = $Slot.Key
        name      = $Slot.Name
        kind      = $Slot.Kind
        found     = $Slot.Found
        directory = $Slot.Directory
        installed = $Slot.Installed
    }
}

# Gemini 采用 Squirrel 式布局：升级后旧版本 app-* 目录常因注入文件被占用而残留。
# 目录名必须按版本号解析比较，字符串排序会把 app-1.9.0 排在 app-1.10.0 前面。
function Get-GeminiAppDirectories {
    $geminiRoot = Join-Path $env:LOCALAPPDATA "Google\Gemini"
    if (-not (Test-Path $geminiRoot)) { return @() }
    $result = @()
    foreach ($dir in @(Get-ChildItem -Path $geminiRoot -Directory -Filter "app-*" -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path (Join-Path $dir.FullName "Gemini.exe"))) { continue }
        $verText = $dir.Name -replace '^app-', ''
        $ver = [version]"0.0"
        [void][version]::TryParse($verText, [ref]$ver)
        $result += [PSCustomObject]@{
            Directory = $dir.FullName
            Version   = $ver
            Name      = $dir.Name
        }
    }
    return @($result | Sort-Object -Property @{ Expression = "Version"; Descending = $true }, @{ Expression = "Name"; Descending = $true })
}

function Get-AppSlotStatus {
    $geminiDirs = @(Get-GeminiAppDirectories)
    $geminiDir = if ($geminiDirs.Count -gt 0) { $geminiDirs[0].Directory } else { $null }

    $agDir = Join-Path $env:LOCALAPPDATA "Programs\Antigravity"
    if (-not (Test-Path (Join-Path $agDir "Antigravity.exe"))) {
        $agDir = $null
    }

    $agIdeDir = Join-Path $env:LOCALAPPDATA "Programs\Antigravity IDE"
    if (-not (Test-Path (Join-Path $agIdeDir "Antigravity IDE.exe"))) {
        $agIdeDir = $null
    }

    return @(
        [PSCustomObject]@{
            Key          = "gemini"
            Name         = "Google Gemini"
            ExeName      = "Gemini.exe"
            Kind         = "dir"
            ProcessNames = @("Gemini")
            Found        = ($null -ne $geminiDir)
            Directory    = if ($geminiDir) { $geminiDir } else { "" }
            Installed    = if ($geminiDir) { Test-Path (Join-Path $geminiDir "version.dll") } else { $false }
        },
        [PSCustomObject]@{
            Key          = "antigravity"
            Name         = "Antigravity"
            ExeName      = "Antigravity.exe"
            Kind         = "dir"
            ProcessNames = @("Antigravity")
            Found        = ($null -ne $agDir)
            Directory    = if ($agDir) { $agDir } else { "" }
            Installed    = if ($agDir) { Test-Path (Join-Path $agDir "version.dll") } else { $false }
        },
        [PSCustomObject]@{
            Key          = "antigravity_ide"
            Name         = "Antigravity IDE"
            ExeName      = "Antigravity IDE.exe"
            Kind         = "dir"
            ProcessNames = @("Antigravity IDE")
            Found        = ($null -ne $agIdeDir)
            Directory    = if ($agIdeDir) { $agIdeDir } else { "" }
            Installed    = if ($agIdeDir) { Test-Path (Join-Path $agIdeDir "version.dll") } else { $false }
        }
    ) + (Get-MsixSlotStatus)
}

# 商店包槽位：目录随版本变化，只按包名动态定位，再判断是否已投放
function Get-MsixSlotStatus {
    $result = @()
    foreach ($m in $MsixApps) {
        $dir = Get-MsixSlotDirectory -PackageNames $m.PackageNames -SubDir $m.SubDir
        $injected = if ($dir) { Test-Path (Join-Path $dir "version.dll") } else { $false }
        $result += [PSCustomObject]@{
            Key          = $m.Key
            Name         = $m.Name
            ExeName      = $m.ExeName
            Kind         = "msix"
            ProcessNames = $m.ProcessNames
            PackageNames = $m.PackageNames
            Found        = ($null -ne $dir)
            Directory    = if ($dir) { $dir } else { "" }
            Installed    = $injected
        }
    }
    return $result
}

function Install-ProxyToSlot {
    param([PSCustomObject]$Slot)
    if (-not $Slot.Found -or [string]::IsNullOrWhiteSpace($Slot.Directory)) {
        Write-Host "  [!] 本机未检测到 $($Slot.Name) 安装路径，已跳过。" -ForegroundColor Yellow
        return $false
    }
    $dllPath = Get-DllSourcePath
    if (-not $dllPath) {
        Write-Host "  [!] 未找到 version.dll 文件。" -ForegroundColor Red
        return $false
    }
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "  [!] 未找到 core\config.json 配置文件。" -ForegroundColor Red
        return $false
    }

    # 投放前先关闭应用（会先尝试优雅关闭窗口），等 2s 让文件句柄与子进程全部释放
    $wasRunning = Stop-SlotProcesses $Slot

    $dstDll = Join-Path $Slot.Directory "version.dll"
    $dstCfg = Join-Path $Slot.Directory "config.json"
    $hadDll = Test-Path $dstDll
    $hadCfg = Test-Path $dstCfg
    try {
        Copy-Item $dllPath $dstDll -Force -ErrorAction Stop
        Copy-Item $ConfigFile $dstCfg -Force -ErrorAction Stop
    } catch {
        $errMsg = $_.Exception.Message
        # 只回滚本次新建的半截文件；原先已在的旧版本文件保持不动
        foreach ($p in @($dstDll, $dstCfg)) {
            $preexisting = ($p -eq $dstDll -and $hadDll) -or ($p -eq $dstCfg -and $hadCfg)
            if (-not $preexisting -and (Test-Path $p)) {
                try { Remove-Item $p -Force -ErrorAction Stop } catch {}
            }
        }
        if ($Slot.Kind -eq "msix") {
            # 部分商店包目录受系统写保护（提权与备份特权同样被拒），这类应用无法注入，直接说明原因
            Write-Host "  [!] 安装到 $($Slot.Name) 失败：商店包目录禁止写入。$errMsg" -ForegroundColor Red
            Write-Host "      该应用无法通过注入方式代理，已跳过。" -ForegroundColor Yellow
            return $false
        }
        Write-Host "  [!] 安装到 $($Slot.Name) 失败（请先关闭正在运行的 $($Slot.ExeName) 后重试）：$errMsg" -ForegroundColor Red
        return $false
    }

    # 清掉旧的「已提示过」标记，让新版本重新提示一次加载成功
    $marker = Join-Path $Slot.Directory "logs\load-notify-success.marker"
    if (Test-Path $marker) {
        Remove-Item $marker -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  [OK] 已成功安装到 $($Slot.Name): $($Slot.Directory)" -ForegroundColor Green

    # 本来在跑的，装完直接重新拉起；商店应用更新后重复本动作即等于重新注入
    if ($wasRunning) {
        Start-SlotApp $Slot | Out-Null
    } else {
        Write-Host "      下次启动 $($Slot.Name) 时代理即生效。" -ForegroundColor DarkGray
    }
    return $true
}

# 本工具投放过的文件清单；卸载只按此清理，绝不删除应用自身文件。
$ProxyPayloadFiles = @("version.dll", "dbghelp.dll", "antigravity_proxy.dll", "config.json", "index.html", "config-web.html")

function Remove-ProxyFiles {
    param([string]$Directory)
    foreach ($f in $ProxyPayloadFiles) {
        $p = Join-Path $Directory $f
        if (Test-Path $p) { Remove-Item $p -Force -ErrorAction Stop }
    }
    # 日志目录随安装动作产生，卸载时一并清干净，不在应用目录留残留
    $logsDir = Join-Path $Directory "logs"
    if (Test-Path $logsDir) {
        Remove-Item $logsDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 判断某目录是否留有本工具的注入痕迹，避免误删干净的应用目录
function Test-ProxyPayloadPresent {
    param([string]$Directory)
    foreach ($mark in @("version.dll", "dbghelp.dll", "antigravity_proxy.dll")) {
        if (Test-Path (Join-Path $Directory $mark)) { return $true }
    }
    $proxyLogs = @(Get-ChildItem -Path (Join-Path $Directory "logs") -Filter "proxy-*.log" -File -ErrorAction SilentlyContinue)
    return ($proxyLogs.Count -gt 0)
}

# Gemini 升级后旧版本 app-* 目录不会被 updater 清掉，里面的注入会一直留存。
# 卸载主目录时顺带把残留目录一起清干净（此时进程已关闭，DLL 文件锁已释放）。
function Remove-GeminiStaleProxy {
    param([string]$PrimaryDirectory)
    foreach ($item in @(Get-GeminiAppDirectories)) {
        if ($item.Directory -ieq $PrimaryDirectory) { continue }
        if (-not (Test-ProxyPayloadPresent -Directory $item.Directory)) { continue }
        try {
            Remove-ProxyFiles -Directory $item.Directory | Out-Null
            Write-Host "  [OK] 已清理旧版本目录残留代理: $($item.Directory)" -ForegroundColor Green
        } catch {
            Write-Host "  [!] 清理旧版本目录失败（请先关闭 Gemini）：$($item.Directory) — $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Uninstall-ProxyFromSlot {
    param([PSCustomObject]$Slot)
    if (-not $Slot.Found -or [string]::IsNullOrWhiteSpace($Slot.Directory)) {
        Write-Host "  [!] 本机未检测到 $($Slot.Name) 安装路径，已跳过。" -ForegroundColor Yellow
        return
    }
    $wasRunning = Stop-SlotProcesses $Slot
    try {
        Remove-ProxyFiles -Directory $Slot.Directory | Out-Null
        Write-Host "  [OK] 已从 $($Slot.Name) 卸载代理: $($Slot.Directory)" -ForegroundColor Green
    } catch {
        Write-Host "  [!] 从 $($Slot.Name) 卸载失败（请先关闭正在运行的 $($Slot.ExeName)）：$($_.Exception.Message)" -ForegroundColor Red
    }
    # 进程已关闭，正好清理 Gemini 其它版本目录里的历史注入
    if ($Slot.Key -eq "gemini") {
        Remove-GeminiStaleProxy -PrimaryDirectory $Slot.Directory
    }
    if ($wasRunning) {
        Start-SlotApp $Slot | Out-Null
    }
}

# CLI 进程里系统真 version.dll 往往已被加载，同名劫持取不到代理模块，
# 因此改投 dbghelp.dll 转发壳 + 唯一名主体 antigravity_proxy.dll，并按主体所在目录补一份 config.json。
$CliExeNames = @("agy.exe", "antigravity-cli.exe")

function Get-CliProxySourcePaths {
    $dllPath = Get-DllSourcePath
    if (-not $dllPath) { return $null }
    $sideDir = Split-Path -Parent $dllPath
    $shim = Join-Path $sideDir "dbghelp.dll"
    $body = Join-Path $sideDir "antigravity_proxy.dll"
    if (-not (Test-Path $shim) -or -not (Test-Path $body)) { return $null }
    return [PSCustomObject]@{ Shim = $shim; Body = $body }
}

# 从 PATH 与 Antigravity 安装目录里收集 CLI 相关目录。
# -Filter 让文件系统层直接过滤文件名，避免把整个 Electron 目录（数万文件）
# 全部枚举进内存再筛选，卸载时这一步曾明显拖慢菜单。
function Get-CliSearchRoots {
    param([PSCustomObject[]]$Slots)
    $roots = @()
    foreach ($slot in $Slots) {
        if ($slot.Found -and $slot.Kind -eq "dir" -and $slot.Name -match "Antigravity") {
            $roots += $slot.Directory
        }
    }
    return @($roots | Sort-Object -Unique)
}

function Get-CliPathDirectories {
    $dirs = @()
    foreach ($exe in $CliExeNames) {
        $cmd = Get-Command ($exe -replace '\.exe$', '') -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $dirs += (Split-Path -Parent $cmd.Source) }
    }
    return @($dirs | Sort-Object -Unique | Where-Object { $_ -and (Test-Path $_) })
}

# 安装：定位 CLI 可执行文件所在目录
function Find-CliProxyDirectories {
    param([PSCustomObject[]]$Slots)
    $dirs = @(Get-CliPathDirectories)
    foreach ($root in @(Get-CliSearchRoots -Slots $Slots)) {
        foreach ($exe in $CliExeNames) {
            $dirs += @(Get-ChildItem -Path $root -Recurse -File -Filter $exe -ErrorAction SilentlyContinue |
                       ForEach-Object { $_.DirectoryName })
        }
    }
    return @($dirs | Sort-Object -Unique | Where-Object { $_ -and (Test-Path $_) })
}

# 卸载：直接定位带代理主体的目录，一次扫描即可，不必先找 CLI 再逐个试探
function Find-CliProxyPayloadDirectories {
    param([PSCustomObject[]]$Slots)
    $dirs = @(Get-CliPathDirectories)
    foreach ($root in @(Get-CliSearchRoots -Slots $Slots)) {
        $dirs += @(Get-ChildItem -Path $root -Recurse -File -Filter "antigravity_proxy.dll" -ErrorAction SilentlyContinue |
                   ForEach-Object { $_.DirectoryName })
    }
    return @($dirs | Sort-Object -Unique | Where-Object { $_ -and (Test-Path $_) })
}

# 仅当本轮确实安装/卸载了 Antigravity 相关目标时才处理 CLI
function Get-CliRelevantSlots {
    param([PSCustomObject[]]$Slots)
    return @($Slots | Where-Object { $_.Name -match "Antigravity" })
}

function Install-CliProxy {
    param([PSCustomObject[]]$Slots)
    $relevant = Get-CliRelevantSlots -Slots $Slots
    if ($relevant.Count -eq 0) { return }
    $src = Get-CliProxySourcePaths
    if (-not $src) {
        Write-Host "  [!] 包内缺少 dbghelp.dll / antigravity_proxy.dll，跳过 Antigravity CLI 代理投放。" -ForegroundColor Yellow
        return
    }
    foreach ($dir in (Find-CliProxyDirectories -Slots $relevant)) {
        $body = Join-Path $dir "antigravity_proxy.dll"
        $cfg = Join-Path $dir "config.json"
        # config.json 是通用文件名：目录里既没有我们的代理主体、又已存在该文件时不动它
        if (-not (Test-Path $body) -and (Test-Path $cfg)) {
            Write-Host "  [!] $dir 已有 config.json 且非本工具投放，已跳过 CLI 代理。" -ForegroundColor Yellow
            continue
        }
        try {
            Copy-Item $src.Shim (Join-Path $dir "dbghelp.dll") -Force -ErrorAction Stop
            Copy-Item $src.Body $body -Force -ErrorAction Stop
            Copy-Item $ConfigFile $cfg -Force -ErrorAction Stop
            Write-Host "  [OK] 已为 Antigravity CLI 投放代理: $dir" -ForegroundColor Green
        } catch {
            Write-Host "  [!] Antigravity CLI 代理投放失败（CLI 正在运行时请先退出）：$dir — $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Uninstall-CliProxy {
    param([PSCustomObject[]]$Slots)
    $relevant = Get-CliRelevantSlots -Slots $Slots
    if ($relevant.Count -eq 0) { return }
    foreach ($dir in (Find-CliProxyPayloadDirectories -Slots $relevant)) {
        if (-not (Test-Path (Join-Path $dir "antigravity_proxy.dll"))) { continue }
        try {
            foreach ($f in @("dbghelp.dll", "antigravity_proxy.dll", "config.json")) {
                $p = Join-Path $dir $f
                if (Test-Path $p) { Remove-Item $p -Force }
            }
            Write-Host "  [OK] 已清理 Antigravity CLI 代理: $dir" -ForegroundColor Green
        } catch {
            Write-Host "  [!] Antigravity CLI 代理清理失败：$dir — $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Get-SlotStatusLabel {
    param([PSCustomObject]$Slot)
    if (-not $Slot.Found) { return "[未检测到]" }
    if (-not $Slot.Installed) { return "[未安装]" }
    if ($Slot.Kind -eq "msix") { return "[已注入]" }
    return "[已安装]"
}

function Invoke-CustomInstallSubMenu {
    while ($true) {
        $slots = Get-AppSlotStatus
        Write-Host ""
        Write-Host "  --- 自定义安装 ---" -ForegroundColor Cyan
        for ($i = 0; $i -lt $slots.Count; $i++) {
            $s = $slots[$i]
            Write-Host ("  [{0}] 安装到 {1,-16} {2}" -f ($i + 1), $s.Name, (Get-SlotStatusLabel $s))
        }
        $maxOpt = $slots.Count
        Write-Host "  [0] 返回主菜单"

        while ($true) {
            $sub = (Read-Host "  请选择 (0~$maxOpt)").Trim()
            if ($sub -eq "0") {
                return
            }
            if ($sub -match '^\d+$') {
                $num = [int]$sub
                if ($num -ge 1 -and $num -le $maxOpt) {
                    Write-Host ""
                    $target = $slots[$num - 1]
                    if (Install-ProxyToSlot $target) {
                        Install-CliProxy -Slots @($target)
                    }
                    Wait-ForReturn "操作完成，按回车返回..."
                    break
                }
            }
            Write-Host "  [!] 输入有误，请输入 0 ~ $maxOpt 之间的编号。" -ForegroundColor Yellow
        }
    }
}

function Invoke-UninstallSubMenu {
    while ($true) {
        $slots = Get-AppSlotStatus
        Write-Host ""
        Write-Host "  --- 卸载代理 ---" -ForegroundColor Cyan
        Write-Host "  [1] 全部卸载 (卸载所有已检测软件的代理)"
        for ($i = 0; $i -lt $slots.Count; $i++) {
            $s = $slots[$i]
            Write-Host ("  [{0}] 卸载 {1,-18} {2}" -f ($i + 2), $s.Name, (Get-SlotStatusLabel $s))
        }
        $maxOpt = $slots.Count + 1
        Write-Host "  [0] 返回主菜单"

        while ($true) {
            $sub = (Read-Host "  请选择 (0~$maxOpt)").Trim()
            if ($sub -eq "0") {
                return
            }
            if ($sub -match '^\d+$') {
                $num = [int]$sub
                if ($num -eq 1) {
                    Write-Host ""
                    foreach ($s in $slots) {
                        if ($s.Found) {
                            Uninstall-ProxyFromSlot $s
                        }
                    }
                    Uninstall-CliProxy -Slots $slots
                    Wait-ForReturn "操作完成，按回车返回..."
                    break
                } elseif ($num -ge 2 -and $num -le $maxOpt) {
                    Write-Host ""
                    $target = $slots[$num - 2]
                    Uninstall-ProxyFromSlot $target
                    Uninstall-CliProxy -Slots @($target)
                    Wait-ForReturn "操作完成，按回车返回..."
                    break
                }
            }
            Write-Host "  [!] 输入有误，请输入 0 ~ $maxOpt 之间的编号。" -ForegroundColor Yellow
        }
    }
}

# 版本号以「.」切分后逐级按整数比较，禁止按字符串字典序比较
function Test-CalVerFormat {
    param([string]$Value)
    return $Value -match '^\d+(\.\d+)+$'
}

function Compare-CalVer {
    param([string]$Left, [string]$Right)
    $a = @($Left -split '\.')
    $b = @($Right -split '\.')
    $count = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $x = 0
        $y = 0
        if ($i -lt $a.Count) { [void][int]::TryParse($a[$i], [ref]$x) }
        if ($i -lt $b.Count) { [void][int]::TryParse($b[$i], [ref]$y) }
        if ($x -ne $y) { return $(if ($x -gt $y) { 1 } else { -1 }) }
    }
    return 0
}

# 本地版本优先取随包发布的 config.json，读取失败时退回脚本内置版本
function Get-LocalVersion {
    if (Test-Path $ConfigFile) {
        try {
            $c = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $v = ($c._version -replace '^v', '').Trim()
            if (Test-CalVerFormat $v) { return $v }
        } catch {}
    }
    return $CurrentVer
}

# 以正式 Release 的 tag 为唯一版本依据；镜像仅用于取数，返回值一律为 GitHub 官方链接
function Get-LatestRelease {
    param([int]$TimeoutSec = 6)

    $apiUrl = "https://api.github.com/repos/$GithubRepo/releases/latest"
    $sources = @(
        "https://gh-proxy.org/",
        "https://hk.gh-proxy.org/",
        "https://cdn.gh-proxy.org/",
        "https://edgeone.gh-proxy.org/",
        ""
    )
    $oldProgress = $global:ProgressPreference
    $global:ProgressPreference = "SilentlyContinue"
    try {
        foreach ($prefix in $sources) {
            $resp = $null
            try {
                $resp = Invoke-RestMethod -Uri "${prefix}${apiUrl}" -Method Get -TimeoutSec $TimeoutSec `
                    -Headers @{ "User-Agent" = "ProxyAiApp-Updater" }
            } catch {
                continue
            }
            $tag = ""
            if ($resp -and $resp.tag_name) { $tag = ("$($resp.tag_name)" -replace '^v', '').Trim() }
            if (-not (Test-CalVerFormat $tag)) { continue }

            $page = "https://github.com/$GithubRepo/releases"
            if ($resp.html_url -and "$($resp.html_url)" -match "^https://github\.com/") {
                $page = "$($resp.html_url)"
            }
            return [PSCustomObject]@{ Version = $tag; Page = $page; Body = "$($resp.body)" }
        }
        return $null
    } finally {
        $global:ProgressPreference = $oldProgress
    }
}

function Invoke-CheckUpdate {
    $ver = Get-LocalVersion
    Write-Host ""
    Write-Host "  [*] 当前版本: v$ver，正在检查更新 ($GithubRepo)..." -ForegroundColor Cyan
    $latest = Get-LatestRelease
    if (-not $latest) {
        Write-Host "  [!] 检查更新失败，请前往 Releases 页面查看最新版本：" -ForegroundColor Yellow
        Write-Host "      https://github.com/$GithubRepo/releases" -ForegroundColor Cyan
        return
    }
    Write-Host "  [OK] 最新已发布版本: v$($latest.Version)" -ForegroundColor Green
    if ((Compare-CalVer $latest.Version $ver) -gt 0) {
        Write-Host "  [!] 发现新版本 v$($latest.Version)，请前往 Releases 页面下载更新：" -ForegroundColor Yellow
        Write-Host "      $($latest.Page)" -ForegroundColor Cyan
    } else {
        Write-Host "  [OK] 当前已是最新版本。" -ForegroundColor Green
    }
}

# 从 Release 正文中挑出适合终端显示的条目。
# 正文含网盘二维码等 HTML 区块，整段输出会挤满屏幕，因此只取 `- ` 条目、遇到 `---` 截止。
function Get-ReleaseHighlights {
    param([string]$Body, [int]$MaxItems = 6)

    if ([string]::IsNullOrWhiteSpace($Body)) { return @() }
    $items = @()
    foreach ($line in ($Body -split "\r?\n")) {
        $t = $line.Trim()
        if ($t -match '^-{3,}$') { break }
        if ($t -match '^[-*]\s+(.+)$') {
            # 去掉 Markdown 加粗与行内代码标记（\x60 即反引号），终端不需要这些符号
            $item = ($Matches[1] -replace '\*\*', '' -replace '\x60', '').Trim()
            if ($item) { $items += $item }
            if ($items.Count -ge $MaxItems) { break }
        }
    }
    return $items
}

# 检测到新版本时先单独提示，按任意键打开下载页面后再进入主界面。
# 主界面标题下只有一行黄字，很容易被后续输出刷走，故给一段不会被淹没的独立画面。
function Show-UpdateNotice {
    param([PSCustomObject]$Latest)

    $localVer = Get-LocalVersion
    $url = "https://github.com/$GithubRepo/releases/latest"

    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "  [!] 发现新版本" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("  当前版本：v{0}" -f $localVer) -ForegroundColor DarkGray
    Write-Host ("  最新版本：v{0}" -f $Latest.Version) -ForegroundColor Green
    Write-Host ""

    $highlights = @(Get-ReleaseHighlights -Body $Latest.Body)
    if ($highlights.Count -gt 0) {
        Write-Host "  更新内容：" -ForegroundColor Cyan
        foreach ($h in $highlights) {
            Write-Host "    - $h"
        }
        Write-Host ""
    }

    Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  按任意键打开下载页面，随后自动进入安装工具..." -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow

    try {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        # 个别宿主不支持 RawUI 按键读取，退回按回车
        $null = Read-Host
    }

    try {
        Start-Process $url
    } catch {
        Write-Host ""
        Write-Host "  [!] 未能自动打开浏览器，请手动访问：" -ForegroundColor Yellow
        Write-Host "      $url" -ForegroundColor Cyan
        # 留出看清提示的时间，否则主界面刷新会立刻把它清掉
        Start-Sleep -Seconds 3
    }
}

function Start-LocalConfigServer {
    if (-not (Test-Path $WebFile)) {
        Write-Host "  [!] 未找到 index.html" -ForegroundColor Red
        return
    }

    $port = 18960
    $listener = $null
    for ($tryPort = 18960; $tryPort -le 18975; $tryPort++) {
        try {
            $endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Loopback, $tryPort)
            $candidate = New-Object System.Net.Sockets.TcpListener($endpoint)
            $candidate.Start()
            $listener = $candidate
            $port = $tryPort
            break
        } catch {
            continue
        }
    }

    if (-not $listener) {
        Write-Host "  [!] 本地端口占用，直接打开静态网页..." -ForegroundColor Yellow
        Start-Process $WebFile
        return
    }

    $url = "http://127.0.0.1:${port}/"
    Write-Host ""
    Write-Host "  [OK] 本地配置服务已启动: $url" -ForegroundColor Green
    Write-Host "  [*] 已在浏览器中打开配置页面。在网页内点击「直接保存」或「保存并一键安装」将直接生效。" -ForegroundColor Cyan
    Write-Host "  [*] 配置完成后，按 [Q] 或 [Enter] 键即可关闭此服务并返回菜单..." -ForegroundColor Yellow
    Start-Process $url

    try {
        while ($true) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Enter -or $key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::Escape) {
                    break
                }
            }
            if (-not $listener.Pending()) {
                Start-Sleep -Milliseconds 60
                continue
            }

            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $stream.ReadTimeout = 3000
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $false, 4096, $true)

                $requestLine = $reader.ReadLine()
                if ([string]::IsNullOrWhiteSpace($requestLine)) {
                    $client.Close()
                    continue
                }
                $parts = $requestLine.Split(' ')
                $method = $parts[0]
                $path = if ($parts.Length -ge 2) { $parts[1].Split('?')[0] } else { "/" }

                $contentLength = 0
                while ($true) {
                    $headerLine = $reader.ReadLine()
                    if ([string]::IsNullOrEmpty($headerLine)) { break }
                    if ($headerLine -match '^Content-Length:\s*(\d+)') {
                        $contentLength = [int]$Matches[1]
                    }
                }

                $bodyText = ""
                if ($contentLength -gt 0) {
                    $buf = New-Object char[] $contentLength
                    $readTotal = 0
                    while ($readTotal -lt $contentLength) {
                        $n = $reader.Read($buf, $readTotal, $contentLength - $readTotal)
                        if ($n -le 0) { break }
                        $readTotal += $n
                    }
                    $bodyText = New-Object string($buf, 0, $readTotal)
                }

                $statusCode = "200 OK"
                $contentType = "application/json; charset=utf-8"
                $respBytes = [byte[]]@()

                if ($method -eq "GET" -and ($path -eq "/" -or $path -eq "/index.html" -or $path -eq "/config-web.html")) {
                    $contentType = "text/html; charset=utf-8"
                    $respBytes = [System.IO.File]::ReadAllBytes($WebFile)
                } elseif ($method -eq "GET" -and ($path -eq "/favicon.ico" -or $path -like "/assets/*")) {
                    $relPath = if ($path -eq "/favicon.ico") { "assets\favicon.ico" } else { ([System.Uri]::UnescapeDataString($path)).TrimStart('/').Replace('/', '\') }
                    $assetsRoot = [System.IO.Path]::GetFullPath((Join-Path $AppRoot "assets"))
                    $assetFile = [System.IO.Path]::GetFullPath((Join-Path $AppRoot $relPath))
                    if ($assetFile.StartsWith($assetsRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path $assetFile -PathType Leaf)) {
                        $contentType = switch ([System.IO.Path]::GetExtension($assetFile).ToLowerInvariant()) {
                            ".css"  { "text/css; charset=utf-8" }
                            ".js"   { "application/javascript; charset=utf-8" }
                            ".ico"  { "image/x-icon" }
                            ".png"  { "image/png" }
                            ".svg"  { "image/svg+xml" }
                            default { "application/octet-stream" }
                        }
                        $respBytes = [System.IO.File]::ReadAllBytes($assetFile)
                    } else {
                        $statusCode = "404 Not Found"
                    }
                } elseif ($method -eq "GET" -and $path -eq "/api/status") {
                    $cfgObj = $null
                    if (Test-Path $ConfigFile) {
                        $cfgObj = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    }
                    $slots = Get-AppSlotStatus | ForEach-Object { Convert-SlotToApiObject $_ }
                    $payload = @{
                        ok      = $true
                        config  = $cfgObj
                        targets = $slots
                    } | ConvertTo-Json -Depth 10
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                } elseif ($method -eq "POST" -and $path -eq "/api/save") {
                    try {
                        $parsed = $bodyText | ConvertFrom-Json
                        $formatted = $parsed | ConvertTo-Json -Depth 10
                        [System.IO.File]::WriteAllText($ConfigFile, $formatted + "`n", (New-Object System.Text.UTF8Encoding($false)))
                        Write-Host "  [网页同步] 已保存 core\config.json" -ForegroundColor Green
                        $payload = @{ ok = $true } | ConvertTo-Json
                        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                    } catch {
                        $payload = @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json
                        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                    }
                } elseif ($method -eq "POST" -and $path -eq "/api/install") {
                    try {
                        $req = $bodyText | ConvertFrom-Json
                        if ($req.config) {
                            $formatted = $req.config | ConvertTo-Json -Depth 10
                            [System.IO.File]::WriteAllText($ConfigFile, $formatted + "`n", (New-Object System.Text.UTF8Encoding($false)))
                        }
                        $selected = @($req.targets)
                        $slots = Get-AppSlotStatus
                        $installedSlots = @()
                        $installedNames = @()
                        $failedNames = @()
                        foreach ($s in $slots) {
                            if ($selected -contains $s.Key -and $s.Found) {
                                if (Install-ProxyToSlot $s) {
                                    $installedSlots += $s
                                    $installedNames += $s.Name
                                } else {
                                    $failedNames += $s.Name
                                }
                            }
                        }
                        Install-CliProxy -Slots $installedSlots
                        $updatedSlots = Get-AppSlotStatus | ForEach-Object { Convert-SlotToApiObject $_ }
                        $okFlag = ($failedNames.Count -eq 0)
                        $msg = if ($installedNames.Count -gt 0 -and $failedNames.Count -eq 0) {
                            "已保存配置并成功安装到: " + ($installedNames -join "、")
                        } elseif ($failedNames.Count -gt 0) {
                            "安装失败: " + ($failedNames -join "、") + "（请先关闭对应软件后重试，安装日志见终端输出）"
                        } else {
                            "已保存 core\config.json（所选软件未在本机检测到安装路径）"
                        }
                        $payload = @{
                            ok      = $okFlag
                            message = $msg
                            targets = $updatedSlots
                        } | ConvertTo-Json -Depth 10
                        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                    } catch {
                        $payload = @{ ok = $false; message = $_.Exception.Message } | ConvertTo-Json
                        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                    }
                } else {
                    $statusCode = "404 Not Found"
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false}')
                }

                $headerStr = "HTTP/1.1 $statusCode`r`nContent-Type: $contentType`r`nContent-Length: $($respBytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
                $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headerStr)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                if ($respBytes.Length -gt 0) {
                    $stream.Write($respBytes, 0, $respBytes.Length)
                }
                $stream.Flush()
            } catch {
            } finally {
                $client.Close()
            }
        }
    } finally {
        $listener.Stop()
    }
}

if ($CheckUpdate) {
    Invoke-CheckUpdate
    exit 0
}

if ($Status) {
    Get-AppSlotStatus | ForEach-Object { Convert-SlotToApiObject $_ } | ConvertTo-Json -Depth 4
    exit 0
}

# 只跑 CLI 代理的投放 / 清理，供开发工具调用，避免两边各维护一套定位规则。
# -CliSlotKeys 与菜单里的单项操作保持一致：只把对应槽位交给 CLI 逻辑。
if ($CliInstall -or $CliUninstall) {
    if ($CliInstall -and $CliUninstall) {
        throw "-CliInstall 与 -CliUninstall 不能同时使用。"
    }
    $cliSlots = @(Get-AppSlotStatus)
    if ($CliSlotKeys.Count -gt 0) {
        $cliSlots = @($cliSlots | Where-Object { $CliSlotKeys -contains $_.Key })
    }
    if ($CliInstall) {
        Install-CliProxy -Slots $cliSlots
    } else {
        Uninstall-CliProxy -Slots $cliSlots
    }
    exit 0
}

if ($InstallAll) {
    $okCount = 0
    $failCount = 0
    $allSlots = @(Get-AppSlotStatus)
    foreach ($s in $allSlots) {
        if (-not $s.Found) { continue }
        if (Install-ProxyToSlot $s) { $okCount++ } else { $failCount++ }
    }
    Install-CliProxy -Slots $allSlots
    Write-Host ""
    Write-Host "  完成：成功 $okCount 项，失败 $failCount 项。" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Yellow" })
    exit $(if ($failCount -eq 0) { 0 } else { 1 })
}

if ($UninstallAll) {
    $allSlots = @(Get-AppSlotStatus)
    foreach ($s in $allSlots) {
        if ($s.Found) {
            Uninstall-ProxyFromSlot $s
        }
    }
    Uninstall-CliProxy -Slots $allSlots
    exit 0
}

if ($Web) {
    Start-LocalConfigServer
    exit 0
}

# 打开脚本即检查一次更新：取数可走镜像，提示只给 GitHub 官方链接
Write-Host ""
Write-Host "  [*] 正在检查更新..." -ForegroundColor DarkGray
$LatestRelease = Get-LatestRelease
$UpdateHint = $null
if ($LatestRelease -and ((Compare-CalVer $LatestRelease.Version (Get-LocalVersion)) -gt 0)) {
    $UpdateHint = "发现新版本 v$($LatestRelease.Version)：$($LatestRelease.Page)"
    # 先给出独立提示画面并引导到下载页，之后照常进入主界面
    Show-UpdateNotice -Latest $LatestRelease
}

while ($true) {
    Clear-Host
    $slots = Get-AppSlotStatus
    $proxyDisplay = "未读取"
    if (Test-Path $ConfigFile) {
        try {
            $c = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $proxyDisplay = "$($c.proxy.type)://$($c.proxy.host):$($c.proxy.port)"
        } catch {}
    }

    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  Proxy-AiApp 安装工具 v$CurrentVer" -ForegroundColor Cyan
    Write-Host "  作者：莫莫先生 · B站：https://space.bilibili.com/255947051" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  当前代理 : $proxyDisplay" -ForegroundColor Yellow
    if ($UpdateHint) {
        Write-Host "  [!] $UpdateHint" -ForegroundColor Yellow
    }
    Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray

    foreach ($s in $slots) {
        if ($s.Found) {
            $st = Get-SlotStatusLabel $s
            $col = if ($s.Installed) { "Green" } else { "White" }
            Write-Host ("  - {0,-16} {1,-14} {2}" -f $s.Name, $st, $s.Directory) -ForegroundColor $col
        } else {
            Write-Host ("  - {0,-16} [未检测到]" -f $s.Name) -ForegroundColor DarkGray
        }
    }

    Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  安装前会自动关闭对应软件，投放完成后自动重新拉起。" -ForegroundColor DarkGray
    Write-Host "  [1] 打开网页配置 (默认回车)" -ForegroundColor Green
    Write-Host "  [2] 一键安装全部"
    Write-Host "  [3] 自定义安装"
    Write-Host "  [4] 卸载已安装代理"
    Write-Host "  [5] 检查更新"
    Write-Host "  [0] 退出"
    Write-Host "==========================================================" -ForegroundColor Cyan

    while ($true) {
        $choice = Read-Host "请选择 (默认 1)"
        if ([string]::IsNullOrWhiteSpace($choice)) {
            $choice = "1"
        }
        $choice = $choice.Trim()
        if ($choice -in @("0", "1", "2", "3", "4", "5")) {
            break
        }
        Write-Host "  [!] 输入有误，请输入 0 ~ 5 之间的编号。" -ForegroundColor Yellow
    }

    switch ($choice) {
        "1" {
            Start-LocalConfigServer
        }
        "2" {
            Write-Host ""
            $anyFound = $false
            foreach ($s in $slots) {
                if ($s.Found) {
                    $anyFound = $true
                    Install-ProxyToSlot $s | Out-Null
                }
            }
            if (-not $anyFound) {
                Write-Host "  [!] 未检测到任何已安装的软件。" -ForegroundColor Yellow
            } else {
                Install-CliProxy -Slots $slots
            }
            Wait-ForReturn "操作完成，按回车返回..."
        }
        "3" {
            Invoke-CustomInstallSubMenu
        }
        "4" {
            Invoke-UninstallSubMenu
        }
        "5" {
            Invoke-CheckUpdate
            Wait-ForReturn "操作完成，按回车返回..."
        }
        "0" {
            exit 0
        }
    }
}
