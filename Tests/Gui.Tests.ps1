$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Src\Load.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Set-CpRegistryProvider -Provider (New-CpFakeRegistry)

$fileExt = 'explorer.show-file-extensions'
$dark = 'appearance.dark-theme'
$protectedFiles = 'explorer.show-protected-os-files'   # Medium risk

function Get-Row { param($Ctx, [string]$Id) return @($Ctx.Rows | Where-Object { $_.Id -ceq $Id })[0] }

# The rows currently shown in the three card columns.
function Get-ShownRows {
    param($Ctx)
    $rows = New-Object System.Collections.ArrayList
    foreach ($name in 'Col1', 'Col2', 'Col3') {
        foreach ($card in @($Ctx.Controls[$name].ItemsSource)) { foreach ($row in @($card.Rows)) { [void]$rows.Add($row) } }
    }
    return $rows.ToArray()
}

function Raise-Click {
    param($Button)
    $Button.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}

Describe 'GUI model (no window)' {
    BeforeEach { $t = Initialize-CpTestEnvironment -Root $root }
    AfterEach { Remove-CpTestEnvironment $t }

    It 'builds one localized row per feature' {
        $rows = @(Get-CpGuiRows)
        $rows.Count | Should Be @(Get-CpFeatures).Count
        (@($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.Name) -or $_.Name -like 'Feature.*' })).Count | Should Be 0
    }
    It 'shows the registry state in the row and in its tooltip' {
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 0
        $row = @(Get-CpGuiRows | Where-Object { $_.Id -eq $fileExt })[0]
        $row.Status | Should Be 'Applied'
        $row.Changes | Should Match 'HideFileExt'
        $row.Tip | Should Match 'HideFileExt'
        $row.Tip | Should Match ([regex]::Escape($row.Description))
        $row.CanSelect | Should Be $true
    }
    It 'tags rows: applied, riskier ones and unavailable ones' {
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 0
        $rows = @(Get-CpGuiRows)
        $applied = @($rows | Where-Object { $_.Id -eq $fileExt })[0]
        $applied.TagKind | Should Be 'Good'
        $applied.TagText | Should Be 'Applied'
        $risky = @($rows | Where-Object { $_.Id -eq $protectedFiles })[0]
        $risky.TagKind | Should Be 'Warn'
        $risky.TagText | Should Be 'Medium risk'
        $plain = @($rows | Where-Object { $_.Id -eq $dark })[0]
        $plain.TagKind | Should Be ''
        Remove-CpTestEnvironment $t
        $t = Initialize-CpTestEnvironment -Root $root -Build 19045
        (@(Get-CpGuiRows | Where-Object { $_.Id -eq $fileExt })[0]).TagKind | Should Be 'Muted'
    }
    It 'lets you tick only what CorePilot can act on' {
        # Applied by someone else: nothing to apply and nothing saved to undo -> not tickable.
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 0
        (@(Get-CpGuiRows -Selected @{ $fileExt = $true } | Where-Object { $_.Id -eq $fileExt })[0]).CanCheck | Should Be $false
        (@(Get-CpGuiRows -Selected @{ $fileExt = $true } | Where-Object { $_.Id -eq $fileExt })[0]).Selected | Should Be $false
        # Applied by CorePilot: can be ticked to undo.
        Remove-CpTestEnvironment $t
        $t = Initialize-CpTestEnvironment -Root $root
        [void](Invoke-CpApply -FeatureId $fileExt -Approved)
        $row = @(Get-CpGuiRows -Selected @{ $fileExt = $true } | Where-Object { $_.Id -eq $fileExt })[0]
        $row.Status | Should Be 'Applied'
        $row.HasSaved | Should Be $true
        $row.CanCheck | Should Be $true
        $row.Selected | Should Be $true
    }
    It 'keeps requested checkmarks, but never on unavailable features' {
        $rows = @(Get-CpGuiRows -Selected @{ $fileExt = $true })
        (@($rows | Where-Object { $_.Id -eq $fileExt })[0]).Selected | Should Be $true
        Remove-CpTestEnvironment $t
        $t = Initialize-CpTestEnvironment -Root $root -Build 19045
        $rows = @(Get-CpGuiRows -Selected @{ $fileExt = $true })
        $row = @($rows | Where-Object { $_.Id -eq $fileExt })[0]
        $row.CanSelect | Should Be $false
        $row.CanCheck | Should Be $false
        $row.Selected | Should Be $false
        $row.Status | Should Be 'Unsupported'
    }
    It 'filters by search text' {
        $rows = @(Get-CpGuiRows)
        $hit = @(Select-CpGuiRows -Rows $rows -Search '  FILE extensions ')
        ($hit | ForEach-Object { $_.Id }) -contains $fileExt | Should Be $true
        @(Select-CpGuiRows -Rows $rows -Search 'zzzz-no-such-thing').Count | Should Be 0
        @(Select-CpGuiRows -Rows $rows -Search '[').Count | Should Be 0
        @(Select-CpGuiRows -Rows $rows).Count | Should Be $rows.Count
        $taskbarOnly = @(Select-CpGuiRows -Rows $rows -Category 'Taskbar')
        $taskbarOnly.Count | Should BeGreaterThan 3
        (@($taskbarOnly | Where-Object { $_.Category -ne 'Taskbar' })).Count | Should Be 0
    }
    It 'groups rows into one card per category, in catalog order' {
        $cards = @(Get-CpGuiCards -Rows @(Get-CpGuiRows))
        $cards.Count | Should Be (@(Get-CpFeatures | ForEach-Object { $_.category } | Select-Object -Unique).Count)
        $cards[0].Key | Should Be (@(Get-CpFeatures)[0].category)
        $total = 0
        foreach ($card in $cards) {
            $total += @($card.Rows).Count
            (@($card.Rows | Where-Object { $_.Category -cne $card.Key })).Count | Should Be 0
            $card.CountText | Should Be "($(@($card.Rows).Count))"
        }
        $total | Should Be @(Get-CpFeatures).Count
    }
    It 'spreads cards over three columns without losing or repeating any' {
        $cards = @(Get-CpGuiCards -Rows @(Get-CpGuiRows))
        $columns = @(Split-CpGuiColumns -Cards $cards -Count 3)
        $columns.Count | Should Be 3
        $keys = @($columns | ForEach-Object { $_ } | ForEach-Object { $_.Key })
        ($keys | Sort-Object) -join ',' | Should Be (($cards | ForEach-Object { $_.Key } | Sort-Object) -join ',')
        $heights = @($columns | ForEach-Object { $h = 0; foreach ($card in $_) { $h += @($card.Rows).Count + 2 }; $h })
        (($heights | Measure-Object -Maximum).Maximum - ($heights | Measure-Object -Minimum).Minimum) | Should BeLessThan 14
        @(Split-CpGuiColumns -Cards @() -Count 3).Count | Should Be 3
    }
    It 'counts only the changes that would really happen' {
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 0   # already applied
        $s = Get-CpGuiPendingSummary -Ids @($fileExt, $dark)
        $s.Features | Should Be 1
        $s.Changes | Should Be 2
        ($s.Ids -join ',') | Should Be $dark
    }
    It 'applies and undoes a selection and reports each line' {
        $a = Invoke-CpGuiOperation -Ids @($fileExt, $dark) -Action Apply
        $a.Succeeded | Should Be 2
        $a.Failed | Should Be 0
        $a.Lines.Count | Should Be 2
        (Get-FakeEntry $t.Registry $Adv 'HideFileExt').Value | Should Be 0
        $u = Invoke-CpGuiOperation -Ids @($fileExt, $dark) -Action Undo
        $u.Succeeded | Should Be 2
        ($u.Lines -join "`n") | Should Match 'Reverted'
        $null -eq (Get-FakeEntry $t.Registry $Pers 'AppsUseLightTheme') | Should Be $true
    }
    It 'reports a failure without hiding it' {
        $t.Registry.FailSetOn["$Adv|HideFileExt".ToLowerInvariant()] = $true
        $r = Invoke-CpGuiOperation -Ids @($fileExt) -Action Apply
        $r.Failed | Should Be 1
        $r.Succeeded | Should Be 0
        ($r.Lines -join "`n") | Should Match 'Access denied'
    }
    It 'lists at most 12 feature names in a question and says how many more there are' {
        $ids = @(Get-CpFeatures | Select-Object -First 20 | ForEach-Object { $_.id })
        $text = Get-CpGuiFeatureListText -Ids $ids
        @($text -split "`n").Count | Should Be 13
        $text | Should Match '\.\.\.and 8 more'
        @((Get-CpGuiFeatureListText -Ids $ids[0..2]) -split "`n").Count | Should Be 3
    }
    It 'detects the Windows color mode' {
        Set-FakeValue $t.Registry $Pers 'AppsUseLightTheme' 'DWord' 0
        Get-CpSystemUsesDarkTheme | Should Be $true
        Set-FakeValue $t.Registry $Pers 'AppsUseLightTheme' 'DWord' 1
        Get-CpSystemUsesDarkTheme | Should Be $false
    }
    It 'formats history newest first' {
        [void](Invoke-CpApply -FeatureId $fileExt -Approved)
        [void](Invoke-CpRevert -FeatureId $fileExt -Approved)
        $lines = @(Get-CpHistoryLines)
        $lines.Count | Should Be 2
        $lines[0] | Should Match 'Reverted'
        $lines[1] | Should Match 'Applied and verified'
    }
}

