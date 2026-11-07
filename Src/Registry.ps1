# Registry access. Only HKEY_CURRENT_USER is ever touched, and only DWord and String values are supported.
# The provider is replaceable (Set-CpRegistryProvider) so tests can run against an in-memory fake.

function New-CpRealRegistry {
    $get = {
        param([string]$Path, [string]$Name)
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path, $false)
        if ($null -eq $key) { return [pscustomobject]@{ Exists = $false; Kind = $null; Value = $null } }
        try {
            if (@($key.GetValueNames()) -notcontains $Name) {
                return [pscustomobject]@{ Exists = $false; Kind = $null; Value = $null }
            }
            $kind = $key.GetValueKind($Name).ToString()
            $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return [pscustomobject]@{ Exists = $true; Kind = $kind; Value = $value }
        }
        finally { $key.Dispose() }
    }
    $set = {
        param([string]$Path, [string]$Name, [string]$Kind, $Value)
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Path)
        try {
            if ($Kind -eq 'DWord') { $key.SetValue($Name, [int]$Value, [Microsoft.Win32.RegistryValueKind]::DWord) }
            elseif ($Kind -eq 'String') { $key.SetValue($Name, [string]$Value, [Microsoft.Win32.RegistryValueKind]::String) }
            else { throw "Unsupported registry value kind '$Kind'." }
        }
        finally { $key.Dispose() }
    }
    $remove = {
        param([string]$Path, [string]$Name)
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path, $true)
        if ($null -eq $key) { return }
        try { $key.DeleteValue($Name, $false) }
        finally { $key.Dispose() }
    }
    return @{ Get = $get; Set = $set; Remove = $remove; IsFake = $false }
}

$script:CpRegistry = New-CpRealRegistry

function Set-CpRegistryProvider {
    param([Parameter(Mandatory)][hashtable]$Provider)
    $script:CpRegistry = $Provider
}

function Reset-CpRegistryProvider {
    $script:CpRegistry = New-CpRealRegistry
}

function Test-CpRegistryProviderIsFake {
    return [bool]$script:CpRegistry.IsFake
}

function Read-CpRegistry {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $get = $script:CpRegistry.Get
    return (& $get $Path $Name)
}

# Writes only to targets that appear in the feature catalog.
function Write-CpRegistry {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Value
    )
    if (-not (Test-CpAllowedTarget -Path $Path -Name $Name)) { throw "Target '$Path\$Name' is not in the allowed list." }
    $set = $script:CpRegistry.Set
    & $set $Path $Name $Kind $Value
}

function Remove-CpRegistry {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-CpAllowedTarget -Path $Path -Name $Name)) { throw "Target '$Path\$Name' is not in the allowed list." }
    $remove = $script:CpRegistry.Remove
    & $remove $Path $Name
}

function Get-CpWindowsBuild {
    $provider = $script:CpBuildProvider
    if ($null -ne $provider) { return (& $provider) }
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion', $false)
        if ($null -ne $key) {
            try { return [int]$key.GetValue('CurrentBuildNumber') } finally { $key.Dispose() }
        }
    }
    catch { }
    return 0
}

$script:CpBuildProvider = $null
function Set-CpBuildProvider {
    param([scriptblock]$Provider)
    $script:CpBuildProvider = $Provider
}
