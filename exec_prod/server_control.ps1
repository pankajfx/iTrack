<#
===================================================================================
   SERVER CONTROL (WINDOWS PRODUCTION) – INTERACTIVE MENU
   Author: Generated for Pankaj
   Features:
      ✔ Python install check / auto-install (winget/choco)
      ✔ Virtual environment management
      ✔ Flask app via WAITRESS (start/stop/restart/status/logs)
      ✔ MongoDB install check / auto-install / service control
      ✔ Windows Service wrapper for app via NSSM (auto-install + manage)
      ✔ Log rotation (auto + manual)
      ✔ Port conflict resolver (detect -> kill/change port)
      ✔ Backups (zip) & restore for app
      ✔ Config & State JSON persisted
      ✔ Colored UI, robust navigation ('back' / exit only via 'quit')
===================================================================================
#>

# ----------------------------
# GLOBALS & INITIALIZATION
# ----------------------------

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptRoot

# Paths (relative to exec_prod)
$configPath   = Join-Path $ScriptRoot "config.json"
$statePath    = Join-Path $ScriptRoot "state.json"
$logsDir      = Join-Path $ScriptRoot "logs"
$backupsDir   = Join-Path $ScriptRoot "backups"
$scriptLog    = Join-Path $logsDir  "script.log"

# Ensure dirs
foreach ($d in @($logsDir, $backupsDir)) { if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }

# ----------------------------
# LOGGING / UI HELPERS
# ----------------------------

function Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$timestamp [$Level] $Message" | Out-File -FilePath $scriptLog -Append -Encoding UTF8
}

function Color([string]$text, [string]$color="Gray") { Write-Host $text -ForegroundColor $color }

function Header([string]$txt) {
    Write-Host ""
    Write-Host "==============================" -ForegroundColor Cyan
    Write-Host $txt -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor Cyan
    Write-Host ""
}

