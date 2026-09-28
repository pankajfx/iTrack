<# =======================================================================
   ITracker Control Console (App + MongoDB + Reverse Proxy)
   - The app server is `python app.py` in gevent mode: one process serves HTTP
     and WebSocket (Socket.IO). Waitress is not used - it cannot carry WebSockets.
   - Production: install the app as a Windows service via NSSM (option S) -
     starts at boot, restarts on exit, rotating logs in LogDir.
   - Without a service, A/B/C run it detached (closing the console won't stop it).
   - Reverse proxy: prefers Caddy (auto/local HTTPS), or Nginx fallback
   Full deployment guide: PROJECT_GUIDE.md section 9.
   Author: You + Copilot
   ======================================================================= #>

# -------------------- CONFIG: edit to match your setup --------------------
$Cfg = [ordered]@{
  AppName           = 'ITracker'
  AppRoot           = 'G:\srv\app\itracker'               # contains app.py/package
  VenvPython        = 'G:\srv\app\itracker\venv\Scripts\python.exe'
  Port              = 5001
  # gevent is the production server. 'threading' is the development server and
  # refuses to run without a console, so it can never be a service.
  AsyncMode         = 'gevent'
  LogDir            = 'G:\srv\app\itracker\logs'          # service stdout/stderr, rotated at 10 MB
  PIDFile           = 'G:\srv\app\itracker\itracker_app.pid'

  # MongoDB Windows service name
  MongoService      = 'MongoDB'

  # mongosh location
  MongoshDir        = 'G:\srv\db\mongosh'

  # Reverse proxy preference (CADDY or NGINX). The script will still detect both if present.
  ReverseProxyPref  = 'CADDY'

  # Caddy locations
  CaddyExe          = 'C:\Tools\Caddy\caddy.exe'
  CaddyDir          = 'C:\Tools\Caddy'
  Caddyfile         = 'C:\Tools\Caddy\Caddyfile'
  CaddyServiceName  = 'Caddy'

  # Nginx locations
  NginxExe          = 'C:\nginx\nginx.exe'
  NginxDir          = 'C:\nginx'
  NginxConf         = 'C:\nginx\conf\nginx.conf'
  NginxServiceName  = 'nginx'
  NginxSslDir       = 'C:\nginx\conf\ssl'
  NginxCertPath     = 'C:\nginx\conf\ssl\itracker.crt'
  NginxKeyPath      = 'C:\nginx\conf\ssl\itracker.key'

  # Optional: NSSM to install Windows services (set to full path if you have it)
  NssmExe           = 'C:\Tools\NSSM\nssm.exe'
}

# -------------------- Utility helpers --------------------
function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Safer port->PID resolver that never touches $PID and prefers waitress/python
function Get-ListenerInfo {
  param([int]$Port)

  try {
    $tcp = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop
  } catch {
    $tcp = @()
  }

  if (-not $tcp) {
    return [pscustomobject]@{
      Listening   = $false
      PID         = $null
      ProcessName = $null
      CommandLine = $null
    }
  }

  $candidates = foreach ($t in $tcp) {
    $ownPid = $t.OwningProcess
    $p      = Get-Process -Id $ownPid -ErrorAction SilentlyContinue
    $cmd    = (Get-CimInstance Win32_Process -Filter "ProcessId=$ownPid" -ErrorAction SilentlyContinue).CommandLine

    $score = 0
    if ($p.Name -match 'waitress|python') { $score += 10 }
    if ($cmd -match 'waitress-serve')     { $score += 10 }
    if ($cmd -match [Regex]::Escape($Cfg.AppRoot)) { $score += 5 }

    [pscustomobject]@{
      Score       = $score
      PID         = $ownPid
      ProcessName = $p.Name
      CommandLine = $cmd
    }
  }

  $best = $candidates | Sort-Object Score -Descending | Select-Object -First 1
  if (-not $best) {
    return [pscustomobject]@{
      Listening   = $true
      PID         = $null
      ProcessName = $null
      CommandLine = $null
    }
  }

  [pscustomobject]@{
    Listening   = $true
    PID         = $best.PID
    ProcessName = $best.ProcessName
    CommandLine = $best.CommandLine
  }
}

function Detach-Run {
  param(
    [Parameter(Mandatory)] [string]$FilePath,
    [string[]]$ArgumentList,
    [string]$WorkingDirectory
  )
  Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru | Out-Null
}

# Pause helper for PS7 (no built-in Pause)
function Pause { Read-Host 'Press ENTER to continue...' }

# -------------------- App (python app.py on gevent) --------------------
function Get-AppService { Get-Service -Name $Cfg.AppName -ErrorAction SilentlyContinue }

# gevent + gevent-websocket are the production server; without them app.py cannot
# start in gevent mode. Checked before every start so the failure is explained.
function Test-AppDeps {
  if ($Cfg.AsyncMode -ne 'gevent') { return $true }
  & $Cfg.VenvPython -c "import gevent, geventwebsocket" 2>$null
  if ($LASTEXITCODE -eq 0) { return $true }
  Write-Warning "gevent / gevent-websocket are missing from $($Cfg.VenvPython). Install the app's requirements, e.g. offline:"
  Write-Warning "  & '$($Cfg.VenvPython)' -m pip install --no-index --find-links <wheels folder> -r '$(Join-Path $Cfg.AppRoot 'Requirements.txt')'"
  return $false
}

# An 'ITracker' service installed by older versions of this console ran waitress.
function Test-LegacyWaitressService {
  if (-not (Get-AppService) -or -not (Test-Path $Cfg.NssmExe)) { return $false }
  $appExe = ((& $Cfg.NssmExe get $Cfg.AppName Application 2>$null) -join '') -replace "`0", ''
  if ($appExe -match 'waitress') {
    Write-Warning "Service '$($Cfg.AppName)' runs waitress, which cannot carry WebSockets (live updates fail). Remove it (T), then install the app service (S)."
    return $true
  }
  return $false
}

function Wait-AppListening([int]$Seconds = 30) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  do {
    $info = Get-ListenerInfo -Port $Cfg.Port
    if ($info.Listening) { return $info }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)
  return $null
}

