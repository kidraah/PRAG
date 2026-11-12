import Testing
@testable import NotchPipeCore

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
