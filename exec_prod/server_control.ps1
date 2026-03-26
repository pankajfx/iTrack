<#
===================================================================================
   ITRACKER SERVER CONTROL — WINDOWS PRODUCTION

   All-in-one interactive management for:
     * Flask/Waitress app (multi-method detection)
     * Nginx reverse proxy
     * Caddy reverse proxy
     * MongoDB database
     * NSSM Windows Services
     * Python / venv management
     * Logs, backups, health checks, system info
===================================================================================
#>

# ─── Paths ───────────────────────────────────────────────────────────────────
$APP_DIR      = 'G:\srv\app\itracker'
$VENV_DIR     = 'G:\srv\app\itracker\venv'
$VENV_SCRIPTS = 'G:\srv\app\itracker\venv\Scripts'
$PYTHON_EXE   = Join-Path $VENV_SCRIPTS 'python.exe'
$PIP_EXE      = Join-Path $VENV_SCRIPTS 'pip.exe'
$WAITRESS_EXE = Join-Path $VENV_SCRIPTS 'waitress-serve.exe'
$NGINX_DIR    = 'C:\nginx'
$NGINX_EXE    = Join-Path $NGINX_DIR 'nginx.exe'
$NGINX_CONF   = Join-Path $NGINX_DIR 'conf\nginx.conf'
$CADDY_DIR    = 'C:\Tools\Caddy'
$CADDY_EXE    = Join-Path $CADDY_DIR 'caddy.exe'
$CADDYFILE    = Join-Path $CADDY_DIR 'Caddyfile'
$NSSM_DIR     = 'C:\Tools\NSSM'
$NSSM_EXE     = Join-Path $NSSM_DIR 'win64\nssm.exe'

# ─── Script internals ────────────────────────────────────────────────────────
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $ScriptRoot 'config.json'
$statePath  = Join-Path $ScriptRoot 'state.json'
$logsDir    = Join-Path $ScriptRoot 'logs'
$backupsDir = Join-Path $ScriptRoot 'backups'
$scriptLog  = Join-Path $logsDir 'script.log'

foreach ($d in @($logsDir, $backupsDir)) {
    if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

# ─── Service name constants ──────────────────────────────────────────────────
$SVC_APP      = 'ITrackerApp'
$SVC_NGINX    = 'nginx'
$SVC_CADDY    = 'caddy'
$SVC_MONGO    = @('MongoDB', 'MongoDB Server', 'mongod')

# ─── App defaults ────────────────────────────────────────────────────────────
$APP_HOST       = '0.0.0.0'      # bind all interfaces so remote clients can connect
$APP_PORT       = 5001
$WSGI_ENTRY     = 'app:app'
$APP_THREADS    = 8
$APP_IDENT      = 'ITracker'
$APP_URL_SCHEME = 'https'
$PID_FILE       = Join-Path $ScriptRoot 'app.pid'

# ═════════════════════════════════════════════════════════════════════════════
#  UTILITY FUNCTIONS
# ═════════════════════════════════════════════════════════════════════════════

function Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    "$ts [$Level] $Message" | Out-File -FilePath $scriptLog -Append -Encoding UTF8
}

function Color([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }

function Header([string]$txt) {
    $line = '=' * 60
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $txt" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Write-Host ''
}

function SubHeader([string]$txt) {
    Write-Host ''
    Write-Host "--- $txt ---" -ForegroundColor DarkCyan
}

function StatusLine([string]$label, [string]$value, [string]$color = 'Gray') {
    Write-Host ("  {0,-22}" -f $label) -NoNewline -ForegroundColor DarkGray
    Write-Host $value -ForegroundColor $color
}

function StatusBullet([string]$symbol, [string]$text, [string]$color) {
    Write-Host "  $symbol " -NoNewline -ForegroundColor $color
    Write-Host $text -ForegroundColor $color
}

function Is-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Pause-Enter { Write-Host ''; Read-Host 'Press ENTER to continue' | Out-Null }

function Read-Choice([string]$prompt = '> ') {
    Write-Host ''
    return (Read-Host $prompt).Trim()
}

function Ask-YesNo([string]$q, [bool]$defaultNo = $false) {
    $suffix = if ($defaultNo) { '[y/N]' } else { '[Y/n]' }
    while ($true) {
        $ans = Read-Host "$q $suffix"
        if ([string]::IsNullOrWhiteSpace($ans)) { return -not $defaultNo }
        switch ($ans.Trim().ToLower()) {
            'y'   { return $true }
            'yes' { return $true }
            'n'   { return $false }
            'no'  { return $false }
            default { Color 'Please answer y/n.' 'Yellow' }
        }
    }
}

function Has-Command([string]$cmd) { return $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }

function Ensure-Admin-Guard([string]$context = 'this action') {
    if (-not (Is-Admin)) { Color "  Administrator rights required for $context. Run PowerShell as Administrator." 'Red'; return $false }
    return $true
}

function Format-Uptime([datetime]$start) {
    $span = New-TimeSpan -Start $start -End (Get-Date)
    $parts = @()
    if ($span.Days -gt 0) { $parts += "$($span.Days)d" }
    $parts += "$($span.Hours)h"
    $parts += "$($span.Minutes)m"
    $parts += "$($span.Seconds)s"
    return ($parts -join ' ')
}

# ─── Config / State persistence ──────────────────────────────────────────────

function Load-Config {
    if (!(Test-Path $configPath)) {
        $default = @{
            appDir         = $APP_DIR
            venvPath       = $VENV_DIR
            host           = $APP_HOST
            port           = $APP_PORT
            wsgiEntrypoint = $WSGI_ENTRY
            threads        = $APP_THREADS
            ident          = $APP_IDENT
            urlScheme      = $APP_URL_SCHEME
            logsDir        = $logsDir
            pidFile        = $PID_FILE
            logRotationMB  = 20
            healthCheckUrl = "http://127.0.0.1:${APP_PORT}/api/auth/session"
            mongodbLogPath = ''
            service = @{
                appName   = $SVC_APP
                startMode = 'auto'
            }
        }
        $default | ConvertTo-Json -Depth 10 | Out-File $configPath -Encoding utf8
    }
    return (Get-Content $configPath -Raw | ConvertFrom-Json)
}
function Save-Config { param([Parameter(Mandatory)]$cfg); $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8 }

function Load-State {
    if (!(Test-Path $statePath)) {
        $default = @{
            app     = @{ lastStart = ''; lastStop = '' }
            nginx   = @{ lastStart = ''; lastStop = '' }
            caddy   = @{ lastStart = ''; lastStop = '' }
            mongodb = @{ lastStart = ''; lastStop = '' }
        }
        $default | ConvertTo-Json -Depth 10 | Out-File $statePath -Encoding utf8
    }
    return (Get-Content $statePath -Raw | ConvertFrom-Json)
}
function Save-State { param([Parameter(Mandatory)]$st); $st | ConvertTo-Json -Depth 10 | Set-Content -Path $statePath -Encoding UTF8 }

$Config = Load-Config
$State  = Load-State

# ═════════════════════════════════════════════════════════════════════════════
#  DETECTION FUNCTIONS — Flask App (multiple methods)
# ═════════════════════════════════════════════════════════════════════════════

function Detect-App-ByPidFile {
    <# Check stored PID file #>
    if (!(Test-Path $Config.pidFile)) { return $null }
    $raw = (Get-Content $Config.pidFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { Remove-Item $Config.pidFile -Force; return $null }
    $proc = Get-Process -Id ([int]$raw) -ErrorAction SilentlyContinue
    if ($proc) { return @{ pid=$proc.Id; name=$proc.ProcessName; start=$proc.StartTime; method='pidfile' } }
    Remove-Item $Config.pidFile -Force
    return $null
}

function Detect-App-ByPort {
    <# Scan TCP listeners on the configured port #>
    $port = [int]$Config.port
    try {
        $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if ($conns) {
            $procId = $conns[0].OwningProcess
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) { return @{ pid=$proc.Id; name=$proc.ProcessName; start=$proc.StartTime; method='port-scan' } }
            return @{ pid=$procId; name='Unknown'; start=$null; method='port-scan' }
        }
    } catch {}
    # Fallback: netstat
    try {
        $lines = netstat -ano 2>$null | Select-String ":$port\s"
        foreach ($line in $lines) {
            if ($line -match 'LISTENING\s+(\d+)') {
                $procId = [int]$Matches[1]
                $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($proc) { return @{ pid=$proc.Id; name=$proc.ProcessName; start=$proc.StartTime; method='netstat' } }
                return @{ pid=$procId; name='Unknown'; start=$null; method='netstat' }
            }
        }
    } catch {}
    return $null
}

function Detect-App-ByProcessName {
    <# Find python/waitress processes running from the venv #>
    $procs = Get-Process -Name 'python','python3','pythonw','waitress-serve' -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        try {
            $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue).CommandLine
            if ($cmdLine -and ($cmdLine -like "*$APP_DIR*" -or $cmdLine -like "*$VENV_DIR*" -or $cmdLine -like "*waitress*$WSGI_ENTRY*")) {
                return @{ pid=$p.Id; name=$p.ProcessName; start=$p.StartTime; method='process-scan'; cmdLine=$cmdLine }
            }
        } catch {}
    }
    return $null
}

function Detect-App-ByNSSM {
    <# Check if running as a Windows Service via NSSM #>
    $svcName = $Config.service.appName
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        $cim = Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
        $procId = if ($cim) { $cim.ProcessId } else { 0 }
        $startTime = $null
        if ($procId -gt 0) {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) { $startTime = $proc.StartTime }
        }
        return @{ pid=$procId; name=$svcName; start=$startTime; method='nssm-service'; svcStatus=$svc.Status }
    }
    return $null
}