function Is-Admin {
    return ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent() `
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Pause-Enter { Write-Host ""; Read-Host "Press ENTER to continue" | Out-Null }

function Read-Choice([string]$prompt="> ") {
    Write-Host ""
    $c = Read-Host $prompt
    return ($c.Trim())
}

function Ask-YesNo([string]$q, [bool]$defaultNo=$false) {
    $suffix = $(if ($defaultNo) { "[y/N]" } else { "[Y/n]" })
    while ($true) {
        $ans = Read-Host "$q $suffix"
        if ([string]::IsNullOrWhiteSpace($ans)) { return -not $defaultNo }
        switch ($ans.Trim().ToLower()) {
            "y" { return $true }
            "yes" { return $true }
            "n" { return $false }
            "no" { return $false }
            default { Color "Please answer y/n." "Yellow" }
        }
    }
}

# ----------------------------
# CONFIG & STATE
# ----------------------------

function Load-Config {
    if (!(Test-Path $configPath)) {
        $default = @{
            pythonPreferredCommands = @("python","py -3")
            venvPath = ".\exec_prod\venv"
            appDir   = ".\app"
            wsgiEntrypoint = "app:app"
            host = "0.0.0.0"
            port = 8000
            useWaitressCLI = $true
            logsDir = ".\exec_prod\logs"
            pidFile = ".\exec_prod\app.pid"
            mongodbServiceNames = @("MongoDB","MongoDB Server")
            mongodbLogPath = ""   # set in Config menu if detected empty
            service = @{
                enabled = $false
                name = "FlaskWaitressService"
                nssmExe = ""       # auto-detect or fill after install
                startMode = "auto" # auto | demand | disabled
            }
            installHints = @{
                python = @(
                    "winget install --id Python.Python.3 --source winget",
                    "choco install python -y"
                )
                mongodb = @(
                    "winget install --id MongoDB.MongoDBServer --source winget",
                    "choco install mongodb -y"
                )
                nssm = @(
                    "winget install --id NSSM.NSSM --source winget",
                    "choco install nssm -y"
                )
            }
            logRotationMB = 20
        }
        $default | ConvertTo-Json -Depth 10 | Out-File $configPath -Encoding utf8
    }
    return (Get-Content $configPath -Raw | ConvertFrom-Json)
}
function Save-Config { param([Parameter(Mandatory)]$cfg) $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8 }

function Load-State {
    if (!(Test-Path $statePath)) {
        $default = @{
            app     = @{ lastStart = ""; lastStop = "" }
            mongodb = @{ lastStart = ""; lastStop = "" }
        }
        $default | ConvertTo-Json -Depth 10 | Out-File $statePath -Encoding utf8
    }
    return (Get-Content $statePath -Raw | ConvertFrom-Json)
}
function Save-State { param([Parameter(Mandatory)]$st) $st | ConvertTo-Json -Depth 10 | Set-Content -Path $statePath -Encoding UTF8 }

$Config = Load-Config
$State  = Load-State

# Ensure config logs dir exists if user edited to a custom path
if ($Config.logsDir -and !(Test-Path $Config.logsDir)) { New-Item -ItemType Directory -Path $Config.logsDir | Out-Null }

# ----------------------------
# TOOL DETECTION & INSTALLERS
# ----------------------------

function Has-Command([string]$cmd) {
    return $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Ensure-Admin-Guard([string]$context="this action") {
    if (-not (Is-Admin)) {
        Color "Administrator rights are required for $context. Please run PowerShell as Administrator." "Red"
        return $false
    }
    return $true
}

function Install-WithWinget([string]$id, [string]$desc) {
    if (-not (Has-Command "winget")) { Color "winget not found." "Yellow"; return $false }
    Color "Installing $desc via winget..." "Cyan"
    Log "winget install $id"
    Start-Process -FilePath "winget" -ArgumentList @("install", "--id", $id, "--source", "winget", "--silent", "--accept-source-agreements", "--accept-package-agreements") -Wait
    return $true
}

function Install-WithChoco([string]$pkg, [string]$desc) {
    if (-not (Has-Command "choco")) { Color "Chocolatey not found." "Yellow"; return $false }
    Color "Installing $desc via Chocolatey..." "Cyan"
    Log "choco install $pkg -y"
    Start-Process -FilePath "choco" -ArgumentList @("install", $pkg, "-y") -Wait
    return $true
}

function Install-Python {
    Color "Attempting to install Python..." "Cyan"
    if (Install-WithWinget "Python.Python.3" "Python") { return }
    if (Install-WithChoco "python" "Python") { return }
    Color "Auto-install failed. Please run one of:" "Yellow"
    $Config.installHints.python | ForEach-Object { Color "  $_" "Gray" }
}

function Install-MongoDB {
    if (-not (Ensure-Admin-Guard "installing MongoDB")) { return }
    Color "Attempting to install MongoDB Server..." "Cyan"
    if (Install-WithWinget "MongoDB.MongoDBServer" "MongoDB Server") { return }
    if (Install-WithChoco "mongodb" "MongoDB Server") { return }
    Color "Auto-install failed. Please run one of:" "Yellow"
    $Config.installHints.mongodb | ForEach-Object { Color "  $_" "Gray" }
}

function Install-NSSM {
    if (-not (Ensure-Admin-Guard "installing NSSM")) { return }
    Color "Attempting to install NSSM..." "Cyan"
    if (Install-WithWinget "NSSM.NSSM" "NSSM") { } elseif (Install-WithChoco "nssm" "NSSM") { }
    # Try discover nssm.exe
    $nssm = Get-Command "nssm" -ErrorAction SilentlyContinue
    if ($nssm) {
        $Config.service.nssmExe = $nssm.Source
        Save-Config $Config
        Color "NSSM found at: $($Config.service.nssmExe)" "Green"
    } else {
        # common install path
        $candidate = "C:\Program Files\nssm\win64\nssm.exe"
        if (Test-Path $candidate) {
            $Config.service.nssmExe = $candidate
            Save-Config $Config
            Color "NSSM found at: $($Config.service.nssmExe)" "Green"
        } else {
            Color "NSSM not found. Please install manually or add to PATH." "Red"
        }
    }
}

# ----------------------------
# PYTHON / VENV
# ----------------------------

function Find-Python {
    foreach ($cmd in $Config.pythonPreferredCommands) {
        try { & $cmd --version *>$null; if ($LASTEXITCODE -eq 0) { return $cmd } } catch {}
    }
    return $null
}

function Ensure-Venv {
    $python = Find-Python
    if (-not $python) {
        Color "Python not found." "Red"
        if (Ask-YesNo "Install Python now?" $false) { Install-Python }
        $python = Find-Python
        if (-not $python) { return $false }
    }
    if (Test-Path $Config.venvPath) { return $true }
    Color "Creating virtual environment..." "Cyan"
    & $python -m venv $Config.venvPath
    if ($LASTEXITCODE -ne 0) { Color "Failed to create venv." "Red"; return $false }
    Color "Virtual environment created." "Green"
    return $true
}

function Install-Requirements {
    $venvPip    = Join-Path $Config.venvPath "Scripts\pip.exe"
    $reqPath    = Join-Path $Config.appDir "requirements.txt"

    if (!(Test-Path $venvPip)) { Color "Venv not found." "Red"; return }
    if (Test-Path $reqPath) {
        Color "Installing requirements..." "Cyan"
        & $venvPip install --upgrade pip *> $null
        & $venvPip install -r $reqPath
    } else {
        Color "No requirements.txt found in $($Config.appDir)." "Yellow"
    }
}

function Ensure-Waitress {
    $venvPip = Join-Path $Config.venvPath "Scripts\pip.exe"
    if (!(Test-Path $venvPip)) { return $false }
    & $venvPip show waitress *> $null
    if ($LASTEXITCODE -ne 0) {
        Color "Installing waitress into venv..." "Cyan"
        & $venvPip install waitress
    }
    return $true
}

# ----------------------------
# LOG MANAGEMENT
# ----------------------------

function Rotate-Log([string]$file) {
    if (!(Test-Path $file)) { return }
    $sizeMB = [math]::Round((Get-Item $file).Length / 1MB, 2)
    if ($sizeMB -gt $Config.logRotationMB) {
        $ts = Get-Date -Format "yyyyMMdd_HHmmss"
        $dest = "$file.$ts"
        Rename-Item -Path $file -NewName $dest
        Color "Rotated log: $(Split-Path $file -Leaf) -> $(Split-Path $dest -Leaf)" "Yellow"
        Log "Rotated $file to $dest"
    }
}

function Rotate-AppLogs {
    $stdout = Join-Path $Config.logsDir "app_stdout.log"
    $stderr = Join-Path $Config.logsDir "app_stderr.log"
    Rotate-Log $stdout
    Rotate-Log $stderr
}

function Tail-Log([string]$file, [string]$keyword = "") {
    if (!(Test-Path $file)) { Color "Log not found: $file" "Red"; return }
    Color "Tailing $file (Ctrl+C to stop)..." "Cyan"
    if ([string]::IsNullOrWhiteSpace($keyword)) {
        Get-Content -Path $file -Wait -Tail 50
    } else {
        Get-Content -Path $file -Wait -Tail 0 | Where-Object { $_ -match [Regex]::Escape($keyword) }
    }
}

function Show-RecentErrors([int]$lines=100) {
    $stderr = Join-Path $Config.logsDir "app_stderr.log"
    if (!(Test-Path $stderr)) { Color "No stderr log found." "Yellow"; return }
    Color "Last $lines error lines from app_stderr.log" "Magenta"
    Get-Content $stderr -Tail $lines
}

# ----------------------------
# PORT & PROCESS
# ----------------------------

function Get-PortProcess($port) {
    try {
        $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if ($conns) {
            foreach ($c in $conns) {
                $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
                if ($p) {
                    [PSCustomObject]@{
                        Port = $port; PID = $p.Id; Name = $p.ProcessName; StartTime = $p.StartTime
                    }
                } else {
                    [PSCustomObject]@{
                        Port = $port; PID = $c.OwningProcess; Name = "Unknown"; StartTime = $null
                    }
                }
            }
        }
    } catch {}
}

function Resolve-PortConflict {
    $port = [int]$Config.port
    $busy = Get-PortProcess $port
    if ($busy) {
        Color "Port $port is in use by:" "Yellow"
        $busy | ForEach-Object { Color ("  PID {0}  Name {1}  Start {2}" -f $_.PID, $_.Name, $_.StartTime) "Gray" }
        if (Ask-YesNo "Kill these process(es)? (Admin may be needed)" $true) {
            foreach ($b in $busy) {
                try { Stop-Process -Id $b.PID -Force -ErrorAction Stop; Color "Killed PID $($b.PID)" "Green" }
                catch { Color "Failed to kill PID $($b.PID): $_" "Red" }
            }
            Start-Sleep -Seconds 1
            return $true
        } else {
            $newPort = Read-Host "Enter a different port (1-65535) or leave blank to cancel"
            if ($newPort -and ([int]$newPort -ge 1 -and [int]$newPort -le 65535)) {
                $Config.port = [int]$newPort
                Save-Config $Config
                Color "Updated port to $newPort in config.json" "Green"
                return $true
            }
            return $false
        }
    }
    return $true
}

# ----------------------------
# APP PROCESS CONTROL (NON-SERVICE)
# ----------------------------

function App-Status {
    $pidFile = $Config.pidFile
    if (!(Test-Path $pidFile)) { return @{ running = $false; reason = "No PID file" } }
    $pid = (Get-Content $pidFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($pid)) { Remove-Item $pidFile -Force; return @{ running = $false; reason = "Empty PID file" } }
    $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
    if ($null -eq $proc) { Remove-Item $pidFile -Force; return @{ running = $false; reason = "Stale PID file cleaned" } }
    return @{ running = $true; pid = $proc.Id; startTime = $proc.StartTime }
}

function Start-App {
    if (-not (Ensure-Venv)) { return }
    if (-not (Ensure-Waitress)) { return }

    if (-not (Resolve-PortConflict)) { Color "Start aborted due to port issue." "Red"; return }

    # Rotate logs if large
    Rotate-AppLogs

    $venvPython = Join-Path $Config.venvPath "Scripts\python.exe"

    $stdout = Join-Path $Config.logsDir "app_stdout.log"
    $stderr = Join-Path $Config.logsDir "app_stderr.log"

    $workingDir = (Resolve-Path $Config.appDir).Path

    if ($Config.useWaitressCLI) {
        $args = @("-m","waitress","--host",$Config.host,"--port",$Config.port.ToString(),$Config.wsgiEntrypoint)
    } else {
        $pyCmd = "from waitress import serve; import importlib; m,o='$($Config.wsgiEntrypoint)'.split(':'); app=getattr(importlib.import_module(m),o); serve(app,host='$($Config.host)',port=$($Config.port))"
        $args = @("-c", $pyCmd)
    }

    try {
        $p = Start-Process -FilePath $venvPython -ArgumentList $args `
              -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
              -WorkingDirectory $workingDir -PassThru -WindowStyle Hidden
        $p.Id | Out-File $Config.pidFile -Encoding utf8
        $State.app.lastStart = (Get-Date).ToString("o")
        Save-State $State
        Color "App started (PID $($p.Id)) on $($Config.host):$($Config.port)" "Green"
    } catch {
        Color "Failed to start app: $_" "Red"
    }
}

