# LinkGate

LinkGate is a native macOS utility that receives ordinary HTTP and HTTPS links,
shows a lightweight picker of eligible installed applications, and opens the
unchanged link in the application the user selects. Each received link is
handled in arrival order. Cancelling the picker discards only the current link.

LinkGate can also store explicit routing rules in Settings. A matching URL
prefix, exact domain, or domain-plus-subdomains rule opens the link directly in
its configured installed browser. When no rule matches, or the configured
browser is unavailable, LinkGate uses the normal chooser.
Settings also lets you hide individual discovered browsers from the chooser
without losing their saved order. A rule targeting a hidden browser falls back
to the chooser until that browser is enabled again.

## Prerequisites

- macOS with Xcode installed.
- Xcode command-line tools selected (`xcode-select -p`).
- The app targets macOS 14.0. The XCTest target has a macOS 26.5 deployment
  target, so local tests require a compatible macOS/Xcode environment.
  Phase 02 was verified with Xcode 26.6.

The project has no third-party dependencies or package-manager setup.

## Development commands

Run these commands from the repository root:

```bash
make build
make run
make test
make verify
```

`make build` compiles the Debug app bundle. Launching or opening that built
bundle lets macOS perform normal Launch Services registration if needed. `make
run` builds and opens the Debug app for local testing.
`make test` runs the native XCTest target. `make verify` runs the build, XCTest,
and deterministic release checks; it is the authoritative verification path.

The repository also contains the beta publication pipeline. Set it up with
`./scripts/release/setup-publish-env.sh`, then run `make publish-beta-tests`.
See [`RELEASING.md`](RELEASING.md) for the public release-tooling setup and
publication sequence. `make publish-beta-check` is the read-only readiness
check, while `make publish-beta` is the explicit public publication command.
The current `0.1.3 (5)` release remains validation evidence only; publication
also requires resolved infrastructure and a fresh publishable Step 6 release.

Build output is written to `build/DerivedData/`. It is generated locally and
is excluded from version control.

## Phase 02 manual Launch Services validation

This procedure changes the default web-link handler temporarily. Record the
current browser first and restore it before finishing.

1. Run `make build`, then inspect the built bundle:

   ```bash
   plutil -p build/DerivedData/Build/Products/Debug/LinkGate.app/Contents/Info.plist
   ```

   Confirm the bundle identifier is `com.nickghardwick.LinkGate`, its Viewer
   URL type contains `http` and `https`, and its document types include both
   `public.html` and `public.xhtml`.
2. In **System Settings → Desktop & Dock → Default web browser**, record the
   existing browser. Select **LinkGate** temporarily. If it is missing, rebuild,
   launch or open the current built bundle once, then reopen System Settings.
3. Quit LinkGate, then open an HTTP or HTTPS URL from another application. A
   centered, key chooser should appear and show the URL host, full URL, icons,
   and names of eligible applications. LinkGate must not be an option.
4. Choose two different eligible applications in separate runs. Use a URL with
   a query, fragment, percent encoding, and Unicode, and verify each destination
   receives the same URL representation supported by that application.
5. Verify pointer selection; arrow-key focus movement; Return or Enter to
   select the focused application; and Escape to cancel. A cancelled URL must
   not open an application.
6. While the first chooser is visible, deliver two URLs. The first must remain
   visible; after selecting or cancelling it, the second must appear next.
7. Restore the previously recorded default browser in System Settings.

The picker displays Launch Services URL handlers in the order supplied by
macOS. It intentionally does not maintain a browser allowlist, so applications
other than conventional web browsers can appear when macOS registers them as
eligible handlers.

Launch Services may retain stale development registrations. The current build
is the bundle under `build/DerivedData/Build/Products/Debug/LinkGate.app`; make
sure that is the running bundle before interpreting a result. If the chooser
does not reflect the current build, rebuild, relaunch that bundle, and repeat
the procedure. Do not alter installed applications or system files to force a
launch failure. Automated coverage verifies the safe failure, one-candidate,
and cancellation-during-opening paths.

## Phase 03 routing-rule validation

Open LinkGate directly to show Settings, or choose **Settings…** from its menu-bar item. Each rule contains
only a match type, pattern, and browser:

- **Exact Domain** matches only the named host.
- **Domain + Subdomains** matches the named host and dot-delimited subdomains.
- **URL Prefix** matches a fragment-free normalized absolute URL prefix.

Domain comparison ignores hostname case and equivalent trailing dots. Prefix
comparison also ignores scheme/hostname case and fragments, while paths,
queries, percent encoding, ports, and slash structure remain literal. When
rules overlap, the fixed order is URL Prefix, Exact Domain, then Domain +
Subdomains; the longest matching prefix or domain family wins within its type.

