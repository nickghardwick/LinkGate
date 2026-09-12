# LinkGate repository guidance

LinkGate is a native macOS URL handler. It receives external HTTP and HTTPS
links, applies any explicit routing rule, and otherwise presents a browser
picker. It opens the incoming URL in the chosen installed application.

## Build and verification

Use the native Apple toolchain: Swift, AppKit, SwiftUI, Foundation, XCTest, and
Xcode. The Xcode project defines the supported macOS deployment target.

Run these commands from the repository root:

```bash
make build
make test
make verify
```

`make verify` is the full local check. Keep generated build and release output
out of version control.

## Implementation constraints

- Use supported macOS URL-handling and launch APIs. Explicitly target the
  selected browser so LinkGate does not receive its own outgoing link.
- Keep URL reception, routing decisions, browser discovery and launch, picker
  presentation, and settings responsibilities separate.
- Preserve the incoming URL when opening it. Do not rewrite its query,
  fragment, percent encoding, or other case-sensitive components.
- Discover eligible installed browsers rather than maintaining a fixed list.
  Exclude LinkGate itself and handle unavailable browsers gracefully.
- Keep the picker keyboard accessible: arrows, Return or Enter, Escape, and
  pointer selection. AppKit owns panel focus and lifecycle behavior.
- Use `UserDefaults` for lightweight local preferences. Avoid unnecessary
  runtime dependencies and unrelated infrastructure.
- Cover routing, browser filtering, URL preservation, settings, cancellation,
  and failure paths with focused tests. Do not weaken existing assertions to
  accommodate a change.

Keep changes scoped to the requested behavior. Run `make verify` and
`git diff --check` before reporting a change complete.
