#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs PM2 as a Windows service using the upstream pm2-installer project.

.DESCRIPTION
Interactive runs ask which Node.js installation to use and whether the PM2
service should run as the current user (recommended) or LocalService.

.PARAMETER NodePath
Optional path to node.exe. When omitted, the script displays detected Node.js
installations and defaults to C:\Program Files\nodejs\node.exe when present.

.PARAMETER ServiceAccount
Optional non-interactive account selection: CurrentUser or LocalService.

.PARAMETER ServiceCredential
Credential for CurrentUser mode. Windows services require the account password;
a Windows Hello PIN cannot be used.
#>

[CmdletBinding()]
param(
    [string] $NodePath,

    [ValidateSet('CurrentUser', 'LocalService')]
    [string] $ServiceAccount,

    [PSCredential] $ServiceCredential
)

$ErrorActionPreference = 'Stop'

$pm2InstallerVersion = '3.4.3'
$pm2InstallerCommit = 'e5315225c26ef4d77b29ed65d4ccc33fc75691c3'
$pm2InstallerArchiveSha256 = '16bbe2740f86c7f90cbe46bccbcc631eca50a32f57d2108a42010ef8f7dad0e9'
$pm2InstallerUrl = "https://github.com/jessety/pm2-installer/archive/$pm2InstallerCommit.zip"
$pm2InstallerRoot = Join-Path $env:ProgramData "Remed\pm2-installer-$pm2InstallerVersion"
$npmRoot = Join-Path $env:ProgramData 'npm'
$npmPrefix = Join-Path $npmRoot 'npm'
$pm2Home = Join-Path $env:ProgramData 'pm2\home'
$pm2ServiceDirectory = Join-Path $env:ProgramData 'pm2\service'
$unsetEnvironmentMarker = '__REMED_UNSET__'

function Get-CanonicalPath {
    param([Parameter(Mandatory)] [string] $Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-NodeCandidates {
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $preferredNode = 'C:\Program Files\nodejs\node.exe'

    foreach ($candidate in @(
        $preferredNode,
        "${env:ProgramFiles(x86)}\nodejs\node.exe",
        'C:\nodejs\node.exe'
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            [void]$paths.Add((Get-CanonicalPath -Path $candidate))
        }
    }

    foreach ($command in Get-Command node.exe -All -ErrorAction SilentlyContinue) {
        if ($command.Source -and (Test-Path -LiteralPath $command.Source)) {
            [void]$paths.Add((Get-CanonicalPath -Path $command.Source))
        }
    }

    foreach ($registryRoot in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        Get-ItemProperty -Path $registryRoot -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '^Node\.js' -and $_.InstallLocation } |
            ForEach-Object {
                $candidate = Join-Path $_.InstallLocation 'node.exe'
                if (Test-Path -LiteralPath $candidate) {
                    [void]$paths.Add((Get-CanonicalPath -Path $candidate))
                }
            }
    }

    $preferredCanonical = Get-CanonicalPath -Path $preferredNode
    return @($paths | Sort-Object @{ Expression = { if ($_ -ieq $preferredCanonical) { 0 } else { 1 } } }, @{ Expression = { $_ } })
}

function Test-NodeInstallation {
    param([Parameter(Mandatory)] [string] $Candidate)

    if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
        throw "Node.js executable was not found: $Candidate"
    }

    $nodeDirectory = Split-Path -Parent $Candidate
    $npmCommand = Join-Path $nodeDirectory 'npm.cmd'
    if (-not (Test-Path -LiteralPath $npmCommand -PathType Leaf)) {
        throw "The selected Node.js installation does not contain npm.cmd: $nodeDirectory"
    }

    $versionOutput = @(& $Candidate --version 2>&1)
    $nodeExitCode = $LASTEXITCODE
    $version = $versionOutput | Select-Object -First 1
    if ($nodeExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($version)) {
        throw "The selected Node.js executable could not report its version: $Candidate"
    }

    return [PSCustomObject]@{
        NodePath = Get-CanonicalPath -Path $Candidate
        NodeDirectory = Get-CanonicalPath -Path $nodeDirectory
        NpmCommand = Get-CanonicalPath -Path $npmCommand
        Version = [string] $version
    }
}