# /healthz: 200 when the app is up and MongoDB answers, 503 when the database does not.
function Get-AppHealth {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$($Cfg.Port)/healthz" -UseBasicParsing -TimeoutSec 5
    "$($r.StatusCode) $($r.Content)"
  } catch { "FAILED ($($_.Exception.Message))" }
}

function Get-FlaskStatus {
  $svc = Get-AppService
  $how = if ($svc) { "service $($svc.Status)" } else { 'no service' }
  $info = Get-ListenerInfo -Port $Cfg.Port
  if ($info.Listening) { "RUNNING (port $($Cfg.Port), PID $($info.PID), $($info.ProcessName)) [$how]" } else { "STOPPED [$how]" }
}

function Start-Flask {
  if (-not (Test-Path $Cfg.VenvPython)) {
    Write-Warning "Python not found at $($Cfg.VenvPython)."
    return
  }
  # Installed as a service: the service manager owns the process (killing or
  # double-starting it here would fight NSSM's restart policy).
  $svc = Get-AppService
  if ($svc) {
    Test-LegacyWaitressService | Out-Null
    if ($svc.Status -ne 'Running') { Start-Service -Name $Cfg.AppName }
    $post = Wait-AppListening
    if ($post) { Write-Host "Service '$($Cfg.AppName)' is serving on port $($Cfg.Port) (PID $($post.PID)). Health: $(Get-AppHealth)" }
    else { Write-Error "Service '$($Cfg.AppName)' did not open port $($Cfg.Port). See $(Join-Path $Cfg.LogDir 'itracker.err.log')." }
    return
  }
  $info = Get-ListenerInfo -Port $Cfg.Port
  if ($info.Listening) { Write-Host "App already listening on $($Cfg.Port) (PID $($info.PID))." -ForegroundColor Yellow; return }
  if (-not (Test-AppDeps)) { return }

  Push-Location $Cfg.AppRoot
  try {
    # python app.py is the server: in gevent mode socketio.run() serves HTTP and
    # WebSocket on one event loop. Process environment beats .env for these keys.
    $env:PORT = $Cfg.Port
    $env:SOCKETIO_ASYNC_MODE = $Cfg.AsyncMode
    Detach-Run -FilePath $Cfg.VenvPython -ArgumentList @('app.py') -WorkingDirectory $Cfg.AppRoot
    $post = Wait-AppListening
    if ($post) {
      $post.PID | Out-File -FilePath $Cfg.PIDFile -Encoding ascii -Force
      Write-Host "Started the app ($($Cfg.AsyncMode)) on port $($Cfg.Port) (PID $($post.PID)). Health: $(Get-AppHealth)"
    } else {
      Write-Error "App failed to bind to :$($Cfg.Port). Run it in the foreground to see why:  cd '$($Cfg.AppRoot)'; & '$($Cfg.VenvPython)' app.py"
    }
  } finally { Pop-Location }
}

