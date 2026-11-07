$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Src\Load.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Set-CpRegistryProvider -Provider (New-CpFakeRegistry)
Set-CpAppProvider -Provider (New-CpFakeAppProvider)

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

Describe 'GUI app rows (no window)' {
    BeforeEach { $t = Initialize-CpTestEnvironment -Root $root }
    AfterEach { Remove-CpTestEnvironment $t }

    It 'lists installed and protected apps only, in safety groups' {
        Add-FakePackage $t.Apps 'Microsoft.BingNews' -Version '4.55.0.0' | Out-Null
        Add-FakePackage $t.Apps 'Microsoft.Paint' | Out-Null
        Add-FakePackage $t.Apps 'Microsoft.WindowsStore' -NonRemovable $true | Out-Null
        $rows = @(Get-CpGuiAppRows)
        ($rows | ForEach-Object { $_.Id }) -join ',' | Should Be 'app.bing-news,app.paint,app.store'
        (@($rows | Where-Object { $_.Id -eq 'app.bing-news' })[0]).CanCheck | Should Be $true
        (@($rows | Where-Object { $_.Id -eq 'app.store' })[0]).CanCheck | Should Be $false
        (@($rows | Where-Object { $_.Id -eq 'app.store' })[0]).TagText | Should Be 'Protected by Windows'
        $cards = @(Get-CpGuiCards -Rows $rows)
        $cards.Count | Should Be 3
        $cards[0].Title | Should Match 'Safe to remove'
        (@($rows | Where-Object { $_.Id -eq 'app.bing-news' })[0]).Tip | Should Match 'cannot undo'
        (@($rows | Where-Object { $_.Id -eq 'app.bing-news' })[0]).Tip | Should Match '4\.55\.0\.0'
    }
    It 'marks Unsafe apps and keeps requested checkmarks only for apps that can be removed' {
        Add-FakePackage $t.Apps 'Microsoft.Xbox.TCUI' | Out-Null
        Add-FakePackage $t.Apps 'Microsoft.WindowsStore' -NonRemovable $true | Out-Null
        $rows = @(Get-CpGuiAppRows -Selected @{ 'app.xbox-tcui' = $true; 'app.store' = $true })
        $tcui = @($rows | Where-Object { $_.Id -eq 'app.xbox-tcui' })[0]
        $tcui.Selected | Should Be $true
        $tcui.TagText | Should Be 'Unsafe'
        (@($rows | Where-Object { $_.Id -eq 'app.store' })[0]).Selected | Should Be $false
    }
    It 'shows every app as Unknown when the app list cannot be read' {
        $t.Apps.FailList = $true
        $rows = @(Get-CpGuiAppRows)
        $rows.Count | Should Be @(Get-CpApps).Count
        @($rows | Where-Object { $_.Status -ne 'Unknown' }).Count | Should Be 0
        @($rows | Where-Object { $_.CanCheck }).Count | Should Be 0
    }
    It 'removes the given apps and skips Unsafe ones that were not confirmed separately' {
        Add-FakePackage $t.Apps 'Microsoft.BingNews' | Out-Null
        Add-FakePackage $t.Apps 'Microsoft.Xbox.TCUI' | Out-Null
        $r = Invoke-CpGuiAppOperation -Ids @('app.bing-news', 'app.xbox-tcui')
        $r.Succeeded | Should Be 1
        $r.Failed | Should Be 0
        (@($t.Apps.Packages | ForEach-Object { $_.Name })) -join ',' | Should Be 'Microsoft.Xbox.TCUI'
        ($r.Lines -join "`n") | Should Match 'Skipped \(Unsafe'
        $r2 = Invoke-CpGuiAppOperation -Ids @('app.xbox-tcui') -AllowUnsafeIds @('app.xbox-tcui')
        $r2.Succeeded | Should Be 1
        @($t.Apps.Packages).Count | Should Be 0
    }
}

