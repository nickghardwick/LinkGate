from __future__ import annotations

from enum import Enum


class FailureClass(str, Enum):
    REPOSITORY = "REPOSITORY"
    PROVENANCE = "PROVENANCE"
    ARTIFACT = "ARTIFACT"
    CONFIGURATION = "CONFIGURATION"
    RELEASE_NOTES = "RELEASE_NOTES"
    TOOLING = "TOOLING"
    GITHUB = "GITHUB"
    APPCAST = "APPCAST"
    TRUST = "TRUST"


class PublicationError(Exception):
    def __init__(self, failure_class: FailureClass, message: str) -> None:
        super().__init__(message)
        self.failure_class = failure_class

    def __str__(self) -> str:
        return f"{self.failure_class.value}: {self.args[0]}"
