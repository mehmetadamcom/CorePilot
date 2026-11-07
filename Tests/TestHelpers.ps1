# Shared test helpers. Tests never touch the real registry or the real %LOCALAPPDATA%\CorePilot:
# they swap in an in-memory registry, a temp data folder and a fixed Windows build before doing anything.

function New-CpFakeRegistry {
    $fake = @{ IsFake = $true; Store = @{}; Log = (New-Object System.Collections.ArrayList); FailSetOn = @{}; FailSetAfter = 0; SilentCorrupt = @{}; SetCount = 0 }
    $fake['Get'] = {
        param([string]$Path, [string]$Name)
        [void]$fake.Log.Add("get $Path|$Name")
        $key = "$Path|$Name".ToLowerInvariant()
        if (-not $fake.Store.ContainsKey($key)) { return [pscustomobject]@{ Exists = $false; Kind = $null; Value = $null } }
        $entry = $fake.Store[$key]
        return [pscustomobject]@{ Exists = $true; Kind = $entry.Kind; Value = $entry.Value }
    }.GetNewClosure()
    $fake['Set'] = {
        param([string]$Path, [string]$Name, [string]$Kind, $Value)
        $key = "$Path|$Name".ToLowerInvariant()
        $fake.SetCount++
        [void]$fake.Log.Add("set $Path|$Name")
        if ($fake.FailSetOn.ContainsKey($key)) { throw (New-Object System.UnauthorizedAccessException('denied by test')) }
        if ($fake.FailSetAfter -gt 0 -and $fake.SetCount -ge $fake.FailSetAfter) { throw (New-Object System.UnauthorizedAccessException('denied by test (after)')) }
        if ($fake.SilentCorrupt.ContainsKey($key)) { $fake.Store[$key] = @{ Kind = $Kind; Value = 12345 }; return }
        $fake.Store[$key] = @{ Kind = $Kind; Value = $Value }
    }.GetNewClosure()
    $fake['Remove'] = {
        param([string]$Path, [string]$Name)
        [void]$fake.Log.Add("remove $Path|$Name")
        $fake.Store.Remove("$Path|$Name".ToLowerInvariant())
    }.GetNewClosure()
    return $fake
}

function Set-FakeValue {
    param($Fake, [string]$Path, [string]$Name, [string]$Kind, $Value)
    $Fake.Store["$Path|$Name".ToLowerInvariant()] = @{ Kind = $Kind; Value = $Value }
}

function Get-FakeEntry {
    param($Fake, [string]$Path, [string]$Name)
    $key = "$Path|$Name".ToLowerInvariant()
    if ($Fake.Store.ContainsKey($key)) { return $Fake.Store[$key] }
    return $null
}

function Get-FakeSnapshot {
    param($Fake)
    return ((@($Fake.Store.Keys | Sort-Object | ForEach-Object { "$_=$($Fake.Store[$_].Kind):$($Fake.Store[$_].Value)" })) -join ';')
}

function Get-FakeWriteCount {
    param($Fake)
    return @($Fake.Log | Where-Object { $_ -like 'set *' -or $_ -like 'remove *' }).Count
}

function Initialize-CpTestEnvironment {
    param([Parameter(Mandatory)][string]$Root, [int]$Build = 26200, [string]$Language = 'en-US')
    $fake = New-CpFakeRegistry
    Set-CpRegistryProvider -Provider $fake
    $dataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CorePilotTest-' + [guid]::NewGuid().ToString('N'))
    Set-CpDataRoot -Path $dataRoot
    $fixedBuild = $Build
    Set-CpBuildProvider -Provider { $fixedBuild }.GetNewClosure()
    Import-CpLocale -Root $Root -Language $Language
    Import-CpCatalog -Root $Root
    return [pscustomobject]@{ Registry = $fake; DataRoot = $dataRoot; Root = $Root }
}

function Remove-CpTestEnvironment {
    param($Environment)
    Set-CpRegistryProvider -Provider (New-CpFakeRegistry)
    Set-CpBuildProvider -Provider $null
    Set-CpDataRoot -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'CorePilotTest-unused')
    if ($Environment -and (Test-Path -LiteralPath $Environment.DataRoot)) {
        Remove-Item -LiteralPath $Environment.DataRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Start-CpOutputCapture {
    $lines = New-Object System.Collections.ArrayList
    Set-CpOutput -Sink { param([string]$Text) [void]$lines.Add($Text) }.GetNewClosure()
    return , $lines
}

$script:Adv = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$script:Pers = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$script:Mouse = 'Control Panel\Mouse'
