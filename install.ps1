param(
    [switch]$Web
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptRoot

$ConfigFile = Join-Path $ScriptRoot "config.json"
$WebFile    = Join-Path $ScriptRoot "config-web.html"
$GithubRepo = "hcllmsx/proxy-aiapp"
$CurrentVer = "26.10.20"

function Get-DllSourcePath {
    $localDll = Join-Path $ScriptRoot "version.dll"
    if (Test-Path $localDll) { return $localDll }
    $buildDll = Join-Path $ScriptRoot "_temp\build-x64\Release\version.dll"
    if (Test-Path $buildDll) { return $buildDll }
    return $null
}

function Get-AppSlotStatus {
    $geminiDir = $null
    $geminiRoot = Join-Path $env:LOCALAPPDATA "Google\Gemini"
    if (Test-Path $geminiRoot) {
        $latestApp = Get-ChildItem -Path $geminiRoot -Directory -Filter "app-*" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            Select-Object -First 1
        if ($latestApp -and (Test-Path (Join-Path $latestApp.FullName "Gemini.exe"))) {
            $geminiDir = $latestApp.FullName
        }
    }

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
            Key       = "gemini"
            Name      = "Google Gemini"
            ExeName   = "Gemini.exe"
            Found     = ($null -ne $geminiDir)
            Directory = if ($geminiDir) { $geminiDir } else { "" }
            Installed = if ($geminiDir) { Test-Path (Join-Path $geminiDir "version.dll") } else { $false }
        },
        [PSCustomObject]@{
            Key       = "antigravity"
            Name      = "Antigravity"
            ExeName   = "Antigravity.exe"
            Found     = ($null -ne $agDir)
            Directory = if ($agDir) { $agDir } else { "" }
            Installed = if ($agDir) { Test-Path (Join-Path $agDir "version.dll") } else { $false }
        },
        [PSCustomObject]@{
            Key       = "antigravity_ide"
            Name      = "Antigravity IDE"
            ExeName   = "Antigravity IDE.exe"
            Found     = ($null -ne $agIdeDir)
            Directory = if ($agIdeDir) { $agIdeDir } else { "" }
            Installed = if ($agIdeDir) { Test-Path (Join-Path $agIdeDir "version.dll") } else { $false }
        }
    )
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
        Write-Host "  [!] 未找到 config.json 配置文件。" -ForegroundColor Red
        return $false
    }
    try {
        Copy-Item $dllPath (Join-Path $Slot.Directory "version.dll") -Force
        Copy-Item $ConfigFile (Join-Path $Slot.Directory "config.json") -Force
        $marker = Join-Path $Slot.Directory "logs\load-notify-success.marker"
        if (Test-Path $marker) {
            Remove-Item $marker -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  [OK] 已成功安装到 $($Slot.Name): $($Slot.Directory)" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [!] 安装到 $($Slot.Name) 失败（请先关闭正在运行的 $($Slot.ExeName) 后重试）：$($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Uninstall-ProxyFromSlot {
    param([PSCustomObject]$Slot)
    if (-not $Slot.Found -or [string]::IsNullOrWhiteSpace($Slot.Directory)) {
        Write-Host "  [!] 本机未检测到 $($Slot.Name) 安装路径，已跳过。" -ForegroundColor Yellow
        return
    }
    try {
        foreach ($f in @("version.dll", "dbghelp.dll", "config.json", "config-web.html")) {
            $p = Join-Path $Slot.Directory $f
            if (Test-Path $p) { Remove-Item $p -Force }
        }
        Write-Host "  [OK] 已从 $($Slot.Name) 卸载代理: $($Slot.Directory)" -ForegroundColor Green
    } catch {
        Write-Host "  [!] 从 $($Slot.Name) 卸载失败（请先关闭正在运行的 $($Slot.ExeName)）：$($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-CustomInstallSubMenu {
    while ($true) {
        $slots = Get-AppSlotStatus
        Write-Host ""
        Write-Host "  --- 自定义安装 ---" -ForegroundColor Cyan
        for ($i = 0; $i -lt $slots.Count; $i++) {
            $s = $slots[$i]
            $st = if (-not $s.Found) { "[未检测到]" } elseif ($s.Installed) { "[已安装]" } else { "[未安装]" }
            Write-Host ("  [{0}] 安装到 {1,-16} {2}" -f ($i + 1), $s.Name, $st)
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
                    Install-ProxyToSlot $slots[$num - 1] | Out-Null
                    Read-Host "`n  按回车继续..."
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
            $st = if (-not $s.Found) { "[未检测到]" } elseif ($s.Installed) { "[已安装]" } else { "[未安装]" }
            Write-Host ("  [{0}] 卸载 {1,-18} {2}" -f ($i + 2), $s.Name, $st)
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
                    Read-Host "`n  按回车继续..."
                    break
                } elseif ($num -ge 2 -and $num -le $maxOpt) {
                    Write-Host ""
                    Uninstall-ProxyFromSlot $slots[$num - 2]
                    Read-Host "`n  按回车继续..."
                    break
                }
            }
            Write-Host "  [!] 输入有误，请输入 0 ~ $maxOpt 之间的编号。" -ForegroundColor Yellow
        }
    }
}

