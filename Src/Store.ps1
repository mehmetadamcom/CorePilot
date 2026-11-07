# Persistent state: one record per feature (the original values, so a change can be undone) and an append-only history.
# Default location: %LOCALAPPDATA%\CorePilot. Replaceable for tests (Set-CpDataRoot).

$script:CpDataRoot = $null

function Set-CpDataRoot {
    param([string]$Path)
    $script:CpDataRoot = $Path
}

function Get-CpDataRoot {
    if ($script:CpDataRoot) { return $script:CpDataRoot }
    return (Join-Path $env:LOCALAPPDATA 'CorePilot')
}

function Assert-CpSafeId {
    param([string]$Id)
    if ($Id -cnotmatch $script:CpIdPattern) { throw "Unsafe feature id '$Id'." }
}

function Get-CpRecordPath {
    param([string]$Id)
    Assert-CpSafeId -Id $Id
    return (Join-Path (Join-Path (Get-CpDataRoot) 'records') "$Id.json")
}

function Write-CpFileAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N')
    [System.IO.File]::WriteAllText($temp, $Text, (New-Object System.Text.UTF8Encoding($false)))
    try { Move-Item -LiteralPath $temp -Destination $Path -Force }
    catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw
    }
}

# Returns $null when there is no record. Throws when a record exists but cannot be trusted.
function Read-CpRecord {
    param([Parameter(Mandatory)][string]$Id)
    $path = Get-CpRecordPath -Id $Id
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $record = Read-CpJson $path
    if ($record.schema -ne 1 -or $record.featureId -cne $Id -or -not ($record.state -is [string])) {
        throw "Record for '$Id' is not valid."
    }
    $null = @($record.originals)
    return $record
}

function Save-CpRecord {
    param([Parameter(Mandatory)]$Record)
    $path = Get-CpRecordPath -Id $Record.featureId
    $Record.updatedUtc = [DateTime]::UtcNow.ToString('o')
    Write-CpFileAtomic -Path $path -Text (ConvertTo-Json -InputObject $Record -Depth 6)
}

function New-CpRecord {
    param(
        [Parameter(Mandatory)][string]$FeatureId,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][object[]]$Originals,
        [int]$Build
    )
    $now = [DateTime]::UtcNow.ToString('o')
    return [ordered]@{
        schema     = 1
        featureId  = $FeatureId
        state      = $State
        build      = $Build
        createdUtc = $now
        updatedUtc = $now
        originals  = @($Originals)
    }
}

function Get-CpRecordsNeedingRecovery {
    $directory = Join-Path (Get-CpDataRoot) 'records'
    if (-not (Test-Path -LiteralPath $directory)) { return @() }
    $found = New-Object System.Collections.ArrayList
    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*.json' -File) {
        try {
            $record = Read-CpRecord -Id ([System.IO.Path]::GetFileNameWithoutExtension($file.Name))
            if ($null -ne $record -and @('Applying', 'Reverting', 'RecoveryNeeded') -contains $record.state) { [void]$found.Add($record) }
        }
        catch { }
    }
    return $found.ToArray()
}

function Add-CpHistory {
    param(
        [Parameter(Mandatory)][string]$FeatureId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Status,
        [string]$Reason = ''
    )
    try {
        $entry = [ordered]@{
            timeUtc   = [DateTime]::UtcNow.ToString('o')
            featureId = $FeatureId
            action    = $Action
            status    = $Status
            reason    = $Reason
        }
        $path = Join-Path (Get-CpDataRoot) 'history.jsonl'
        $directory = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        $line = (ConvertTo-Json -InputObject $entry -Compress) + "`n"
        [System.IO.File]::AppendAllText($path, $line, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

function Get-CpHistory {
    param([int]$Last = 50)
    $path = Join-Path (Get-CpDataRoot) 'history.jsonl'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $entries = New-Object System.Collections.ArrayList
    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$entries.Add((ConvertFrom-Json -InputObject $line)) } catch { }
    }
    $all = $entries.ToArray()
    if ($all.Count -gt $Last) { $all = $all[($all.Count - $Last)..($all.Count - 1)] }
    return $all
}
