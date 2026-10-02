import Foundation
import Testing

@testable import Latch

@Test func `host keys merge without silently choosing between conflicting retry identities`() throws {
    let key = UUID().uuidString
    let metadata: MCPValue = [MCPRetryKeys.metadataKey: .string(key)]
    let values = try MCPRetryKeys.arguments(["name": "test"], metadata: metadata)
    #expect(values?["requestKey"] == .string(key))
    #expect(values?["name"] == "test")
    #expect(try MCPRetryKeys.arguments(["requestKey": .string(key)], metadata: metadata)?["requestKey"] == .string(key))
    #expect(throws: MCPFailure.self) { try MCPRetryKeys.arguments(["requestKey": "different"], metadata: metadata) }
    for invalid in [MCPValue.string(""), .number(1), .string(String(repeating: "a", count: 129)), .string("nul\0")] {
        #expect(throws: MCPFailure.self) {
            try MCPRetryKeys.arguments([:], metadata: [MCPRetryKeys.metadataKey: invalid])
        }
    }
    #expect(
        try MCPRetryKeys.arguments(["requestKey": "original"], metadata: ["progressToken": 1]) == [
            "requestKey": "original"
        ])
}

@Test func `discovery gives agents unique namespaces without minting keys per wait`() throws {
    let first = MCPRetryKeys()
    let second = MCPRetryKeys()
    #expect(first.prefix != second.prefix)
    let tools = MCPTools.listing(retryKeyPrefix: first.prefix)
    for tool in tools where tool["inputSchema"]?["properties"]?["requestKey"] != nil {
        #expect(
            tool["inputSchema"]?["properties"]?["requestKey"]?["description"]?.string?.contains(first.prefix) == true)
        #expect(
            tool["inputSchema"]?["properties"]?["requestKey"]?["description"]?.string?.contains(
                MCPRetryKeys.metadataKey) == true)
    }
}
