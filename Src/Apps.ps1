# App removal (Store/Appx apps, current user only). Design: docs\APPS-DESIGN.md
# Only packages listed in Data\Apps.json can be removed, by exact package name. Windows-protected packages are refused.
# The package provider is replaceable (Set-CpAppProvider) so tests never touch real apps.

$script:CpAppCatalog = $null
$script:CpAppSafeties = @('Safe', 'Optional', 'Unsafe')
$script:CpAppIdPattern = '^app\.[a-z0-9]+(-[a-z0-9]+)*$'
$script:CpAppPackagePattern = '^[A-Za-z0-9][A-Za-z0-9.\-]*$'
$script:CpPackageFullNamePattern = '^[A-Za-z0-9][A-Za-z0-9._~\-]*$'

# Core Windows packages that must never appear in the catalog, whatever else is decided later.
$script:CpAppNeverRemove = @(
    'Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.Windows.CloudExperienceHost',
    'Microsoft.Windows.ContentDeliveryManager', 'Microsoft.Windows.Search', 'Microsoft.SecHealthUI', 'Microsoft.DesktopAppInstaller',
    'Microsoft.MicrosoftEdge', 'Microsoft.MicrosoftEdge.Stable', 'Microsoft.Win32WebViewHost', 'Microsoft.AAD.BrokerPlugin',
    'Microsoft.AccountsControl', 'Microsoft.LockApp', 'Microsoft.Windows.PeopleExperienceHost', 'Microsoft.UI.Xaml',
    'Microsoft.VCLibs', 'Microsoft.NET.Native.Framework', 'Microsoft.NET.Native.Runtime', 'Microsoft.WindowsAppRuntime',
    'windows.immersivecontrolpanel', 'Windows.PrintDialog', 'MicrosoftWindows.Client.CBS', 'MicrosoftWindows.Client.Core',
    'MicrosoftWindows.Client.FileExp', 'MicrosoftWindows.Client.OOBE', 'MicrosoftWindows.Client.CoreAI'
)

# ---- provider ----------------------------------------------------------------------------------------------------

function New-CpRealAppProvider {
    $list = {
        # Current user only. One call returns everything; callers filter by exact name.
        # Listing only reads. Under -WhatIf the Appx module would otherwise print one "Set Alias" line per alias while it
        # loads; it reads the session-wide preference, so that one is switched off for the duration of the call (and restored).
        $found = New-Object System.Collections.ArrayList
        $previousWhatIf = $global:WhatIfPreference
        try {
            $global:WhatIfPreference = $false
            $packages = @(Get-AppxPackage -ErrorAction Stop)
        }
        finally { $global:WhatIfPreference = $previousWhatIf }
        foreach ($package in $packages) {
            [void]$found.Add([pscustomobject]@{
                    Name              = [string]$package.Name
                    PackageFullName   = [string]$package.PackageFullName
                    PackageFamilyName = [string]$package.PackageFamilyName
                    Version           = [string]$package.Version
                    NonRemovable      = [bool]$package.NonRemovable
                    IsFramework       = [bool]$package.IsFramework
                    SignatureKind     = [string]$package.SignatureKind
                })
        }
        return $found.ToArray()
    }
    $remove = {
        param([string]$PackageFullName)
        Remove-AppxPackage -Package $PackageFullName -ErrorAction Stop
    }
    return @{ List = $list; Remove = $remove; IsFake = $false }
}

$script:CpApps = New-CpRealAppProvider

function Set-CpAppProvider {
    param([Parameter(Mandatory)][hashtable]$Provider)
    $script:CpApps = $Provider
}

function Reset-CpAppProvider { $script:CpApps = New-CpRealAppProvider }

function Get-CpInstalledPackages {
    $list = $script:CpApps.List
    return @(& $list)
}

# ---- catalog -----------------------------------------------------------------------------------------------------

function Test-CpAppCatalog {
    param([Parameter(Mandatory)]$Catalog)
    $problems = New-Object System.Collections.Generic.List[string]
    $ids = @{}
    $packages = @{}
    if ($Catalog.schema -ne 1) { $problems.Add('schema must be 1') }
    $apps = @($Catalog.apps)
    if ($apps.Count -eq 0) { $problems.Add('app catalog has no apps') }
    foreach ($app in $apps) {
        $id = [string]$app.id
        if ($id -cnotmatch $script:CpAppIdPattern) { $problems.Add("bad app id '$id'"); continue }
        if ($ids.ContainsKey($id)) { $problems.Add("duplicate app id '$id'") }
        $ids[$id] = $true
        $package = [string]$app.package
        if ($package -cnotmatch $script:CpAppPackagePattern) { $problems.Add("$id : bad package name '$package'"); continue }
        $key = $package.ToLowerInvariant()
        if ($packages.ContainsKey($key)) { $problems.Add("$id : package '$package' is already used by '$($packages[$key])'") }
        $packages[$key] = $id
        foreach ($never in $script:CpAppNeverRemove) {
            if ($package.ToLowerInvariant() -ceq $never.ToLowerInvariant()) { $problems.Add("$id : package '$package' must never be removable") }
        }
        if ($script:CpAppSafeties -cnotcontains [string]$app.safety) { $problems.Add("$id : unknown safety '$($app.safety)'") }
        if ([string]::IsNullOrWhiteSpace([string]$app.name)) { $problems.Add("$id : missing name") }
    }
    return $problems.ToArray()
}

