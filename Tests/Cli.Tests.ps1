$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Src\Load.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Set-CpRegistryProvider -Provider (New-CpFakeRegistry)

$fileExt = 'explorer.show-file-extensions'
$mouse = 'input.disable-mouse-acceleration'

Describe 'Command line' {
    BeforeEach {
        $t = Initialize-CpTestEnvironment -Root $root
        $lines = Start-CpOutputCapture
        Set-CpConfirm -Handler { param([string]$Prompt) $false }
    }
    AfterEach { Remove-CpTestEnvironment $t }

    It 'lists every feature without writing anything' {
        (Invoke-CpCli -Root $root -Language 'en-US') | Should Be 0
        $text = $lines -join "`n"
        $text | Should Match ('CorePilot features \(' + @(Get-CpFeatures).Count + '\)')
        $text | Should Match 'explorer\.show-file-extensions'
        $text | Should Match 'Not applied'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
    It 'prints the list in Turkish when asked' {
        (Invoke-CpCli -Root $root -Language 'tr-TR') | Should Be 0
        # Test files must stay ASCII, so the Turkish letters are written as code points.
        ($lines -join "`n") | Should Match ([char]0x00F6 + 'zellikleri')
        ($lines -join "`n") | Should Match ('Uygulanmad' + [char]0x0131)
    }
    It 'previews a feature (registry path, old and new value) and changes nothing' {
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 1
        (Invoke-CpCli -Root $root -Language 'en-US' -Feature $fileExt) | Should Be 0
        $text = $lines -join "`n"
        $text | Should Match 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\HideFileExt: 1 -> 0'
        $text | Should Match 'only a preview'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
    It 'does not write on -Apply with -PreviewOnly (the -WhatIf path)' {
        (Invoke-CpCli -Root $root -Language 'en-US' -Feature $fileExt -Apply -PreviewOnly) | Should Be 0
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
    It 'does not write when the user declines the confirmation' {
        (Invoke-CpCli -Root $root -Language 'en-US' -Feature $fileExt -Apply) | Should Be 0
        ($lines -join "`n") | Should Match 'Nothing was changed'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
    It 'asks once with the number of pending changes, then applies after a yes' {
        $asked = New-Object System.Collections.ArrayList
        Set-CpConfirm -Handler { param([string]$Prompt) [void]$asked.Add($Prompt); $true }.GetNewClosure()
        (Invoke-CpCli -Root $root -Language 'en-US' -Feature 'appearance.dark-theme,appearance.disable-transparency' -Apply) | Should Be 0
        $asked.Count | Should Be 1
        $asked[0] | Should Match 'Apply 3 change'
        (Get-FakeEntry $t.Registry $Pers 'AppsUseLightTheme').Value | Should Be 0
        (Get-FakeEntry $t.Registry $Pers 'EnableTransparency').Value | Should Be 0
        ($lines -join "`n") | Should Match 'Applied and verified'
    }
    It 'applies with -Yes without asking, then undoes it' {
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 1
        (Invoke-CpCli -Root $root -Language 'en-US' -Feature $fileExt -Apply -Yes) | Should Be 0
        (Get-FakeEntry $t.Registry $Adv 'HideFileExt').Value | Should Be 0
        (Invoke-CpCli -Root $root -Language 'en-US' -Feature $fileExt -Undo -Yes) | Should Be 0
        (Get-FakeEntry $t.Registry $Adv 'HideFileExt').Value | Should Be 1
        ($lines -join "`n") | Should Match 'Reverted to the saved original'
    }
    It 'undo asks for confirmation and does nothing when declined' {
        [void](Invoke-CpApply -FeatureId $fileExt -Approved)
        (Invoke-CpCli -Root $root -Language 'en-US' -Feature $fileExt -Undo) | Should Be 0
        (Get-FakeEntry $t.Registry $Adv 'HideFileExt').Value | Should Be 0
    }
    It 'tells the user when a restart or sign-out is needed' {
        [void](Invoke-CpCli -Root $root -Language 'en-US' -Feature $mouse -Apply -Yes)
        ($lines -join "`n") | Should Match 'sign out'
    }
    It 'returns 2 for an unknown feature and for apply/undo with no feature' {
        (Invoke-CpCli -Root $root -Language 'en-US' -Feature 'nope.nothing' -Apply -Yes) | Should Be 2
        ($lines -join "`n") | Should Match 'Unknown feature: nope.nothing'
        (Invoke-CpCli -Root $root -Language 'en-US' -Apply -Yes) | Should Be 2
        (Invoke-CpCli -Root $root -Language 'en-US' -Undo -Yes) | Should Be 2
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
    It 'returns 1 and explains a failure' {
        $t.Registry.FailSetOn["$Adv|HideFileExt".ToLowerInvariant()] = $true
        (Invoke-CpCli -Root $root -Language 'en-US' -Feature $fileExt -Apply -Yes) | Should Be 1
        ($lines -join "`n") | Should Match 'Access denied'
    }
    It 'selects features with wildcards' {
        [void](Invoke-CpCli -Root $root -Language 'en-US' -Feature 'taskbar.*')
        $count = @($lines | Where-Object { $_ -like 'What would change for*' }).Count
        $count | Should Be @(Get-CpFeatures | Where-Object { $_.id -like 'taskbar.*' }).Count
    }
    It 'accepts comma-separated ids in one argument (powershell -File style)' {
        (Invoke-CpCli -Root $root -Language 'en-US' -Feature "$fileExt, $mouse") | Should Be 0
        @($lines | Where-Object { $_ -like 'What would change for*' }).Count | Should Be 2
    }
    It 'shows the history after changes, and an empty-history message before' {
        [void](Invoke-CpCli -Root $root -Language 'en-US' -History)
        ($lines -join "`n") | Should Match 'has not changed anything'
        [void](Invoke-CpApply -FeatureId $fileExt -Approved)
        [void](Invoke-CpRevert -FeatureId $fileExt -Approved)
        $lines.Clear()
        [void](Invoke-CpCli -Root $root -Language 'en-US' -History)
        $text = $lines -join "`n"
        $text | Should Match 'explorer\.show-file-extensions'
        $text | Should Match 'Reverted'
    }
    It 'warns about an interrupted run' {
        $originals = @([ordered]@{ path = $Adv; name = 'HideFileExt'; exists = $true; kind = 'DWord'; value = 1 })
        Save-CpRecord -Record (New-CpRecord -FeatureId $fileExt -State 'Applying' -Originals $originals -Build 26200)
        [void](Invoke-CpCli -Root $root -Language 'en-US')
        ($lines -join "`n") | Should Match '1 earlier run'
    }
    It 'shows features as unavailable on an older Windows' {
        Remove-CpTestEnvironment $t
        $t = Initialize-CpTestEnvironment -Root $root -Build 19045
        $lines = Start-CpOutputCapture
        [void](Invoke-CpCli -Root $root -Language 'en-US')
        ($lines -join "`n") | Should Match 'Not available on this Windows'
        (Invoke-CpCli -Root $root -Language 'en-US' -Feature $fileExt -Apply -Yes) | Should Be 0
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
}
