$ErrorActionPreference = 'SilentlyContinue'
$log = 'C:\ProgramData\Slyce\logs\tunnel-guard.log'
function Kill-Proc($id, $why) {
  Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
  ("{0} killed {1} pid={2}" -f (Get-Date).ToString('o'), $why, $id) | Out-File -Append -FilePath $log -Encoding UTF8
}
# --- cloudflared: keep exactly one (wrapper-parented, else newest) ---
$cfs = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'cloudflared.exe' })
if ($cfs.Count -gt 1) {
  $svc = Get-CimInstance Win32_Service -Filter "Name='SlyceCloudflared'"
  $live = 0
  if ($svc -and $svc.ProcessId) { $live = $svc.ProcessId }
  $wrapperKids = @($cfs | Where-Object { $_.ParentProcessId -eq $live })
  $keep = if ($wrapperKids.Count -gt 0) { $wrapperKids | Sort-Object CreationDate | Select-Object -Last 1 }
          else { $cfs | Sort-Object CreationDate | Select-Object -Last 1 }
  foreach ($c in $cfs) { if ($c.ProcessId -ne $keep.ProcessId) { Kill-Proc $c.ProcessId 'stale cloudflared' } }
}
# --- slyce plane: kill only REAL plane instances (cmdline contains "plane"),
# --- never detached run-job executors (they are parented by the plane, not the
# --- WinSW wrapper; killing them orphans in-flight uploads - sbm7/mbr2/dubstream 2026-08-02).
$psvc = Get-CimInstance Win32_Service -Filter "Name='SlycePlane'"
$livePid = 0
if ($psvc -and $psvc.ProcessId) { $livePid = $psvc.ProcessId }
$slyce = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'slyce.exe' -and $_.CommandLine -match '\bplane\b' })
foreach ($s in $slyce) {
  if ($livePid -gt 0) {
    if ($s.ParentProcessId -ne $livePid) { Kill-Proc $s.ProcessId 'orphan slyce plane' }
  } else {
    Kill-Proc $s.ProcessId 'slyce plane (no live wrapper)'
  }
}
