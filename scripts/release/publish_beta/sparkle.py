from __future__ import annotations

import base64
import hashlib
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, Sequence

from .config import PublicationConfig
from .errors import FailureClass, PublicationError


class CommandRunner(Protocol):
    def run(self, args: Sequence[str], cwd: Path | None = None):
        ...


_SIGNATURE_OUTPUT = re.compile(
    r'^sparkle:edSignature="(?P<signature>[A-Za-z0-9+/]+={0,2})" length="(?P<length>[0-9]+)"$'
)
_PUBLIC_KEY_DER_PREFIX = bytes.fromhex("302a300506032b6570032100")
_OPENSSL_CAPABILITY_ARTIFACT = b"LinkGate Sparkle 2.9.6 interoperability fixture\n"
_OPENSSL_CAPABILITY_PUBLIC_KEY = "ilzG6yMvd8qfr6pk2O9wV5GT/BjOFfQ5e5+2bJNpoK4="
_OPENSSL_CAPABILITY_SIGNATURE = "FMrvQWb5U+/x/Pb9X9kji6h3b1NJwtfyGB0vljF7XQi/j7M/3Bmmfzf8cOE+lHdjhU7oS3z67qA2MylLL7x6Dg=="


@dataclass(frozen=True)
class SparkleSignature:
    ed_signature: str
    length: int


class SignatureVerifier(Protocol):
    def verify(self, archive: Path, signature: SparkleSignature, public_key: str) -> None:
        ...


def _ed25519_spki_der(raw_public_key: bytes) -> bytes:
    """Wrap Sparkle's raw key in the RFC 8410 Ed25519 SPKI structure.

    Sparkle stores SUPublicEDKey as exactly the 32-byte Ed25519 public key.
    OpenSSL's ``pkeyutl -pubin`` consumes a DER SubjectPublicKeyInfo whose
    AlgorithmIdentifier contains OID 1.3.101.112 and whose BIT STRING holds
    those same 32 bytes.  The fixed prefix encodes only that standard
    structure; the key bytes are appended without slicing or reinterpretation.
    """
    if len(raw_public_key) != 32:
        raise PublicationError(FailureClass.CONFIGURATION, "configured Sparkle public key has invalid length")
    return _PUBLIC_KEY_DER_PREFIX + raw_public_key


def _run_openssl_ed25519_verification(
    runner: CommandRunner,
    openssl: str,
    archive: Path,
    signature: bytes,
    raw_public_key: bytes,
) -> bool:
    with tempfile.TemporaryDirectory(prefix="linkgate-openssl-verify-") as directory:
        directory_path = Path(directory)
        public_key_path = directory_path / "public-key.pem"
        signature_path = directory_path / "signature.bin"
        der = _ed25519_spki_der(raw_public_key)
        public_key_path.write_text(
            "-----BEGIN PUBLIC KEY-----\n"
            + base64.b64encode(der).decode("ascii")
            + "\n-----END PUBLIC KEY-----\n",
            encoding="ascii",
        )
        signature_path.write_bytes(signature)
        try:
            result = runner.run(
                [
                    openssl,
                    "pkeyutl",
                    "-verify",
                    "-pubin",
                    "-inkey",
                    str(public_key_path),
                    "-rawin",
                    "-in",
                    str(archive),
                    "-sigfile",
                    str(signature_path),
                ]
            )
        except OSError:
            return False
    return result.returncode == 0


def verify_openssl_capability(runner: CommandRunner, openssl: str) -> None:
    """Require the selected executable to verify an Ed25519 signature."""
    try:
        public_key = base64.b64decode(_OPENSSL_CAPABILITY_PUBLIC_KEY, validate=True)
        signature = base64.b64decode(_OPENSSL_CAPABILITY_SIGNATURE, validate=True)
    except (ValueError, base64.binascii.Error) as error:
        raise PublicationError(FailureClass.TOOLING, "internal OpenSSL capability fixture is invalid") from error
    with tempfile.TemporaryDirectory(prefix="linkgate-openssl-capability-") as directory:
        archive = Path(directory) / "probe.bin"
        archive.write_bytes(_OPENSSL_CAPABILITY_ARTIFACT)
        if not _run_openssl_ed25519_verification(runner, openssl, archive, signature, public_key):
            raise PublicationError(FailureClass.TOOLING, "OpenSSL verifier does not support Ed25519 verification")