function Stop-App {
    $st = App-Status
    if (-not $st.running) { Color "App not running. ($($st.reason))" "Yellow"; return }
    try {
        Stop-Process -Id $st.pid -Force -ErrorAction Stop
        if (Test-Path $Config.pidFile) { Remove-Item $Config.pidFile -Force }
        $State.app.lastStop = (Get-Date).ToString("o")
        Save-State $State
        Color "App stopped." "Green"
    } catch {
        Color "Failed to stop app: $_" "Red"
    }
}

function Restart-App { Stop-App; Start-Sleep 1; Start-App }

# ----------------------------
# WINDOWS SERVICE (NSSM)
# ----------------------------

function Get-NSSM {
    if ($Config.service.nssmExe -and (Test-Path $Config.service.nssmExe)) { return $Config.service.nssmExe }
    $cmd = Get-Command "nssm" -ErrorAction SilentlyContinue
    if ($cmd) { $Config.service.nssmExe = $cmd.Source; Save-Config $Config; return $cmd.Source }
    $default = "C:\Program Files\nssm\win64\nssm.exe"
    if (Test-Path $default) { $Config.service.nssmExe = $default; Save-Config $Config; return $default }
    return $null
}

function Service-Exists([string]$name) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    return $null -ne $svc
}

function Service-Status([string]$name) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) { return @{ exists=$false } }
    $running = $svc.Status -eq 'Running'
    # Try process start time via WMI/CIM
    $pid = (Get-CimInstance Win32_Service -Filter "Name='$name'").ProcessId
    $startTime = $null
    if ($pid -gt 0) { $p = Get-Process -Id $pid -ErrorAction SilentlyContinue; if ($p) { $startTime = $p.StartTime } }
    return @{ exists=$true; running=$running; status=$svc.Status; pid=$pid; startTime=$startTime }
}

