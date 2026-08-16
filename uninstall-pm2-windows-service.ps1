#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Removes Remed PM2 Windows service installations created by either setup script.

.PARAMETER RemoveData
Also removes PM2 state, saved process lists, and logs from C:\pm2 and
C:\ProgramData\pm2. Application data is retained by default.

.EXAMPLE
.\uninstall-pm2-windows-service.ps1 -WhatIf

.EXAMPLE
.\uninstall-pm2-windows-service.ps1

.EXAMPLE
.\uninstall-pm2-windows-service.ps1 -RemoveData
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $RemoveData
)

$ErrorActionPreference = 'Stop'

$v1NpmPrefix = 'C:\node-global'
$v1Pm2Root = 'C:\pm2'
$v1Pm2Home = 'C:\pm2\.pm2'
$v2NpmRoot = Join-Path $env:ProgramData 'npm'
$v2NpmPrefix = Join-Path $v2NpmRoot 'npm'
$v2NpmCache = Join-Path $v2NpmRoot 'npm-cache'
$v2Pm2Root = Join-Path $env:ProgramData 'pm2'
$v2Pm2Home = Join-Path $v2Pm2Root 'home'
$v2ServiceDirectory = Join-Path $v2Pm2Root 'service'
$defaultV2InstallerDirectory = Join-Path $env:ProgramData 'Remed\pm2-installer-3.4.3'
$unsetEnvironmentMarker = '__REMED_UNSET__'
$log = Join-Path $PSScriptRoot 'uninstall-pm2-windows-service-machine.log'

function Test-SamePath {
    param(
        [string] $Left,
        [string] $Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }

    try {
        return [IO.Path]::GetFullPath($Left).TrimEnd('\').Equals(
            [IO.Path]::GetFullPath($Right).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )
    } catch {
        return $false
    }
}

function Get-Pm2WindowsServices {
    return @(Get-Service -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @('PM2', 'pm2.exe') -or $_.DisplayName -eq 'PM2'
        })
}

function Remove-Pm2WindowsServices {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    foreach ($service in @(Get-Pm2WindowsServices)) {
        if ($service.Status -ne 'Stopped' -and $PSCmdlet.ShouldProcess($service.Name, 'Stop PM2 Windows service')) {
            Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
            try {
                $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
            } catch {
                Write-Warning "The $($service.Name) service did not report a stopped state within 30 seconds."
            }
        }

        if ($PSCmdlet.ShouldProcess($service.Name, 'Delete PM2 Windows service')) {
            & sc.exe delete $service.Name | Out-Host
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1060) {
                throw "sc.exe could not delete service '$($service.Name)' (exit code $LASTEXITCODE)."
            }
        }
    }
}

function Wait-Pm2WindowsServicesRemoved {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (@(Get-Pm2WindowsServices).Count -eq 0) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    } while ($stopwatch.Elapsed -lt [TimeSpan]::FromSeconds(30))

    return $false
}

function Stop-InstalledPm2Processes {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @('node.exe', 'pm2.exe') -and
            $_.CommandLine -match '(?i)(C:\\node-global|C:\\ProgramData\\npm\\npm\\node_modules\\pm2|C:\\ProgramData\\pm2|PM2_HOME)'
        }

    foreach ($process in @($processes)) {
        if ($PSCmdlet.ShouldProcess("PID $($process.ProcessId)", 'Stop installed PM2 process')) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

function Find-NpmCommand {
    $rememberedNode = [Environment]::GetEnvironmentVariable('REMED_PM2_NODE_PATH', 'Machine')
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($rememberedNode)) {
        $candidates += Join-Path (Split-Path -Parent $rememberedNode) 'npm.cmd'
    }
    $candidates += @(
        "$env:ProgramFiles\nodejs\npm.cmd",
        "${env:ProgramFiles(x86)}\nodejs\npm.cmd"
    )
    $candidates += @(Get-Command npm.cmd, npm.exe -All -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Source })

    return @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -Unique | Select-Object -First 1)
}