function Stop-Flask {
  $killed = $false

  # 0) A service is stopped through the service manager - killing its process
  #    would only make NSSM start it again.
  $svc = Get-AppService
  if ($svc -and $svc.Status -ne 'Stopped') {
    Stop-Service -Name $Cfg.AppName -ErrorAction SilentlyContinue
    Write-Host "Stopped service '$($Cfg.AppName)'."
    $killed = $true
  }

  # 1) Try PID file first
  if (Test-Path $Cfg.PIDFile) {
    try {
      $filePid = [int]((Get-Content $Cfg.PIDFile -ErrorAction Stop | Select-Object -First 1).Trim())
      if ($filePid -ne $PID) {
        $proc = Get-Process -Id $filePid -ErrorAction SilentlyContinue
        if ($proc) {
          Stop-Process -Id $filePid -Force -ErrorAction SilentlyContinue
          Write-Host "Stopped PID $filePid ($($proc.ProcessName)) from PID file."
          $killed = $true
        }
      }
    } catch {}
    Remove-Item $Cfg.PIDFile -Force -ErrorAction SilentlyContinue
  }

  # 2) Always sweep port after - handles stale PID file and dual IPv4/IPv6 listeners
  if ($killed) { Start-Sleep 1 }
  $listeners = Get-NetTCPConnection -LocalPort $Cfg.Port -State Listen -ErrorAction SilentlyContinue
  if ($listeners) {
    $portPids = @($listeners | Select-Object -ExpandProperty OwningProcess | Sort-Object -Unique)
    foreach ($pp in $portPids) {
      if ($pp -eq $PID) { Write-Warning "Refusing to kill current shell (PID $PID)."; continue }
      $proc = Get-Process -Id $pp -ErrorAction SilentlyContinue
      if ($proc) {
        try {
          Stop-Process -Id $pp -Force -ErrorAction Stop
          Write-Host "Killed PID $pp ($($proc.ProcessName)) on port $($Cfg.Port)."
          $killed = $true
        } catch {
          Write-Warning "Could not kill PID $pp ($($proc.ProcessName)): $($_.Exception.Message)"
          Write-Warning "Try running this script as Administrator."
        }
      }
    }
  }

  if (-not $killed) { Write-Host "Nothing to stop on port $($Cfg.Port)."; return }

  Start-Sleep 3
  if (Get-NetTCPConnection -LocalPort $Cfg.Port -State Listen -ErrorAction SilentlyContinue) {
    Write-Warning "Port $($Cfg.Port) still in use. If above showed a permission error, re-run as Administrator."
  } else {
    Write-Host "Port $($Cfg.Port) is free." -ForegroundColor Green
  }
}

function Restart-Flask { Stop-Flask; Start-Sleep 2; Start-Flask }

