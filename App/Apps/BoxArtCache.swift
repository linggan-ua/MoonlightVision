//
//  BoxArtCache.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation
import UIKit

/// Caches decoded box art. AppRow otherwise re-reads and re-decodes the PNG on
/// every SwiftUI body evaluation. The token is part of the key so refreshed
/// assets do not return a stale image.
final class BoxArtCache {
    static let shared = BoxArtCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {}

    func image(for app: TemporaryApp, token: Int) -> UIImage? {
        guard let path = AppAssetManager.boxArtPath(for: app) else {
            return nil
        }
        let key = "\(path)#\(token)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(contentsOfFile: path) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
