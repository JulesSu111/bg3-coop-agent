# Optional manual entry point. The login task starts pythonw supervisor directly.
param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'
$runtime = [IO.Path]::GetFullPath($Root)
$settings = Get-Content -LiteralPath (Join-Path $runtime 'config.json') -Raw | ConvertFrom-Json
$pythonw = $settings.supervisor_python
if (-not (Test-Path -LiteralPath $pythonw)) { throw 'pythonw.exe is required for hidden startup' }
$process = Start-Process -FilePath $pythonw -ArgumentList @(('"' + $settings.supervisor_script + '"'),'--root',('"' + $runtime + '"')) -WindowStyle Hidden -PassThru
$null = $process.Handle
$process.WaitForExit()
exit $process.ExitCode
