import Foundation
import Testing
@testable import KurnCore

struct CloudConsentLedgerTests {
    private let destination = CloudConsentLedger.destination(providerID: "openai", endpoint: "https://api.openai.com/v1")
    private let date = Date(timeIntervalSince1970: 1_795_000_000)

    @Test func emptyLedgerAllowsNothing() {
        let ledger = CloudConsentLedger()
        #expect(!ledger.allows(destination, for: .onRequest))
        #expect(!ledger.allows(destination, for: .automatic))
    }

    @Test func automaticCoversOnRequestButNotTheReverse() {
        var onRequest = CloudConsentLedger()
        onRequest.grant(destination, for: .onRequest, at: date)
        #expect(onRequest.allows(destination, for: .onRequest))
        #expect(!onRequest.allows(destination, for: .automatic))

        var automatic = CloudConsentLedger()
        automatic.grant(destination, for: .automatic, at: date)
        #expect(automatic.allows(destination, for: .onRequest))
        #expect(automatic.allows(destination, for: .automatic))
    }

    @Test func aChangedEndpointIsADifferentDestination() {
        var ledger = CloudConsentLedger()
        ledger.grant(destination, for: .automatic, at: date)
        let moved = CloudConsentLedger.destination(providerID: "openai", endpoint: "https://proxy.example/v1")
        #expect(!ledger.allows(moved, for: .onRequest))
    }

    @Test func grantingTwiceKeepsTheFirstDate() {
        var ledger = CloudConsentLedger()
        ledger.grant(destination, for: .automatic, at: date)
        ledger.grant(destination, for: .automatic, at: date.addingTimeInterval(60))
        #expect(ledger.grants.count == 1)
        #expect(ledger.grant(for: destination, purpose: .automatic)?.grantedAt == date)
    }

    @Test func revokingOnePurposeKeepsTheOther() {
        var ledger = CloudConsentLedger()
        ledger.grant(destination, for: .onRequest, at: date)
        ledger.grant(destination, for: .automatic, at: date)
        ledger.revoke(destination, for: .automatic)
        #expect(ledger.allows(destination, for: .onRequest))
        #expect(!ledger.allows(destination, for: .automatic))
        ledger.revokeAll(destination)
        #expect(ledger.destinations.isEmpty)
        #expect(ledger.isWithdrawn(destination))
        ledger.grant(destination, for: .onRequest, at: date)
        #expect(!ledger.isWithdrawn(destination))
    }

    @Test func roundTripsAndRefusesAFutureVersion() throws {
        var ledger = CloudConsentLedger()
        ledger.grant(destination, for: .automatic, at: date)
        #expect(try CloudConsentLedger.decode(ledger.encoded()) == ledger)

        let future = Data(#"{"version":2,"grants":[]}"#.utf8)
        #expect(throws: CloudConsentLedgerError.unsupportedVersion) { try CloudConsentLedger.decode(future) }
    }
}
