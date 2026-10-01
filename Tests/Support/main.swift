import CryptoKit
import Darwin
import Foundation
import LatchCheckpoint

let arguments = Array(CommandLine.arguments.dropFirst())
let tool = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
if tool.hasPrefix("installer-") {
    let environment = ProcessInfo.processInfo.environment
    let scenario = environment["LATCH_INSTALLER_TEST_SCENARIO"] ?? "install"
    let home = URL(fileURLWithPath: environment["HOME"]!)
    let event = tool + " " + arguments.joined(separator: " ") + "\n"
    let log = try FileHandle(forWritingTo: home.appendingPathComponent("events"))
    try log.seekToEnd()
    try log.write(contentsOf: Data(event.utf8))
    try log.close()
    switch tool {
    case "installer-id": print(scenario == "root" ? "0" : "501")
    case "installer-uname": print(arguments == ["-s"] ? "Darwin" : scenario == "intel" ? "x86_64" : "arm64")
    case "installer-sw_vers": print(scenario == "old-os" ? "25.0" : "26.0")
    case "installer-stat": print("501")
    case "installer-codesign": exit(scenario == "bad-signature" ? 1 : 0)
    case "installer-curl":
        if scenario == "network-failure" { exit(22) }
        let index = arguments.firstIndex(of: "--output")!
        let output = URL(fileURLWithPath: arguments[index + 1])
        if arguments.last!.hasSuffix(".sha256") {
            let data = try Data(contentsOf: URL(fileURLWithPath: environment["LATCH_INSTALLER_TEST_BINARY"]!))
            let hash =
                scenario == "bad-checksum"
                ? String(repeating: "0", count: 64)
                : SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try Data((hash + "\n").utf8).write(to: output)
        } else {
            try FileManager.default.copyItem(atPath: environment["LATCH_INSTALLER_TEST_BINARY"]!, toPath: output.path)
        }
    case "installer-latch":
        if arguments == ["--version"] {
            print(scenario == "bad-version" ? "9.9.9" : "0.11.0")
        } else if scenario == "command-failure" {
            exit(74)
        }
    default: exit(64)
    }
    exit(0)
}
switch arguments.first {
case "checkpoints":
    let session = try LatchSession.connect()
    for iteration in 0..<2 {
        try session.awaitPermit(iteration: iteration)
        FileHandle.standardOutput.write(Data("iteration:\(iteration)\n".utf8))
        _ = try FileHandle.standardInput.read(upToCount: 1)
        try session.finishIteration(iteration: iteration)
    }
case "report":
    let report = [
        "arguments": Array(arguments.dropFirst()), "workingDirectory": [FileManager.default.currentDirectoryPath],
    ]
    try FileHandle.standardOutput.write(JSONEncoder().encode(report))
    FileHandle.standardError.write(Data("separate stderr".utf8))
    exit(FileHandle.standardInput.readDataToEndOfFile().isEmpty ? 0 : 1)
case "fail75": exit(75)
case "blocked-input":
    FileHandle.standardOutput.write(Data("ready\n".utf8))
    while true {
        pause()
    }
case "pipe-input", "ignore-interrupt":
    if arguments[0] == "ignore-interrupt" {
        signal(SIGINT, SIG_IGN)
    }
    FileHandle.standardOutput.write(Data("ready\n".utf8))
    let bytes = FileHandle.standardInput.readDataToEndOfFile()
    FileHandle.standardOutput.write(Data(bytes.base64EncodedString().utf8))
case "terminal", "raw-terminal":
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1, isatty(STDERR_FILENO) == 1,
        tcgetpgrp(STDIN_FILENO) == getpgrp()
    else { exit(65) }
    if arguments[0] == "raw-terminal" {
        var settings = termios()
        guard tcgetattr(STDIN_FILENO, &settings) == 0 else { exit(66) }
        cfmakeraw(&settings)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0 else { exit(66) }
        FileHandle.standardOutput.write(Data("raw-ready\n".utf8))
        var bytes = [UInt8](repeating: 0, count: 3)
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes {
                read(STDIN_FILENO, $0.baseAddress!.advanced(by: offset), remaining)
            }
            guard count > 0 else { exit(67) }
            offset += count
        }
        FileHandle.standardOutput.write(Data(Data(bytes).base64EncodedString().utf8))
    } else {
        FileHandle.standardOutput.write(Data("terminal-ready\n".utf8))
        FileHandle.standardError.write(Data("terminal-stderr\n".utf8))
        while let line = readLine() {
            if line == "exit" {
                break
            }
            if line == "size" {
                var size = winsize()
                guard ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0 else { exit(68) }
                FileHandle.standardOutput.write(Data("size: \(size.ws_col)x\(size.ws_row)\n".utf8))
            } else {
                FileHandle.standardOutput.write(Data("line: \(line)\n".utf8))
            }
        }
    }
case "flood":
    FileHandle.standardOutput.write(Data(repeating: 65, count: 200_000))
    FileHandle.standardError.write(Data(repeating: 66, count: 200_000))
case "descendant", "orphan":
    if arguments[0] == "descendant" {
        signal(SIGTERM, SIG_IGN)
    }
    var child: pid_t = 0
    var pointers = [
        strdup(CommandLine.arguments[0]), strdup(arguments[0] == "descendant" ? "descendant-child" : "orphan-child"),
        strdup(arguments[1]), nil,
    ]
    defer { for pointer in pointers { free(pointer) } }
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    guard posix_spawn(&child, CommandLine.arguments[0], nil, nil, &pointers, &environment) == 0 else { exit(1) }
    while true {
        pause()
    }
case "descendant-child", "orphan-child":
    signal(SIGTERM, SIG_IGN)
    if arguments[0] == "orphan-child" {
        close(STDOUT_FILENO)
        close(STDERR_FILENO)
    }
    try Data("\(getpid())".utf8).write(to: URL(fileURLWithPath: arguments[1]))
    while true {
        pause()
    }
default: exit(64)
}
