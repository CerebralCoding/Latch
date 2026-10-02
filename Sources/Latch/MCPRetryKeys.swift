import Foundation

struct MCPRetryKeys {
    static let metadataKey = "com.cerebralcoding.latch/retryKey"
    static let prefixMetadataKey = "com.cerebralcoding.latch/retryKeyPrefix"
    let prefix = UUID().uuidString + "/"

    var instructions: String {
        "Latch-issued retry-key prefix: \(prefix). Append a distinct operation name or number for each new submission or control. Keep the full key for identical retries, even if a later connection issues a different prefix. No external UUID-generation call is needed."
    }

    static func arguments(_ arguments: MCPValue?, metadata: MCPValue?) throws -> MCPValue? {
        guard let supplied = metadata?[metadataKey] else { return arguments }
        let key = try MCPArguments(["requestKey": supplied], allowed: ["requestKey"]).text("requestKey", maximum: 128)
        guard arguments == nil || arguments?.object != nil else {
            throw MCPFailure.invalid("arguments must be an object")
        }
        var values = arguments?.object ?? [:]
        if let explicit = values["requestKey"], explicit != .string(key) {
            throw MCPFailure.invalid("requestKey differs from host retry-key metadata")
        }
        values["requestKey"] = .string(key)
        return .object(values)
    }
}
