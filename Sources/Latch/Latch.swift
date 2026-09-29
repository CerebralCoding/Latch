import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

struct LatchError: Error, CustomStringConvertible {
    let description: String
    let exitCode: Int32

    init(_ description: String, exitCode: Int32 = 64) {
        self.description = description
        self.exitCode = exitCode
    }

    static func system(_ operation: String) -> LatchError {
        LatchError("\(operation): \(String(cString: strerror(errno)))", exitCode: 74)
    }
}

@main
struct Latch {
    static func main() {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.command == .help {
                print(Options.usage)
                return
            }

            let path = try options.resolvedPath()
            let latch = try FileLatch(path: path)
            switch options.command {
            case .run:
                try latch.acquire(shared: options.shared, timeout: options.timeout)
                try withExtendedLifetime(latch) {
                    try latch.inheritAcrossExec()
                    try execute(options.childArguments)
                }
            case .wait:
                try latch.acquire(shared: true, timeout: options.timeout)
            case .status:
                do {
                    try latch.acquire(shared: false, timeout: 0)
                    print("free")
                } catch let error as LatchError where error.exitCode == 75 {
                    print("held")
                    exit(75)
                }
            case .help:
                break
            }
        } catch let error as LatchError {
            FileHandle.standardError.write(Data("latch: \(error)\n".utf8))
            exit(error.exitCode)
        } catch {
            FileHandle.standardError.write(Data("latch: \(error.localizedDescription)\n".utf8))
            exit(74)
        }
    }

    static func execute(_ arguments: [String]) throws {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        defer { pointers.forEach { free($0) } }
        for argument in arguments {
            guard let pointer = strdup(argument) else {
                throw LatchError("out of memory", exitCode: 71)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        pointers.withUnsafeBufferPointer { buffer in
            _ = execvp(buffer[0], buffer.baseAddress!)
        }
        let code: Int32 = errno == ENOENT ? 127 : 126
        throw LatchError("cannot execute \(arguments[0]): \(String(cString: strerror(errno)))", exitCode: code)
    }
}
