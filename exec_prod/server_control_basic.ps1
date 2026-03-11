<#
===================================================================================
   SERVER CONTROL SCRIPT (WINDOWS PRODUCTION) – INTERACTIVE MENU
   Manages:
      ✔ Python installation check
      ✔ Virtual environment create/activate
      ✔ Flask app via WAITRESS (start/stop/restart/status/logs)
      ✔ MongoDB installation check + service control
      ✔ Full log management
      ✔ Config & State JSON
      ✔ Navigation (Back / Quit only via "quit")
===================================================================================
#>

# ----------------------------
# GLOBAL PATHS & INITIAL SETUP
# ----------------------------

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptRoot

$configPath = Join-Path $ScriptRoot "config.json"
$statePath  = Join-Path $ScriptRoot "state.json"
$logsDir    = Join-Path $ScriptRoot "logs"

# Ensure logs directory exists
if (!(Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }

# Script log
$scriptLog = Join-Path $logsDir "script.log"

function Log {
    param([string]$msg)
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$timestamp  |  $msg" | Out-File -FilePath $scriptLog -Append -Encoding UTF8
}

# ----------------------------
# CONFIG INITIALIZATION
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
            installHints = @{
                python = @(
                    "winget install --id Python.Python.3 --source winget",
                    "choco install python -y"
                )
                mongodb = @(
                    "winget install --id MongoDB.MongoDBServer --source winget",
                    "choco install mongodb -y"
                )
            }
        }
        $default | ConvertTo-Json -Depth 10 | Out-File $configPath -Encoding utf8
    }
    return (Get-Content $configPath | ConvertFrom-Json)
}

# ----------------------------
# STATE INITIALIZATION
# ----------------------------

function Load-State {
    if (!(Test-Path $statePath)) {
        $default = @{
            app = @{ lastStart = ""; lastStop = "" }
            mongodb = @{ lastStart = ""; lastStop = "" }
        }
        $default | ConvertTo-Json -Depth 10 | Out-File $statePath -Encoding utf8
    }
    return (Get-Content $statePath | ConvertFrom-Json)
}

$Config = Load-Config
$State  = Load-State

# ----------------------------
# UTILITY FUNCTIONS
# ----------------------------

function Save-State {
    $State | ConvertTo-Json -Depth 10 | Out-File $statePath -Encoding utf8
}

function Press-Enter {
    Write-Host ""
    Read-Host "Press ENTER to continue"
}

function Show-Header($text) {
    Write-Host "`n====================" -ForegroundColor Cyan
    Write-Host "$text" -ForegroundColor Cyan
    Write-Host "====================`n"
}

