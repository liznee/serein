param(
  [ValidateSet('Debug', 'RelWithDebInfo', 'Release')]
  [string]$Configuration = 'RelWithDebInfo',
  [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$buildDir = Join-Path $projectDir 'build'

if ($Clean -and (Test-Path -LiteralPath $buildDir)) {
  $resolvedProject = [IO.Path]::GetFullPath($projectDir).TrimEnd('\')
  $resolvedBuild = [IO.Path]::GetFullPath($buildDir).TrimEnd('\')
  if (-not $resolvedBuild.StartsWith($resolvedProject + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean a build directory outside the project: $resolvedBuild"
  }
  Remove-Item -LiteralPath $resolvedBuild -Recurse -Force
}

$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
  throw @'
Visual Studio 2022 Build Tools were not found.
Install the "Desktop development with C++" workload and Windows 10/11 SDK,
then run this script again. DevEco's OpenHarmony compiler cannot build DXGI.
'@
}

$vsPath = (& $vswhere -latest -products * `
  -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
  -property installationPath).Trim()
if (-not $vsPath) {
  throw 'Visual Studio C++ x64 tools were not found.'
}

$cmakeCandidates = @(
  (Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'),
  ((Get-Command cmake.exe -ErrorAction SilentlyContinue).Source)
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
$cmake = $cmakeCandidates | Select-Object -First 1
if (-not $cmake) {
  throw 'CMake was not found in Visual Studio or PATH.'
}

$ninja = Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
if (-not (Test-Path -LiteralPath $ninja)) {
  throw 'Ninja was not found in Visual Studio. Install the C++ CMake tools component.'
}

# Shell and CI processes do not always inherit the standard Windows
# architecture variables. Import the VS x64 environment and use Ninja so
# compiler, linker, and SDK selection always comes from HostX64.
$devCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
$buildCommand = 'call "' + $devCmd + '" -no_logo -arch=x64 -host_arch=x64' +
  ' && "' + $cmake + '" -S "' + $projectDir + '" -B "' + $buildDir + '" -G Ninja' +
  ' -DCMAKE_MAKE_PROGRAM:FILEPATH="' + $ninja + '"' +
  ' -DCMAKE_BUILD_TYPE=' + $Configuration +
  ' -DCMAKE_CXX_COMPILER=cl.exe' +
  ' && "' + $cmake + '" --build "' + $buildDir + '" --parallel'

& cmd.exe /d /c $buildCommand
if ($LASTEXITCODE -ne 0) { throw "Native build failed: $LASTEXITCODE" }

$binary = Join-Path $buildDir 'serein-remote-host.exe'
if (-not (Test-Path -LiteralPath $binary)) {
  throw "Build succeeded but the executable was not found: $binary"
}

& $binary --self-test
if ($LASTEXITCODE -ne 0) { throw "Synthetic frame self-test failed: $LASTEXITCODE" }
& $binary --encoder-self-test
if ($LASTEXITCODE -ne 0) { throw "Media Foundation H.264 self-test failed: $LASTEXITCODE" }
& $binary --service-self-test
if ($LASTEXITCODE -ne 0) { throw "Remote Host IPC self-test failed: $LASTEXITCODE" }

Write-Output "Built: $binary"

# Build the Go WebRTC bridge. Go is optional: if it is not installed, the
# native host still works, but the lifecycle manager will not declare the
# webrtc transport and the phone will refuse view requests.
$bridgeDir = Join-Path $projectDir 'bridge'
$bridgeBinary = Join-Path $bridgeDir 'serein-remote-bridge.exe'
$goExe = (Get-Command go.exe -ErrorAction SilentlyContinue).Source
if ($goExe) {
  Push-Location $bridgeDir
  try {
    & $goExe build -o $bridgeBinary .
    if ($LASTEXITCODE -ne 0) { throw "Go bridge build failed: $LASTEXITCODE" }
    & $goExe vet ./...
    if ($LASTEXITCODE -ne 0) { throw "Go bridge vet failed: $LASTEXITCODE" }
    Write-Output "Built: $bridgeBinary"
  } finally {
    Pop-Location
  }
} elseif (Test-Path -LiteralPath $bridgeBinary) {
  Write-Output "Go not found; keeping existing bridge: $bridgeBinary"
} else {
  Write-Output "Go not found; skipping bridge build. Remote view will be unavailable."
}
