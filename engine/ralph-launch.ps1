# ralph-launch.ps1 — launch N Ralph loops, each with its own monitor terminal.
#
# For each repo: opens TWO terminals — one runs the executor (the loop), one runs the clean
# monitor (ralph-watch.sh) that becomes a Claude grill if the loop blocks/fails. One repo's
# pair never interferes with another's (separate worktrees + separate terminals).
#
# Usage (PowerShell):
#   .\ralph-launch.ps1 -Repos "C:\path\repoA","C:\path\repoB"
#   .\ralph-launch.ps1 -Repos "C:\path\repoA" -WatchOnly      # just the monitor, loop already running
#
# Each terminal titles itself so you can tell them apart on the taskbar.

param(
  [Parameter(Mandatory=$true)][string[]]$Repos,
  [switch]$WatchOnly,                 # don't start the loop, only the monitor
  [string]$BashExe = ""               # auto-detected if not given (your git is on D:, not C:)
)

function Find-Bash {
  param([string]$Override)
  if ($Override -and (Test-Path $Override)) { return $Override }
  # 1) candidates on any drive (your git is D:\Git)
  $cands = @(
    "C:\Program Files\Git\bin\bash.exe","C:\Program Files\Git\usr\bin\bash.exe",
    "D:\Git\bin\bash.exe","D:\Git\usr\bin\bash.exe",
    "C:\Program Files (x86)\Git\bin\bash.exe"
  )
  foreach ($c in $cands) { if (Test-Path $c) { return $c } }
  # 2) derive from git on PATH: <gitroot>\bin\bash.exe  (git --exec-path → ...\mingw64\libexec\git-core)
  $git = (Get-Command git -ErrorAction SilentlyContinue).Source
  if ($git) {
    $root = Split-Path (Split-Path $git -Parent) -Parent   # ...\Git\cmd\git.exe → ...\Git
    foreach ($sub in @("bin\bash.exe","usr\bin\bash.exe")) {
      $p = Join-Path $root $sub
      if (Test-Path $p) { return $p }
    }
  }
  # 3) bash on PATH directly
  $b = (Get-Command bash -ErrorAction SilentlyContinue).Source
  if ($b) { return $b }
  return $null
}

$BashExe = Find-Bash -Override $BashExe
if (-not $BashExe) {
  Write-Error "Could not find git-bash. Pass -BashExe <full path to bash.exe> (yours may be under D:\Git\bin\bash.exe)."; exit 1
}
Write-Host "using bash: $BashExe" -ForegroundColor DarkGray

foreach ($repo in $Repos) {
  if (-not (Test-Path $repo)) { Write-Warning "skip: $repo (not found)"; continue }
  $name = Split-Path $repo -Leaf

  if (-not $WatchOnly) {
    # Terminal 1: the loop. Title = "ralph:<repo>".
    $loopCmd = "cd '$repo' && ~/.claude/ralph/ralph-exec.sh; echo; read -p 'loop exited — Enter to close '"
    Start-Process -FilePath "cmd.exe" -ArgumentList @(
      "/c","title ralph:$name && `"$BashExe`" -lc `"$loopCmd`""
    )
    Start-Sleep -Milliseconds 800   # let the loop write its first status.json
  }

  # Terminal 2: the clean monitor (becomes a Claude grill on a blocker). Title = "watch:<repo>".
  $watchCmd = "~/.claude/ralph/ralph-watch.sh '$repo'"
  Start-Process -FilePath "cmd.exe" -ArgumentList @(
    "/c","title watch:$name && `"$BashExe`" -lc `"$watchCmd`""
  )

  Write-Host "launched: $name  (loop + monitor)" -ForegroundColor Green
}

Write-Host ""
Write-Host "All loops launched. Each 'watch:<repo>' window shows a clean dashboard;" -ForegroundColor Cyan
Write-Host "if a loop blocks or fails, that window becomes a Claude session that asks you" -ForegroundColor Cyan
Write-Host "what it needs, then returns to monitoring once you've answered." -ForegroundColor Cyan
