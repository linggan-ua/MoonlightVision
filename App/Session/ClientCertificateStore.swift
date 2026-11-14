//
//  ClientCertificateStore.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation

/// Generates and caches the client certificate used for pairing and HTTPS.
/// Key generation can take a moment on first launch, so it never runs on the
/// main thread. A single in-flight task is shared by concurrent callers; actor
/// reentrancy must not start two key generations against the same files.
actor ClientCertificateStore {
    static let shared = ClientCertificateStore()

    private var cached: Data?
    private var inFlight: Task<Data?, Never>?

    func certificate() async -> Data? {
        if let cached {
            return cached
        }
        if let inFlight {
            return await inFlight.value
        }

        let task = Task.detached(priority: .userInitiated) { () -> Data? in
            if let existing = CryptoManager.readCertFromFile() {
                return existing
            }
            CryptoManager.generateKeyPairUsingSSL()
            return CryptoManager.readCertFromFile()
        }
        inFlight = task

        let certificate = await task.value
        if cached == nil {
            cached = certificate
        }
        inFlight = nil
        return certificate
    }
}