function Create-AppService {
    if (-not (Ensure-Admin-Guard "creating a Windows Service")) { return }
    if (-not (Ensure-Venv)) { return }
    if (-not (Ensure-Waitress)) { return }

    $nssm = Get-NSSM
    if (-not $nssm) {
        Color "NSSM not found." "Yellow"
        if (Ask-YesNo "Install NSSM now? (winget/choco)" $false) { Install-NSSM; $nssm = Get-NSSM }
        if (-not $nssm) { Color "Cannot proceed without NSSM." "Red"; return }
    }

    $svcName = $Config.service.name
    if (Service-Exists $svcName) {
        Color "Service '$svcName' already exists." "Yellow"
        if (-not (Ask-YesNo "Recreate service?" $true)) { return }
        & $nssm remove $svcName confirm
        Start-Sleep 1
    }

    $venvPython = (Resolve-Path (Join-Path $Config.venvPath "Scripts\python.exe")).Path
    $workDir    = (Resolve-Path $Config.appDir).Path

    $args = @()
    if ($Config.useWaitressCLI) {
        $args = @("-m","waitress","--host",$Config.host,"--port",$Config.port.ToString(),$Config.wsgiEntrypoint)
    } else {
        $pyCmd = "from waitress import serve; import importlib; m,o='$($Config.wsgiEntrypoint)'.split(':'); app=getattr(importlib.import_module(m),o); serve(app,host='$($Config.host)',port=$($Config.port))"
        $args  = @("-c",$pyCmd)
    }
    $argLine = ($args | ForEach-Object {
        if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
    }) -join ' '

    $stdout = (Resolve-Path (Join-Path $Config.logsDir "app_stdout.log")).Path
    $stderr = (Resolve-Path (Join-Path $Config.logsDir "app_stderr.log")).Path

    Color "Creating service '$svcName' with NSSM..." "Cyan"
    & $nssm install $svcName $venvPython $argLine
    & $nssm set $svcName AppDirectory $workDir
    & $nssm set $svcName AppStdout   $stdout
    & $nssm set $svcName AppStderr   $stderr
    & $nssm set $svcName Start       $(if ($Config.service.startMode -eq "auto") {"SERVICE_AUTO_START"} else {"SERVICE_DEMAND_START"})
    & $nssm set $svcName AppStopMethodSkip 6  # try stop gracefully then kill
    & $nssm set $svcName AppStopMethodConsole 15000
    & $nssm set $svcName AppStopMethodWindow  15000
    & $nssm set $svcName AppStopMethodThreads  0

    Color "Service '$svcName' created." "Green"
    $Config.service.enabled = $true
    Save-Config $Config
}

function Remove-AppService {
    if (-not (Ensure-Admin-Guard "removing a Windows Service")) { return }
    $svcName = $Config.service.name
    if (-not (Service-Exists $svcName)) { Color "Service '$svcName' does not exist." "Yellow"; return }
    $nssm = Get-NSSM
    if (-not $nssm) { Color "NSSM not found. Cannot remove." "Red"; return }
    if (Ask-YesNo "Stop and remove service '$svcName'?" $true) {
        & $nssm stop $svcName
        & $nssm remove $svcName confirm
        $Config.service.enabled = $false
        Save-Config $Config
        Color "Service removed." "Green"
    }
}

