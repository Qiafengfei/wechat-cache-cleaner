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

function Test-WeChatRunning {
    $names = @('WeChat', 'Weixin', 'WeChatAppEx', 'WeixinAppEx', 'WeChatPlayer', 'WeixinPlayer', 'WeixinUpdate', 'xwechat')
    foreach ($process in (Get-Process -ErrorAction Stop)) {
        if ($process.ProcessName -in $names) { return $true }
    }
    return $false
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

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    try {
        $choice = '1'
        if (-not $Preview) {
            Write-Host 'Windows 微信清理'
            Write-Host '1  日志与缓存'
            Write-Host '2  日志与缓存 + 小程序安装包'
            Write-Host '3  日志与缓存 + 微信插件'
            Write-Host '4  日志与缓存 + 小程序安装包 + 微信插件'
            $choice = Read-Host '选择 1 到 4，回车选 1，输入 Q 退出'
            if ($choice -eq 'Q') { exit 0 }
            if (-not $choice) { $choice = '1' }
            if ($choice -notin @('1', '2', '3', '4')) { throw '请输入 1 到 4。' }
        }

        $packages = $choice -in @('2', '4')
        $plugins = $choice -in @('3', '4')
        $root = Join-Path $env:APPDATA 'Tencent\xwechat'
        $selection = @(Get-CleanupSelection -Root $root -Packages:$packages -Plugins:$plugins)
        Write-Host '清理预览'
        foreach ($group in ($selection | Group-Object Category)) {
            $size = ($group.Group | Measure-Object Bytes -Sum).Sum
            Write-Host ('{0}  {1} 个文件  {2:N2} MiB' -f $group.Name, $group.Count, ($size / 1MB))
        }
        $total = ($selection | Measure-Object Bytes -Sum).Sum
        Write-Host ('合计  {0} 个文件  {1:N2} MiB' -f $selection.Count, ($total / 1MB))
        if ($Preview -or $selection.Count -eq 0) { exit 0 }
        if ($packages) { Write-Host '小程序可能需要重新下载安装包。' }
        if ($plugins) { Write-Host 'OCR、播放器等功能可能暂时不可用，恢复取决于微信能否重新下载插件。' }
        if ((Read-Host '请从系统托盘退出微信。输入 Y 永久删除，直接回车取消') -ne 'Y') {
            Write-Host '已取消。'
            exit 0
        }
        $result = Invoke-Cleanup $selection
        Write-Host ('已删除 {0} 个文件（{1:N2} MiB），跳过 {2} 个。' -f $result.Removed, ($result.Bytes / 1MB), $result.Skipped)
        if ($result.Skipped -gt 0) { exit 1 }
    } catch {
        Write-Host ("清理中止：{0}" -f $_.Exception.Message)
        exit 1
    }
}
