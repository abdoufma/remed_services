#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]] $Pm2Arguments
)

$ErrorActionPreference = 'Stop'

$serviceName = 'PM2'
$pm2Cli = 'C:\node-global\pm2-cli.cmd'
$daemonStartTimeout = [TimeSpan]::FromSeconds(30)

function Test-IsAdministrator {
    return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Pm2Service {
    return Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $serviceName -or $_.DisplayName -eq $serviceName } |
        Select-Object -First 1
}

function Get-Pm2DaemonProcesses {
    return Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '\\node_modules\\pm2\\lib\\Daemon\.js' }
}

function Get-ServiceAccountSid {
    param([Parameter(Mandatory)] [string] $AccountName)

    switch -Regex ($AccountName) {
        '^(LocalSystem|NT AUTHORITY\\SYSTEM|\.\\LocalSystem)$' { return 'S-1-5-18' }
        '^(NT AUTHORITY\\LocalService|\.\\LocalService)$' { return 'S-1-5-19' }
        '^(NT AUTHORITY\\NetworkService|\.\\NetworkService)$' { return 'S-1-5-20' }
        default {
            return ([Security.Principal.NTAccount] $AccountName).
                Translate([Security.Principal.SecurityIdentifier]).Value
        }
    }
}

function Get-ProcessOwnerSid {
    param([Parameter(Mandatory)] $Process)

    $owner = Invoke-CimMethod -InputObject $Process -MethodName GetOwnerSid
    if ($owner.ReturnValue -ne 0 -or [string]::IsNullOrWhiteSpace($owner.Sid)) {
        throw "Could not determine the owner of PM2 daemon PID $($Process.ProcessId)."
    }

    return $owner.Sid
}

function Remove-ForeignPm2Daemons {
    param([Parameter(Mandatory)] [string] $ExpectedOwnerSid)

    $removed = $false
    foreach ($daemon in @(Get-Pm2DaemonProcesses)) {
        $ownerSid = Get-ProcessOwnerSid -Process $daemon
        if (-not $ownerSid.Equals($ExpectedOwnerSid, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "Stopping PM2 daemon PID $($daemon.ProcessId) because it is not owned by the Windows service account."
            Stop-Process -Id $daemon.ProcessId -Force
            $removed = $true
        }
    }

    return $removed
}

function Wait-Pm2Daemon {
    param([Parameter(Mandatory)] [string] $ExpectedOwnerSid)

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        foreach ($daemon in @(Get-Pm2DaemonProcesses)) {
            if ((Get-ProcessOwnerSid -Process $daemon) -eq $ExpectedOwnerSid) {
                return $daemon
            }
        }

        Start-Sleep -Milliseconds 250
    } while ($stopwatch.Elapsed -lt $daemonStartTimeout)

    return $null
}

if (-not (Test-IsAdministrator)) {
    throw 'Run PM2 from an elevated PowerShell or Command Prompt. The PM2 daemon is owned by the Windows service.'
}

if (-not (Test-Path -LiteralPath $pm2Cli)) {
    throw "The service-safe PM2 CLI was not found: $pm2Cli. Re-run setup-pm2-windows-service.ps1."
}

$service = Get-Pm2Service
if (-not $service) {
    throw "The $serviceName Windows service is not installed. Re-run setup-pm2-windows-service.ps1."
}

$escapedServiceName = $service.Name.Replace("'", "''")
$serviceDetails = Get-CimInstance Win32_Service -Filter "Name = '$escapedServiceName'"
if (-not $serviceDetails) {
    throw "Could not read the Windows service account for $($service.Name)."
}
$serviceAccountSid = Get-ServiceAccountSid -AccountName $serviceDetails.StartName

$command = if ($Pm2Arguments.Count -gt 0) { $Pm2Arguments[0].ToLowerInvariant() } else { '' }
if ($command -eq 'update') {
    throw 'pm2 update is disabled for the service-managed daemon because it would recreate the daemon as the interactive user. Re-run setup-pm2-windows-service.ps1 to update PM2 safely.'
}

if ($command -eq 'kill') {
    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name $service.Name -Force
        $service.WaitForStatus('Stopped', $daemonStartTimeout)
    }

    foreach ($daemon in @(Get-Pm2DaemonProcesses)) {
        Stop-Process -Id $daemon.ProcessId -Force
    }

    Write-Host "The $($service.Name) Windows service and its PM2 daemon are stopped."
    exit 0
}

if ($service.Status -ne 'Running') {
    Start-Service -Name $service.Name
    $service.WaitForStatus('Running', $daemonStartTimeout)
}

$foreignDaemonRemoved = Remove-ForeignPm2Daemons -ExpectedOwnerSid $serviceAccountSid
$daemon = Wait-Pm2Daemon -ExpectedOwnerSid $serviceAccountSid
if ($foreignDaemonRemoved -or -not $daemon) {
    Write-Host 'Restarting the PM2 service to restore its service-owned daemon.'
    Restart-Service -Name $service.Name -Force
    (Get-Service -Name $service.Name).WaitForStatus('Running', $daemonStartTimeout)
    $daemon = Wait-Pm2Daemon -ExpectedOwnerSid $serviceAccountSid
}

if (-not $daemon) {
    throw "The $($service.Name) service did not start its PM2 daemon within $($daemonStartTimeout.TotalSeconds) seconds."
}

& $pm2Cli @Pm2Arguments
exit $LASTEXITCODE