function Detect-App-ByHTTP {
    <# HTTP health check — confirms the app is actually responding #>
    $url = $Config.healthCheckUrl
    if (-not $url) { $url = "http://127.0.0.1:$($Config.port)/" }
    try {
        $response = Invoke-WebRequest -Uri $url -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        return @{ statusCode=$response.StatusCode; url=$url; method='http-check'; responding=$true }
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        # A non-null code means the server responded (even with 401/403/500)
        if ($code) {
            return @{ statusCode=$code; url=$url; method='http-check'; responding=$true }
        }
        return @{ statusCode=$null; url=$url; method='http-check'; responding=$false; error=$_.Exception.Message }
    }
}

function Get-AppStatus-Full {
    <# Aggregate all detection methods for comprehensive status #>
    $results = @{
        pidFile     = Detect-App-ByPidFile
        port        = Detect-App-ByPort
        process     = Detect-App-ByProcessName
        nssm        = Detect-App-ByNSSM
        http        = Detect-App-ByHTTP
    }
    # Determine overall state
    $running = ($results.pidFile -ne $null) -or ($results.port -ne $null) -or ($results.process -ne $null) -or ($results.nssm -ne $null)
    $responding = $results.http -and $results.http.responding
    # Best PID source
    $best = $null
    foreach ($key in @('pidFile','nssm','port','process')) {
        if ($results[$key] -ne $null) { $best = $results[$key]; break }
    }
    $results.running = $running
    $results.responding = $responding
    $results.best = $best
    return $results
}

# ═════════════════════════════════════════════════════════════════════════════
#  PORT & PROCESS HELPERS
# ═════════════════════════════════════════════════════════════════════════════

function Get-PortProcess($port) {
    try {
        $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if ($conns) {
            foreach ($c in $conns) {
                $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
                [PSCustomObject]@{ Port=$port; PID=$c.OwningProcess; Name=if($p){$p.ProcessName}else{'Unknown'}; StartTime=if($p){$p.StartTime}else{$null} }
            }
        }
    } catch {}
}

function Resolve-PortConflict {
    $port = [int]$Config.port
    $busy = Get-PortProcess $port
    if ($busy) {
        Color "  Port $port in use by:" 'Yellow'
        $busy | ForEach-Object { Color ("    PID {0}  {1}" -f $_.PID, $_.Name) 'Gray' }
        if (Ask-YesNo '  Kill these process(es)?' $true) {
            foreach ($b in $busy) {
                try { Stop-Process -Id $b.PID -Force -ErrorAction Stop; Color "  Killed PID $($b.PID)" 'Green' }
                catch { Color "  Failed to kill PID $($b.PID): $_" 'Red' }
            }
            Start-Sleep -Seconds 1; return $true
        } else {
            $newPort = Read-Host '  Enter a different port (1-65535) or blank to cancel'
            if ($newPort -and [int]$newPort -ge 1 -and [int]$newPort -le 65535) {
                $Config.port = [int]$newPort; Save-Config $Config
                Color "  Updated port to $newPort" 'Green'; return $true
            }
            return $false
        }
    }
    return $true
}

# ═════════════════════════════════════════════════════════════════════════════
#  LOG MANAGEMENT
# ═════════════════════════════════════════════════════════════════════════════

function Rotate-Log([string]$file) {
    if (!(Test-Path $file)) { return }
    $sizeMB = [math]::Round((Get-Item $file).Length / 1MB, 2)
    if ($sizeMB -gt $Config.logRotationMB) {
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $dest = "$file.$ts"
        Rename-Item -Path $file -NewName $dest
        Color "  Rotated: $(Split-Path $file -Leaf) ($sizeMB MB)" 'Yellow'
        Log "Rotated $file to $dest"
    }
}

function Rotate-AppLogs {
    Rotate-Log (Join-Path $Config.logsDir 'app_stdout.log')
    Rotate-Log (Join-Path $Config.logsDir 'app_stderr.log')
}

function Tail-Log([string]$file, [string]$keyword = '') {
    if (!(Test-Path $file)) { Color "  Log not found: $file" 'Red'; return }
    Color "  Tailing $file (Ctrl+C to stop)..." 'Cyan'
    if ([string]::IsNullOrWhiteSpace($keyword)) { Get-Content -Path $file -Wait -Tail 50 }
    else { Get-Content -Path $file -Wait -Tail 0 | Where-Object { $_ -match [Regex]::Escape($keyword) } }
}

function Show-RecentErrors([int]$lines = 100) {
    $stderr = Join-Path $Config.logsDir 'app_stderr.log'
    if (!(Test-Path $stderr)) { Color '  No stderr log found.' 'Yellow'; return }
    Color "  Last $lines lines from app_stderr.log:" 'Magenta'
    Get-Content $stderr -Tail $lines
}

# ═════════════════════════════════════════════════════════════════════════════
#  PYTHON / VENV
# ═════════════════════════════════════════════════════════════════════════════

function Find-Python {
    # Check venv first
    if (Test-Path $PYTHON_EXE) { return $PYTHON_EXE }
    # Fallback to system python
    foreach ($cmd in @('python', 'py -3', 'python3')) {
        try { & $cmd --version *>$null; if ($LASTEXITCODE -eq 0) { return $cmd } } catch {}
    }
    return $null
}

function Check-Python {
    SubHeader 'Python'
    if (Test-Path $PYTHON_EXE) {
        $ver = & $PYTHON_EXE --version 2>&1
        StatusLine 'Venv Python:' "$ver ($PYTHON_EXE)" 'Green'
    } else {
        StatusLine 'Venv Python:' 'NOT FOUND' 'Red'
    }
    $sysPy = $null
    foreach ($cmd in @('python', 'py', 'python3')) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) { $sysPy = $found.Source; break }
    }
    if ($sysPy) {
        $ver = & $sysPy --version 2>&1
        StatusLine 'System Python:' "$ver ($sysPy)" 'Gray'
    } else {
        StatusLine 'System Python:' 'NOT FOUND' 'Yellow'
    }
}

function Ensure-Venv {
    if (Test-Path $PYTHON_EXE) { return $true }
    $sysPy = Find-Python
    if (-not $sysPy) { Color '  Python not found anywhere. Install Python first.' 'Red'; return $false }
    Color "  Creating venv at $VENV_DIR..." 'Cyan'
    & $sysPy -m venv $VENV_DIR
    if ($LASTEXITCODE -ne 0) { Color '  Failed to create venv.' 'Red'; return $false }
    Color '  Virtual environment created.' 'Green'
    return $true
}

function Ensure-Waitress {
    if (!(Test-Path $PIP_EXE)) { return $false }
    & $PIP_EXE show waitress *>$null
    if ($LASTEXITCODE -ne 0) { Color '  Installing waitress...' 'Cyan'; & $PIP_EXE install waitress }
    return $true
}

function Install-Requirements {
    if (!(Test-Path $PIP_EXE)) { Color '  Venv pip not found.' 'Red'; return }
    $reqPath = Join-Path $APP_DIR 'Requirements.txt'
    if (!(Test-Path $reqPath)) { $reqPath = Join-Path $APP_DIR 'requirements.txt' }
    if (!(Test-Path $reqPath)) { Color "  No requirements.txt found in $APP_DIR." 'Yellow'; return }
    Color "  Upgrading pip..." 'Cyan'
    & $PIP_EXE install --upgrade pip *>$null
    Color "  Installing from $reqPath..." 'Cyan'
    & $PIP_EXE install -r $reqPath
}

# ═════════════════════════════════════════════════════════════════════════════
#  FLASK APP — Start / Stop / Restart
# ═════════════════════════════════════════════════════════════════════════════

function Start-App {
    $status = Get-AppStatus-Full
    if ($status.running) {
        $b = $status.best
        Color "  App already running — PID $($b.pid) ($($b.method)) on port $($Config.port)" 'Yellow'
        return
    }
    if (-not (Ensure-Venv))          { return }
    if (-not (Ensure-Waitress))      { return }
    if (-not (Resolve-PortConflict)) { Color '  Start aborted due to port conflict.' 'Red'; return }
    Rotate-AppLogs

    $stdoutLog = Join-Path $Config.logsDir 'app_stdout.log'
    $stderrLog = Join-Path $Config.logsDir 'app_stderr.log'

    $threads   = if ($Config.threads)   { $Config.threads }   else { $APP_THREADS }
    $ident     = if ($Config.ident)     { $Config.ident }     else { $APP_IDENT }
    $urlScheme = if ($Config.urlScheme) { $Config.urlScheme } else { $APP_URL_SCHEME }
    $appArgs = "--listen=*:$($Config.port) --threads=$threads --ident=$ident --url-scheme=$urlScheme $($Config.wsgiEntrypoint)"

    $launcherPath = Join-Path $logsDir '_launcher.bat'
    $batContent = "@echo off`r`ncd /d `"$APP_DIR`"`r`n`"$WAITRESS_EXE`" $appArgs >> `"$stdoutLog`" 2>> `"$stderrLog`""
    $batContent | Out-File -FilePath $launcherPath -Encoding ascii -Force

    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c start /b `"`" `"$launcherPath`"" -WorkingDirectory $APP_DIR -WindowStyle Hidden -PassThru | Out-Null
        Color "  Waiting for app to bind port $($Config.port)..." 'Cyan'
        $waited = 0
        $realPid = $null
        while ($waited -lt 10) {
            Start-Sleep -Seconds 1
            $waited++
            $detect = Detect-App-ByPort
            if ($detect) { $realPid = $detect.pid; break }
        }
        if ($realPid) {
            $realPid | Out-File $Config.pidFile -Encoding utf8
            $State.app.lastStart = (Get-Date).ToString('o'); Save-State $State
            Color "  App started — PID $realPid on $($Config.host):$($Config.port)" 'Green'
            Log "App started PID $realPid port $($Config.port)"
        } else {
            Color "  Process launched but not confirmed on port $($Config.port) after ${waited}s." 'Yellow'
            Color "    stdout: $stdoutLog" 'Gray'
            Color "    stderr: $stderrLog" 'Gray'
        }
    } catch { Color "  Failed to start app: $_" 'Red'; Log "Start-App error: $_" 'ERROR' }
}

