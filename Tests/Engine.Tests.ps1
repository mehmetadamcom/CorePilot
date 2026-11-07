$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Src\Load.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Set-CpRegistryProvider -Provider (New-CpFakeRegistry)

$fileExt = 'explorer.show-file-extensions'   # HideFileExt = 0 (DWord)
$dark = 'appearance.dark-theme'              # two DWord values
$mouse = 'input.disable-mouse-acceleration'  # three String values

Describe 'Detection' {
    BeforeEach { $t = Initialize-CpTestEnvironment -Root $root }
    AfterEach { Remove-CpTestEnvironment $t }

    It 'reports every feature as not applied on an empty registry' {
        $applied = @(Get-CpFeatures | Where-Object { (Get-CpFeatureStatus -Feature $_).Status -ne 'NotApplied' })
        $applied.Count | Should Be 0
    }
    It 'reports Applied when the value matches' {
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 0
        (Get-CpFeatureStatus -Feature (Get-CpFeature $fileExt)).Status | Should Be 'Applied'
    }
    It 'reports NotApplied for the other value, and for the right number with the wrong type' {
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 1
        (Get-CpFeatureStatus -Feature (Get-CpFeature $fileExt)).Status | Should Be 'NotApplied'
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'String' '0'
        (Get-CpFeatureStatus -Feature (Get-CpFeature $fileExt)).Status | Should Be 'NotApplied'
    }
    It 'reports Partial when only some values match' {
        Set-FakeValue $t.Registry $Pers 'AppsUseLightTheme' 'DWord' 0
        (Get-CpFeatureStatus -Feature (Get-CpFeature $dark)).Status | Should Be 'Partial'
    }
    It 'reports Unsupported, without reading, when Windows is too old' {
        Remove-CpTestEnvironment $t
        $t = Initialize-CpTestEnvironment -Root $root -Build 19045
        $status = Get-CpFeatureStatus -Feature (Get-CpFeature $fileExt)
        $status.Status | Should Be 'Unsupported'
        $status.Reason | Should Be 'windows-build-too-old'
        $t.Registry.Log.Count | Should Be 0
    }
    It 'never writes while detecting or previewing' {
        foreach ($f in Get-CpFeatures) { [void](Get-CpFeatureStatus -Feature $f) }
        $lines = Start-CpOutputCapture
        foreach ($f in Get-CpFeatures) { [void](Show-CpPreview -Feature $f) }
        (Get-FakeWriteCount $t.Registry) | Should Be 0
        $lines.Count | Should BeGreaterThan 20
    }
}

