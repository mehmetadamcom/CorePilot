# WPF window. Thin layer over GuiModel.ps1: it builds the window, fills it, and calls the same engine as the CLI.
# Nothing is written to the registry until the user presses Apply/Undo and confirms.

$script:CpGuiControlNames = @(
    'TitleText', 'HintText', 'HistoryButton', 'RefreshButton', 'LangButton',
    'SelectPendingButton', 'ClearButton', 'SearchLabel', 'SearchBox',
    'MainBody', 'Col1', 'Col2', 'Col3',
    'HistoryPanel', 'BackButton', 'HistoryTitle', 'HistoryText',
    'FooterText', 'UndoButton', 'ApplyButton', 'ResultText'
)
$script:CpGuiColumnCount = 3
$script:CpGuiCtx = $null

function Set-CpGuiTheme {
    param($Ctx)
    if (Get-CpSystemUsesDarkTheme) {
        $palette = @{ Bg = '#202020'; Panel = '#2B2B2B'; Fg = '#F2F2F2'; Muted = '#A6A6A6'; Accent = '#4CC2FF'; AccentFg = '#000000'; Line = '#454545'; Hover = '#3A3A3A'; Select = '#383838'; Warn = '#FFB454'; Bad = '#FF6B6B'; Good = '#6CCB5F' }
    }
    else {
        $palette = @{ Bg = '#F3F3F3'; Panel = '#FFFFFF'; Fg = '#1B1B1B'; Muted = '#5F5F5F'; Accent = '#005FB8'; AccentFg = '#FFFFFF'; Line = '#D0D0D0'; Hover = '#E9E9E9'; Select = '#DCEBFA'; Warn = '#9A5B00'; Bad = '#B42318'; Good = '#176F2C' }
    }
    foreach ($key in $palette.Keys) {
        $color = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($palette[$key])
        # ::new returns the plain .NET object; New-Object would hand WPF a PowerShell wrapper it rejects as a brush.
        $Ctx.Window.Resources["$($key)Brush"] = [System.Windows.Media.SolidColorBrush]::new($color)
    }
}

function Set-CpGuiStatusLine {
    param($Ctx, [string]$Text)
    $Ctx.Controls.ResultText.Text = $Text
}

function Update-CpGuiFooter {
    param($Ctx)
    $selected = @($Ctx.Rows | Where-Object { $_.Selected }).Count
    $Ctx.Controls.FooterText.Text = Get-CpText 'Gui.Footer' @($Ctx.ShownCount, $selected)
}

# Rebuilds the cards from the current rows and the search text.
function Update-CpGuiList {
    param($Ctx)
    $c = $Ctx.Controls
    $filtered = @(Select-CpGuiRows -Rows $Ctx.Rows -Search $c.SearchBox.Text)
    $Ctx.ShownCount = $filtered.Count
    $cards = @(Get-CpGuiCards -Rows $filtered)
    $columns = @(Split-CpGuiColumns -Cards $cards -Count $script:CpGuiColumnCount)
    $c.Col1.ItemsSource = $columns[0]
    $c.Col2.ItemsSource = $columns[1]
    $c.Col3.ItemsSource = $columns[2]
    Update-CpGuiFooter -Ctx $Ctx
}

# Re-reads the registry state of every feature and rebuilds the rows, keeping the user's checkmarks.
function Update-CpGuiData {
    param($Ctx)
    foreach ($row in @($Ctx.Rows)) { $Ctx.Selected[$row.Id] = [bool]$row.Selected }
    $Ctx.Rows = @(Get-CpGuiRows -Selected $Ctx.Selected)
    Update-CpGuiList -Ctx $Ctx
}

