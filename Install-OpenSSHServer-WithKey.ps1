#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs/enables Windows OpenSSH Server and adds a pasted public key.

.DESCRIPTION
Run this script from an elevated PowerShell session on the Windows server.

For regular users, OpenSSH reads keys from:
  $HOME\.ssh\authorized_keys

For members of the local Administrators group, the default Windows OpenSSH
configuration usually reads keys from:
  C:\ProgramData\ssh\administrators_authorized_keys

This script detects that default administrator Match block and installs the
key in the location sshd will actually use for the current Windows user.
#>

[CmdletBinding()]
param(
    [string]$PublicKey,
    [switch]$NoFirewall
)

$ErrorActionPreference = "Stop"

function Test-RunningAsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Normalize-PublicKey {
    param([string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key)) {
        throw "No public key was provided."
    }

    $normalized = $Key.Trim()

    $validPrefix = @(
        "ssh-ed25519",
        "ssh-rsa",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com",
        "sk-ecdsa-sha2-nistp256@openssh.com"
    )

    $hasKnownPrefix = $false
    foreach ($prefix in $validPrefix) {
        if ($normalized.StartsWith("$prefix ")) {
            $hasKnownPrefix = $true
            break
        }
    }

    if (-not $hasKnownPrefix) {
        Write-Warning "The pasted text does not start with a common OpenSSH public key prefix."
        $answer = Read-Host "Continue anyway? Type YES to continue"
        if ($answer -ne "YES") {
            throw "Aborted because the pasted public key did not look valid."
        }
    }

    return $normalized
}

function Add-LineIfMissing {
    param(
        [string]$Path,
        [string]$Line
    )

    $existing = @()
    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -ErrorAction Stop
    }

    if ($existing -contains $Line) {
        Write-Host "Public key already exists in $Path"
        return
    }

    Add-Content -LiteralPath $Path -Value $Line -Encoding ascii
    Write-Host "Added public key to $Path"
}

function Set-UserAuthorizedKeysAcl {
    param(
        [string]$SshDirectory,
        [string]$AuthorizedKeysPath
    )

    $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $currentUserDirectoryGrant = "*${currentUserSid}:(OI)(CI)F"
    $currentUserFileGrant = "*${currentUserSid}:F"
    $systemDirectoryGrant = "*S-1-5-18:(OI)(CI)F"
    $systemFileGrant = "*S-1-5-18:F"

    icacls $SshDirectory /inheritance:r | Out-Null
    icacls $SshDirectory /grant $currentUserDirectoryGrant $systemDirectoryGrant | Out-Null

    icacls $AuthorizedKeysPath /inheritance:r | Out-Null
    icacls $AuthorizedKeysPath /grant $currentUserFileGrant $systemFileGrant | Out-Null
}

function Set-AdministratorsAuthorizedKeysAcl {
    param([string]$AuthorizedKeysPath)

    icacls $AuthorizedKeysPath /inheritance:r | Out-Null
    icacls $AuthorizedKeysPath /grant "*S-1-5-32-544:F" "*S-1-5-18:F" | Out-Null
}

function New-OpenSshFirewallRule {
    param([string]$RuleName)

    New-NetFirewallRule `
        -Name $RuleName `
        -DisplayName "OpenSSH Server (sshd)" `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -Action Allow `
        -LocalPort 22 | Out-Null
}

