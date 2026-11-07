# Roadmap

Reference for feature parity: raphire/win11debloat (about 100 settings in 12 categories, about 160 removable apps, GUI, CLI, silent mode, Sysprep). CorePilot does not copy it; each item below is designed and verified on its own.

| Phase | Content | State |
|---|---|---|
| 1 | Skeleton, change engine (preview, record original, apply, verify, rollback, undo), 20 HKCU tweaks, CLI, tr/en, tests | done (real registry writer not yet exercised on the real registry) |
| 2 | 30 more per-user tweaks (now 50 in 10 categories), detection of applied state for all (the default list view) | done. Left for later: classic context menu (needs default-value write + key deletion in the engine), choice-style settings such as search box modes / Start layout (need a "one of several values" model), widgets button (protected on newer builds, test first) |
| 3 | WPF window in the style of Win11Debloat: category cards in three balanced columns, search, check boxes, tags (Applied / risk / unavailable), tooltip with description and each registry value (now -> new), low-risk quick select, apply/undo with a confirmation that names every feature, history panel, tr/en switch, dark/light follows Windows, `CorePilot.cmd` launcher without a lingering console (`conhost --headless`), start-up errors shown in a message box and a log | done (real click on Apply with the real dialog not exercised yet). Left for later: dark scrollbars, window size/position memory, export/import of a selection (phase 6) |
| 4 | Admin-level features (HKLM, policies, services, scheduled tasks): telemetry, Windows Update behavior, Copilot/Recall policies, BitLocker auto-encryption, restore point before changes. Each with its own warning and separate confirmation | planned, needs user approval of the design |
| 5 | App removal (Appx and winget) with safe / optional / unsafe labels and an extra confirmation for unsafe ones | steps 1-2 done: 49 listed Store apps, current user, command line (`-App`, `-Remove`, `-AllowUnsafe`) and an "Apps" view in the window (installed apps only, three safety groups, question that names every app, second question for Unsafe), design in [APPS-DESIGN.md](APPS-DESIGN.md); no real removal run yet. Left: real trial with one throwaway app, winget/Win32 uninstall, all-users removal (admin) |
| 6 | Export/import of a selection, silent mode with a config file, other user / Sysprep (default profile), more languages, script signing, packaging | planned |

Open items: trademark check for the name "CorePilot"; whether to publish (default: local only); Pester 5 from PSGallery (needs approval, Pester 3.4 works today).