function Remove-Pm2Packages {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $npm = Find-NpmCommand
    if (-not $npm) {
        Write-Warning 'npm.cmd was not found; known PM2 package files will be removed directly.'
        return
    }

    foreach ($prefix in @($v1NpmPrefix, $v2NpmPrefix)) {
        if (-not (Test-Path -LiteralPath $prefix)) {
            continue
        }

        foreach ($packageName in @('pm2', 'pm2-windows-service', 'pm2-win-service', '@jessety/pm2-logrotate', 'node-windows')) {
            if ($PSCmdlet.ShouldProcess("$packageName in $prefix", 'Uninstall global npm package')) {
                & $npm uninstall --global --prefix $prefix --loglevel=error --no-audit --no-fund $packageName
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "npm could not uninstall $packageName from $prefix (exit code $LASTEXITCODE)."
                }
            }
        }
    }

    $configuredPrefix = (& $npm config --global get prefix 2>$null | Select-Object -Last 1)
    if ((Test-SamePath -Left $configuredPrefix -Right $v1NpmPrefix) -or
        (Test-SamePath -Left $configuredPrefix -Right $v2NpmPrefix)) {
        if ($PSCmdlet.ShouldProcess('global npm prefix configuration', "Remove $configuredPrefix")) {
            & $npm config --global delete prefix
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "npm could not clear its global prefix (exit code $LASTEXITCODE)."
            }
        }
    }

    $configuredCache = (& $npm config --global get cache 2>$null | Select-Object -Last 1)
    if ((Test-SamePath -Left $configuredCache -Right $v2NpmCache) -and
        $PSCmdlet.ShouldProcess('global npm cache configuration', "Remove $configuredCache")) {
        & $npm config --global delete cache
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "npm could not clear its global cache (exit code $LASTEXITCODE)."
        }
    }
}

function Remove-KnownInstallationFiles {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $paths = @(
        (Join-Path $v1NpmPrefix 'node_modules\pm2'),
        (Join-Path $v1NpmPrefix 'node_modules\pm2-windows-service'),
        (Join-Path $v1NpmPrefix 'node_modules\pm2-win-service'),
        (Join-Path $v1NpmPrefix 'pm2'),
        (Join-Path $v1NpmPrefix 'pm2.cmd'),
        (Join-Path $v1NpmPrefix 'pm2.ps1'),
        (Join-Path $v1NpmPrefix 'pm2-cli.cmd'),
        (Join-Path $v1NpmPrefix 'pm2-service-cli.ps1'),
        (Join-Path $v1NpmPrefix 'pm2-service-install'),
        (Join-Path $v1NpmPrefix 'pm2-service-install.cmd'),
        (Join-Path $v1NpmPrefix 'pm2-service-install.ps1'),
        (Join-Path $v1NpmPrefix 'pm2-service-uninstall'),
        (Join-Path $v1NpmPrefix 'pm2-service-uninstall.cmd'),
        (Join-Path $v1NpmPrefix 'pm2-service-uninstall.ps1'),
        (Join-Path $v1NpmPrefix 'node.exe'),
        $v2ServiceDirectory,
        (Join-Path $v2NpmPrefix 'node_modules\pm2'),
        (Join-Path $v2NpmPrefix 'node_modules\node-windows'),
        (Join-Path $v2NpmPrefix 'node_modules\@jessety\pm2-logrotate'),
        (Join-Path $v2NpmPrefix 'pm2'),
        (Join-Path $v2NpmPrefix 'pm2.cmd'),
        (Join-Path $v2NpmPrefix 'pm2.ps1'),
        $v2NpmCache,
        $defaultV2InstallerDirectory
    )

    foreach ($path in $paths) {
        if ((Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, 'Remove PM2 installation artifact')) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }

    foreach ($directory in @(
        (Join-Path $v1NpmPrefix 'node_modules'),
        (Join-Path $v2NpmPrefix 'node_modules\@jessety'),
        (Join-Path $v2NpmPrefix 'node_modules'),
        $v1NpmPrefix,
        $v2NpmPrefix,
        $v2NpmRoot,
        (Split-Path -Parent $defaultV2InstallerDirectory)
    )) {
        if (Test-Path -LiteralPath $directory) {
            $remaining = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0 -and $PSCmdlet.ShouldProcess($directory, 'Remove empty installation directory')) {
                Remove-Item -LiteralPath $directory -Force
            } elseif ($remaining.Count -gt 0 -and $directory -in @($v1NpmPrefix, $v2NpmPrefix)) {
                Write-Host "$directory was retained because it contains non-PM2 files."
            }
        }
    }
}

