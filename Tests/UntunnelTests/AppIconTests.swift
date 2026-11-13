import AppKit
import Foundation
import Testing

@Test
func appIconSetContainsEveryRequiredResolution() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 1 ? "" : "@2x"
            let file = root.appendingPathComponent(
                "Support/AppIcon.iconset/icon_\(size)x\(size)\(suffix).png")
            let image = try #require(NSBitmapImageRep(data: Data(contentsOf: file)))
            #expect(image.pixelsWide == size * scale)
            #expect(image.pixelsHigh == size * scale)
        }
    }
}
