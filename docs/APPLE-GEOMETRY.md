# Apple's macOS geometry — measured, not guessed

What makes a Mac app "look like Apple made it" on macOS 26, with every number's source. Gathered
2026-11-02 on this Mac (macOS **26.6.2**, build 25G83) for Decanter's Standard theme, but nothing here is
Decanter-specific.

**The headline finding:** Apple apps don't hand-tune these numbers per app. They fall out of the system
containers — `NavigationSplitView` (floating sidebar), the window toolbar (title, items), `Form(.grouped)`
and the stock controls. An app that lays out its own chrome has to reproduce every number below by hand,
and drifts. **Use the containers; reach for numbers only inside your own content.**

## Sources, in order of trust

1. **AppKit itself** — `NSFont.preferredFont(forTextStyle:)`, `NSControl.controlSize` fitting sizes and
   `NSOutlineView` source-list row heights, printed by a probe on this Mac. Exact.
2. **Pixel measurements** of System Settings and Notes, captured at 2× with `screencapture -o -l <id>`
   and scanned for brightness edges (2 px = 1 pt). ±0.5 pt. Corner radii fitted from edge offsets.
3. **WWDC25 "Get to know the new design system"** (session 356) and the HIG — the rules, few numbers.

## Window and toolbar

| | Value | Source |
|---|---|---|
| Window corner radius | **26 pt** | measured (edge offsets fit r = 26) |
| Toolbar height (title-bar row with a toolbar) | **52 pt** — content starts at y = 52 | measured |
| Traffic lights | 14 pt circles, centres at **y = 26**, x = 26 / 49 / 72 (23 pt pitch) | measured |
| Toolbar items / title | vertically centred on the **same 26 pt line** as the lights | measured |
| Toolbar control height | **36 pt** glass capsule (= `extraLarge` control) | measured + AppKit |
| First toolbar item after the sidebar | **8 pt** right of the sidebar's edge | measured |
| Without a toolbar | lights sit at y ≈ 16 in a ~32 pt strip — a *different*, sparser-looking window | measured (Decanter) |

## Sidebar (Tahoe's floating sidebar)

| | Value | Source |
|---|---|---|
| Inset from window edges (top, leading, bottom) | **8 pt** | measured, System Settings and Notes |
| Corner radius | **≈18 pt = 26 − 8** — concentric with the window | measured; the WWDC25 rule below |
| Width | ≈**215 pt** (System Settings) | measured |
| Row height, small / **medium (default)** / large | 24 / **32** / 40 pt | AppKit source-list `rowHeight`; 32 measured in both apps |
| Selection pill | inset **10 pt** from the sidebar's edges (starts 18 pt from the window); 32 pt tall | measured |
| Icon → text | icon at 24 pt from the window edge, text at ≈48 pt | measured (Notes) |
| Search field | 28 pt tall capsule, same insets as the pill | measured |

## Content

| | Value | Source |
|---|---|---|
| Margin from the sidebar, and from the window's trailing edge | **20 pt** | measured |
| Grouped box (Form section) corner radius | **12 pt** | measured (offsets fit r = 12 exactly) |
| Padding inside a grouped box; inset of its row separators | **10 pt** | measured |
| Top of content | directly under the 52 pt toolbar; scrolls under it | measured |

## Text styles (macOS — note these are NOT the iOS sizes)

`largeTitle` 26 · `title1` 22 · `title2` 17 · `title3` 15 · `headline` 13 **bold** · `body` 13 ·
`callout` 12 · `subheadline` 11 · `footnote` 10 · `caption1` 10 · `caption2` 10. System font 13, small 11.
(AppKit, this Mac.) Body is 13 pt on the Mac — a 17 pt "title2" header is already large.

## Control heights (push button, pop-up, segmented)

mini **16** · small **20** · regular **24** · large **28** · extraLarge **36** pt. Text fields and switches
report 24 pt at every size. (AppKit, this Mac.) On macOS, mini/small/medium controls are rounded
rectangles; **large and extra-large are capsules** (WWDC25).

## The rules behind the numbers (WWDC25 session 356, HIG)

- **Concentricity.** Three shape types: *fixed* (constant radius), *capsule* (radius = half the height),
  *concentric* (radius = parent's radius − the padding between them). Nested shapes must be concentric —
  the 26 → 8 → 18 sidebar is the rule in action; a box with padding *p* inside a 12 pt box gets 12 − *p*.
  Corners that "feel off" are almost always a nested shape that isn't.
- **Sidebars are inset and float** over content on macOS 26; content may extend behind them.
- **Bars hold few things.** Move secondary actions into a menu; group items by function and frequency;
  keep the primary action separate and prominent (a prominent text button on macOS); don't mix symbol
  and text buttons in one group.
- **Emphasis comes from grouping and layout, not colour.** Don't decorate with colour.
- **Optical alignment** — centre mathematically unless it looks off (glyphs with uneven weight), then
  nudge.
- **Consistent spacing** and a shared grid (HIG Layout); keep secondary information out of the way and
  let the content area own the window.

## How Decanter measured against this (before the 2026-11-02 rebuild)

| | Apple | Decanter (Standard) |
|---|---|---|
| Toolbar | 52 pt, title on the lights' line | none — custom header panel + divider |
| Traffic lights | y = 26 | y = 16 (no-toolbar window) |
| Sidebar | floating, 8 pt inset, 18 pt corners, ~215 pt | full height, square, 264 pt |
| Sidebar rows | 32 pt | ≈28 pt |
| Content margin | 20 pt | 16 pt + 6 pt GroupBox padding |
| Page title | window title in the toolbar | 30 pt icon + 17 pt bold title + 10 pt caption |

All six come from one cause: hand-built chrome. See CLAUDE.md ▸ "HIG geometry pass".

## SDK stamp — check this before anything else

macOS chooses an app's design from the **SDK version stamped in the binary** (`LC_BUILD_VERSION`'s
`sdk`), not from the code. Stamped below 26, the app runs in **compatibility mode**: no floating sidebar,
the compact toolbar (lights at y ≈ 18), old control metrics — whatever the SwiftUI asks for.

    otool -l <binary> | grep -A4 LC_BUILD_VERSION    # want: sdk 26.x or later

This bit Decanter on 2026-11-02: once Xcode's licence was accepted, `swift build` switched to Xcode's
build system, which stamped **sdk 14.0** (the deployment target) instead of the real SDK (27.2). The
Command Line Tools stamp the real one (26.5). Fix: link with
`-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$(xcrun --show-sdk-version)"` —
`Scripts/make_app.sh` does, and refuses to finish if the stamp is below 26. For comparison, System Settings
is stamped 26.6.1. **A screenshot of a mis-stamped build is a screenshot of the old design**: the first
capture of the NavigationSplitView rebuild showed a full-height square sidebar for exactly this reason.

## Reproducing the measurements

- AppKit probe: a ~40-line Swift script calling the APIs above (`swiftc` it; it needs
  `NSApplication.shared` before anything touches fonts or controls).
- Pixels: `screencapture -x -o -l <CGWindowID> out.png` captures a window even on another Space (list ids
  with `CGWindowListCopyWindowInfo`). Scan rows/columns for brightness steps > 3; fit corner radii from
  the edge offset *d* at depth *y* below the top: d = r − √(r² − (r − y)²).
- Nothing captures while the screen is locked, and a window can't be brought into a full-screen Space.
