#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs or repairs WinGet/App Installer on Windows Server machines.

.DESCRIPTION
Run this script from an elevated PowerShell session on the Windows server.

The script first checks whether winget is already usable. If not, it tries to
register the built-in App Installer package, which is the normal path on newer
systems such as Windows Server 2025.

If winget is still unavailable, it downloads the latest official Microsoft
winget-cli release assets from GitHub. On Windows Server 2019/2022, it defaults
to v1.11.400 because newer v1.12+ releases depend on Windows App Runtime 1.8,
which is frequently unreliable on those server versions. Use -Latest to force
the newest stable release, or -ReleaseTag to pin a specific release.

Downloaded assets:
  - Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle
  - DesktopAppInstaller_Dependencies.zip
  - License XML

It then installs the dependencies, provisions App Installer for the machine,
installs/registers it for the current user, and verifies winget.
#>

[CmdletBinding()]
param(
    [string]$DownloadDirectory = (Join-Path $env:TEMP "winget-server-install"),
    [string]$Proxy,
    [string]$ReleaseTag,
    [switch]$Latest,
    [switch]$Force,
    [switch]$SkipProvisioning,
    [switch]$KeepDownloads
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Test-RunningAsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
}

function Get-WinGetCommand {
    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $windowsAppsWinget = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
    if (Test-Path -LiteralPath $windowsAppsWinget) {
        return $windowsAppsWinget
    }

    return $null
}

function Test-WinGetUsable {
    $winget = Get-WinGetCommand
    if (-not $winget) {
        return $false
    }

    try {
        $output = & $winget --version 2>$null
        return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($output | Out-String)))
    } catch {
        return $false
    }
}

function Invoke-WithOptionalProxy {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Rest", "Web")][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$OutFile
    )

    $common = @{
        Uri = $Uri
        Headers = @{ "User-Agent" = "Install-WinGetServer.ps1" }
    }

    if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
        $common.Proxy = $Proxy
    }

    if ($Kind -eq "Rest") {
        if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey("UseBasicParsing")) {
            $common.UseBasicParsing = $true
        }
        return Invoke-RestMethod @common
    }

    if ([string]::IsNullOrWhiteSpace($OutFile)) {
        throw "OutFile is required for web downloads."
    }

    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey("UseBasicParsing")) {
        $common.UseBasicParsing = $true
    }

    Invoke-WebRequest @common -OutFile $OutFile
}

function Assert-FileDigest {
    param(
        [Parameter(Mandatory = $true)]$Asset,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Asset.digest)) {
        return
    }

    if ($Asset.digest -notmatch "^sha256:(?<hash>[a-fA-F0-9]{64})$") {
        Write-Warning "Skipping unrecognized digest format for $($Asset.name): $($Asset.digest)"
        return
    }

    $expected = $Matches.hash.ToUpperInvariant()
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()

    if ($actual -ne $expected) {
        throw "SHA256 mismatch for $($Asset.name). Expected $expected, got $actual."
    }

    Write-Host "Verified SHA256 for $($Asset.name)"
}

function Get-ReleaseAssets {
    param([string]$Tag)

    if ([string]::IsNullOrWhiteSpace($Tag)) {
        Write-Step "Fetching latest official WinGet release metadata"
        $release = Invoke-WithOptionalProxy -Kind Rest -Uri "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
    } else {
        Write-Step "Fetching official WinGet release metadata for $Tag"
        $release = Invoke-WithOptionalProxy -Kind Rest -Uri "https://api.github.com/repos/microsoft/winget-cli/releases/tags/$Tag"
    }

    $bundle = $release.assets |
        Where-Object { $_.name -eq "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" } |
        Select-Object -First 1

    $dependencies = $release.assets |
        Where-Object { $_.name -eq "DesktopAppInstaller_Dependencies.zip" } |
        Select-Object -First 1

    $license = $release.assets |
        Where-Object { $_.name -match "License.*\.xml$" } |
        Select-Object -First 1

    if (-not $bundle -or -not $dependencies -or -not $license) {
        throw "The latest GitHub release did not contain the expected App Installer bundle, dependencies ZIP, and license XML."
    }

    return [pscustomobject]@{
        Tag = $release.tag_name
        Url = $release.html_url
        Bundle = $bundle
        Dependencies = $dependencies
        License = $license
    }
}

function Resolve-DefaultReleaseTag {
    param($OperatingSystem)

    $buildNumber = [int]$OperatingSystem.BuildNumber

    if ($OperatingSystem.Caption -match "Server" -and $buildNumber -lt 26100) {
        return "v1.11.400"
    }

    return $null
}

