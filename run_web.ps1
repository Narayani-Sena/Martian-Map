# Launch the Martian Map web planner in one step.
#   .\run_web.ps1              # build the web app if its sources changed, start the API if needed, open the browser
#   .\run_web.ps1 -Port 8010   # another port
#   .\run_web.ps1 -NoBrowser   # start (or find) the server only
#   .\run_web.ps1 -Rebuild     # always rebuild web/dist
#   .\run_web.ps1 -Lan         # serve over HTTPS to phones and tablets on the same Wi-Fi (port 8443). Phones only
#                              # share GPS ("Walk it on Earth") with a secure page, so this makes a self-signed
#                              # certificate for this computer's address once (kept in data\https, not in git).
# The API serves the built planner itself (web/dist), so no separate web server is needed.
# Needs: .venv with requirements.txt installed; Node.js only when the planner has to be (re)built;
# for -Lan, openssl (Git for Windows includes one).
param(
    [int]$Port = 0,
    [switch]$NoBrowser,
    [switch]$Rebuild,
    [switch]$Lan
)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$web = Join-Path $root "web"
$dist = Join-Path $web "dist\index.html"
$python = Join-Path $root ".venv\Scripts\python.exe"
if ($Port -eq 0) { $Port = if ($Lan) { 8443 } else { 8000 } }
$scheme = if ($Lan) { "https" } else { "http" }
$url = "${scheme}://localhost:$Port/"

function Test-Api {
    $ErrorActionPreference = "Continue"
    # curl.exe ships with Windows 10 and later; -k accepts the -Lan server's self-signed certificate.
    $out = & curl.exe -s -k --max-time 3 "${scheme}://127.0.0.1:$Port/api/health"
    return ($LASTEXITCODE -eq 0 -and "$out" -match '"ok"\s*:\s*true')
}

function Get-LanAddress {
    # The adapter that has a default gateway is the one the phone shares (skips VirtualBox / Hyper-V adapters).
    $cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" } |
        Select-Object -First 1
    if ($cfg) { return @($cfg.IPv4Address)[0].IPAddress }
    return $null
}

function New-LanCertificate([string]$dir, [string]$ip) {
    $openssl = (Get-Command openssl -ErrorAction SilentlyContinue).Source
    if (-not $openssl) {
        foreach ($p in "$env:ProgramFiles\Git\usr\bin\openssl.exe", "$env:ProgramFiles\Git\mingw64\bin\openssl.exe") {
            if (Test-Path $p) { $openssl = $p; break }
        }
    }
    if (-not $openssl) { Write-Error "-Lan needs openssl to make a certificate: install Git for Windows (it includes openssl)." }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $cnf = Join-Path $dir "cert.cnf"
    @"
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Martian Map on this computer
[ext]
subjectAltName = IP:$ip, IP:127.0.0.1, DNS:localhost
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
"@ | Set-Content -Encoding ascii $cnf
    $ErrorActionPreference = "Continue"   # openssl reports progress on stderr
    & $openssl req -x509 -newkey rsa:2048 -nodes -days 397 -config $cnf `
        -keyout (Join-Path $dir "key.pem") -out (Join-Path $dir "cert.pem") 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "openssl could not make the certificate." }
    Set-Content -Encoding ascii (Join-Path $dir "ip.txt") $ip
}

# 1. Build the planner when web/dist is missing or older than any source file.
$needBuild = $Rebuild -or -not (Test-Path $dist)
if (-not $needBuild) {
    $built = (Get-Item $dist).LastWriteTime
    $newer = Get-ChildItem -Path (Join-Path $web "src"), (Join-Path $web "index.html"), (Join-Path $web "public") -Recurse -File |
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

# 2. For -Lan: this computer's Wi-Fi address and a certificate made for it (remade when the address changes).
$lanIp = $null
if ($Lan) {
    $lanIp = Get-LanAddress
    if (-not $lanIp) { Write-Error "No network with a gateway found: connect this computer to the Wi-Fi the phone will use." }
    $certDir = Join-Path $root "data\https"
    $ipFile = Join-Path $certDir "ip.txt"
    $have = (Test-Path (Join-Path $certDir "cert.pem")) -and (Test-Path $ipFile) -and ((Get-Content $ipFile -Raw).Trim() -eq $lanIp)
    if (-not $have) {
        Write-Host "Making a certificate for $lanIp (data\https)..."
        New-LanCertificate $certDir $lanIp
    }
}

# 3. Start the API (it also serves the planner) unless one is already answering on this port.
if (Test-Api) {
    Write-Host "The API is already running on port $Port."
} else {
    if (-not (Test-Path $python)) {
        Write-Error "No Python environment at .venv. Run: python -m venv .venv; .venv\Scripts\pip install -r requirements.txt"
    }
    if ($needBuild) { Write-Host "Starting the API (restart it after editing server code: it runs without --reload)..." }
    $log = Join-Path $root "data\server.log"
    $uvArgs = @("-m", "uvicorn", "server.main:app", "--port", "$Port")
    if ($Lan) {
        # Relative paths: Start-Process does not quote arguments, and the project path may contain spaces.
        $uvArgs += @("--host", "0.0.0.0", "--ssl-keyfile", "data\https\key.pem", "--ssl-certfile", "data\https\cert.pem")
        $log = Join-Path $root "data\server-lan.log"
    } else {
        $uvArgs += @("--host", "127.0.0.1")
    }
    Start-Process -FilePath $python -ArgumentList $uvArgs -WorkingDirectory $root -WindowStyle Minimized -RedirectStandardError $log
    $t0 = Get-Date
    while (-not (Test-Api)) {
        if (((Get-Date) - $t0).TotalSeconds -gt 90) { Write-Error "The API did not start within 90 s. See $log" }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "API up on port $Port (log: $(Split-Path $log -Leaf) in data)."
}

# 4. Open the planner.
if ($Lan) {
    Write-Host ""
    Write-Host "On a phone or tablet on the same Wi-Fi, open:   https://${lanIp}:$Port/"
    Write-Host "The certificate was made on this computer, so the browser warns once: choose Advanced, then Proceed."
    Write-Host "Then: Earth link -> Walk it on Earth, and walk the EVA at full scale on a sports field."
    Write-Host "If the phone cannot connect, Windows may be blocking Python on this network (Windows Security -> Firewall)."
    Write-Host ""
}
if (-not $NoBrowser) { Start-Process $url }
Write-Host "Web planner: $url"