function Select-NodeInstallation {
    param([string] $RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        return Test-NodeInstallation -Candidate $RequestedPath
    }

    $candidates = @(Get-NodeCandidates)
    if ($candidates.Count -eq 0) {
        $customPath = Read-Host 'No Node.js installations were detected. Enter the full path to node.exe'
        return Test-NodeInstallation -Candidate $customPath
    }

    Write-Host 'Detected Node.js installations:'
    for ($index = 0; $index -lt $candidates.Count; $index++) {
        try {
            $candidate = Test-NodeInstallation -Candidate $candidates[$index]
            Write-Host "  [$($index + 1)] $($candidate.NodePath) ($($candidate.Version))"
        } catch {
            Write-Host "  [$($index + 1)] $($candidates[$index]) (unusable: $($_.Exception.Message))"
        }
    }

    Write-Host '  [C] Enter a custom node.exe path'
    while ($true) {
        $selection = Read-Host 'Select Node.js [1]'
        if ([string]::IsNullOrWhiteSpace($selection)) {
            $selection = '1'
        }

        if ($selection -ieq 'c') {
            $customPath = Read-Host 'Enter the full path to node.exe'
            return Test-NodeInstallation -Candidate $customPath
        }

        $selectedIndex = 0
        if ([int]::TryParse($selection, [ref] $selectedIndex) -and
            $selectedIndex -ge 1 -and $selectedIndex -le $candidates.Count) {
            return Test-NodeInstallation -Candidate $candidates[$selectedIndex - 1]
        }

        Write-Warning "Choose a number from 1 to $($candidates.Count), or C for a custom path."
    }
}

function Select-ServiceAccountMode {
    param([string] $RequestedMode)

    if (-not [string]::IsNullOrWhiteSpace($RequestedMode)) {
        return $RequestedMode
    }

    Write-Host ''
    Write-Host 'Choose the Windows service account:'
    Write-Host '  [1] Current user - simplest PM2 administration; recommended'
    Write-Host '  [2] LocalService - isolated built-in account; advanced'

    while ($true) {
        $selection = Read-Host 'Select service account [1]'
        if ([string]::IsNullOrWhiteSpace($selection) -or $selection -eq '1') {
            return 'CurrentUser'
        }
        if ($selection -eq '2') {
            return 'LocalService'
        }

        Write-Warning 'Choose 1 for Current user or 2 for LocalService.'
    }
}

function Get-CurrentUserServiceCredential {
    param([PSCredential] $RequestedCredential)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentAccount = $identity.Name
    $credential = $RequestedCredential
    if (-not $credential) {
        Write-Host ''
        Write-Host "The service will run as $currentAccount."
        Write-Host 'Windows requires the account password for a service logon; a Windows Hello PIN will not work.'
        Write-Host 'If this password changes later, update the password on the PM2 service Log On tab.'
        $credential = Get-Credential -UserName $currentAccount -Message 'Enter the password for the current Windows account.'
    }

    if (-not $credential) {
        throw 'A credential is required when the service runs as the current user.'
    }

    try {
        $credentialSid = ([Security.Principal.NTAccount] $credential.UserName).
            Translate([Security.Principal.SecurityIdentifier]).Value
    } catch {
        throw "Could not resolve credential account '$($credential.UserName)' to a Windows security identifier."
    }

    if ($credentialSid -ne $identity.User.Value) {
        throw "The supplied credential belongs to '$($credential.UserName)', not the current user '$currentAccount'."
    }

    return $credential
}

