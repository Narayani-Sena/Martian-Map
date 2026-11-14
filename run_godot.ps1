# Launch the Martian Map EVA Console (Godot 4.7).
#   .\run_godot.ps1                 # normal start (the app starts the API itself if it is not running)
#   .\run_godot.ps1 -Quality high   # force a rendering preset: low | medium | high
#   .\run_godot.ps1 -Editor         # open the project in the Godot editor instead
# Set $env:GODOT to your Godot executable if it is not found automatically.
param(
    [ValidateSet("", "low", "medium", "high")][string]$Quality = "",
    [switch]$Editor
)
$ErrorActionPreference = "Stop"
$project = Join-Path $PSScriptRoot "godot"

$candidates = @()
if ($env:GODOT) { $candidates += $env:GODOT }
foreach ($n in "godot", "godot4", "Godot_v4.7.2-stable_win64.exe") {
    $c = Get-Command $n -ErrorAction SilentlyContinue
    if ($c) { $candidates += $c.Source }
}
$candidates += "D:\!!Pendrive\Coding\Python\ORON\godot_engine\Godot_v4.7.2-stable_win64.exe"
$godot = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $godot) {
    Write-Error "Godot 4.7 not found. Install it from https://godotengine.org and set `$env:GODOT to the .exe path."
}

# First run: let the editor import the project once (builds .godot/ and the class cache).
if (-not (Test-Path (Join-Path $project ".godot\global_script_class_cache.cfg"))) {
    Write-Host "First run: importing the Godot project..."
    & $godot --headless --path $project --import | Out-Null
}

$gargs = @("--path", $project)
if ($Editor) {
    $gargs = @("--editor") + $gargs
} elseif ($Quality) {
    $gargs += @("--", "--quality=$Quality")
}
& $godot @gargs
