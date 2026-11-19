param([switch]$Preview)

function Get-Entry {
    param([string]$Path)
    try {
        Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        return
    }
}

function Test-RegularEntry {
    param($Entry)
    $null -ne $Entry -and -not ($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Test-SafeDirectory {
    param([string]$Path)
    while ($Path) {
        $entry = Get-Entry $Path
        if (-not (Test-RegularEntry $entry) -or -not $entry.PSIsContainer) { return $false }
        $Path = [IO.Path]::GetDirectoryName($Path)
    }
    return $true
}

function Get-SafeDirectories {
    param([string]$Path)
    if (Test-SafeDirectory $Path) {
        Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction Stop |
            Where-Object { Test-RegularEntry $_ }
    }
}

function Get-CleanupFiles {
    param([string]$Path, [string]$Category)
    if (-not (Test-SafeDirectory $Path)) { return }
    foreach ($entry in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
        if (-not (Test-RegularEntry $entry)) { continue }
        if ($entry.PSIsContainer) {
            Get-CleanupFiles $entry.FullName $Category
        } elseif (($Category -ne '日志' -or $entry.Extension -eq '.xlog') -and $entry.LinkType -ne 'HardLink') {
            [pscustomobject]@{
                Category = $Category
                Path = $entry.FullName
                Bytes = $entry.Length
                Created = $entry.CreationTimeUtc
                Modified = $entry.LastWriteTimeUtc
            }
        }
    }
}

function Get-CleanupSelection {
    param([string]$Root, [switch]$Packages, [switch]$Plugins)
    if (-not (Test-SafeDirectory $Root)) { throw '微信目录不存在，或路径包含链接。' }
    Get-CleanupFiles (Join-Path $Root 'log') '日志'

    foreach ($profile in (Get-SafeDirectories (Join-Path $Root 'radium\web\profiles'))) {
        foreach ($name in @('Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache')) {
            Get-CleanupFiles (Join-Path $profile.FullName $name) '网页缓存'
        }
    }
    foreach ($user in (Get-SafeDirectories (Join-Path $Root 'radium\users'))) {
        $applet = Join-Path $user.FullName 'applet'
        foreach ($name in @('codecache', 'icon')) {
            Get-CleanupFiles (Join-Path $applet $name) '小程序缓存'
        }
        if ($Packages) { Get-CleanupFiles (Join-Path $applet 'packages') '小程序安装包' }
    }
    if ($Plugins) { Get-CleanupFiles (Join-Path $Root 'XPlugin\Plugins') '微信插件' }
}

function Get-WeChatProcess {
    $names = @('WeChat', 'Weixin', 'WeChatAppEx', 'WeixinAppEx', 'WeChatPlayer', 'WeixinPlayer', 'WeixinUpdate', 'xwechat')
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    foreach ($process in (Get-Process -ErrorAction Stop)) {
        if ($process.ProcessName -in $names -and $process.SessionId -eq $session) { $process }
    }
}

function Test-WeChatRunning {
    @(Get-WeChatProcess).Count -gt 0
}

function Get-WeChatMainProcess {
    Get-WeChatProcess | Where-Object { $_.ProcessName -in @('Weixin', 'WeChat') }
}

function Get-WeChatLaunchPath {
    foreach ($process in (Get-WeChatMainProcess)) {
        if ($process.Path -and (Test-Path -LiteralPath $process.Path -PathType Leaf)) {
            return $process.Path
        }
    }
    foreach ($folder in @('Programs', 'CommonPrograms')) {
        $directory = [Environment]::GetFolderPath($folder)
        if (-not $directory) { continue }
        $shortcut = Get-ChildItem -LiteralPath $directory -File -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -in @('微信', 'Weixin', 'WeChat') } |
            Select-Object -First 1
        if ($shortcut) { return $shortcut.FullName }
    }
}

function Start-WeChat {
    param([string]$Path)
    if (Get-WeChatMainProcess) {
        Write-Host '微信已在运行。'
        return
    }
    Start-Process -FilePath $Path -WorkingDirectory ([IO.Path]::GetDirectoryName($Path)) -ErrorAction Stop
    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        if (Get-WeChatMainProcess) {
            Write-Host '已重新打开微信。'
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw '已请求启动，但暂未检测到微信进程。'
}

function Stop-WeChat {
    $closeRequested = $false
    foreach ($process in (Get-WeChatProcess)) {
        if (-not $process.HasExited -and $process.CloseMainWindow()) { $closeRequested = $true }
    }
    if ($closeRequested) { Start-Sleep -Seconds 2 }

    foreach ($process in (Get-WeChatProcess)) {
        try {
            if (-not $process.HasExited) { Stop-Process -InputObject $process -ErrorAction Stop }
        } catch {
            if (-not $process.HasExited) { throw }
        }
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (-not (Test-WeChatRunning)) { return }
        Start-Sleep -Milliseconds 250
    }
    throw '微信后台仍在运行。请从系统托盘退出微信后重试。'
}

function Invoke-Cleanup {
    param($Selection)
    if (Test-WeChatRunning) { throw '请从系统托盘彻底退出微信后再清理。' }

    $removed = 0
    $bytes = 0L
    foreach ($file in $Selection) {
        try {
            if (-not (Test-SafeDirectory ([IO.Path]::GetDirectoryName($file.Path)))) { continue }
            $entry = Get-Entry $file.Path
            if (-not (Test-RegularEntry $entry) -or $entry.PSIsContainer -or
                $entry.LinkType -eq 'HardLink' -or $entry.Length -ne $file.Bytes -or
                $entry.CreationTimeUtc -ne $file.Created -or $entry.LastWriteTimeUtc -ne $file.Modified) {
                continue
            }
            [IO.File]::Delete($file.Path)
            $removed++
            $bytes += $file.Bytes
        } catch {
            Write-Warning ("无法删除 {0}：{1}" -f $file.Path, $_.Exception.Message)
        }
    }
    [pscustomobject]@{ Removed = $removed; Bytes = $bytes; Skipped = $Selection.Count - $removed }
}

function Write-CleanupPreview {
    param($Selection)
    Write-Host '清理预览'
    foreach ($group in ($Selection | Group-Object Category)) {
        $size = ($group.Group | Measure-Object Bytes -Sum).Sum
        Write-Host ('{0}  {1} 个文件  {2:N2} MiB' -f $group.Name, $group.Count, ($size / 1MB))
    }
    $total = ($Selection | Measure-Object Bytes -Sum).Sum
    Write-Host ('合计  {0} 个文件  {1:N2} MiB' -f $Selection.Count, ($total / 1MB))
}

function Invoke-WeChatCleaner {
    param([string]$Root, [switch]$Preview)
    $ErrorActionPreference = 'Stop'
    $restartPath = $null
    try {
        $choice = '1'
        if (-not $Preview) {
            Write-Host 'Windows 微信清理'
            Write-Host '1  日志与缓存'
            Write-Host '2  日志与缓存 + 小程序安装包'
            Write-Host '3  日志与缓存 + 微信插件'
            Write-Host '4  日志与缓存 + 小程序安装包 + 微信插件'
            $choice = Read-Host '选择 1 到 4，回车选 1，输入 Q 退出'
            if ($choice -eq 'Q') { return 0 }
            if (-not $choice) { $choice = '1' }
            if ($choice -notin @('1', '2', '3', '4')) { throw '请输入 1 到 4。' }
        }

        $packages = $choice -in @('2', '4')
        $plugins = $choice -in @('3', '4')
        $selection = @(Get-CleanupSelection -Root $Root -Packages:$packages -Plugins:$plugins)
        Write-CleanupPreview $selection
        if ($Preview -or $selection.Count -eq 0) { return 0 }
        if (Test-WeChatRunning) {
            Write-Host '检测到微信正在运行。自动退出可能会中断正在进行的操作。'
            if ((Read-Host '输入 Y 自动退出微信并继续，直接回车取消') -ne 'Y') {
                Write-Host '已取消。'
                return 0
            }
            if (Test-WeChatRunning) {
                $restartPath = Get-WeChatLaunchPath
                if (-not $restartPath) { throw '找不到微信启动入口。请手动退出微信后重试。' }
                Stop-WeChat
                Write-Host '微信已退出，正在重新扫描。'
                $selection = @(Get-CleanupSelection -Root $Root -Packages:$packages -Plugins:$plugins)
                Write-CleanupPreview $selection
                if ($selection.Count -eq 0) { return 0 }
            }
        }
        if ($packages) { Write-Host '小程序可能需要重新下载安装包。' }
        if ($plugins) { Write-Host 'OCR、播放器等功能可能暂时不可用，恢复取决于微信能否重新下载插件。' }
        if ((Read-Host '输入 Y 永久删除，直接回车取消') -ne 'Y') {
            Write-Host '已取消。'
            return 0
        }
        $result = Invoke-Cleanup $selection
        Write-Host ('已删除 {0} 个文件（{1:N2} MiB），跳过 {2} 个。' -f $result.Removed, ($result.Bytes / 1MB), $result.Skipped)
        return [int]($result.Skipped -gt 0)
    } catch {
        Write-Host ("清理中止：{0}" -f $_.Exception.Message)
        return 1
    } finally {
        if ($restartPath) {
            try {
                Start-WeChat -Path $restartPath
            } catch {
                Write-Warning ("无法确认微信已重新打开，请从开始菜单打开微信。{0}" -f $_.Exception.Message)
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-WeChatCleaner -Root (Join-Path $env:APPDATA 'Tencent\xwechat') -Preview:$Preview)
}
