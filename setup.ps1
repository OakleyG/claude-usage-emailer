# Installer for claude-usage-emailer on Windows. Safe to run more than once.
#
#   powershell -ExecutionPolicy Bypass -File setup.ps1
#   powershell -ExecutionPolicy Bypass -File setup.ps1 -Hour 7 -Minute 30
#   powershell -ExecutionPolicy Bypass -File setup.ps1 -Uninstall
#
# The SMTP_HOST, SMTP_PORT, SMTP_FROM, SMTP_USERNAME and SMTP_PASSWORD
# environment variables fill the smtp section of config.json, if set.
param(
    [int]$Hour = 8,
    [int]$Minute = 0,
    [string]$InstallDir = (Join-Path $env:USERPROFILE "claude-usage-emailer"),
    [switch]$Uninstall
)
$ErrorActionPreference = "Stop"
$TaskName = "claude-usage-emailer"

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Scheduled task removed. Delete $InstallDir yourself if you no longer need the config or logs."
    exit 0
}

# 1. Find a real Python 3 (not the Microsoft Store stub).
$Py = $null
foreach ($cmd in @(@("py", "-3"), @("python"), @("python3"))) {
    try {
        $extra = @($cmd | Select-Object -Skip 1)
        $exe = & $cmd[0] @extra -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $exe -and (Test-Path $exe)) { $Py = $exe.Trim(); break }
    } catch { }
}
if (-not $Py) {
    Write-Host "Python 3 not found. Install it from https://www.python.org/downloads/ (tick 'Add to PATH'), then re-run."
    exit 1
}

# 2. Copy files.
$Src = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
if ((Resolve-Path $Src).Path -ne (Resolve-Path $InstallDir).Path) {
    foreach ($f in @("usage_report.py", "config.example.json", "README.md", "AGENT_SETUP.md", "setup.ps1")) {
        $p = Join-Path $Src $f
        if (Test-Path $p) { Copy-Item $p $InstallDir -Force }
    }
}
Set-Location $InstallDir

# 3. Create config.json once and restrict it to the current user.
$Config = Join-Path $InstallDir "config.json"
if (-not (Test-Path $Config)) {
    Copy-Item (Join-Path $InstallDir "config.example.json") $Config
    Write-Host "Created $Config"
}
icacls $Config /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null

# 4. Fill smtp settings from environment variables, if given.
& $Py -c @"
import json, os
p = r'$Config'; c = json.load(open(p, encoding='utf-8')); s = c.setdefault('smtp', {})
for env, key in [('SMTP_HOST','host'),('SMTP_PORT','port'),('SMTP_FROM','from'),
                 ('SMTP_USERNAME','username'),('SMTP_PASSWORD','password')]:
    v = os.environ.get(env)
    if v:
        s[key] = int(v) if key == 'port' else v
json.dump(c, open(p, 'w', encoding='utf-8'), indent=2)
"@

# 5. Schedule with Task Scheduler. StartWhenAvailable runs a missed send
#    as soon as the PC is back on.
$Script = Join-Path $InstallDir "usage_report.py"
$Log = Join-Path $InstallDir "run.log"
$Action = New-ScheduledTaskAction -Execute "cmd.exe" `
    -Argument "/c `"`"$Py`" `"$Script`" >> `"$Log`" 2>&1`"" -WorkingDirectory $InstallDir
$Trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($Hour).AddMinutes($Minute))
$Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings `
    -Description "Email daily Claude API spend" -Force | Out-Null
Write-Host ("Scheduled in Task Scheduler: every day at {0:D2}:{1:D2}." -f $Hour, $Minute)

# 6. Say what is left.
Write-Host ""
if ((Get-Content $Config -Raw) -match "PASTE_ADMIN_KEY_HERE") {
    Write-Host "Next: paste your Admin API key into $Config, then run"
    Write-Host "  `"$Py`" `"$Script`" --check"
} else {
    & $Py $Script --check
}
$smtp = (Get-Content $Config -Raw | ConvertFrom-Json).smtp
if (-not $smtp.from -or -not $smtp.password) {
    Write-Host "Email is not set up yet: fill in the smtp section of config.json."
}
