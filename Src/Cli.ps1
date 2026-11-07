# Command-line front end. Invoke-CpCli returns an exit code: 0 ok, 1 something failed, 2 bad usage.

$script:CpOutput = { param([string]$Text) Write-Host $Text }
$script:CpConfirm = {
    param([string]$Prompt)
    try { $answer = Read-Host -Prompt $Prompt } catch { return $false }
    return ([string]$answer).Trim().ToLowerInvariant() -cmatch '^(y|yes|e|evet)$'
}

function Set-CpOutput { param([scriptblock]$Sink) $script:CpOutput = $Sink }
function Set-CpConfirm { param([scriptblock]$Handler) $script:CpConfirm = $Handler }

function Write-CpLine {
    param([string]$Text = '')
    $sink = $script:CpOutput
    & $sink $Text
}

function Write-CpTable {
    param([string[]]$Headers, $Rows)
    $widths = @($Headers | ForEach-Object { $_.Length })
    foreach ($row in $Rows) {
        for ($i = 0; $i -lt $widths.Count; $i++) {
            if ($row[$i].Length -gt $widths[$i]) { $widths[$i] = $row[$i].Length }
        }
    }
    $format = {
        param($cells)
        $parts = for ($i = 0; $i -lt $widths.Count; $i++) { ([string]$cells[$i]).PadRight($widths[$i]) }
        ($parts -join '  ').TrimEnd()
    }
    Write-CpLine (& $format $Headers)
    Write-CpLine ((@($widths | ForEach-Object { '-' * $_ })) -join '  ')
    foreach ($row in $Rows) { Write-CpLine (& $format $row) }
}

function Get-CpFeatureName { param($Feature) return (Get-CpText "Feature.$($Feature.id).Name") }

function Format-CpShownValue {
    param([bool]$Exists, $Value)
    if (-not $Exists) { return (Get-CpText 'Cli.NotSet') }
    return [string]$Value
}

function Get-CpFailureText {
    param($Feature, $Result)
    $text = Get-CpText "Failure.$($Result.Reason)"
    if ($Result.Detail) { $text = "$text ($($Result.Detail))" }
    return (Get-CpText 'Cli.FailedLine' @((Get-CpFeatureName $Feature), $text))
}

function Write-CpFailure {
    param($Feature, $Result)
    Write-CpLine (Get-CpFailureText -Feature $Feature -Result $Result)
}

function Write-CpRecoveryWarning {
    $pending = @(Get-CpRecordsNeedingRecovery)
    if ($pending.Count -gt 0) { Write-CpLine (Get-CpText 'Cli.RecoveryWarning' @($pending.Count)) }
}

function Show-CpList {
    $features = Get-CpFeatures
    Write-CpLine (Get-CpText 'Cli.ListTitle' @($features.Count))
    Write-CpLine (Get-CpText 'Cli.BuildLine' @((Get-CpWindowsBuild)))
    Write-CpLine ''
    $rows = New-Object System.Collections.ArrayList
    foreach ($feature in $features) {
        $status = Get-CpFeatureStatus -Feature $feature
        [void]$rows.Add([string[]]@(
                $feature.id,
                (Get-CpText "Category.$($feature.category)"),
                (Get-CpText "Risk.$($feature.risk)"),
                (Get-CpText "Status.$($status.Status)")))
    }
    Write-CpTable -Headers @((Get-CpText 'Col.Id'), (Get-CpText 'Col.Category'), (Get-CpText 'Col.Risk'), (Get-CpText 'Col.Status')) -Rows $rows
    Write-CpLine ''
    Write-CpRecoveryWarning
}

