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
        $extension = [IO.Path]::GetExtension($source)
        if ($extension.Equals('.cmd', [StringComparison]::OrdinalIgnoreCase) -or
            $extension.Equals('.exe', [StringComparison]::OrdinalIgnoreCase)) {
            [void]$npmCommands.Add($source)
            continue
        }

        $cmdSibling = Join-Path (Split-Path -Parent $source) 'npm.cmd'
        if (Test-Path -LiteralPath $cmdSibling) {
            [void]$npmCommands.Add($cmdSibling)
            continue
        }

        Write-Host "Skipping npm command that cannot be started directly: $source"
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

function Stop-ExistingPm2ServiceAndDaemons {
    $service = Get-Service -Name PM2 -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Stopped') {
        Write-Host 'Stopping existing PM2 service.'
        Stop-Service -Name PM2 -Force -ErrorAction SilentlyContinue
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }

    Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -match '\\node_modules\\pm2\\lib\\Daemon\.js' -or
            $_.CommandLine -match '\\node_modules\\pm2-windows-service\\'
        } |
        ForEach-Object {
            Write-Host "Stopping existing PM2-related node process: PID $($_.ProcessId)"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
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

    foreach ($key in @('PM2_HOME', 'PM2_SERVICE_PM2_DIR')) {
        $processValue = [Environment]::GetEnvironmentVariable($key, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($processValue)) {
            $clean[$key] = $processValue
        }
    }

    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('PM2_SERVICE_SCRIPTS', 'Process'))) {
        [void]$clean.Remove('PM2_SERVICE_SCRIPTS')
        [void]$clean.Remove('PM2_SERVICE_CONFIG')
        [void]$clean.Remove('PM2_SERVICE_SCRIPT')
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

function Repair-Pm2WindowsNamedPipes {
    $pathsJs = 'C:\node-global\node_modules\pm2\paths.js'
    $sockJs = 'C:\node-global\node_modules\pm2\node_modules\pm2-axon\lib\sockets\sock.js'

    if (Test-Path -LiteralPath $pathsJs) {
        $backup = "$pathsJs.bak-before-windows-pipe-repair"
        if (-not (Test-Path -LiteralPath $backup)) {
            Copy-Item -LiteralPath $pathsJs -Destination $backup
        }

        $pathsText = Get-Content -LiteralPath $pathsJs -Raw
        if ($pathsText -notmatch 'pipeNamePrefix') {
            $windowsPipeBlock = @'
if (process.platform === 'win32' ||
      process.platform === 'win64') {
    var pipeNamePrefix = 'pm2-' + String(PM2_HOME || 'default')
      .replace(/^[a-zA-Z]:/, '')
      .replace(/[^a-zA-Z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .toLowerCase();
    if (!pipeNamePrefix || pipeNamePrefix === 'pm2-') pipeNamePrefix = 'pm2-default';
    pm2_file_stucture.DAEMON_RPC_PORT = '\\\\.\\pipe\\' + pipeNamePrefix + '-rpc.sock';
    pm2_file_stucture.DAEMON_PUB_PORT = '\\\\.\\pipe\\' + pipeNamePrefix + '-pub.sock';
    pm2_file_stucture.INTERACTOR_RPC_PORT = '\\\\.\\pipe\\' + pipeNamePrefix + '-interactor.sock';
  }
'@
            $pathsText = $pathsText -replace "(?s)if \(process\.platform === 'win32'\s*\|\|\s*process\.platform === 'win64'\) \{\s*//@todo instead of static unique rpc/pub file custom with PM2_HOME or UID\s*pm2_file_stucture\.DAEMON_RPC_PORT = '\\\\\\\\.\\\\pipe\\\\rpc\.sock';\s*pm2_file_stucture\.DAEMON_PUB_PORT = '\\\\\\\\.\\\\pipe\\\\pub\.sock';\s*pm2_file_stucture\.INTERACTOR_RPC_PORT = '\\\\\\\\.\\\\pipe\\\\interactor\.sock';\s*\}", $windowsPipeBlock
            Set-Content -LiteralPath $pathsJs -Value $pathsText -NoNewline
        }
    }

    if (Test-Path -LiteralPath $sockJs) {
        $backup = "$sockJs.bak-before-windows-pipe-acl"
        if (-not (Test-Path -LiteralPath $backup)) {
            Copy-Item -LiteralPath $sockJs -Destination $backup
        }

        $sockText = Get-Content -LiteralPath $sockJs -Raw
        if ($sockText -notmatch 'function listenWithWindowsPipeAcl') {
            $pipeAclHelper = @'
function listenWithWindowsPipeAcl(server, port, host, fn) {
  if (process.platform === 'win32' && typeof port === 'string' && /^\\\\[.?]\\pipe\\/.test(port)) {
    return server.listen({ path: port, readableAll: true, writableAll: true }, fn);
  }

  return server.listen(port, host, fn);
}

'@
            $sockText = $sockText -replace "var fs = require\('fs'\);\r?\n", "var fs = require('fs');`r`n`r`n$pipeAclHelper"
        }

        $sockText = $sockText.Replace('self.server.listen(port, host, fn);', 'listenWithWindowsPipeAcl(self.server, port, host, fn);')
        $sockText = $sockText.Replace('this.server.listen(port, host, fn);', 'listenWithWindowsPipeAcl(this.server, port, host, fn);')
        Set-Content -LiteralPath $sockJs -Value $sockText -NoNewline
    }
}

function Assert-Pm2WindowsNamedPipeRepair {
    param([Parameter(Mandatory)] [string] $NodeExe)

    $checkScript = @'
process.env.PM2_HOME = 'C:\\pm2\\.pm2';
const paths = require('C:\\node-global\\node_modules\\pm2\\paths')(process.env.PM2_HOME);
console.log('PM2 daemon RPC pipe: ' + paths.DAEMON_RPC_PORT);
if (/^\\\\\.\\pipe\\rpc\.sock$/i.test(paths.DAEMON_RPC_PORT)) {
  console.error('PM2 is still using the stock Windows rpc.sock pipe.');
  process.exit(2);
}
'@

    $exitCode = Invoke-CleanProcess -FilePath $NodeExe -Arguments @('-e', $checkScript) -ExtraPathPrefix 'C:\Program Files\nodejs;C:\node-global'
    if ($exitCode -ne 0) {
        throw 'PM2 Windows named pipe repair did not apply.'
    }
}

function Set-Pm2DirectoryAcl {
    param([Parameter(Mandatory)] [string[]] $Paths)

    $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        icacls $path /grant "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*${currentUserSid}:(OI)(CI)M" | Out-Null
    }
}

function Set-Pm2EnvironmentVariables {
    param(
        [Parameter(Mandatory)] [string] $Pm2Home,
        [Parameter(Mandatory)] [string] $Pm2ModuleDir
    )

    foreach ($scope in @('Machine', 'User')) {
        [Environment]::SetEnvironmentVariable('PM2_HOME', $Pm2Home, $scope)
        [Environment]::SetEnvironmentVariable('PM2_SERVICE_PM2_DIR', $Pm2ModuleDir, $scope)
        [Environment]::SetEnvironmentVariable('PM2_SERVICE_SCRIPTS', $null, $scope)
        [Environment]::SetEnvironmentVariable('PM2_SERVICE_CONFIG', $null, $scope)
        [Environment]::SetEnvironmentVariable('PM2_SERVICE_SCRIPT', $null, $scope)
    }

    $env:PM2_HOME = $Pm2Home
    $env:PM2_SERVICE_PM2_DIR = $Pm2ModuleDir
    Remove-Item Env:PM2_SERVICE_SCRIPTS -ErrorAction SilentlyContinue
    Remove-Item Env:PM2_SERVICE_CONFIG -ErrorAction SilentlyContinue
    Remove-Item Env:PM2_SERVICE_SCRIPT -ErrorAction SilentlyContinue
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

function Install-Pm2WindowsService {
    param([Parameter(Mandatory)] [string] $NodeExe)

    $installScript = @'
const pm2ws = require('C:\\node-global\\node_modules\\pm2-windows-service');
pm2ws.install('PM2', true).then(() => {
  console.log('PM2 service installed and started.');
}, err => {
  console.error(err && (err.stack || err.message) || err);
  process.exit((err && err.code) || 1);
});
'@

    $exitCode = Invoke-CleanProcess -FilePath $NodeExe -Arguments @('-e', $installScript) -ExtraPathPrefix 'C:\Program Files\nodejs;C:\node-global'
    if ($exitCode -ne 0) {
        throw "pm2-windows-service install failed with exit code $exitCode"
    }
}

function Assert-Pm2ServiceInstalledAndRunning {
    $service = Get-Service -Name PM2 -ErrorAction Stop
    if ($service.Status -ne 'Running') {
        Write-Host "PM2 service is $($service.Status). Starting it."
        Start-Service -Name $service.Name
        $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
        $service = Get-Service -Name $service.Name -ErrorAction Stop
    }

    if ($service.Status -ne 'Running') {
        throw "PM2 service exists but is not running. Current status: $($service.Status)"
    }

    Write-Host "PM2 service installed: Name=$($service.Name), DisplayName=$($service.DisplayName), Status=$($service.Status), StartType=$($service.StartType)"

    $escapedName = $service.Name.Replace('\', '\\').Replace("'", "''")
    $serviceDetails = Get-CimInstance Win32_Service -Filter "Name = '$escapedName'" -ErrorAction Stop
    if (-not $serviceDetails) {
        throw "Get-Service sees PM2 service '$($service.Name)', but Win32_Service did not return service details."
    }

    Write-Host "PM2 service account: $($serviceDetails.StartName)"
    Write-Host "PM2 service PathName: $($serviceDetails.PathName)"
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

    Stop-ExistingPm2ServiceAndDaemons

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
    Set-Pm2DirectoryAcl -Paths @($npmPrefix, 'C:\pm2', $pm2Home)

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
    Repair-Pm2WindowsNamedPipes
    Assert-Pm2WindowsNamedPipeRepair -NodeExe $nodeInstall.NodeExe

    Copy-Item -LiteralPath $nodeInstall.NodeExe -Destination 'C:\node-global\node.exe' -Force

    $pm2ModuleDir = 'C:\node-global\node_modules\pm2'
    if (-not (Test-Path -LiteralPath $pm2ModuleDir)) {
        throw "PM2 module directory was not found after install: $pm2ModuleDir"
    }

    Write-Host 'Setting PM2 environment variables.'
    Set-Pm2EnvironmentVariables -Pm2Home $pm2Home -Pm2ModuleDir $pm2ModuleDir

    Write-Host 'Installing pm2-windows-service.'
    Invoke-NpmGlobal -NpmCmd $nodeInstall.NpmCmd -Arguments @('install', '-g', 'pm2-windows-service', '--ignore-scripts')
    Repair-Pm2WindowsServiceEnvironmentSpawn

    Write-Host 'Installing PM2 service non-interactively.'
    Install-Pm2WindowsService -NodeExe $nodeInstall.NodeExe

    Write-Host 'Verifying PM2 service.'
    Assert-Pm2ServiceInstalledAndRunning
    Write-Host 'Verifying C:\node-global PM2 command.'
    & 'C:\node-global\pm2.cmd' --version
} finally {
    Stop-Transcript | Out-Null
}
