//
//  CorrectionFaithfulnessTests.swift
//  KurnCoreTests
//

import Testing
@testable import KurnCore

struct CorrectionFaithfulnessTests {

    private func accepts(_ original: String, _ corrected: String, allowed: [String] = []) -> Bool {
        CorrectionFaithfulness.accepts(original: original, corrected: corrected, allowedTerms: allowed)
    }

    @Test func punctuationAndCaseOnlyChangesAreFaithful() {
        #expect(accepts("we need it", "We need it."))
    }

    @Test func respellingsOfWhatWasHeardAreFaithful() {
        #expect(accepts("we ned to ship this fetur", "we need to ship this feature"))
    }

    @Test func joiningAWordTheASRSplitIsFaithful() {
        #expect(accepts("we move it to cuber netes", "we move it to Kubernetes"))
    }

    @Test func splittingAWordTheASRMergedIsFaithful() {
        #expect(accepts("thanks alot", "thanks a lot"))
    }

    @Test func aGroundedTermMayReplaceADissimilarForm() {
        #expect(!accepts("deploy it with helmet", "deploy it with Helm chart"))
        #expect(accepts("the jay son file", "the JSON file", allowed: ["JSON"]))
    }

    @Test func aWordWithNoConnectionToWhatWasSaidIsRejected() {
        #expect(!accepts("we need it", "we need it by Friday"))
        #expect(!accepts("the budget is fine", "the Kubernetes budget is fine"))
    }

    @Test func shortWordsMustMatchClosely() {
        #expect(CorrectionFaithfulness.isRespelling("in", of: "on"))
        #expect(!CorrectionFaithfulness.isRespelling("by", of: "it"))
    }

    @Test func editDistanceStopsPastItsLimit() {
        #expect(CorrectionFaithfulness.editDistance(Array("kitten"), Array("sitting"), limit: 5) == 3)
        #expect(CorrectionFaithfulness.editDistance(Array("a"), Array("abcdef"), limit: 2) == 3)
        #expect(CorrectionFaithfulness.editDistance(Array(""), Array("ab"), limit: 5) == 2)
        #expect(CorrectionFaithfulness.editDistance(Array("abcd"), Array("wxyz"), limit: 1) == 2)
    }
}
