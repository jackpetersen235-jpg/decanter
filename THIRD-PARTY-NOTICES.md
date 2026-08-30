# Third-party notices

Decanter downloads and runs a Windows compatibility engine on the user's behalf (the setup
wizard's engine install, see `docs/GAMING-STACK.md`). That engine is a third-party payload —
**downloaded at first run, not bundled inside the Decanter.app you ship** — but Decanter installs,
configures, and launches it as part of normal operation, and this file exists to attribute what it
installs. If you sell Decanter, get real legal advice on this before shipping — this file is
written from what's verifiably true about the packages involved, not as a legal opinion.

Two mitigating facts, already noted in `COMMERCIAL-READINESS.md`: the engine is **downloaded, not
bundled** in the app itself, and Wine is invoked as a separate executable (`Process`/`Shell.run`)
rather than linked into Decanter's own binary. Both weigh in Decanter's favor, but neither removes
the attribution obligation for software actually distributed to the user via the app's own
first-run flow.

## What's installed

| Component | License | Confirmed how |
|---|---|---|
| Wine | LGPL 2.1 | Well-known upstream license (winehq.org) |
| DXVK | zlib | Well-known upstream license (github.com/doitsujin/dxvk) |
| DXMT | MIT | `LICENSE` file shipped inside the actual downloaded payload — read directly, copyright Feifan He, 2023 |
| gnutls | LGPL 2.1 | Well-known upstream license (part of the base bundle's ~94 support dylibs) |
| FreeType | FTL, or GPL 2 (dual-licensed, distributor's choice) | Well-known upstream license |
| MoltenVK | Apache 2.0 | Well-known upstream license (github.com/KhronosGroup/MoltenVK) |
| SDL2 | zlib | Well-known upstream license (libsdl.org) |
| ~90 further support dylibs | Mixed | Bundled inside the base release asset (`frankea/Whisky`'s `Libraries.tar.gz`) — not individually audited here; a full pass should enumerate `Wine/Libraries/**/*.dylib` and match each to its source project before shipping |

The base bundle (`WineInstaller.releaseURL`) and the msync overlay (`WineInstaller.msyncEngineURL`)
are both third-party GitHub release assets — see `COMMERCIAL-READINESS.md` item 1 for the separate
risk that raises (no mirror, until recently no checksum — see the SHA-256 pinning commit).

## What this file does NOT cover

- **Decanter's own source code's license** — proprietary, all rights reserved. See the top-level
  `LICENSE` file.
- **A full per-dylib audit** of the ~90 unlisted support libraries in the base bundle. The table
  above lists the well-known, major components; a complete pass would need to enumerate every
  `.dylib` under the installed `Wine/Libraries/` tree and identify each one's actual license,
  which no one has done yet for this project.
- **Steam itself** — Decanter installs Valve's Steam client into a Wine prefix on the user's
  behalf; Steam's own EULA/terms are between the user and Valve, not something Decanter
  redistributes or needs to attribute here.

## In-app acknowledgements

Not yet built. `COMMERCIAL-READINESS.md` recommends an in-app "Acknowledgements" screen surfacing
this table (or something equivalent) — that's a small SwiftUI view reading this file's content (or
a structured version of it), not built as part of this pass. Worth doing before a public release;
low effort relative to the risk it closes.
