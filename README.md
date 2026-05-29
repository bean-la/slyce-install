# slyce-install

Install and recovery scripts for Slyce CLI/runtime boxes.

## Install (stable)

Windows PowerShell 5.1-safe:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$IsWindows=$true; irm https://raw.githubusercontent.com/bean-la/slyce-install/main/install-slyce.ps1 | iex"
```

macOS/Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/bean-la/slyce-install/main/install-slyce.sh | sh
```

## Install (staging channel)

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$IsWindows=$true; irm https://raw.githubusercontent.com/bean-la/slyce-install/main/install-slyce-staging.ps1 | iex"
```

## Doctor / force-upgrade helper (Windows)

Runs install + `slyce upgrade` + `slyce service repair` + `slyce restart`.

Default channel is `prod`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$IsWindows=$true; irm https://raw.githubusercontent.com/bean-la/slyce-install/main/doctor-slyce.ps1 | iex"
```

Optional channel override before running doctor:

```powershell
$env:SLYCE_DOCTOR_CHANNEL="staging"
```

## Notes

- If service/ACL operations fail, rerun the command in an elevated PowerShell (Run as Administrator).
- If `slyce version` lags immediately after upgrade on Windows, wait a few seconds and run it again.
