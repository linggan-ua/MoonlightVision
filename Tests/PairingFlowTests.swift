//
//  PairingFlowTests.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import XCTest
@testable import MoonlightVision

@MainActor
final class PairingFlowTests: XCTestCase {
    private final class FakeSession: PairingSession {
        private(set) var started = false

        func start() {
            started = true
        }
    }

    private final class FakeFactory: PairingSessionFactory {
        let session = FakeSession()
        private(set) var callback: PairCallback?

        func makeSession(host: TemporaryHost, clientCert: Data, callback: PairCallback) -> PairingSession? {
            self.callback = callback
            return session
        }
    }

    func testPINThenCertificate() {
        let factory = FakeFactory()
        let flow = PairingFlow(factory: factory)
        var events: [PairingFlow.Event] = []
        flow.onEvent = { events.append($0) }

        flow.start(host: TemporaryHost(), clientCert: Data([0x01]))
        XCTAssertTrue(factory.session.started)

        factory.callback?.startPairing("1234")
        factory.callback?.pairSuccessful(Data([0xAA, 0xBB]))

        XCTAssertEqual(events, [.pin("1234"), .paired(Data([0xAA, 0xBB]))])
    }

    func testAlreadyPairedAndFailure() {
        let factory = FakeFactory()
        let flow = PairingFlow(factory: factory)
        var events: [PairingFlow.Event] = []
        flow.onEvent = { events.append($0) }

        flow.start(host: TemporaryHost(), clientCert: Data())
        factory.callback?.alreadyPaired()
        factory.callback?.pairFailed("denied")

        XCTAssertEqual(events, [.alreadyPaired, .failed("denied")])
    }

    func testNilCertificateBecomesFailure() {
        let factory = FakeFactory()
        let flow = PairingFlow(factory: factory)
        var events: [PairingFlow.Event] = []
        flow.onEvent = { events.append($0) }

        flow.start(host: TemporaryHost(), clientCert: Data())
        factory.callback?.pairSuccessful(nil)

        XCTAssertEqual(events.count, 1)
        guard let event = events.first, case .failed = event else {
            XCTFail("Expected a failure event, got \(events)")
            return
        }
    }
}
