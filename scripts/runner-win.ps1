# Native self-hosted GitHub Actions runner on the owner's Windows PC, for jobs that must run on Windows
# (the desktop client installer: NSIS + the native crypto module). Not a container: it uses the PC's
# installed Node/pnpm/Rust/MSVC toolchain, exactly what `pnpm dist:win` uses locally.
#
#   powershell -File scripts\runner-win.ps1 up       download (once), register (label karma-win), start in the background,
#                                                    and set the client repo variable WINDOWS_RUNNER=karma-win
#   powershell -File scripts\runner-win.ps1 down     stop, deregister, unset WINDOWS_RUNNER (releases fall back to windows-latest)
#   powershell -File scripts\runner-win.ps1 status
#
# Needs: gh with admin:org. The runner runs as your user while it is up; it does not survive a reboot
# (run `up` again). Releases wait in the queue while it is down and WINDOWS_RUNNER is set.
param([ValidateSet('up', 'down', 'status')][string]$Command = 'status')
$ErrorActionPreference = 'Stop'
$Org = 'discordy-voics'
$Label = 'karma-win'
$Name = "karma-win-$env:COMPUTERNAME".ToLower()
$Version = '2.338.0'   # same runner version as the Linux runners
$Dir = Join-Path $env:LOCALAPPDATA 'discordy-actions-runner'

function Get-RunnerId {
  $json = gh api --paginate "orgs/$Org/actions/runners?per_page=100" | ConvertFrom-Json
  ($json.runners | Where-Object { $_.name -eq $Name }).id
}

switch ($Command) {
  'up' {
    if (-not (Test-Path "$Dir\config.cmd")) {
      New-Item -ItemType Directory -Force $Dir | Out-Null
      $zip = Join-Path $env:TEMP "actions-runner-win-x64-$Version.zip"
      Invoke-WebRequest "https://github.com/actions/runner/releases/download/v$Version/actions-runner-win-x64-$Version.zip" -OutFile $zip
      Expand-Archive $zip -DestinationPath $Dir -Force
      Remove-Item $zip
    }
    Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue | Stop-Process -Force
    $token = gh api -X POST "orgs/$Org/actions/runners/registration-token" -q .token
    Push-Location $Dir
    & .\config.cmd --unattended --replace --url "https://github.com/$Org" --token $token --name $Name --labels $Label --no-default-labels --work _work | Out-Null
    Start-Process -FilePath "$Dir\run.cmd" -WorkingDirectory $Dir -WindowStyle Hidden
    Pop-Location
    for ($i = 0; $i -lt 30; $i++) {
      Start-Sleep 2
      $r = (gh api --paginate "orgs/$Org/actions/runners?per_page=100" | ConvertFrom-Json).runners | Where-Object { $_.name -eq $Name }
      if ($r.status -eq 'online') { break }
    }
    "runner ${Name}: $($r.status)"
    gh variable set WINDOWS_RUNNER -R "$Org/client" --body $Label | Out-Null
    "WINDOWS_RUNNER=$Label on $Org/client"
  }
  'down' {
    gh variable delete WINDOWS_RUNNER -R "$Org/client" 2>$null | Out-Null
    Get-Process -Name 'Runner.Listener', 'Runner.Worker' -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Test-Path "$Dir\config.cmd") {
      $token = gh api -X POST "orgs/$Org/actions/runners/remove-token" -q .token
      Push-Location $Dir; & .\config.cmd remove --token $token | Out-Null; Pop-Location
    }
    $id = Get-RunnerId
    if ($id) { gh api -X DELETE "orgs/$Org/actions/runners/$id" | Out-Null }
    "runner $Name removed; client releases use windows-latest"
  }
  'status' {
    $r = (gh api --paginate "orgs/$Org/actions/runners?per_page=100" | ConvertFrom-Json).runners | Where-Object { $_.name -eq $Name }
    "runner ${Name}: $(if ($r) { "$($r.status) busy=$($r.busy)" } else { 'not registered' })"
    $v = gh api "repos/$Org/client/actions/variables/WINDOWS_RUNNER" -q .value 2>$null
    "WINDOWS_RUNNER (client): $(if ($v) { $v } else { '<unset: windows-latest>' })"
  }
}
