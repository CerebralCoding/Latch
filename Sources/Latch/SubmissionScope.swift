import CryptoKit
import Foundation

enum SubmissionScope {
    static func create(in directory: URL) throws -> String {
        let nonce = UUID().uuidString
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(nonce.utf8), using: try key(in: directory, create: true))
        return nonce + "." + Data(signature).base64EncodedString()
    }

    static func validate(_ token: String, in directory: URL) throws -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
            let signature = Data(base64Encoded: String(parts[1])), signature.count == 32,
            HMAC<SHA256>.isValidAuthenticationCode(
                signature, authenticating: Data(parts[0].utf8), using: try key(in: directory, create: false))
        else { throw MCPFailure.invalid("Invalid submission scope token") }
        return SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func key(in directory: URL, create: Bool) throws -> SymmetricKey {
        let file = try FileLatch(path: directory.appendingPathComponent("scope.key").path)
        try file.acquire(shared: false, timeout: nil)
        return try withExtendedLifetime(file) {
            let handle = FileHandle(fileDescriptor: file.descriptor, closeOnDealloc: false)
            let data = try handle.readToEnd() ?? Data()
            if data.isEmpty, create {
                let key = SymmetricKey(size: .bits256)
                try handle.write(contentsOf: key.withUnsafeBytes { Data($0) })
                try handle.synchronize()
                return key
            }
            guard data.count == 32 else { throw MCPFailure.invalid("Submission scope key is unavailable") }
            return SymmetricKey(data: data)
        }
    }
}
