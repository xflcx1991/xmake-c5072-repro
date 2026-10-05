# Measures the runner's real cl.exe with the same command line the slow
# ground-truth step uses, twice in the same job: once before any xmake has run,
# once after setup-xmake + `xmake l`. Only the job history differs between the
# two phases, so a difference in timing is a difference in history.
#
# Every wait is capped: the capped variants poll HasExited themselves, and the
# -Wait shape runs in a child pwsh the parent can kill.
param([string]$Phase)

$ErrorActionPreference = 'Continue'
$cl = (Get-Command cl.exe).Source
$work = (Get-Location).Path
$src = Join-Path $work 'probe.c'
Set-Content -Path $src -Value 'int main(void){return 0;}' -Encoding ascii
$obj = Join-Path $env:RUNNER_TEMP 'h.obj'

function Get-SharedText([string]$Path) {
    # Read a file another process is still writing; Get-Content does not share.
    if (-not (Test-Path $Path)) { return '' }
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}

function Invoke-Capped {
    param([string]$Name, [string[]]$ArgList, [int]$CapMs = 20000)
    $outFile = Join-Path $env:RUNNER_TEMP "h_$($Name)_out.txt"
    $errFile = Join-Path $env:RUNNER_TEMP "h_$($Name)_err.txt"
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue

    $sw = [Diagnostics.Stopwatch]::StartNew()
    # The ci.yml call shape, minus the unbounded -Wait.
    $p = Start-Process -FilePath $cl -ArgumentList $ArgList -NoNewWindow -PassThru `
          -WorkingDirectory $work `
          -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $exited = $false
    while ($sw.ElapsedMilliseconds -lt $CapMs) {
        if ($p.WaitForExit(200)) { $exited = $true; break }
    }
    $sw.Stop()

    if ($exited) {
        Write-Host "[$Phase/$Name] cl exited after $($sw.ElapsedMilliseconds) ms, exit code $($p.ExitCode)"
    } else {
        Write-Host "[$Phase/$Name] cl STILL ALIVE at the ${CapMs} ms cap"
        try { $p.Kill($true); $p.WaitForExit(5000) | Out-Null } catch {}
    }
    Write-Host "[$Phase/$Name]   stdout: $((Get-SharedText $outFile) -replace '\r?\n', ' | ')"
    Write-Host "[$Phase/$Name]   stderr: $((Get-SharedText $errFile) -replace '\r?\n', ' | ')"
}

Write-Host "=== phase: $Phase"
Write-Host "[$Phase] cl:        $cl"
Write-Host "[$Phase] workdir:   $work"
Write-Host "[$Phase] XMAKE_ROOT=$($env:XMAKE_ROOT) XMAKE_PROGRAM_DIR=$($env:XMAKE_PROGRAM_DIR)"
$live = @(Get-Process -Name cl, mspdbsrv, vctip, xmake -ErrorAction SilentlyContinue)
$liveText = if ($live) { ($live | ForEach-Object { "$($_.ProcessName)=$($_.Id)" }) -join ' ' } else { 'none' }
Write-Host "[$Phase] toolchain/xmake processes already alive: $liveText"

Invoke-Capped -Name 'asanProbeA' -ArgList @('/nologo', '/c', '/fsanitize=address', "/Fo$obj", $src)
Invoke-Capped -Name 'unknownXx' -ArgList @('/nologo', '/c', '/xx', "/Fo$obj", $src)

# The unbounded shape, in a child pwsh so it can be capped. diag/waitcase.ps1 is
# the ci.yml code verbatim, including -Wait.
$pwsh = (Get-Process -Id $PID).Path
$case = Join-Path $work 'diag\waitcase.ps1'
$kidOut = Join-Path $env:RUNNER_TEMP 'kid.out'
$kidErr = Join-Path $env:RUNNER_TEMP 'kid.err'
Remove-Item $kidOut, $kidErr -ErrorAction SilentlyContinue
$kidArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" "{1}" "{2}" "{3}" "{4}"' -f `
    $case, $cl, $src, $env:RUNNER_TEMP, $Phase

$capSec = 60
$sw = [Diagnostics.Stopwatch]::StartNew()
$cp = Start-Process -FilePath $pwsh -ArgumentList $kidArgs -NoNewWindow -PassThru `
      -WorkingDirectory $work `
      -RedirectStandardOutput $kidOut -RedirectStandardError $kidErr
$pumped = 0
$ok = $false
while ($sw.ElapsedMilliseconds -lt ($capSec * 1000)) {
    $cp.WaitForExit(1000) | Out-Null
    $lines = @((Get-SharedText $kidOut) -split "\r?\n" | Where-Object { $_ -ne '' })
    while ($pumped -lt $lines.Count) {
        Write-Host "[$Phase/relay] $($lines[$pumped])   (parent t=$($sw.ElapsedMilliseconds) ms)"
        $pumped++
    }
    if ($cp.HasExited) { $ok = $true; break }
    $n = @(Get-Process -Name cl -ErrorAction SilentlyContinue).Count
    Write-Host "[$Phase/relay] cl processes alive: $n (parent t=$($sw.ElapsedMilliseconds) ms)"
}
$sw.Stop()

if ($ok) {
    Write-Host "[$Phase/-Wait] the verbatim ci.yml shape returned in $($sw.ElapsedMilliseconds) ms"
} else {
    Write-Host "[$Phase/-Wait] STILL BLOCKED at the ${capSec} s cap -- reproduced in this phase"
    Get-Process -Name cl, pwsh, mspdbsrv, vctip, xmake -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "    holding: $($_.ProcessName) pid=$($_.Id) start=$($_.StartTime.ToString('HH:mm:ss'))" }
    try { $cp.Kill($true); $cp.WaitForExit(5000) | Out-Null } catch {}
}
$ke = Get-SharedText $kidErr
if ($ke) { Write-Host "[$Phase] child stderr: $($ke -replace '\r?\n', ' | ')" }
exit 0