function Remove-Pm2Environment {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $pathValues = @(
        $v1Pm2Home,
        $v2Pm2Home,
        (Join-Path $v1NpmPrefix 'node_modules\pm2'),
        (Join-Path $v2NpmPrefix 'node_modules\pm2'),
        $v2ServiceDirectory
    )
    $alwaysRemove = @(
        'PM2_SERVICE_SCRIPTS',
        'PM2_SERVICE_CONFIG',
        'PM2_SERVICE_SCRIPT',
        'PM2_SERVICE_ACCOUNT',
        'PM2_SERVICE_ACCOUNT_PASSWORD',
        'REMED_PM2_INSTALLER_DIRECTORY',
        'REMED_PM2_NODE_PATH',
        'REMED_PM2_SERVICE_ACCOUNT'
    )

    foreach ($name in @('PM2_HOME', 'PM2_SERVICE_PM2_DIR')) {
        $backupName = "REMED_PM2_PREVIOUS_USER_$name"
        $backupValue = [Environment]::GetEnvironmentVariable($backupName, 'User')
        if ($null -eq $backupValue) {
            continue
        }

        $currentValue = [Environment]::GetEnvironmentVariable($name, 'User')
        $valueIsOwnedByV2 = if ($name -eq 'PM2_HOME') {
            Test-SamePath -Left $currentValue -Right $v2Pm2Home
        } else {
            [string]::IsNullOrWhiteSpace($currentValue) -or
                (Test-SamePath -Left $currentValue -Right (Join-Path $v2NpmPrefix 'node_modules\pm2'))
        }

        if ($valueIsOwnedByV2 -and $PSCmdlet.ShouldProcess("User environment variable $name", 'Restore pre-install value')) {
            $restoredValue = if ($backupValue -eq $unsetEnvironmentMarker) { $null } else { $backupValue }
            [Environment]::SetEnvironmentVariable($name, $restoredValue, 'User')
        } elseif (-not $valueIsOwnedByV2) {
            Write-Host "User environment variable $name was retained because it changed after v2 installation."
        }

        if ($PSCmdlet.ShouldProcess("User environment variable $backupName", 'Remove restoration marker')) {
            [Environment]::SetEnvironmentVariable($backupName, $null, 'User')
        }
    }

    foreach ($scope in @('Machine', 'User')) {
        foreach ($name in @('PM2_HOME', 'PM2_INSTALL_DIRECTORY', 'PM2_SERVICE_PM2_DIR', 'PM2_SERVICE_DIRECTORY')) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            $belongsToInstallation = @($pathValues | Where-Object { Test-SamePath -Left $value -Right $_ }).Count -gt 0
            if ($belongsToInstallation -and $PSCmdlet.ShouldProcess("$scope environment variable $name", 'Remove')) {
                [Environment]::SetEnvironmentVariable($name, $null, $scope)
            } elseif ($null -ne $value -and -not $belongsToInstallation) {
                Write-Host "$scope environment variable $name was retained because its value does not belong to this installation."
            }
        }

        foreach ($name in $alwaysRemove) {
            if ($null -ne [Environment]::GetEnvironmentVariable($name, $scope) -and
                $PSCmdlet.ShouldProcess("$scope environment variable $name", 'Remove')) {
                [Environment]::SetEnvironmentVariable($name, $null, $scope)
            }
        }

        $path = [Environment]::GetEnvironmentVariable('Path', $scope)
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $filtered = @($path -split ';' | Where-Object {
                $_ -and -not (Test-SamePath -Left $_ -Right $v1NpmPrefix) -and
                -not (Test-SamePath -Left $_ -Right $v2NpmPrefix)
            })
            $newPath = $filtered -join ';'
            if ($newPath -ne $path -and $PSCmdlet.ShouldProcess("$scope Path", 'Remove PM2 npm directories')) {
                [Environment]::SetEnvironmentVariable('Path', $newPath, $scope)
            }
        }
    }
}

$transcriptStarted = $false
try {
    Start-Transcript -Path $log -Append | Out-Null
    $transcriptStarted = $true

    Remove-Pm2WindowsServices
    Stop-InstalledPm2Processes
    Remove-Pm2Packages
    Remove-KnownInstallationFiles
    Remove-Pm2Environment

    if ($RemoveData) {
        foreach ($root in @($v1Pm2Root, $v2Pm2Root)) {
            if ((Test-Path -LiteralPath $root) -and $PSCmdlet.ShouldProcess($root, 'Remove PM2 state, saved process list, and logs')) {
                Remove-Item -LiteralPath $root -Recurse -Force
            }
        }
    } else {
        foreach ($home in @($v1Pm2Home, $v2Pm2Home)) {
            if (Test-Path -LiteralPath $home) {
                Write-Host "PM2 data was retained at $home. Use -RemoveData to delete it."
            }
        }
    }

    $servicesRemoved = if ($WhatIfPreference) { $true } else { Wait-Pm2WindowsServicesRemoved }
    if (-not $servicesRemoved) {
        $remainingServices = @(Get-Pm2WindowsServices)
        throw "PM2 service removal is still pending for: $($remainingServices.Name -join ', '). Close Services consoles and retry, or reboot Windows."
    }

    Write-Host 'PM2 Windows service removal completed.'
} finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