function Invoke-CheckUpdate {
    $ver = $CurrentVer
    if (Test-Path $ConfigFile) {
        try {
            $c = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($c._version) { $ver = ($c._version -replace '^v', '').Trim() }
        } catch {}
    }
    $apiUrl = "https://api.github.com/repos/$GithubRepo/releases/latest"
    $proxies = @(
        "https://gh-proxy.org/",
        "https://hk.gh-proxy.org/",
        "https://cdn.gh-proxy.org/",
        "https://edgeone.gh-proxy.org/",
        ""
    )
    Write-Host ""
    Write-Host "  [*] 当前版本: v$ver，正在检查更新 ($GithubRepo)..." -ForegroundColor Cyan
    foreach ($prefix in $proxies) {
        $reqUrl = "${prefix}${apiUrl}"
        try {
            $resp = Invoke-RestMethod -Uri $reqUrl -Method Get -TimeoutSec 8 -Headers @{ "User-Agent" = "ProxyAiApp-Updater" }
            if ($resp -and $resp.tag_name) {
                $latestVer = ($resp.tag_name -replace '^v', '').Trim()
                $channelName = if ($prefix) { $prefix } else { "GitHub 直连" }
                Write-Host "  [OK] 最新版本: v$latestVer (通道: $channelName)" -ForegroundColor Green
                if ($latestVer -ne $ver) {
                    $dlUrl = "https://github.com/$GithubRepo/releases/latest"
                    if ($resp.assets -and $resp.assets.Count -gt 0) {
                        $dlUrl = $resp.assets[0].browser_download_url
                    }
                    $finalDlUrl = "${prefix}${dlUrl}"
                    Write-Host "  [!] 发现新版本 v$latestVer，下载地址: $finalDlUrl" -ForegroundColor Yellow
                } else {
                    Write-Host "  [OK] 当前已是最新版本。" -ForegroundColor Green
                }
                return
            }
        } catch {
            continue
        }
    }
    Write-Host "  [!] 暂未获取到发布版本信息（仓库尚未发布 Release 或网络受限）。" -ForegroundColor Yellow
}

function Start-LocalConfigServer {
    if (-not (Test-Path $WebFile)) {
        Write-Host "  [!] 未找到 config-web.html" -ForegroundColor Red
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

                if ($method -eq "GET" -and ($path -eq "/" -or $path -eq "/config-web.html")) {
                    $contentType = "text/html; charset=utf-8"
                    $respBytes = [System.IO.File]::ReadAllBytes($WebFile)
                } elseif ($method -eq "GET" -and ($path -eq "/favicon.ico" -or $path -like "/assets/*")) {
                    $relPath = if ($path -eq "/favicon.ico") { "assets\favicon.ico" } else { ([System.Uri]::UnescapeDataString($path)).TrimStart('/').Replace('/', '\') }
                    $assetFile = Join-Path $ScriptRoot $relPath
                    if ((Test-Path $assetFile -PathType Leaf)) {
                        $contentType = if ($assetFile.EndsWith(".ico")) { "image/x-icon" } else { "image/png" }
                        $respBytes = [System.IO.File]::ReadAllBytes($assetFile)
                    } else {
                        $statusCode = "404 Not Found"
                    }
                } elseif ($method -eq "GET" -and $path -eq "/api/status") {
                    $cfgObj = $null
                    if (Test-Path $ConfigFile) {
                        $cfgObj = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    }
                    $slots = Get-AppSlotStatus | ForEach-Object {
                        @{
                            key       = $_.Key
                            name      = $_.Name
                            found     = $_.Found
                            directory = $_.Directory
                            installed = $_.Installed
                        }
                    }
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
                        Write-Host "  [网页同步] 已保存 config.json" -ForegroundColor Green
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
                        $installedNames = @()
                        $failedNames = @()
                        foreach ($s in $slots) {
                            if ($selected -contains $s.Key -and $s.Found) {
                                if (Install-ProxyToSlot $s) {
                                    $installedNames += $s.Name
                                } else {
                                    $failedNames += $s.Name
                                }
                            }
                        }
                        $updatedSlots = Get-AppSlotStatus | ForEach-Object {
                            @{
                                key       = $_.Key
                                name      = $_.Name
                                found     = $_.Found
                                directory = $_.Directory
                                installed = $_.Installed
                            }
                        }
                        $okFlag = ($failedNames.Count -eq 0)
                        $msg = if ($installedNames.Count -gt 0 -and $failedNames.Count -eq 0) {
                            "已保存配置并成功安装到: " + ($installedNames -join "、")
                        } elseif ($failedNames.Count -gt 0) {
                            "安装失败: " + ($failedNames -join "、") + "（请先关闭对应软件后重试）"
                        } else {
                            "已保存 config.json（所选软件未在本机检测到安装路径）"
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

if ($Web) {
    Start-LocalConfigServer
    exit 0
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
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  当前代理 : $proxyDisplay" -ForegroundColor Yellow
    Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray

    foreach ($s in $slots) {
        if ($s.Found) {
            $st = if ($s.Installed) { "[已安装]" } else { "[未安装]" }
            $col = if ($s.Installed) { "Green" } else { "White" }
            Write-Host ("  - {0,-16} {1,-10} {2}" -f $s.Name, $st, $s.Directory) -ForegroundColor $col
        } else {
            Write-Host ("  - {0,-16} [未检测到]" -f $s.Name) -ForegroundColor DarkGray
        }
    }

    Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray
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
            }
            Read-Host "`n按回车返回..."
        }
        "3" {
            Invoke-CustomInstallSubMenu
        }
        "4" {
            Invoke-UninstallSubMenu
        }
        "5" {
            Invoke-CheckUpdate
            Read-Host "`n按回车返回..."
        }
        "0" {
            exit 0
        }
    }
}