function Is-Admin {
    return ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent() `
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ----------------------------
# PYTHON CHECK
# ----------------------------

function Find-Python {
    foreach ($cmd in $Config.pythonPreferredCommands) {
        try {
            $v = & $cmd --version 2>$null
            if ($LASTEXITCODE -eq 0) { return $cmd }
        } catch {}
    }
    return $null
}

# ----------------------------
# VIRTUAL ENV MGMT
# ----------------------------

function Create-Venv {
    $python = Find-Python
    if (-not $python) {
        Write-Host "Python not found!" -ForegroundColor Red
        Write-Host "Install using:" -ForegroundColor Yellow
        $Config.installHints.python | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        return
    }

    Write-Host "Creating virtual environment..." -ForegroundColor Green
    & $python -m venv $Config.venvPath
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Virtual environment created successfully." -ForegroundColor Green
    } else {
        Write-Host "Failed to create virtual environment." -ForegroundColor Red
    }
}

function Install-Requirements {
    $venvPython = Join-Path $Config.venvPath "Scripts\python.exe"
    $venvPip    = Join-Path $Config.venvPath "Scripts\pip.exe"
    $reqPath    = Join-Path $Config.appDir "requirements.txt"

    if (!(Test-Path $venvPython)) {
        Write-Host "Venv not found." -ForegroundColor Red
        return
    }

    if (Test-Path $reqPath) {
        Write-Host "Installing requirements..." -ForegroundColor Green
        & $venvPip install -r $reqPath
    } else {
        Write-Host "No requirements.txt found." -ForegroundColor Yellow
    }
}

# ----------------------------
# APP SERVER (WAITRESS)
# ----------------------------

function App-Status {
    $pidFile = $Config.pidFile
    if (!(Test-Path $pidFile)) {
        return @{ running = $false; message = "Not running" }
    }

    $pid = Get-Content $pidFile | Select-Object -First 1
    $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue

    if ($null -eq $proc) {
        Remove-Item $pidFile -Force
        return @{ running = $false; message = "Stale PID file cleaned" }
    }

    return @{
        running = $true
        pid = $proc.Id
        startTime = $proc.StartTime
    }
}

function Start-App {
    $status = App-Status
    if ($status.running) {
        Write-Host "App already running (PID $($status.pid))." -ForegroundColor Yellow
        return
    }

    $venvPython = Join-Path $Config.venvPath "Scripts\python.exe"
    if (!(Test-Path $venvPython)) {
        Write-Host "Venv missing. Create it first." -ForegroundColor Red
        return
    }

    # Ensure waitress installed
    & (Join-Path $Config.venvPath "Scripts\pip.exe") install waitress > $null

    $cmd = ""
    if ($Config.useWaitressCLI) {
        $cmd = "$venvPython -m waitress --host $($Config.host) --port $($Config.port) $($Config.wsgiEntrypoint)"
    } else {
        $cmd = "$venvPython -c `"from waitress import serve; import importlib; module,obj='$($Config.wsgiEntrypoint)'.split(':'); app=getattr(importlib.import_module(module),obj); serve(app,host='$($Config.host)',port=$($Config.port))`""
    }

    $stdout = Join-Path $logsDir "app_stdout.log"
    $stderr = Join-Path $logsDir "app_stderr.log"

    $process = Start-Process powershell -ArgumentList "-NoLogo -NoProfile -Command $cmd" `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    $process.Id | Out-File $Config.pidFile -Encoding utf8

    $State.app.lastStart = (Get-Date).ToString("o")
    Save-State

    Write-Host "App started with PID $($process.Id)" -ForegroundColor Green
}

function Stop-App {
    $status = App-Status
    if (-not $status.running) {
        Write-Host "App not running." -ForegroundColor Yellow
        return
    }

    Stop-Process -Id $status.pid -Force
    Remove-Item $Config.pidFile -Force

    $State.app.lastStop = (Get-Date).ToString("o")
    Save-State

    Write-Host "App stopped." -ForegroundColor Green
}

function Restart-App {
    Stop-App
    Start-App
}

function Tail-Log($file) {
    if (!(Test-Path $file)) {
        Write-Host "Log not found." -ForegroundColor Red
        return
    }
    Write-Host "Tailing: $file" -ForegroundColor Cyan
    Get-Content $file -Wait -Tail 30
}

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
    if (-not $svc) {
        return @{ installed = $false }
    }

    return @{
        installed = $true
        running = ($svc.Status -eq "Running")
        status = $svc.Status
    }
}

function Start-Mongo {
    $svc = Get-Mongo-Service
    if (!$svc) { Write-Host "MongoDB not installed." -Red; return }
    Start-Service $svc.Name
    $State.mongodb.lastStart = (Get-Date).ToString("o")
    Save-State
    Write-Host "MongoDB started." -Green
}

function Stop-Mongo {
    $svc = Get-Mongo-Service
    if (!$svc) { Write-Host "MongoDB not installed." -Red; return }
    Stop-Service $svc.Name
    $State.mongodb.lastStop = (Get-Date).ToString("o")
    Save-State
    Write-Host "MongoDB stopped." -Green
}

function Restart-Mongo {
    $svc = Get-Mongo-Service
    if (!$svc) { Write-Host "MongoDB not installed." -Red; return }
    Restart-Service $svc.Name
    $State.mongodb.lastStart = (Get-Date).ToString("o")
    Save-State
    Write-Host "MongoDB restarted." -Green
}

# ----------------------------
# MENUS
# ----------------------------

function Menu-Python {
    while ($true) {
        Show-Header "Python & Virtual Environment"
        Write-Host "[1] Check Python"
        Write-Host "[2] Create/Recreate Virtualenv"
        Write-Host "[3] Install Requirements"
        Write-Host "Type 'back' or 'quit'"
        $c = Read-Host ">"

        switch ($c) {
            "1" {
                $py = Find-Python
                if ($py) {
                    Write-Host "Python found: $py" -ForegroundColor Green
                    & $py --version
                } else {
                    Write-Host "Python not found." -ForegroundColor Red
                    Write-Host "Install suggestions:" -ForegroundColor Yellow
                    $Config.installHints.python | ForEach-Object { Write-Host $_ }
                }
                Press-Enter
            }
            "2" {
                if (Test-Path $Config.venvPath) {
                    $ans = Read-Host "Venv exists. Recreate? (y/n)"
                    if ($ans -eq "y") { Remove-Item $Config.venvPath -Recurse -Force }
                }
                Create-Venv
                Press-Enter
            }
            "3" {
                Install-Requirements
                Press-Enter
            }
            "back" { return }
            "quit" { exit }
        }
    }
}

function Menu-App {
    while ($true) {
        Show-Header "App Server (Waitress)"
        Write-Host "[1] Start App"
        Write-Host "[2] Stop App"
        Write-Host "[3] Restart App"
        Write-Host "[4] Status"
        Write-Host "[5] Tail stdout"
        Write-Host "[6] Tail stderr"
        Write-Host "Type 'back' or 'quit'"
        $c = Read-Host ">"

        switch ($c) {
            "1" { Start-App; Press-Enter }
            "2" { Stop-App; Press-Enter }
            "3" { Restart-App; Press-Enter }
            "4" {
                $st = App-Status
                if ($st.running) {
                    Write-Host "Running (PID $($st.pid)) since $($st.startTime)" -Green
                } else {
                    Write-Host "Not Running." -Red
                    Write-Host "Last stopped: $($State.app.lastStop)"
                }
                Press-Enter
            }
            "5" { Tail-Log (Join-Path $logsDir "app_stdout.log") }
            "6" { Tail-Log (Join-Path $logsDir "app_stderr.log") }
            "back" { return }
            "quit" { exit }
        }
    }
}

function Menu-Mongo {
    while ($true) {
        Show-Header "MongoDB Management"
        Write-Host "[1] Status"
        Write-Host "[2] Start"
        Write-Host "[3] Stop"
        Write-Host "[4] Restart"
        Write-Host "Type 'back' or 'quit'"

        $c = Read-Host ">"

        switch ($c) {
            "1" {
                $st = Mongo-Status
                if (-not $st.installed) {
                    Write-Host "MongoDB not installed." -Red
                    Write-Host "Install using:"
                    $Config.installHints.mongodb | ForEach-Object { Write-Host $_ }
                } else {
                    Write-Host "MongoDB Status: $($st.status)" -ForegroundColor Green
                    Write-Host "Last Start: $($State.mongodb.lastStart)"
                    Write-Host "Last Stop:  $($State.mongodb.lastStop)"
                }
                Press-Enter
            }
            "2" { Start-Mongo; Press-Enter }
            "3" { Stop-Mongo;  Press-Enter }
            "4" { Restart-Mongo; Press-Enter }
            "back" { return }
            "quit" { exit }
        }
    }
}

# ----------------------------
# MAIN MENU LOOP
# ----------------------------

while ($true) {
    Show-Header "MAIN MENU"
    Write-Host "[1] Python & Virtual Environment"
    Write-Host "[2] App Server (Waitress)"
    Write-Host "[3] MongoDB"
    Write-Host "[4] Quit"
    $c = Read-Host ">"

    switch ($c) {
        "1" { Menu-Python }
        "2" { Menu-App }
        "3" { Menu-Mongo }
        "4" { exit }
        "quit" { exit }
    }
}