function Update-CpGuiTexts {
    param($Ctx)
    $c = $Ctx.Controls
    $Ctx.Window.Title = Get-CpText 'Gui.Title'
    $c.HintText.Text = Get-CpText 'Gui.Hint'
    $c.SearchLabel.Text = Get-CpText 'Gui.Search'
    $c.HistoryButton.Content = Get-CpText 'Gui.History'
    $c.RefreshButton.Content = Get-CpText 'Gui.Refresh'
    $c.LangButton.Content = Get-CpText 'Gui.LanguageButton'
    $c.BackButton.Content = Get-CpText 'Gui.Back'
    $c.HistoryTitle.Text = Get-CpText 'Gui.History'
    $c.SelectPendingButton.Content = Get-CpText 'Gui.SelectPending'
    $c.ClearButton.Content = Get-CpText 'Gui.ClearSelection'
    $c.UndoButton.Content = Get-CpText 'Gui.UndoSelected'
    $c.ApplyButton.Content = Get-CpText 'Gui.ApplySelected'
}

function Show-CpGuiMessage {
    param($Ctx, [string]$Text)
    $notify = $Ctx.Notify
    & $notify $Text
}

# The question shown before a change: the summary plus the names of the features, so nothing hidden by a filter slips through.
function Get-CpGuiFeatureListText {
    param([string[]]$Ids, [int]$Max = 12)
    $names = @($Ids | ForEach-Object { '- ' + (Get-CpText "Feature.$_.Name") })
    if ($names.Count -le $Max) { return ($names -join "`n") }
    $shown = @($names | Select-Object -First $Max)
    $shown += (Get-CpText 'Gui.AndMore' @(($names.Count - $Max)))
    return ($shown -join "`n")
}

function Invoke-CpGuiApplySelected {
    param($Ctx)
    foreach ($row in $Ctx.Rows) { $Ctx.Selected[$row.Id] = [bool]$row.Selected }
    $ids = @($Ctx.Rows | Where-Object { $_.Selected -and $_.CanSelect } | ForEach-Object { $_.Id })
    if ($ids.Count -eq 0) { Set-CpGuiStatusLine $Ctx (Get-CpText 'Gui.NothingSelected'); return }
    $pending = Get-CpGuiPendingSummary -Ids $ids
    if ($pending.Changes -eq 0) { Set-CpGuiStatusLine $Ctx (Get-CpText 'Gui.NothingPending'); return }
    $confirm = $Ctx.Confirm
    $question = (Get-CpText 'Gui.ConfirmApply' @($pending.Changes, $pending.Features)) + "`n`n" + (Get-CpGuiFeatureListText -Ids $pending.Ids)
    if (-not (& $confirm $question)) {
        Set-CpGuiStatusLine $Ctx (Get-CpText 'Cli.Cancelled')
        return
    }
    Complete-CpGuiOperation -Ctx $Ctx -Result (Invoke-CpGuiOperation -Ids $pending.Ids -Action Apply)
}

function Invoke-CpGuiUndoSelected {
    param($Ctx)
    foreach ($row in $Ctx.Rows) { $Ctx.Selected[$row.Id] = [bool]$row.Selected }
    $selected = @($Ctx.Rows | Where-Object { $_.Selected -and $_.CanSelect })
    if ($selected.Count -eq 0) { Set-CpGuiStatusLine $Ctx (Get-CpText 'Gui.NothingSelected'); return }
    $ids = @($selected | Where-Object { $_.HasSaved } | ForEach-Object { $_.Id })
    if ($ids.Count -eq 0) { Set-CpGuiStatusLine $Ctx (Get-CpText 'Gui.NothingToUndo'); return }
    $confirm = $Ctx.Confirm
    $question = (Get-CpText 'Gui.ConfirmUndo' @($ids.Count)) + "`n`n" + (Get-CpGuiFeatureListText -Ids $ids)
    if (-not (& $confirm $question)) {
        Set-CpGuiStatusLine $Ctx (Get-CpText 'Cli.Cancelled')
        return
    }
    Complete-CpGuiOperation -Ctx $Ctx -Result (Invoke-CpGuiOperation -Ids $ids -Action Undo)
}

