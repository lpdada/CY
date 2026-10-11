// Copyright © 2026 Anton Novoselov. All rights reserved.

import Testing
import AIProviders

@Suite("OpenAIOAuthClient")
struct OpenAIOAuthClientTests {
    /// Ids that are valid in the API-key catalog but rejected by the Codex
    /// endpoint must fall back to the default instead of being sent as-is.
    @Test(arguments: ["gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-4o"])
    func resolveModelRejectsIdsCodexDoesNotServe(_ id: String) {
        #expect(OpenAIOAuthClient.resolveModel(id) == OpenAIOAuthClient.defaultModel)
    }

    @Test func resolveModelKeepsServedIds() {
        for id in OpenAIOAuthClient.supportedModels {
            #expect(OpenAIOAuthClient.resolveModel(id) == id)
        }
    }
}
