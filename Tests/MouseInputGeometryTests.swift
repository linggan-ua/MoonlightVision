//
//  MouseInputGeometryTests.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import XCTest
@testable import MoonlightVision

final class MouseInputGeometryTests: XCTestCase {
    func testWideVideoIsLetterboxedInSquareView() {
        let geometry = MouseInputGeometry(
            viewSize: CGSize(width: 1000, height: 1000),
            streamWidth: 1920,
            streamHeight: 1080
        )
        let rect = geometry.videoRect
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 218.75, accuracy: 0.001)
        XCTAssertEqual(rect.width, 1000, accuracy: 0.001)
        XCTAssertEqual(rect.height, 562.5, accuracy: 0.001)
    }

    func testTallVideoIsPillarboxedInSquareView() {
        let geometry = MouseInputGeometry(
            viewSize: CGSize(width: 1000, height: 1000),
            streamWidth: 1080,
            streamHeight: 1920
        )
        let rect = geometry.videoRect
        XCTAssertEqual(rect.minX, 218.75, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(rect.width, 562.5, accuracy: 0.001)
        XCTAssertEqual(rect.height, 1000, accuracy: 0.001)
    }

    func testMappingUsesTheVideoRectAndClampsToItsEdges() {
        let geometry = MouseInputGeometry(
            viewSize: CGSize(width: 1000, height: 1000),
            streamWidth: 1920,
            streamHeight: 1080
        )
        XCTAssertEqual(geometry.streamPoint(for: CGPoint(x: 500, y: 500))?.x, 960)
        XCTAssertEqual(geometry.streamPoint(for: CGPoint(x: 500, y: 500))?.y, 540)

        // In the letterbox above the video, the pointer maps to the top edge.
        XCTAssertEqual(geometry.streamPoint(for: CGPoint(x: 500, y: 10))?.y, 0)
        // Beyond the right edge, it maps to the last host pixel.
        XCTAssertEqual(geometry.streamPoint(for: CGPoint(x: 5000, y: 500))?.x, 1919)
        XCTAssertEqual(geometry.streamPoint(for: CGPoint(x: 5000, y: 5000))?.y, 1079)
    }

    func testZeroSizedInputHasNoVideoRect() {
        let geometry = MouseInputGeometry(
            viewSize: .zero,
            streamWidth: 1920,
            streamHeight: 1080
        )
        XCTAssertEqual(geometry.videoRect, .zero)
        XCTAssertNil(geometry.streamPoint(for: .zero))
    }
}