function Start-AppService { if (-not (Ensure-Admin-Guard "starting service")) { return }; Start-Service -Name $Config.service.name; Color "Service started." "Green" }
function Stop-AppService  { if (-not (Ensure-Admin-Guard "stopping service")) { return }; Stop-Service  -Name $Config.service.name; Color "Service stopped."  "Green" }
function Restart-AppService { if (-not (Ensure-Admin-Guard "restarting service")) { return }; Restart-Service -Name $Config.service.name; Color "Service restarted." "Green" }

# ----------------------------
# MONGODB CONTROL
# ----------------------------

function Get-Mongo-Service {
    foreach ($name in $Config.mongodbServiceNames) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) { return $svc }
    }
    return $null
}

function Mongo-Status {
    $svc = Get-Mongo-Service
    if (-not $svc) { return @{ installed = $false } }
    $running = $svc.Status -eq "Running"
    $pid = (Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'").ProcessId
    $startTime = $null
    if ($pid -gt 0) { $p = Get-Process -Id $pid -ErrorAction SilentlyContinue; if ($p) { $startTime = $p.StartTime } }
    return @{ installed=$true; name=$svc.Name; running=$running; status=$svc.Status; pid=$pid; startTime=$startTime }
}

function Start-Mongo {
    if (-not (Ensure-Admin-Guard "starting MongoDB service")) { return }
    $svc = Get-Mongo-Service
    if (!$svc) {
        Color "MongoDB not installed." "Yellow"
        if (Ask-YesNo "Install MongoDB now?" $false) { Install-MongoDB }
        return
    }
    Start-Service $svc.Name
    $State.mongodb.lastStart = (Get-Date).ToString("o")
    Save-State $State
    Color "MongoDB started." "Green"
}

function Stop-Mongo {
    if (-not (Ensure-Admin-Guard "stopping MongoDB service")) { return }
    $svc = Get-Mongo-Service
    if (!$svc) { Color "MongoDB not installed." "Yellow"; return }
    Stop-Service $svc.Name
    $State.mongodb.lastStop = (Get-Date).ToString("o")
    Save-State $State
    Color "MongoDB stopped." "Green"
}

function Restart-Mongo {
    if (-not (Ensure-Admin-Guard "restarting MongoDB service")) { return }
    $svc = Get-Mongo-Service
    if (!$svc) { Color "MongoDB not installed." "Yellow"; return }
    Restart-Service $svc.Name
    $State.mongodb.lastStart = (Get-Date).ToString("o")
    Save-State $State
    Color "MongoDB restarted." "Green"
}

function Tail-Mongo-Logs {
    if ($Config.mongodbLogPath -and (Test-Path $Config.mongodbLogPath)) {
        Tail-Log $Config.mongodbLogPath
    } else {
        Color "MongoDB log path unknown. Set it in Config menu." "Yellow"
    }
}

# ----------------------------
# BACKUP & RESTORE
# ----------------------------

function New-AppBackup {
    $appPath = (Resolve-Path $Config.appDir).Path
    $includeVenv = Ask-YesNo "Include venv in backup? (increases size)"
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $zip = Join-Path $backupsDir "app_backup_$ts.zip"

    # Build temp staging to exclude/ include easily
    $tmp = Join-Path $env:TEMP ("app_backup_" + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Copy-Item -Path (Join-Path $ScriptRoot "config.json") -Destination $tmp -Force -ErrorAction SilentlyContinue | Out-Null
    Copy-Item -Path $appPath -Destination (Join-Path $tmp "app") -Recurse -Force
    if ($includeVenv) {
        if (Test-Path $Config.venvPath) {
            Copy-Item -Path $Config.venvPath -Destination (Join-Path $tmp "venv") -Recurse -Force
        }
    }

    Compress-Archive -Path (Join-Path $tmp "*") -DestinationPath $zip -Force
    Remove-Item $tmp -Recurse -Force
    Color "Backup created: $zip" "Green"
}

function Restore-AppBackup {
    $files = Get-ChildItem -Path $backupsDir -Filter "*.zip" | Sort-Object LastWriteTime -Descending
    if (!$files) { Color "No backups found in $backupsDir" "Yellow"; return }
    Color "Available backups:" "Cyan"
    $i = 1
    foreach ($f in $files) { Color ("[{0}] {1} ({2} MB)" -f $i, $f.Name, [math]::Round($f.Length/1MB,2)) "Gray"; $i++ }
    $sel = Read-Host "Pick a number to restore (or 'back')"
    if ($sel.Trim().ToLower() -eq "back") { return }
    $index = 0; [int]::TryParse($sel, [ref]$index) | Out-Null
    if ($index -lt 1 -or $index -gt $files.Count) { Color "Invalid selection." "Red"; return }
    $zip = $files[$index-1].FullName
    if (-not (Ask-YesNo "This will overwrite current app files (and possibly venv). Continue?" $true)) { return }

    $tmp = Join-Path $env:TEMP ("restore_" + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Expand-Archive -Path $zip -DestinationPath $tmp -Force

    # Restore config.json if included
    if (Test-Path (Join-Path $tmp "config.json")) {
        Copy-Item -Path (Join-Path $tmp "config.json") -Destination (Join-Path $ScriptRoot "config.json") -Force
        $Config = Load-Config
    }

    # Restore app folder
    $destApp = (Resolve-Path $Config.appDir -ErrorAction SilentlyContinue)
    if ($destApp) {
        Remove-Item $destApp.Path -Recurse -Force
    } else {
        New-Item -ItemType Directory -Path $Config.appDir | Out-Null
    }
    Copy-Item -Path (Join-Path $tmp "app\*") -Destination $Config.appDir -Recurse -Force

    # Restore venv if present in backup
    $backupVenv = Join-Path $tmp "venv"
    if (Test-Path $backupVenv) {
        if (Test-Path $Config.venvPath) { Remove-Item $Config.venvPath -Recurse -Force }
        Copy-Item -Path $backupVenv -Destination $Config.venvPath -Recurse -Force
    }

    Remove-Item $tmp -Recurse -Force
    Color "Restore complete." "Green"
}

# ----------------------------
# SYSTEM INFO
# ----------------------------

function Show-SystemInfo {
    Header "System Info"
    Color ("OS: " + (Get-CimInstance Win32_OperatingSystem).Caption) "Gray"
    Color ("Version: " + (Get-CimInstance Win32_OperatingSystem).Version) "Gray"
    Color ("PowerShell: " + $PSVersionTable.PSVersion.ToString()) "Gray"
    $adm = if (Is-Admin) {"Yes"} else {"No"}
    Color ("Admin: " + $adm) "Gray"
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Color ("CPU: {0} ({1} cores)" -f $cpu.Name,$cpu.NumberOfLogicalProcessors) "Gray"
    $mem = Get-CimInstance Win32_OperatingSystem
    Color ("Memory: {0} GB total / {1} GB free" -f [math]::Round($mem.TotalVisibleMemorySize/1MB,2), [math]::Round($mem.FreePhysicalMemory/1MB,2)) "Gray"
    Color "Top processes by CPU (sample):" "Cyan"
    Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 | ForEach-Object { Color ("  {0,-6} {1,-25} CPU={2}" -f $_.Id,$_.ProcessName,[math]::Round($_.CPU,2)) "Gray" }
    Color ("Open connections on port {0}:" -f $Config.port) "Cyan"
    $pp = Get-PortProcess $Config.port
    if ($pp) { $pp | ForEach-Object { Color ("  PID {0} {1}" -f $_.PID,$_.Name) "Gray" } } else { Color "  None." "Gray" }
    Pause-Enter
}

# ----------------------------
# CONFIG MENU
# ----------------------------

function Show-Config {
    Header "Current Config"
    $Config | ConvertTo-Json -Depth 10 | Write-Host
    Pause-Enter
}

function Edit-Config {
    while ($true) {
        Header "Edit Config"
        Color "[1] Host ($($Config.host))" "Gray"
        Color "[2] Port ($($Config.port))" "Gray"
        Color "[3] App Dir ($($Config.appDir))" "Gray"
        Color "[4] venv Path ($($Config.venvPath))" "Gray"
        Color "[5] WSGI Entrypoint ($($Config.wsgiEntrypoint))" "Gray"
        Color "[6] Logs Dir ($($Config.logsDir))" "Gray"
        Color "[7] MongoDB Service Names ($($Config.mongodbServiceNames -join ', '))" "Gray"
        Color "[8] MongoDB Log Path ($($Config.mongodbLogPath))" "Gray"
        Color "[9] Service Name ($($Config.service.name))" "Gray"
        Color "[10] Service Start Mode ($($Config.service.startMode))" "Gray"
        Color "[11] Log Rotation MB ($($Config.logRotationMB))" "Gray"
        Color "Type number to edit, 'back' to return, or 'quit' to exit." "Yellow"
        $c = Read-Choice
        switch ($c.ToLower()) {
            "1" { $v = Read-Host "Enter host"; if ($v) { $Config.host=$v; Save-Config $Config } }
            "2" { $v = Read-Host "Enter port (1-65535)"; if ($v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le 65535) { $Config.port=[int]$v; Save-Config $Config } else { Color "Invalid port." "Red" } }
            "3" { $v = Read-Host "Enter app dir path"; if ($v) { $Config.appDir=$v; Save-Config $Config } }
            "4" { $v = Read-Host "Enter venv path"; if ($v) { $Config.venvPath=$v; Save-Config $Config } }
            "5" { $v = Read-Host "Enter WSGI entrypoint (module:object)"; if ($v) { $Config.wsgiEntrypoint=$v; Save-Config $Config } }
            "6" { $v = Read-Host "Enter logs dir"; if ($v) { $Config.logsDir=$v; if (!(Test-Path $v)) { New-Item -ItemType Directory -Path $v | Out-Null } Save-Config $Config } }
            "7" { $v = Read-Host "Enter service names (comma-separated)"; if ($v) { $Config.mongodbServiceNames = ($v.Split(",") | ForEach-Object { $_.Trim() }); Save-Config $Config } }
            "8" { $v = Read-Host "Enter MongoDB log file full path"; if ($v) { $Config.mongodbLogPath = $v; Save-Config $Config } }
            "9" { $v = Read-Host "Enter Service Name"; if ($v) { $Config.service.name = $v; Save-Config $Config } }
            "10" { $v = Read-Host "Enter start mode (auto|demand|disabled)"; if ($v -in @("auto","demand","disabled")) { $Config.service.startMode=$v; Save-Config $Config } else { Color "Invalid start mode." "Red" } }
            "11" { $v = Read-Host "Enter rotation threshold in MB"; if ($v -match '^\d+$' -and [int]$v -gt 0) { $Config.logRotationMB=[int]$v; Save-Config $Config } else { Color "Invalid number." "Red" } }
            "back" { return }
            "quit" { exit }
        }
    }
}

# ----------------------------
# MENU: PYTHON / VENV
# ----------------------------

function Menu-PythonVenv {
    while ($true) {
        Header "Python & Virtual Environment"
        Color "[1] Check Python" "Gray"
        Color "[2] Auto-install Python (winget/choco)" "Gray"
        Color "[3] Create/Recreate Virtualenv" "Gray"
        Color "[4] Install requirements.txt" "Gray"
        Color "Type 'back' or 'quit'." "Yellow"
        $c = Read-Choice
        switch ($c.ToLower()) {
            "1" {
                $py = Find-Python
                if ($py) { Color "Python found: $py" "Green"; & $py --version }
                else {
                    Color "Python not found." "Red"
                    Color "Install suggestions:" "Yellow"
                    $Config.installHints.python | ForEach-Object { Color "  $_" "Gray" }
                }
                Pause-Enter
            }
            "2" { Install-Python; Pause-Enter }
            "3" {
                if (Test-Path $Config.venvPath) {
                    if (Ask-YesNo "Venv exists. Recreate?" $true) { Remove-Item $Config.venvPath -Recurse -Force }
                }
                Ensure-Venv | Out-Null
                Pause-Enter
            }
            "4" { Install-Requirements; Pause-Enter }
            "back" { return }
            "quit" { exit }
        }
    }
}

# ----------------------------
# MENU: APP (PROCESS)
# ----------------------------

function Menu-App {
    while ($true) {
        Header "App Server (Waitress)"
        Color "[1] Start App" "Gray"
        Color "[2] Stop App" "Gray"
        Color "[3] Restart App" "Gray"
        Color "[4] Status (PID, port, uptime/downtime)" "Gray"
        Color "[5] Tail app stdout (optional filter)" "Gray"
        Color "[6] Tail app stderr (optional filter)" "Gray"
        Color "[7] Show recent errors" "Gray"
        Color "[8] Rotate app logs now" "Gray"
        Color "Type 'back' or 'quit'." "Yellow"
        $c = Read-Choice
        switch ($c.ToLower()) {
            "1" { Start-App; Pause-Enter }
            "2" { Stop-App; Pause-Enter }
            "3" { Restart-App; Pause-Enter }
            "4" {
                $st = App-Status
                if ($st.running) {
                    $up = (New-TimeSpan -Start $st.startTime -End (Get-Date))
                    Color ("RUNNING (PID {0}) since {1}  |  Uptime: {2}h {3}m {4}s" -f $st.pid,$st.startTime,$up.Hours,$up.Minutes,$up.Seconds) "Green"
                } else {
                    Color ("STOPPED. Reason: {0}" -f $st.reason) "Yellow"
                    if ($State.app.lastStop) {
                        $down = (New-TimeSpan -Start $State.app.lastStop -End (Get-Date))
                        Color ("Down since {0}  |  Downtime: {1}h {2}m {3}s" -f $State.app.lastStop,$down.Hours,$down.Minutes,$down.Seconds) "Gray"
                    }
                }
                Pause-Enter
            }
            "5" {
                $kw = Read-Host "Keyword filter (optional, press ENTER to skip)"
                Tail-Log (Join-Path $Config.logsDir "app_stdout.log") $kw
            }
            "6" {
                $kw = Read-Host "Keyword filter (optional, press ENTER to skip)"
                Tail-Log (Join-Path $Config.logsDir "app_stderr.log") $kw
            }
            "7" { Show-RecentErrors 200; Pause-Enter }
            "8" { Rotate-AppLogs; Pause-Enter }
            "back" { return }
            "quit" { exit }
        }
    }
}

# ----------------------------
# MENU: WINDOWS SERVICE
# ----------------------------

function Menu-Service {
    while ($true) {
        Header "Windows Service (NSSM)"
        $svcName = $Config.service.name
        $st = Service-Status $svcName
        if ($st.exists) {
            $msg = "Service '$svcName': {0}" -f $st.status
            if ($st.running -and $st.startTime) {
                $up = (New-TimeSpan -Start $st.startTime -End (Get-Date))
                $msg += (" | Uptime: {0}h {1}m {2}s (PID {3})" -f $up.Hours,$up.Minutes,$up.Seconds,$st.pid)
            }
            Color $msg "Green"
        } else {
            Color "Service '$svcName' does not exist." "Yellow"
        }
        Color "[1] Create/Recreate Service (NSSM)" "Gray"
        Color "[2] Remove Service" "Gray"
        Color "[3] Start Service" "Gray"
        Color "[4] Stop Service" "Gray"
        Color "[5] Restart Service" "Gray"
        Color "Type 'back' or 'quit'." "Yellow"
        $c = Read-Choice
        switch ($c.ToLower()) {
            "1" { Create-AppService; Pause-Enter }
            "2" { Remove-AppService; Pause-Enter }
            "3" { Start-AppService; Pause-Enter }
            "4" { Stop-AppService; Pause-Enter }
            "5" { Restart-AppService; Pause-Enter }
            "back" { return }
            "quit" { exit }
        }
    }
}

# ----------------------------
# MENU: MONGODB
# ----------------------------

function Menu-Mongo {
    while ($true) {
        Header "MongoDB"
        $st = Mongo-Status
        if (-not $st.installed) {
            Color "MongoDB not installed." "Yellow"
        } else {
            $txt = "MongoDB Service '{0}': {1}" -f $st.name,$st.status
            if ($st.running -and $st.startTime) {
                $up = (New-TimeSpan -Start $st.startTime -End (Get-Date))
                $txt += (" | Uptime: {0}h {1}m {2}s (PID {3})" -f $up.Hours,$up.Minutes,$up.Seconds,$st.pid)
            }
            Color $txt "Green"
        }
        Color "[1] Auto-install MongoDB (winget/choco)" "Gray"
        Color "[2] Start" "Gray"
        Color "[3] Stop" "Gray"
        Color "[4] Restart" "Gray"
        Color "[5] Tail MongoDB logs" "Gray"
        Color "Type 'back' or 'quit'." "Yellow"
        $c = Read-Choice
        switch ($c.ToLower()) {
            "1" { Install-MongoDB; Pause-Enter }
            "2" { Start-Mongo; Pause-Enter }
            "3" { Stop-Mongo; Pause-Enter }
            "4" { Restart-Mongo; Pause-Enter }
            "5" { Tail-Mongo-Logs }
            "back" { return }
            "quit" { exit }
        }
    }
}

# ----------------------------
# MENU: LOGS
# ----------------------------

function Menu-Logs {
    while ($true) {
        Header "Logs"
        $stdout = Join-Path $Config.logsDir "app_stdout.log"
        $stderr = Join-Path $Config.logsDir "app_stderr.log"
        Color "[1] Tail app stdout" "Gray"
        Color "[2] Tail app stderr" "Gray"
        Color "[3] Tail script.log" "Gray"
        Color "[4] Rotate logs now" "Gray"
        Color "[5] Show last 200 error lines" "Gray"
        Color "Type 'back' or 'quit'." "Yellow"
        $c = Read-Choice
        switch ($c.ToLower()) {
            "1" { $kw = Read-Host "Keyword filter (optional)"; Tail-Log $stdout $kw }
            "2" { $kw = Read-Host "Keyword filter (optional)"; Tail-Log $stderr $kw }
            "3" { Tail-Log $scriptLog }
            "4" { Rotate-AppLogs; Pause-Enter }
            "5" { Show-RecentErrors 200; Pause-Enter }
            "back" { return }
            "quit" { exit }
        }
    }
}

# ----------------------------
# MENU: BACKUP/RESTORE
# ----------------------------

function Menu-BackupRestore {
    while ($true) {
        Header "Backup & Restore"
        Color "[1] Create App Backup (zip)" "Gray"
        Color "[2] Restore from Backup" "Gray"
        Color "Type 'back' or 'quit'." "Yellow"
        $c = Read-Choice
        switch ($c.ToLower()) {
            "1" { New-AppBackup; Pause-Enter }
            "2" { Restore-AppBackup; Pause-Enter }
            "back" { return }
            "quit" { exit }
        }
    }
}

# ----------------------------
# MAIN MENU (NO NUMERIC QUIT; exit only via 'quit')
# ----------------------------

while ($true) {
    Header "MAIN MENU"
    Color "[1] Python & Virtual Environment" "Gray"
    Color "[2] App Server (Waitress, process mode)" "Gray"
    Color "[3] Windows Service (NSSM) for App" "Gray"
    Color "[4] MongoDB" "Gray"
    Color "[5] Logs" "Gray"
    Color "[6] Backup & Restore" "Gray"
    Color "[7] System Info" "Gray"
    Color "[8] Config (view/edit)" "Gray"
    Color "Type a number, or 'quit' to exit." "Yellow"
    $c = Read-Choice
    switch ($c.ToLower()) {
        "1" { Menu-PythonVenv }
        "2" { Menu-App }
        "3" { Menu-Service }
        "4" { Menu-Mongo }
        "5" { Menu-Logs }
        "6" { Menu-BackupRestore }
        "7" { Show-SystemInfo }
        "8" {
            while ($true) {
                Header "Config"
                Color "[1] View config" "Gray"
                Color "[2] Edit config" "Gray"
                Color "Type 'back' or 'quit'." "Yellow"
                $ch = Read-Choice
                switch ($ch.ToLower()) {
                    "1" { Show-Config }
                    "2" { Edit-Config }
                    "back" { break }
                    "quit" { exit }
                }
            }
        }
        "quit" { break }
    }
}

Color "Goodbye! Exiting as requested." "Cyan"