function Complete-CpGuiOperation {
    param($Ctx, $Result)
    foreach ($id in $Result.OkIds) { $Ctx.Selected[$id] = $false }
    foreach ($row in $Ctx.Rows) { if ($Result.OkIds -contains $row.Id) { $row.Selected = $false } }
    $text = @($Result.Lines) + @($Result.Hints) + @(Get-CpText 'Gui.ResultSummary' @($Result.Succeeded, $Result.Failed))
    Update-CpGuiData -Ctx $Ctx
    Set-CpGuiStatusLine $Ctx ($text -join "`n")
    if ($Result.Failed -gt 0) { Show-CpGuiMessage -Ctx $Ctx -Text ($Result.Lines -join "`n") }
}

# 'Pending' ticks only settings that are low risk, can be applied, and are not applied yet. Riskier ones stay a conscious choice.
function Set-CpGuiSelectionMode {
    param($Ctx, [ValidateSet('Pending', 'None')][string]$Mode)
    foreach ($row in $Ctx.Rows) {
        if ($Mode -eq 'None') { $row.Selected = $false }
        elseif ($row.CanCheck -and $row.Risk -ceq 'Low' -and $row.Status -in @('NotApplied', 'Partial')) { $row.Selected = $true }
    }
    # The cards show the same objects, so rebuild them to refresh the check boxes.
    Update-CpGuiList -Ctx $Ctx
}

function Switch-CpGuiLanguage {
    param($Ctx)
    $next = 'tr-TR'
    if ($script:CpLanguage -eq 'tr-TR') { $next = 'en-US' }
    Import-CpLocale -Root $Ctx.Root -Language $next
    Update-CpGuiTexts -Ctx $Ctx
    Update-CpGuiData -Ctx $Ctx
    Set-CpGuiStatusLine $Ctx (Get-CpText 'Gui.Ready')
}

function Show-CpGuiHistory {
    param($Ctx, [bool]$Visible)
    $c = $Ctx.Controls
    if ($Visible) {
        $c.HistoryText.Text = (Get-CpHistoryLines) -join "`n"
        $c.MainBody.Visibility = [System.Windows.Visibility]::Collapsed
        $c.HistoryPanel.Visibility = [System.Windows.Visibility]::Visible
    }
    else {
        $c.HistoryPanel.Visibility = [System.Windows.Visibility]::Collapsed
        $c.MainBody.Visibility = [System.Windows.Visibility]::Visible
    }
}

# Every window event goes through here, so a failure shows up in the window instead of crashing it.
function Invoke-CpGuiAction {
    param([Parameter(Mandatory)][string]$Name)
    $ctx = $script:CpGuiCtx
    try {
        switch ($Name) {
            'Search' { Update-CpGuiList -Ctx $ctx }
            'SelectionToggled' { Update-CpGuiFooter -Ctx $ctx }
            'Refresh' { Update-CpGuiData -Ctx $ctx; Set-CpGuiStatusLine $ctx (Get-CpText 'Gui.Ready') }
            'Language' { Switch-CpGuiLanguage -Ctx $ctx }
            'History' { Show-CpGuiHistory -Ctx $ctx -Visible $true }
            'Back' { Show-CpGuiHistory -Ctx $ctx -Visible $false }
            'SelectPending' { Set-CpGuiSelectionMode -Ctx $ctx -Mode Pending }
            'ClearSelection' { Set-CpGuiSelectionMode -Ctx $ctx -Mode None }
            'Apply' { Invoke-CpGuiApplySelected -Ctx $ctx }
            'Undo' { Invoke-CpGuiUndoSelected -Ctx $ctx }
            default { throw "Unknown window action '$Name'." }
        }
    }
    catch { Set-CpGuiStatusLine $ctx ((Get-CpText 'Failure.unexpected') + ' ' + $_.Exception.Message) }
}

