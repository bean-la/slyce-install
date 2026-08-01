# SlyceTunnelGuard — reap orphan cloudflared processes (tunnel flapping fix)
#
# Root cause (2026-08-01): the SlyceCloudflared WinSW service crashes periodically
# (SCM 7031s — up to 842x in a storm on 7/25, ~1/day since). Each crash orphans the
# child cloudflared.exe (parent dies, child keeps running). The service restarts and
# spawns a NEW cloudflared for the SAME named tunnel ID, so over days the box
# accumulates 2-9 cloudflared processes racing one tunnel -> Cloudflare edge flaps
# between connections -> intermittent 502s / 10s timeouts ("tunnel flapping").
#
# This task (every 10 min, SYSTEM) kills any cloudflared that is:
#   - an orphan (parent process no longer exists), or
#   - not the newest wrapper-parented process when multiple are alive.
# Keeps exactly one tunnel process per box regardless of WinSW crashes.
#
# Install:
#   Copy to C:\ProgramData\Slyce\scripts\tunnel-guard.ps1
#   schtasks /create /tn "SlyceTunnelGuard" /tr "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\ProgramData\Slyce\scripts\tunnel-guard.ps1" /sc MINUTE /mo 10 /ru SYSTEM /f
#
# Related fixes applied same day:
#   - cloudflared.yml regenerated with 127.0.0.1 (not localhost; on some boxes
#     localhost resolves to [::1] while the plane binds IPv4 only -> 502/530).
#   - cloudflare_cert.pem was 0 bytes (mbr2) -> restored from cloudflare_cert2.pem
#     so the plane's in-process tunnel fallback can start if the wrapper dies.

$ErrorActionPreference = 'SilentlyContinue'
$log = 'C:\ProgramData\Slyce\logs\tunnel-guard.log'
$cfs = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'cloudflared.exe' })
if ($cfs.Count -lt 2) { exit }

$svc = Get-CimInstance Win32_Service -Filter "Name='SlyceCloudflared'"
$live = 0
if ($svc -and $svc.ProcessId) { $live = $svc.ProcessId }

$toKill = New-Object System.Collections.ArrayList
foreach ($c in $cfs) {
  $parentAlive = $null -ne (Get-Process -Id $c.ParentProcessId -ErrorAction SilentlyContinue)
  if (-not $parentAlive) { [void]$toKill.Add($c.ProcessId) }
}
if ($cfs.Count -gt 1) {
  $wrapperKids = @($cfs | Where-Object { $_.ParentProcessId -eq $live })
  $keep = if ($wrapperKids.Count -gt 0) { $wrapperKids | Sort-Object CreationDate | Select-Object -Last 1 }
          else { $cfs | Sort-Object CreationDate | Select-Object -Last 1 }
  foreach ($c in $cfs) { if ($c.ProcessId -ne $keep.ProcessId) { [void]$toKill.Add($c.ProcessId) } }
}
$killed = @($toKill | Sort-Object -Unique)
foreach ($id in $killed) {
  Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
  ("{0} killed stale cloudflared {1}" -f (Get-Date).ToString('o'), $id) | Out-File -Append -FilePath $log -Encoding UTF8
}