function Grant-LogOnAsServiceRight {
    param([Parameter(Mandatory)] [string] $Sid)

    if (-not ('RemedServiceAccountRights' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

public static class RemedServiceAccountRights
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LSA_OBJECT_ATTRIBUTES
    {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LSA_UNICODE_STRING
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern uint LsaOpenPolicy(
        IntPtr systemName,
        ref LSA_OBJECT_ATTRIBUTES objectAttributes,
        uint desiredAccess,
        out IntPtr policyHandle);

    [DllImport("advapi32.dll")]
    private static extern uint LsaAddAccountRights(
        IntPtr policyHandle,
        IntPtr accountSid,
        LSA_UNICODE_STRING[] userRights,
        uint countOfRights);

    [DllImport("advapi32.dll")]
    private static extern uint LsaNtStatusToWinError(uint status);

    [DllImport("advapi32.dll")]
    private static extern uint LsaClose(IntPtr policyHandle);

    public static void GrantLogOnAsService(string sidValue)
    {
        const uint POLICY_CREATE_ACCOUNT = 0x00000010;
        const uint POLICY_LOOKUP_NAMES = 0x00000800;

        var attributes = new LSA_OBJECT_ATTRIBUTES();
        attributes.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));

        IntPtr policyHandle;
        uint status = LsaOpenPolicy(
            IntPtr.Zero,
            ref attributes,
            POLICY_CREATE_ACCOUNT | POLICY_LOOKUP_NAMES,
            out policyHandle);
        ThrowIfFailed(status, "open the local security policy");

        IntPtr sidPointer = IntPtr.Zero;
        IntPtr rightBuffer = IntPtr.Zero;
        try
        {
            var sid = new SecurityIdentifier(sidValue);
            var sidBytes = new byte[sid.BinaryLength];
            sid.GetBinaryForm(sidBytes, 0);
            sidPointer = Marshal.AllocHGlobal(sidBytes.Length);
            Marshal.Copy(sidBytes, 0, sidPointer, sidBytes.Length);

            const string rightName = "SeServiceLogonRight";
            rightBuffer = Marshal.StringToHGlobalUni(rightName);
            var right = new LSA_UNICODE_STRING
            {
                Buffer = rightBuffer,
                Length = (ushort)(rightName.Length * sizeof(char)),
                MaximumLength = (ushort)((rightName.Length + 1) * sizeof(char))
            };

            status = LsaAddAccountRights(policyHandle, sidPointer, new[] { right }, 1);
            ThrowIfFailed(status, "grant Log on as a service");
        }
        finally
        {
            if (rightBuffer != IntPtr.Zero) Marshal.FreeHGlobal(rightBuffer);
            if (sidPointer != IntPtr.Zero) Marshal.FreeHGlobal(sidPointer);
            LsaClose(policyHandle);
        }
    }

    private static void ThrowIfFailed(uint status, string operation)
    {
        if (status == 0) return;
        int error = (int)LsaNtStatusToWinError(status);
        throw new Win32Exception(error, "Could not " + operation + ".");
    }
}
'@
    }

    [RemedServiceAccountRights]::GrantLogOnAsService($Sid)
}

