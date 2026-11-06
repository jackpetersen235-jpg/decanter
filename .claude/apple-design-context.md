# Apple Design Context

Read by the `hig-*` skills so they don't re-ask. Decanter only — the other Apple apps in
`~/coding` (Balance, Phosphor, Penumbra, Cartridge) have different platforms and design systems.

## Product
- **Name**: Decanter
- **Description**: One-button setup and launcher for running Windows Steam games on Apple-silicon
  Macs through Wine "bottles".
- **Category**: Games utility (`LSApplicationCategoryType` = `public.app-category.games`)
- **Stage**: Released **free and open source (GPL-3.0)** on a public GitHub repo, 2026-11-05;
  v1.1 is the current release and the goal is wide public use with bug reports coming back.
  (Until then it was headed for sale — see `docs/COMMERCIAL-READINESS.md`.) Shipped as an
  ad-hoc-signed zip (`Scripts/package-for-friend.sh`), not notarized. Judge every HIG question
  as if the user is a stranger on an unfamiliar Mac.

## Platforms
| Platform | Supported | Min OS | Notes |
|----------|-----------|--------|-------|
| iOS      | No        |        |       |
| iPadOS   | No        |        |       |
| macOS    | Yes       | 14.0   | Apple silicon only (needs Rosetta 2). Built and tested on macOS 26 Tahoe, M5 MacBook Air. |
| tvOS     | No        |        |       |
| watchOS  | No        |        |       |
| visionOS | No        |        |       |

Outside the Mac App Store by necessity: it runs Wine and manages other processes, so it is not
sandboxed.

## Technology
- **UI Framework**: SwiftUI, with AppKit where SwiftUI can't reach (clear window backing,
  `NSAlert` quit guard, panels). SwiftPM only — no `.xcodeproj`, Command Line Tools build.
- **Architecture**: Single main window (sidebar of bottles + detail pane with Overview /
  Configuration / Programs tabs) plus a Settings window; window tabbing is off. Sheets for New
  Bottle, Setup (gear), Console and Uninstall. The Setup Assistant replaces the main window's
  content (with "Not Now" when opened from the menu).
- **Menu bar** (updated 2026-11-02): File — New Bottle… ⌘N, Import CrossOver Bottles · View —
  Overview/Configuration/Programs ⌘1–⌘3, Rescan Wine Installations ⇧⌘R, Setup Assistant… ·
  Bottle — Launch ‹bottle› ⌘↩, Quit Steam…, Open C: Drive, Apply Settings to Prefix, both deletes ·
  Help — Export Diagnostics. **Dock menu:** Launch ‹bottle› per bottle.
- **Apple Technologies**: Liquid Glass (`.glass` button styles, clear window), macOS Game Mode
  (via a games-category helper app), Metal (GPU keep-alive helper), Rosetta 2, CryptoKit
  (download checksums), UniformTypeIdentifiers.
- **Blocked by the toolchain** (not by design): App Shortcuts/Siri/Spotlight need
  `appintentsmetadataprocessor` (full Xcode only); widgets need an extension SwiftPM doesn't build
  and real signing. Revisit once Xcode's license is accepted and signing is real. Notifications
  are buildable today but were not chosen.

## Design System
- **Base**: Custom, three themes chosen in Settings, applied all-or-nothing:
  **Liquid Glass** (default; clear window over the desktop), **Frutiger Aero** (glossy 2006 style,
  painted sky, always light), **Standard** (plain macOS, no theming).
- **Brand Colors**: System accent in Liquid Glass and Standard. Aero tokens in
  `Theme/AeroTokens.swift`: lime `#4B7617`, aqua `#1972B1` (both darkened from period colours to
  pass contrast), ink `#172129`. Components must name a token, never a literal colour.
- **Typography**: System fonts and text styles; monospaced for the console.
- **Dark Mode**: Supported in Liquid Glass and Standard. Aero is light-only by design.
- **Dynamic Type**: N/A (macOS). Use text styles, not fixed sizes, for text.

