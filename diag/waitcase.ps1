# The ci.yml ground-truth probe, verbatim: Start-Process -NoNewWindow -Wait
# -PassThru with stdout/stderr redirected to files. Run as a child pwsh so the
# parent (diag/harness.ps1) can cap it instead of hanging for the full 900 s.
param([string]$Cl, [string]$Src, [string]$Tmp, [string]$Phase)

$ErrorActionPreference = 'Continue'
$sw = [Diagnostics.Stopwatch]::StartNew()
Write-Host "child[$Phase] t=$($sw.ElapsedMilliseconds) ms: calling Start-Process -Wait"

# Same argument list shape as the slow step, including the relative source file
# and the /Fo path built by string interpolation.
$obj = "/Fo$Tmp\gt_a.obj"
$p = Start-Process -FilePath $Cl `
      -ArgumentList @('/nologo', '/c', '/fsanitize=address', $obj, 'probe.c') `
      -NoNewWindow -Wait -PassThru `
      -RedirectStandardOutput "$Tmp\gt.out" -RedirectStandardError "$Tmp\gt.err"
$sw.Stop()

Write-Host "child[$Phase] t=$($sw.ElapsedMilliseconds) ms: -Wait returned, exit=$($p.ExitCode)"
$out = Get-Content "$Tmp\gt.out" -ErrorAction SilentlyContinue
Write-Host "child[$Phase] gt.out: $(@($out) -join ' | ')"
