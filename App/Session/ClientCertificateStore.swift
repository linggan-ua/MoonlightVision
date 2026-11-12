//
//  ClientCertificateStore.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation

/// Generates and caches the client certificate used for pairing and HTTPS.
/// Key generation can take a moment on first launch, so it never runs on the main thread.
actor ClientCertificateStore {
    static let shared = ClientCertificateStore()

    private var cached: Data?

    func certificate() async -> Data? {
        if let cached {
            return cached
        }

        let certificate: Data? = await Task.detached(priority: .userInitiated) {
            if let existing = CryptoManager.readCertFromFile() {
                return existing
            }
            CryptoManager.generateKeyPairUsingSSL()
            return CryptoManager.readCertFromFile()
        }.value

        cached = certificate
        return certificate
    }
}