Describe 'GUI window: apps view (created, not shown)' {
    BeforeEach {
        $t = Initialize-CpTestEnvironment -Root $root
        Add-FakePackage $t.Apps 'Microsoft.BingNews' | Out-Null
        Add-FakePackage $t.Apps 'Microsoft.BingWeather' | Out-Null
        Add-FakePackage $t.Apps 'Microsoft.Paint' | Out-Null
        Add-FakePackage $t.Apps 'Microsoft.Xbox.TCUI' | Out-Null
        Add-FakePackage $t.Apps 'Claude' | Out-Null
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
    function Get-AppRow { param($Ctx, [string]$Id) return @($Ctx.AppRows | Where-Object { $_.Id -ceq $Id })[0] }

    It 'starts in the settings view and does not read the apps until asked' {
        $ctx.Mode | Should Be 'Settings'
        @($t.Apps.Log | Where-Object { $_ -eq 'list' }).Count | Should Be 0
        $ctx.Controls.ApplyButton.Content | Should Be 'Apply selected'
    }
    It 'switches to the apps view: only installed catalog apps, Remove button, no quick select or undo' {
        Raise-Click $ctx.Controls.ModeAppsButton
        $ctx.Mode | Should Be 'Apps'
        (@(Get-ShownRows $ctx) | ForEach-Object { $_.Id } | Sort-Object) -join ',' | Should Be 'app.bing-news,app.bing-weather,app.paint,app.xbox-tcui'
        $ctx.Controls.ApplyButton.Content | Should Be 'Remove selected'
        $ctx.Controls.UndoButton.Visibility.ToString() | Should Be 'Collapsed'
        $ctx.Controls.SelectPendingButton.Visibility.ToString() | Should Be 'Collapsed'
        $ctx.Controls.FooterText.Text | Should Match '^4 apps shown, 0 selected'
        $ctx.Controls.HintText.Text | Should Match 'cannot undo'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'never offers apps that are not in the catalog' {
        Raise-Click $ctx.Controls.ModeAppsButton
        (@(Get-ShownRows $ctx) | ForEach-Object { $_.Name }) -contains 'Claude' | Should Be $false
    }
    It 'goes back to the settings view with its buttons' {
        Raise-Click $ctx.Controls.ModeAppsButton
        Raise-Click $ctx.Controls.ModeSettingsButton
        $ctx.Mode | Should Be 'Settings'
        @(Get-ShownRows $ctx).Count | Should Be @(Get-CpFeatures).Count
        $ctx.Controls.UndoButton.Visibility.ToString() | Should Be 'Visible'
        $ctx.Controls.SelectPendingButton.Visibility.ToString() | Should Be 'Visible'
        $ctx.Controls.ApplyButton.Content | Should Be 'Apply selected'
    }
    It 'filters apps by search text and clears the search when switching views' {
        Raise-Click $ctx.Controls.ModeAppsButton
        $ctx.Controls.SearchBox.Text = 'weather'
        (@(Get-ShownRows $ctx) | ForEach-Object { $_.Id }) -join ',' | Should Be 'app.bing-weather'
        Raise-Click $ctx.Controls.ModeSettingsButton
        $ctx.Controls.SearchBox.Text | Should Be ''
    }
    It 'says so when Remove is pressed with nothing ticked, and removes nothing' {
        Raise-Click $ctx.Controls.ModeAppsButton
        Raise-Click $ctx.Controls.ApplyButton
        $ctx.Controls.ResultText.Text | Should Match 'Select at least one'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'does not remove when the question is declined' {
        Raise-Click $ctx.Controls.ModeAppsButton
        (Get-AppRow $ctx 'app.bing-news').Selected = $true
        $ctx.Confirm = { param([string]$Text) $false }
        Invoke-CpGuiAction 'Apply'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
        $ctx.Controls.ResultText.Text | Should Match 'Nothing was changed'
    }
    It 'asks with the names and a no-undo warning, removes, refreshes the list and clears the checkmark' {
        $asked = New-Object System.Collections.ArrayList
        $ctx.Confirm = { param([string]$Text) [void]$asked.Add($Text); $true }.GetNewClosure()
        Raise-Click $ctx.Controls.ModeAppsButton
        (Get-AppRow $ctx 'app.bing-news').Selected = $true
        (Get-AppRow $ctx 'app.paint').Selected = $true
        Raise-Click $ctx.Controls.ApplyButton
        $asked.Count | Should Be 1
        $asked[0] | Should Match 'Remove 2 app'
        $asked[0] | Should Match 'cannot undo'
        $asked[0] | Should Match '- Microsoft News'
        $asked[0] | Should Match '- Paint'
        (@($t.Apps.Packages | ForEach-Object { $_.Name }) | Sort-Object) -join ',' | Should Be 'Claude,Microsoft.BingWeather,Microsoft.Xbox.TCUI'
        (@(Get-ShownRows $ctx) | ForEach-Object { $_.Id } | Sort-Object) -join ',' | Should Be 'app.bing-weather,app.xbox-tcui'
        @($ctx.AppRows | Where-Object { $_.Selected }).Count | Should Be 0
        $ctx.Controls.ResultText.Text | Should Match 'Removed and verified: Microsoft News'
        $ctx.Controls.ResultText.Text | Should Match '2 succeeded, 0 failed'
        $ctx.Controls.ResultText.Text | Should Match 'Microsoft Store'
        (Read-CpAppRecord -Id 'app.bing-news').state | Should Be 'Removed'
    }
    It 'names ticked apps that a search currently hides' {
        $asked = New-Object System.Collections.ArrayList
        $ctx.Confirm = { param([string]$Text) [void]$asked.Add($Text); $false }.GetNewClosure()
        Raise-Click $ctx.Controls.ModeAppsButton
        (Get-AppRow $ctx 'app.paint').Selected = $true
        $ctx.Controls.SearchBox.Text = 'weather'
        Invoke-CpGuiAction 'Apply'
        $asked[0] | Should Match '- Paint'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'asks a second question for Unsafe apps and leaves them alone on a no' {
        $asked = New-Object System.Collections.ArrayList
        $ctx.Confirm = { param([string]$Text) [void]$asked.Add($Text); ($asked.Count -eq 1) }.GetNewClosure()
        Raise-Click $ctx.Controls.ModeAppsButton
        (Get-AppRow $ctx 'app.bing-news').Selected = $true
        (Get-AppRow $ctx 'app.xbox-tcui').Selected = $true
        Invoke-CpGuiAction 'Apply'
        $asked.Count | Should Be 2
        $asked[0] | Should Match '\[Unsafe\]'
        $asked[1] | Should Match 'marked Unsafe'
        (@($t.Apps.Packages | ForEach-Object { $_.Name }) | Sort-Object) -join ',' | Should Be 'Claude,Microsoft.BingWeather,Microsoft.Paint,Microsoft.Xbox.TCUI'
        $ctx.Controls.ResultText.Text | Should Match 'Skipped \(Unsafe'
    }
    It 'removes an Unsafe app after both questions are answered yes' {
        Raise-Click $ctx.Controls.ModeAppsButton
        (Get-AppRow $ctx 'app.xbox-tcui').Selected = $true
        Invoke-CpGuiAction 'Apply'
        @($t.Apps.Packages | Where-Object { $_.Name -eq 'Microsoft.Xbox.TCUI' }).Count | Should Be 0
    }
    It 'cannot tick an app that Windows protects' {
        Add-FakePackage $t.Apps 'Microsoft.WindowsStore' -NonRemovable $true | Out-Null
        Raise-Click $ctx.Controls.ModeAppsButton
        (Get-AppRow $ctx 'app.store').CanCheck | Should Be $false
        (Get-AppRow $ctx 'app.store').Selected = $true
        Invoke-CpGuiAction 'Apply'
        $ctx.Controls.ResultText.Text | Should Match 'Select at least one'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'shows a failure in the result box and as a message' {
        $p = @($t.Apps.Packages | Where-Object { $_.Name -eq 'Microsoft.BingNews' })[0]
        $t.Apps.FailRemoveOn[$p.PackageFullName] = $true
        Raise-Click $ctx.Controls.ModeAppsButton
        (Get-AppRow $ctx 'app.bing-news').Selected = $true
        Invoke-CpGuiAction 'Apply'
        $ctx.Controls.ResultText.Text | Should Match 'Access denied'
        $ctx.Controls.ResultText.Text | Should Match '0 succeeded, 1 failed'
        $messages.Count | Should Be 1
    }
    It 'Clear selection works in the apps view and quick select stays out of it' {
        Raise-Click $ctx.Controls.ModeAppsButton
        (Get-AppRow $ctx 'app.bing-news').Selected = $true
        Raise-Click $ctx.Controls.ClearButton
        @($ctx.AppRows | Where-Object { $_.Selected }).Count | Should Be 0
        Invoke-CpGuiAction 'SelectPending'
        @($ctx.AppRows | Where-Object { $_.Selected }).Count | Should Be 0
    }
    It 'keeps the apps view on refresh and language switch, and translates it' {
        Raise-Click $ctx.Controls.ModeAppsButton
        (Get-AppRow $ctx 'app.paint').Selected = $true
        Invoke-CpGuiAction 'Refresh'
        $ctx.Mode | Should Be 'Apps'
        (Get-AppRow $ctx 'app.paint').Selected | Should Be $true
        Invoke-CpGuiAction 'Language'
        $ctx.Mode | Should Be 'Apps'
        $ctx.Controls.ApplyButton.Content | Should Be ('Se' + [char]0x00E7 + 'ilenleri kald' + [char]0x0131 + 'r')
        $ctx.Controls.FooterText.Text | Should Match 'uygulama g'
        Invoke-CpGuiAction 'Language'
        $ctx.Controls.ApplyButton.Content | Should Be 'Remove selected'
    }
    It 'says so in the window when the app list cannot be read' {
        $t.Apps.FailList = $true
        Raise-Click $ctx.Controls.ModeAppsButton
        $ctx.Controls.ResultText.Text | Should Match 'could not be read'
        @($ctx.AppRows | Where-Object { $_.CanCheck }).Count | Should Be 0
    }
    It 'shows removals in the history panel' {
        Raise-Click $ctx.Controls.ModeAppsButton
        (Get-AppRow $ctx 'app.bing-news').Selected = $true
        Invoke-CpGuiAction 'Apply'
        Invoke-CpGuiAction 'History'
        $ctx.Controls.HistoryText.Text | Should Match 'app\.bing-news'
        $ctx.Controls.HistoryText.Text | Should Match 'Remove: Removed'
    }
    It 'never touches the registry' {
        Raise-Click $ctx.Controls.ModeAppsButton
        (Get-AppRow $ctx 'app.bing-news').Selected = $true
        Invoke-CpGuiAction 'Apply'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
}
