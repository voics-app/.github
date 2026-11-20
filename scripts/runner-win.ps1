# Native self-hosted GitHub Actions runner on the owner's Windows PC, for jobs that must run on Windows
# (the desktop client installer: NSIS + the native crypto module). Not a container: it uses the PC's
# installed Node/pnpm/Rust/MSVC toolchain, exactly what `pnpm dist:win` uses locally.
#
#   powershell -File scripts\runner-win.ps1 up       download (once), register (label karma-win), start in the background,
#                                                    and set the client repo variable WINDOWS_RUNNER=karma-win
#   powershell -File scripts\runner-win.ps1 down     stop this runner; leave WINDOWS_RUNNER set so releases queue
#   powershell -File scripts\runner-win.ps1 status
#
# Needs: gh with admin:org. The runner runs as your user while it is up; it does not survive a reboot
# (run `up` again). Releases wait in the queue while it is down and WINDOWS_RUNNER is set.
param(
  [ValidateSet('up', 'down', 'status')][string]$Command = 'status',
  [string]$RunnerDir = (Join-Path $env:LOCALAPPDATA 'discordy-actions-runner'),
  [string]$RunnerName = "karma-win-$env:COMPUTERNAME"
)
$ErrorActionPreference = 'Stop'
$Org = 'discordy-voics'
$Label = 'karma-win'
$Name = $RunnerName.ToLower()
$Version = '2.338.0'   # same runner version as the Linux runners
$Dir = $RunnerDir

function Get-OrgRunners {
  $response = gh api --paginate --slurp "orgs/$Org/actions/runners?per_page=100"
  if ($LASTEXITCODE -ne 0) { throw 'Could not list organization runners.' }
  @($response | ConvertFrom-Json | ForEach-Object { $_.runners })
}

function Get-NamedRunner {
  $found = @(Get-OrgRunners | Where-Object { $_.name -eq $Name })
  if ($found.Count -gt 1) { throw 'Duplicate runner names; resolve them first.' }
  if ($found.Count -eq 1) { return $found[0] }
  return $null
}

function Get-LocalConfiguration {
  $path = Join-Path $Dir '.runner'
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
  catch { throw 'Local runner configuration is unreadable.' }
  if ($config.agentName -ne $Name -or $config.gitHubUrl -notmatch '^https://github\.com/discordy-voics/?$') {
    throw 'Local runner belongs to another name or organization; refusing to change it.'
  }
  $config
}

function Get-LocalRunnerProcesses {
  $bin = [IO.Path]::GetFullPath((Join-Path $Dir 'bin')).TrimEnd('\') + '\'
  @(Get-Process -Name 'Runner.Listener', 'Runner.Worker' -ErrorAction SilentlyContinue | Where-Object {
    try { $path = $_.Path } catch { throw 'Cannot identify a runner process path; refusing to modify processes.' }
    if (-not $path) { throw 'Cannot identify a runner process path; refusing to modify processes.' }
    $path.StartsWith($bin, [StringComparison]::OrdinalIgnoreCase)
  })
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
    $config = Get-LocalConfiguration
    $runner = Get-NamedRunner
    if ($config) {
      if (-not $runner -or [string]$runner.id -ne [string]$config.agentId) {
        throw 'Local registration is stale or does not match GitHub; repair it before starting.'
      }
      $local = @(Get-LocalRunnerProcesses | Where-Object { $_.ProcessName -eq 'Runner.Listener' })
      if ($runner.status -eq 'online' -and $local.Count -eq 0) {
        throw 'Runner is online without its local listener; refusing a duplicate.'
      }
      if ($local.Count -gt 1) { throw 'Multiple local listeners belong to this runner.' }
    } else {
      if ($runner) { throw 'Runner name exists without matching local configuration.' }
      $token = gh api -X POST "orgs/$Org/actions/runners/registration-token" -q .token
      if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not obtain a registration token.' }
      Push-Location $Dir
      try {
        & .\config.cmd --unattended --url "https://github.com/$Org" --token $token --name $Name --labels $Label --no-default-labels --work _work | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Runner configuration failed; WINDOWS_RUNNER was not changed.' }
      } finally { $token = $null; Pop-Location }
      $config = Get-LocalConfiguration
      if (-not $config) { throw 'Runner configuration did not produce a local registration.' }
    }
    if (@(Get-LocalRunnerProcesses | Where-Object { $_.ProcessName -eq 'Runner.Listener' }).Count -eq 0) {
      Start-Process -FilePath (Join-Path $Dir 'run.cmd') -WorkingDirectory $Dir -WindowStyle Hidden
    }
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
      $runner = Get-NamedRunner
      if ($runner -and [string]$runner.id -eq [string]$config.agentId -and $runner.status -eq 'online' -and @($runner.labels | Where-Object { $_.name -eq $Label }).Count -gt 0) { $ready = $true; break }
      Start-Sleep 2
    }
    if (-not $ready) { throw 'Runner did not become online with the required label; WINDOWS_RUNNER was not changed.' }
    gh variable set WINDOWS_RUNNER -R "$Org/client" --body $Label | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Runner is online, but setting WINDOWS_RUNNER failed.' }
    "runner ${Name}: online; WINDOWS_RUNNER=$Label on $Org/client"
  }
  'down' {
    $config = Get-LocalConfiguration
    if (-not $config) { throw 'No matching local runner configuration; refusing to remove a remote runner.' }
    $runner = Get-NamedRunner
    if ($runner -and [string]$runner.id -ne [string]$config.agentId) { throw 'Runner ID mismatch; refusing to remove it.' }
    if ($runner -and $runner.busy) { throw 'Runner is busy; wait for its job before stopping it.' }
    $local = @(Get-LocalRunnerProcesses)
    if (@($local | Where-Object { $_.ProcessName -eq 'Runner.Worker' }).Count -gt 0) { throw 'A local runner job is active; wait before stopping it.' }
    $local | Where-Object { $_.ProcessName -eq 'Runner.Listener' } | Stop-Process -Force
    if (@(Get-LocalRunnerProcesses | Where-Object { $_.ProcessName -eq 'Runner.Worker' }).Count -gt 0) { throw 'A job started during shutdown; it was left running.' }
    if ($runner) {
      $token = gh api -X POST "orgs/$Org/actions/runners/remove-token" -q .token
      if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not obtain a removal token.' }
      Push-Location $Dir
      try {
        & .\config.cmd remove --token $token | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Runner removal failed.' }
      } finally { $token = $null; Pop-Location }
    }
    "runner $Name stopped; WINDOWS_RUNNER retained so releases queue rather than use hosted minutes"
  }
  'status' {
    $r = Get-NamedRunner
    "runner ${Name}: $(if ($r) { "$($r.status) busy=$($r.busy)" } else { 'not registered' })"
    $v = gh api "repos/$Org/client/actions/variables/WINDOWS_RUNNER" -q .value 2>$null
    "WINDOWS_RUNNER (client): $(if ($v) { $v } else { '<unset: windows-latest>' })"
  }
}
