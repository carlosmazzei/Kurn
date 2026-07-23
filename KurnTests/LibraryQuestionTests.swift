//
//  LibraryQuestionTests.swift
//  KurnTests
//
//  The global-aggregate detection for the library-wide "Ask": counts and
//  "all/every meeting" questions, which must be answered over every article,
//  are distinguished from ordinary questions across the app's seven languages.
//

import Foundation
import Testing
@testable import Kurn

struct LibraryQuestionTests {

    @Test func detectsGlobalAggregatesAcrossLanguages() {
        let aggregates = [
            "How many meetings discussed hiring?",      // en
            "List every action item",                   // en
            "Quantas reuniões falaram de orçamento?",   // pt
            "Liste todas as decisões",                  // pt
            "¿Cuántas reuniones trataron el tema?",     // es
            "Combien de réunions ont abordé cela ?",    // fr
            "Quante riunioni ne hanno parlato?",        // it
            "Wie viele Meetings behandelten das?",      // de
            "所有会议里总共提到多少次预算？"                  // zh
        ]
        for question in aggregates {
            #expect(LibraryQuestion.isGlobalAggregate(question), "\(question)")
        }
    }

    @Test func ordinaryQuestionsAreNotGlobalAggregates() {
        #expect(!LibraryQuestion.isGlobalAggregate("What did Ana say about the deadline?"))
        #expect(!LibraryQuestion.isGlobalAggregate("How did the budget evolve?"))
        #expect(!LibraryQuestion.isGlobalAggregate("Resuma a reunião de ontem"))
    }
}
