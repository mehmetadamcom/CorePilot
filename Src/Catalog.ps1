$script:CpCatalog = $null
$script:CpAllowedTargets = @{}
$script:CpCategories = @('Privacy', 'Taskbar', 'Explorer', 'Start', 'Search', 'Appearance', 'Multitasking', 'Gaming', 'AI', 'Input')
$script:CpRisks = @('Low', 'Medium', 'High')
$script:CpRebootKinds = @('None', 'ExplorerRestart', 'SignOut', 'Reboot')
$script:CpIdPattern = '^[a-z0-9]+([.-][a-z0-9]+)*$'

function Get-CpTargetKey {
    param([string]$Path, [string]$Name)
    return ('{0}|{1}' -f $Path.ToLowerInvariant(), $Name.ToLowerInvariant())
}

# Returns a list of human-readable problems; an empty list means the catalog is sound.
function Test-CpCatalog {
    param([Parameter(Mandatory)]$Catalog)

    $problems = New-Object System.Collections.Generic.List[string]
    $ids = @{}
    $targets = @{}

    if ($Catalog.schema -ne 1) { $problems.Add('schema must be 1') }
    $features = @($Catalog.features)
    if ($features.Count -eq 0) { $problems.Add('catalog has no features') }

    foreach ($feature in $features) {
        $id = [string]$feature.id
        # Regexes here are case-sensitive (-cmatch) on purpose: case-insensitive matching follows the current culture,
        # and in Turkish an upper-case I no longer matches [a-z] or i.
        if ($id -cnotmatch $script:CpIdPattern) { $problems.Add("bad id '$id'"); continue }
        if ($ids.ContainsKey($id)) { $problems.Add("duplicate id '$id'") }
        $ids[$id] = $true

        if ($script:CpCategories -cnotcontains [string]$feature.category) { $problems.Add("$id : unknown category '$($feature.category)'") }
        if ($script:CpRisks -cnotcontains [string]$feature.risk) { $problems.Add("$id : unknown risk '$($feature.risk)'") }
        if ($script:CpRebootKinds -cnotcontains [string]$feature.reboot) { $problems.Add("$id : unknown reboot kind '$($feature.reboot)'") }
        if (-not ($feature.minBuild -is [int] -or $feature.minBuild -is [long]) -or $feature.minBuild -lt 1) { $problems.Add("$id : minBuild must be a positive integer") }

        $changes = @($feature.changes)
        if ($changes.Count -eq 0) { $problems.Add("$id : has no changes"); continue }
        foreach ($change in $changes) {
            $path = [string]$change.path
            $name = [string]$change.name
            if ($path -cnotmatch '^(Software|Control Panel)(\\[A-Za-z0-9 _.\-]+)+$' -or $path.Contains('..')) { $problems.Add("$id : path '$path' is not an allowed HKCU path") }
            if ($name -cnotmatch '^[A-Za-z0-9_.\- ]+$') { $problems.Add("$id : bad value name '$name'") }
            switch ([string]$change.type) {
                'DWord' {
                    if (-not ($change.value -is [int] -or $change.value -is [long]) -or $change.value -lt 0 -or $change.value -gt 2147483647) {
                        $problems.Add("$id : DWord value for '$name' must be an integer from 0 to 2147483647")
                    }
                }
                'String' {
                    if (-not ($change.value -is [string])) { $problems.Add("$id : String value for '$name' must be a string") }
                }
                default { $problems.Add("$id : unsupported type '$($change.type)' for '$name'") }
            }
            $key = Get-CpTargetKey -Path $path -Name $name
            if ($targets.ContainsKey($key)) { $problems.Add("$id : target '$path\$name' is already used by '$($targets[$key])'") }
            $targets[$key] = $id
        }
    }
    return $problems.ToArray()
}

function Import-CpCatalog {
    param([Parameter(Mandatory)][string]$Root)
    $catalog = Read-CpJson (Join-Path $Root 'Data\Features.json')
    $problems = @(Test-CpCatalog -Catalog $catalog)
    if ($problems.Count -gt 0) {
        throw ("The feature catalog is invalid:`n" + ($problems -join "`n"))
    }
    $allowed = @{}
    foreach ($feature in @($catalog.features)) {
        foreach ($change in @($feature.changes)) {
            $allowed[(Get-CpTargetKey -Path $change.path -Name $change.name)] = $feature.id
        }
    }
    $script:CpAllowedTargets = $allowed
    $script:CpCatalog = $catalog
}

function Get-CpFeatures {
    return @($script:CpCatalog.features)
}

function Get-CpFeature {
    param([Parameter(Mandatory)][string]$Id)
    foreach ($feature in @($script:CpCatalog.features)) {
        if ($feature.id -ceq $Id) { return $feature }
    }
    return $null
}

function Test-CpAllowedTarget {
    param([string]$Path, [string]$Name)
    return $script:CpAllowedTargets.ContainsKey((Get-CpTargetKey -Path $Path -Name $Name))
}