For a repeatable manual check, first follow Phase 02 steps 1–3 and record the
current default browser. With at least two real browsers installed:

1. With no rules, open a complex URL and confirm the existing chooser,
   keyboard focus, Escape, and exact URL behavior.
2. Add an Exact Domain rule and confirm the root routes directly while a
   subdomain shows the chooser.
3. Edit it to Domain + Subdomains and confirm both root and subdomain route.
4. Add an overlapping URL Prefix rule for another browser and confirm the
   prefix wins while another path follows the less-specific rule.
5. Quit and relaunch LinkGate, then confirm the rules and routing persist.
6. Make one target unavailable only through a safe reversible method, confirm
   chooser fallback, and restore it. Skip this step rather than altering an
   installed application or system file unsafely.
7. Exercise add, edit, conflicting duplicate validation, and delete in
   Settings. Manual chooser choices must not create or update rules.
8. Repeat Escape, complex-URL, rapid-arrival, identical-URL, and queued-focus
   checks from Phase 02.
9. Delete test rules and restore the recorded default browser.


## Everyday use and Phase 04 verification

Opening LinkGate directly shows one reusable Settings window. Incoming HTTP/HTTPS
links use the existing routing rules or chooser without opening Settings.
LinkGate stays running after its last window closes and behaves as a background
utility without a persistent Dock entry. Its menu-bar item provides **Settings…**
and **Quit LinkGate**. Closing Settings or cancelling the chooser leaves LinkGate
running; explicit Quit discards any pending links. Queues and chooser state are
never saved or restored after relaunch. Automatic routes do not show LinkGate
windows or request activation; only Settings and chooser/error interactions
request focus. macOS Launch Services can briefly activate its URL handler before
the destination browser even without an activation request from LinkGate. This
native handoff is an accepted platform limitation; the app stays accessory.

Settings shows detected web-link handlers with their names and icons, identifies
unavailable rule targets, and exposes the existing rule editor. Its browser list
lets you show or hide browsers in the chooser and reorder them. Rules retain
their targets when a browser is removed.

The default-browser section checks both HTTP and HTTPS. **Make LinkGate Default**
requests the change through macOS and may require system confirmation. If only
one scheme changes, Settings reflects that partial status; it never reports full
success based on one scheme alone.

The chooser supports mouse selection, arrow keys, Return/keypad Enter, Escape,
and numbered shortcuts for the first nine choices. A failed browser
launch refreshes available choices for the same link. If no handler remains,
Close dismisses that link and advances the queue. Selection cannot be cancelled
after launching begins.

### Stored configuration

Routing rules remain under `LinkGate.routingRules` in the application's
UserDefaults domain. Phase 03 arrays load without a write. The first successful
edit migrates to a version 1 envelope, preserving original bytes at
`LinkGate.routingRules.legacyBackup`. Valid rules retain stable IDs and order;
unreadable records are preserved rather than silently discarded during edits.
An unsupported version or unreadable root disables configuration changes and
shows a safe warning while links can still use the chooser.

Before rolling back to a Phase 03 binary, quit LinkGate and retain a copy of the
current versioned data. Phase 03 cannot read the new envelope. Restoring the
legacy backup to the original key restores the pre-migration rules only; later
Phase 04 edits are absent from that backup. Do not delete either value simply
to clear a warning.

### Acceptance checks

Run `make verify`, `git diff --check`, and the established static scan:

```bash
semgrep scan --config auto --no-git-ignore LinkGate LinkGateTests
```

For a desktop smoke pass, exercise manual cold launch and reopen, URL cold launch,
rule routing, chooser mouse/keyboard/cancellation, rapid and identical deliveries,
and Settings edits across quit/relaunch. Check focus and placement after changing
Spaces/displays, hidden-app delivery, and sleep/wake where hardware permits.
Inspect browser/control names with VoiceOver. Use automated injected discovery
and opening failures rather than modifying installed browsers. Record original
default-handler state before any consented test change and restore it afterward.

## Phase 05 lifecycle verification

The URL handler and selection coordinator are constructed before AppKit can
deliver delegate callbacks. Cold and warm arrivals share that same path; launch
notifications install the menu-bar item without replaying URLs or resetting the
queue. The chooser remains an AppKit floating panel that moves to the active
Space and uses the pointer's display when a new presentation begins.

Manual lifecycle verification should include HTTP/HTTPS cold and warm delivery,
automatic routing focus, selection/FIFO/failure recovery, menu/Settings/quit,
sleep/wake, Spaces/displays, VoiceOver, and enlarged text. Launch-at-login and
session restoration remain out of scope.
