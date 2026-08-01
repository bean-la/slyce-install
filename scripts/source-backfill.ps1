$ErrorActionPreference = 'SilentlyContinue'
$state = 'C:\ProgramData\Slyce\config\backfill-queue.json'
$log = 'C:\ProgramData\Slyce\logs\source-backfill.log'
if (-not (Test-Path $state)) { exit }
$queue = @(Get-Content $state -Raw | ConvertFrom-Json)
if ($queue.Count -eq 0) { exit }
try {
  $r = Invoke-WebRequest -Uri 'http://127.0.0.1:2022/trpc/plane.local.queue.status?input=%7B%7D' -UseBasicParsing -TimeoutSec 8
  $data = ($r.Content | ConvertFrom-Json).result.data
  $busy = $false
  foreach ($w in $data.workers) {
    if (($w.type -eq 's3-push-source' -or $w.type -eq 's3.push.source') -and $w.isRunning) { $busy = $true }
  }
  if ($busy) { exit }
  $key = $queue[0]
  $rest = @($queue | Select-Object -Skip 1)
  $body = (@{ type = 's3-push-source'; data = @{ sourceKey = $key } } | ConvertTo-Json -Compress)
  $add = Invoke-WebRequest -Uri 'http://127.0.0.1:2022/trpc/plane.local.queue.addJob' -Method POST -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 8
  ($rest | ConvertTo-Json -Compress) | Set-Content $state -Encoding UTF8
  ("{0} enqueued {1} -> HTTP {2}" -f (Get-Date).ToString('o'), $key, $add.StatusCode) | Out-File -Append $log -Encoding UTF8
} catch {
  ("{0} ERROR {1}" -f (Get-Date).ToString('o'), $_.Exception.Message) | Out-File -Append $log -Encoding UTF8
}
