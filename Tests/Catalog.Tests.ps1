$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Src\Load.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Set-CpRegistryProvider -Provider (New-CpFakeRegistry)

function Read-CatalogText { return [System.IO.File]::ReadAllText((Join-Path $root 'Data\Features.json'), [System.Text.Encoding]::UTF8) }
function Test-Mutated {
    param([scriptblock]$Mutate)
    $catalog = ConvertFrom-Json -InputObject (Read-CatalogText)
    & $Mutate $catalog
    return @(Test-CpCatalog -Catalog $catalog)
}

Describe 'Feature catalog' {
    $real = ConvertFrom-Json -InputObject (Read-CatalogText)

    It 'is valid' {
        $problems = @(Test-CpCatalog -Catalog $real)
        ($problems -join '; ') | Should Be ''
    }
    It 'is valid under the Turkish and the English culture (upper-case I must not break matching)' {
        $thread = [System.Threading.Thread]::CurrentThread
        $saved = $thread.CurrentCulture
        try {
            foreach ($name in @('tr-TR', 'en-US')) {
                $thread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($name)
                $problems = @(Test-CpCatalog -Catalog $real)
                ("$name : " + ($problems -join '; ')) | Should Be "$name : "
            }
        }
        finally { $thread.CurrentCulture = $saved }
    }
    It 'starts every id with its category name' {
        $bad = @($real.features | Where-Object { -not $_.id.StartsWith($_.category.ToLowerInvariant() + '.') } | ForEach-Object { $_.id })
        ($bad -join ',') | Should Be ''
    }
    It 'has at least 20 features' {
        @($real.features).Count | Should BeGreaterThan 19
    }
    It 'only targets HKCU-style relative paths' {
        foreach ($feature in $real.features) {
            foreach ($change in $feature.changes) { $change.path | Should Match '^(Software|Control Panel)\\' }
        }
    }
    It 'rejects a duplicate id' {
        $p = Test-Mutated { param($c) $c.features[1].id = $c.features[0].id }
        ($p -join ';') | Should Match 'duplicate id'
    }
    It 'rejects a machine-wide or traversal path' {
        $p = Test-Mutated { param($c) $c.features[0].changes[0].path = 'SYSTEM\CurrentControlSet\Services\X' }
        ($p -join ';') | Should Match 'not an allowed HKCU path'
        $p = Test-Mutated { param($c) $c.features[0].changes[0].path = 'Software\..\..\X' }
        ($p -join ';') | Should Match 'not an allowed HKCU path'
    }
    It 'rejects an unsupported value type' {
        $p = Test-Mutated { param($c) $c.features[0].changes[0].type = 'Binary' }
        ($p -join ';') | Should Match "unsupported type"
    }
    It 'rejects a negative DWord and a non-string String' {
        $p = Test-Mutated { param($c) $c.features[0].changes[0].value = -1 }
        ($p -join ';') | Should Match 'DWord value'
        $c2 = ConvertFrom-Json -InputObject (Read-CatalogText)
        $idx = 0
        foreach ($f in $c2.features) { if ($f.id -eq 'input.disable-mouse-acceleration') { break }; $idx++ }
        $c2.features[$idx].changes[0].value = 5
        (@(Test-CpCatalog -Catalog $c2) -join ';') | Should Match 'String value'
    }
    It 'rejects a target used by two features' {
        $p = Test-Mutated {
            param($c)
            $c.features[1].changes[0].path = $c.features[0].changes[0].path
            $c.features[1].changes[0].name = $c.features[0].changes[0].name
        }
        ($p -join ';') | Should Match 'already used'
    }
    It 'rejects unknown risk, category and empty changes' {
        (Test-Mutated { param($c) $c.features[0].risk = 'Scary' }) -join ';' | Should Match 'unknown risk'
        (Test-Mutated { param($c) $c.features[0].category = 'Nope' }) -join ';' | Should Match 'unknown category'
        (Test-Mutated { param($c) $c.features[0].changes = @() }) -join ';' | Should Match 'no changes'
    }
    It 'refuses to load an invalid catalog' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('CpCat-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $temp 'Data') -Force | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $temp 'Data\Features.json') -Value '{"schema":1,"features":[]}' -Encoding UTF8
            { Import-CpCatalog -Root $temp } | Should Throw
        }
        finally { Remove-Item -LiteralPath $temp -Recurse -Force }
    }
}

