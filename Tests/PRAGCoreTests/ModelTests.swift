import Testing
@testable import PRAGCore

@Test func byteDeltaFormatting() {
    let d = ByteDelta(before: 5_100_000, after: 1_800_000)
    #expect(d.percentString == "-65%")
    #expect(d.isSaving)
}

@Test func webReadyIsValid() {
    #expect(ActionPipeline.webReady.isValidChain)
    #expect(ActionPipeline.webReady.isApplicable(kinds: [.image], count: 1))
    #expect(!ActionPipeline.submissionReady.isApplicable(kinds: [.pdf], count: 1))
}


@Test func byteDeltaNeverClaimsTotalLossOrFakeZero() {
    #expect(ByteDelta(before: 24_100_000, after: 77_000).percentString == "-99%")
    #expect(ByteDelta(before: 1_000_000, after: 999_000).percentString == "-<1%")
    #expect(ByteDelta(before: 1_000_000, after: 1_002_000).percentString == "+<1%")
    #expect(ByteDelta(before: 500, after: 500).percentString == "±0%")
}