Describe 'GUI window (created, not shown)' {
    BeforeEach {
        $t = Initialize-CpTestEnvironment -Root $root
        $ctx = New-CpGuiWindow -Root $root -Language 'en-US'
        Connect-CpGuiEvents -Ctx $ctx
        $messages = New-Object System.Collections.ArrayList
        $ctx.Confirm = { param([string]$Text) $true }
        $ctx.Notify = { param([string]$Text) [void]$messages.Add($Text) }.GetNewClosure()
    }
    AfterEach {
        try { $ctx.Window.Close() } catch { }
        Remove-CpTestEnvironment $t
    }

    It 'has every named control and shows every feature in cards' {
        foreach ($name in $script:CpGuiControlNames) { ($null -ne $ctx.Controls[$name]) | Should Be $true }
        @(Get-ShownRows $ctx).Count | Should Be @(Get-CpFeatures).Count
        $ctx.Controls.FooterText.Text | Should Match 'selected'
        $ctx.Controls.ResultText.Text | Should Match 'Nothing is changed until you apply'
        $ctx.Controls.HintText.Text | Should Match 'hover'
    }
    It 'puts all three columns to use' {
        foreach ($name in 'Col1', 'Col2', 'Col3') { @($ctx.Controls[$name].ItemsSource).Count | Should BeGreaterThan 0 }
    }
    It 'filters the cards when typing in the search box' {
        $ctx.Controls.SearchBox.Text = 'file extensions'
        $shown = @(Get-ShownRows $ctx)
        $shown.Count | Should BeGreaterThan 0
        $shown.Count | Should BeLessThan @(Get-CpFeatures).Count
        ($shown | ForEach-Object { $_.Id }) -contains $fileExt | Should Be $true
        $ctx.Controls.FooterText.Text | Should Match ("^$($shown.Count) features shown")
        $ctx.Controls.SearchBox.Text = ''
        @(Get-ShownRows $ctx).Count | Should Be @(Get-CpFeatures).Count
    }
    It 'shows no cards at all when nothing matches' {
        $ctx.Controls.SearchBox.Text = 'zzzz-no-such-thing'
        @(Get-ShownRows $ctx).Count | Should Be 0
    }
    It 'says so when Apply is pressed with nothing selected, and writes nothing' {
        Raise-Click $ctx.Controls.ApplyButton
        $ctx.Controls.ResultText.Text | Should Match 'Select at least one'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
    It 'does not write when the confirmation is declined' {
        (Get-Row $ctx $fileExt).Selected = $true
        $ctx.Confirm = { param([string]$Text) $false }
        Invoke-CpGuiAction 'Apply'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
        $ctx.Controls.ResultText.Text | Should Match 'Nothing was changed'
    }
    It 'asks with the real number of changes and names, then applies, refreshes and clears the checkmark' {
        $asked = New-Object System.Collections.ArrayList
        $ctx.Confirm = { param([string]$Text) [void]$asked.Add($Text); $true }.GetNewClosure()
        (Get-Row $ctx $dark).Selected = $true
        (Get-Row $ctx $fileExt).Selected = $true
        Raise-Click $ctx.Controls.ApplyButton
        $asked.Count | Should Be 1
        $asked[0] | Should Match 'Apply 3 change'
        # The question names every feature that will change, including ones a filter would hide.
        $asked[0] | Should Match ([regex]::Escape((Get-CpText "Feature.$dark.Name")))
        $asked[0] | Should Match ([regex]::Escape((Get-CpText "Feature.$fileExt.Name")))
        (Get-FakeEntry $t.Registry $Adv 'HideFileExt').Value | Should Be 0
        (Get-Row $ctx $fileExt).Status | Should Be 'Applied'
        (Get-Row $ctx $fileExt).Selected | Should Be $false
        (Get-Row $ctx $fileExt).HasSaved | Should Be $true
        $ctx.Controls.ResultText.Text | Should Match '2 succeeded, 0 failed'
    }
    It 'applies features that a search filter currently hides, and says so in the question' {
        (Get-Row $ctx $dark).Selected = $true
        $ctx.Controls.SearchBox.Text = 'file extensions'
        (@(Get-ShownRows $ctx | Where-Object { $_.Id -eq $dark })).Count | Should Be 0
        $asked = New-Object System.Collections.ArrayList
        $ctx.Confirm = { param([string]$Text) [void]$asked.Add($Text); $false }.GetNewClosure()
        Invoke-CpGuiAction 'Apply'
        $asked[0] | Should Match ([regex]::Escape((Get-CpText "Feature.$dark.Name")))
    }
    It 'skips features that are already applied' {
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 0
        Invoke-CpGuiAction 'Refresh'
        (Get-Row $ctx $fileExt).Selected = $true
        Invoke-CpGuiAction 'Apply'
        $ctx.Controls.ResultText.Text | Should Match 'Nothing to change'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
    It 'undoes only features with saved originals and explains when there are none' {
        (Get-Row $ctx $fileExt).Selected = $true
        Invoke-CpGuiAction 'Undo'
        $ctx.Controls.ResultText.Text | Should Match 'None of the selected'
        Invoke-CpGuiAction 'Apply'
        (Get-Row $ctx $fileExt).Selected = $true
        Invoke-CpGuiAction 'Undo'
        $ctx.Controls.ResultText.Text | Should Match 'Reverted'
        $null -eq (Get-FakeEntry $t.Registry $Adv 'HideFileExt') | Should Be $true
    }
    It 'shows a failure in the result box and as a message' {
        $t.Registry.FailSetOn["$Adv|HideFileExt".ToLowerInvariant()] = $true
        (Get-Row $ctx $fileExt).Selected = $true
        Invoke-CpGuiAction 'Apply'
        $ctx.Controls.ResultText.Text | Should Match 'Access denied'
        $ctx.Controls.ResultText.Text | Should Match '0 succeeded, 1 failed'
        $messages.Count | Should Be 1
    }
    It 'quick select ticks only low-risk features that are not applied yet, then clear removes all' {
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 0
        Invoke-CpGuiAction 'Refresh'
        Invoke-CpGuiAction 'SelectPending'
        $selected = @($ctx.Rows | Where-Object { $_.Selected })
        $selected.Count | Should BeGreaterThan 10
        (@($selected | Where-Object { $_.Risk -ne 'Low' -or $_.Status -eq 'Applied' })).Count | Should Be 0
        (Get-Row $ctx $protectedFiles).Selected | Should Be $false
        (Get-Row $ctx $fileExt).Selected | Should Be $false
        $ctx.Controls.FooterText.Text | Should Match ("$($selected.Count) selected")
        Invoke-CpGuiAction 'ClearSelection'
        @($ctx.Rows | Where-Object { $_.Selected }).Count | Should Be 0
    }
    It 'keeps checkmarks across a refresh' {
        (Get-Row $ctx $dark).Selected = $true
        Invoke-CpGuiAction 'Refresh'
        (Get-Row $ctx $dark).Selected | Should Be $true
    }
    It 'switches to Turkish and back' {
        Invoke-CpGuiAction 'Language'
        $ctx.Controls.ApplyButton.Content | Should Be ('Se' + [char]0x00E7 + 'ilenleri uygula')
        (Get-Row $ctx $fileExt).Name | Should Be ('Dosya uzant' + [char]0x0131 + 'lar' + [char]0x0131 + 'n' + [char]0x0131 + ' g' + [char]0x00F6 + 'ster')
        Invoke-CpGuiAction 'Language'
        $ctx.Controls.ApplyButton.Content | Should Be 'Apply selected'
    }
    It 'opens and closes the history panel' {
        [void](Invoke-CpApply -FeatureId $fileExt -Approved)
        Invoke-CpGuiAction 'History'
        $ctx.Controls.HistoryPanel.Visibility | Should Be 'Visible'
        $ctx.Controls.MainBody.Visibility | Should Be 'Collapsed'
        $ctx.Controls.HistoryText.Text | Should Match 'explorer\.show-file-extensions'
        Invoke-CpGuiAction 'Back'
        $ctx.Controls.MainBody.Visibility | Should Be 'Visible'
    }
    It 'cannot check a feature that is unavailable on this Windows' {
        Remove-CpTestEnvironment $t
        $t = Initialize-CpTestEnvironment -Root $root -Build 19045
        $ctx = New-CpGuiWindow -Root $root -Language 'en-US'
        $row = Get-Row $ctx $fileExt
        $row.CanCheck | Should Be $false
        $row.TagText | Should Be 'Not available on this Windows'
    }
    It 'turns an unexpected error into a message in the window' {
        { Invoke-CpGuiAction 'NoSuchAction' } | Should Not Throw
        $ctx.Controls.ResultText.Text | Should Match 'unexpected'
    }
}

Describe 'GUI start-up failure (the window has no console to print to)' {
    BeforeEach { $t = Initialize-CpTestEnvironment -Root $root }
    AfterEach { Remove-CpTestEnvironment $t }

    It 'shows a message and writes a log when the window cannot be built' {
        $broken = Join-Path ([System.IO.Path]::GetTempPath()) ('CpBroken-' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $root -Destination $broken -Recurse
        $shown = New-Object System.Collections.ArrayList
        Set-CpGuiFatalNotifier -Handler { param([string]$Text) [void]$shown.Add($Text) }.GetNewClosure()
        try {
            Set-Content -LiteralPath (Join-Path $broken 'Gui\MainWindow.xaml') -Value '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><Grid>'
            (Show-CpGui -Root $broken -Language 'en-US') | Should Be 1
            $shown.Count | Should Be 1
            $shown[0] | Should Match 'could not open its window'
            $log = Join-Path $t.DataRoot 'gui-error.log'
            Test-Path -LiteralPath $log | Should Be $true
            # Windows words the parser's message in the user's language, but the call name "Parse" is always there.
            [System.IO.File]::ReadAllText($log) | Should Match 'Parse'
        }
        finally {
            Set-CpGuiFatalNotifier -Handler $null
            Remove-Item -LiteralPath $broken -Recurse -Force
        }
    }
    It 'reports a missing element in the window definition' {
        $broken = Join-Path ([System.IO.Path]::GetTempPath()) ('CpBroken-' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $root -Destination $broken -Recurse
        $shown = New-Object System.Collections.ArrayList
        Set-CpGuiFatalNotifier -Handler { param([string]$Text) [void]$shown.Add($Text) }.GetNewClosure()
        try {
            $xaml = [System.IO.File]::ReadAllText((Join-Path $broken 'Gui\MainWindow.xaml'), [System.Text.Encoding]::UTF8).Replace('x:Name="ApplyButton"', 'x:Name="OtherName"')
            [System.IO.File]::WriteAllText((Join-Path $broken 'Gui\MainWindow.xaml'), $xaml, (New-Object System.Text.UTF8Encoding($false)))
            (Show-CpGui -Root $broken -Language 'en-US') | Should Be 1
            $shown[0] | Should Match "named 'ApplyButton'"
        }
        finally {
            Set-CpGuiFatalNotifier -Handler $null
            Remove-Item -LiteralPath $broken -Recurse -Force
        }
    }
}
