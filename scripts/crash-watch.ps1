$ErrorActionPreference = 'SilentlyContinue'
$log = 'C:\ProgramData\Slyce\logs\crash-forensics.log'
$st = 'C:\ProgramData\Slyce\config\crash-watch-state.txt'
$since = if (Test-Path $st) { Get-Date (Get-Content $st -Raw) } else { (Get-Date).AddHours(-1) }
(Get-Date).ToString('o') | Set-Content $st
$events = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$since; Id=7031,7034} -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -match 'SlyceCloudflared|SlycePlane' }
foreach ($e in $events) {
  ("=== " + $e.TimeCreated.ToString('o') + " SCM Event " + $e.Id + " ===") | Out-File -Append $log -Encoding UTF8
  (($e.Message -split "`n")[0]) | Out-File -Append $log -Encoding UTF8
  "cloudflared procs:" | Out-File -Append $log -Encoding UTF8
  Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'cloudflared.exe' } |
    Select-Object ProcessId, ParentProcessId, CreationDate | Format-Table -AutoSize | Out-String | Out-File -Append $log -Encoding UTF8
  "wrapper.err tail:" | Out-File -Append $log -Encoding UTF8
  Get-Content 'C:\ProgramData\Slyce\logs\binaries\cloudflared\SlyceCloudflared.err.log' -Tail 12 -ErrorAction SilentlyContinue | Out-File -Append $log -Encoding UTF8
  "wrapper.log tail:" | Out-File -Append $log -Encoding UTF8
  Get-Content 'C:\ProgramData\Slyce\logs\binaries\cloudflared\SlyceCloudflared.wrapper.log' -Tail 12 -ErrorAction SilentlyContinue | Out-File -Append $log -Encoding UTF8
}
$faults = Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$since; Id=1000} -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -match 'cloudflared|WinSW|Slyce' }
foreach ($f in $faults) {
  ("=== APPFAULT " + $f.TimeCreated.ToString('o') + " ===") | Out-File -Append $log -Encoding UTF8
  (($f.Message -split "`n") | Select-Object -First 6) | Out-File -Append $log -Encoding UTF8
}