function Ensure-OpenSshFirewallRule {
    param([string]$RuleName)

    if (-not (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
        Write-Warning "NetSecurity firewall cmdlets are unavailable. Falling back to netsh."
        netsh advfirewall firewall delete rule name="OpenSSH Server (sshd)" | Out-Null
        netsh advfirewall firewall add rule name="OpenSSH Server (sshd)" dir=in action=allow protocol=TCP localport=22 | Out-Null
        return
    }

    $rule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue

    if ($null -eq $rule) {
        New-OpenSshFirewallRule -RuleName $RuleName
        return
    }

    if (-not (Get-Command Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)) {
        Write-Warning "Get-NetFirewallPortFilter is unavailable. Recreating managed firewall rule $RuleName."
        Remove-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
        New-OpenSshFirewallRule -RuleName $RuleName
        return
    }

    $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    $needsRecreate = (
        $null -eq $portFilter -or
        $portFilter.Protocol -ne "TCP" -or
        $portFilter.LocalPort -ne "22"
    )

    if ($needsRecreate) {
        Write-Host "Existing firewall rule has unexpected port settings. Recreating managed rule $RuleName."
        Remove-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
        New-OpenSshFirewallRule -RuleName $RuleName
        return
    }

    Set-NetFirewallRule -Name $RuleName -Enabled True -Direction Inbound -Action Allow
}

if (-not (Test-RunningAsAdministrator)) {
    throw "Run this script from PowerShell opened as Administrator."
}

Write-Host "Checking OpenSSH Server capability..."
$capabilityName = "OpenSSH.Server~~~~0.0.1.0"
$capability = Get-WindowsCapability -Online -Name $capabilityName

if ($capability.State -ne "Installed") {
    Write-Host "Installing OpenSSH Server..."
    Add-WindowsCapability -Online -Name $capabilityName | Out-Null
} else {
    Write-Host "OpenSSH Server is already installed."
}

Write-Host "Starting and enabling sshd..."
Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd

if (-not $NoFirewall) {
    Write-Host "Ensuring inbound firewall rule for TCP port 22..."
    Ensure-OpenSshFirewallRule -RuleName "OpenSSH-Server-In-TCP"
}

if ([string]::IsNullOrWhiteSpace($PublicKey)) {
    Write-Host ""
    Write-Host "Paste the OpenSSH public key to trust, then press Enter."
    Write-Host "Example: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... laptop"
    $PublicKey = [Console]::ReadLine()
}

$PublicKey = Normalize-PublicKey -Key $PublicKey

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isCurrentUserAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$sshdConfigPath = Join-Path $env:ProgramData "ssh\sshd_config"
$usesAdminAuthorizedKeys = $false

if ($isCurrentUserAdmin -and (Test-Path -LiteralPath $sshdConfigPath)) {
    $configText = Get-Content -LiteralPath $sshdConfigPath -Raw
    $usesAdminAuthorizedKeys = (
        $configText -match "(?ims)^\s*Match\s+Group\s+administrators\b.*?^\s*AuthorizedKeysFile\s+__PROGRAMDATA__/ssh/administrators_authorized_keys\b"
    )
}

if ($usesAdminAuthorizedKeys) {
    $authorizedKeysPath = Join-Path $env:ProgramData "ssh\administrators_authorized_keys"
    New-Item -ItemType Directory -Path (Split-Path -Parent $authorizedKeysPath) -Force | Out-Null
    if (-not (Test-Path -LiteralPath $authorizedKeysPath)) {
        New-Item -ItemType File -Path $authorizedKeysPath -Force | Out-Null
    }

    Add-LineIfMissing -Path $authorizedKeysPath -Line $PublicKey
    Set-AdministratorsAuthorizedKeysAcl -AuthorizedKeysPath $authorizedKeysPath
    Write-Host "Installed key for administrator logins."
} else {
    $sshDirectory = Join-Path $HOME ".ssh"
    $authorizedKeysPath = Join-Path $sshDirectory "authorized_keys"

    New-Item -ItemType Directory -Path $sshDirectory -Force | Out-Null
    if (-not (Test-Path -LiteralPath $authorizedKeysPath)) {
        New-Item -ItemType File -Path $authorizedKeysPath -Force | Out-Null
    }

    Add-LineIfMissing -Path $authorizedKeysPath -Line $PublicKey
    Set-UserAuthorizedKeysAcl -SshDirectory $sshDirectory -AuthorizedKeysPath $authorizedKeysPath
    Write-Host "Installed key for the current user: $($identity.Name)"
}

Write-Host ""
Write-Host "Done."
Write-Host "sshd status:"
Get-Service -Name sshd | Format-Table -AutoSize
Write-Host ""
Write-Host "Test from your laptop with:"
Write-Host "  ssh $($env:USERNAME)@<server-ip>"
Write-Host ""
Write-Host "For a SOCKS proxy:"
Write-Host "  ssh -N -D 1080 $($env:USERNAME)@<server-ip>"
