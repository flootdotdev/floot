# Installs the floot CLI for windows. This is loaded via
# `irm https://floot.dev/install.ps1 | iex`, so it must not declare a
# param block and must not rely on $MyInvocation or $PSScriptRoot;
# all configuration comes from environment variables instead.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = 'flootdotdev/floot'
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"
$downloadBase = "https://github.com/$repo/releases/download"

# only x64 builds are published for windows today, so anything else
# (arm64, for example) is unsupported rather than silently mismatched
$osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
if ($osArch -ne [System.Runtime.InteropServices.Architecture]::X64) {
    throw "unsupported architecture for windows: $osArch (only x64 is published)"
}

# archives ship as .zip on windows because Expand-Archive can unpack zip
# natively here, with no built-in tar.gz support to lean on instead
$asset = 'floot-windows-x64.zip'

$headers = @{}
$token = $env:GITHUB_TOKEN
if ([string]::IsNullOrEmpty($token)) { $token = $env:GH_TOKEN }
if (-not [string]::IsNullOrEmpty($token)) {
    $headers['Authorization'] = "Bearer $token"
}

# the API is used instead of following the /releases/latest redirect
# because it is what skips pre-releases when picking the latest tag
Write-Host 'resolving latest release...'
$release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing
$tag = $release.tag_name
if ([string]::IsNullOrEmpty($tag)) {
    throw 'could not determine the latest release tag'
}
$version = $tag -replace '^cli-v', ''

Write-Host "installing floot $version for windows-x64"

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('floot-install-' + [System.Guid]::NewGuid())
New-Item -ItemType Directory -Path $workDir | Out-Null

try {
    $archivePath = Join-Path $workDir $asset
    $checksumsPath = Join-Path $workDir 'checksums.txt'

    # No authorization header on these two: a release download redirects to an
    # object store that signs the redirect itself and answers 400 when a second
    # credential rides along, and Invoke-WebRequest forwards headers across the
    # redirect. The token only ever helps the API call above.
    Invoke-WebRequest -Uri "$downloadBase/$tag/$asset" -OutFile $archivePath -UseBasicParsing
    Invoke-WebRequest -Uri "$downloadBase/$tag/checksums.txt" -OutFile $checksumsPath -UseBasicParsing

    # Anchored on the whole file name: the release also carries the package
    # manager builds, whose names end in the same architecture and extension.
    $expectedLine = Select-String -Path $checksumsPath -Pattern ('\s\*?' + [regex]::Escape($asset) + '$') | Select-Object -First 1
    if (-not $expectedLine) {
        throw "no checksum entry found for $asset in checksums.txt"
    }
    $expected = ($expectedLine.Line -split '\s+')[0]
    $actual = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash

    if ($actual.ToLower() -ne $expected.ToLower()) {
        throw "checksum mismatch for ${asset}: expected $expected, got $actual"
    }

    $extractDir = Join-Path $workDir 'extracted'
    Expand-Archive -Path $archivePath -DestinationPath $extractDir -Force

    $binary = Get-ChildItem -Path $extractDir -Recurse -Filter 'floot.exe' | Select-Object -First 1
    if (-not $binary) {
        throw "could not find floot.exe inside $asset"
    }

    # the install directory has to stay user writable because "floot update"
    # replaces this binary in place later and must never need an elevated prompt
    $installDir = $env:FLOOT_INSTALL_DIR
    if ([string]::IsNullOrEmpty($installDir)) {
        $installDir = Join-Path $env:LOCALAPPDATA 'floot\bin'
    }
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null

    $targetPath = Join-Path $installDir 'floot.exe'
    Copy-Item -Path $binary.FullName -Destination $targetPath -Force

    # The version is taken from the tag rather than from the binary: running it
    # here would also fire its post-run check against pub.dev, on a channel that
    # does not install from there.
    Write-Host "installed floot $version to $targetPath"

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrEmpty($userPath)) { $userPath = '' }
    $pathEntries = $userPath -split ';'
    if ($pathEntries -notcontains $installDir) {
        $newPath = if ($userPath) { "$userPath;$installDir" } else { $installDir }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        $env:Path = "$env:Path;$installDir"
        Write-Host "added $installDir to your user PATH, open a new terminal for it to take effect"
    }

    Write-Host 'next: run floot login'
} finally {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}
