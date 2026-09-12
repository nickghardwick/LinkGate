#!/usr/bin/env swift

import CryptoKit
import Foundation

private struct ReleaseMetadata: Codable, Equatable {
    let product: String
    let marketingVersion: String
    let build: String
    let bundleID: String
    let architectures: [String]
    let deploymentTarget: String
    let signingIdentity: String

    enum CodingKeys: String, CodingKey {
        case product
        case marketingVersion = "marketing_version"
        case build
        case bundleID = "bundle_id"
        case architectures
        case deploymentTarget = "deployment_target"
        case signingIdentity = "signing_identity"
    }
}

private struct ReleaseManifest: Codable {
    let product: String
    let marketingVersion: String
    let build: String
    let bundleID: String
    let sourceCommit: String
    let architectures: [String]
    let deploymentTarget: String
    let signingIdentity: String
    let notarized: Bool
    let stapled: Bool
    let xcodeVersion: String
    let macOSVersion: String
    let artifactName: String
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case product
        case marketingVersion = "marketing_version"
        case build
        case bundleID = "bundle_id"
        case sourceCommit = "source_commit"
        case architectures
        case deploymentTarget = "deployment_target"
        case signingIdentity = "signing_identity"
        case notarized, stapled
        case xcodeVersion = "xcode_version"
        case macOSVersion = "macos_version"
        case artifactName = "artifact_name"
        case sha256
    }
}

private struct ObservedArtifact: Codable {
    let product: String
    let marketingVersion: String
    let build: String
    let bundleID: String
    let architectures: [String]
    let deploymentTarget: String
    let signingIdentity: String
    let notarized: Bool
    let stapled: Bool

    enum CodingKeys: String, CodingKey {
        case product
        case marketingVersion = "marketing_version"
        case build
        case bundleID = "bundle_id"
        case architectures
        case deploymentTarget = "deployment_target"
        case signingIdentity = "signing_identity"
        case notarized, stapled
    }
}

private enum ReleaseSupportError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): return message
        }
    }
}

private func fail(_ message: String) throws -> Never {
    throw ReleaseSupportError.message(message)
}

private func readData(at path: String) throws -> Data {
    guard FileManager.default.fileExists(atPath: path) else {
        try fail("missing input file: \(path)")
    }
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    return try handle.readToEnd() ?? Data()
}

private func decode<T: Decodable>(_ type: T.Type, from path: String, label: String) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: readData(at: path))
    } catch let error as ReleaseSupportError {
        throw error
    } catch {
        try fail("invalid \(label) JSON: \(error.localizedDescription)")
    }
}

private func write<T: Encodable>(_ value: T, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

private func value(_ name: String, in arguments: [String: String]) throws -> String {
    guard let value = arguments[name], !value.isEmpty else {
        try fail("missing required --\(name) argument")
    }
    return value
}

private func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
}

private func validate(_ metadata: ReleaseMetadata) throws {
    guard !metadata.product.isEmpty,
          !metadata.bundleID.isEmpty,
          !metadata.architectures.isEmpty,
          !metadata.architectures.contains(where: \.isEmpty),
          !metadata.deploymentTarget.isEmpty,
          !metadata.signingIdentity.isEmpty else {
        try fail("release metadata contains an empty required value")
    }
    guard matches(metadata.marketingVersion, "^[0-9]+\\.[0-9]+\\.[0-9]+$") else {
        try fail("invalid marketing version: \(metadata.marketingVersion)")
    }
    guard matches(metadata.build, "^[0-9]+$") else {
        try fail("invalid build value: \(metadata.build)")
    }
}

private func validate(_ manifest: ReleaseManifest) throws {
    try validate(ReleaseMetadata(
        product: manifest.product,
        marketingVersion: manifest.marketingVersion,
        build: manifest.build,
        bundleID: manifest.bundleID,
        architectures: manifest.architectures,
        deploymentTarget: manifest.deploymentTarget,
        signingIdentity: manifest.signingIdentity
    ))
    guard matches(manifest.sourceCommit, "^[0-9a-f]{40}$") else {
        try fail("invalid source commit")
    }
    guard !manifest.xcodeVersion.isEmpty, !manifest.macOSVersion.isEmpty else {
        try fail("manifest is missing build environment metadata")
    }
    guard URL(fileURLWithPath: manifest.artifactName).lastPathComponent == manifest.artifactName,
          manifest.artifactName.hasSuffix(".dmg") else {
        try fail("invalid artifact name: \(manifest.artifactName)")
    }
    guard matches(manifest.sha256, "^[0-9a-f]{64}$") else {
        try fail("invalid SHA-256 digest")
    }
    guard manifest.notarized, manifest.stapled else {
        try fail("manifest requires notarized and stapled artifacts")
    }
}