## Accessibility
- **Target Level**: **Enhanced** (confirmed 2026-11-02).
  - VoiceOver: every control labelled; state that's only visual gets an accessibility value;
    decorative images hidden.
  - Full keyboard use: anything clickable is a `Button`, never `.onTapGesture`; sheets cancel
    with Esc; custom button styles draw their own focus ring (`aeroFocusRing`).
  - Contrast 4.5:1 for text in every theme AND both appearances. Never tint caption text with a
    system colour — `StatusNote` puts the colour on the symbol.
  - Reduce Motion and Reduce Transparency respected (themes flatten; nothing animates per event).
- **Key Considerations**: Liquid Glass puts text over the user's wallpaper, so contrast there is
  only as good as the scrim and the Text colour override (Settings ▸ Appearance). Rules and
  measurements: `CLAUDE.md` ▸ "HIG foundations pass (2026-11-02)".

## Conventions established by the 2026-11-02 HIG passes
Follow these in new UI; each has its reasoning in `CLAUDE.md` ▸ "HIG … pass".
- **Undo over confirmation** when the action is reversible (Delete Bottle (keep files), Delete
  key, ⌘Z). Confirm only what can't be undone (Delete Bottle & Files, Quit Steam).
- **Button words say what happens:** "Stop" kills a running task; "Cancel"/"Hide" only close.
  One name per action everywhere ("Apply Settings to Prefix"). "…" only when more input follows.
- **Capitalization:** title case for buttons and menu items, sentence case for toggles, pickers,
  section headings; proper names keep capitals.
- **Mutually exclusive options are a picker,** never toggles that switch each other off.
- **Every command is in the menu bar;** context menus and buttons supplement it. No menu shortcut
  that fires while typing (no ⌘⌫ for delete — the sidebar takes the Delete key instead).
- **Esc dismisses every sheet** without doing anything destructive.
- **A spinner means something is running** (`BottleSetupState`); one indicator per task; a bar
  reports progress through the whole task (`EngineDownloadProgress`).
- **Warnings and failures use `StatusNote`** — colour on the symbol, text readable.

## Users
- **Primary Persona**: A Mac gamer on Apple silicon who wants their Windows Steam library and has
  never heard of Wine. Non-technical; follows a READ ME at most.
- **Secondary Persona**: A technical helper (or Claude Code) setting it up for them —
  `docs/SETUP-WITH-CLAUDE.md`, `Scripts/doctor.sh`.
- **Key Use Cases**: first-run setup with one button (Rosetta → engine → bottle → Steam); make a
  bottle for an installed game from the detected list; press Play; quit Steam; tune a slow game.
  Short visits — Decanter is a launcher, the time is spent in the game.
- **Known Challenges**:
  - Cold Steam sign-in takes ~70 s, so Play must show progress and survive the user quitting
    Decanter mid-wait (quit guard).
  - Several bottles can share one Wine prefix; every setting and destructive action must say
    which bottles it really affects.
  - Ad-hoc signing means a Gatekeeper prompt on first open.
  - Kernel anti-cheat games cannot work under Wine on macOS; say so rather than imply a fix.
  - A bottle is saved before its Windows setup runs, so quitting mid-setup leaves an unfinished
    bottle; the UI says "Setup didn't finish" rather than spinning (nothing deletes it unasked).
  - The engine is two downloads (~317 + ~163 MB) shown as one progress bar.
- **Testing UI changes**: never against the real install. Use a copy of `build/Decanter.app` with
  its own bundle id and a scratch `DECANTER_HOME` (`CLAUDE.md` ▸ "HIG foundations pass").

## Open design decisions
Raised in the 2026-11-02 HIG patterns pass, waiting on Jack (details in `CLAUDE.md`):
- Restore the last-selected bottle at launch? Conflicts with the selection-only Steam warm-start.
- Retire the gear sheet (`SetupSheet`), which duplicates the Settings window?
- Point Help ▸ Decanter Help at a troubleshooting guide shipped inside the app?
- Let people hide the sidebar (layout pass)? Lost when `NavigationSplitView` was dropped for
  Liquid Glass; a hand-built toggle must also clear the floating traffic lights.
