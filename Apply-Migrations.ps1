<#
.SYNOPSIS
    Apply numbered etl-control migrations to the existing DWH database (Approach 2).

.DESCRIPTION
    1. Bootstraps etl.SCHEMA_MIGRATION if missing
    2. Runs each migrations/*.sql in name order
    3. Skips scripts already recorded in the ledger
    4. Records each successful script in etl.SCHEMA_MIGRATION

.PARAMETER Server
    SQL Server instance (e.g. SQLDWH01 or localhost)

.PARAMETER Database
    Existing DWH database name (e.g. SaudiRe_DW)

.PARAMETER UseTrustedConnection
    Windows auth (default). Set -Username/-Password for SQL auth instead.

.EXAMPLE
    .\Apply-Migrations.ps1 -Server SQLDWH01 -Database SaudiRe_DW

.EXAMPLE
    .\Apply-Migrations.ps1 -Server SQLDWH01 -Database SaudiRe_DW -Username sa -Password '***'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Server,

    [Parameter(Mandatory = $true)]
    [string] $Database,

    [string] $Username,
    [string] $Password,

    [switch] $UseTrustedConnection = $true
)

$ErrorActionPreference = 'Stop'

$scriptsRoot     = Split-Path -Parent $MyInvocation.MyCommand.Path
$etlControlRoot  = Split-Path -Parent $scriptsRoot
$migrationsDir   = Join-Path $etlControlRoot 'migrations'
$bootstrapSql    = Join-Path $scriptsRoot 'bootstrap_ledger.sql'

if (-not (Test-Path $migrationsDir)) {
    throw "Migrations folder not found: $migrationsDir"
}
if (-not (Test-Path $bootstrapSql)) {
    throw "Bootstrap script not found: $bootstrapSql"
}

function Invoke-SqlFile {
    param([string] $Path)

    $args = @(
        '-S', $Server,
        '-d', $Database,
        '-b',
        '-I',
        '-i', $Path
    )

    if ($Username) {
        $args += @('-U', $Username, '-P', $Password)
    }
    else {
        $args += '-E'
    }

    & sqlcmd @args
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd failed for $Path (exit $LASTEXITCODE)"
    }
}

function Invoke-SqlQuery {
    param([string] $Query)

    $args = @(
        '-S', $Server,
        '-d', $Database,
        '-b',
        '-h', '-1',
        '-W',
        '-Q', $Query
    )

    if ($Username) {
        $args += @('-U', $Username, '-P', $Password)
    }
    else {
        $args += '-E'
    }

    $out = & sqlcmd @args
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd query failed (exit $LASTEXITCODE): $Query"
    }
    return $out
}

Write-Host "Bootstrapping ledger on $Server / $Database ..."
Invoke-SqlFile -Path $bootstrapSql

$files = Get-ChildItem -Path $migrationsDir -Filter '*.sql' |
    Sort-Object Name

if ($files.Count -eq 0) {
    Write-Host "No migration scripts found in $migrationsDir"
    exit 0
}

foreach ($file in $files) {
    $name = $file.Name
    $escaped = $name.Replace("'", "''")

    $check = Invoke-SqlQuery -Query @"
SET NOCOUNT ON;
SELECT COUNT(1) FROM etl.SCHEMA_MIGRATION WHERE SCRIPT_NAME = N'$escaped';
"@

    $count = 0
    if ($check) {
        $count = [int](($check | Where-Object { $_.Trim() -match '^\d+$' } | Select-Object -First 1).Trim())
    }

    if ($count -gt 0) {
        Write-Host "SKIP  $name (already applied)"
        continue
    }

    Write-Host "APPLY $name ..."
    Invoke-SqlFile -Path $file.FullName

    Invoke-SqlQuery -Query @"
SET NOCOUNT ON;
INSERT INTO etl.SCHEMA_MIGRATION (SCRIPT_NAME) VALUES (N'$escaped');
"@ | Out-Null

    Write-Host "OK    $name"
}

Write-Host "Done. Applied migrations ledger:"
Invoke-SqlQuery -Query @"
SET NOCOUNT ON;
SELECT SCRIPT_NAME, APPLIED_DATE, APPLIED_BY
FROM etl.SCHEMA_MIGRATION
ORDER BY SCRIPT_NAME;
"@
