# Run the QuickJS spider integration tests.
#
# `flutter test` runs on the plain Dart VM (flutter_tester.exe), which cannot
# load the Flutter plugin's native library. These spider tests are therefore
# integration tests: they need a real `quickjs_c_bridge.dll` plus a real HTTP
# fixture, so they are skipped by default and enabled by this script.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tool/run_spider_tests.ps1
param(
  [string]$Flutter = 'flutter',
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root

try {
  if (-not $SkipBuild) {
    Write-Host '==> Building Windows release (produces quickjs_c_bridge.dll)' -ForegroundColor Cyan
    & $Flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }
  }

  $releaseDir = Join-Path $root 'build\windows\x64\runner\Release'
  $dll = Join-Path $releaseDir 'quickjs_c_bridge.dll'
  if (-not (Test-Path $dll)) {
    throw "Missing $dll - rerun without -SkipBuild."
  }

  # LoadLibrary resolves by module name; putting the artifact dir on PATH lets
  # flutter_js's DynamicLibrary.open('quickjs_c_bridge.dll') find it.
  $env:PATH = "$releaseDir;$env:PATH"
  Write-Host "==> PATH now includes $releaseDir" -ForegroundColor Cyan

  # Opt in to the spider integration tests (skipped by default).
  $env:AQUAN_SPIDER_TESTS = '1'

  Write-Host '==> Running test/spider' -ForegroundColor Cyan
  & $Flutter test test/spider
  if ($LASTEXITCODE -ne 0) { throw 'spider tests failed' }
}
finally {
  Pop-Location
}
