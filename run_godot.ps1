# Launch the Martian Map EVA Console (Godot 4.7).
#   .\run_godot.ps1                          # normal start (the app starts the API itself if it is not running)
#   .\run_godot.ps1 -Quality high            # force a rendering preset: low | medium | high
#   .\run_godot.ps1 -Site jezero_threeforks  # open another site
#   .\run_godot.ps1 -Editor                  # open the project in the Godot editor instead
#   .\run_godot.ps1 -Trailer [-Site <id>]    # record the hands-free demo to trailer\martian_map_<site>.mp4 (MP4 needs ffmpeg)
#   .\run_godot.ps1 -Trailer -Short [-Site <id>]   # the 30-second cut (a Space Apps demo video is 30 s): ..._30s.mp4
# Set $env:GODOT to your Godot executable if it is not found automatically.
param(
    [ValidateSet("", "low", "medium", "high")][string]$Quality = "",
    [switch]$Editor,
    [switch]$Trailer,
    [switch]$Short,
    [string]$Site = ""
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

if ($Trailer) {
    # Godot's movie writer renders every frame at a fixed 30 fps, so the video is smooth however fast the laptop is.
    $out = Join-Path $PSScriptRoot "trailer"
    New-Item -ItemType Directory -Force $out | Out-Null
    $name = if ($Site) { "martian_map_$Site" } else { "martian_map_demo" }
    if ($Short) { $name += "_30s" }
    $tourArg = if ($Short) { "--tour=trailer30" } else { "--tour=trailer" }
    $avi = Join-Path $out "$name.avi"
    $shots = Join-Path $env:TEMP "martian_map_trailer"
    New-Item -ItemType Directory -Force $shots | Out-Null
    $marks = Join-Path $shots "trailer_marks.txt"
    Remove-Item $marks -ErrorAction SilentlyContinue
    Write-Host "Recording the demo (it runs slower than real time while it records)..."
    $q = { param($v) '"' + $v + '"' }   # Start-Process passes one string: quote the paths with spaces
    $argv = @("--path", (& $q $project), "--resolution", "1600x900", "--write-movie", (& $q $avi), "--fixed-fps", "30",
        "--", (& $q "--capture=$shots"), $tourArg)
    if ($Site) { $argv += "--site=$Site" }
    Start-Process -FilePath $godot -ArgumentList $argv -Wait   # the windowed exe returns at once unless we wait for it
    $ff = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($ff -and (Test-Path $avi)) {
        $mp4 = [IO.Path]::ChangeExtension($avi, ".mp4")
        $enc = @("-c:v", "libx264", "-crf", "21", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart")
        # The app writes where the demo starts and ends (frames): keep 3 s of the title screen, then cut the loading out.
        $t0 = $null; $t1 = $null
        if (Test-Path $marks) {
            foreach ($l in Get-Content $marks) {
                $p = $l -split " "
                if ($p[0] -eq "start") { $t0 = [double]$p[1] / 30.0 }
                if ($p[0] -eq "end") { $t1 = [double]$p[1] / 30.0 }
            }
        }
        if ($Short -and (Test-Path $marks)) {
            # keep 1 s of the title, then every stretch between an "in" and an "out" mark (loading is cut out)
            $segs = @(, @(0.0, 1.0))
            $s0 = $null
            foreach ($l in Get-Content $marks) {
                $p = $l -split " "
                $f = [double]$p[1] / 30.0
                if ($p[0] -eq "in") { $s0 = $f }
                elseif (($p[0] -eq "out" -or $p[0] -eq "end") -and $null -ne $s0) { $segs += , @($s0, $f); $s0 = $null }
            }
            $total = ($segs | ForEach-Object { $_[1] - $_[0] } | Measure-Object -Sum).Sum
            $k = [Math]::Max(1.0, $total / 29.8)   # a few per cent faster if the shots ran long
            $inv = [Globalization.CultureInfo]::InvariantCulture
            $fc = ""; $cat = ""
            for ($i = 0; $i -lt $segs.Count; $i++) {
                $a = $segs[$i][0].ToString("0.###", $inv)
                $b = $segs[$i][1].ToString("0.###", $inv)
                $fc += "[0:v]trim=start=${a}:end=${b},setpts=PTS-STARTPTS[v$i];[0:a]atrim=start=${a}:end=${b},asetpts=PTS-STARTPTS[a$i];"
                $cat += "[v$i][a$i]"
            }
            $kk = $k.ToString("0.####", $inv)
            $fc += "${cat}concat=n=$($segs.Count):v=1:a=1[cv][ca];[cv]setpts=PTS/${kk}[v];[ca]atempo=${kk}[a]"
            & $ff.Source -y -loglevel error -i $avi -filter_complex $fc -map "[v]" -map "[a]" @enc $mp4
            Write-Host ("30-second cut: {0} shots from {1:0.0} s of footage, played x{2}" -f ($segs.Count - 1), $total, $kk)
        } elseif ($null -ne $t0 -and $null -ne $t1 -and $t1 -gt $t0) {
            $inv = [Globalization.CultureInfo]::InvariantCulture
            $s = $t0.ToString("0.###", $inv)
            $e = $t1.ToString("0.###", $inv)
            $fc = "[0:v]trim=0:3,setpts=PTS-STARTPTS[tv];[0:a]atrim=0:3,asetpts=PTS-STARTPTS[ta];" +
                "[0:v]trim=start=${s}:end=${e},setpts=PTS-STARTPTS[dv];[0:a]atrim=start=${s}:end=${e},asetpts=PTS-STARTPTS[da];" +
                "[tv][ta][dv][da]concat=n=2:v=1:a=1[v][a]"
            & $ff.Source -y -loglevel error -i $avi -filter_complex $fc -map "[v]" -map "[a]" @enc $mp4
        } else {
            & $ff.Source -y -loglevel error -i $avi @enc $mp4
        }
        if (Test-Path $mp4) { Remove-Item $avi; Write-Host "Trailer: $mp4" }
    } else {
        Write-Host "Trailer: $avi (install ffmpeg for a small MP4)"
    }
    return
}

$gargs = @("--path", $project)
$user = @()
if ($Quality) { $user += "--quality=$Quality" }
if ($Site) { $user += "--site=$Site" }
if ($Editor) {
    $gargs = @("--editor") + $gargs
} elseif ($user.Count -gt 0) {
    $gargs += @("--") + $user
}
& $godot @gargs
