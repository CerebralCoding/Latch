import Darwin
import Foundation
import LatchCheckpoint

let arguments = Array(CommandLine.arguments.dropFirst())
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
