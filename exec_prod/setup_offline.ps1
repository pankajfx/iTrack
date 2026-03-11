<#
 deploy_itracker.ps1
 - Detects embedded WinPython python.exe
 - Creates venv under G:\srv\app\itracker\venv (if not exists)
 - Upgrades pip/setuptools/wheel
 - Installs packages from wheelhouse (offline)
 - Optionally copies wheelhouse into the app for full portability
 - Creates a run.bat launcher
 - Runs simple verification (pip list, python --version)
#>
# === Config - edit if your paths differ ===
$WPYRoot    = "G:\srv\python\WPy64-31190b5"    # WinPython root you extracted
$wheelhouse = "G:\srv\python\wheelhouse1"      # your wheel directory
$app        = "G:\srv\app\itracker"            # app root (where venv will be created)
$copyWheelhouseIntoApp = $true                 # set to $false if you DON'T want copy
$logFile    = Join-Path $app "deploy_log.txt"
# entry script detection (will try these names)
$entryCandidates = @("run_my_app.py", "app.py", "main.py", "itracker.py")
# ensure app path exists
if (-not (Test-Path $app)) { Throw "App path $app not found" }
# --- helper log function
"==== Deploy run at $(Get-Date) ====" | Out-File $logFile -Encoding utf8 -Append
function Log { param($s) $s | Tee-Object -FilePath $logFile -Append; }
# 1) find python.exe inside WinPython folder if possible
$python = $null
if (Test-Path $WPYRoot) {
   $python = Get-ChildItem -Path $WPYRoot -Recurse -Filter python.exe -ErrorAction SilentlyContinue |
             Select-Object -First 1 -ExpandProperty FullName
   if ($python) { Log "Found python: $python" } else { Log "Warning: could not auto-find python.exe under $WPYRoot" }
} else {
   Log "WPYRoot $WPYRoot not found."
}
# If not found, try to detect any python.exe on PATH (fallback)
if (-not $python) {
   $which = (where.exe python) 2>$null
   if ($which) { $python = $which.Trim(); Log "Fallback python from PATH: $python" }
}
if (-not $python) { Throw "Python interpreter not found. Set \$WPYRoot correctly or provide path to python.exe." }
# 2) create venv
$venv = Join-Path $app "venv"
if (-not (Test-Path $venv)) {
   Log "Creating virtualenv at $venv"
& $python -m venv $venv 2>&1 | Out-File $logFile -Append
} else {
   Log "Venv already exists at $venv (skipping create)"
}
$venvPython = Join-Path $venv "Scripts\python.exe"
if (-not (Test-Path $venvPython)) { Throw "venv python not found at $venvPython" }
Log "Using venv python: $venvPython"
# 3) upgrade pip, setuptools, wheel
Log "Upgrading pip/setuptools/wheel..."
& $venvPython -m pip install --upgrade pip setuptools wheel 2>&1 | Out-File $logFile -Append
# 4) install from wheelhouse
if (-not (Test-Path $wheelhouse)) { Log "Wheelhouse not found at $wheelhouse"; Throw "Wheelhouse not found: $wheelhouse" }
if (Test-Path (Join-Path $app "requirements.txt")) {
   $req = Join-Path $app "requirements.txt"
   Log "Installing from requirements.txt using wheelhouse"
& $venvPython -m pip install --no-index --find-links $wheelhouse -r $req 2>&1 | Out-File $logFile -Append
} else {
   $wheels = Get-ChildItem -Path $wheelhouse -Filter *.whl -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
   if (-not $wheels) { Throw "No .whl files found in wheelhouse: $wheelhouse" }
   Log "Installing all .whl files found in $wheelhouse (count: $($wheels.Count))"
   # pip can accept multiple filenames; pass them joined
& $venvPython -m pip install --no-index --find-links $wheelhouse $wheels 2>&1 | Out-File $logFile -Append
}
# 5) optional: copy wheelhouse into app for full-portability
if ($copyWheelhouseIntoApp) {
   $dest = Join-Path $app "wheelhouse"
   Log "Copying wheelhouse to $dest for portability"
   if (-not (Test-Path $dest)) { New-Item -Path $dest -ItemType Directory -Force | Out-Null }
   Copy-Item -Path (Join-Path $wheelhouse "*") -Destination $dest -Recurse -Force
   Log "Copied wheelhouse."
}
# 6) Create a simple run.bat launcher (safe for services/schedulers)
$runBat = Join-Path $app "run.bat"
$entry = $null
foreach ($cand in $entryCandidates) { if (Test-Path (Join-Path $app $cand)) { $entry = Join-Path $app $cand; break } }
if (-not $entry) {
   Log "No entry script found by auto-detect. Creating run.bat template that calls venv python. Edit run.bat to point to your script."
   $batContent = @"@echo off
REM Edit the line below to reference your entry script (e.g. app.py)
"%~dp0venv\Scripts\python.exe" "%~dp0app.py" %*
"@
} else {
   Log "Detected entry script: $entry"
   $relEntry = Split-Path -Leaf $entry
   $batContent = "@echo off`r`n`"%~dp0venv\\Scripts\\python.exe`" `"%~dp0$relEntry`" %*"
}
$batContent | Out-File -FilePath $runBat -Encoding ascii -Force
Log "Created run.bat at $runBat"
# 7) verification: pip list and python version
Log "=== Verification ==="
& $venvPython --version 2>&1 | Out-File $logFile -Append
& $venvPython -m pip list --disable-pip-version-check 2>&1 | Out-File $logFile -Append
# 8) Attempt smoke-run of the entry script if found
if ($entry) {
   Log "Running small smoke test of entry script (30s timeout). Check logs for app-specific errors."
   # run entry script but limit duration: start process and wait 30 seconds then kill (avoid long-block)
   $psi = New-Object System.Diagnostics.ProcessStartInfo
   $psi.FileName = $venvPython
   $psi.Arguments = "`"$entry`""
   $psi.WorkingDirectory = $app
   $psi.RedirectStandardOutput = $true
   $psi.RedirectStandardError = $true
   $psi.UseShellExecute = $false
   $proc = [System.Diagnostics.Process]::Start($psi)
   Start-Sleep -Seconds 30
   if (-not $proc.HasExited) {
       try { $proc.Kill() } catch {}
       Log "Smoke-run timed out after 30s and was killed (expected if your app is long-running)."
   } else {
       Log "Smoke-run finished. Capturing output..."
   }
   $out = $proc.StandardOutput.ReadToEnd()
   $err = $proc.StandardError.ReadToEnd()
   $out | Out-File $logFile -Append
   $err | Out-File $logFile -Append
} else {
   Log "No entry script to smoke-run. Please edit run.bat to point to your app's entry script."
}
Log "Deploy script finished. See log at $logFile"
Write-Host "Deploy complete. See $logFile for details."