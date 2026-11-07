# Isolated standby measurement: no installation, no real Codex, no scheduled-task changes.
[CmdletBinding()]
param([int]$Seconds = 30, [string]$PythonPath = (Join-Path $PSScriptRoot '..\.venv\Scripts\python.exe'))
$ErrorActionPreference = 'Stop'
if ($Seconds -lt 5 -or $Seconds -gt 60) { throw 'Seconds must be between 5 and 60' }
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$python = (Resolve-Path -LiteralPath $PythonPath).Path
& $python -c 'from bg3coop.process_watch import game_running; import sys; sys.exit(1 if game_running() else 0)'
if ($LASTEXITCODE -ne 0) { throw 'Close BG3 before profiling standby' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('bg3coop-profile-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$launcher = $null
function Get-ProfileTree([int]$ParentId) {
    $snapshot = Get-CimInstance Win32_Process
    $ids = New-Object 'System.Collections.Generic.HashSet[int]'
    $null = $ids.Add($ParentId)
    do {
        $changed = $false
        foreach ($entry in $snapshot) {
            if ($ids.Contains([int]$entry.ParentProcessId) -and $ids.Add([int]$entry.ProcessId)) { $changed = $true }
        }
    } while ($changed)
    foreach ($processId in $ids) {
        try {
            $process = [Diagnostics.Process]::GetProcessById($processId)
            $null = $process.Handle
            $process
        } catch [ArgumentException] { }
    }
}
try {
    Copy-Item -LiteralPath (Join-Path $source 'scripts\background-launcher.ps1') -Destination $root
    $config = Get-Content -LiteralPath (Join-Path $source 'config\windows-local.json') -Raw | ConvertFrom-Json
    $config.codex = Join-Path $root 'NO-REAL-CODEX.exe'
    $config | Add-Member -NotePropertyName python -NotePropertyValue $python
    $config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'config.json') -Encoding UTF8
    @{port=0; token='isolated-profile'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bridge.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root 'enabled') -Value 'test'
    $basePython = (& $python -c 'import sys; print(sys._base_executable)').Trim()
    $pythonw = Join-Path ([IO.Path]::GetDirectoryName($basePython)) 'pythonw.exe'
    $launcher = Start-Process -FilePath $pythonw -ArgumentList @(('"' + (Join-Path $source 'src\bg3coop\supervisor.py') + '"'),'--root',('"' + $root + '"')) -WindowStyle Hidden -PassThru -WorkingDirectory $source
    $null = $launcher.Handle
    $deadline = (Get-Date).AddSeconds(15)
    $pidFile = Join-Path $root 'daemon.pid'
    while (-not (Test-Path -LiteralPath $pidFile) -and -not $launcher.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $pidFile)) { throw 'Isolated launcher did not start; another launcher may own the mutex' }
    $daemon = [Diagnostics.Process]::GetProcessById([int](Get-Content -LiteralPath $pidFile))
    $null = $daemon.Handle
    Start-Sleep -Seconds 1
    $launcher.Refresh(); $daemon.Refresh()
    $processes = @(Get-ProfileTree $launcher.Id)
    $initialCpu = ($processes | ForEach-Object { $_.TotalProcessorTime.TotalSeconds } | Measure-Object -Sum).Sum
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds $Seconds
    $watch.Stop()
    $launcher.Refresh(); $daemon.Refresh()
    foreach ($process in $processes) { $process.Refresh() }
    $cpu = ($processes | ForEach-Object { $_.TotalProcessorTime.TotalSeconds } | Measure-Object -Sum).Sum - $initialCpu
    $workingSet = ($processes | ForEach-Object { $_.WorkingSet64 } | Measure-Object -Sum).Sum
    $privateMemory = ($processes | ForEach-Object { $_.PrivateMemorySize64 } | Measure-Object -Sum).Sum
    $log = Join-Path $root 'daemon.log'
    $logBytes = if (Test-Path -LiteralPath $log) { (Get-Item -LiteralPath $log).Length } else { 0 }
    [pscustomobject]@{
        Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
        CpuSeconds = [math]::Round($cpu, 4)
        CpuPercentOneCore = [math]::Round(100 * $cpu / $watch.Elapsed.TotalSeconds, 3)
        ProcessCountIncludingRedirectors = $processes.Length
        SupervisorWorkingSetMB = [math]::Round($launcher.WorkingSet64 / 1MB, 2)
        CombinedWorkingSetMB = [math]::Round($workingSet / 1MB, 2)
        CombinedPrivateMemoryMB = [math]::Round($privateMemory / 1MB, 2)
        DaemonLogBytes = $logBytes
        LauncherLogBytes = if (Test-Path -LiteralPath (Join-Path $root 'launcher.log')) { (Get-Item -LiteralPath (Join-Path $root 'launcher.log')).Length } else { 0 }
    } | ConvertTo-Json
} finally {
    if ($launcher -and -not $launcher.HasExited) { $launcher.Kill(); $launcher.WaitForExit() }
    # The launcher job owns only these isolated test descendants.
    Start-Sleep -Milliseconds 200
    $resolved = [IO.Path]::GetFullPath($root)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ne $tempRoot.TrimEnd('\') -or -not [IO.Path]::GetFileName($resolved).StartsWith('bg3coop-profile-')) { throw 'Unsafe profile cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