function Import-CpAppCatalog {
    param([Parameter(Mandatory)][string]$Root)
    $catalog = Read-CpJson (Join-Path $Root 'Data\Apps.json')
    $problems = @(Test-CpAppCatalog -Catalog $catalog)
    if ($problems.Count -gt 0) { throw ("The app catalog is invalid:`n" + ($problems -join "`n")) }
    $script:CpAppCatalog = $catalog
}

function Get-CpApps {
    if ($null -eq $script:CpAppCatalog) { return @() }
    return @($script:CpAppCatalog.apps)
}

function Get-CpApp {
    param([Parameter(Mandatory)][string]$Id)
    foreach ($app in (Get-CpApps)) { if ($app.id -ceq $Id) { return $app } }
    return $null
}

function Test-CpPackageName {
    param([string]$Left, [string]$Right)
    return [string]::Equals($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase)
}

# ---- status ------------------------------------------------------------------------------------------------------

function Test-CpPackageProtected {
    param($Package)
    if ($Package.NonRemovable -or $Package.IsFramework) { return $true }
    if ($Package.SignatureKind -eq 'System') { return $true }
    return $false
}

# Reads the package list once and returns one status object per catalog app. Never writes.
# Status: Installed, NotInstalled, Protected (installed but Windows does not allow removal), Unknown.
function Get-CpAppStatusList {
    param($Installed = $null)
    if ($null -eq $Installed) {
        try { $Installed = @(Get-CpInstalledPackages) }
        catch {
            return @(Get-CpApps | ForEach-Object { [pscustomobject]@{ AppId = $_.id; Status = 'Unknown'; Packages = @() } })
        }
    }
    $result = New-Object System.Collections.ArrayList
    foreach ($app in (Get-CpApps)) {
        $hits = @($Installed | Where-Object { Test-CpPackageName -Left $_.Name -Right $app.package })
        $status = 'NotInstalled'
        if ($hits.Count -gt 0) {
            $status = 'Installed'
            foreach ($package in $hits) { if (Test-CpPackageProtected -Package $package) { $status = 'Protected' } }
        }
        [void]$result.Add([pscustomobject]@{ AppId = $app.id; Status = $status; Packages = $hits })
    }
    return $result.ToArray()
}

function Get-CpAppStatus {
    param([Parameter(Mandatory)][string]$AppId)
    foreach ($item in (Get-CpAppStatusList)) { if ($item.AppId -ceq $AppId) { return $item } }
    return $null
}

# ---- records -----------------------------------------------------------------------------------------------------

function Get-CpAppRecordPath {
    param([string]$Id)
    if ($Id -cnotmatch $script:CpAppIdPattern) { throw "Unsafe app id '$Id'." }
    return (Join-Path (Join-Path (Get-CpDataRoot) 'apps') "$Id.json")
}

function Save-CpAppRecord {
    param([Parameter(Mandatory)]$Record)
    $path = Get-CpAppRecordPath -Id $Record.appId
    $Record.updatedUtc = [DateTime]::UtcNow.ToString('o')
    Write-CpFileAtomic -Path $path -Text (ConvertTo-Json -InputObject $Record -Depth 6)
}

function Read-CpAppRecord {
    param([Parameter(Mandatory)][string]$Id)
    $path = Get-CpAppRecordPath -Id $Id
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $record = Read-CpJson $path
    if ($record.schema -ne 1 -or $record.appId -cne $Id -or -not ($record.state -is [string])) { throw "App record for '$Id' is not valid." }
    return $record
}

function New-CpAppRecord {
    param([string]$AppId, [string]$State, [object[]]$Packages)
    $now = [DateTime]::UtcNow.ToString('o')
    $items = @($Packages | ForEach-Object {
            [ordered]@{ name = $_.Name; fullName = $_.PackageFullName; familyName = $_.PackageFamilyName; version = $_.Version }
        })
    return [ordered]@{ schema = 1; appId = $AppId; state = $State; createdUtc = $now; updatedUtc = $now; packages = $items }
}