function New-CpGuiWindow {
    param([Parameter(Mandatory)][string]$Root, [string]$Language)
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Import-CpLocale -Root $Root -Language $Language
    Import-CpCatalog -Root $Root

    $xaml = [System.IO.File]::ReadAllText((Join-Path $Root 'Gui\MainWindow.xaml'), [System.Text.Encoding]::UTF8)
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)

    $controls = @{}
    foreach ($name in $script:CpGuiControlNames) {
        $element = $window.FindName($name)
        if ($null -eq $element) { throw "The window definition has no element named '$name'." }
        $controls[$name] = $element
    }
    $ctx = @{
        Window     = $window
        Root       = $Root
        Controls   = $controls
        Selected   = @{}
        Rows       = @()
        ShownCount = 0
        Confirm    = {
            param([string]$Text)
            $answer = [System.Windows.MessageBox]::Show($Text, 'CorePilot', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question, [System.Windows.MessageBoxResult]::No)
            return ($answer -eq [System.Windows.MessageBoxResult]::Yes)
        }
        Notify     = {
            param([string]$Text)
            [void][System.Windows.MessageBox]::Show($Text, 'CorePilot', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        }
    }

    Set-CpGuiTheme -Ctx $ctx
    Update-CpGuiTexts -Ctx $ctx
    Update-CpGuiData -Ctx $ctx
    Set-CpGuiStatusLine $ctx (Get-CpText 'Gui.Ready')
    return $ctx
}

function Connect-CpGuiEvents {
    param($Ctx)
    $script:CpGuiCtx = $Ctx
    $c = $Ctx.Controls
    $c.SearchBox.Add_TextChanged({ Invoke-CpGuiAction 'Search' })
    $toggled = [System.Windows.RoutedEventHandler] { Invoke-CpGuiAction 'SelectionToggled' }
    $c.MainBody.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent, $toggled)
    $c.MainBody.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent, $toggled)
    $c.RefreshButton.Add_Click({ Invoke-CpGuiAction 'Refresh' })
    $c.LangButton.Add_Click({ Invoke-CpGuiAction 'Language' })
    $c.HistoryButton.Add_Click({ Invoke-CpGuiAction 'History' })
    $c.BackButton.Add_Click({ Invoke-CpGuiAction 'Back' })
    $c.SelectPendingButton.Add_Click({ Invoke-CpGuiAction 'SelectPending' })
    $c.ClearButton.Add_Click({ Invoke-CpGuiAction 'ClearSelection' })
    $c.ApplyButton.Add_Click({ Invoke-CpGuiAction 'Apply' })
    $c.UndoButton.Add_Click({ Invoke-CpGuiAction 'Undo' })
}

# The window is started without a console, so a startup failure must be visible some other way: a message box and a log file.
$script:CpGuiDefaultFatalNotify = {
    param([string]$Text)
    Add-Type -AssemblyName PresentationFramework
    [void][System.Windows.MessageBox]::Show($Text, 'CorePilot', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
}
$script:CpGuiFatalNotify = $script:CpGuiDefaultFatalNotify

# Tests replace the message box; $null restores it.
function Set-CpGuiFatalNotifier {
    param([scriptblock]$Handler)
    if ($null -eq $Handler) { $script:CpGuiFatalNotify = $script:CpGuiDefaultFatalNotify } else { $script:CpGuiFatalNotify = $Handler }
}

function Show-CpGuiFatal {
    param([string]$Message)
    try {
        Write-CpFileAtomic -Path (Join-Path (Get-CpDataRoot) 'gui-error.log') -Text ("{0}`n{1}`n" -f [DateTime]::Now.ToString('o'), $Message)
    }
    catch { }
    try {
        $text = Get-CpText 'Gui.StartFailed' @($Message)
        if ($text -eq 'Gui.StartFailed') { $text = "CorePilot could not open its window:`n$Message" }
        $notify = $script:CpGuiFatalNotify
        & $notify $text
    }
    catch { Write-Host $Message }
}

function Show-CpGui {
    param([Parameter(Mandatory)][string]$Root, [string]$Language)
    try {
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
            Import-CpLocale -Root $Root -Language $Language
            Show-CpGuiFatal -Message (Get-CpText 'Gui.NeedsSta')
            return 1
        }
        $ctx = New-CpGuiWindow -Root $Root -Language $Language
        Connect-CpGuiEvents -Ctx $ctx
        [void]$ctx.Window.ShowDialog()
        return 0
    }
    catch {
        Show-CpGuiFatal -Message $_.Exception.Message
        return 1
    }
}
