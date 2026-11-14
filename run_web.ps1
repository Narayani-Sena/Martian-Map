# Launch the Martian Map web planner in one step.
#   .\run_web.ps1              # build the web app if its sources changed, start the API if needed, open the browser
#   .\run_web.ps1 -Port 8010   # another port
#   .\run_web.ps1 -NoBrowser   # start (or find) the server only
#   .\run_web.ps1 -Rebuild     # always rebuild web/dist
# The API serves the built planner itself (web/dist), so no separate web server is needed.
# Needs: .venv with requirements.txt installed; Node.js only when the planner has to be (re)built.
param(
    [int]$Port = 8000,
    [switch]$NoBrowser,
    [switch]$Rebuild
)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$web = Join-Path $root "web"
$dist = Join-Path $web "dist\index.html"
$python = Join-Path $root ".venv\Scripts\python.exe"
$url = "http://localhost:$Port/"

function Test-Api {
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/health" -TimeoutSec 3
        return [bool]$r.ok
    } catch { return $false }
}

# 1. Build the planner when web/dist is missing or older than any source file.
$needBuild = $Rebuild -or -not (Test-Path $dist)
if (-not $needBuild) {
    $built = (Get-Item $dist).LastWriteTime
    $newer = Get-ChildItem -Path (Join-Path $web "src"), (Join-Path $web "index.html") -Recurse -File |
        Where-Object { $_.LastWriteTime -gt $built } | Select-Object -First 1
    $needBuild = [bool]$newer
}
if ($needBuild) {
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Error "The web planner needs building but npm was not found. Install Node.js 18+ (https://nodejs.org)."
    }
    Write-Host "Building the web planner (web/dist)..."
    Push-Location $web
    try {
        if (-not (Test-Path "node_modules")) { npm install --no-audit --no-fund }
        npx vite build
        if ($LASTEXITCODE -ne 0) { throw "vite build failed" }
    } finally { Pop-Location }
}

# 2. Start the API (it also serves the planner) unless one is already answering on this port.
if (Test-Api) {
    Write-Host "The API is already running on port $Port."
} else {
    if (-not (Test-Path $python)) {
        Write-Error "No Python environment at .venv. Run: python -m venv .venv; .venv\Scripts\pip install -r requirements.txt"
    }
    if ($needBuild) { Write-Host "Starting the API (restart it after editing server code: it runs without --reload)..." }
    $log = Join-Path $root "data\server.log"
    Start-Process -FilePath $python -ArgumentList "-m", "uvicorn", "server.main:app", "--host", "127.0.0.1", "--port", "$Port" `
        -WorkingDirectory $root -WindowStyle Minimized -RedirectStandardError $log
    $t0 = Get-Date
    while (-not (Test-Api)) {
        if (((Get-Date) - $t0).TotalSeconds -gt 90) { Write-Error "The API did not start within 90 s. See $log" }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "API up on port $Port (log: data\server.log)."
}

# 3. Open the planner.
if (-not $NoBrowser) { Start-Process $url }
Write-Host "Web planner: $url"