function Install-PinnedPm2Installer {
    $packageJson = Join-Path $pm2InstallerRoot 'package.json'
    $commitMarker = Join-Path $pm2InstallerRoot '.remed-pinned-commit'
    if ((Test-Path -LiteralPath $packageJson) -and (Test-Path -LiteralPath $commitMarker)) {
        try {
            $package = Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
            $installedCommit = (Get-Content -LiteralPath $commitMarker -Raw).Trim()
            if ($package.name -eq 'pm2-installer' -and $package.version -eq $pm2InstallerVersion -and
                $installedCommit -eq $pm2InstallerCommit) {
                Write-Host "Using existing pm2-installer $pm2InstallerVersion at $pm2InstallerRoot."
                return
            }
        } catch {
            Write-Warning "The existing pm2-installer directory is invalid and will be replaced: $pm2InstallerRoot"
        }
    }

    $downloadRoot = Join-Path $env:TEMP "remed-pm2-installer-$([Guid]::NewGuid().ToString('N'))"
    $archivePath = Join-Path $downloadRoot 'pm2-installer.zip'
    $extractRoot = Join-Path $downloadRoot 'extracted'
    New-Item -ItemType Directory -Force -Path $downloadRoot, $extractRoot | Out-Null

    try {
        Write-Host "Downloading pm2-installer $pm2InstallerVersion from its pinned upstream commit."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $pm2InstallerUrl -OutFile $archivePath -UseBasicParsing

        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        if ($actualHash -ne $pm2InstallerArchiveSha256) {
            throw "pm2-installer archive checksum mismatch. Expected $pm2InstallerArchiveSha256, received $actualHash."
        }

        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
        $extractedDirectory = Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1
        if (-not $extractedDirectory -or -not (Test-Path -LiteralPath (Join-Path $extractedDirectory.FullName 'package.json'))) {
            throw 'The pm2-installer archive did not contain the expected project directory.'
        }

        if (Test-Path -LiteralPath $pm2InstallerRoot) {
            Remove-Item -LiteralPath $pm2InstallerRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pm2InstallerRoot) | Out-Null
        Move-Item -LiteralPath $extractedDirectory.FullName -Destination $pm2InstallerRoot
        Set-Content -LiteralPath $commitMarker -Value $pm2InstallerCommit -Encoding Ascii
        Get-ChildItem -LiteralPath $pm2InstallerRoot -File -Recurse | Unblock-File
    } finally {
        if (Test-Path -LiteralPath $downloadRoot) {
            Remove-Item -LiteralPath $downloadRoot -Recurse -Force
        }
    }
}

function Assert-NoExistingPm2Service {
    $existingServices = @(Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('PM2', 'pm2.exe') -or $_.DisplayName -eq 'PM2' })
    if ($existingServices.Count -gt 0) {
        $names = $existingServices.Name -join ', '
        throw "An existing PM2 Windows service was found ($names). Run .\uninstall-pm2-windows-service.ps1 first, then retry v2 setup."
    }
}

function Add-AccountDirectoryAccess {
    param([Parameter(Mandatory)] [string] $Account)

    foreach ($directory in @($npmRoot, (Split-Path -Parent $pm2Home))) {
        if (Test-Path -LiteralPath $directory) {
            & icacls.exe $directory /grant "${Account}:(OI)(CI)F" /T /C | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Could not grant $Account access to $directory."
            }
        }
    }
}

function Set-AdminPm2Environment {
    foreach ($name in @('PM2_HOME', 'PM2_SERVICE_PM2_DIR')) {
        $backupName = "REMED_PM2_PREVIOUS_USER_$name"
        if ($null -eq [Environment]::GetEnvironmentVariable($backupName, 'User')) {
            $previousValue = [Environment]::GetEnvironmentVariable($name, 'User')
            if ($null -eq $previousValue) {
                $previousValue = $unsetEnvironmentMarker
            }
            [Environment]::SetEnvironmentVariable($backupName, $previousValue, 'User')
        }
    }

    # A user-scoped value wins over pm2-installer's machine-scoped PM2_HOME.
    # Align it so an ordinary terminal controls the same daemon as the service.
    [Environment]::SetEnvironmentVariable('PM2_HOME', $pm2Home, 'User')
    [Environment]::SetEnvironmentVariable('PM2_SERVICE_PM2_DIR', $null, 'User')
}

