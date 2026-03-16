<# =======================================================================
   ITracker Control Console (Waitress + MongoDB + Reverse Proxy)
   - Runs waitress detached so closing the console won't stop the server
   - Optional: install/uninstall Windows services via NSSM if available
   - Reverse proxy: prefers Caddy (auto/local HTTPS), or Nginx fallback
   Author: You + Copilot
   ======================================================================= #>

# -------------------- CONFIG: edit to match your setup --------------------
$Cfg = [ordered]@{
  AppName           = 'ITracker'
  AppRoot           = 'G:\srv\app\itracker'               # contains app.py/package
  VenvPython        = 'G:\srv\app\itracker\venv\Scripts\python.exe'
  WsgiObject        = 'app:app'                           # e.g., 'app:app' or use --call factory
  Port              = 5001
  Threads           = 8
  UrlScheme         = 'https'                             # app thinks HTTPS behind proxy
  PIDFile           = 'G:\srv\app\itracker\itracker_waitress.pid'

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

$Cfg.WaitressExe = Join-Path (Split-Path $Cfg.VenvPython -Parent) 'waitress-serve.exe'

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

# -------------------- Waitress (Flask) --------------------
function Get-FlaskStatus {
  $info = Get-ListenerInfo -Port $Cfg.Port
  if ($info.Listening) { "RUNNING (port $($Cfg.Port), PID $($info.PID), $($info.ProcessName))" } else { "STOPPED" }
}

function Start-Flask {
  if (-not (Test-Path $Cfg.WaitressExe)) {
    Write-Warning "waitress-serve.exe not found at $($Cfg.WaitressExe). Install in your venv: `"$($Cfg.VenvPython)`" -m pip install waitress"
    return
  }
  $info = Get-ListenerInfo -Port $Cfg.Port
  if ($info.Listening) { Write-Host "Waitress already listening on $($Cfg.Port) (PID $($info.PID))." -ForegroundColor Yellow; return }

  Push-Location $Cfg.AppRoot
  try {
    $args = @("--listen=*:$($Cfg.Port)","--threads=$($Cfg.Threads)","--ident=$($Cfg.AppName)","--url-scheme=$($Cfg.UrlScheme)", $Cfg.WsgiObject)
    Detach-Run -FilePath $Cfg.WaitressExe -ArgumentList $args -WorkingDirectory $Cfg.AppRoot
    Start-Sleep 2
    $post = Get-ListenerInfo -Port $Cfg.Port
    if ($post.Listening) {
      $post.PID | Out-File -FilePath $Cfg.PIDFile -Encoding ascii -Force
      Write-Host "Started waitress on port $($Cfg.Port) (PID $($post.PID))."
    } else {
      Write-Error "Waitress failed to bind to :$($Cfg.Port). Check module/object '$($Cfg.WsgiObject)' and any prior listeners."
    }
  } finally { Pop-Location }
}

function Stop-Flask {
  # 1) Prefer PID file (most reliable)
  $pidFromFile = $null
  if (Test-Path $Cfg.PIDFile) {
    try { $pidFromFile = Get-Content $Cfg.PIDFile -ErrorAction Stop | Select-Object -First 1 } catch {}
  }

  if ($pidFromFile) {
    $proc = Get-Process -Id $pidFromFile -ErrorAction SilentlyContinue
    if ($proc) {
      if ($pidFromFile -eq $PID) {
        Write-Warning "Refusing to kill current shell (PID $PID). PID file may be stale — falling back to port lookup."
      } else {
        Stop-Process -Id $pidFromFile -Force -ErrorAction SilentlyContinue
        Remove-Item $Cfg.PIDFile -Force -ErrorAction SilentlyContinue
        Write-Host "Stopped waitress (PID $pidFromFile)."
        return
      }
    } else {
      # Stale PID file — remove it and continue
      Remove-Item $Cfg.PIDFile -Force -ErrorAction SilentlyContinue
    }
  }

  # 2) Fall back to port-based lookup
  $info = Get-ListenerInfo -Port $Cfg.Port
  if (-not $info.Listening -or -not $info.PID) {
    Write-Host "Nothing listening on port $($Cfg.Port)."
    return
  }

  if ($info.PID -eq $PID) {
    Write-Warning "Detected current PowerShell process (PID $PID) as the :$($Cfg.Port) listener; refusing to stop it."
    Write-Warning "This usually means the earlier PID detection was wrong or the listener changed. Try Restart-Flask."
    return
  }

  try {
    Stop-Process -Id $info.PID -Force -ErrorAction Stop
    Write-Host "Stopped process on port $($Cfg.Port) (PID $($info.PID), $($info.ProcessName))."
  } catch {
    Write-Warning "Failed to stop PID $($info.PID): $($_.Exception.Message)"
  }
}

function Restart-Flask { Stop-Flask; Start-Sleep 1; Start-Flask }

# Optional: install waitress as a Windows service (via NSSM)
function Install-WaitressService {
  if (-not (Test-Path $Cfg.NssmExe)) { Write-Warning "NSSM not found at $($Cfg.NssmExe)"; return }
  $args = @("install",$Cfg.AppName,$Cfg.WaitressExe,"--listen=*:$($Cfg.Port)","--threads=$($Cfg.Threads)","--ident=$($Cfg.AppName)","--url-scheme=$($Cfg.UrlScheme)",$Cfg.WsgiObject)
  & $Cfg.NssmExe @args
  & $Cfg.NssmExe set $Cfg.AppName AppDirectory $Cfg.AppRoot
  & $Cfg.NssmExe set $Cfg.AppName Start SERVICE_AUTO_START
  & $Cfg.NssmExe start $Cfg.AppName
  Write-Host "Installed/started Windows service '$($Cfg.AppName)' for waitress."
}

function Uninstall-WaitressService {
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
    'localhost {'
    '    tls internal'
    '    encode gzip'
    "    reverse_proxy 127.0.0.1:$($Cfg.Port)"
    '}'
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
    'worker_processes  1;'
    ''
    'events { worker_connections  1024; }'
    ''
    'http {'
    '    include       mime.types;'
    '    default_type  application/octet-stream;'
    '    sendfile      on;'
    ''
    '    server {'
    '        listen              443 ssl;'
    '        server_name         localhost;'
    ''
    "        ssl_certificate     $($Cfg.NginxCertPath -replace '\\','/');"
    "        ssl_certificate_key $($Cfg.NginxKeyPath -replace '\\','/');"
    ''
    '        location / {'
    "            proxy_pass         http://127.0.0.1:$($Cfg.Port);"
    '            proxy_set_header   Host $host;'
    '            proxy_set_header   X-Real-IP $remote_addr;'
    '            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;'
    '            proxy_set_header   X-Forwarded-Proto https;'
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
  Write-Host (" Flask/Waitress (port {0}): {1}" -f $Cfg.Port, $flask)
  Write-Host (" MongoDB Service '{0}': {1}" -f $Cfg.MongoService, $mongo)
  Write-Host (" Caddy:  {0}" -f $caddy)
  Write-Host (" Nginx:  {0}" -f $nginx)
  Write-Host "=============================================================`n"

  Write-Host " A) Start Flask    B) Stop Flask    C) Restart Flask"
  Write-Host " D) Start Mongo    E) Stop Mongo    F) Restart Mongo"
  Write-Host " G) Launch mongosh"
  Write-Host " --- Reverse Proxy (Caddy preferred) ---"
  Write-Host " H) Setup/Start Caddy      I) Stop Caddy      J) Restart Caddy      K) Trust Caddy local root"
  Write-Host " L) Install Caddy Service  M) Remove Caddy Service"
  Write-Host " --- OR Nginx ---"
  Write-Host " N) Setup/Start Nginx      O) Stop Nginx      P) Reload Nginx"
  Write-Host " Q) Install Nginx Service  R) Remove Nginx Service"
  Write-Host " S) Install Waitress Service  T) Remove Waitress Service"
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
    'S' { Install-WaitressService; Pause }
    'T' { Uninstall-WaitressService; Pause }
    '0' { $running = $false; continue }
    default { }
  }
}