<#
.SYNOPSIS
    CorePilot - safe, reversible Windows 11 tweaks for the current user.

.DESCRIPTION
    Without parameters it lists every feature and whether it is already applied (reading only).
    -Feature shows a preview of what would change. Nothing is written unless you add -Apply
    and confirm (or pass -Yes). Every change records the original value first, so -Undo can restore it.

.EXAMPLE
    .\CorePilot.ps1
    .\CorePilot.ps1 -Feature explorer.show-file-extensions
    .\CorePilot.ps1 -Feature 'privacy.*' -Apply
    .\CorePilot.ps1 -Feature explorer.show-file-extensions -Undo
    .\CorePilot.ps1 -History
    .\CorePilot.ps1 -App '*'
    .\CorePilot.ps1 -App app.clipchamp,app.bing-news -Remove
    .\CorePilot.ps1 -Gui
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Show')]
param(
    [Parameter(ParameterSetName = 'Show')]
    [Parameter(ParameterSetName = 'Apply', Mandatory = $true)]
    [Parameter(ParameterSetName = 'Undo', Mandatory = $true)]
    [string[]]$Feature = @(),

    [Parameter(ParameterSetName = 'Apply', Mandatory = $true)]
    [switch]$Apply,

    [Parameter(ParameterSetName = 'Undo', Mandatory = $true)]
    [switch]$Undo,

    [Parameter(ParameterSetName = 'Apps', Mandatory = $true)]
    [Parameter(ParameterSetName = 'RemoveApps', Mandatory = $true)]
    [string[]]$App = @(),

    [Parameter(ParameterSetName = 'RemoveApps', Mandatory = $true)]
    [switch]$Remove,

    [Parameter(ParameterSetName = 'RemoveApps')]
    [switch]$AllowUnsafe,

    [Parameter(ParameterSetName = 'History', Mandatory = $true)]
    [switch]$History,

    [Parameter(ParameterSetName = 'Gui', Mandatory = $true)]
    [switch]$Gui,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Undo')]
    [Parameter(ParameterSetName = 'RemoveApps')]
    [switch]$Yes,

    [ValidateSet('en-US', 'tr-TR')]
    [string]$Language
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try { . (Join-Path $PSScriptRoot 'Src\Load.ps1') }
catch {
    if ($Gui) {
        # The window is started without a console, so say what went wrong in a message box.
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show("CorePilot could not start:`n$($_.Exception.Message)", 'CorePilot', 'OK', 'Error')
        exit 1
    }
    throw
}

if ($Gui) { exit (Show-CpGui -Root $PSScriptRoot -Language $Language) }

$exitCode = Invoke-CpCli -Root $PSScriptRoot -Feature $Feature -App $App -Apply:$Apply -Undo:$Undo -Remove:$Remove `
    -AllowUnsafe:$AllowUnsafe -Yes:$Yes -History:$History -PreviewOnly:$WhatIfPreference -Language $Language
exit $exitCode