# Production: the app as a Windows service (via NSSM). Starts at boot - after
# MongoDB when that is a local service - restarts 5 s after any exit, and writes
# stdout/stderr to LogDir, rotated at 10 MB. Everything else comes from
# AppRoot\.env; the service pins SOCKETIO_ASYNC_MODE and PORT from $Cfg.
function Install-AppService {
  if (-not (Test-Path $Cfg.NssmExe)) { Write-Warning "NSSM not found at $($Cfg.NssmExe)"; return }
  if (-not (Test-Path $Cfg.VenvPython)) { Write-Warning "Python not found at $($Cfg.VenvPython)."; return }
  if ($Cfg.AsyncMode -ne 'gevent') {
    Write-Warning "AsyncMode must be 'gevent' for a service: the threading development server refuses to run without a console."
    return
  }
  if (-not (Test-AppDeps)) { return }
  if (Get-AppService) {
    Test-LegacyWaitressService | Out-Null
    Write-Warning "Service '$($Cfg.AppName)' already exists. Remove it first (T) to reinstall."
    return
  }
  $info = Get-ListenerInfo -Port $Cfg.Port
  if ($info.Listening) { Write-Warning "Port $($Cfg.Port) is in use (PID $($info.PID)). Stop the running app first (B)."; return }

  New-Item -ItemType Directory -Path $Cfg.LogDir -Force | Out-Null
  $n = $Cfg.NssmExe; $s = $Cfg.AppName
  & $n install $s $Cfg.VenvPython app.py
  & $n set $s AppDirectory $Cfg.AppRoot
  & $n set $s AppEnvironmentExtra "SOCKETIO_ASYNC_MODE=$($Cfg.AsyncMode)" "PORT=$($Cfg.Port)" 'PYTHONUNBUFFERED=1' 'PYTHONIOENCODING=utf-8'
  & $n set $s AppStdout (Join-Path $Cfg.LogDir 'itracker.out.log')
  & $n set $s AppStderr (Join-Path $Cfg.LogDir 'itracker.err.log')
  & $n set $s AppRotateFiles 1
  & $n set $s AppRotateOnline 1
  & $n set $s AppRotateBytes 10485760
  & $n set $s AppExit Default Restart
  & $n set $s AppRestartDelay 5000
  & $n set $s Start SERVICE_AUTO_START
  if (Get-Service -Name $Cfg.MongoService -ErrorAction SilentlyContinue) {
    & $n set $s DependOnService $Cfg.MongoService
  }
  & $n start $s
  $post = Wait-AppListening
  if ($post) { Write-Host "Installed/started service '$s' ($($Cfg.AsyncMode)) on port $($Cfg.Port). Health: $(Get-AppHealth)" }
  else { Write-Warning "Service '$s' installed but port $($Cfg.Port) is not open yet. See $(Join-Path $Cfg.LogDir 'itracker.err.log')." }
}

function Uninstall-AppService {
  if (-not (Test-Path $Cfg.NssmExe)) { Write-Warning "NSSM not found at $($Cfg.NssmExe)"; return }
  & $Cfg.NssmExe stop  $Cfg.AppName
  & $Cfg.NssmExe remove $Cfg.AppName confirm
  Write-Host "Removed Windows service '$($Cfg.AppName)'."
}

# -------------------- MongoDB --------------------
function Get-MongoStatus {
  try { (Get-Service -Name $Cfg.MongoService -ErrorAction Stop).Status } catch { "NotFound" }
}
function Start-Mongo { Start-Service -Name $Cfg.MongoService -ErrorAction SilentlyContinue; Get-MongoStatus }
function Stop-Mongo  { Stop-Service  -Name $Cfg.MongoService -ErrorAction SilentlyContinue; Get-MongoStatus }
function Restart-Mongo { Restart-Service -Name $Cfg.MongoService -ErrorAction SilentlyContinue; Get-MongoStatus }

function Launch-Mongosh {
  $exe = Join-Path $Cfg.MongoshDir 'mongosh.exe'
  if (-not (Test-Path $exe)) { Write-Warning "mongosh.exe not found in $($Cfg.MongoshDir)."; return }
  Start-Process -FilePath $exe -WorkingDirectory $Cfg.MongoshDir
}

