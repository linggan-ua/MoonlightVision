//
//  PairingFlow.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation

/// One in-flight pairing operation. The core implementation wraps PairManager
/// in an NSOperation; tests can provide a fake session.
protocol PairingSession: AnyObject {
    func start()
}

protocol PairingSessionFactory {
    func makeSession(host: TemporaryHost, clientCert: Data, callback: PairCallback) -> PairingSession?
}

final class LimelightPairingSessionFactory: PairingSessionFactory {
    private let queue = OperationQueue()

    func makeSession(host: TemporaryHost, clientCert: Data, callback: PairCallback) -> PairingSession? {
        guard let http = HttpManager(host: host),
              let manager = PairManager(manager: http, clientCert: clientCert, callback: callback) else {
            return nil
        }
        return LimelightPairingSession(manager: manager, queue: queue)
    }
}

private final class LimelightPairingSession: PairingSession {
    private let manager: PairManager
    private let queue: OperationQueue

    init(manager: PairManager, queue: OperationQueue) {
        self.manager = manager
        self.queue = queue
    }

    func start() {
        queue.addOperation(manager)
    }
}

/// Pairing events, independent of networking. HostSessionModel owns one of these
/// per pairing attempt and updates its UI/persistence state from the events.
final class PairingFlow {
    enum Event: Equatable {
        case pin(String)
        case paired(Data)
        case alreadyPaired
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?

    private let factory: PairingSessionFactory
    private var session: PairingSession?
    private var callback: PairingCallbackProxy?

    init(factory: PairingSessionFactory = LimelightPairingSessionFactory()) {
        self.factory = factory
    }

    func start(host: TemporaryHost, clientCert: Data) {
        let proxy = PairingCallbackProxy { [weak self] event in
            self?.onEvent?(event)
        }
        callback = proxy
        session = factory.makeSession(host: host, clientCert: clientCert, callback: proxy)
        session?.start()
    }
}

private final class PairingCallbackProxy: NSObject, PairCallback {
    private let handler: (PairingFlow.Event) -> Void

    init(handler: @escaping (PairingFlow.Event) -> Void) {
        self.handler = handler
    }

    func startPairing(_ PIN: String!) {
        handler(.pin(PIN ?? ""))
    }

    func pairSuccessful(_ serverCert: Data!) {
        guard let serverCert else {
            handler(.failed("The host returned an invalid certificate."))
            return
        }
        handler(.paired(serverCert))
    }

    func pairFailed(_ message: String!) {
        handler(.failed(message ?? "Pairing failed."))
    }

    func alreadyPaired() {
        handler(.alreadyPaired)
    }
}
