$ErrorActionPreference = 'SilentlyContinue'
$state = 'C:\ProgramData\Slyce\config\backfill-queue.json'
$log = 'C:\ProgramData\Slyce\logs\source-backfill.log'
function Log-Msg($m) { ("{0} {1}" -f (Get-Date).ToString('o'), $m) | Out-File -Append -FilePath $log -Encoding UTF8 }
function Read-Queue {
  $raw = Get-Content $state -Raw -ErrorAction SilentlyContinue
  if (-not $raw) { return ,@() }
  $p = $raw | ConvertFrom-Json
  if ($null -eq $p) { return ,@() }
  if ($p -is [System.Array]) { return ,@($p) }
  if (($p.PSObject.Properties.Name -contains 'value') -and ($p.value -is [System.Array])) { return ,@($p.value) }
  return ,@($p)
}
function Write-Queue($arr) {
  if ($arr.Count -eq 0) { Set-Content $state '[]' -Encoding UTF8 -Force; return }
  ($arr | ConvertTo-Json -Compress) | Set-Content $state -Encoding UTF8 -Force
}
$queue = Read-Queue
if ($queue.Count -eq 0) { exit }
$base = 'http://127.0.0.1:2022/trpc/'
try {
  $r = Invoke-WebRequest -Uri ($base + 'plane.local.queue.status?input=%7B%7D') -UseBasicParsing -TimeoutSec 8
  $data = ($r.Content | ConvertFrom-Json).result.data
} catch { Log-Msg ('plane unreachable: ' + $_.Exception.Message); exit }
$busy = $false
foreach ($w in $data.workers) {
  if (($w.type -eq 's3-push-source' -or $w.type -eq 's3.push.source') -and $w.isRunning) { $busy = $true }
}
if ($busy) { exit }
$top = [string]$queue[0]
$today = (Get-Date -Format 'yyyy-MM-dd')
$wlog = 'C:\ProgramData\Slyce\logs\worker-' + $today + '.json.log'
$completed = $null
if (Test-Path $wlog) {
  $line = Get-Content $wlog -Tail 30000 | Select-String 's3-push-source: obj' | Select-Object -Last 1
  if ($line -and $line.Line -match 'mbr2/([0-9]{4}-[0-9]{2}-[0-9]{2}[_-][0-9]{2}-[0-9]{2})/PROGRAM\.mp4') {
    $completed = 'mbr2__' + $matches[1] + '__PROGRAM'
  }
}
if ($completed -and $completed -eq $top) {
  $queue = @($queue | Select-Object -Skip 1)
  Write-Queue $queue
  Log-Msg ('completed+popped ' + $top + ' (remaining ' + $queue.Count + ')')
  if ($queue.Count -eq 0) { exit }
  $queue = Read-Queue
  $top = [string]$queue[0]
}
$body = (@{ type = 's3-push-source'; data = @{ sourceKey = $top } } | ConvertTo-Json -Compress)
try {
  $add = Invoke-WebRequest -Uri ($base + 'plane.local.queue.addJob') -Method POST -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 8
  Log-Msg ('enqueued ' + $top + ' -> HTTP ' + $add.StatusCode)
} catch { Log-Msg ('enqueue FAILED for ' + $top + ': ' + $_.Exception.Message) }