function Stop-App {
    $status = Get-AppStatus-Full
    if (-not $status.running) { Color '  App is not running.' 'Yellow'; return }
    $b = $status.best
    $targetPid = $b.pid
    if ($b.method -eq 'nssm-service') {
        Color "  App is running as Windows Service '$($Config.service.appName)'. Use Service menu to stop it." 'Yellow'
        return
    }
    if ($b.method -in @('port-scan','netstat','process-scan')) {
        Color "  Detected via $($b.method): PID $targetPid ($($b.name)) on port $($Config.port)" 'Yellow'
        if (-not (Ask-YesNo '  Stop this process?' $false)) { return }
    }
    try {
        Stop-Process -Id $targetPid -Force -ErrorAction Stop
        if (Test-Path $Config.pidFile) { Remove-Item $Config.pidFile -Force }
        $State.app.lastStop = (Get-Date).ToString('o'); Save-State $State
        Color "  App stopped (PID $targetPid)." 'Green'; Log "App stopped PID $targetPid"
    } catch {
        Color "  Failed to stop PID $targetPid : $_" 'Red'
        Color "  Try manually: Stop-Process -Id $targetPid -Force" 'Gray'
    }
}

function Restart-App { Stop-App; Start-Sleep 1; Start-App }

# ═════════════════════════════════════════════════════════════════════════════
#  NGINX
# ═════════════════════════════════════════════════════════════════════════════

function Check-Nginx-Installed {
    return (Test-Path $NGINX_EXE)
}

function Detect-Nginx {
    <# Multiple methods to detect Nginx #>
    # Method 1: Windows Service
    $svc = Get-Service -Name $SVC_NGINX -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        $cim = Get-CimInstance Win32_Service -Filter "Name='$SVC_NGINX'" -ErrorAction SilentlyContinue
        $procId = if ($cim) { $cim.ProcessId } else { 0 }
        return @{ running=$true; pid=$procId; method='service'; svcStatus=$svc.Status }
    }
    # Method 2: Process scan
    $procs = Get-Process -Name 'nginx' -ErrorAction SilentlyContinue
    if ($procs) {
        $master = $procs | Where-Object { $_.Id -eq $procs[0].Id } | Select-Object -First 1
        return @{ running=$true; pid=$master.Id; method='process'; workerCount=$procs.Count }
    }
    # Method 3: Port 80/443 check
    foreach ($port in @(80, 443)) {
        try {
            $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
            foreach ($c in $conns) {
                $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
                if ($p -and $p.ProcessName -eq 'nginx') {
                    return @{ running=$true; pid=$p.Id; method="port-$port" }
                }
            }
        } catch {}
    }
    return @{ running=$false }
}

function Nginx-TestConfig {
    if (-not (Check-Nginx-Installed)) { Color '  Nginx not found at expected path.' 'Red'; return $false }
    Color '  Testing nginx configuration...' 'Cyan'
    $result = & $NGINX_EXE -t -c $NGINX_CONF 2>&1
    $result | ForEach-Object { Color "    $_" 'Gray' }
    if ($LASTEXITCODE -eq 0) { Color '  Configuration OK.' 'Green'; return $true }
    else { Color '  Configuration has errors!' 'Red'; return $false }
}

function Start-Nginx {
    if (-not (Check-Nginx-Installed)) { Color '  Nginx not installed.' 'Red'; return }
    $st = Detect-Nginx
    if ($st.running) { Color "  Nginx already running (PID $($st.pid), $($st.method))." 'Yellow'; return }
    if (-not (Nginx-TestConfig)) { Color '  Fix config before starting.' 'Red'; return }
    Color '  Starting Nginx...' 'Cyan'
    Start-Process -FilePath $NGINX_EXE -WorkingDirectory $NGINX_DIR -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $st = Detect-Nginx
    if ($st.running) {
        $State.nginx.lastStart = (Get-Date).ToString('o'); Save-State $State
        Color "  Nginx started (PID $($st.pid))." 'Green'
        Log "Nginx started PID $($st.pid)"
    } else { Color '  Nginx may not have started. Check logs.' 'Yellow' }
}

