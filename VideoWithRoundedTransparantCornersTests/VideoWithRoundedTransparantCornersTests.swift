import XCTest
@testable import VideoWithRoundedTransparantCorners

final class VideoWithRoundedTransparantCornersTests: XCTestCase {
    func testExample() async throws {
        let video = Bundle(for: VideoWithRoundedTransparantCornersTests.self).url(forResource: "a", withExtension: ".mp4")!
        let error = await VideoEditor().export(url: video, outputDir: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "temp.mov"), size: .init(width: 1000, height: 1000))

        XCTAssertNil(error)
    }
}
