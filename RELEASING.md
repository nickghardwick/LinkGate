# LinkGate release tooling

`make release` is the existing Step 6 workflow. It creates the signed,
notarized, stapled DMG, checksum, and provenance manifest in the ignored
`dist/` directory. The artifact is publishable only when its source is committed
with matching versioned release notes and passes publication preflight.

## Publication foundation setup

Step 7B adds only offline publication foundations. Set up the repository-scoped
Python environment explicitly:

```bash
./scripts/release/setup-publish-env.sh
. ./scripts/release/activate-publish-env.sh
make publish-beta-tests
```

The environment installs the exact dependency pin in
`requirements-publish.txt` and provisions the pinned Sparkle 2.9.6
`sign_update` binary. The virtual environment is `.venv/publish/`; the Sparkle
tool is `.venv/publish-tools/sparkle-2.9.6/`; both are ignored. Setup verifies
the official archive SHA-256 before extracting it, then verifies the extracted
tool SHA-256. Activation verifies the installed tool again, exports
`LINKGATE_SPARKLE_DIR`, and prepends the verified Sparkle and Python bins to
`PATH`. Normal verification never installs, updates, or downloads packages.

Publication constants are kept in
`scripts/release/publish-config.json`. The canonical repository and production
Sparkle public key are configured there. No credentials or private keys belong
in the repository.

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

A publishable release must use a fresh Step 6 artifact from the source commit
containing its matching versioned release notes.

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
`bin/sign_update` path, and the extracted binary digest. Provision and expose
that exact local tool with:

```bash
./scripts/release/setup-publish-env.sh
. ./scripts/release/activate-publish-env.sh
```

`make publish-beta-check` hashes `$LINKGATE_SPARKLE_DIR/bin/sign_update` and
accepts it only when it matches the pinned binary digest. It does not download,
extract, execute, or sign with the tool during preflight. The Sparkle archive
and binary are not vendored in this repository.

The preflight also runs a deterministic Ed25519 verification probe through the
selected OpenSSL executable. This is a capability check rather than a pathname
check; Apple’s `/usr/bin/openssl` LibreSSL build is rejected because it cannot
load Ed25519 public keys. Install or expose a compatible OpenSSL 3.x executable
in `PATH` before preflight. The same validated executable is carried through
Sparkle staging and final public-resource verification.

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

## Production Sparkle identity

The production Sparkle Ed25519 private key is stored in the macOS Keychain
under the LinkGate account. The matching public key is committed in the
publication configuration. Maintain an additional secure backup created with
Sparkle's `generate_keys -x` export workflow outside the repository. Do not
print, commit, or pass the private key on a command line.

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

For an already-public immutable beta, run the read-only retrospective check
with an explicit version, for example:

```bash
VERSION=0.1.4 make verify-published-beta
```

It verifies the public release, assets, appcast, release notes, Pages commit,
official Sparkle verification, and independent Ed25519 verification. It does
not modify GitHub, tags, releases, Pages, or `dist/`; it writes only a local
follow-up record under `.scratch/publication-evidence/<version>/`.