function Stop-Nginx {
    if (-not (Check-Nginx-Installed)) { Color '  Nginx not installed.' 'Red'; return }
    $st = Detect-Nginx
    if (-not $st.running) { Color '  Nginx is not running.' 'Yellow'; return }
    Color '  Stopping Nginx...' 'Cyan'
    & $NGINX_EXE -s quit -p $NGINX_DIR 2>$null
    Start-Sleep -Seconds 2
    # Force-kill remaining workers if graceful quit failed
    $remaining = Get-Process -Name 'nginx' -ErrorAction SilentlyContinue
    if ($remaining) {
        Color '  Graceful quit incomplete — force-stopping workers...' 'Yellow'
        $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    $State.nginx.lastStop = (Get-Date).ToString('o'); Save-State $State
    Color '  Nginx stopped.' 'Green'
    Log "Nginx stopped"
}

function Restart-Nginx { Stop-Nginx; Start-Sleep 1; Start-Nginx }

function Reload-Nginx {
    if (-not (Check-Nginx-Installed)) { Color '  Nginx not installed.' 'Red'; return }
    $st = Detect-Nginx
    if (-not $st.running) { Color '  Nginx is not running. Start it first.' 'Yellow'; return }
    if (-not (Nginx-TestConfig)) { Color '  Fix config before reloading.' 'Red'; return }
    Color '  Reloading Nginx configuration...' 'Cyan'
    & $NGINX_EXE -s reload -p $NGINX_DIR 2>$null
    Color '  Nginx reloaded.' 'Green'
    Log "Nginx reloaded"
}

function Show-Nginx-Logs {
    $accessLog = Join-Path $NGINX_DIR 'logs\access.log'
    $errorLog  = Join-Path $NGINX_DIR 'logs\error.log'
    Color '' 'Gray'
    Color '  [1] Tail access.log' 'Gray'
    Color '  [2] Tail error.log' 'Gray'
    Color '  [3] Last 50 error lines' 'Gray'
    $c = Read-Choice
    switch ($c) {
        '1' { Tail-Log $accessLog }
        '2' { Tail-Log $errorLog }
        '3' {
            if (Test-Path $errorLog) { Get-Content $errorLog -Tail 50 }
            else { Color '  error.log not found.' 'Yellow' }
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
#  CADDY
# ═════════════════════════════════════════════════════════════════════════════

function Check-Caddy-Installed {
    return (Test-Path $CADDY_EXE)
}

function Detect-Caddy {
    <# Multiple methods to detect Caddy #>
    # Method 1: Windows Service
    $svc = Get-Service -Name $SVC_CADDY -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        $cim = Get-CimInstance Win32_Service -Filter "Name='$SVC_CADDY'" -ErrorAction SilentlyContinue
        $procId = if ($cim) { $cim.ProcessId } else { 0 }
        return @{ running=$true; pid=$procId; method='service'; svcStatus=$svc.Status }
    }
    # Method 2: Process scan
    $procs = Get-Process -Name 'caddy' -ErrorAction SilentlyContinue
    if ($procs) {
        return @{ running=$true; pid=$procs[0].Id; method='process' }
    }
    # Method 3: Caddy admin API (localhost:2019)
    try {
        $resp = Invoke-WebRequest -Uri 'http://localhost:2019/config/' -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        return @{ running=$true; pid=$null; method='admin-api'; statusCode=$resp.StatusCode }
    } catch {
        if ($_.Exception.Response) {
            return @{ running=$true; pid=$null; method='admin-api'; statusCode=[int]$_.Exception.Response.StatusCode }
        }
    }
    return @{ running=$false }
}

function Caddy-Validate {
    if (-not (Check-Caddy-Installed)) { Color '  Caddy not found.' 'Red'; return $false }
    Color '  Validating Caddyfile...' 'Cyan'
    $result = & $CADDY_EXE validate --config $CADDYFILE 2>&1
    $result | ForEach-Object { Color "    $_" 'Gray' }
    if ($LASTEXITCODE -eq 0) { Color '  Caddyfile valid.' 'Green'; return $true }
    else { Color '  Caddyfile has errors!' 'Red'; return $false }
}

function Start-Caddy {
    if (-not (Check-Caddy-Installed)) { Color '  Caddy not installed.' 'Red'; return }
    $st = Detect-Caddy
    if ($st.running) { Color "  Caddy already running ($($st.method))." 'Yellow'; return }
    Color '  Starting Caddy...' 'Cyan'
    Start-Process -FilePath $CADDY_EXE -ArgumentList "start --config `"$CADDYFILE`"" -WorkingDirectory $CADDY_DIR -WindowStyle Hidden
    Start-Sleep -Seconds 3
    $st = Detect-Caddy
    if ($st.running) {
        $State.caddy.lastStart = (Get-Date).ToString('o'); Save-State $State
        Color "  Caddy started ($($st.method))." 'Green'
        Log "Caddy started"
    } else { Color '  Caddy may not have started. Check logs.' 'Yellow' }
}

function Stop-Caddy {
    if (-not (Check-Caddy-Installed)) { Color '  Caddy not installed.' 'Red'; return }
    $st = Detect-Caddy
    if (-not $st.running) { Color '  Caddy is not running.' 'Yellow'; return }
    Color '  Stopping Caddy...' 'Cyan'
    & $CADDY_EXE stop 2>$null
    Start-Sleep -Seconds 2
    $remaining = Get-Process -Name 'caddy' -ErrorAction SilentlyContinue
    if ($remaining) { $remaining | Stop-Process -Force -ErrorAction SilentlyContinue }
    $State.caddy.lastStop = (Get-Date).ToString('o'); Save-State $State
    Color '  Caddy stopped.' 'Green'
    Log "Caddy stopped"
}

function Restart-Caddy { Stop-Caddy; Start-Sleep 1; Start-Caddy }

function Reload-Caddy {
    if (-not (Check-Caddy-Installed)) { Color '  Caddy not installed.' 'Red'; return }
    $st = Detect-Caddy
    if (-not $st.running) { Color '  Caddy is not running. Start it first.' 'Yellow'; return }
    Color '  Reloading Caddy configuration...' 'Cyan'
    & $CADDY_EXE reload --config $CADDYFILE 2>&1 | ForEach-Object { Color "    $_" 'Gray' }
    if ($LASTEXITCODE -eq 0) { Color '  Caddy reloaded.' 'Green'; Log "Caddy reloaded" }
    else { Color '  Reload failed. Validate Caddyfile first.' 'Red' }
}

# ═════════════════════════════════════════════════════════════════════════════
#  MONGODB
# ═════════════════════════════════════════════════════════════════════════════

function Get-Mongo-Service {
    foreach ($name in $SVC_MONGO) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) { return $svc }
    }
    return $null
}

function Detect-Mongo {
    # Method 1: Windows Service
    $svc = Get-Mongo-Service
    if ($svc) {
        $running = $svc.Status -eq 'Running'
        $procId = 0; $startTime = $null
        if ($running) {
            $cim = Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue
            $procId = if ($cim) { $cim.ProcessId } else { 0 }
            if ($procId -gt 0) { $p = Get-Process -Id $procId -ErrorAction SilentlyContinue; if ($p) { $startTime = $p.StartTime } }
        }
        return @{ installed=$true; name=$svc.Name; running=$running; status=$svc.Status; pid=$procId; start=$startTime; method='service' }
    }
    # Method 2: Process scan
    $procs = Get-Process -Name 'mongod','mongos' -ErrorAction SilentlyContinue
    if ($procs) {
        return @{ installed=$true; name='mongod'; running=$true; pid=$procs[0].Id; start=$procs[0].StartTime; method='process' }
    }
    # Method 3: Port 27017 check
    try {
        $conns = Get-NetTCPConnection -LocalPort 27017 -State Listen -ErrorAction SilentlyContinue
        if ($conns) {
            $procId = $conns[0].OwningProcess
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            return @{ installed=$true; name=if($p){$p.ProcessName}else{'Unknown'}; running=$true; pid=$procId; start=if($p){$p.StartTime}else{$null}; method='port-27017' }
        }
    } catch {}
    # Method 4: Check if mongod.exe exists on PATH or common locations
    $mongoExe = Get-Command 'mongod' -ErrorAction SilentlyContinue
    if ($mongoExe) { return @{ installed=$true; running=$false; method='exe-found'; path=$mongoExe.Source } }
    foreach ($p in @('C:\Program Files\MongoDB\Server', 'C:\MongoDB\Server')) {
        if (Test-Path $p) { return @{ installed=$true; running=$false; method='dir-found'; path=$p } }
    }
    return @{ installed=$false; running=$false }
}

function Start-Mongo {
    if (-not (Ensure-Admin-Guard 'starting MongoDB')) { return }
    $svc = Get-Mongo-Service
    if (!$svc) { Color '  MongoDB service not found.' 'Yellow'; return }
    if ($svc.Status -eq 'Running') { Color '  MongoDB is already running.' 'Yellow'; return }
    Start-Service $svc.Name
    $State.mongodb.lastStart = (Get-Date).ToString('o'); Save-State $State
    Color '  MongoDB started.' 'Green'; Log "MongoDB started"
}

function Stop-Mongo {
    if (-not (Ensure-Admin-Guard 'stopping MongoDB')) { return }
    $svc = Get-Mongo-Service
    if (!$svc) { Color '  MongoDB service not found.' 'Yellow'; return }
    if ($svc.Status -ne 'Running') { Color '  MongoDB is not running.' 'Yellow'; return }
    Stop-Service $svc.Name
    $State.mongodb.lastStop = (Get-Date).ToString('o'); Save-State $State
    Color '  MongoDB stopped.' 'Green'; Log "MongoDB stopped"
}

function Restart-Mongo {
    if (-not (Ensure-Admin-Guard 'restarting MongoDB')) { return }
    $svc = Get-Mongo-Service
    if (!$svc) { Color '  MongoDB service not found.' 'Yellow'; return }
    Restart-Service $svc.Name
    $State.mongodb.lastStart = (Get-Date).ToString('o'); Save-State $State
    Color '  MongoDB restarted.' 'Green'; Log "MongoDB restarted"
}

# ═════════════════════════════════════════════════════════════════════════════
#  NSSM — Windows Service Management
# ═════════════════════════════════════════════════════════════════════════════

function Get-NSSM {
    if (Test-Path $NSSM_EXE) { return $NSSM_EXE }
    $cmd = Get-Command 'nssm' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Search common NSSM locations
    foreach ($p in @(
        'C:\Tools\NSSM\win64\nssm.exe',
        'C:\Tools\NSSM\nssm.exe',
        'C:\nssm\win64\nssm.exe',
        'C:\Program Files\nssm\win64\nssm.exe',
        'C:\Program Files (x86)\nssm\win64\nssm.exe'
    )) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Service-Status([string]$name) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) { return @{ exists=$false } }
    $running = $svc.Status -eq 'Running'
    $procId = 0; $startTime = $null
    try {
        $cim = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
        $procId = if ($cim) { $cim.ProcessId } else { 0 }
        if ($procId -gt 0) { $p = Get-Process -Id $procId -ErrorAction SilentlyContinue; if ($p) { $startTime = $p.StartTime } }
    } catch {}
    return @{ exists=$true; running=$running; status=$svc.Status; pid=$procId; startTime=$startTime; startType=$svc.StartType }
}

function Create-AppService {
    if (-not (Ensure-Admin-Guard 'creating a Windows Service')) { return }
    if (-not (Ensure-Venv))     { return }
    if (-not (Ensure-Waitress)) { return }
    $nssm = Get-NSSM
    if (-not $nssm) { Color '  NSSM not found. Place nssm.exe in C:\Tools\NSSM\win64\' 'Red'; return }
    $svcName = $Config.service.appName
    $existing = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($existing) {
        Color "  Service '$svcName' already exists (Status: $($existing.Status))." 'Yellow'
        if (-not (Ask-YesNo '  Recreate service?' $true)) { return }
        & $nssm stop $svcName 2>$null; Start-Sleep 1
        & $nssm remove $svcName confirm; Start-Sleep 1
    }
    $argLine = "-m waitress --host $($Config.host) --port $($Config.port) $($Config.wsgiEntrypoint)"
    $stdoutLog = Join-Path $Config.logsDir 'app_stdout.log'
    $stderrLog = Join-Path $Config.logsDir 'app_stderr.log'

    Color "  Creating service '$svcName'..." 'Cyan'
    & $nssm install $svcName $PYTHON_EXE $argLine
    & $nssm set $svcName AppDirectory $APP_DIR
    & $nssm set $svcName AppStdout    $stdoutLog
    & $nssm set $svcName AppStderr    $stderrLog
    & $nssm set $svcName Start        $(if ($Config.service.startMode -eq 'auto') { 'SERVICE_AUTO_START' } else { 'SERVICE_DEMAND_START' })
    & $nssm set $svcName AppStopMethodSkip    6
    & $nssm set $svcName AppStopMethodConsole 15000
    & $nssm set $svcName AppStopMethodWindow  15000
    & $nssm set $svcName AppStopMethodThreads 0
    Color "  Service '$svcName' created." 'Green'
    Log "NSSM service '$svcName' created"
}

function Remove-AppService {
    if (-not (Ensure-Admin-Guard 'removing a Windows Service')) { return }
    $svcName = $Config.service.appName
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) { Color "  Service '$svcName' does not exist." 'Yellow'; return }
    $nssm = Get-NSSM
    if (-not $nssm) { Color '  NSSM not found.' 'Red'; return }
    if (Ask-YesNo "  Stop and remove service '$svcName'?" $true) {
        & $nssm stop $svcName 2>$null; & $nssm remove $svcName confirm
        Color '  Service removed.' 'Green'; Log "Service '$svcName' removed"
    }
}

function Install-NginxService {
    if (-not (Ensure-Admin-Guard 'installing Nginx service')) { return }
    if (-not (Check-Nginx-Installed)) { Color '  Nginx not found.' 'Red'; return }
    $nssm = Get-NSSM
    if (-not $nssm) { Color '  NSSM not found.' 'Red'; return }
    $existing = Get-Service -Name $SVC_NGINX -ErrorAction SilentlyContinue
    if ($existing) {
        Color "  Nginx service already exists (Status: $($existing.Status))." 'Yellow'
        if (-not (Ask-YesNo '  Recreate?' $true)) { return }
        & $nssm stop $SVC_NGINX 2>$null; Start-Sleep 1
        & $nssm remove $SVC_NGINX confirm; Start-Sleep 1
    }
    Color '  Creating Nginx Windows Service...' 'Cyan'
    & $nssm install $SVC_NGINX $NGINX_EXE
    & $nssm set $SVC_NGINX AppDirectory $NGINX_DIR
    & $nssm set $SVC_NGINX Start SERVICE_AUTO_START
    Color '  Nginx service installed.' 'Green'
    Log "Nginx NSSM service installed"
}

function Install-CaddyService {
    if (-not (Ensure-Admin-Guard 'installing Caddy service')) { return }
    if (-not (Check-Caddy-Installed)) { Color '  Caddy not found.' 'Red'; return }
    $nssm = Get-NSSM
    if (-not $nssm) { Color '  NSSM not found.' 'Red'; return }
    $existing = Get-Service -Name $SVC_CADDY -ErrorAction SilentlyContinue
    if ($existing) {
        Color "  Caddy service already exists (Status: $($existing.Status))." 'Yellow'
        if (-not (Ask-YesNo '  Recreate?' $true)) { return }
        & $nssm stop $SVC_CADDY 2>$null; Start-Sleep 1
        & $nssm remove $SVC_CADDY confirm; Start-Sleep 1
    }
    Color '  Creating Caddy Windows Service...' 'Cyan'
    & $nssm install $SVC_CADDY $CADDY_EXE "run --config `"$CADDYFILE`""
    & $nssm set $SVC_CADDY AppDirectory $CADDY_DIR
    & $nssm set $SVC_CADDY Start SERVICE_AUTO_START
    Color '  Caddy service installed.' 'Green'
    Log "Caddy NSSM service installed"
}

# ═════════════════════════════════════════════════════════════════════════════
#  BACKUP & RESTORE
# ═════════════════════════════════════════════════════════════════════════════

function New-AppBackup {
    $includeVenv = Ask-YesNo '  Include venv in backup? (increases size)' $true
    $ts  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $zip = Join-Path $backupsDir "app_backup_$ts.zip"
    $tmp = Join-Path $env:TEMP ('app_backup_' + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Copy-Item -Path $configPath -Destination $tmp -Force -ErrorAction SilentlyContinue | Out-Null
    Copy-Item -Path $APP_DIR -Destination (Join-Path $tmp 'app') -Recurse -Force
    if ($includeVenv -and (Test-Path $VENV_DIR)) {
        Copy-Item -Path $VENV_DIR -Destination (Join-Path $tmp 'venv') -Recurse -Force
    }
    Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $zip -Force
    Remove-Item $tmp -Recurse -Force
    $sz = [math]::Round((Get-Item $zip).Length / 1MB, 2)
    Color "  Backup created: $zip ($sz MB)" 'Green'
}

function Restore-AppBackup {
    $files = Get-ChildItem -Path $backupsDir -Filter '*.zip' | Sort-Object LastWriteTime -Descending
    if (!$files) { Color "  No backups found in $backupsDir" 'Yellow'; return }
    Color '  Available backups:' 'Cyan'
    $i = 1
    foreach ($f in $files) {
        $sz = [math]::Round($f.Length / 1MB, 2)
        Color ("    [{0}] {1} ({2} MB)" -f $i, $f.Name, $sz) 'Gray'
        $i++
    }
    $sel = Read-Host "  Pick number to restore (or 'back')"
    if ($sel.Trim().ToLower() -eq 'back') { return }
    $index = 0; [int]::TryParse($sel, [ref]$index) | Out-Null
    if ($index -lt 1 -or $index -gt $files.Count) { Color '  Invalid selection.' 'Red'; return }
    $zip = $files[$index - 1].FullName
    if (-not (Ask-YesNo '  Overwrite current app files?' $true)) { return }
    $tmp = Join-Path $env:TEMP ('restore_' + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    if (Test-Path (Join-Path $tmp 'config.json')) {
        Copy-Item -Path (Join-Path $tmp 'config.json') -Destination $configPath -Force
        $Config = Load-Config
    }
    if (Test-Path (Join-Path $tmp 'app')) {
        Copy-Item -Path (Join-Path $tmp 'app\*') -Destination $APP_DIR -Recurse -Force
    }
    if (Test-Path (Join-Path $tmp 'venv')) {
        if (Test-Path $VENV_DIR) { Remove-Item $VENV_DIR -Recurse -Force }
        Copy-Item -Path (Join-Path $tmp 'venv') -Destination $VENV_DIR -Recurse -Force
    }
    Remove-Item $tmp -Recurse -Force
    Color '  Restore complete.' 'Green'
}

# ═════════════════════════════════════════════════════════════════════════════
#  STATUS DASHBOARD
# ═════════════════════════════════════════════════════════════════════════════

function Show-QuickStatus {
    <# Compact one-line-per-service status #>
    $sym_ok   = [char]0x2714   # checkmark
    $sym_fail = [char]0x2718   # cross
    $sym_warn = '!'
    $sym_na   = '-'

    # Flask App
    $app = Get-AppStatus-Full
    if ($app.running -and $app.responding) {
        StatusBullet $sym_ok "Flask App       PID $($app.best.pid)  port $($Config.port)  HTTP $($app.http.statusCode)  ($($app.best.method))" 'Green'
    } elseif ($app.running) {
        StatusBullet $sym_warn "Flask App       PID $($app.best.pid)  port $($Config.port)  NOT RESPONDING  ($($app.best.method))" 'Yellow'
    } else {
        StatusBullet $sym_fail "Flask App       DOWN" 'Red'
    }

    # Nginx
    if (Check-Nginx-Installed) {
        $ng = Detect-Nginx
        if ($ng.running) { StatusBullet $sym_ok "Nginx           PID $($ng.pid)  ($($ng.method))" 'Green' }
        else { StatusBullet $sym_fail "Nginx           DOWN" 'Red' }
    } else { StatusBullet $sym_na "Nginx           not installed" 'DarkGray' }

    # Caddy
    if (Check-Caddy-Installed) {
        $cd = Detect-Caddy
        if ($cd.running) { StatusBullet $sym_ok "Caddy           ($($cd.method))" 'Green' }
        else { StatusBullet $sym_fail "Caddy           DOWN" 'Red' }
    } else { StatusBullet $sym_na "Caddy           not installed" 'DarkGray' }

    # MongoDB
    $mg = Detect-Mongo
    if ($mg.installed -and $mg.running) {
        StatusBullet $sym_ok "MongoDB         PID $($mg.pid)  ($($mg.method))" 'Green'
    } elseif ($mg.installed) {
        StatusBullet $sym_fail "MongoDB         STOPPED  ($($mg.method))" 'Red'
    } else { StatusBullet $sym_na "MongoDB         not installed" 'DarkGray' }

    # NSSM
    $nssm = Get-NSSM
    if ($nssm) { StatusBullet $sym_ok "NSSM            $nssm" 'Green' }
    else { StatusBullet $sym_na "NSSM            not found" 'DarkGray' }
}

function Show-DetailedStatus {
    Header 'DETAILED STATUS REPORT'
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Color "  Report generated: $ts" 'DarkGray'
    Color "  Admin: $(if (Is-Admin) { 'Yes' } else { 'No' })" 'DarkGray'
    Write-Host ''

    # ── Flask App ────────────────────────────────────
    SubHeader 'Flask App (Waitress)'
    $app = Get-AppStatus-Full
    if ($app.running) {
        $b = $app.best
        StatusLine 'Status:' 'RUNNING' 'Green'
        StatusLine 'PID:' "$($b.pid)" 'Green'
        StatusLine 'Detection:' "$($b.method)" 'Gray'
        if ($b.start) { StatusLine 'Uptime:' (Format-Uptime $b.start) 'Gray' }
        StatusLine 'Port:' "$($Config.port)" 'Gray'

        # Show all detection methods
        Color '' 'Gray'
        Color '  Detection methods:' 'DarkCyan'
        foreach ($key in @('pidFile','port','process','nssm')) {
            $det = $app[$key]
            if ($det) {
                Color "    $($key): PID $($det.pid) ($($det.method))" 'Gray'
                if ($det.cmdLine) { Color "      cmd: $($det.cmdLine)" 'DarkGray' }
            } else {
                Color "    $($key): not detected" 'DarkGray'
            }
        }
        if ($app.http) {
            if ($app.http.responding) {
                Color "    http: $($app.http.url) -> $($app.http.statusCode)" 'Gray'
            } else {
                Color "    http: $($app.http.url) -> NOT RESPONDING" 'Yellow'
                if ($app.http.error) { Color "      $($app.http.error)" 'DarkGray' }
            }
        }
    } else {
        StatusLine 'Status:' 'STOPPED' 'Red'
        if ($State.app.lastStop) { StatusLine 'Last stopped:' $State.app.lastStop 'Gray' }
        if ($State.app.lastStart) { StatusLine 'Last started:' $State.app.lastStart 'Gray' }
    }

    # ── Nginx ────────────────────────────────────────
    SubHeader 'Nginx'
    if (Check-Nginx-Installed) {
        $ng = Detect-Nginx
        StatusLine 'Installed:' "Yes ($NGINX_EXE)" 'Green'
        if ($ng.running) {
            StatusLine 'Status:' 'RUNNING' 'Green'
            StatusLine 'PID:' "$($ng.pid)" 'Gray'
            StatusLine 'Detection:' "$($ng.method)" 'Gray'
            if ($ng.workerCount) { StatusLine 'Workers:' "$($ng.workerCount)" 'Gray' }
        } else {
            StatusLine 'Status:' 'STOPPED' 'Red'
        }
        StatusLine 'Config:' $NGINX_CONF 'DarkGray'
    } else {
        StatusLine 'Installed:' "No ($NGINX_EXE not found)" 'Yellow'
    }

    # ── Caddy ────────────────────────────────────────
    SubHeader 'Caddy'
    if (Check-Caddy-Installed) {
        $cd = Detect-Caddy
        StatusLine 'Installed:' "Yes ($CADDY_EXE)" 'Green'
        if ($cd.running) {
            StatusLine 'Status:' 'RUNNING' 'Green'
            if ($cd.pid) { StatusLine 'PID:' "$($cd.pid)" 'Gray' }
            StatusLine 'Detection:' "$($cd.method)" 'Gray'
        } else {
            StatusLine 'Status:' 'STOPPED' 'Red'
        }
        StatusLine 'Caddyfile:' $CADDYFILE 'DarkGray'
    } else {
        StatusLine 'Installed:' "No ($CADDY_EXE not found)" 'Yellow'
    }

    # ── MongoDB ──────────────────────────────────────
    SubHeader 'MongoDB'
    $mg = Detect-Mongo
    if ($mg.installed) {
        StatusLine 'Installed:' 'Yes' 'Green'
        if ($mg.running) {
            StatusLine 'Status:' 'RUNNING' 'Green'
            StatusLine 'PID:' "$($mg.pid)" 'Gray'
            StatusLine 'Detection:' "$($mg.method)" 'Gray'
            if ($mg.name) { StatusLine 'Service:' "$($mg.name)" 'Gray' }
            if ($mg.start) { StatusLine 'Uptime:' (Format-Uptime $mg.start) 'Gray' }
        } else {
            StatusLine 'Status:' 'STOPPED' 'Red'
            StatusLine 'Detection:' "$($mg.method)" 'Gray'
        }
    } else {
        StatusLine 'Installed:' 'No' 'Yellow'
    }

    # ── NSSM Services ────────────────────────────────
    SubHeader 'NSSM / Windows Services'
    $nssm = Get-NSSM
    StatusLine 'NSSM:' $(if ($nssm) { $nssm } else { 'NOT FOUND' }) $(if ($nssm) { 'Green' } else { 'Red' })
    foreach ($svcName in @($Config.service.appName, $SVC_NGINX, $SVC_CADDY)) {
        $st = Service-Status $svcName
        if ($st.exists) {
            $info = "$($st.status)  StartType=$($st.startType)"
            if ($st.running -and $st.startTime) { $info += "  Uptime=$(Format-Uptime $st.startTime)  PID=$($st.pid)" }
            StatusLine "${svcName}:" $info $(if ($st.running) { 'Green' } else { 'Yellow' })
        } else {
            StatusLine "${svcName}:" 'not installed' 'DarkGray'
        }
    }

    # ── Python ───────────────────────────────────────
    Check-Python

    # ── Paths ────────────────────────────────────────
    SubHeader 'Configured Paths'
    foreach ($item in @(
        @('App Dir',      $APP_DIR),
        @('Venv Dir',     $VENV_DIR),
        @('Python',       $PYTHON_EXE),
        @('Nginx',        $NGINX_EXE),
        @('Caddy',        $CADDY_EXE),
        @('NSSM',         $NSSM_EXE),
        @('Logs Dir',     $Config.logsDir),
        @('PID File',     $Config.pidFile)
    )) {
        $exists = Test-Path $item[1]
        StatusLine "$($item[0]):" "$($item[1]) $(if ($exists) { '' } else { '[MISSING]' })" $(if ($exists) { 'Gray' } else { 'Red' })
    }

    Pause-Enter
}

function Show-SystemInfo {
    Header 'System Info'
    Color ('  OS: '         + (Get-CimInstance Win32_OperatingSystem).Caption) 'Gray'
    Color ('  Version: '    + (Get-CimInstance Win32_OperatingSystem).Version) 'Gray'
    Color ('  PowerShell: ' + $PSVersionTable.PSVersion.ToString()) 'Gray'
    Color ('  Admin: '      + $(if (Is-Admin) { 'Yes' } else { 'No' })) 'Gray'
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $nc  = $cpu.NumberOfLogicalProcessors
    Color ("  CPU: $($cpu.Name) ($nc cores)") 'Gray'
    $mem = Get-CimInstance Win32_OperatingSystem
    $tot = [math]::Round($mem.TotalVisibleMemorySize / 1MB, 2)
    $free = [math]::Round($mem.FreePhysicalMemory / 1MB, 2)
    Color ("  Memory: $tot GB total / $free GB free") 'Gray'

    SubHeader 'Key Ports'
    foreach ($port in @($Config.port, 80, 443, 27017, 2019)) {
        $pp = Get-PortProcess $port
        if ($pp) {
            $pp | ForEach-Object { Color ("  :$port -> PID $($_.PID) $($_.Name)") 'Gray' }
        } else {
            Color "  :$port -> free" 'DarkGray'
        }
    }

    SubHeader 'Top Processes by CPU'
    Get-Process | Sort-Object CPU -Descending | Select-Object -First 8 | ForEach-Object {
        $cpu2 = [math]::Round($_.CPU, 2)
        $memMB = [math]::Round($_.WorkingSet64 / 1MB, 1)
        Color ("  {0,6}  {1,-25} CPU={2,10}  Mem={3,7} MB" -f $_.Id, $_.ProcessName, $cpu2, $memMB) 'Gray'
    }
    Pause-Enter
}

# ═════════════════════════════════════════════════════════════════════════════
#  BULK OPERATIONS
# ═════════════════════════════════════════════════════════════════════════════

function Start-All {
    Header 'START ALL SERVICES'
    Color '  Starting MongoDB...' 'Cyan'
    $svc = Get-Mongo-Service
    if ($svc -and $svc.Status -ne 'Running') {
        if (Is-Admin) { Start-Service $svc.Name; Color '  MongoDB started.' 'Green' }
        else { Color '  Skipped — needs admin.' 'Yellow' }
    } elseif ($svc) { Color '  MongoDB already running.' 'DarkGray' }

    Color '  Starting Flask App...' 'Cyan'
    Start-App

    if (Check-Nginx-Installed) {
        Color '  Starting Nginx...' 'Cyan'
        Start-Nginx
    }
    if (Check-Caddy-Installed) {
        Color '  Starting Caddy...' 'Cyan'
        Start-Caddy
    }
    Write-Host ''
    Show-QuickStatus
}

function Stop-All {
    Header 'STOP ALL SERVICES'
    if (Check-Caddy-Installed) {
        Color '  Stopping Caddy...' 'Cyan'
        Stop-Caddy
    }
    if (Check-Nginx-Installed) {
        Color '  Stopping Nginx...' 'Cyan'
        Stop-Nginx
    }
    Color '  Stopping Flask App...' 'Cyan'
    Stop-App
    $svc = Get-Mongo-Service
    if ($svc -and $svc.Status -eq 'Running') {
        if (Is-Admin) {
            Color '  Stopping MongoDB...' 'Cyan'
            Stop-Service $svc.Name; Color '  MongoDB stopped.' 'Green'
        } else { Color '  MongoDB — skipped (needs admin).' 'Yellow' }
    }
    Write-Host ''
    Show-QuickStatus
}

function Restart-All {
    Header 'RESTART ALL SERVICES'
    Stop-All
    Start-Sleep 2
    Start-All
}

# ═════════════════════════════════════════════════════════════════════════════
#  HEALTH CHECK
# ═════════════════════════════════════════════════════════════════════════════

function Run-HealthCheck {
    Header 'HEALTH CHECK'
    $allGood = $true

    # 1. MongoDB
    Color '  [1/5] MongoDB...' 'Cyan'
    $mg = Detect-Mongo
    if ($mg.installed -and $mg.running) { Color '    OK — running' 'Green' }
    elseif ($mg.installed) { Color '    FAIL — installed but not running' 'Red'; $allGood = $false }
    else { Color '    WARN — not installed' 'Yellow'; $allGood = $false }

    # 2. Flask port
    Color '  [2/5] Flask port binding...' 'Cyan'
    $portDet = Detect-App-ByPort
    if ($portDet) { Color "    OK — PID $($portDet.pid) on port $($Config.port)" 'Green' }
    else { Color "    FAIL — nothing on port $($Config.port)" 'Red'; $allGood = $false }

    # 3. HTTP health
    Color '  [3/5] HTTP response...' 'Cyan'
    $http = Detect-App-ByHTTP
    if ($http.responding) { Color "    OK — HTTP $($http.statusCode) from $($http.url)" 'Green' }
    else { Color "    FAIL — no HTTP response from $($http.url)" 'Red'; $allGood = $false }

    # 4. Reverse proxy
    Color '  [4/5] Reverse proxy...' 'Cyan'
    $ngOk = $false; $cdOk = $false
    if (Check-Nginx-Installed) { $ng = Detect-Nginx; if ($ng.running) { $ngOk = $true } }
    if (Check-Caddy-Installed) { $cd = Detect-Caddy; if ($cd.running) { $cdOk = $true } }
    if ($ngOk)     { Color '    OK — Nginx running' 'Green' }
    elseif ($cdOk) { Color '    OK — Caddy running' 'Green' }
    else { Color '    WARN — no reverse proxy running' 'Yellow' }

    # 5. Disk space
    Color '  [5/5] Disk space...' 'Cyan'
    $drive = (Get-Item $APP_DIR -ErrorAction SilentlyContinue)
    if ($drive) {
        $driveLetter = $drive.PSDrive.Name
        $psDrive = Get-PSDrive $driveLetter -ErrorAction SilentlyContinue
        if ($psDrive) {
            $freeGB = [math]::Round($psDrive.Free / 1GB, 2)
            if ($freeGB -gt 5) { Color "    OK — ${driveLetter}: $freeGB GB free" 'Green' }
            elseif ($freeGB -gt 1) { Color "    WARN — ${driveLetter}: $freeGB GB free (low)" 'Yellow' }
            else { Color "    CRITICAL — ${driveLetter}: $freeGB GB free" 'Red'; $allGood = $false }
        }
    }

    Write-Host ''
    if ($allGood) { Color '  Overall: ALL CHECKS PASSED' 'Green' }
    else { Color '  Overall: SOME CHECKS FAILED — see above' 'Red' }
    Pause-Enter
}

# ═════════════════════════════════════════════════════════════════════════════
#  CONFIG MENU
# ═════════════════════════════════════════════════════════════════════════════

function Show-Config {
    Header 'Current Config'
    $Config | ConvertTo-Json -Depth 10 | Write-Host
    Write-Host ''
    Color "  Config file: $configPath" 'DarkGray'
    Pause-Enter
}

function Edit-Config {
    while ($true) {
        Header 'Edit Config'
        Color "  [1]  Host              ($($Config.host))" 'Gray'
        Color "  [2]  Port              ($($Config.port))" 'Gray'
        Color "  [3]  WSGI Entrypoint   ($($Config.wsgiEntrypoint))" 'Gray'
        Color "  [4]  Logs Dir          ($($Config.logsDir))" 'Gray'
        Color "  [5]  Health Check URL  ($($Config.healthCheckUrl))" 'Gray'
        Color "  [6]  MongoDB Log Path  ($($Config.mongodbLogPath))" 'Gray'
        Color "  [7]  Service Name      ($($Config.service.appName))" 'Gray'
        Color "  [8]  Service StartMode ($($Config.service.startMode))" 'Gray'
        Color "  [9]  Log Rotation MB   ($($Config.logRotationMB))" 'Gray'
        Color "  Type number to edit, 'back' to return." 'Yellow'
        $c = Read-Choice
        switch ($c.ToLower()) {
            '1' { $v = Read-Host '  Host'; if ($v) { $Config.host = $v; Save-Config $Config } }
            '2' { $v = Read-Host '  Port (1-65535)'; if ($v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le 65535) { $Config.port = [int]$v; Save-Config $Config } else { Color '  Invalid port.' 'Red' } }
            '3' { $v = Read-Host '  WSGI entrypoint (module:object)'; if ($v) { $Config.wsgiEntrypoint = $v; Save-Config $Config } }
            '4' { $v = Read-Host '  Logs dir'; if ($v) { $Config.logsDir = $v; if (!(Test-Path $v)) { New-Item -ItemType Directory -Path $v | Out-Null }; Save-Config $Config } }
            '5' { $v = Read-Host '  Health check URL'; if ($v) { $Config.healthCheckUrl = $v; Save-Config $Config } }
            '6' { $v = Read-Host '  MongoDB log file path'; if ($v) { $Config.mongodbLogPath = $v; Save-Config $Config } }
            '7' { $v = Read-Host '  Service name'; if ($v) { $Config.service.appName = $v; Save-Config $Config } }
            '8' { $v = Read-Host '  Start mode (auto|demand)'; if ($v -in @('auto','demand')) { $Config.service.startMode = $v; Save-Config $Config } else { Color '  Invalid.' 'Red' } }
            '9' { $v = Read-Host '  Rotation threshold in MB'; if ($v -match '^\d+$' -and [int]$v -gt 0) { $Config.logRotationMB = [int]$v; Save-Config $Config } else { Color '  Invalid.' 'Red' } }
            'back' { return }
            'quit' { exit }
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
#  INTERACTIVE MENUS
# ═════════════════════════════════════════════════════════════════════════════

function Menu-App {
    while ($true) {
        Header 'Flask App (Waitress)'
        $app = Get-AppStatus-Full
        if ($app.running) {
            $b = $app.best
            $upStr = if ($b.start) { "  Uptime: $(Format-Uptime $b.start)" } else { '' }
            $httpStr = if ($app.responding) { "  HTTP=$($app.http.statusCode)" } else { '  HTTP=N/A' }
            Color "  Status: RUNNING  PID $($b.pid)  port $($Config.port)$httpStr$upStr  ($($b.method))" 'Green'
        } else {
            Color '  Status: STOPPED' 'Red'
        }
        Write-Host ''
        Color '  [1] Start' 'Gray'
        Color '  [2] Stop' 'Gray'
        Color '  [3] Restart' 'Gray'
        Color '  [4] Detailed detection report' 'Gray'
        Color '  [5] HTTP health check' 'Gray'
        Color '  [6] Tail stdout' 'Gray'
        Color '  [7] Tail stderr' 'Gray'
        Color '  [8] Show recent errors' 'Gray'
        Color '  [9] Rotate logs' 'Gray'
        Color "  Type 'back' to return." 'Yellow'
        $c = Read-Choice
        switch ($c.ToLower()) {
            '1' { Start-App; Pause-Enter }
            '2' { Stop-App; Pause-Enter }
            '3' { Restart-App; Pause-Enter }
            '4' {
                $app = Get-AppStatus-Full
                SubHeader 'All Detection Methods'
                foreach ($key in @('pidFile','port','process','nssm','http')) {
                    $det = $app[$key]
                    if ($det) {
                        $info = ($det.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '  '
                        Color "  $($key): $info" 'Gray'
                    } else {
                        Color "  $($key): not detected" 'DarkGray'
                    }
                }
                Pause-Enter
            }
            '5' {
                $http = Detect-App-ByHTTP
                if ($http.responding) { Color "  HTTP $($http.statusCode) from $($http.url)" 'Green' }
                else { Color "  No response from $($http.url)" 'Red'; if ($http.error) { Color "  $($http.error)" 'DarkGray' } }
                Pause-Enter
            }
            '6' { $kw = Read-Host '  Keyword filter (optional)'; Tail-Log (Join-Path $Config.logsDir 'app_stdout.log') $kw }
            '7' { $kw = Read-Host '  Keyword filter (optional)'; Tail-Log (Join-Path $Config.logsDir 'app_stderr.log') $kw }
            '8' { Show-RecentErrors 200; Pause-Enter }
            '9' { Rotate-AppLogs; Color '  Done.' 'Green'; Pause-Enter }
            'back' { return }
            'quit' { exit }
        }
    }
}

function Menu-Nginx {
    while ($true) {
        Header 'Nginx'
        if (Check-Nginx-Installed) {
            $st = Detect-Nginx
            if ($st.running) { Color "  Status: RUNNING  PID $($st.pid)  ($($st.method))" 'Green' }
            else { Color '  Status: STOPPED' 'Red' }
        } else { Color "  Nginx not found at $NGINX_EXE" 'Yellow' }
        Write-Host ''
        Color '  [1] Start' 'Gray'
        Color '  [2] Stop' 'Gray'
        Color '  [3] Restart' 'Gray'
        Color '  [4] Reload config (graceful)' 'Gray'
        Color '  [5] Test config' 'Gray'
        Color '  [6] View logs' 'Gray'
        Color '  [7] Install as Windows Service (NSSM)' 'Gray'
        Color "  Type 'back' to return." 'Yellow'
        $c = Read-Choice
        switch ($c.ToLower()) {
            '1' { Start-Nginx; Pause-Enter }
            '2' { Stop-Nginx; Pause-Enter }
            '3' { Restart-Nginx; Pause-Enter }
            '4' { Reload-Nginx; Pause-Enter }
            '5' { Nginx-TestConfig; Pause-Enter }
            '6' { Show-Nginx-Logs }
            '7' { Install-NginxService; Pause-Enter }
            'back' { return }
            'quit' { exit }
        }
    }
}

function Menu-Caddy {
    while ($true) {
        Header 'Caddy'
        if (Check-Caddy-Installed) {
            $st = Detect-Caddy
            if ($st.running) { Color "  Status: RUNNING  ($($st.method))" 'Green' }
            else { Color '  Status: STOPPED' 'Red' }
        } else { Color "  Caddy not found at $CADDY_EXE" 'Yellow' }
        Write-Host ''
        Color '  [1] Start' 'Gray'
        Color '  [2] Stop' 'Gray'
        Color '  [3] Restart' 'Gray'
        Color '  [4] Reload config' 'Gray'
        Color '  [5] Validate Caddyfile' 'Gray'
        Color '  [6] Install as Windows Service (NSSM)' 'Gray'
        Color "  Type 'back' to return." 'Yellow'
        $c = Read-Choice
        switch ($c.ToLower()) {
            '1' { Start-Caddy; Pause-Enter }
            '2' { Stop-Caddy; Pause-Enter }
            '3' { Restart-Caddy; Pause-Enter }
            '4' { Reload-Caddy; Pause-Enter }
            '5' { Caddy-Validate; Pause-Enter }
            '6' { Install-CaddyService; Pause-Enter }
            'back' { return }
            'quit' { exit }
        }
    }
}

function Menu-Mongo {
    while ($true) {
        Header 'MongoDB'
        $mg = Detect-Mongo
        if ($mg.installed -and $mg.running) {
            $upStr = if ($mg.start) { "  Uptime: $(Format-Uptime $mg.start)" } else { '' }
            Color "  Status: RUNNING  PID $($mg.pid)$upStr  ($($mg.method))" 'Green'
        } elseif ($mg.installed) {
            Color '  Status: STOPPED (installed)' 'Red'
        } else {
            Color '  Status: NOT INSTALLED' 'Yellow'
        }
        Write-Host ''
        Color '  [1] Start' 'Gray'
        Color '  [2] Stop' 'Gray'
        Color '  [3] Restart' 'Gray'
        Color '  [4] Tail MongoDB logs' 'Gray'
        Color "  Type 'back' to return." 'Yellow'
        $c = Read-Choice
        switch ($c.ToLower()) {
            '1' { Start-Mongo; Pause-Enter }
            '2' { Stop-Mongo; Pause-Enter }
            '3' { Restart-Mongo; Pause-Enter }
            '4' {
                if ($Config.mongodbLogPath -and (Test-Path $Config.mongodbLogPath)) { Tail-Log $Config.mongodbLogPath }
                else { Color '  MongoDB log path not configured. Set it in Config menu.' 'Yellow'; Pause-Enter }
            }
            'back' { return }
            'quit' { exit }
        }
    }
}

function Menu-Service {
    while ($true) {
        Header 'Windows Services (NSSM)'
        $nssm = Get-NSSM
        if ($nssm) { Color "  NSSM: $nssm" 'DarkGray' }
        else { Color '  NSSM: NOT FOUND' 'Red' }
        Write-Host ''
        foreach ($svcName in @($Config.service.appName, $SVC_NGINX, $SVC_CADDY)) {
            $st = Service-Status $svcName
            if ($st.exists) {
                $info = "$($st.status)"
                if ($st.running -and $st.startTime) { $info += "  PID=$($st.pid)  Uptime=$(Format-Uptime $st.startTime)" }
                Color "  $svcName : $info" $(if ($st.running) { 'Green' } else { 'Yellow' })
            } else {
                Color "  $svcName : not installed" 'DarkGray'
            }
        }
        Write-Host ''
        Color '  [1] Create/Recreate App Service' 'Gray'
        Color '  [2] Remove App Service' 'Gray'
        Color '  [3] Start App Service' 'Gray'
        Color '  [4] Stop App Service' 'Gray'
        Color '  [5] Restart App Service' 'Gray'
        Color '  [6] Install Nginx Service' 'Gray'
        Color '  [7] Install Caddy Service' 'Gray'
        Color "  Type 'back' to return." 'Yellow'
        $c = Read-Choice
        switch ($c.ToLower()) {
            '1' { Create-AppService; Pause-Enter }
            '2' { Remove-AppService; Pause-Enter }
            '3' {
                if (-not (Ensure-Admin-Guard 'starting service')) { Pause-Enter; continue }
                Start-Service -Name $Config.service.appName -ErrorAction SilentlyContinue
                Color '  Service started.' 'Green'; Pause-Enter
            }
            '4' {
                if (-not (Ensure-Admin-Guard 'stopping service')) { Pause-Enter; continue }
                Stop-Service -Name $Config.service.appName -ErrorAction SilentlyContinue
                Color '  Service stopped.' 'Green'; Pause-Enter
            }
            '5' {
                if (-not (Ensure-Admin-Guard 'restarting service')) { Pause-Enter; continue }
                Restart-Service -Name $Config.service.appName -ErrorAction SilentlyContinue
                Color '  Service restarted.' 'Green'; Pause-Enter
            }
            '6' { Install-NginxService; Pause-Enter }
            '7' { Install-CaddyService; Pause-Enter }
            'back' { return }
            'quit' { exit }
        }
    }
}

function Menu-PythonVenv {
    while ($true) {
        Header 'Python & Virtual Environment'
        Check-Python
        if (Test-Path $VENV_DIR) {
            StatusLine 'Venv:' "EXISTS ($VENV_DIR)" 'Green'
        } else {
            StatusLine 'Venv:' "NOT FOUND ($VENV_DIR)" 'Red'
        }
        Write-Host ''
        Color '  [1] Check Python details' 'Gray'
        Color '  [2] Create/Recreate Virtualenv' 'Gray'
        Color '  [3] Install requirements.txt' 'Gray'
        Color '  [4] List installed packages' 'Gray'
        Color "  Type 'back' to return." 'Yellow'
        $c = Read-Choice
        switch ($c.ToLower()) {
            '1' {
                Check-Python
                if (Test-Path $PIP_EXE) {
                    Color '' 'Gray'
                    $pipVer = & $PIP_EXE --version 2>&1
                    StatusLine 'Pip:' "$pipVer" 'Gray'
                    $waitressVer = & $PIP_EXE show waitress 2>&1 | Select-String 'Version:'
                    if ($waitressVer) { StatusLine 'Waitress:' "$waitressVer" 'Gray' }
                    else { StatusLine 'Waitress:' 'NOT INSTALLED' 'Yellow' }
                }
                Pause-Enter
            }
            '2' {
                if (Test-Path $VENV_DIR) {
                    if (Ask-YesNo '  Venv exists. Recreate? (deletes existing)' $true) {
                        Remove-Item $VENV_DIR -Recurse -Force
                    } else { continue }
                }
                Ensure-Venv | Out-Null
                Pause-Enter
            }
            '3' { Install-Requirements; Pause-Enter }
            '4' {
                if (Test-Path $PIP_EXE) { & $PIP_EXE list }
                else { Color '  Venv pip not found.' 'Red' }
                Pause-Enter
            }
            'back' { return }
            'quit' { exit }
        }
    }
}

function Menu-Logs {
    while ($true) {
        Header 'Logs'
        Color '  [1] Tail app stdout' 'Gray'
        Color '  [2] Tail app stderr' 'Gray'
        Color '  [3] Tail script.log' 'Gray'
        Color '  [4] Tail Nginx access.log' 'Gray'
        Color '  [5] Tail Nginx error.log' 'Gray'
        Color '  [6] Rotate app logs' 'Gray'
        Color '  [7] Show last 200 error lines' 'Gray'
        Color "  Type 'back' to return." 'Yellow'
        $c = Read-Choice
        switch ($c.ToLower()) {
            '1' { $kw = Read-Host '  Keyword filter (optional)'; Tail-Log (Join-Path $Config.logsDir 'app_stdout.log') $kw }
            '2' { $kw = Read-Host '  Keyword filter (optional)'; Tail-Log (Join-Path $Config.logsDir 'app_stderr.log') $kw }
            '3' { Tail-Log $scriptLog }
            '4' { Tail-Log (Join-Path $NGINX_DIR 'logs\access.log') }
            '5' { Tail-Log (Join-Path $NGINX_DIR 'logs\error.log') }
            '6' { Rotate-AppLogs; Color '  Done.' 'Green'; Pause-Enter }
            '7' { Show-RecentErrors 200; Pause-Enter }
            'back' { return }
            'quit' { exit }
        }
    }
}

function Menu-BackupRestore {
    while ($true) {
        Header 'Backup & Restore'
        $backups = Get-ChildItem -Path $backupsDir -Filter '*.zip' -ErrorAction SilentlyContinue
        $count = if ($backups) { $backups.Count } else { 0 }
        Color "  Backups directory: $backupsDir ($count backups)" 'DarkGray'
        Write-Host ''
        Color '  [1] Create App Backup (zip)' 'Gray'
        Color '  [2] Restore from Backup' 'Gray'
        Color "  Type 'back' to return." 'Yellow'
        $c = Read-Choice
        switch ($c.ToLower()) {
            '1' { New-AppBackup; Pause-Enter }
            '2' { Restore-AppBackup; Pause-Enter }
            'back' { return }
            'quit' { exit }
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN LOOP
# ═════════════════════════════════════════════════════════════════════════════

Clear-Host
Write-Host ''
Write-Host '  ╔══════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '  ║         ITRACKER SERVER CONTROL v2.0                    ║' -ForegroundColor Cyan
Write-Host '  ║         Windows Production Management Console           ║' -ForegroundColor Cyan
Write-Host '  ╚══════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''
Show-QuickStatus
Write-Host ''

while ($true) {
    Header 'MAIN MENU'

    Color '  STATUS & HEALTH' -ForegroundColor DarkCyan
    Color '  [s]  Quick Status (all services)' 'Gray'
    Color '  [d]  Detailed Status Report' 'Gray'
    Color '  [h]  Health Check' 'Gray'
    Write-Host ''

    Color '  BULK OPERATIONS' -ForegroundColor DarkCyan
    Color '  [sa] Start All' 'Gray'
    Color '  [xa] Stop All' 'Gray'
    Color '  [ra] Restart All' 'Gray'
    Write-Host ''

    Color '  SERVICE MANAGEMENT' -ForegroundColor DarkCyan
    Color '  [1]  Flask App (Waitress)' 'Gray'
    Color '  [2]  Nginx' 'Gray'
    Color '  [3]  Caddy' 'Gray'
    Color '  [4]  MongoDB' 'Gray'
    Color '  [5]  Windows Services (NSSM)' 'Gray'
    Write-Host ''

    Color '  TOOLS' -ForegroundColor DarkCyan
    Color '  [6]  Python & Virtualenv' 'Gray'
    Color '  [7]  Logs' 'Gray'
    Color '  [8]  Backup & Restore' 'Gray'
    Color '  [9]  System Info' 'Gray'
    Color '  [c]  Config (view/edit)' 'Gray'
    Write-Host ''
    Color "  Type option or 'quit' to exit." 'Yellow'

    $c = Read-Choice
    switch ($c.ToLower()) {
        # Status
        's'  { Write-Host ''; Show-QuickStatus; Pause-Enter }
        'd'  { Show-DetailedStatus }
        'h'  { Run-HealthCheck }
        # Bulk
        'sa' { Start-All; Pause-Enter }
        'xa' { Stop-All; Pause-Enter }
        'ra' { Restart-All; Pause-Enter }
        # Services
        '1'  { Menu-App }
        '2'  { Menu-Nginx }
        '3'  { Menu-Caddy }
        '4'  { Menu-Mongo }
        '5'  { Menu-Service }
        # Tools
        '6'  { Menu-PythonVenv }
        '7'  { Menu-Logs }
        '8'  { Menu-BackupRestore }
        '9'  { Show-SystemInfo }
        'c'  {
            while ($true) {
                Header 'Config'
                Color '  [1] View config' 'Gray'
                Color '  [2] Edit config' 'Gray'
                Color "  Type 'back' to return." 'Yellow'
                $ch = Read-Choice
                switch ($ch.ToLower()) {
                    '1'    { Show-Config }
                    '2'    { Edit-Config }
                    'back' { break }
                    'quit' { exit }
                }
                if ($ch.ToLower() -eq 'back') { break }
            }
        }
        'quit' { break }
        'q'    { break }
        'exit' { break }
    }
}

Color '  Goodbye.' 'Cyan'
