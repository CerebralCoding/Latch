import Foundation
import Testing

@testable import Latch

@Test func `long option values support both separators without changing child arguments`() throws {
    let command = ["tool", "--name=child", "--help", "--", "", "a b"]
    let options = try Options(
        arguments: [
            "schedule", "--file=/queue=a=b", "--name=work=a", "--mode=batch", "--cpu=4", "--memory-mib=4096",
            "--max-cpu-temp=70", "--max-gpu-temp=75", "--cooldown=1", "--timeout=0.25", "--",
        ] + command)
    let separated = try Options(
        arguments: [
            "schedule", "--file", "/queue=a=b", "--name", "work=a", "--mode", "batch", "--cpu", "4",
            "--memory-mib", "4096", "--max-cpu-temp", "70", "--max-gpu-temp", "75", "--cooldown", "1",
            "--timeout", "0.25", "--",
        ] + command)
    #expect(options.file == separated.file)
    #expect(options.taskName == separated.taskName)
    #expect(options.requirements == separated.requirements)
    #expect(options.timeout == 0.25)
    #expect(options.childArguments == command)
    #expect(separated.childArguments == command)
    #expect(try Options(arguments: ["run", "--file=--help", "--", "tool"]).file == "--help")
    #expect(try Options(arguments: ["schedule", "--name=--help", "--", "tool"]).taskName == "--help")
}

@Test func `option boundaries distinguish command operands from flags`() throws {
    let id = UUID().uuidString
    #expect(try Options(arguments: ["prioritize", "--file=/queue", "--", id]).jobID == id)
    #expect(try Options(arguments: ["list", "--"]).command == .list)
    #expect(try Options(arguments: ["service", "status", "--json"]).serviceAction == .status)
    for arguments in [
        ["list", "--", "--json"], ["prioritize", "--", id, "--help"],
        ["service", "--file", "/queue", "status"], ["service", "status", "start"],
        ["service", "start", "--file=/queue"], ["service", "stop", "--file", "/queue"],
        ["service", "uninstall", "--file=/queue"],
        ["view", "--file", "--json"], ["schedule", "--name", "--", "tool"],
        ["view", "--file=/a", "--file", "/b"], ["wait", "--timeout=1", "--timeout", "2"],
        ["view", "--verbose=true"], ["run", "--shared=false", "--", "tool"],
        ["--help", "view"],
    ] {
        #expect(throws: LatchError.self) { try Options(arguments: arguments) }
    }
}

@Test func `help is focused and exits without creating queue state`() throws {
    let fixture = try Fixture()
    for arguments in [
        [], ["--help"], ["-h"], ["help"], ["service", "--help"], ["service", "stop", "--help"],
        ["clear", "--help"], ["stop", "-h"], ["prioritize", "--help"],
    ] {
        let scoped = !arguments.isEmpty && ["clear", "stop", "prioritize"].contains(arguments[0])
        let child = try fixture.launch(arguments, includeFile: scoped)
        #expect(try fixture.finish(child) == 0)
        #expect(child.output.contains("Usage: latch"))
        #expect(child.errors.isEmpty)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.lockPath))
    #expect(!FileManager.default.fileExists(atPath: fixture.lockPath + ".queue"))
    let service = CLIHelp.text(for: .service, service: .stop)
    #expect(service.contains("Usage: latch service stop"))
    #expect(!service.contains("install    "))
    #expect(!service.contains("--verbose"))
    #expect(!service.contains("--file"))
    let status = CLIHelp.text(for: .status)
    #expect(!status.contains("--shared"))
    #expect(!status.contains("--timeout"))
    #expect(CLIHelp.text(for: .run).contains("-- COMMAND [ARG...]"))
}