function Download-Asset {
    param(
        [Parameter(Mandatory = $true)]$Asset,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    $destination = Join-Path $DestinationDirectory $Asset.name
    if ((Test-Path -LiteralPath $destination) -and -not $Force) {
        Write-Host "Using existing download: $destination"
    } else {
        Write-Host "Downloading $($Asset.name)"
        Invoke-WithOptionalProxy -Kind Web -Uri $Asset.browser_download_url -OutFile $destination
    }

    Assert-FileDigest -Asset $Asset -Path $destination
    return $destination
}

function Get-ArchitectureToken {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { return "x64" }
        "ARM64" { return "arm64" }
        "x86" { return "x86" }
        default { return $env:PROCESSOR_ARCHITECTURE.ToLowerInvariant() }
    }
}

function Get-DependencyPackages {
    param([string]$DependenciesDirectory)

    $arch = Get-ArchitectureToken
    $packageExtensions = @(".appx", ".appxbundle", ".msix", ".msixbundle")
    $allPackages = Get-ChildItem -LiteralPath $DependenciesDirectory -Recurse -File |
        Where-Object { $packageExtensions -contains $_.Extension.ToLowerInvariant() }

    if (-not $allPackages) {
        throw "No AppX/MSIX dependency packages were found in $DependenciesDirectory"
    }

    $selected = $allPackages | Where-Object {
        $fullName = $_.FullName.ToLowerInvariant()
        $name = $_.Name.ToLowerInvariant()

        $fullName -match "\\$arch\\" -or
        $name -match "(^|[_.-])$arch([_.-]|$)" -or
        $name -match "(^|[_.-])neutral([_.-]|$)"
    }

    if (-not $selected) {
        Write-Warning "Could not confidently filter dependencies for architecture '$arch'. Installing all dependency packages from the ZIP."
        $selected = $allPackages
    }

    return @($selected | Sort-Object FullName | Select-Object -ExpandProperty FullName)
}

function Try-RegisterExistingAppInstaller {
    Write-Step "Trying to register existing App Installer package"

    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
    } catch {
        Write-Host "Register-by-family-name did not complete: $($_.Exception.Message)"
    }

    return (Test-WinGetUsable)
}

function Install-AppxPackageForCurrentUser {
    param(
        [Parameter(Mandatory = $true)][string]$BundlePath,
        [string[]]$DependencyPackagePath
    )

    $params = @{
        Path = $BundlePath
        ErrorAction = "Stop"
    }

    if ((Get-Command Add-AppxPackage).Parameters.ContainsKey("ForceApplicationShutdown")) {
        $params.ForceApplicationShutdown = $true
    }

    if ($DependencyPackagePath -and $DependencyPackagePath.Count -gt 0) {
        $params.DependencyPath = $DependencyPackagePath
    }

    Add-AppxPackage @params
}

function Install-AppxDependencyForCurrentUser {
    param([Parameter(Mandatory = $true)][string]$Path)

    $params = @{
        Path = $Path
        ErrorAction = "Stop"
    }

    if ((Get-Command Add-AppxPackage).Parameters.ContainsKey("ForceApplicationShutdown")) {
        $params.ForceApplicationShutdown = $true
    }

    Add-AppxPackage @params
}

function Provision-AppInstallerForMachine {
    param(
        [Parameter(Mandatory = $true)][string]$BundlePath,
        [Parameter(Mandatory = $true)][string]$LicensePath,
        [string[]]$DependencyPackagePath
    )

    $params = @{
        Online = $true
        PackagePath = $BundlePath
        LicensePath = $LicensePath
        ErrorAction = "Stop"
    }

    if ($DependencyPackagePath -and $DependencyPackagePath.Count -gt 0) {
        $params.DependencyPackagePath = $DependencyPackagePath
    }

    Add-AppxProvisionedPackage @params | Out-Null
}

function Invoke-WinGetSourceUpdate {
    param([Parameter(Mandatory = $true)][string]$WinGetPath)

    & $WinGetPath source update --disable-interactivity
    if ($LASTEXITCODE -eq 0) {
        return
    }

    Write-Warning "Non-interactive source update failed with exit code $LASTEXITCODE. Retrying without --disable-interactivity."
    & $WinGetPath source update
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Source update failed with exit code $LASTEXITCODE. Try manually later: winget source update"
    }
}

if (-not (Test-RunningAsAdministrator)) {
    throw "Run this script from PowerShell opened as Administrator."
}