# -------------------- Caddy (reverse proxy) --------------------
function Test-CaddyPresent { Test-Path $Cfg.CaddyExe }
function Get-CaddyStatus {
  $pids = (Get-Process -Name caddy -ErrorAction SilentlyContinue).Id
  if ($pids) { "RUNNING (PID(s): $($pids -join ', '))" } else { "STOPPED" }
}
function New-Caddyfile {
  $lines = @(
    '# Caddyfile generated by ITracker console'
    '# Local HTTPS today (internal CA). Later, replace ''localhost'' with your real domain.'
    '# Caddy passes the Socket.IO WebSocket upgrade through and sends'
    '# X-Forwarded-For/-Proto itself: set TRUST_PROXY_HOPS=1 in the app''s .env.'
    'localhost {'
    '    tls internal'
    '    encode gzip'
    "    reverse_proxy 127.0.0.1:$($Cfg.Port)"
    '}'
    '# More than one app instance (each needs SOCKETIO_MESSAGE_QUEUE): a Socket.IO'
    '# session lives in one process, so every client must stay on one instance:'
    "#     reverse_proxy 127.0.0.1:$($Cfg.Port) 127.0.0.1:$($Cfg.Port + 1) {"
    '#         lb_policy cookie'
    '#         health_uri /healthz'
    '#     }'
    '# Example for future public domain (uncomment/replace when DNS is ready)'
    '# itracker.example.com {'
    "#     reverse_proxy 127.0.0.1:$($Cfg.Port)"
    '# }'
  )
  $lines | Set-Content -Path $Cfg.Caddyfile -Encoding ascii
  Write-Host "Wrote Caddyfile at $($Cfg.Caddyfile)."
}
function Start-Caddy {
  if (-not (Test-CaddyPresent)) { Write-Warning "caddy.exe not found at $($Cfg.CaddyExe)"; return }
  if (-not (Test-Path $Cfg.Caddyfile)) { New-Caddyfile }
  Detach-Run -FilePath $Cfg.CaddyExe -ArgumentList @("run","--config",$Cfg.Caddyfile) -WorkingDirectory $Cfg.CaddyDir
  Start-Sleep 2
  Write-Host "Started Caddy; status: $(Get-CaddyStatus)."
}
function Stop-Caddy {
  $procs = Get-Process -Name caddy -ErrorAction SilentlyContinue
  if ($procs) { $procs | Stop-Process -Force -ErrorAction SilentlyContinue; Write-Host "Stopped Caddy." } else { Write-Host "Caddy not running." }
}
function Restart-Caddy { Stop-Caddy; Start-Sleep 1; Start-Caddy }
function Caddy-TrustRootCA {
  if (-not (Test-CaddyPresent)) { Write-Warning "caddy.exe not found."; return }
  & $Cfg.CaddyExe trust
  Write-Host "Attempted to install Caddy's local root CA into Windows trust (may prompt)."
}

# Optional Windows Service for Caddy via NSSM
function Install-CaddyService {
  if (-not (Test-Path $Cfg.NssmExe)) { Write-Warning "NSSM not found."; return }
  if (-not (Test-Path $Cfg.Caddyfile)) { New-Caddyfile }
  & $Cfg.NssmExe install $Cfg.CaddyServiceName $Cfg.CaddyExe run --config "$($Cfg.Caddyfile)"
  & $Cfg.NssmExe set $Cfg.CaddyServiceName AppDirectory $Cfg.CaddyDir
  & $Cfg.NssmExe set $Cfg.CaddyServiceName Start SERVICE_AUTO_START
  & $Cfg.NssmExe start $Cfg.CaddyServiceName
  Write-Host "Installed/started Caddy as Windows service '$($Cfg.CaddyServiceName)'."
}
function Uninstall-CaddyService {
  if (-not (Test-Path $Cfg.NssmExe)) { Write-Warning "NSSM not found."; return }
  & $Cfg.NssmExe stop  $Cfg.CaddyServiceName
  & $Cfg.NssmExe remove $Cfg.CaddyServiceName confirm
  Write-Host "Removed Caddy Windows service."
}

# -------------------- Nginx (reverse proxy) --------------------
function Test-NginxPresent { Test-Path $Cfg.NginxExe }
function Get-NginxStatus {
  $p = Get-Process -Name nginx -ErrorAction SilentlyContinue
  if ($p) { "RUNNING (master+worker, PIDs: $((($p | Select-Object -ExpandProperty Id) -join ', ')))" } else { "STOPPED" }
}