# The Microsoft Store page of an app, for installing it again by hand.
function Get-CpAppReinstallLink {
    param([string]$FamilyName)
    if ($FamilyName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.\-]*_[a-z0-9]+$') { return '' }
    return "ms-windows-store://pdp/?PFN=$FamilyName"
}

# ---- remove ------------------------------------------------------------------------------------------------------

function New-CpAppResult {
    param([string]$AppId, [bool]$Success, [string]$Status, [string]$Reason = '', [string]$Detail = '', $Packages = @())
    if ($Reason -and $script:CpReasonCodes -cnotcontains $Reason) { throw "Unknown reason code '$Reason'." }
    return [pscustomobject]@{ FeatureId = $AppId; Action = 'Remove'; Success = $Success; Status = $Status; Reason = $Reason; Detail = $Detail; Packages = @($Packages) }
}

function Invoke-CpAppRemove {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppId,
        [switch]$Approved,
        [switch]$AllowUnsafe
    )
    $app = Get-CpApp -Id $AppId
    if ($null -eq $app) { return New-CpAppResult $AppId $false 'Refused' 'unknown-operation' }
    if (-not $Approved) { return New-CpAppResult $AppId $false 'Refused' 'approval-required' }
    if ($app.safety -ceq 'Unsafe' -and -not $AllowUnsafe) { return New-CpAppResult $AppId $false 'Refused' 'unsafe-needs-confirmation' }

    $lock = Enter-CpLock
    if ($null -eq $lock) { return New-CpAppResult $AppId $false 'Refused' 'busy' }
    try { $result = Invoke-CpAppRemoveLocked -App $app }
    catch { $result = New-CpAppResult $AppId $false 'Failed' 'unexpected' $_.Exception.Message }
    finally { Exit-CpLock $lock }
    if ($result.Status -in @('Removed', 'Failed', 'RecoveryNeeded')) {
        Add-CpHistory -FeatureId $AppId -Action 'Remove' -Status $result.Status -Reason $result.Reason
    }
    return $result
}

function Invoke-CpAppRemoveLocked {
    param($App)
    $id = $App.id
    try { $installed = @(Get-CpInstalledPackages) }
    catch { return New-CpAppResult $id $false 'Refused' 'app-list-failed' $_.Exception.Message }

    $packages = @($installed | Where-Object { Test-CpPackageName -Left $_.Name -Right $App.package })
    if ($packages.Count -eq 0) { return New-CpAppResult $id $true 'NoChange' 'app-not-installed' }
    foreach ($package in $packages) {
        if (Test-CpPackageProtected -Package $package) { return New-CpAppResult $id $false 'Refused' 'app-protected' $package.Name }
        if ([string]$package.PackageFullName -cnotmatch $script:CpPackageFullNamePattern) { return New-CpAppResult $id $false 'Refused' 'unsupported-value' $package.Name }
    }

    $record = New-CpAppRecord -AppId $id -State 'Removing' -Packages $packages
    try { Save-CpAppRecord -Record $record }
    catch { return New-CpAppResult $id $false 'Refused' 'store-unavailable' $_.Exception.Message }

    $firstError = $null
    foreach ($package in $packages) {
        try { $remove = $script:CpApps.Remove; & $remove ([string]$package.PackageFullName) }
        catch { if ($null -eq $firstError) { $firstError = $_ } }
    }

    $remaining = $null
    try { $remaining = @(Get-CpInstalledPackages | Where-Object { Test-CpPackageName -Left $_.Name -Right $App.package }) }
    catch { $remaining = $null }

    if ($null -eq $remaining) {
        $record.state = 'RecoveryNeeded'
        try { Save-CpAppRecord -Record $record } catch { }
        return New-CpAppResult $id $false 'RecoveryNeeded' 'app-list-failed' '' $packages
    }
    if ($remaining.Count -eq 0) {
        $record.state = 'Removed'
        try { Save-CpAppRecord -Record $record } catch { }
        return New-CpAppResult $id $true 'Removed' '' '' $packages
    }

    $reason = 'app-remove-failed'
    $detail = ''
    if ($null -ne $firstError) {
        $exception = $firstError.Exception
        while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
        if ($exception -is [System.UnauthorizedAccessException]) { $reason = 'access-denied' }
        $detail = $exception.Message
    }
    $record.state = 'Failed'
    try { Save-CpAppRecord -Record $record } catch { }
    return New-CpAppResult $id $false 'Failed' $reason $detail $packages
}
