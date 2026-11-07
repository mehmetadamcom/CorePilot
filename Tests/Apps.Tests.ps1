$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Src\Load.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Set-CpRegistryProvider -Provider (New-CpFakeRegistry)
Set-CpAppProvider -Provider (New-CpFakeAppProvider)

Describe 'App catalog' {
    BeforeEach { $t = Initialize-CpTestEnvironment -Root $root }
    AfterEach { Remove-CpTestEnvironment $t }

    It 'is valid' {
        $catalog = Read-CpJson (Join-Path $root 'Data\Apps.json')
        @(Test-CpAppCatalog -Catalog $catalog).Count | Should Be 0
        @(Get-CpApps).Count | Should BeGreaterThan 30
    }
    It 'rejects duplicate ids, duplicate packages and unknown safety labels' {
        $bad = [pscustomobject]@{ schema = 1; apps = @(
                [pscustomobject]@{ id = 'app.one'; package = 'Vendor.One'; name = 'One'; safety = 'Safe' },
                [pscustomobject]@{ id = 'app.one'; package = 'Vendor.Two'; name = 'Two'; safety = 'Safe' },
                [pscustomobject]@{ id = 'app.three'; package = 'vendor.one'; name = 'Three'; safety = 'Safe' },
                [pscustomobject]@{ id = 'app.four'; package = 'Vendor.Four'; name = 'Four'; safety = 'Risky' }) }
        $text = (@(Test-CpAppCatalog -Catalog $bad)) -join "`n"
        $text | Should Match 'duplicate app id'
        $text | Should Match 'already used'
        $text | Should Match 'unknown safety'
    }
    It 'rejects wildcards and odd characters in package names' {
        foreach ($name in @('Vendor.*', 'Vendor One', '..\x', '')) {
            $bad = [pscustomobject]@{ schema = 1; apps = @([pscustomobject]@{ id = 'app.x'; package = $name; name = 'X'; safety = 'Safe' }) }
            @(Test-CpAppCatalog -Catalog $bad).Count | Should BeGreaterThan 0
        }
    }
    It 'never lists core Windows packages' {
        $core = @('Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.SecHealthUI',
            'Microsoft.DesktopAppInstaller', 'Microsoft.MicrosoftEdge.Stable', 'Microsoft.Win32WebViewHost', 'Microsoft.AAD.BrokerPlugin',
            'MicrosoftWindows.Client.CBS', 'MicrosoftWindows.Client.Core', 'MicrosoftWindows.Client.FileExp', 'Microsoft.Windows.CloudExperienceHost',
            'Microsoft.Windows.ContentDeliveryManager', 'windows.immersivecontrolpanel', 'Microsoft.AccountsControl', 'Microsoft.LockApp')
        $packages = @(Get-CpApps | ForEach-Object { $_.package.ToLowerInvariant() })
        foreach ($name in $core) { ($packages -contains $name.ToLowerInvariant()) | Should Be $false }
    }
    It 'rejects a catalog that lists a core Windows package' {
        $bad = [pscustomobject]@{ schema = 1; apps = @([pscustomobject]@{ id = 'app.shell'; package = 'Microsoft.Windows.ShellExperienceHost'; name = 'Shell'; safety = 'Safe' }) }
        (@(Test-CpAppCatalog -Catalog $bad)) -join "`n" | Should Match 'must never be removable'
    }
    It 'has a description in both languages for every app' {
        $en = ConvertTo-CpHashtable (Read-CpJson (Join-Path $root 'Locales\en-US.json'))
        $tr = ConvertTo-CpHashtable (Read-CpJson (Join-Path $root 'Locales\tr-TR.json'))
        foreach ($app in (Get-CpApps)) {
            $en.ContainsKey("AppDesc.$($app.id)") | Should Be $true
            $tr.ContainsKey("AppDesc.$($app.id)") | Should Be $true
        }
    }
    It 'works in the Turkish culture (upper-case I)' {
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $catalog = Read-CpJson (Join-Path $root 'Data\Apps.json')
            @(Test-CpAppCatalog -Catalog $catalog).Count | Should Be 0
            Add-FakePackage $t.Apps 'MicrosoftTeams' | Out-Null
            (Get-CpAppStatus -AppId 'app.teams-personal').Status | Should Be 'Installed'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }
}