private func metadata(from path: String) throws -> ReleaseMetadata {
    let object = try JSONSerialization.jsonObject(with: readData(at: path))
    guard let entries = object as? [[String: Any]],
          let settings = entries.first?["buildSettings"] as? [String: Any] else {
        try fail("invalid xcodebuild build-settings JSON")
    }

    func setting(_ key: String) throws -> String {
        guard let value = settings[key] as? String, !value.isEmpty else {
            try fail("xcodebuild metadata is missing \(key)")
        }
        return value
    }

    let architectures = try setting("ARCHS").split(separator: " ").map(String.init)
    let result = try ReleaseMetadata(
        product: setting("PRODUCT_NAME"),
        marketingVersion: setting("MARKETING_VERSION"),
        build: setting("CURRENT_PROJECT_VERSION"),
        bundleID: setting("PRODUCT_BUNDLE_IDENTIFIER"),
        architectures: architectures,
        deploymentTarget: setting("MACOSX_DEPLOYMENT_TARGET"),
        signingIdentity: setting("CODE_SIGN_IDENTITY")
    )
    try validate(result)
    return result
}

private func checksum(in path: String, expectedArtifact: String) throws -> String {
    let contents = try String(decoding: readData(at: path), as: UTF8.self)
    let line = contents.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let fields = line.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count == 2, String(fields[1]) == expectedArtifact else {
        try fail("checksum file does not name \(expectedArtifact)")
    }
    let digest = String(fields[0])
    guard matches(digest, "^[0-9a-f]{64}$") else {
        try fail("checksum file contains an invalid SHA-256 digest")
    }
    return digest
}

private func digest(of path: String) throws -> String {
    let hash = SHA256.hash(data: try readData(at: path))
    return hash.map { String(format: "%02x", $0) }.joined()
}

private func validateObserved(_ observed: ObservedArtifact, against manifest: ReleaseManifest) throws {
    guard observed.product == manifest.product,
          observed.marketingVersion == manifest.marketingVersion,
          observed.build == manifest.build,
          observed.bundleID == manifest.bundleID,
          observed.architectures == manifest.architectures,
          observed.deploymentTarget == manifest.deploymentTarget,
          observed.signingIdentity == manifest.signingIdentity else {
        try fail("observed artifact metadata does not match manifest")
    }
    guard observed.notarized, observed.stapled else {
        try fail("observed artifact is not notarized and stapled")
    }
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { try fail("missing command") }
    var options: [String: String] = [:]
    var index = 1
    while index < arguments.count {
        let option = arguments[index]
        guard option.hasPrefix("--"), index + 1 < arguments.count, options[option] == nil else {
            try fail("invalid command arguments")
        }
        options[String(option.dropFirst(2))] = arguments[index + 1]
        index += 2
    }

    switch command {
    case "metadata":
        let result = try metadata(from: value("input", in: options))
        try write(result, to: value("output", in: options))
    case "manifest-write":
        let releaseMetadata: ReleaseMetadata = try decode(ReleaseMetadata.self, from: value("metadata", in: options), label: "metadata")
        try validate(releaseMetadata)
        let artifact = try value("artifact", in: options)
        let manifest = ReleaseManifest(
            product: releaseMetadata.product,
            marketingVersion: releaseMetadata.marketingVersion,
            build: releaseMetadata.build,
            bundleID: releaseMetadata.bundleID,
            sourceCommit: try value("source-commit", in: options),
            architectures: releaseMetadata.architectures,
            deploymentTarget: releaseMetadata.deploymentTarget,
            signingIdentity: releaseMetadata.signingIdentity,
            notarized: true,
            stapled: true,
            xcodeVersion: try value("xcode-version", in: options),
            macOSVersion: try value("macos-version", in: options),
            artifactName: artifact,
            sha256: try value("sha256", in: options)
        )
        try validate(manifest)
        try write(manifest, to: value("output", in: options))
    case "manifest-validate":
        let manifest: ReleaseManifest = try decode(ReleaseManifest.self, from: value("manifest", in: options), label: "manifest")
        try validate(manifest)
        let dmgPath = try value("dmg", in: options)
        let artifactName = URL(fileURLWithPath: dmgPath).lastPathComponent
        guard artifactName == manifest.artifactName else {
            try fail("DMG basename does not match manifest artifact name")
        }
        let expectedChecksum = try checksum(in: value("checksum", in: options), expectedArtifact: artifactName)
        guard expectedChecksum == manifest.sha256 else {
            try fail("checksum file digest does not match manifest")
        }
        guard try digest(of: dmgPath) == manifest.sha256 else {
            try fail("DMG SHA-256 does not match manifest")
        }
        let observed: ObservedArtifact = try decode(ObservedArtifact.self, from: value("observed", in: options), label: "observed artifact metadata")
        try validateObserved(observed, against: manifest)
    default:
        try fail("unknown command: \(command)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
