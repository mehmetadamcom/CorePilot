# Loads every CorePilot source file into the caller's scope (dot-source this file).
# All .ps1 files in this project must stay ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
# User-visible text lives in Locales\*.json (UTF-8).

. (Join-Path $PSScriptRoot 'Localization.ps1')
. (Join-Path $PSScriptRoot 'Catalog.ps1')
. (Join-Path $PSScriptRoot 'Registry.ps1')
. (Join-Path $PSScriptRoot 'Store.ps1')
. (Join-Path $PSScriptRoot 'Engine.ps1')
. (Join-Path $PSScriptRoot 'Cli.ps1')
. (Join-Path $PSScriptRoot 'GuiModel.ps1')
. (Join-Path $PSScriptRoot 'Gui.ps1')