def parse_sign_update_output(output: str, expected_length: int) -> SparkleSignature:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    if len(lines) != 1:
        raise PublicationError(FailureClass.TOOLING, "sign_update returned unexpected output")
    match = _SIGNATURE_OUTPUT.fullmatch(lines[0])
    if match is None:
        raise PublicationError(FailureClass.TOOLING, "sign_update returned an invalid signature fragment")
    signature = match.group("signature")
    try:
        decoded = base64.b64decode(signature, validate=True)
        length = int(match.group("length"))
    except (ValueError, base64.binascii.Error) as error:
        raise PublicationError(FailureClass.TOOLING, "sign_update returned an invalid signature") from error
    if len(decoded) != 64 or length != expected_length:
        raise PublicationError(FailureClass.TOOLING, "sign_update signature length metadata does not match the archive")
    return SparkleSignature(signature, length)


def _run_or_raise(runner: CommandRunner, args: Sequence[str], stage: str):
    result = runner.run(args)
    if result.returncode != 0:
        raise PublicationError(FailureClass.TOOLING, f"Sparkle {stage} failed")
    return result


class SignUpdateAdapter:
    """Invokes only a provenance-verified Sparkle 2.9.6 signer."""

    def __init__(
        self,
        runner: CommandRunner,
        executable: str,
        account: str = "ed25519",
        private_key_file: Path | None = None,
    ) -> None:
        self.runner = runner
        self.executable = executable
        self.account = account
        # This is reserved for isolated interoperability proofs. Normal
        # publication leaves it unset and uses Sparkle's Keychain lookup.
        self.private_key_file = private_key_file

    def sign(self, archive: Path) -> SparkleSignature:
        before = hashlib.sha256(archive.read_bytes()).hexdigest()
        args = [self.executable, "--account", self.account]
        if self.private_key_file is not None:
            args.extend(["--ed-key-file", str(self.private_key_file)])
        args.append(str(archive))
        result = _run_or_raise(self.runner, args, "signing")
        after = hashlib.sha256(archive.read_bytes()).hexdigest()
        if before != after:
            raise PublicationError(FailureClass.ARTIFACT, "Sparkle signing modified the canonical Step 6 archive")
        return parse_sign_update_output(result.stdout, archive.stat().st_size)


class SparkleSignatureVerifier:
    """Uses Sparkle's verifier, then binds the result to configured public-key bytes."""

    def __init__(
        self,
        runner: CommandRunner,
        sign_update: str,
        openssl: str,
        account: str = "ed25519",
        private_key_file: Path | None = None,
    ) -> None:
        self.runner = runner
        self.sign_update = sign_update
        self.openssl = openssl
        self.account = account
        # Only isolated interoperability tests may provide this upstream
        # supported file-key path. Production publication leaves it unset so
        # sign_update reads the configured Keychain account.
        self.private_key_file = private_key_file

    def verify(self, archive: Path, signature: SparkleSignature, public_key: str) -> None:
        if archive.stat().st_size != signature.length:
            raise PublicationError(FailureClass.ARTIFACT, "archive length changed before Sparkle verification")
        try:
            key_bytes = base64.b64decode(public_key, validate=True)
        except (ValueError, base64.binascii.Error) as error:
            raise PublicationError(FailureClass.CONFIGURATION, "configured Sparkle public key is invalid") from error
        if len(key_bytes) != 32:
            raise PublicationError(FailureClass.CONFIGURATION, "configured Sparkle public key has invalid length")

        # This is Sparkle 2.9.6's documented verifier. It obtains the matching
        # public half from the Keychain pair used by the signer.
        sparkle_args = [self.sign_update, "--account", self.account]
        if self.private_key_file is not None:
            sparkle_args.extend(["--ed-key-file", str(self.private_key_file)])
        sparkle_args.extend(["--verify", str(archive), signature.ed_signature])
        _run_or_raise(self.runner, sparkle_args, "signature verification")

        if not _run_openssl_ed25519_verification(
            self.runner,
            self.openssl,
            archive,
            base64.b64decode(signature.ed_signature, validate=True),
            key_bytes,
        ):
            raise PublicationError(FailureClass.TOOLING, "Sparkle configured public-key verification failed")


def verify_sign_update(provenance: PublicationConfig, path: str) -> None:
    """Verify that a local sign_update is the pinned official release binary."""
    candidate = Path(path).resolve()
    expected_parts = Path(provenance.sparkle_sign_update_path).parts
    if tuple(candidate.parts[-len(expected_parts):]) != expected_parts:
        raise PublicationError(FailureClass.TOOLING, "Sparkle tool path does not name sign_update")
    try:
        actual = hashlib.sha256(candidate.read_bytes()).hexdigest()
    except OSError as error:
        raise PublicationError(FailureClass.TOOLING, f"could not read Sparkle sign_update: {candidate}") from error
    if actual != provenance.sparkle_sign_update_sha256:
        raise PublicationError(
            FailureClass.TOOLING,
            f"sign_update does not match the pinned Sparkle {provenance.sparkle_version} distribution "
            f"(expected {provenance.sparkle_sign_update_sha256}, got {actual})",
        )