if ($Latest -and -not [string]::IsNullOrWhiteSpace($ReleaseTag)) {
    throw "Use either -Latest or -ReleaseTag, not both."
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$os = Get-CimInstance -ClassName Win32_OperatingSystem
Write-Host "Detected OS: $($os.Caption) build $($os.BuildNumber)"

if (-not $Latest -and [string]::IsNullOrWhiteSpace($ReleaseTag)) {
    $ReleaseTag = Resolve-DefaultReleaseTag -OperatingSystem $os
    if (-not [string]::IsNullOrWhiteSpace($ReleaseTag)) {
        Write-Host "Defaulting to WinGet $ReleaseTag for this OS. Use -Latest to force the newest stable release."
    }
}

if (-not (Get-Command Add-AppxPackage -ErrorAction SilentlyContinue)) {
    throw "Add-AppxPackage is not available. WinGet/App Installer requires AppX support, which is generally unavailable on Server Core/minimal installs."
}

if (-not (Get-Command Add-AppxProvisionedPackage -ErrorAction SilentlyContinue)) {
    Write-Warning "Add-AppxProvisionedPackage is not available. The script will install for the current user only."
    $SkipProvisioning = $true
}

if ((Test-WinGetUsable) -and -not $Force) {
    Write-Step "WinGet is already usable"
    $winget = Get-WinGetCommand
    & $winget --info
    return
}

if (-not $Force) {
    if (Try-RegisterExistingAppInstaller) {
        Write-Step "WinGet is usable after App Installer registration"
        $winget = Get-WinGetCommand
        & $winget --info
        return
    }
}

$releaseAssets = Get-ReleaseAssets -Tag $ReleaseTag
Write-Host "Using release $($releaseAssets.Tag): $($releaseAssets.Url)"

$releaseDownloadDirectory = Join-Path $DownloadDirectory $releaseAssets.Tag

Write-Step "Preparing download directory"
New-Item -ItemType Directory -Path $releaseDownloadDirectory -Force | Out-Null

$bundlePath = Download-Asset -Asset $releaseAssets.Bundle -DestinationDirectory $releaseDownloadDirectory
$dependenciesZipPath = Download-Asset -Asset $releaseAssets.Dependencies -DestinationDirectory $releaseDownloadDirectory
$licensePath = Download-Asset -Asset $releaseAssets.License -DestinationDirectory $releaseDownloadDirectory

$dependenciesDirectory = Join-Path $releaseDownloadDirectory "Dependencies"
if (Test-Path -LiteralPath $dependenciesDirectory) {
    Remove-Item -LiteralPath $dependenciesDirectory -Recurse -Force
}

Write-Step "Extracting dependency packages"
Expand-Archive -LiteralPath $dependenciesZipPath -DestinationPath $dependenciesDirectory -Force
$dependencyPackagePaths = Get-DependencyPackages -DependenciesDirectory $dependenciesDirectory
$dependencyPackagePaths | ForEach-Object { Write-Host "Dependency: $_" }

Write-Step "Installing dependencies for the current user"
foreach ($dependencyPackagePath in $dependencyPackagePaths) {
    try {
        Install-AppxDependencyForCurrentUser -Path $dependencyPackagePath
    } catch {
        Write-Host "Dependency install reported: $($_.Exception.Message)"
    }
}

if (-not $SkipProvisioning) {
    Write-Step "Provisioning App Installer for the machine"
    try {
        Provision-AppInstallerForMachine -BundlePath $bundlePath -LicensePath $licensePath -DependencyPackagePath $dependencyPackagePaths
    } catch {
        Write-Warning "Machine provisioning failed: $($_.Exception.Message)"
        Write-Warning "Continuing with current-user installation."
    }
}

Write-Step "Installing App Installer for the current user"
Install-AppxPackageForCurrentUser -BundlePath $bundlePath -DependencyPackagePath $dependencyPackagePaths

Write-Step "Registering App Installer package"
try {
    Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
} catch {
    Write-Host "Register-by-family-name reported: $($_.Exception.Message)"
}

if (-not (Test-WinGetUsable)) {
    throw "Installation completed, but winget is still not usable in this session. Open a new PowerShell window and run: winget --info"
}

$winget = Get-WinGetCommand
Write-Step "WinGet installed successfully"
& $winget --info

Write-Step "Updating WinGet sources"
Invoke-WinGetSourceUpdate -WinGetPath $winget

if (-not $KeepDownloads) {
    Write-Step "Cleaning downloaded files"
    Remove-Item -LiteralPath $releaseDownloadDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Done. Open a new PowerShell session if winget is not immediately available on PATH."
Write-Host "Test with:"
Write-Host "  winget --info"