# Create a minimal HTTPS reverse proxy config
function New-NginxConfig {
  if (-not (Test-Path $Cfg.NginxSslDir)) {
    New-Item -ItemType Directory -Path $Cfg.NginxSslDir -Force | Out-Null
  }

  # If no cert exists, generate a local PEM pair in PowerShell (no OpenSSL required)
  if (-not (Test-Path $Cfg.NginxCertPath) -or -not (Test-Path $Cfg.NginxKeyPath)) {
    Write-Host "Generating a local self-signed PEM certificate for Nginx..."
    $cert = New-SelfSignedCertificate -DnsName "localhost" -CertStoreLocation "Cert:\LocalMachine\My" -NotAfter (Get-Date).AddYears(1)
    $cerBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    [System.IO.File]::WriteAllBytes($Cfg.NginxCertPath, $cerBytes)
    $rsa = $cert.GetRSAPrivateKey()
    $pkcs8 = $rsa.ExportPkcs8PrivateKey()
    $b64 = [System.Convert]::ToBase64String($pkcs8) -split ".{1,64}" -ne ""
    @("-----BEGIN PRIVATE KEY-----") + $b64 + @("-----END PRIVATE KEY-----") |
      Set-Content -Path $Cfg.NginxKeyPath -Encoding ascii -NoNewline
  }

  $lines = @(
    '# nginx.conf generated by ITracker console'
    '# nginx on Windows runs one worker with at most 1024 connections, and every live'
    '# socket holds two (browser side + app side): about 500 concurrent users.'
    '# Caddy has no such limit - prefer it on Windows. Set TRUST_PROXY_HOPS=1 in .env.'
    'worker_processes  1;'
    ''
    'events { worker_connections  1024; }'
    ''
    'http {'
    '    include       mime.types;'
    '    default_type  application/octet-stream;'
    '    sendfile      on;'
    ''
    '    # Socket.IO upgrades its connection to WebSocket: pass the handshake through.'
    '    map $http_upgrade $connection_upgrade {'
    '        default upgrade;'
    "        ''      close;"
    '    }'
    ''
    '    upstream itracker_app {'
    "        server 127.0.0.1:$($Cfg.Port);"
    '        # More app instances (each needs SOCKETIO_MESSAGE_QUEUE): add them here and'
    '        # enable ip_hash - a Socket.IO session lives in one process.'
    '        # ip_hash;'
    "        # server 127.0.0.1:$($Cfg.Port + 1);"
    '    }'
    ''
    '    server {'
    '        listen              443 ssl;'
    '        server_name         localhost;'
    ''
    "        ssl_certificate     $($Cfg.NginxCertPath -replace '\\','/');"
    "        ssl_certificate_key $($Cfg.NginxKeyPath -replace '\\','/');"
    ''
    '        client_max_body_size 20m;             # the app caps uploads at 16 MB'
    ''
    '        location / {'
    '            proxy_pass         http://itracker_app;'
    '            proxy_http_version 1.1;'
    '            proxy_set_header   Host $host;'
    '            proxy_set_header   X-Real-IP $remote_addr;'
    '            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;'
    '            proxy_set_header   X-Forwarded-Proto https;'
    '        }'
    ''
    '        location /socket.io/ {'
    '            proxy_pass         http://itracker_app;'
    '            proxy_http_version 1.1;'
    '            proxy_buffering    off;'
    '            proxy_set_header   Host $host;'
    '            proxy_set_header   X-Real-IP $remote_addr;'
    '            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;'
    '            proxy_set_header   X-Forwarded-Proto https;'
    '            proxy_set_header   Upgrade $http_upgrade;'
    '            proxy_set_header   Connection $connection_upgrade;'
    '            # Well above the Socket.IO heartbeat (a ping every 25 s), so nginx'
    '            # never cuts a healthy idle socket.'
    '            proxy_read_timeout 120s;'
    '            proxy_send_timeout 120s;'
    '        }'
    '    }'
    ''
    '    # Optional: redirect HTTP->HTTPS (uncomment if desired)'
    '    # server {'
    '    #   listen 80;'
    '    #   return 301 https://$host$request_uri;'
    '    # }'
    '}'
  )
  $lines | Set-Content -Path $Cfg.NginxConf -Encoding ascii
  Write-Host "Wrote Nginx config at $($Cfg.NginxConf)."
}

function Start-Nginx {
  if (-not (Test-NginxPresent)) { Write-Warning "nginx.exe not found at $($Cfg.NginxExe)"; return }
  if (-not (Test-Path $Cfg.NginxConf)) { New-NginxConfig }
  Detach-Run -FilePath $Cfg.NginxExe -ArgumentList @() -WorkingDirectory $Cfg.NginxDir
  Start-Sleep 2
  Write-Host "Started Nginx; status: $(Get-NginxStatus)."
}
function Stop-Nginx {
  if (-not (Test-NginxPresent)) { Write-Warning "nginx.exe not found"; return }
  & $Cfg.NginxExe -s quit 2>$null
  Start-Sleep 1
  Write-Host "Stopped Nginx; status: $(Get-NginxStatus)."
}
function Reload-Nginx {
  if (-not (Test-NginxPresent)) { Write-Warning "nginx.exe not found"; return }
  & $Cfg.NginxExe -t
  if ($LASTEXITCODE -eq 0) { & $Cfg.NginxExe -s reload; Write-Host "Reloaded Nginx config." }
  else { Write-Warning "nginx -t reported errors; not reloading." }
}

