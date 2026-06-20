[CmdletBinding()]
param(
    [string]$TemplatePath = (Join-Path $PSScriptRoot 'remed.config.cjs'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'remed.generated.config.cjs'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Expand-PathInput {
    param([Parameter(Mandatory)] [string] $Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    return $expanded -replace '/', '\'
}

function Read-PathWithDefault {
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [Parameter(Mandatory)] [string] $Default
    )

    $answer = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return (Expand-PathInput -Path $Default)
    }

    return (Expand-PathInput -Path $answer)
}

function ConvertTo-JavaScriptStringLiteralValue {
    param([Parameter(Mandatory)] [string] $Value)

    $escaped = $Value.Replace('\', '\\')
    $escaped = $escaped.Replace('"', '\"')
    $escaped = $escaped.Replace("`r", '\r')
    $escaped = $escaped.Replace("`n", '\n')

    return $escaped
}

function Replace-ConstString {
    param(
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Value
    )

    $literal = ConvertTo-JavaScriptStringLiteralValue -Value $Value
    $pattern = '(?m)^(\s*const\s+{0}\s*=\s*)"(?:(?:\\.)|[^"\\])*"(\s*;)' -f [Regex]::Escape($Name)

    $result = [Regex]::Replace($Content, $pattern, {
        param($match)
        return $match.Groups[1].Value + '"' + $literal + '"' + $match.Groups[2].Value
    }, 1)

    if ($result -eq $Content) {
        throw "Could not find const string '$Name' in template: $TemplatePath"
    }

    return $result
}

function Replace-EnvString {
    param(
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Value
    )

    $literal = ConvertTo-JavaScriptStringLiteralValue -Value $Value
    $pattern = '(\b{0}\s*:\s*)"(?:(?:\\.)|[^"\\])*"' -f [Regex]::Escape($Name)

    $result = [Regex]::Replace($Content, $pattern, {
        param($match)
        return $match.Groups[1].Value + '"' + $literal + '"'
    }, 1)

    if ($result -eq $Content) {
        throw "Could not find env string '$Name' in template: $TemplatePath"
    }

    return $result
}

function Ensure-Directory {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Host "Created directory: $Path"
        return
    }

    $item = Get-Item -LiteralPath $Path
    if (-not $item.PSIsContainer) {
        throw "Path exists but is not a directory: $Path"
    }

    Write-Host "Directory exists: $Path"
}

if (-not (Test-Path -LiteralPath $TemplatePath)) {
    throw "Template file was not found: $TemplatePath"
}

$defaultProjectRoot = if ($env:USERPROFILE) {
    Join-Path $env:USERPROFILE 'Documents\remed\backend'
} else {
    '%USERPROFILE%\Documents\remed\backend'
}

$projectRoot = Read-PathWithDefault -Prompt 'Project root' -Default $defaultProjectRoot
$uploadsDir = Read-PathWithDefault -Prompt 'UPLOADS_DIR' -Default 'C:\remed_uploads'
$backupsDir = Read-PathWithDefault -Prompt 'BACKUPS_DIR' -Default 'C:\remed_backups'
$sqliteDbPath = Read-PathWithDefault -Prompt 'SQLITE_DB_PATH' -Default 'C:\remed_data\remed.db'

$sqliteDbParent = Split-Path -Parent $sqliteDbPath
if ([string]::IsNullOrWhiteSpace($sqliteDbParent)) {
    throw "SQLITE_DB_PATH must include a parent directory: $sqliteDbPath"
}

Ensure-Directory -Path $uploadsDir
Ensure-Directory -Path $backupsDir
Ensure-Directory -Path $sqliteDbParent

$template = Get-Content -LiteralPath $TemplatePath -Raw
$config = Replace-ConstString -Content $template -Name 'projectRoot' -Value $projectRoot
$config = Replace-EnvString -Content $config -Name 'UPLOADS_DIR' -Value $uploadsDir
$config = Replace-EnvString -Content $config -Name 'BACKUPS_DIR' -Value $backupsDir
$config = Replace-EnvString -Content $config -Name 'SQLITE_DB_PATH' -Value $sqliteDbPath

$outputParent = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputParent)) {
    Ensure-Directory -Path $outputParent
}

if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    $overwrite = Read-Host "Output file already exists: $OutputPath. Overwrite? [Y/n]"
    if ($overwrite -notmatch '^(|y|yes)$') {
        throw 'Aborted without overwriting the generated config.'
    }
}

Set-Content -LiteralPath $OutputPath -Value $config -Encoding UTF8

Write-Host ''
Write-Host "Wrote remed service config: $OutputPath"
Write-Host "Use it with: pm2 start `"$OutputPath`""
