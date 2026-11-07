# CorePilot

Safe, reversible Windows 11 tweaks for the current user, written in PowerShell. No installer, no `.exe`, nothing is downloaded or run from the internet.

> Türkçe için: [README.tr.md](README.tr.md)

CorePilot is **inspired by [Win11Debloat](https://github.com/raphire/win11debloat)** (MIT). It aims for a similar set of features, with its own code, data and safety model. No code or data files were copied from that project.

## Status: Phase 3

50 per-user (HKCU) tweaks in ten categories (Privacy, Taskbar, File Explorer, Start, Search, Appearance, Multitasking, Gaming, AI, Input), a window (WPF, category cards) and a command-line tool, English and Turkish texts, and 100 automated tests. See [docs/ROADMAP.md](docs/ROADMAP.md) for what comes next (GUI, admin-level features, app removal, export/import, ...).

## Use

Windows PowerShell 5.1 (included with Windows 11) is enough. No administrator rights are needed for the current features.

**Window:** double-click `CorePilot.cmd` (or run `.\CorePilot.ps1 -Gui`). Settings are grouped in cards by category. Tick what you want, hover a setting to see its description and every registry value it touches (now -> new), then press **Apply selected**. A question lists every feature that will change before anything is written, including ticked ones a search has hidden. **Undo selected** restores the saved originals. **Quick select** ticks only low-risk settings that are not applied yet. Nothing is changed by opening the window. If Windows blocks the script because it was downloaded, run `Unblock-File` on the files once.

`CorePilot.cmd` is three readable lines: it starts `powershell.exe` through `conhost.exe --headless` (a Windows component), so no console window is left open behind the app. If the window cannot start, a message box explains why and `%LOCALAPPDATA%\CorePilot\gui-error.log` is written. Security software sometimes dislikes hidden-PowerShell launchers; if yours removes or blocks `CorePilot.cmd`, start the window with `powershell -STA -File CorePilot.ps1 -Gui` instead (a console stays open then).

**Command line:**

```powershell
.\CorePilot.ps1                                      # list all features and whether they are applied (read-only)
.\CorePilot.ps1 -Feature explorer.show-file-extensions   # preview: what would change (read-only)
.\CorePilot.ps1 -Feature 'privacy.*' -Apply          # preview, ask, then apply
.\CorePilot.ps1 -Feature 'privacy.*' -Apply -Yes     # same, without the question
.\CorePilot.ps1 -Feature 'privacy.*' -Undo           # put the saved original values back
.\CorePilot.ps1 -History                             # what CorePilot changed, and any interrupted runs
.\CorePilot.ps1 -Language tr-TR                      # tr-TR or en-US (default: follows Windows)
```

`-Feature` accepts several ids (comma-separated) and `*` wildcards. `-WhatIf` turns `-Apply` into a preview.
If scripts are blocked, run once per window: `Set-ExecutionPolicy -Scope Process Bypass`.

## How it keeps you safe

- Reading and previewing never write anything.
- Before a change, the original value (or "did not exist") is saved to `%LOCALAPPDATA%\CorePilot\records`.
- After writing, every value is read back and checked. If anything is wrong, all values of that feature are rolled back.
- `-Undo` restores exactly what was saved. A saved record is only used if it describes this feature's own registry values.
- Only `HKEY_CURRENT_USER` is touched, only the values listed in `Data/Features.json`, only DWord and String types. Anything else is refused.
- An interrupted run is detected and shown in the list and in `-History`; `-Undo` finishes the job.
- Features that do not exist on your Windows build are shown as unavailable and are never written.

## Not verified yet

- The real registry writer (`Set`/`Remove` in `Src/Registry.ps1`) was exercised once on a throwaway `HKCU\Software\CorePilotTest-*` key (DWord/String write, overwrite, kind change, negative values, remove, missing key/value, rejected kinds; the key was deleted afterwards). It was then used on real tweak values once: 22 features were applied from the window (every value read back and verified) and undone with `-Undo`; all 31 registry values returned to the saved originals and the overall status counts matched the state before. Automated write-path tests still use an in-memory fake. Read access has been checked on a real Windows 11 build 26200 PC: the value names of 35 of the 50 features exist there. For the other 15 at least one value is simply absent (Windows default), which neither confirms nor refutes the name.
- The window has been opened and driven on a real PC read-only (statuses, filtering, check boxes, language switch, history panel, screenshots), and its apply/undo flow is tested through the same code paths with a fake registry. A real mouse click on Apply with the real confirmation dialog worked once (22 features); the real Undo button click has not been exercised (undo was run through the command line). Scrollbars keep the default light Windows look in dark mode.
- Whether each tweak takes effect immediately, after restarting Explorer, or after signing out has not been verified on a real apply. The "restart Explorer" / "sign out" hints are best guesses.
- The classic (Windows 10 style) context menu is not included yet: it needs a default-value write and deleting a registry key on undo, which the engine does not support.
- Some tweaks may be ignored or reset by newer Windows builds. Check the result in Windows after applying.

## Develop

```powershell
Import-Module Pester   # Pester 3.4 (built into Windows) is enough
Invoke-Pester -Path .\Tests
```

Rules: see [CLAUDE.md](CLAUDE.md). Short version: every `.ps1` stays ASCII-only, texts live in `Locales/*.json`, tests never touch the real registry or the real data folder.

## License

MIT, see [LICENSE](LICENSE). Use at your own risk.