Describe 'Apply and undo' {
    BeforeEach { $t = Initialize-CpTestEnvironment -Root $root }
    AfterEach { Remove-CpTestEnvironment $t }

    It 'refuses without approval and writes nothing' {
        $r = Invoke-CpApply -FeatureId $fileExt
        $r.Success | Should Be $false
        $r.Reason | Should Be 'approval-required'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
        Test-Path -LiteralPath (Join-Path $t.DataRoot 'records') | Should Be $false
    }
    It 'refuses an id that is not in the catalog' {
        (Invoke-CpApply -FeatureId 'evil.thing' -Approved).Reason | Should Be 'unknown-operation'
        (Invoke-CpRevert -FeatureId 'evil.thing' -Approved).Reason | Should Be 'unknown-operation'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
    It 'applies, verifies, records the original and logs history' {
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 1
        $r = Invoke-CpApply -FeatureId $fileExt -Approved
        $r.Success | Should Be $true
        $r.Status | Should Be 'Verified'
        (Get-FakeEntry $t.Registry $Adv 'HideFileExt').Value | Should Be 0
        $record = Read-CpRecord -Id $fileExt
        $record.state | Should Be 'Verified'
        @($record.originals).Count | Should Be 1
        $record.originals[0].value | Should Be 1
        @(Get-CpHistory).Count | Should Be 1
        (@(Get-CpHistory))[0].status | Should Be 'Verified'
    }
    It 'undo restores an existing value and removes a value that did not exist' {
        Set-FakeValue $t.Registry $Pers 'AppsUseLightTheme' 'DWord' 1
        $before = Get-FakeSnapshot $t.Registry
        (Invoke-CpApply -FeatureId $dark -Approved).Status | Should Be 'Verified'
        (Get-FakeSnapshot $t.Registry) | Should Not Be $before
        $u = Invoke-CpRevert -FeatureId $dark -Approved
        $u.Status | Should Be 'Reverted'
        (Get-FakeSnapshot $t.Registry) | Should Be $before
        $null -eq (Get-FakeEntry $t.Registry $Pers 'SystemUsesLightTheme') | Should Be $true
    }
    It 'undo needs approval, and a second undo has nothing left to restore' {
        [void](Invoke-CpApply -FeatureId $fileExt -Approved)
        (Invoke-CpRevert -FeatureId $fileExt).Reason | Should Be 'approval-required'
        (Invoke-CpRevert -FeatureId $fileExt -Approved).Success | Should Be $true
        (Invoke-CpRevert -FeatureId $fileExt -Approved).Reason | Should Be 'no-original-state'
    }
    It 'undo with no record refuses and writes nothing' {
        (Invoke-CpRevert -FeatureId $fileExt -Approved).Reason | Should Be 'no-original-state'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
    It 'applying twice changes nothing the second time and keeps the true original' {
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 1
        [void](Invoke-CpApply -FeatureId $fileExt -Approved)
        $writes = Get-FakeWriteCount $t.Registry
        $second = Invoke-CpApply -FeatureId $fileExt -Approved
        $second.Status | Should Be 'NoChange'
        $second.Success | Should Be $true
        (Get-FakeWriteCount $t.Registry) | Should Be $writes
        (Read-CpRecord -Id $fileExt).originals[0].value | Should Be 1
    }
    It 'does not create a record when the value was already applied by someone else' {
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 0
        (Invoke-CpApply -FeatureId $fileExt -Approved).Status | Should Be 'NoChange'
        $null -eq (Read-CpRecord -Id $fileExt) | Should Be $true
    }
    It 'keeps the first recorded originals when an earlier run was interrupted' {
        # Crash simulation: record says Applying with the true originals, registry is half changed.
        $originals = @(
            [ordered]@{ path = $Pers; name = 'AppsUseLightTheme'; exists = $true; kind = 'DWord'; value = 1 },
            [ordered]@{ path = $Pers; name = 'SystemUsesLightTheme'; exists = $false; kind = $null; value = $null })
        Save-CpRecord -Record (New-CpRecord -FeatureId $dark -State 'Applying' -Originals $originals -Build 26200)
        Set-FakeValue $t.Registry $Pers 'AppsUseLightTheme' 'DWord' 0
        (Invoke-CpApply -FeatureId $dark -Approved).Status | Should Be 'Verified'
        (Invoke-CpRevert -FeatureId $dark -Approved).Status | Should Be 'Reverted'
        (Get-FakeEntry $t.Registry $Pers 'AppsUseLightTheme').Value | Should Be 1
        $null -eq (Get-FakeEntry $t.Registry $Pers 'SystemUsesLightTheme') | Should Be $true
    }
    It 'round-trips every feature back to the exact starting registry' {
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 1
        Set-FakeValue $t.Registry $Adv 'Hidden' 'DWord' 2
        Set-FakeValue $t.Registry $Mouse 'MouseSpeed' 'String' '1'
        $before = Get-FakeSnapshot $t.Registry
        $bad = New-Object System.Collections.ArrayList
        foreach ($f in Get-CpFeatures) {
            $a = Invoke-CpApply -FeatureId $f.id -Approved
            if (-not $a.Success -or (Get-CpFeatureStatus -Feature $f).Status -ne 'Applied') { [void]$bad.Add("apply:$($f.id):$($a.Reason)") }
        }
        foreach ($f in Get-CpFeatures) {
            $u = Invoke-CpRevert -FeatureId $f.id -Approved
            if (-not $u.Success) { [void]$bad.Add("undo:$($f.id):$($u.Reason)") }
        }
        ($bad -join ',') | Should Be ''
        (Get-FakeSnapshot $t.Registry) | Should Be $before
    }
}

Describe 'Failure handling' {
    BeforeEach { $t = Initialize-CpTestEnvironment -Root $root }
    AfterEach { Remove-CpTestEnvironment $t }

    It 'rolls back everything when a later write is denied' {
        Set-FakeValue $t.Registry $Pers 'AppsUseLightTheme' 'DWord' 1
        $before = Get-FakeSnapshot $t.Registry
        $t.Registry.FailSetOn["$Pers|SystemUsesLightTheme".ToLowerInvariant()] = $true
        $r = Invoke-CpApply -FeatureId $dark -Approved
        $r.Success | Should Be $false
        $r.Status | Should Be 'Failed'
        $r.Reason | Should Be 'access-denied'
        (Get-FakeSnapshot $t.Registry) | Should Be $before
        (Read-CpRecord -Id $dark).state | Should Be 'Failed'
        (@(Get-CpHistory))[0].status | Should Be 'Failed'
    }
    It 'flags RecoveryNeeded when a write is silently wrong and the rollback is wrong too' {
        # The fake stores a wrong number for every write to this value, so neither the change nor its rollback can be confirmed.
        $t.Registry.SilentCorrupt["$Adv|HideFileExt".ToLowerInvariant()] = $true
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 1
        $r = Invoke-CpApply -FeatureId $fileExt -Approved
        $r.Success | Should Be $false
        $r.Reason | Should Be 'verify-failed'
        $r.Status | Should Be 'RecoveryNeeded'
    }
    It 'rolls back cleanly when verification fails but restoring works' {
        # First write is wrong (corrupt), then corruption stops, so the rollback write is exact.
        $key = "$Adv|HideFileExt".ToLowerInvariant()
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'DWord' 1
        $realSet = $t.Registry.Set
        $store = $t.Registry.Store   # closures only capture local variables, so copy what the block needs
        $calls = [pscustomobject]@{ n = 0 }
        $t.Registry.Set = {
            param([string]$Path, [string]$Name, [string]$Kind, $Value)
            $calls.n++
            if ($calls.n -eq 1) { $store[$key] = @{ Kind = $Kind; Value = 999 } } else { & $realSet $Path $Name $Kind $Value }
        }.GetNewClosure()
        $r = Invoke-CpApply -FeatureId $fileExt -Approved
        $r.Status | Should Be 'Failed'
        $r.Reason | Should Be 'verify-failed'
        (Get-FakeEntry $t.Registry $Adv 'HideFileExt').Value | Should Be 1
        (Read-CpRecord -Id $fileExt).state | Should Be 'Failed'
    }
    It 'flags RecoveryNeeded when the rollback itself fails, and undo can finish the job later' {
        Set-FakeValue $t.Registry $Pers 'AppsUseLightTheme' 'DWord' 1
        $t.Registry.FailSetAfter = 2          # first write works, everything after is denied (including the rollback)
        $r = Invoke-CpApply -FeatureId $dark -Approved
        $r.Status | Should Be 'RecoveryNeeded'
        (Read-CpRecord -Id $dark).state | Should Be 'RecoveryNeeded'
        @(Get-CpRecordsNeedingRecovery).Count | Should Be 1
        (Get-FakeEntry $t.Registry $Pers 'AppsUseLightTheme').Value | Should Be 0   # half-applied, as expected
        $t.Registry.FailSetAfter = 0          # the problem went away
        (Invoke-CpRevert -FeatureId $dark -Approved).Status | Should Be 'Reverted'
        (Get-FakeEntry $t.Registry $Pers 'AppsUseLightTheme').Value | Should Be 1
        $null -eq (Get-FakeEntry $t.Registry $Pers 'SystemUsesLightTheme') | Should Be $true
        @(Get-CpRecordsNeedingRecovery).Count | Should Be 0
    }
    It 'leaves a value of a type it cannot restore untouched' {
        Set-FakeValue $t.Registry $Adv 'HideFileExt' 'Binary' ([byte[]](1, 2))
        $r = Invoke-CpApply -FeatureId $fileExt -Approved
        $r.Reason | Should Be 'unsupported-value'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
        $null -eq (Read-CpRecord -Id $fileExt) | Should Be $true
    }
    It 'refuses when Windows is too old or its version is unknown, and writes nothing' {
        Remove-CpTestEnvironment $t
        $t = Initialize-CpTestEnvironment -Root $root -Build 19045
        (Invoke-CpApply -FeatureId $fileExt -Approved).Reason | Should Be 'windows-build-too-old'
        Remove-CpTestEnvironment $t
        $t = Initialize-CpTestEnvironment -Root $root -Build 0
        (Invoke-CpApply -FeatureId $fileExt -Approved).Reason | Should Be 'windows-build-unknown'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
    It 'refuses to change anything when the change record cannot be written' {
        $blocker = Join-Path ([System.IO.Path]::GetTempPath()) ('CpBlock-' + [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $blocker -Value 'a file, not a folder'
        try {
            Set-CpDataRoot -Path (Join-Path $blocker 'data')
            $r = Invoke-CpApply -FeatureId $fileExt -Approved
            $r.Reason | Should Be 'store-unavailable'
            (Get-FakeWriteCount $t.Registry) | Should Be 0
        }
        finally { Remove-Item -LiteralPath $blocker -Force }
    }
    It 'does not trust a record that points at other features or other registry values' {
        # Tampered record: claims to be for fileExt but holds the originals of a different feature's target.
        $evil = @([ordered]@{ path = $Pers; name = 'AppsUseLightTheme'; exists = $true; kind = 'DWord'; value = 7 })
        Save-CpRecord -Record (New-CpRecord -FeatureId $fileExt -State 'Verified' -Originals $evil -Build 26200)
        $r = Invoke-CpRevert -FeatureId $fileExt -Approved
        $r.Reason | Should Be 'captured-state-mismatch'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
        # Same for a path outside the catalog.
        $evil2 = @([ordered]@{ path = 'Software\Evil'; name = 'X'; exists = $true; kind = 'DWord'; value = 1 })
        Save-CpRecord -Record (New-CpRecord -FeatureId $fileExt -State 'Verified' -Originals $evil2 -Build 26200)
        (Invoke-CpRevert -FeatureId $fileExt -Approved).Reason | Should Be 'captured-state-mismatch'
        # Wrong value type for the recorded kind.
        $evil3 = @([ordered]@{ path = $Adv; name = 'HideFileExt'; exists = $true; kind = 'DWord'; value = 'not a number' })
        Save-CpRecord -Record (New-CpRecord -FeatureId $fileExt -State 'Verified' -Originals $evil3 -Build 26200)
        (Invoke-CpRevert -FeatureId $fileExt -Approved).Reason | Should Be 'captured-state-mismatch'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
    It 'refuses to use a corrupt record for undo or apply' {
        $dir = Join-Path $t.DataRoot 'records'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir "$fileExt.json") -Value '{ not json'
        (Invoke-CpRevert -FeatureId $fileExt -Approved).Reason | Should Be 'captured-state-mismatch'
        (Invoke-CpApply -FeatureId $fileExt -Approved).Reason | Should Be 'store-unavailable'
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
    It 'refuses while another process holds the engine lock' {
        New-Item -ItemType Directory -Path $t.DataRoot -Force | Out-Null
        $marker = Join-Path $t.DataRoot 'locked.flag'
        $job = Start-Job -ArgumentList $marker -ScriptBlock {
            param($marker)
            $m = New-Object System.Threading.Mutex($false, 'Local\CorePilot.Engine')
            [void]$m.WaitOne()
            Set-Content -LiteralPath $marker -Value 'locked'
            Start-Sleep -Seconds 25
        }
        try {
            $deadline = (Get-Date).AddSeconds(20)
            while (-not (Test-Path -LiteralPath $marker) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
            Test-Path -LiteralPath $marker | Should Be $true
            (Invoke-CpApply -FeatureId $fileExt -Approved).Reason | Should Be 'busy'
            (Invoke-CpRevert -FeatureId $fileExt -Approved).Reason | Should Be 'busy'
            (Get-FakeWriteCount $t.Registry) | Should Be 0
        }
        finally { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Safety guards' {
    BeforeEach { $t = Initialize-CpTestEnvironment -Root $root }
    AfterEach { Remove-CpTestEnvironment $t }

    It 'the registry wrappers refuse targets that are not in the catalog' {
        { Write-CpRegistry -Path 'Software\Evil' -Name 'X' -Kind 'DWord' -Value 1 } | Should Throw
        { Remove-CpRegistry -Path 'Software\Evil' -Name 'X' } | Should Throw
        { Write-CpRegistry -Path $Adv -Name 'NotInCatalog' -Kind 'DWord' -Value 1 } | Should Throw
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
    It 'rejects unsafe feature ids before touching the disk' {
        { Get-CpRecordPath -Id '..\..\x' } | Should Throw
        { Get-CpRecordPath -Id 'A.B' } | Should Throw
    }
    It 'the tests run on the fake registry, not the real one' {
        Test-CpRegistryProviderIsFake | Should Be $true
    }
}
