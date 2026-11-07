# Window-independent logic of the GUI: building the rows, filtering, and running apply/undo for a selection.
# Everything here is testable without opening a window.

function Get-CpSystemUsesDarkTheme {
    try {
        $value = Read-CpRegistry -Path 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme'
        if ($value.Exists -and $value.Kind -eq 'DWord') { return ([int]$value.Value -eq 0) }
    }
    catch { }
    return $false
}

function Test-CpHasSavedOriginals {
    param([string]$Id)
    try {
        $record = Read-CpRecord -Id $Id
        return ($null -ne $record -and $script:CpRevertableStates -ccontains $record.state)
    }
    catch { return $false }
}

# One row per feature, in catalog order. $Selected maps feature id -> $true for rows that should start checked.
function Get-CpGuiRows {
    param([hashtable]$Selected = @{})
    $rows = New-Object System.Collections.ArrayList
    foreach ($feature in Get-CpFeatures) {
        $id = $feature.id
        $status = Get-CpFeatureStatus -Feature $feature
        $lines = New-Object System.Collections.ArrayList
        if ($status.Status -in @('Unsupported', 'Unknown')) {
            [void]$lines.Add((Get-CpText "Failure.$($status.Reason)"))
        }
        foreach ($item in $status.Items) {
            $now = Format-CpShownValue -Exists $item.Exists -Value $item.Current
            $mark = ' '
            if ($item.Matches) { $mark = '=' }
            [void]$lines.Add("$mark HKCU\$($item.Path)\$($item.Name)")
            [void]$lines.Add("    $now -> $($item.Target)")
        }
        $name = Get-CpText "Feature.$id.Name"
        $description = Get-CpText "Feature.$id.Description"
        $reboot = ''
        if ($feature.reboot -ne 'None') { $reboot = Get-CpText "Reboot.$($feature.reboot)" }
        $canSelect = ($status.Status -notin @('Unsupported', 'Unknown'))
        $hasSaved = Test-CpHasSavedOriginals -Id $id
        # A box can be ticked when there is something CorePilot can do: apply it, or undo what it saved.
        $canCheck = ($canSelect -and ($status.Status -ne 'Applied' -or $hasSaved))

        $tagKind = ''
        $tagText = ''
        switch ($status.Status) {
            'Applied' { $tagKind = 'Good'; $tagText = Get-CpText 'Status.Applied' }
            'Partial' { $tagKind = 'Warn'; $tagText = Get-CpText 'Status.Partial' }
            'Unsupported' { $tagKind = 'Muted'; $tagText = Get-CpText 'Status.Unsupported' }
            'Unknown' { $tagKind = 'Muted'; $tagText = Get-CpText 'Status.Unknown' }
            default {
                if ($feature.risk -ne 'Low') { $tagKind = 'Warn'; $tagText = Get-CpText 'Gui.RiskTag' @((Get-CpText "Risk.$($feature.risk)")) }
            }
        }

        $tip = New-Object System.Collections.ArrayList
        [void]$tip.Add($name)
        [void]$tip.Add('')
        [void]$tip.Add($description)
        [void]$tip.Add('')
        [void]$tip.Add("$(Get-CpText 'Col.Risk'): $(Get-CpText "Risk.$($feature.risk)")    $(Get-CpText 'Col.Status'): $(Get-CpText "Status.$($status.Status)")")
        if ($reboot) { [void]$tip.Add($reboot) }
        if ($hasSaved) { [void]$tip.Add("$(Get-CpText 'Gui.DetailSaved'): $(Get-CpText 'Gui.Yes')") }
        [void]$tip.Add('')
        [void]$tip.Add((Get-CpText 'Gui.DetailChanges'))
        [void]$tip.Add(($lines -join "`n"))

        [void]$rows.Add([pscustomobject]@{
                Id           = $id
                Name         = $name
                Description  = $description
                Category     = $feature.category
                CategoryText = (Get-CpText "Category.$($feature.category)")
                Risk         = $feature.risk
                RiskText     = (Get-CpText "Risk.$($feature.risk)")
                Status       = $status.Status
                StatusText   = (Get-CpText "Status.$($status.Status)")
                Selected     = ($canCheck -and $Selected.ContainsKey($id) -and [bool]$Selected[$id])
                CanSelect    = $canSelect
                CanCheck     = $canCheck
                RebootText   = $reboot
                HasSaved     = $hasSaved
                TagKind      = $tagKind
                TagText      = $tagText
                Tip          = ($tip -join "`n")
                Changes      = ($lines -join "`n")
                Search       = ("$id $name $description " + (Get-CpText "Category.$($feature.category)")).ToLowerInvariant()
            })
    }
    return $rows.ToArray()
}

