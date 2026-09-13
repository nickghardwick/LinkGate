# LinkGate release tooling

`make release` is the existing Step 6 workflow. It creates the signed,
notarized, stapled DMG, checksum, and provenance manifest in the ignored
`dist/` directory. The current `0.1.3 (5)` output is validation evidence only;
it is not a publishable Step 7 release.

## Publication foundation setup

Step 7B adds only offline publication foundations. Set up the repository-scoped
Python environment explicitly:

```bash
./scripts/release/setup-publish-env.sh
make publish-beta-tests
```

The environment installs the exact dependency pin in
`requirements-publish.txt`. The virtual environment is `.venv/publish/` and
is ignored. Normal verification never installs or updates packages.

Publication constants are kept in
`scripts/release/publish-config.json`. The file currently contains deliberately
invalid placeholders for the future GitHub repository and Sparkle public key;
foundation code rejects those values. No credentials or private keys belong in
the repository.

Future public release notes use the tracked convention
`release-notes/<MARKETING_VERSION>.md`. A release-note file must be committed
before the matching Step 6 `make release`. No release-note file is created by
the tooling. The full `make publish-beta` command consumes only a fresh Step 6
release with committed versioned notes.

The Markdown renderer produces deterministic static HTML with raw HTML
disabled and no external CSS or JavaScript. The appcast and content staging
code uses structured XML with the Sparkle namespace and is exercised with fake
signatures in offline tests; it does not create public feed history.

## Read-only publication preflight

After the environment setup above, `make publish-beta-check` runs the
non-mutating readiness check. It validates the Step 6 manifest and artifacts,
repository state, Xcode metadata, release-note source, local tools, the
configured Sparkle tool, and—once the repository is configured—read-only GitHub
and appcast state. It may make read-only HTTPS or `gh` calls when configuration
allows them.

Exit status `0` means ready. Exit status `2` means blocked and prints the
blocking categories and reasons. The check does not create refs or releases,
write Pages, sign archives, install dependencies, rebuild the app, or modify
`dist/`.

The committed configuration intentionally remains unresolved until the
operator creates the real repository and establishes the Sparkle identity.
The current `0.1.3 (5)` artifact also remains validation evidence only because
its source commit has no committed versioned release notes.

The staging core used by later pipeline composition consumes a successful
preflight, creates one unsigned annotated version tag, pushes that tag
explicitly, and creates a GitHub draft prerelease. It uploads the three exact
Step 6 files plus a generated publication manifest, then downloads every draft
asset and compares its bytes with the local source. The publication manifest is
written in a temporary ignored workspace outside `dist/` and does not inventory
itself.

If draft staging fails before public publication, cleanup deletes only tags and
the draft release whose identity was established by that invocation. Changed or
uncertain identities stop cleanup and report manual recovery. Step 6 artifacts
are never rewritten.

Sparkle tool provenance

Sparkle 2.9.6 `sign_update` does not provide a release-version interface:
`--version` exits with a usage error, while `-h` and `--help` print options but
no version. The committed publication configuration therefore pins the
official `Sparkle-2.9.6.tar.xz` release URL and digest, the expected
`bin/sign_update` path, and the extracted binary digest. After obtaining and
extracting that official archive locally, set:

```bash
export LINKGATE_SPARKLE_DIR=/path/to/extracted/Sparkle-2.9.6
```

`make publish-beta-check` hashes `$LINKGATE_SPARKLE_DIR/bin/sign_update` and
accepts it only when it matches the pinned binary digest. It does not download,
extract, execute, or sign with the tool during preflight. The Sparkle archive
and binary are not vendored in this repository.

## Content and Pages staging

Step 7E prepares publication content only after Step 7D has produced a
byte-verified draft. The verified Sparkle 2.9.6 `sign_update --verify` command
checks the archive using the Keychain identity; a separate OpenSSL Ed25519
verification binds the same signature to the configured public key. The
configured base64 value is decoded to exactly 32 raw bytes, wrapped in the
RFC 8410 SubjectPublicKeyInfo structure for Ed25519 OID `1.3.101.112`, and
passed to OpenSSL as a temporary PEM public key. The DMG is hashed before and
after signing and must remain unchanged. LinkGate never passes the private key
on a command line or exports it from the Keychain.

The committed Markdown source is rendered to
`updates/releases/<MARKETING_VERSION>.html` using the static renderer. A typed
Sparkle feed item is then merged into a validated `updates/appcast.xml`; an
absent feed creates the first item, while an existing feed keeps its historical
items and ordering. The appcast points to the exact versioned GitHub Release
DMG URL and uses the single Step 7D publication timestamp.

Pages uses a dedicated `gh-pages` branch configured in GitHub as “Deploy from a
branch” at the repository root. Setup creates one empty orphan commit with
subject `Bootstrap GitHub Pages` so the Pages source can be configured before
the first release. The first publication stages its update as a child of that
commit; later publications continue from the existing feed history. A
`.nojekyll` infrastructure file, if present, is preserved. Each local
publication commit contains only `updates/appcast.xml` and the new versioned
release-note page, with subject `Publish LinkGate <version> update feed`. The
staging component itself does not push Pages; `make publish-beta` performs the
final fast-forward push only after the GitHub prerelease is public.

## Full beta publication

After one-time setup is complete, the operator sequence is:

```bash
git commit   # includes the version and release-notes/<version>.md
make release
make publish-beta-check
make publish-beta
```

`make release` is the only command that creates the canonical Step 6 DMG. The
publication command never rebuilds, re-signs, notarizes, staples, or repackages
that artifact. It stages the exact tag, draft prerelease, four verified assets,
Sparkle content, and a fast-forward `gh-pages` commit. It then publishes the
prerelease, verifies the public DMG, appcast, and release-note URLs anonymously,
and retains evidence under `.scratch/publication-evidence/<version>/`.

Published beta releases and their assets are immutable. Corrections require a
new marketing version, a greater build number, new committed release notes, and
a fresh `make release`.

Publication outcomes use stable exit codes:

```text
0  PUBLISHED
2  BLOCKED_PREFLIGHT
3  ROLLED_BACK
4  INCOMPLETE_PUBLICATION
5  MANUAL_RECOVERY_REQUIRED
70 INTERNAL_ERROR
```

`ROLLED_BACK` means all invocation-owned pre-publication state was removed.
`INCOMPLETE_PUBLICATION` means the GitHub release is already public and is
retained for manual follow-up. `MANUAL_RECOVERY_REQUIRED` means ownership or
cleanup could not be established safely. The command never resumes a failed
attempt.