Describe 'Locales' {
    $en = ConvertTo-CpHashtable (Read-CpJson (Join-Path $root 'Locales\en-US.json'))
    $tr = ConvertTo-CpHashtable (Read-CpJson (Join-Path $root 'Locales\tr-TR.json'))
    $catalog = ConvertFrom-Json -InputObject (Read-CatalogText)

    It 'has the same keys in both languages' {
        $onlyEn = @($en.Keys | Where-Object { -not $tr.ContainsKey($_) })
        $onlyTr = @($tr.Keys | Where-Object { -not $en.ContainsKey($_) })
        ($onlyEn -join ',') | Should Be ''
        ($onlyTr -join ',') | Should Be ''
    }
    It 'has no empty text' {
        $empty = @($en.Keys | Where-Object { [string]::IsNullOrWhiteSpace($en[$_]) -or [string]::IsNullOrWhiteSpace($tr[$_]) })
        ($empty -join ',') | Should Be ''
    }
    It 'uses the same placeholders in both languages' {
        $bad = @($en.Keys | Where-Object {
                $a = @([regex]::Matches($en[$_], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object)
                $b = @([regex]::Matches($tr[$_], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object)
                ($a -join '') -ne ($b -join '')
            })
        ($bad -join ',') | Should Be ''
    }
    It 'names and describes every feature, and labels every category and risk' {
        $missing = New-Object System.Collections.ArrayList
        foreach ($f in $catalog.features) {
            foreach ($k in @("Feature.$($f.id).Name", "Feature.$($f.id).Description", "Category.$($f.category)", "Risk.$($f.risk)")) {
                if (-not $en.ContainsKey($k)) { [void]$missing.Add($k) }
            }
            if ($f.reboot -ne 'None' -and -not $en.ContainsKey("Reboot.$($f.reboot)")) { [void]$missing.Add("Reboot.$($f.reboot)") }
        }
        ($missing -join ',') | Should Be ''
    }
    It 'has a message for every failure reason, status and result state' {
        $missing = New-Object System.Collections.ArrayList
        foreach ($code in $script:CpReasonCodes) { if (-not $en.ContainsKey("Failure.$code")) { [void]$missing.Add("Failure.$code") } }
        foreach ($s in @('Applied', 'NotApplied', 'Partial', 'Unknown', 'Unsupported')) { if (-not $en.ContainsKey("Status.$s")) { [void]$missing.Add("Status.$s") } }
        foreach ($s in @('Applying', 'Verified', 'Failed', 'Reverting', 'Reverted', 'RecoveryNeeded', 'NoChange', 'Refused')) { if (-not $en.ContainsKey("State.$s")) { [void]$missing.Add("State.$s") } }
        ($missing -join ',') | Should Be ''
    }
    It 'defines every text key that the source files ask for' {
        $missing = New-Object System.Collections.ArrayList
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'Src') -Filter '*.ps1') {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            foreach ($m in [regex]::Matches($text, "Get-CpText\s+'([A-Za-z0-9.\-]+)'")) {
                if (-not $en.ContainsKey($m.Groups[1].Value)) { [void]$missing.Add($m.Groups[1].Value) }
            }
        }
        ($missing -join ',') | Should Be ''
    }
    It 'picks Turkish for tr cultures and English otherwise' {
        Resolve-CpLanguage -Requested 'tr-TR' | Should Be 'tr-TR'
        Resolve-CpLanguage -Requested 'tr' | Should Be 'tr-TR'
        Resolve-CpLanguage -Requested 'de-DE' | Should Be 'en-US'
    }
    It 'falls back to the key for an unknown text' {
        Import-CpLocale -Root $root -Language 'en-US'
        Get-CpText 'No.Such.Key' | Should Be 'No.Such.Key'
    }
}

Describe 'Source hygiene' {
    It 'keeps every .ps1 file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
        $bad = New-Object System.Collections.ArrayList
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' -File)
        foreach ($file in $files) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            foreach ($b in $bytes) { if ($b -gt 127) { [void]$bad.Add($file.Name); break } }
        }
        ($bad -join ',') | Should Be ''
        $files.Count | Should BeGreaterThan 5
    }
    It 'only touches the registry through HKEY_CURRENT_USER' {
        $text = [System.IO.File]::ReadAllText((Join-Path $root 'Src\Registry.ps1'))
        $text | Should Match 'Registry\]::CurrentUser'
        ([regex]::Matches($text, 'Registry\]::(?!CurrentUser)(\w+)') | ForEach-Object { $_.Groups[1].Value }) -join ',' | Should Be 'LocalMachine'
    }
}
