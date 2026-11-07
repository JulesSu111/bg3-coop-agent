[CmdletBinding()]
param([string]$CodexPath, [string]$PythonPath, [switch]$ConfigureGame)
$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
$runtime = Join-Path $env:LOCALAPPDATA 'BG3Coop'
$taskName = 'BG3Coop-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if (-not $PythonPath) { $PythonPath = Join-Path $source '.venv\Scripts\python.exe' }
if (-not (Test-Path -LiteralPath $PythonPath)) {
    & uv sync --python 3.13 --no-dev --project $source
    if ($LASTEXITCODE -ne 0) { throw 'uv sync failed' }
}
$PythonPath = (Resolve-Path -LiteralPath $PythonPath).Path
$basePython = (& $PythonPath -c 'import sys; print(sys._base_executable)').Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve native base Python' }
$PythonwPath = Join-Path ([IO.Path]::GetDirectoryName($basePython)) 'pythonw.exe'
if (-not (Test-Path -LiteralPath $PythonwPath)) { throw 'Native base pythonw.exe is required for hidden login startup' }
if (-not $CodexPath) {
    $command = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($command) { $CodexPath = $command.Source }
    else {
        $candidates = Get-ChildItem -Path (Join-Path $env:USERPROFILE '.codex\packages\standalone\releases\*\bin\codex.exe') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        if ($candidates) { $CodexPath = $candidates[0].FullName }
        else { throw 'Codex executable not found; pass -CodexPath with the native executable path.' }
    }
}
$CodexPath = (Resolve-Path -LiteralPath $CodexPath).Path
if ([IO.Path]::GetExtension($CodexPath) -ne '.exe') { throw 'Pass the native Codex executable with -CodexPath.' }
& $PythonPath -c 'import bg3coop.daemon'
if ($LASTEXITCODE -ne 0) { throw 'Python must have this repository installed (uv sync).' }
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
# Per-user credentials and chat logs: remove inherited access and grant only this user and SYSTEM.
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& icacls.exe $runtime /reset | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot reset runtime directory ACL' }
& icacls.exe $runtime /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot restrict runtime directory ACL' }
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $taskName }
$previous = Get-CimInstance Win32_Process | Where-Object {
    $_.Name -in @('python.exe','pythonw.exe') -and $_.CommandLine -like '*-m bg3coop.daemon*' -and $_.CommandLine.Contains($runtime)
}
foreach ($process in $previous) { & taskkill.exe /PID $process.ProcessId /T /F | Out-Null }
if (-not (Test-Path -LiteralPath (Join-Path $runtime 'bridge.json'))) {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    @{ port = 19999; token = [Convert]::ToBase64String($bytes) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtime 'bridge.json') -Encoding UTF8
}
$configPath = Join-Path $runtime 'config.json'
if (Test-Path -LiteralPath $configPath) { $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json }
else { $config = Get-Content -LiteralPath (Join-Path $source 'config\windows-local.json') -Raw | ConvertFrom-Json }
$defaults = Get-Content -LiteralPath (Join-Path $source 'config\windows-local.json') -Raw | ConvertFrom-Json
foreach ($property in $defaults.PSObject.Properties) {
    if (-not $config.PSObject.Properties[$property.Name]) {
        $config | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
    }
}
$config.codex = $CodexPath
$config | Add-Member -NotePropertyName python -NotePropertyValue $PythonPath -Force
$config | Add-Member -NotePropertyName supervisor_python -NotePropertyValue $PythonwPath -Force
$config | Add-Member -NotePropertyName supervisor_script -NotePropertyValue (Join-Path $source 'src\bg3coop\supervisor.py') -Force
$config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $source 'scripts\background-launcher.ps1') -Destination $runtime -Force
Set-Content -LiteralPath (Join-Path $runtime 'enabled') -Value 'enabled'
if ($ConfigureGame) {
    # Explicit opt-in; never install the optional save-memory mod in unattended setup.
    & $PythonPath -m bg3coop.cli setup --no-mod
    if ($LASTEXITCODE -ne 0) { throw 'Game setup failed' }
}
$launcher = Join-Path $runtime 'background-launcher.ps1'
$action = New-ScheduledTaskAction -Execute $PythonwPath -Argument ('"' + $config.supervisor_script + '" --root "' + $runtime + '"') -WorkingDirectory $source
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $sid
$principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Host "Installed. Runtime/config/logs: $runtime. Start BG3, load a save, press F10."
