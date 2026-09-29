import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "report":
    let report = ["arguments": Array(arguments.dropFirst()), "workingDirectory": [FileManager.default.currentDirectoryPath]]
    try FileHandle.standardOutput.write(JSONEncoder().encode(report))
    FileHandle.standardError.write(Data("separate stderr".utf8))
    exit(FileHandle.standardInput.readDataToEndOfFile().isEmpty ? 0 : 1)
case "fail75": exit(75)
case "flood":
    FileHandle.standardOutput.write(Data(repeating: 65, count: 200_000))
    FileHandle.standardError.write(Data(repeating: 66, count: 200_000))
case "descendant", "orphan":
    if arguments[0] == "descendant" {
        signal(SIGTERM, SIG_IGN)
    }
    var child: pid_t = 0
    var pointers = [strdup(CommandLine.arguments[0]), strdup(arguments[0] == "descendant" ? "descendant-child" : "orphan-child"), strdup(arguments[1]), nil]
    defer { pointers.forEach { free($0) } }
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    guard posix_spawn(&child, CommandLine.arguments[0], nil, nil, &pointers, &environment) == 0 else { exit(1) }
    while true {
        pause()
    }
case "descendant-child", "orphan-child":
    signal(SIGTERM, SIG_IGN)
    if arguments[0] == "orphan-child" {
        close(STDOUT_FILENO); close(STDERR_FILENO)
    }
    try Data("\(getpid())".utf8).write(to: URL(fileURLWithPath: arguments[1]))
    while true {
        pause()
    }
default: exit(64)
}