function Invoke-Pm2InstallerScript {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [string[]] $Arguments = @(),
        [int] $TimeoutSeconds = 300
    )

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
        throw "Windows PowerShell was not found: $windowsPowerShell"
    }

    $processArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$ScriptPath`""
    ) + $Arguments

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $windowsPowerShell
    $startInfo.Arguments = $processArguments -join ' '
    $startInfo.WorkingDirectory = $pm2InstallerRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Could not start pm2-installer script: $ScriptPath"
    }
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        throw "pm2-installer script timed out after $TimeoutSeconds seconds: $ScriptPath"
    }
    $exitCode = $process.ExitCode
    if ($exitCode -ne 0) {
        throw "pm2-installer script failed with exit code ${exitCode}: $ScriptPath"
    }
}

function Assert-Pm2Installation {
    param(
        [Parameter(Mandatory)] [string] $ExpectedServiceAccount,
        [Parameter(Mandatory)] [string] $ExpectedNodePath
    )

    $service = Get-CimInstance Win32_Service -Filter "Name = 'pm2.exe'" -ErrorAction Stop
    if (-not $service) {
        throw 'pm2-installer did not create the expected pm2.exe Windows service.'
    }
    if ($service.State -ne 'Running') {
        throw "The pm2.exe service is not running. Current state: $($service.State)"
    }

    $expectedSid = ([Security.Principal.NTAccount] $ExpectedServiceAccount).
        Translate([Security.Principal.SecurityIdentifier]).Value
    $actualSid = ([Security.Principal.NTAccount] $service.StartName).
        Translate([Security.Principal.SecurityIdentifier]).Value
    if ($actualSid -ne $expectedSid) {
        throw "The pm2.exe service runs as '$($service.StartName)', expected '$ExpectedServiceAccount'."
    }

    foreach ($requiredPath in @(
        (Join-Path $npmPrefix 'pm2.cmd'),
        (Join-Path $npmPrefix 'node_modules\pm2'),
        $pm2Home,
        $pm2ServiceDirectory
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "PM2 installation is incomplete; required path is missing: $requiredPath"
        }
    }

    $serviceConfig = Get-ChildItem -LiteralPath $pm2ServiceDirectory -Filter '*.xml' -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $serviceConfig) {
        throw "The node-windows service XML is missing from $pm2ServiceDirectory."
    }
    $configText = Get-Content -LiteralPath $serviceConfig.FullName -Raw
    if ($configText -notmatch [Regex]::Escape($ExpectedNodePath)) {
        throw "The PM2 service does not reference the selected Node.js executable: $ExpectedNodePath"
    }

    $env:PM2_HOME = $pm2Home
    & (Join-Path $npmPrefix 'pm2.cmd') ping
    if ($LASTEXITCODE -ne 0) {
        throw 'The PM2 CLI could not reach the service-owned daemon.'
    }
}

$priorLocation = (Get-Location).Path
$priorPath = $env:Path
$priorServiceAccount = $env:PM2_SERVICE_ACCOUNT
$priorServicePassword = $env:PM2_SERVICE_ACCOUNT_PASSWORD
$priorPm2Home = $env:PM2_HOME
$priorPm2InstallDirectory = $env:PM2_INSTALL_DIRECTORY
$priorPm2ServiceDirectory = $env:PM2_SERVICE_DIRECTORY

try {
    $node = Select-NodeInstallation -RequestedPath $NodePath
    $accountMode = Select-ServiceAccountMode -RequestedMode $ServiceAccount
    Assert-NoExistingPm2Service

    $serviceAccountName = $null
    $servicePassword = ''
    if ($accountMode -eq 'CurrentUser') {
        $credential = Get-CurrentUserServiceCredential -RequestedCredential $ServiceCredential
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $serviceAccountName = $currentIdentity.Name
        $servicePassword = $credential.GetNetworkCredential().Password
        Write-Host "Granting 'Log on as a service' to $serviceAccountName."
        Grant-LogOnAsServiceRight -Sid $currentIdentity.User.Value
    } else {
        $localServiceSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-19')
        $serviceAccountName = $localServiceSid.Translate([Security.Principal.NTAccount]).Value
    }

    Write-Host ''
    Write-Host 'PM2 v2 configuration:'
    Write-Host "  pm2-installer: $pm2InstallerVersion ($pm2InstallerCommit)"
    Write-Host "  Node.js:       $($node.NodePath) ($($node.Version))"
    Write-Host "  Service user:  $serviceAccountName ($accountMode)"
    Write-Host "  PM2 home:      $pm2Home"

    Install-PinnedPm2Installer

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($node.NodeDirectory, $npmPrefix, $machinePath, $userPath) -join ';'
    $resolvedNode = (Get-Command node.exe -ErrorAction Stop).Source
    if ((Get-CanonicalPath -Path $resolvedNode) -ne $node.NodePath) {
        throw "Could not activate the selected Node.js installation. Resolved node.exe: $resolvedNode"
    }

    $env:PM2_SERVICE_ACCOUNT = $serviceAccountName
    $env:PM2_SERVICE_ACCOUNT_PASSWORD = $servicePassword

    Set-Location $pm2InstallerRoot
    Write-Host 'Configuring the machine-wide npm directories through pm2-installer.'
    Invoke-Pm2InstallerScript -ScriptPath (Join-Path $pm2InstallerRoot 'src\windows\configure-setup.ps1') `
        -Arguments @('-Directory', "`"$npmRoot`"")

    Write-Host 'Installing PM2 packages through pm2-installer.'
    Invoke-Pm2InstallerScript -ScriptPath (Join-Path $pm2InstallerRoot 'src\windows\setup-packages.ps1') `
        -TimeoutSeconds 600
    foreach ($requiredPackage in @('pm2', 'node-windows')) {
        $packagePath = Join-Path $npmPrefix "node_modules\$requiredPackage"
        if (-not (Test-Path -LiteralPath $packagePath)) {
            throw "pm2-installer did not install required package: $requiredPackage"
        }
    }

    # pm2-installer grants these directories to LocalService internally. Give
    # the installing admin access as well so their normal terminal can manage
    # the same PM2 daemon, regardless of the selected service account.
    New-Item -ItemType Directory -Force -Path $pm2Home, $pm2ServiceDirectory | Out-Null
    $adminAccountName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Add-AccountDirectoryAccess -Account $adminAccountName
    Set-AdminPm2Environment

    # Child PowerShell processes do not inherit machine-environment changes made
    # by earlier children. Set the selected v2 values explicitly for every
    # remaining pm2-installer phase, especially logrotate.
    $env:PM2_HOME = $pm2Home
    $env:PM2_INSTALL_DIRECTORY = Join-Path $npmPrefix 'node_modules\pm2'
    $env:PM2_SERVICE_DIRECTORY = $pm2ServiceDirectory

    Write-Host 'Creating the PM2 Windows service through pm2-installer.'
    Invoke-Pm2InstallerScript -ScriptPath (Join-Path $pm2InstallerRoot 'src\windows\setup-service.ps1') `
        -Arguments @(
            '-PM2_HOME', "`"$pm2Home`"",
            '-PM2_SERVICE_DIRECTORY', "`"$pm2ServiceDirectory`""
        ) -TimeoutSeconds 120

    Add-AccountDirectoryAccess -Account $adminAccountName

    Write-Host 'Installing PM2 log rotation through pm2-installer.'
    Invoke-Pm2InstallerScript -ScriptPath (Join-Path $pm2InstallerRoot 'src\windows\setup-logrotate.ps1')

    [Environment]::SetEnvironmentVariable('REMED_PM2_INSTALLER_DIRECTORY', $pm2InstallerRoot, 'Machine')
    [Environment]::SetEnvironmentVariable('REMED_PM2_NODE_PATH', $node.NodePath, 'Machine')
    [Environment]::SetEnvironmentVariable('REMED_PM2_SERVICE_ACCOUNT', $accountMode, 'Machine')

    Assert-Pm2Installation -ExpectedServiceAccount $serviceAccountName -ExpectedNodePath $node.NodePath

    Write-Host ''
    Write-Host 'PM2 v2 installation completed successfully.'
    Write-Host 'Open a new terminal before using pm2 so it receives the machine PM2_HOME and PATH values.'
} finally {
    Set-Location $priorLocation
    $env:Path = $priorPath
    $env:PM2_SERVICE_ACCOUNT = $priorServiceAccount
    $env:PM2_SERVICE_ACCOUNT_PASSWORD = $priorServicePassword
    $env:PM2_HOME = $priorPm2Home
    $env:PM2_INSTALL_DIRECTORY = $priorPm2InstallDirectory
    $env:PM2_SERVICE_DIRECTORY = $priorPm2ServiceDirectory
    $servicePassword = $null
}