# Optional Windows Service for Nginx via NSSM
function Install-NginxService {
  if (-not (Test-Path $Cfg.NssmExe)) { Write-Warning "NSSM not found."; return }
  if (-not (Test-Path $Cfg.NginxConf)) { New-NginxConfig }
  & $Cfg.NssmExe install $Cfg.NginxServiceName $Cfg.NginxExe
  & $Cfg.NssmExe set $Cfg.NginxServiceName AppDirectory $Cfg.NginxDir
  & $Cfg.NssmExe set $Cfg.NginxServiceName Start SERVICE_AUTO_START
  & $Cfg.NssmExe start $Cfg.NginxServiceName
  Write-Host "Installed/started Nginx as Windows service '$($Cfg.NginxServiceName)'."
}
function Uninstall-NginxService {
  if (-not (Test-Path $Cfg.NssmExe)) { Write-Warning "NSSM not found."; return }
  & $Cfg.NssmExe stop  $Cfg.NginxServiceName
  & $Cfg.NssmExe remove $Cfg.NginxServiceName confirm
  Write-Host "Removed Nginx Windows service."
}

# -------------------- UI LOOP --------------------
$admin = Test-Admin
if (-not $admin) { Write-Warning "Tip: Run PowerShell as Administrator for service control and local root trust." }

$running = $true
while ($running) {
  Clear-Host
  $flask = Get-FlaskStatus
  $mongo = Get-MongoStatus
  $caddy = if (Test-CaddyPresent) { Get-CaddyStatus } else { "Not Installed/Not Found" }
  $nginx = if (Test-NginxPresent) { Get-NginxStatus } else { "Not Installed/Not Found" }

  Write-Host "================ ITracker Control Console ==================="
  Write-Host (" App (port {0}): {1}" -f $Cfg.Port, $flask)
  Write-Host (" MongoDB Service '{0}': {1}" -f $Cfg.MongoService, $mongo)
  Write-Host (" Caddy:  {0}" -f $caddy)
  Write-Host (" Nginx:  {0}" -f $nginx)
  Write-Host "=============================================================`n"

  Write-Host " A) Start App      B) Stop App      C) Restart App"
  Write-Host " D) Start Mongo    E) Stop Mongo    F) Restart Mongo"
  Write-Host " G) Launch mongosh"
  Write-Host " --- Reverse Proxy (Caddy preferred) ---"
  Write-Host " H) Setup/Start Caddy      I) Stop Caddy      J) Restart Caddy      K) Trust Caddy local root"
  Write-Host " L) Install Caddy Service  M) Remove Caddy Service"
  Write-Host " --- OR Nginx ---"
  Write-Host " N) Setup/Start Nginx      O) Stop Nginx      P) Reload Nginx"
  Write-Host " Q) Install Nginx Service  R) Remove Nginx Service"
  Write-Host " --- App as a Windows service (production) ---"
  Write-Host " S) Install App Service (gevent)  T) Remove App Service"
  Write-Host " 0) Exit`n"
  $choice = (Read-Host "Choose").Trim().ToUpperInvariant()

  switch ($choice) {
    'A' { Start-Flask; Pause }
    'B' { Stop-Flask; Pause }
    'C' { Restart-Flask; Pause }
    'D' { Start-Mongo | Out-Host; Pause }
    'E' { Stop-Mongo  | Out-Host; Pause }
    'F' { Restart-Mongo | Out-Host; Pause }
    'G' { Launch-Mongosh }
    'H' { if (-not (Test-Path $Cfg.Caddyfile)) { New-Caddyfile }; Start-Caddy; Pause }
    'I' { Stop-Caddy; Pause }
    'J' { Restart-Caddy; Pause }
    'K' { Caddy-TrustRootCA; Pause }
    'L' { Install-CaddyService; Pause }
    'M' { Uninstall-CaddyService; Pause }
    'N' { if (-not (Test-Path $Cfg.NginxConf)) { New-NginxConfig }; Start-Nginx; Pause }
    'O' { Stop-Nginx; Pause }
    'P' { Reload-Nginx; Pause }
    'Q' { Install-NginxService; Pause }
    'R' { Uninstall-NginxService; Pause }
    'S' { Install-AppService; Pause }
    'T' { Uninstall-AppService; Pause }
    '0' { $running = $false; continue }
    default { }
  }
}