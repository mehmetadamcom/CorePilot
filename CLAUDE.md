# CorePilot - project rules

PowerShell 5.1 tool for safe, reversible Windows 11 tweaks. Modeled on the feature set of raphire/win11debloat (MIT), but all code and data are written from scratch: never copy its code, `.reg` files or JSON.

## Working agreement
- Chat with the user in Turkish; keep explanations short and plain.
- Never change the real OS (registry, apps, services) without the user's explicit approval for that action. Read-only checks are fine.
- Never claim something is verified unless it was actually run; say what was not tested.
- Third-party tools (e.g. the REA skill) stay outside this folder.

## Code rules
- Every `.ps1` file is ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI). User-visible text goes in `Locales/en-US.json` and `Locales/tr-TR.json` (UTF-8), always both, same keys and placeholders.
- Regexes on ids, paths and names use `-cmatch`/`-cnotmatch`: case-insensitive matching follows the culture, and in Turkish `I` does not match `i`/`[a-z]` (this broke catalog validation once).
- Do not `return , $array` from functions that callers wrap in `@()`; that yields a one-element array holding the array.
- `Data/Features.json` and `Locales/*.json` are edited directly (the generator script used for Phases 1-2 was a session-only helper and is not part of the project).
- Every new tweak is a data entry in `Data/Features.json` (HKCU, DWord/String only until the engine supports more) plus Name/Description in both locales. `Test-CpCatalog` and the locale tests must pass.
- Writes go through `Write-CpRegistry`/`Remove-CpRegistry` only (allowlist from the catalog). New anything-admin/HKLM work needs its own design and user approval first.

## App removal rules
- Only packages in `Data/Apps.json` (exact name) may be removed, current user only. `Test-CpAppCatalog` also rejects core Windows packages (`$script:CpAppNeverRemove`); never shorten that list. Windows-protected packages (NonRemovable, framework, system-signed) are refused at run time as well.
- Package access goes through the app provider (`Set-CpAppProvider`). Tests use `New-CpFakeAppProvider` (set by `Initialize-CpTestEnvironment`); a test must never list or remove real apps.
- Removal cannot be undone: never say or imply otherwise in texts. Record first (`%LOCALAPPDATA%\CorePilot\apps`), verify after, never report success when a package is still there.
- Unsafe apps need a separate confirmation (`-AllowUnsafe` or a second yes). Do not add apps the user installed themselves (Claude, PowerToys, VS Code, WhatsApp, ...).
- Under `-WhatIf` the Appx module prints "Set Alias" noise when it loads; the real list call switches `$global:WhatIfPreference` off while reading (see `Src/Apps.ps1`).
- Real removal on this PC only after the user explicitly approves each app, one at a time.

## GUI rules
- Window logic lives in `Src/GuiModel.ps1` (testable, no window); `Src/Gui.ps1` is a thin WPF layer over it; layout in `Gui/MainWindow.xaml` (ASCII only, no texts: all texts come from `Locales`).
- All window events go through `Invoke-CpGuiAction` using `$script:CpGuiCtx` (handlers run after the creating function returned; do not rely on function locals or `GetNewClosure` there).
- Put WPF brushes in resources with `[SolidColorBrush]::new(...)`, never `New-Object` (PowerShell wrapper is rejected by WPF).
- Apply/Undo must always ask first and name every feature (selection can include rows hidden by a filter). Tests inject `$ctx.Confirm`/`$ctx.Notify`; never show a real MessageBox in tests.
- Never apply anything to the real PC while checking the window; screenshots are taken read-only.
- The window is launched without a console (`conhost.exe --headless`), so errors must be visible some other way: `Show-CpGui` catches start-up failures into a message box + `gui-error.log`. Keep it that way.
- The window has two views (`$ctx.Mode`: `Settings` / `Apps`) that share the same card columns; the apps are read from Windows only when the Apps view is opened or refreshed. Anything that touches "the rows" must go through `Get-CpGuiCurrentRows`. The Apps view never has quick select or an undo button, and its question must say that a removal cannot be undone.
- WPF `CheckBox` ignores the window text color: keep the implicit `CheckBox` style in `MainWindow.xaml`.
- A `.lnk` that starts hidden PowerShell was deleted within minutes on the user's PC (Kaspersky + Defender present); do not ship shortcut generators. Keep `CorePilot.cmd` transparent: a few readable lines, no encoded commands, no downloads.

## Tests
```
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester; Invoke-Pester -Path .\Tests"
```
Tests use `Initialize-CpTestEnvironment` (fake registry, temp data folder, fixed Windows build). They must never touch the real registry or `%LOCALAPPDATA%\CorePilot`. Pester 3.4 syntax (`Should Be`), closures only capture local variables.
