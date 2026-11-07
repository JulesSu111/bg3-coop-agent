[CmdletBinding()]
param([switch]$RemoveData)
$ErrorActionPreference = 'Stop'
$runtime = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'BG3Coop'))
$expected = [IO.Path]::GetFullPath($env:LOCALAPPDATA)
if ([IO.Path]::GetDirectoryName($runtime) -ne $expected -or [IO.Path]::GetFileName($runtime) -ne 'BG3Coop') { throw 'Unsafe runtime path' }
$taskName = 'BG3Coop-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$enabled = Join-Path $runtime 'enabled'
if (Test-Path -LiteralPath $enabled) { Remove-Item -LiteralPath $enabled -Force }
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Disable-ScheduledTask -TaskName $taskName | Out-Null
    # Clean up legacy launchers without a job BEFORE Stop-ScheduledTask can orphan their tree.
    $legacy = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('python.exe','pythonw.exe') -and $_.CommandLine -like '*-m bg3coop.daemon*' -and $_.CommandLine.Contains($runtime)
    }
    foreach ($process in $legacy) { & taskkill.exe /PID $process.ProcessId /T /F | Out-Null }
    Stop-ScheduledTask -TaskName $taskName
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
# Match full command line before terminating owned processes; never kill an arbitrary stale PID.
$owned = Get-CimInstance Win32_Process | Where-Object {
    ($_.Name -in @('python.exe','pythonw.exe') -and $_.CommandLine -like '*-m bg3coop.daemon*' -and $_.CommandLine.Contains($runtime)) -or
    ($_.Name -in @('python.exe','pythonw.exe') -and $_.CommandLine -like '*-m bg3coop.supervisor*' -and $_.CommandLine.Contains($runtime)) -or
    ($_.Name -in @('python.exe','pythonw.exe') -and $_.CommandLine -like '*supervisor.py*' -and $_.CommandLine.Contains($runtime)) -or
    ($_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*background-launcher.ps1*' -and $_.CommandLine.Contains($runtime))
}
foreach ($process in $owned) { & taskkill.exe /PID $process.ProcessId /T /F | Out-Null }
$endpoint = Join-Path $runtime 'bridge.json'
if (Test-Path -LiteralPath $endpoint) { Remove-Item -LiteralPath $endpoint -Force }
if ($RemoveData -and (Test-Path -LiteralPath $runtime)) {
    # Windows paths are case-insensitive: original persona notes also live in "bg3coop".
    # Remove only this mode's known files, never recurse into notes or unknown directories.
    $files = @('config.json','bridge.json','tasks.sqlite3','tasks.sqlite3-journal','tasks.sqlite3-wal','tasks.sqlite3-shm',
        'daemon.log','daemon.log.1','daemon.log.2','daemon.log.3','launcher.log','launcher.log.1','launcher.log.2','daemon.pid','enabled',
        'background-launcher.ps1','process-job.ps1')
    foreach ($name in $files) {
        $file = Join-Path $runtime $name
        if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force }
    }
    if ([IO.Directory]::GetFileSystemEntries($runtime).Length -eq 0) { Remove-Item -LiteralPath $runtime -Force }
}
Write-Host 'Uninstalled local startup. Game files, saves, mods and existing MCP setup were preserved.'
