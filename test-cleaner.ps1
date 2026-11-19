$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\WechatCleaner.ps1"

$temp = (Get-Item -LiteralPath $env:TEMP).FullName.TrimEnd('\')
$fixture = [IO.Path]::GetFullPath((Join-Path $temp ('wechat-cleaner-' + [guid]::NewGuid().ToString('N'))))
if ([IO.Path]::GetDirectoryName($fixture) -ne $temp) { throw 'Invalid test fixture location.' }
$root = Join-Path $fixture 'xwechat'
$defaults = @(
    'log\radium\old.xlog'
    'radium\web\profiles\profile\Cache\Cache_Data\entry'
    'radium\users\account\applet\codecache\entry'
)
$optional = @(
    'radium\users\account\applet\packages\app.wxapkg'
    'XPlugin\Plugins\Example\plugin.dll'
)
$keep = @(
    'log\mm.mmap3'
    'radium\cache\main.mmap'
    'radium\web\profiles\profile\Local Storage\entry'
    'radium\users\account\applet\local\entry'
    'XPlugin\info\metadata'
    'login\account'
)
$junction = Join-Path $root 'log\junction'

try {
    foreach ($relative in ($defaults + $optional + $keep)) {
        $path = Join-Path $root $relative
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
        [IO.File]::WriteAllText($path, 'sample')
    }
    $externalDir = Join-Path $fixture 'other'
    [IO.Directory]::CreateDirectory($externalDir) | Out-Null
    $external = Join-Path $externalDir 'outside.xlog'
    [IO.File]::WriteAllText($external, 'keep')
    New-Item -ItemType Junction -Path $junction -Target $externalDir | Out-Null
    New-Item -ItemType HardLink -Path (Join-Path $root 'log\linked.xlog') -Target $external | Out-Null
    $keep += @('log\linked.xlog', 'log\junction\outside.xlog')

    $selection = @(Get-CleanupSelection -Root $root)
    if ($selection.Count -ne $defaults.Count) { throw 'Wrong preview selection.' }
    foreach ($relative in ($defaults + $optional + $keep)) {
        if (-not [IO.File]::Exists((Join-Path $root $relative))) { throw "Preview changed $relative" }
    }
    function Test-WeChatRunning { $true }
    $blocked = $false
    try { Invoke-Cleanup -Selection $selection | Out-Null } catch { $blocked = $true }
    if (-not $blocked -or -not [IO.File]::Exists((Join-Path $root $defaults[0]))) {
        throw 'Running WeChat did not prevent cleanup.'
    }

    function Test-WeChatRunning { $false }
    if ((Invoke-Cleanup -Selection $selection).Removed -ne $defaults.Count) { throw 'Default cleanup failed.' }
    foreach ($relative in ($optional + $keep)) {
        if (-not [IO.File]::Exists((Join-Path $root $relative))) { throw "Default cleanup changed $relative" }
    }
    $selection = @(Get-CleanupSelection -Root $root -Packages -Plugins)
    if ((Invoke-Cleanup -Selection $selection).Removed -ne $optional.Count) { throw 'Optional cleanup failed.' }
    if (@(Get-CleanupSelection -Root $root -Packages -Plugins).Count -ne 0) { throw 'Cleanup left selected files.' }
    foreach ($relative in $keep) {
        if (-not [IO.File]::Exists((Join-Path $root $relative))) { throw "Cleanup changed $relative" }
    }
    if ([IO.File]::ReadAllText($external) -ne 'keep') { throw 'Cleanup modified an external file.' }
    Write-Host 'PASS: preview, process guard, default and optional cleanup, junction and hard link protection.'
} finally {
    if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
    if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture, $true) }
}
