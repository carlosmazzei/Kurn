//
//  StreamedWordCountTests.swift
//  KurnCoreTests
//

import Foundation
import Testing
@testable import KurnCore

struct StreamedWordCountTests {

    @Test func countsRunsOfLettersAndDigits() {
        var count = StreamedWordCount()
        #expect(count.add("We agreed on 3 dates.") == 5)
    }

    @Test func aWordSplitAcrossFragmentsCountsOnce() {
        var count = StreamedWordCount()
        count.add("the summ")
        #expect(count.add("ary is ready") == 4)
    }

    @Test func jsonPunctuationIsNotAWord() {
        var count = StreamedWordCount()
        #expect(count.add(#"{"sections":[{"title":"Ação","#) == 3)
        #expect(count.add(#""body":""}]}"#) == 4)
    }

    @Test func emptyAndPunctuationOnlyFragmentsAddNothing() {
        var count = StreamedWordCount()
        #expect(count.add("") == 0)
        #expect(count.add(" {}[]\n") == 0)
        #expect(count.words == 0)
    }
}
