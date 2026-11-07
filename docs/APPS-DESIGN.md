# Phase 5 design: app removal

Scope of this step: remove Store/Appx apps **for the current user only** (no administrator rights, no provisioned packages, no winget, no classic Win32 uninstallers). Written from scratch; the app list is CorePilot's own.

## Safety model

1. **Allowlist only.** Only packages named in `Data/Apps.json` can ever be removed. The match is on the exact package name. There is no wildcard removal and no "remove everything that matches".
2. **Three labels.** `Safe` (consumer extras nobody depends on), `Optional` (useful to many people, remove only if you do not use it), `Unsafe` (removing can break sign-in, the Store or Xbox features). `Unsafe` needs an extra, separate confirmation (`-AllowUnsafe` on the command line).
3. **Windows protection wins.** A package that Windows marks `NonRemovable`, a framework package, or a system-signed package is refused (`app-protected`), even if it were in the catalog. A built-in test makes sure the catalog never lists the core shell/system packages that exist on a real Windows 11 PC.
4. **Preview first, then ask.** A removal shows every package (name, safety label, version) and says plainly that CorePilot cannot undo it. Nothing is removed without `-Approved` from a confirmed question.
5. **Record before removing.** The full package name, family name and version are saved to `%LOCALAPPDATA%\CorePilot\apps\<id>.json` before anything is removed, and an entry goes to `history.jsonl`.
6. **Verify after.** The package list is read again; the result is `Removed` only if no package of that name is left. A partial result is reported as failed, never as success.
7. **No undo promise.** Removing a Store app cannot be rolled back by writing a value, so CorePilot does not claim it can. The record keeps the package family name so the app can be installed again from the Microsoft Store (`ms-windows-store://pdp/?PFN=<family>`); the CLI prints that hint.

## Limits (stated, not hidden)

- Current user only. The app can come back for new users or after a Windows feature update.
- Removing an app that other apps depend on can fail; the Windows message is shown.
- App data of the removed app is deleted by Windows together with the app.

## Pieces

| Piece | File |
|---|---|
| Catalog (id, package, safety, English product name) | `Data/Apps.json`, descriptions in `Locales/*.json` as `AppDesc.<id>` |
| Provider (list + remove), swappable for tests | `Src/Apps.ps1` |
| Status, remove engine, records | `Src/Apps.ps1` |
| CLI: `-App <ids|wildcards>` (list/preview), `-App ... -Remove [-AllowUnsafe] [-Yes]` | `Src/Cli.ps1`, `CorePilot.ps1` |
| Window: an "Apps" view (Settings / Apps switch, installed apps only, three safety groups, no quick select, no undo button, question names every app, second question for Unsafe) | `Src/GuiModel.ps1` (`Get-CpGuiAppRows`, `Invoke-CpGuiAppOperation`), `Src/Gui.ps1` (`Switch-CpGuiMode`, `Invoke-CpGuiRemoveSelected`), `Gui/MainWindow.xaml` |

## Not in this step

winget/Win32 uninstall, provisioned (all users) removal, restore point, reinstall button.