Describe 'App status' {
    BeforeEach { $t = Initialize-CpTestEnvironment -Root $root }
    AfterEach { Remove-CpTestEnvironment $t }

    It 'reports installed, not installed and protected, without removing anything' {
        Add-FakePackage $t.Apps 'Microsoft.BingNews' | Out-Null
        Add-FakePackage $t.Apps 'Microsoft.WindowsStore' -NonRemovable $true | Out-Null
        (Get-CpAppStatus -AppId 'app.bing-news').Status | Should Be 'Installed'
        (Get-CpAppStatus -AppId 'app.bing-weather').Status | Should Be 'NotInstalled'
        (Get-CpAppStatus -AppId 'app.store').Status | Should Be 'Protected'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'matches the exact package name only (no prefix or substring)' {
        Add-FakePackage $t.Apps 'Microsoft.BingNewsExtra' | Out-Null
        Add-FakePackage $t.Apps 'My.Microsoft.BingNews' | Out-Null
        (Get-CpAppStatus -AppId 'app.bing-news').Status | Should Be 'NotInstalled'
    }
    It 'matches the package name ignoring case' {
        Add-FakePackage $t.Apps 'MICROSOFT.windowscommunicationsapps' | Out-Null
        (Get-CpAppStatus -AppId 'app.mail-calendar').Status | Should Be 'Installed'
    }
    It 'reports Unknown when the app list cannot be read' {
        $t.Apps.FailList = $true
        (Get-CpAppStatus -AppId 'app.bing-news').Status | Should Be 'Unknown'
    }
}

Describe 'App removal' {
    BeforeEach { $t = Initialize-CpTestEnvironment -Root $root }
    AfterEach { Remove-CpTestEnvironment $t }

    It 'refuses without approval and removes nothing' {
        Add-FakePackage $t.Apps 'Microsoft.BingNews' | Out-Null
        $r = Invoke-CpAppRemove -AppId 'app.bing-news'
        $r.Success | Should Be $false
        $r.Reason | Should Be 'approval-required'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'refuses an id that is not in the catalog' {
        Add-FakePackage $t.Apps 'Claude' | Out-Null
        $r = Invoke-CpAppRemove -AppId 'app.claude' -Approved
        $r.Reason | Should Be 'unknown-operation'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'removes an installed app, verifies it, and saves a record and history' {
        $p = Add-FakePackage $t.Apps 'Microsoft.BingNews' -Version '4.55.0.0'
        $r = Invoke-CpAppRemove -AppId 'app.bing-news' -Approved
        $r.Success | Should Be $true
        $r.Status | Should Be 'Removed'
        @($t.Apps.Packages).Count | Should Be 0
        $record = Read-CpAppRecord -Id 'app.bing-news'
        $record.state | Should Be 'Removed'
        @($record.packages)[0].fullName | Should Be $p.PackageFullName
        @($record.packages)[0].version | Should Be '4.55.0.0'
        $last = @(Get-CpHistory)[-1]
        $last.featureId | Should Be 'app.bing-news'
        $last.action | Should Be 'Remove'
        $last.status | Should Be 'Removed'
    }
    It 'removes only the requested app and leaves every other package alone' {
        Add-FakePackage $t.Apps 'Microsoft.BingNews' | Out-Null
        Add-FakePackage $t.Apps 'Claude' | Out-Null
        Add-FakePackage $t.Apps 'Microsoft.BingWeather' | Out-Null
        Invoke-CpAppRemove -AppId 'app.bing-news' -Approved | Out-Null
        (@($t.Apps.Packages | ForEach-Object { $_.Name }) | Sort-Object) -join ',' | Should Be 'Claude,Microsoft.BingWeather'
    }
    It 'removes every architecture of the same package' {
        Add-FakePackage $t.Apps 'Microsoft.BingNews' -Arch 'x64' | Out-Null
        Add-FakePackage $t.Apps 'Microsoft.BingNews' -Arch 'arm64' | Out-Null
        $r = Invoke-CpAppRemove -AppId 'app.bing-news' -Approved
        $r.Status | Should Be 'Removed'
        (Get-FakeRemoveCount $t.Apps) | Should Be 2
        @($t.Apps.Packages).Count | Should Be 0
    }
    It 'does nothing when the app is not installed' {
        $r = Invoke-CpAppRemove -AppId 'app.bing-news' -Approved
        $r.Success | Should Be $true
        $r.Status | Should Be 'NoChange'
        $r.Reason | Should Be 'app-not-installed'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
        (Read-CpAppRecord -Id 'app.bing-news') | Should Be $null
    }
    It 'refuses a package that Windows marks non-removable, even when it is in the catalog' {
        Add-FakePackage $t.Apps 'Microsoft.WindowsStore' -NonRemovable $true | Out-Null
        $r = Invoke-CpAppRemove -AppId 'app.store' -Approved -AllowUnsafe
        $r.Reason | Should Be 'app-protected'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'refuses framework and system-signed packages' {
        Add-FakePackage $t.Apps 'Microsoft.BingNews' -IsFramework $true | Out-Null
        (Invoke-CpAppRemove -AppId 'app.bing-news' -Approved).Reason | Should Be 'app-protected'
        $t.Apps.Packages.Clear()
        Add-FakePackage $t.Apps 'Microsoft.BingNews' -SignatureKind 'System' | Out-Null
        (Invoke-CpAppRemove -AppId 'app.bing-news' -Approved).Reason | Should Be 'app-protected'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'refuses a protected package when only one of several matching packages is protected' {
        Add-FakePackage $t.Apps 'Microsoft.BingNews' -Arch 'x64' | Out-Null
        Add-FakePackage $t.Apps 'Microsoft.BingNews' -Arch 'arm64' -NonRemovable $true | Out-Null
        (Invoke-CpAppRemove -AppId 'app.bing-news' -Approved).Reason | Should Be 'app-protected'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'needs the extra confirmation for an Unsafe app' {
        Add-FakePackage $t.Apps 'Microsoft.Xbox.TCUI' | Out-Null
        $r = Invoke-CpAppRemove -AppId 'app.xbox-tcui' -Approved
        $r.Reason | Should Be 'unsafe-needs-confirmation'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
        (Invoke-CpAppRemove -AppId 'app.xbox-tcui' -Approved -AllowUnsafe).Status | Should Be 'Removed'
    }
    It 'reports failure and keeps a Failed record when Windows refuses the removal' {
        $p = Add-FakePackage $t.Apps 'Microsoft.BingNews'
        $t.Apps.FailRemoveOn[$p.PackageFullName] = $true
        $r = Invoke-CpAppRemove -AppId 'app.bing-news' -Approved
        $r.Success | Should Be $false
        $r.Status | Should Be 'Failed'
        $r.Reason | Should Be 'access-denied'
        (Read-CpAppRecord -Id 'app.bing-news').state | Should Be 'Failed'
        @(Get-CpHistory)[-1].status | Should Be 'Failed'
    }
    It 'does not claim success when the package is still there after the removal call' {
        $p = Add-FakePackage $t.Apps 'Microsoft.BingNews'
        $t.Apps.SilentNoop[$p.PackageFullName] = $true
        $r = Invoke-CpAppRemove -AppId 'app.bing-news' -Approved
        $r.Success | Should Be $false
        $r.Reason | Should Be 'app-remove-failed'
    }
    It 'does not claim success when only some architectures were removed' {
        Add-FakePackage $t.Apps 'Microsoft.BingNews' -Arch 'x64' | Out-Null
        $second = Add-FakePackage $t.Apps 'Microsoft.BingNews' -Arch 'arm64'
        $t.Apps.FailRemoveOn[$second.PackageFullName] = $true
        $r = Invoke-CpAppRemove -AppId 'app.bing-news' -Approved
        $r.Success | Should Be $false
        @($t.Apps.Packages).Count | Should Be 1
    }
    It 'saves the record before the first removal call' {
        $p = Add-FakePackage $t.Apps 'Microsoft.BingNews'
        $seen = @{ Text = $null }
        $recordPath = Get-CpAppRecordPath -Id 'app.bing-news'
        $original = $t.Apps.Remove
        $t.Apps['Remove'] = {
            param([string]$PackageFullName)
            $seen.Text = [System.IO.File]::ReadAllText($recordPath)
            & $original $PackageFullName
        }.GetNewClosure()
        Invoke-CpAppRemove -AppId 'app.bing-news' -Approved | Out-Null
        $seen.Text | Should Match '"state":\s+"Removing"'
        $seen.Text | Should Match ([regex]::Escape($p.PackageFullName))
    }
    It 'refuses when the record cannot be written, and removes nothing' {
        Add-FakePackage $t.Apps 'Microsoft.BingNews' | Out-Null
        $blocker = Join-Path $t.DataRoot 'apps'
        New-Item -ItemType Directory -Path $t.DataRoot -Force | Out-Null
        Set-Content -LiteralPath $blocker -Value 'not a folder'
        $r = Invoke-CpAppRemove -AppId 'app.bing-news' -Approved
        $r.Reason | Should Be 'store-unavailable'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'refuses when the list of apps cannot be read' {
        $t.Apps.FailList = $true
        $r = Invoke-CpAppRemove -AppId 'app.bing-news' -Approved
        $r.Reason | Should Be 'app-list-failed'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'refuses a package full name with odd characters' {
        $p = Add-FakePackage $t.Apps 'Microsoft.BingNews'
        $p.PackageFullName = 'x; Remove-Item C:\*'
        $r = Invoke-CpAppRemove -AppId 'app.bing-news' -Approved
        $r.Reason | Should Be 'unsupported-value'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'builds a Store link only for a valid family name' {
        (Get-CpAppReinstallLink -FamilyName 'Microsoft.BingNews_8wekyb3d8bbwe') | Should Be 'ms-windows-store://pdp/?PFN=Microsoft.BingNews_8wekyb3d8bbwe'
        (Get-CpAppReinstallLink -FamilyName 'bad name & more') | Should Be ''
    }
    It 'never touches the registry' {
        Add-FakePackage $t.Apps 'Microsoft.BingNews' | Out-Null
        Invoke-CpAppRemove -AppId 'app.bing-news' -Approved | Out-Null
        (Get-FakeWriteCount $t.Registry) | Should Be 0
    }
}

Describe 'App command line' {
    BeforeEach {
        $t = Initialize-CpTestEnvironment -Root $root
        $lines = Start-CpOutputCapture
        Set-CpConfirm -Handler { param([string]$Prompt) $false }
        Add-FakePackage $t.Apps 'Microsoft.BingNews' -Version '4.55.0.0' | Out-Null
        Add-FakePackage $t.Apps 'Microsoft.BingWeather' | Out-Null
        Add-FakePackage $t.Apps 'Microsoft.Xbox.TCUI' | Out-Null
        Add-FakePackage $t.Apps 'Claude' | Out-Null
    }
    AfterEach { Remove-CpTestEnvironment $t }

    It 'lists the apps with safety and status without removing anything' {
        (Invoke-CpCli -Root $root -Language 'en-US' -App '*') | Should Be 0
        $text = $lines -join "`n"
        $text | Should Match 'CorePilot apps \('
        $text | Should Match 'app\.bing-news'
        $text | Should Match 'Installed'
        $text | Should Match 'Not installed'
        $text | Should Match 'Unsafe'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'lists in Turkish when asked' {
        (Invoke-CpCli -Root $root -Language 'tr-TR' -App 'app.bing-news') | Should Be 0
        ($lines -join "`n") | Should Match ('Y' + [char]0x00FC + 'kl' + [char]0x00FC)
    }
    It 'does not remove on -App alone, nor with -Remove and -PreviewOnly (the -WhatIf path)' {
        (Invoke-CpCli -Root $root -Language 'en-US' -App 'app.bing-news') | Should Be 0
        (Invoke-CpCli -Root $root -Language 'en-US' -App 'app.bing-news' -Remove -PreviewOnly) | Should Be 0
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'reports an unknown app with exit code 2 and removes nothing' {
        (Invoke-CpCli -Root $root -Language 'en-US' -App 'app.nope' -Remove -Yes) | Should Be 2
        ($lines -join "`n") | Should Match 'Unknown app: app.nope'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'does not accept -Remove together with features or -Apply' {
        (Invoke-CpCli -Root $root -Language 'en-US' -App 'app.bing-news' -Feature 'explorer.show-file-extensions' -Remove -Yes) | Should Be 2
        (Invoke-CpCli -Root $root -Language 'en-US' -Remove -Yes) | Should Be 2
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'does not remove when the user declines' {
        (Invoke-CpCli -Root $root -Language 'en-US' -App 'app.bing-news' -Remove) | Should Be 0
        ($lines -join "`n") | Should Match 'Nothing was changed'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'asks once with the number of apps and warns that it cannot be undone, then removes after a yes' {
        $asked = New-Object System.Collections.ArrayList
        Set-CpConfirm -Handler { param([string]$Prompt) [void]$asked.Add($Prompt); $true }.GetNewClosure()
        (Invoke-CpCli -Root $root -Language 'en-US' -App 'app.bing-news,app.bing-weather' -Remove) | Should Be 0
        $asked.Count | Should Be 1
        $asked[0] | Should Match 'Remove 2 app'
        $asked[0] | Should Match 'cannot undo'
        (@($t.Apps.Packages | ForEach-Object { $_.Name }) | Sort-Object) -join ',' | Should Be 'Claude,Microsoft.Xbox.TCUI'
        $text = $lines -join "`n"
        $text | Should Match 'Removed and verified'
        $text | Should Match 'ms-windows-store://pdp/\?PFN=Microsoft\.BingNews_8wekyb3d8bbwe'
    }
    It 'removes with -Yes without asking' {
        (Invoke-CpCli -Root $root -Language 'en-US' -App 'app.bing-news' -Remove -Yes) | Should Be 0
        (Get-FakeRemoveCount $t.Apps) | Should Be 1
    }
    It 'skips Unsafe apps with -Yes unless -AllowUnsafe is given' {
        (Invoke-CpCli -Root $root -Language 'en-US' -App 'app.xbox-tcui' -Remove -Yes) | Should Be 0
        ($lines -join "`n") | Should Match 'Skipped \(Unsafe'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
        (Invoke-CpCli -Root $root -Language 'en-US' -App 'app.xbox-tcui' -Remove -Yes -AllowUnsafe) | Should Be 0
        (Get-FakeRemoveCount $t.Apps) | Should Be 1
    }
    It 'asks a second question for Unsafe apps and honors a no' {
        $asked = New-Object System.Collections.ArrayList
        $answers = New-Object System.Collections.ArrayList
        [void]$answers.Add($true); [void]$answers.Add($false)
        Set-CpConfirm -Handler { param([string]$Prompt) [void]$asked.Add($Prompt); $answers[$asked.Count - 1] }.GetNewClosure()
        (Invoke-CpCli -Root $root -Language 'en-US' -App 'app.bing-news,app.xbox-tcui' -Remove) | Should Be 0
        $asked.Count | Should Be 2
        $asked[1] | Should Match 'marked Unsafe'
        (@($t.Apps.Packages | ForEach-Object { $_.Name }) | Sort-Object) -join ',' | Should Be 'Claude,Microsoft.BingWeather,Microsoft.Xbox.TCUI'
    }
    It 'says so for apps that are not installed or protected, and exits 0' {
        Add-FakePackage $t.Apps 'Microsoft.WindowsStore' -NonRemovable $true | Out-Null
        (Invoke-CpCli -Root $root -Language 'en-US' -App 'app.maps,app.store' -Remove -Yes -AllowUnsafe) | Should Be 0
        $text = $lines -join "`n"
        $text | Should Match 'Not installed: Maps'
        $text | Should Match 'Protected by Windows, skipped: Microsoft Store'
        (Get-FakeRemoveCount $t.Apps) | Should Be 0
    }
    It 'returns 1 when a removal fails' {
        $p = @($t.Apps.Packages | Where-Object { $_.Name -eq 'Microsoft.BingNews' })[0]
        $t.Apps.FailRemoveOn[$p.PackageFullName] = $true
        (Invoke-CpCli -Root $root -Language 'en-US' -App 'app.bing-news' -Remove -Yes) | Should Be 1
        ($lines -join "`n") | Should Match 'Access denied'
    }
    It 'shows removals in the history' {
        Invoke-CpCli -Root $root -Language 'en-US' -App 'app.bing-news' -Remove -Yes | Out-Null
        $lines.Clear()
        (Invoke-CpCli -Root $root -Language 'en-US' -History) | Should Be 0
        $text = $lines -join "`n"
        $text | Should Match 'app\.bing-news'
        $text | Should Match 'Remove'
    }
}
