$script:CpTexts = @{}
$script:CpFallbackTexts = @{}
$script:CpLanguage = 'en-US'

function Read-CpJson {
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ConvertFrom-Json -InputObject $text
}

function ConvertTo-CpHashtable {
    param([Parameter(Mandatory)]$Object)
    $table = @{}
    foreach ($property in $Object.PSObject.Properties) { $table[$property.Name] = [string]$property.Value }
    return $table
}

function Resolve-CpLanguage {
    param([string]$Requested)
    if ([string]::IsNullOrWhiteSpace($Requested)) {
        $Requested = [System.Globalization.CultureInfo]::CurrentUICulture.Name
    }
    if ($Requested -like 'tr*') { return 'tr-TR' }
    return 'en-US'
}

function Import-CpLocale {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Language
    )
    $resolved = Resolve-CpLanguage -Requested $Language
    $english = ConvertTo-CpHashtable (Read-CpJson (Join-Path $Root 'Locales\en-US.json'))
    $current = $english
    if ($resolved -ne 'en-US') {
        $current = ConvertTo-CpHashtable (Read-CpJson (Join-Path $Root "Locales\$resolved.json"))
    }
    $script:CpFallbackTexts = $english
    $script:CpTexts = $current
    $script:CpLanguage = $resolved
}

function Get-CpText {
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$FormatArgs = @()
    )
    $template = $null
    if ($script:CpTexts.ContainsKey($Key)) { $template = $script:CpTexts[$Key] }
    elseif ($script:CpFallbackTexts.ContainsKey($Key)) { $template = $script:CpFallbackTexts[$Key] }
    else { return $Key }
    if ($FormatArgs.Count -gt 0) { return [string]::Format($template, $FormatArgs) }
    return $template
}
