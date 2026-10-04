import Foundation
import Testing

@testable import LatchRelease

private func hostedEnvironment(_ directory: URL) -> [String: String] {
    [
        "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
        "GITHUB_REPOSITORY": "CerebralCoding/Latch", "GITHUB_REF": "refs/heads/main",
        "GITHUB_ACTOR": "CerebralCoding", "GITHUB_TRIGGERING_ACTOR": "CerebralCoding",
        "GITHUB_EVENT_NAME": "workflow_dispatch", "RUNNER_TEMP": directory.path,
        "LATCH_SIGNING_P12_BASE64": Data("not a signing identity".utf8).base64EncodedString(),
        "LATCH_SIGNING_P12_PASSWORD": "fixture password",
        "LATCH_NOTARY_KEY_BASE64": Data("fixture API key".utf8).base64EncodedString(),
        "LATCH_NOTARY_KEY_ID": "TESTKEY123", "LATCH_NOTARY_ISSUER_ID": UUID().uuidString,
    ]
}

@Test func `hosted signing rejects other actors refs events repositories and runners before writing credentials`()
    throws
{
    let fixture = try Fixture()
    for (name, value) in [
        ("GITHUB_ACTIONS", "false"), ("RUNNER_ENVIRONMENT", "self-hosted"),
        ("GITHUB_REPOSITORY", "someone/Latch"), ("GITHUB_REF", "refs/heads/topic"),
        ("GITHUB_REF", "refs/tags/v0.17.0"), ("GITHUB_ACTOR", "someone"),
        ("GITHUB_TRIGGERING_ACTOR", "someone"), ("GITHUB_EVENT_NAME", "pull_request"), ("RUNNER_TEMP", "relative"),
    ] {
        var environment = hostedEnvironment(fixture.directory)
        environment[name] = value
        #expect(throws: ReleaseError.self) { try HostedSigning(environment: environment) }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
}

@Test func `hosted signing rejects missing malformed and path escaping secrets before Keychain setup`() throws {
    let fixture = try Fixture()
    for (name, value) in [
        ("LATCH_SIGNING_P12_BASE64", ""), ("LATCH_SIGNING_P12_BASE64", "invalid!"),
        ("LATCH_SIGNING_P12_PASSWORD", ""), ("LATCH_NOTARY_KEY_BASE64", "invalid!"),
        ("LATCH_NOTARY_KEY_ID", "../../key"), ("LATCH_NOTARY_ISSUER_ID", "not a UUID"),
    ] {
        var environment = hostedEnvironment(fixture.directory)
        environment[name] = value
        #expect(throws: ReleaseError.self) { try HostedSigning(environment: environment) }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
}

@Test func `hosted signing removes temporary keys and Keychain after failed identity import`() throws {
    let fixture = try Fixture()
    let credentials = try HostedSigning(environment: hostedEnvironment(fixture.directory))
    #expect(throws: ReleaseError.self) {
        try credentials.prepare(profile: "fixture") { _ in Issue.record("invalid identity must not reach signing") }
    }
    #expect(!FileManager.default.fileExists(atPath: credentials.directory.path))
}

@Test func `hosted cleanup refuses an existing directory not created by LatchRelease`() throws {
    let fixture = try Fixture()
    let credentials = try HostedSigning(environment: hostedEnvironment(fixture.directory))
    try FileManager.default.createDirectory(at: credentials.directory, withIntermediateDirectories: false)
    let existing = credentials.directory.appendingPathComponent("existing")
    try Data("preserve me".utf8).write(to: existing)
    #expect(throws: ReleaseError.self) { try credentials.prepare(profile: "fixture") { _ in } }
    #expect(throws: (any Error).self) { try HostedSigning.cleanup(directory: credentials.directory) }
    #expect(try String(contentsOf: existing, encoding: .utf8) == "preserve me")
}
