//
//  StreamPictureGeometryTests.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import XCTest
@testable import MoonlightVision

final class StreamPictureGeometryTests: XCTestCase {
    func testStandardModeUsesFullFrameAspect() {
        XCTAssertEqual(
            StreamPictureGeometry.aspectRatio(width: 3840, height: 1080, mode: .standard2D),
            32.0 / 9.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            StreamPictureGeometry.aspectRatio(width: 1920, height: 1080, mode: .standard2D),
            16.0 / 9.0,
            accuracy: 0.0001
        )
    }

    func testSideBySideUsesHalfWidthFor32by9Frames() {
        XCTAssertEqual(
            StreamPictureGeometry.aspectRatio(width: 3840, height: 1080, mode: .sideBySide3D),
            16.0 / 9.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            StreamPictureGeometry.aspectRatio(width: 5120, height: 1440, mode: .sideBySide3D),
            16.0 / 9.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            StreamPictureGeometry.aspectRatio(width: 2560, height: 720, mode: .sideBySide3D),
            16.0 / 9.0,
            accuracy: 0.0001
        )
    }

    func testSideBySideLeavesOtherFramesAlone() {
        XCTAssertEqual(
            StreamPictureGeometry.aspectRatio(width: 1920, height: 1080, mode: .sideBySide3D),
            16.0 / 9.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            StreamPictureGeometry.aspectRatio(width: 3440, height: 1440, mode: .sideBySide3D),
            3440.0 / 1440.0,
            accuracy: 0.0001
        )
    }

    func testDegenerateSizeFallsBackToSixteenByNine() {
        XCTAssertEqual(
            StreamPictureGeometry.aspectRatio(width: 0, height: 0, mode: .standard2D),
            16.0 / 9.0,
            accuracy: 0.0001
        )
    }

    func testSideBySideFrameDetection() {
        XCTAssertTrue(StreamPictureGeometry.isSideBySideFrame(width: 3840, height: 1080))
        XCTAssertTrue(StreamPictureGeometry.isSideBySideFrame(width: 5120, height: 1440))
        XCTAssertFalse(StreamPictureGeometry.isSideBySideFrame(width: 1920, height: 1080))
        XCTAssertFalse(StreamPictureGeometry.isSideBySideFrame(width: 3440, height: 1440))
        XCTAssertFalse(StreamPictureGeometry.isSideBySideFrame(width: 0, height: 1080))
    }

    func testDisplayedFractionCompressesSbSPicture() {
        let sbs = StreamInputSize(
            hostWidth: 3840,
            hostHeight: 1080,
            displayedWidth: 1920,
            displayedHeight: 1080
        )
        XCTAssertEqual(sbs.displayedFractionX, 0.5, accuracy: 0.0001)

        let standard = StreamInputSize(
            hostWidth: 1920,
            hostHeight: 1080,
            displayedWidth: 1920,
            displayedHeight: 1080
        )
        XCTAssertEqual(standard.displayedFractionX, 1.0, accuracy: 0.0001)
    }
}
