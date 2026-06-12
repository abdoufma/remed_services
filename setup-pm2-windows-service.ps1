$ErrorActionPreference = 'Stop'

$log = Join-Path $PSScriptRoot 'setup-pm2-windows-service-machine.log'
Start-Transcript -Path $log -Append | Out-Null

function Test-IsAdministrator {
    return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-ExistingNodePaths {
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($command in Get-Command node.exe -All -ErrorAction SilentlyContinue) {
        if ($command.Source) {
            [void]$paths.Add((Resolve-Path -LiteralPath $command.Source).Path)
        }
    }

    foreach ($candidate in @(
        "$env:ProgramFiles\nodejs\node.exe",
        "${env:ProgramFiles(x86)}\nodejs\node.exe"
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            [void]$paths.Add((Resolve-Path -LiteralPath $candidate).Path)
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
                $nodeExe = Join-Path $_.InstallLocation 'node.exe'
                if (Test-Path -LiteralPath $nodeExe) {
                    [void]$paths.Add((Resolve-Path -LiteralPath $nodeExe).Path)
                }
            }
    }

    foreach ($root in @(
        "$env:LOCALAPPDATA\fnm_multishells",
        "$env:APPDATA\fnm",
        "$env:LOCALAPPDATA\fnm"
    )) {
        if ($root -and (Test-Path -LiteralPath $root)) {
            Get-ChildItem -LiteralPath $root -Filter node.exe -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object { [void]$paths.Add($_.FullName) }
        }
    }

    return @($paths)
}

function Test-IsFnmNodePath {
    param([Parameter(Mandatory)] [string] $Path)

    $fnmRoots = @(
        "$env:LOCALAPPDATA\fnm_multishells",
        "$env:APPDATA\fnm",
        "$env:LOCALAPPDATA\fnm"
    ) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') + '\' }

    $fullPath = [IO.Path]::GetFullPath($Path)
    foreach ($root in $fnmRoots) {
        if ($fullPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-IsGlobalNodePath {
    param([Parameter(Mandatory)] [string] $Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $globalRoots = @(
        "$env:ProgramFiles\",
        "${env:ProgramFiles(x86)}\",
        'C:\nodejs\'
    ) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_) }

    foreach ($root in $globalRoots) {
        if ($fullPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-NodeInstallFromNodeExe {
    param([Parameter(Mandatory)] [string] $NodeExe)

    $nodeRoot = Split-Path -Parent $NodeExe
    $npmCmd = Join-Path $nodeRoot 'npm.cmd'
    if (-not (Test-Path -LiteralPath $npmCmd)) {
        throw "Detected Node install does not include npm.cmd: $nodeRoot"
    }

    return @{
        NodeRoot = $nodeRoot
        NodeExe = $NodeExe
        NpmCmd = $npmCmd
    }
}

function Get-NodeVersionText {
    param([Parameter(Mandatory)] [string] $NodeExe)

    try {
        return (& $NodeExe --version 2>$null)
    } catch {
        return 'version unknown'
    }
}

function Select-GlobalNodeInstall {
    param([Parameter(Mandatory)] [string[]] $NodePaths)

    $candidates = @($NodePaths | Where-Object {
        (Test-IsGlobalNodePath $_) -and
        (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $_) 'npm.cmd'))
    })

    if ($candidates.Count -eq 0) {
        return $null
    }

    Write-Host 'Global non-FNM Node.js install(s) were detected:'
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $version = Get-NodeVersionText -NodeExe $candidates[$i]
        Write-Host "  [$($i + 1)] $($candidates[$i]) ($version)"
    }

    if ($candidates.Count -eq 1) {
        $answer = Read-Host 'Install PM2 against this global Node.js install? [Y/n]'
        if ($answer -match '^(|y|yes)$') {
            return Get-NodeInstallFromNodeExe -NodeExe $candidates[0]
        }

        throw 'User declined to use the detected global Node.js install.'
    }

    $selection = Read-Host "Choose the Node.js install to use for PM2 [1-$($candidates.Count)], or press Enter to abort"
    if (-not $selection) {
        throw 'No global Node.js install was selected.'
    }

    $index = 0
    if (-not [int]::TryParse($selection, [ref]$index) -or $index -lt 1 -or $index -gt $candidates.Count) {
        throw "Invalid Node.js selection: $selection"
    }

    return Get-NodeInstallFromNodeExe -NodeExe $candidates[$index - 1]
}

function Get-LatestLtsNodeVersion {
    $indexUrl = 'https://nodejs.org/dist/index.json'
    $releases = Invoke-RestMethod -Uri $indexUrl
    $latestLts = $releases |
        Where-Object { $_.lts -and ($_.files -contains 'win-x64-zip') } |
        Select-Object -First 1

    if (-not $latestLts) {
        throw 'Could not find a latest Windows x64 LTS Node release from nodejs.org.'
    }

    return $latestLts.version
}

function Install-NodeToProgramFiles {
    param([Parameter(Mandatory)] [string] $Version)

    $nodeRoot = "$env:ProgramFiles\nodejs"
    $zip = Join-Path $env:TEMP "node-$Version-win-x64.zip"
    $extractRoot = Join-Path $env:TEMP "node-$Version-win-x64"
    $downloadUrl = "https://nodejs.org/dist/$Version/node-$Version-win-x64.zip"

    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }

    Invoke-WebRequest -Uri $downloadUrl -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $env:TEMP -Force

    New-Item -ItemType Directory -Force -Path $nodeRoot | Out-Null
    Copy-Item -Path (Join-Path $extractRoot '*') -Destination $nodeRoot -Recurse -Force

    $nodeExe = Join-Path $nodeRoot 'node.exe'
    $npmCmd = Join-Path $nodeRoot 'npm.cmd'
    foreach ($required in @($nodeExe, $npmCmd)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "Node install did not create required file: $required"
        }
    }

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $pathParts = @($machinePath -split ';' | Where-Object { $_ })
    if ($pathParts -notcontains $nodeRoot) {
        [Environment]::SetEnvironmentVariable('Path', (($pathParts + $nodeRoot) -join ';'), 'Machine')
    }

    return @{
        NodeRoot = $nodeRoot
        NodeExe = $nodeExe
        NpmCmd = $npmCmd
    }
}

function Remove-ExistingPm2Packages {
    $packages = @('pm2', 'pm2-windows-service', 'pm2-win-service')
    $npmCommands = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($command in Get-Command npm.cmd, npm.ps1, npm.exe, npm -All -ErrorAction SilentlyContinue) {
        if (-not $command.Source) {
            continue
        }

        $source = $command.Source
        if ($source.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
            $cmdSibling = Join-Path (Split-Path -Parent $source) 'npm.cmd'
            if (Test-Path -LiteralPath $cmdSibling) {
                $source = $cmdSibling
            }
        }

        [void]$npmCommands.Add($source)
    }

    foreach ($npm in $npmCommands) {
        Write-Host "Removing PM2 packages via npm: $npm"
        foreach ($packageName in $packages) {
            try {
                $npmDir = Split-Path -Parent $npm
                $exitCode = Invoke-CleanProcess -FilePath $npm -Arguments @('uninstall', '-g', $packageName) -ExtraPathPrefix $npmDir
                if ($exitCode -ne 0) {
                    Write-Host "  $packageName was not removed by $npm; npm exited with $exitCode"
                }
            } catch {
                Write-Host "  $packageName was not removed by $npm`: $($_.Exception.Message)"
            }
        }
    }

    $bun = Get-Command bun.exe -ErrorAction SilentlyContinue
    if ($bun -and $bun.Source) {
        try {
            $bunGlobals = & $bun.Source pm ls -g 2>$null
            foreach ($packageName in $packages) {
                if ($bunGlobals -match "(^|\s)$([Regex]::Escape($packageName))@") {
                    Write-Host "Removing PM2 package via Bun: $packageName"
                    & $bun.Source remove -g $packageName
                }
            }
        } catch {
            Write-Host "Could not inspect/remove Bun global PM2 packages: $($_.Exception.Message)"
        }
    }
}

function New-CleanEnvironment {
    param([string] $ExtraPathPrefix)

    $clean = @{}

    foreach ($scope in @('Machine', 'User')) {
        $scopeEnv = [Environment]::GetEnvironmentVariables($scope)
        foreach ($key in $scopeEnv.Keys) {
            $name = [string]$key
            $value = [string]$scopeEnv[$key]
            if ($name.Equals('steam_master_ipc_name_override', [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            if ($name.Contains([char]0) -or $value.Contains([char]0)) {
                continue
            }

            $clean[$name] = $value
        }
    }

    $processEnv = [Environment]::GetEnvironmentVariables('Process')
    foreach ($key in $processEnv.Keys) {
        $name = [string]$key
        $value = [string]$processEnv[$key]
        if ($name.Equals('steam_master_ipc_name_override', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ($name.Contains([char]0) -or $value.Contains([char]0)) {
            continue
        }

        if (-not $clean.ContainsKey($name)) {
            $clean[$name] = $value
        }
    }

    if ($ExtraPathPrefix) {
        $clean['Path'] = "$ExtraPathPrefix;$($clean['Path'])"
    }

    return $clean
}

function Invoke-CleanProcess {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $ExtraPathPrefix
    )

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($argument in $Arguments) {
        [void]$psi.ArgumentList.Add($argument)
    }

    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = (Get-Location).Path
    $psi.EnvironmentVariables.Clear()

    $cleanEnv = New-CleanEnvironment -ExtraPathPrefix $ExtraPathPrefix
    foreach ($key in $cleanEnv.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$cleanEnv[$key]
    }

    $process = [Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($stdout) {
        Write-Host $stdout.TrimEnd()
    }
    if ($stderr) {
        Write-Host $stderr.TrimEnd()
    }

    return $process.ExitCode
}

function Invoke-CleanInteractiveProcess {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $ExtraPathPrefix
    )

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($argument in $Arguments) {
        [void]$psi.ArgumentList.Add($argument)
    }

    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $false
    $psi.WorkingDirectory = (Get-Location).Path
    $psi.EnvironmentVariables.Clear()

    $cleanEnv = New-CleanEnvironment -ExtraPathPrefix $ExtraPathPrefix
    foreach ($key in $cleanEnv.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$cleanEnv[$key]
    }

    $process = [Diagnostics.Process]::Start($psi)
    $process.WaitForExit()
    return $process.ExitCode
}

function Invoke-NpmGlobal {
    param(
        [Parameter(Mandatory)] [string] $NpmCmd,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    $env:PATH = "C:\Program Files\nodejs;C:\node-global;$env:PATH"
    $exitCode = Invoke-CleanProcess -FilePath $NpmCmd -Arguments $Arguments -ExtraPathPrefix 'C:\Program Files\nodejs;C:\node-global'
    if ($exitCode -ne 0) {
        throw "npm command failed: $NpmCmd $($Arguments -join ' ')"
    }
}

function Repair-Pm2EnvironmentSpawn {
    $clientJs = 'C:\node-global\node_modules\pm2\lib\Client.js'
    if (-not (Test-Path -LiteralPath $clientJs)) {
        return
    }

    $backup = "$clientJs.bak-before-null-env-filter"
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $clientJs -Destination $backup
    }

    $clientText = Get-Content -LiteralPath $clientJs -Raw
    if ($clientText -notmatch 'function sanitizeEnvForSpawn') {
        $helper = @'
function sanitizeEnvForSpawn(env) {
  return Object.keys(env).reduce(function(clean, key) {
    var value = env[key];
    if (key.indexOf('\0') !== -1) return clean;
    if (typeof value === 'string' && value.indexOf('\0') !== -1) return clean;
    clean[key] = value;
    return clean;
  }, {});
}

'@
        $clientText = $clientText -replace 'function noop\(\) \{\}\r?\n\r?\n', "function noop() {}`r`n`r`n$helper"
    }

    $clientText = $clientText -replace "Object.assign\(\{\r?\n      'SILENT'    : that.conf.DEBUG \? !that.conf.DEBUG : true,\r?\n      'PM2_HOME'  : that.pm2_home\r?\n    \}, process.env\)", "Object.assign({`r`n      'SILENT'    : that.conf.DEBUG ? !that.conf.DEBUG : true,`r`n      'PM2_HOME'  : that.pm2_home`r`n    }, sanitizeEnvForSpawn(process.env))"
    Set-Content -LiteralPath $clientJs -Value $clientText -NoNewline
}

function Repair-Pm2WindowsServiceEnvironmentSpawn {
    $serviceRoot = 'C:\node-global\node_modules\pm2-windows-service'
    $launcher = Join-Path $serviceRoot 'bin\pm2-service-install'
    $cmdJs = Join-Path $serviceRoot 'node_modules\node-windows\lib\cmd.js'

    if (Test-Path -LiteralPath $launcher) {
        $backup = "$launcher.bak-before-env-filter"
        if (-not (Test-Path -LiteralPath $backup)) {
            Copy-Item -LiteralPath $launcher -Destination $backup
        }

        $launcherText = Get-Content -LiteralPath $launcher -Raw
        if ($launcherText -notmatch 'sanitizeEnvironmentForSpawn') {
            $envPatch = @'
function sanitizeEnvironmentForSpawn() {
    Object.keys(process.env).forEach(function(key) {
        var value = process.env[key];
        if (key.toLowerCase() === 'steam_master_ipc_name_override' ||
            key.indexOf('\0') !== -1 ||
            (typeof value === 'string' && value.indexOf('\0') !== -1)) {
            delete process.env[key];
        }
    });
}
sanitizeEnvironmentForSpawn();

'@
            $launcherText = $launcherText -replace "'use strict';\r?\n\r?\n", "'use strict';`r`n`r`n$envPatch"
            Set-Content -LiteralPath $launcher -Value $launcherText -NoNewline
        }
    }

    if (Test-Path -LiteralPath $cmdJs) {
        $backup = "$cmdJs.bak-before-env-filter"
        if (-not (Test-Path -LiteralPath $backup)) {
            Copy-Item -LiteralPath $cmdJs -Destination $backup
        }

        $cmdText = Get-Content -LiteralPath $cmdJs -Raw
        if ($cmdText -notmatch 'sanitizeEnvForExec') {
            $replacement = @'
var childProcess = require('child_process'),
    originalExec = childProcess.exec,
    bin = require('./binaries');

function sanitizeEnvForExec(env) {
  return Object.keys(env).reduce(function(clean, key) {
    var value = env[key];
    if (key.toLowerCase() === 'steam_master_ipc_name_override') return clean;
    if (key.indexOf('\0') !== -1) return clean;
    if (typeof value === 'string' && value.indexOf('\0') !== -1) return clean;
    clean[key] = value;
    return clean;
  }, {});
}

function exec(command, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = {};
  }
  options = options || {};
  options.env = sanitizeEnvForExec(options.env || process.env);
  return originalExec(command, options, callback);
}
'@
            $cmdText = $cmdText -replace "var exec = require\('child_process'\)\.exec,\r?\n    bin = require\('./binaries'\);", $replacement
            Set-Content -LiteralPath $cmdJs -Value $cmdText -NoNewline
        }
    }
}

try {
    if (-not (Test-IsAdministrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }

    $detectedNodes = Resolve-ExistingNodePaths
    Write-Host 'Detected Node.js executables before global install:'
    if ($detectedNodes.Count -eq 0) {
        Write-Host '  none'
    } else {
        $detectedNodes | ForEach-Object { Write-Host "  $_" }
    }

    $nonFnmNodes = @($detectedNodes | Where-Object { -not (Test-IsFnmNodePath $_) })
    $nodeInstall = $null
    if ($nonFnmNodes.Count -gt 0) {
        $nodeInstall = Select-GlobalNodeInstall -NodePaths $nonFnmNodes
        if (-not $nodeInstall) {
            Write-Host 'Non-FNM Node.js executables were detected, but none were usable global Node.js installs:'
            $nonFnmNodes | ForEach-Object { Write-Host "  $_" }
            throw 'Aborting because a non-FNM Node.js runtime was detected but no global Node/npm install was selected.'
        }
    }

    Write-Host 'Removing existing PM2 packages from currently available npm/Bun globals.'
    Remove-ExistingPm2Packages

    if (-not $nodeInstall) {
        $latestLts = Get-LatestLtsNodeVersion
        Write-Host "Installing latest Node.js LTS release to C:\Program Files\nodejs: $latestLts"
        $nodeInstall = Install-NodeToProgramFiles -Version $latestLts
    } else {
        Write-Host "Using selected global Node.js install for PM2: $($nodeInstall.NodeExe)"
    }

    $npmPrefix = 'C:\node-global'
    $pm2Home = 'C:\pm2\.pm2'
    New-Item -ItemType Directory -Force -Path $npmPrefix, $pm2Home | Out-Null

    Write-Host 'Setting npm global prefix to C:\node-global'
    Invoke-NpmGlobal -NpmCmd $nodeInstall.NpmCmd -Arguments @('config', 'set', 'prefix', $npmPrefix, '--location', 'global')

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $pathParts = @($machinePath -split ';' | Where-Object { $_ })
    foreach ($pathToAdd in @('C:\Program Files\nodejs', 'C:\node-global')) {
        if ($pathParts -notcontains $pathToAdd) {
            $pathParts += $pathToAdd
        }
    }
    [Environment]::SetEnvironmentVariable('Path', ($pathParts -join ';'), 'Machine')
    $env:PATH = "C:\Program Files\nodejs;C:\node-global;$env:PATH"

    Write-Host 'Removing any existing PM2 packages visible to the global Node install.'
    foreach ($packageName in @('pm2', 'pm2-windows-service', 'pm2-win-service')) {
        try {
            Invoke-NpmGlobal -NpmCmd $nodeInstall.NpmCmd -Arguments @('uninstall', '-g', $packageName)
        } catch {
            Write-Host "  $packageName was not installed or could not be removed: $($_.Exception.Message)"
        }
    }

    Write-Host 'Installing PM2 with the global Node install.'
    Invoke-NpmGlobal -NpmCmd $nodeInstall.NpmCmd -Arguments @('install', '-g', 'pm2')
    Repair-Pm2EnvironmentSpawn

    Copy-Item -LiteralPath $nodeInstall.NodeExe -Destination 'C:\node-global\node.exe' -Force

    $pm2ModuleDir = 'C:\node-global\node_modules\pm2'
    if (-not (Test-Path -LiteralPath $pm2ModuleDir)) {
        throw "PM2 module directory was not found after install: $pm2ModuleDir"
    }

    Write-Host 'Setting machine-level PM2 environment variables.'
    [Environment]::SetEnvironmentVariable('PM2_HOME', $pm2Home, 'Machine')
    [Environment]::SetEnvironmentVariable('PM2_SERVICE_PM2_DIR', $pm2ModuleDir, 'Machine')
    [Environment]::SetEnvironmentVariable('PM2_SERVICE_SCRIPTS', $null, 'Machine')

    $env:PM2_HOME = $pm2Home
    $env:PM2_SERVICE_PM2_DIR = $pm2ModuleDir
    Remove-Item Env:PM2_SERVICE_SCRIPTS -ErrorAction SilentlyContinue

    Write-Host 'Installing pm2-windows-service.'
    Invoke-NpmGlobal -NpmCmd $nodeInstall.NpmCmd -Arguments @('install', '-g', 'pm2-windows-service', '--ignore-scripts')
    Repair-Pm2WindowsServiceEnvironmentSpawn

    $serviceInstaller = 'C:\node-global\pm2-service-install.cmd'
    if (-not (Test-Path -LiteralPath $serviceInstaller)) {
        throw "pm2-service-install was not found after pm2-windows-service install: $serviceInstaller"
    }

    Write-Host 'Running: pm2-service-install -n PM2'
    $serviceExitCode = Invoke-CleanInteractiveProcess -FilePath $serviceInstaller -Arguments @('-n', 'PM2') -ExtraPathPrefix 'C:\Program Files\nodejs;C:\node-global'
    if ($serviceExitCode -ne 0) {
        throw "pm2-service-install failed with exit code $serviceExitCode"
    }

    Write-Host 'Verifying PM2 service.'
    Get-Service -Name PM2 -ErrorAction Stop | Select-Object Name, Status, StartType
    & 'C:\node-global\pm2.cmd' --version
} finally {
    Stop-Transcript | Out-Null
}
