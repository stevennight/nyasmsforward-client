# Builds the release artifacts into build/releases:
#   NyaSmsForward-Client_<version>_x64-setup.exe        Windows installer (NSIS)      [Windows only]
#   NyaSmsForward-Client_<version>_windows_x64.zip      Windows portable zip          [Windows only]
#   NyaSmsForward-Client_<version>.apk                  Android APK
# each with a .sha256 file next to it.
#
# Runs on Windows PowerShell 5.1 and PowerShell 7 (the Android part also runs on Linux CI runners).
#
# Android signing comes from the environment: ANDROID_KEYSTORE_FILE, ANDROID_KEYSTORE_PASSWORD,
# ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD. Without them Flutter signs with the debug key; pass
# -RequireSigned to refuse that (the release workflow does).
param(
  [switch]$SkipWindows,
  [switch]$SkipAndroid,
  [switch]$SkipInstaller,
  [switch]$RequireSigned,
  [string]$Tag = ""
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $Root

# Joins with forward slashes in the source and returns a fully normalized path for the current OS, so the same
# script works on Windows (native tools such as makensis want backslashes) and on Linux.
function Get-RootPath {
  param([Parameter(Mandatory = $true)][string]$Relative)
  return [IO.Path]::GetFullPath((Join-Path $Root $Relative))
}

function Invoke-Checked {
  param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$Arguments = @())
  # Flutter and Dart write progress to stderr. Windows PowerShell 5.1 turns redirected stderr into terminating
  # errors under "Stop", so success is decided by the exit code alone.
  $ErrorActionPreference = "Continue"
  & $FilePath @Arguments
  $ErrorActionPreference = "Stop"
  if ($LASTEXITCODE -ne 0) { throw "$FilePath failed with exit code $LASTEXITCODE" }
}

function Write-Sha256 {
  param([string]$Path)
  $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  Set-Content -LiteralPath "$Path.sha256" -Value "$hash  $(Split-Path -Leaf $Path)" -Encoding ascii
}

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { throw "Flutter was not found on PATH." }

# VERSION is the source of truth; refuse to build when pubspec.yaml or the tag disagree.
$versionArgs = @("run", "tool/check_version.dart")
if ($Tag) { $versionArgs += $Tag }
Invoke-Checked dart $versionArgs

$version = (Get-Content -LiteralPath (Get-RootPath "VERSION") -Raw).Trim()
$parts = $version.Split(".") | ForEach-Object { [int64]$_ }
$buildNumber = $parts[0] * 1000000 + $parts[1] * 1000 + $parts[2]

$outDir = Get-RootPath "build/releases"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

if (-not $SkipWindows) {
  if ($env:OS -ne "Windows_NT") { throw "The Windows build only runs on Windows; pass -SkipWindows." }
  Write-Host "== Windows ($version)" -ForegroundColor Cyan
  Invoke-Checked flutter @("build", "windows", "--release", "--build-name=$version", "--build-number=$buildNumber")
  $release = Get-RootPath "build/windows/x64/runner/Release"
  if (-not (Test-Path -LiteralPath (Join-Path $release "NyaSmsForward.exe"))) { throw "NyaSmsForward.exe was not produced." }

  # Stage the release folder plus the VC++ runtime DLLs the app links against (app-local deployment is allowed for
  # these), so the app starts on machines without the Visual C++ redistributable.
  $stage = Get-RootPath "build/windows-package/NyaSmsForward"
  if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Copy-Item -Path (Join-Path $release "*") -Destination $stage -Recurse -Force
  foreach ($dll in @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")) {
    $source = Join-Path $env:SystemRoot "System32\$dll"
    if (-not (Test-Path -LiteralPath $source)) { throw "$dll was not found in System32; install the Visual C++ redistributable on the build machine." }
    Copy-Item -LiteralPath $source -Destination $stage -Force
  }

  $zip = Join-Path $outDir "NyaSmsForward-Client_${version}_windows_x64.zip"
  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
  Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -Force
  Write-Sha256 $zip

  if (-not $SkipInstaller) {
    $makensis = Get-Command makensis -ErrorAction SilentlyContinue
    if (-not $makensis) {
      # Careful: PowerShell variables are case-insensitive, so the loop variable must not be called $root ($Root above).
      foreach ($programFiles in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        foreach ($rel in @("NSIS\makensis.exe", "NSIS\Bin\makensis.exe")) {
          $candidate = if ($programFiles) { Join-Path $programFiles $rel } else { $null }
          if ($candidate -and (Test-Path -LiteralPath $candidate)) { $makensis = Get-Command $candidate; break }
        }
        if ($makensis) { break }
      }
    }
    if (-not $makensis) { throw "makensis was not found. Install NSIS (choco install nsis) or pass -SkipInstaller." }

    $installer = Join-Path $outDir "NyaSmsForward-Client_${version}_x64-setup.exe"
    Invoke-Checked $makensis.Source @(
      "/V2", "/DVERSION=$version", "/DSOURCE_DIR=$stage", "/DOUTFILE=$installer",
      "/DICON=$(Get-RootPath 'windows/runner/resources/app_icon.ico')",
      (Get-RootPath "installer/nyasmsforward-client.nsi")
    )
    Write-Sha256 $installer
  }
}

if (-not $SkipAndroid) {
  Write-Host "== Android ($version)" -ForegroundColor Cyan
  if ($RequireSigned -and [string]::IsNullOrWhiteSpace($env:ANDROID_KEYSTORE_FILE)) {
    throw "ANDROID_KEYSTORE_FILE is not set; refusing to build an APK signed with the debug key."
  }
  # arm64 + armv7 covers every real phone; x86_64 is emulator-only and would add ~25 MB.
  Invoke-Checked flutter @("build", "apk", "--release", "--target-platform", "android-arm,android-arm64", "--build-name=$version", "--build-number=$buildNumber")
  $apk = Get-RootPath "build/app/outputs/flutter-apk/app-release.apk"
  if (-not (Test-Path -LiteralPath $apk)) { throw "app-release.apk was not produced." }
  $out = Join-Path $outDir "NyaSmsForward-Client_${version}.apk"
  Copy-Item -LiteralPath $apk -Destination $out -Force
  Write-Sha256 $out
}

Write-Host "Artifacts in ${outDir}:" -ForegroundColor Green
Get-ChildItem -LiteralPath $outDir | ForEach-Object { "  $($_.Name)  ($([math]::Round($_.Length / 1MB, 1)) MB)" }