# $Category: a category key, or '*' for all. $Search: free text, matched against id, name, description and category.
function Select-CpGuiRows {
    param($Rows, [string]$Category = '*', [string]$Search = '')
    $query = $Search.Trim().ToLowerInvariant()
    foreach ($row in @($Rows)) {
        if ($Category -ne '*' -and $row.Category -cne $Category) { continue }
        if ($query -and -not $row.Search.Contains($query)) { continue }
        $row
    }
}

# One card per category (in catalog order) holding that category's rows.
function Get-CpGuiCards {
    param($Rows)
    $cards = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($row in @($Rows)) {
        if ($seen.ContainsKey($row.Category)) { continue }
        $seen[$row.Category] = $true
        $inCategory = @($Rows | Where-Object { $_.Category -ceq $row.Category })
        [void]$cards.Add([pscustomobject]@{
                Key       = $row.Category
                Title     = $row.CategoryText
                CountText = "($($inCategory.Count))"
                Rows      = $inCategory
            })
    }
    return $cards.ToArray()
}

# Spreads cards over $Count columns, always adding to the shortest one, so the page looks balanced.
# Returns $Count lists of cards.
function Split-CpGuiColumns {
    param($Cards, [int]$Count = 3)
    $columns = New-Object 'System.Collections.ArrayList[]' $Count
    for ($i = 0; $i -lt $Count; $i++) { $columns[$i] = New-Object System.Collections.ArrayList }
    $weights = New-Object 'int[]' $Count
    foreach ($card in @($Cards)) {
        $target = 0
        for ($i = 1; $i -lt $Count; $i++) { if ($weights[$i] -lt $weights[$target]) { $target = $i } }
        [void]$columns[$target].Add($card)
        $weights[$target] += @($card.Rows).Count + 2
    }
    return $columns
}

# For the selected ids: how many features and registry values would really change.
function Get-CpGuiPendingSummary {
    param([string[]]$Ids)
    $features = 0
    $changes = 0
    $pendingIds = New-Object System.Collections.ArrayList
    foreach ($id in $Ids) {
        $feature = Get-CpFeature -Id $id
        if ($null -eq $feature) { continue }
        $status = Get-CpFeatureStatus -Feature $feature
        $open = @($status.Items | Where-Object { -not $_.Matches }).Count
        if ($open -gt 0) { $features++; $changes += $open; [void]$pendingIds.Add($id) }
    }
    return [pscustomobject]@{ Features = $features; Changes = $changes; Ids = $pendingIds.ToArray() }
}

# Runs apply or undo for each id. The caller has already asked the user.
function Invoke-CpGuiOperation {
    param([string[]]$Ids, [ValidateSet('Apply', 'Undo')][string]$Action)
    $lines = New-Object System.Collections.ArrayList
    $hints = New-Object System.Collections.ArrayList
    $okIds = New-Object System.Collections.ArrayList
    $failed = 0
    foreach ($id in $Ids) {
        $feature = Get-CpFeature -Id $id
        if ($null -eq $feature) { continue }
        if ($Action -eq 'Apply') { $result = Invoke-CpApply -FeatureId $id -Approved }
        else { $result = Invoke-CpRevert -FeatureId $id -Approved }
        $name = Get-CpFeatureName $feature
        if ($result.Success -and $result.Status -eq 'Verified') {
            [void]$lines.Add((Get-CpText 'Cli.AppliedOk' @($name)))
            [void]$okIds.Add($id)
            if ($feature.reboot -ne 'None') {
                $hint = Get-CpText "Reboot.$($feature.reboot)"
                if ($hints -notcontains $hint) { [void]$hints.Add($hint) }
            }
        }
        elseif ($result.Success -and $result.Status -eq 'Reverted') {
            [void]$lines.Add((Get-CpText 'Cli.RevertedOk' @($name)))
            [void]$okIds.Add($id)
        }
        elseif ($result.Success) {
            [void]$lines.Add((Get-CpText 'Cli.FailedLine' @($name, (Get-CpText "Failure.$($result.Reason)"))))
        }
        else {
            $failed++
            [void]$lines.Add((Get-CpFailureText -Feature $feature -Result $result))
        }
    }
    return [pscustomobject]@{
        Succeeded = $okIds.Count
        Failed    = $failed
        OkIds     = $okIds.ToArray()
        Lines     = $lines.ToArray()
        Hints     = $hints.ToArray()
    }
}

function Get-CpHistoryLines {
    $entries = @(Get-CpHistory -Last 200)
    if ($entries.Count -eq 0) { return @(Get-CpText 'Cli.HistoryEmpty') }
    $lines = New-Object System.Collections.ArrayList
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $entry = $entries[$i]
        $detail = ''
        if ($entry.reason) { $detail = ' - ' + (Get-CpText "Failure.$($entry.reason)") }
        $when = [DateTime]::Parse($entry.timeUtc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        [void]$lines.Add(('{0}  {1}  {2}: {3}{4}' -f $when, $entry.featureId, (Get-CpText "Action.$($entry.action)"), (Get-CpText "State.$($entry.status)"), $detail))
    }
    return $lines.ToArray()
}