function Show-CpHistory {
    $entries = @(Get-CpHistory)
    if ($entries.Count -eq 0) { Write-CpLine (Get-CpText 'Cli.HistoryEmpty') }
    else {
        $rows = New-Object System.Collections.ArrayList
        foreach ($entry in $entries) {
            $detail = ''
            if ($entry.reason) { $detail = Get-CpText "Failure.$($entry.reason)" }
            [void]$rows.Add([string[]]@(
                    ([DateTime]::Parse($entry.timeUtc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')),
                    $entry.featureId,
                    (Get-CpText "Action.$($entry.action)"),
                    (Get-CpText "State.$($entry.status)"),
                    $detail))
        }
        Write-CpTable -Headers @((Get-CpText 'Col.Time'), (Get-CpText 'Col.Feature'), (Get-CpText 'Col.Action'), (Get-CpText 'Col.Result'), (Get-CpText 'Col.Detail')) -Rows $rows
    }
    Write-CpLine ''
    Write-CpRecoveryWarning
}

# Prints what would change; returns the number of pending changes (0 when nothing to do or unsupported).
function Show-CpPreview {
    param($Feature)
    $status = Get-CpFeatureStatus -Feature $Feature
    $name = Get-CpFeatureName $Feature
    Write-CpLine (Get-CpText 'Cli.PreviewTitle' @($name))
    if ($status.Status -eq 'Unsupported') { Write-CpLine ('  ' + (Get-CpText "Failure.$($status.Reason)")); return 0 }
    if ($status.Status -eq 'Unknown') { Write-CpLine ('  ' + (Get-CpText "Failure.$($status.Reason)")); return 0 }
    $pending = 0
    foreach ($item in $status.Items) {
        if ($item.Matches) { continue }
        $pending++
        $from = Format-CpShownValue -Exists $item.Exists -Value $item.Current
        Write-CpLine ('  ' + (Get-CpText 'Cli.Change' @("HKCU\$($item.Path)\$($item.Name)", $from, $item.Target)))
    }
    if ($pending -eq 0) { Write-CpLine ('  ' + (Get-CpText 'Failure.already-applied')) }
    return $pending
}

function Get-CpAppDisplayName { param($App) return "$($App.name) ($($App.id))" }

# Lists the selected apps (and what would be removed) without changing anything. Returns the removable apps.
function Show-CpAppPreview {
    param([object[]]$Selected, [switch]$ListOnly)
    $statuses = @{}
    foreach ($item in (Get-CpAppStatusList)) { $statuses[$item.AppId] = $item }
    $removable = New-Object System.Collections.ArrayList
    if ($ListOnly) {
        Write-CpLine (Get-CpText 'Cli.AppListTitle' @($Selected.Count))
        Write-CpLine ''
        $rows = New-Object System.Collections.ArrayList
        foreach ($app in $Selected) {
            $state = $statuses[$app.id]
            $version = ''
            if (@($state.Packages).Count -gt 0) { $version = [string]@($state.Packages)[0].Version }
            [void]$rows.Add([string[]]@($app.id, $app.name, (Get-CpText "Safety.$($app.safety)"), (Get-CpText "AppStatus.$($state.Status)"), $version))
        }
        Write-CpTable -Headers @((Get-CpText 'Col.Id'), (Get-CpText 'Col.Name'), (Get-CpText 'Col.Safety'), (Get-CpText 'Col.Status'), (Get-CpText 'Col.Version')) -Rows $rows
    }
    foreach ($app in $Selected) {
        $state = $statuses[$app.id]
        if ($state.Status -eq 'Installed') { [void]$removable.Add($app) }
    }
    return $removable.ToArray()
}

# -App: list or preview (read only), -App ... -Remove: remove after the confirmations. Returns an exit code.
function Invoke-CpCliApps {
    param([string[]]$Patterns, [switch]$Remove, [switch]$AllowUnsafe, [switch]$Yes, [switch]$PreviewOnly)
    try { Import-CpAppCatalog -Root $script:CpCliRoot }
    catch {
        Write-CpLine (Get-CpText 'Failure.unexpected')
        Write-CpLine $_.Exception.Message
        return 1
    }
    $selected = New-Object System.Collections.ArrayList
    $unknown = $false
    foreach ($pattern in $Patterns) {
        $found = @(Get-CpApps | Where-Object { $_.id -like $pattern })
        if ($found.Count -eq 0) { Write-CpLine (Get-CpText 'Cli.UnknownApp' @($pattern)); $unknown = $true; continue }
        foreach ($item in $found) { if ($selected -notcontains $item) { [void]$selected.Add($item) } }
    }
    if ($unknown) { return 2 }

    if (-not $Remove -or $PreviewOnly) {
        $null = Show-CpAppPreview -Selected $selected.ToArray() -ListOnly
        Write-CpLine ''
        Write-CpLine (Get-CpText 'Cli.AppPreviewNote')
        return 0
    }

    $removable = @(Show-CpAppPreview -Selected $selected.ToArray())
    foreach ($app in $selected) {
        if ($removable -notcontains $app) {
            $state = Get-CpAppStatus -AppId $app.id
            if ($null -ne $state -and $state.Status -eq 'Protected') { Write-CpLine (Get-CpText 'Cli.AppProtected' @((Get-CpAppDisplayName $app))) }
            else { Write-CpLine (Get-CpText 'Cli.AppNotInstalled' @((Get-CpAppDisplayName $app))) }
        }
    }
    if ($removable.Count -eq 0) { Write-CpLine (Get-CpText 'Cli.AppNothing'); return 0 }

    Write-CpLine (Get-CpText 'Cli.AppPreviewTitle')
    foreach ($app in $removable) {
        $state = Get-CpAppStatus -AppId $app.id
        Write-CpLine (Get-CpText 'Cli.AppLine' @((Get-CpAppDisplayName $app), (Get-CpText "Safety.$($app.safety)"), [string]@($state.Packages)[0].Version))
    }

    $unsafe = @($removable | Where-Object { $_.safety -ceq 'Unsafe' })
    $allowUnsafeNow = [bool]$AllowUnsafe
    if (-not $Yes) {
        $confirm = $script:CpConfirm
        if (-not (& $confirm (Get-CpText 'Cli.ConfirmRemove' @($removable.Count)))) {
            Write-CpLine (Get-CpText 'Cli.Cancelled')
            return 0
        }
        if ($unsafe.Count -gt 0 -and -not $allowUnsafeNow) {
            $allowUnsafeNow = [bool](& $confirm (Get-CpText 'Cli.ConfirmUnsafe' @($unsafe.Count)))
        }
    }

    $exitCode = 0
    foreach ($app in $removable) {
        if ($app.safety -ceq 'Unsafe' -and -not $allowUnsafeNow) {
            Write-CpLine (Get-CpText 'Cli.UnsafeSkipped' @((Get-CpAppDisplayName $app)))
            continue
        }
        $result = Invoke-CpAppRemove -AppId $app.id -Approved -AllowUnsafe:$allowUnsafeNow
        if ($result.Success -and $result.Status -eq 'Removed') {
            Write-CpLine (Get-CpText 'Cli.RemovedOk' @((Get-CpAppDisplayName $app)))
            foreach ($package in @($result.Packages)) {
                $link = Get-CpAppReinstallLink -FamilyName $package.PackageFamilyName
                if ($link) { Write-CpLine (Get-CpText 'Cli.ReinstallHint' @($link)) }
            }
        }
        elseif ($result.Success) { Write-CpLine (Get-CpText 'Cli.AppNotInstalled' @((Get-CpAppDisplayName $app))) }
        else {
            $text = Get-CpText "Failure.$($result.Reason)"
            if ($result.Detail) { $text = "$text ($($result.Detail))" }
            Write-CpLine (Get-CpText 'Cli.FailedLine' @((Get-CpAppDisplayName $app), $text))
            $exitCode = 1
        }
    }
    return $exitCode
}

$script:CpCliRoot = $null

function Invoke-CpCli {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$Feature = @(),
        [string[]]$App = @(),
        [switch]$Apply,
        [switch]$Undo,
        [switch]$Remove,
        [switch]$AllowUnsafe,
        [switch]$Yes,
        [switch]$History,
        [switch]$PreviewOnly,
        [string]$Language
    )
    Import-CpLocale -Root $Root -Language $Language
    $script:CpCliRoot = $Root
    try { Import-CpCatalog -Root $Root }
    catch {
        Write-CpLine (Get-CpText 'Failure.unexpected')
        Write-CpLine $_.Exception.Message
        return 1
    }

    # "powershell -File" passes "a,b" as one string, so accept comma-separated ids as well.
    $Feature = @($Feature | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $App = @($App | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    if ($Apply -and $Undo) { Write-CpLine (Get-CpText 'Cli.NothingToDo'); return 2 }
    if ($History) { Show-CpHistory; return 0 }
    if ($App.Count -gt 0 -or $Remove) {
        if ($App.Count -eq 0 -or $Feature.Count -gt 0 -or $Apply -or $Undo) { Write-CpLine (Get-CpText 'Cli.NothingToDo'); return 2 }
        return (Invoke-CpCliApps -Patterns $App -Remove:$Remove -AllowUnsafe:$AllowUnsafe -Yes:$Yes -PreviewOnly:$PreviewOnly)
    }
    if ($Feature.Count -eq 0) {
        if ($Apply -or $Undo) { Write-CpLine (Get-CpText 'Cli.NothingToDo'); return 2 }
        Show-CpList
        return 0
    }

    $selected = New-Object System.Collections.ArrayList
    $unknown = $false
    foreach ($pattern in $Feature) {
        $found = @(Get-CpFeatures | Where-Object { $_.id -like $pattern })
        if ($found.Count -eq 0) { Write-CpLine (Get-CpText 'Cli.UnknownFeature' @($pattern)); $unknown = $true; continue }
        foreach ($item in $found) { if ($selected -notcontains $item) { [void]$selected.Add($item) } }
    }
    if ($unknown) { return 2 }

    if ($Undo) { return (Invoke-CpCliUndo -Selected $selected.ToArray() -Yes:$Yes) }

    $pendingTotal = 0
    foreach ($item in $selected) { $pendingTotal += (Show-CpPreview -Feature $item) }
    if (-not $Apply -or $PreviewOnly) {
        Write-CpLine ''
        Write-CpLine (Get-CpText 'Cli.PreviewNote')
        return 0
    }
    if ($pendingTotal -eq 0) { return 0 }

    if (-not $Yes) {
        $confirm = $script:CpConfirm
        if (-not (& $confirm (Get-CpText 'Cli.ConfirmApply' @($pendingTotal)))) {
            Write-CpLine (Get-CpText 'Cli.Cancelled')
            return 0
        }
    }

    $exitCode = 0
    foreach ($item in $selected) {
        $result = Invoke-CpApply -FeatureId $item.id -Approved
        if ($result.Success -and $result.Status -eq 'Verified') {
            Write-CpLine (Get-CpText 'Cli.AppliedOk' @((Get-CpFeatureName $item)))
            if ($item.reboot -ne 'None') { Write-CpLine ('  ' + (Get-CpText "Reboot.$($item.reboot)")) }
        }
        elseif ($result.Success) { Write-CpLine (Get-CpText 'Cli.FailedLine' @((Get-CpFeatureName $item), (Get-CpText "Failure.$($result.Reason)"))) }
        else { Write-CpFailure -Feature $item -Result $result; $exitCode = 1 }
    }
    return $exitCode
}

function Invoke-CpCliUndo {
    param([object[]]$Selected, [switch]$Yes)
    if (-not $Yes) {
        $confirm = $script:CpConfirm
        if (-not (& $confirm (Get-CpText 'Cli.ConfirmUndo' @($Selected.Count)))) {
            Write-CpLine (Get-CpText 'Cli.Cancelled')
            return 0
        }
    }
    $exitCode = 0
    foreach ($item in $Selected) {
        $result = Invoke-CpRevert -FeatureId $item.id -Approved
        if ($result.Success) { Write-CpLine (Get-CpText 'Cli.RevertedOk' @((Get-CpFeatureName $item))) }
        else { Write-CpFailure -Feature $item -Result $result; $exitCode = 1 }
    }
    return $exitCode
}
