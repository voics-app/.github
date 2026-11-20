$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $env:TEMP ('runner-win-test-' + [guid]::NewGuid().ToString('N'))
$testRoot = [IO.Path]::GetFullPath($testRoot)
if (-not $testRoot.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Bad test directory' }
New-Item -ItemType Directory -Path $testRoot | Out-Null
$global:testRunnerName = 'karma-win-fixture'
$global:testRunnerState = 'online'
$global:testRunnerId = 12
$global:testSeenSets = 0
$global:testStarted = 0
$global:testLocalListener = $true
function global:gh {
  $global:LASTEXITCODE = 0
  if ($args[0] -eq 'variable' -and $args[1] -eq 'set') { $global:testSeenSets++; return }
  if ($args[0] -eq 'api' -and $args -contains '--slurp' -and $global:testRunnerAbsent) { return '[{"runners":[]}]' }
  if ($args[0] -eq 'api' -and $args -contains '--slurp') {
    return (ConvertTo-Json -InputObject @(@{ runners = @(@{ id = $global:testRunnerId; name = $global:testRunnerName; status = $global:testRunnerState; busy = [bool]$global:testRunnerBusy; labels = @(@{ name = 'karma-win' }) }) }) -Depth 8 -Compress)
  }
  if ($args[0] -eq 'api' -and $args -contains 'POST') { return 'fixture-token' }
  throw 'Unexpected gh call'
}
function global:Get-Process {
  if ($global:testLocalListener) { [pscustomobject]@{ ProcessName='Runner.Listener'; Path=(Join-Path $testRoot 'bin\Runner.Listener.exe') } }
}
function global:Start-Process { $global:testStarted++ }
function global:Start-Sleep { }
try {
  New-Item -ItemType File -Path (Join-Path $testRoot 'config.cmd') | Out-Null
  @{ agentName=$global:testRunnerName; agentId=12; gitHubUrl='https://github.com/discordy-voics' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot '.runner')
  & "$PSScriptRoot\..\scripts\runner-win.ps1" up -RunnerDir $testRoot -RunnerName $global:testRunnerName
  if ($global:testSeenSets -ne 1 -or $global:testStarted -ne 0) { throw 'Online runner was not preserved.' }
  $global:testSeenSets = 0; $global:testRunnerState = 'offline'
  try { & "$PSScriptRoot\..\scripts\runner-win.ps1" up -RunnerDir $testRoot -RunnerName $global:testRunnerName; throw 'Expected offline refusal' }
  catch { if ($_.Exception.Message -notmatch 'did not become online') { throw } }
  if ($global:testSeenSets -ne 0) { throw 'Offline runner changed WINDOWS_RUNNER.' }
  $global:testRunnerId = 13
  try { & "$PSScriptRoot\..\scripts\runner-win.ps1" up -RunnerDir $testRoot -RunnerName $global:testRunnerName; throw 'Expected mismatch refusal' }
  catch { if ($_.Exception.Message -notmatch 'stale or does not match') { throw } }
  if ($global:testSeenSets -ne 0) { throw 'Mismatched runner changed WINDOWS_RUNNER.' }
  $global:testRunnerId = 12; $global:testRunnerState = 'online'; $global:testRunnerBusy = $true
  try { & "$PSScriptRoot\..\scripts\runner-win.ps1" down -RunnerDir $testRoot -RunnerName $global:testRunnerName; throw 'Expected busy refusal' }
  catch { if ($_.Exception.Message -notmatch 'busy') { throw } }
  if ($global:testSeenSets -ne 0) { throw 'Busy shutdown changed WINDOWS_RUNNER.' }
  $global:testRunnerAbsent = $true
  $newRoot = Join-Path $testRoot 'new'
  New-Item -ItemType Directory -Path $newRoot | Out-Null
  '@exit /b 7' | Set-Content -Encoding ascii (Join-Path $newRoot 'config.cmd')
  try { & "$PSScriptRoot\..\scripts\runner-win.ps1" up -RunnerDir $newRoot -RunnerName $global:testRunnerName; throw 'Expected configuration failure' }
  catch { if ($_.Exception.Message -notmatch 'configuration failed') { throw } }
  if ($global:testSeenSets -ne 0 -or $global:testStarted -ne 0) { throw 'Failed configuration started a runner or changed WINDOWS_RUNNER.' }
  'runner-win tests passed'
} finally {
  Remove-Item function:global:gh, function:global:Get-Process, function:global:Start-Process, function:global:Start-Sleep -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $testRoot -Recurse -Force
}
