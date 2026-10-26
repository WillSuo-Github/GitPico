import AppKit
import CryptoKit
import GitCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private struct BinaryPreviewRequest: Equatable {
    let path: String
    let original: String?
    let left: BinaryFileSource
    let right: BinaryFileSource
    let version: Date?
}
private struct BinaryPreviewSide: Sendable {
    let exists: Bool
    let bytes: Int
    let digest: String
    let thumbnail: Data?
    let dimensions: String?
    nonisolated static func make(_ data: Data?) -> Self {
        guard let data else { return Self(exists: false, bytes: 0, digest: "", thumbnail: nil, dimensions: nil) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000, height <= 100_000, width <= 100_000_000 / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else {
            return Self(exists: true, bytes: data.count, digest: digest, thumbnail: nil, dimensions: nil)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return Self(exists: true, bytes: data.count, digest: digest, thumbnail: nil, dimensions: "\(width) × \(height)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        let png = CGImageDestinationFinalize(destination) ? output as Data : nil
        return Self(exists: true, bytes: data.count, digest: digest, thumbnail: png, dimensions: "\(width) × \(height)")
    }
}

struct BinaryComparisonView: View {
    let repository: GitRepository
    let path: String
    var originalPath: String? = nil
    let left: BinaryFileSource
    let right: BinaryFileSource
    var version: Date? = nil
    @State private var sides: [BinaryPreviewSide] = []
    @State private var failure: String?
    @State private var overlay = false
    @State private var opacity = 0.5
    static func isImageCandidate(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif", "ico"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let failure { Text(failure).foregroundStyle(.secondary).textSelection(.enabled) }
                else if sides.count == 2 {
                    let before = sides[0], after = sides[1]
                    if before.thumbnail != nil || after.thumbnail != nil {
                        Picker("Image comparison", selection: $overlay) { Text("Side by Side").tag(false); Text("Overlay").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
                        if overlay {
                            ZStack { preview(before); preview(after).opacity(opacity) }.frame(height: 340).frame(maxWidth: .infinity)
                            HStack { Text(left.title); Slider(value: $opacity, in: 0...1).accessibilityLabel("After image opacity"); Text(right.title) }
                        } else {
                            HStack(alignment: .top, spacing: 16) {
                                VStack { Text(left.title).font(.headline); preview(before) }.frame(maxWidth: .infinity)
                                VStack { Text(right.title).font(.headline); preview(after) }.frame(maxWidth: .infinity)
                            }.frame(height: 340)
                        }
                        Text("Preview uses the first frame, scaled to at most 2048 pixels. Original dimensions appear below.").font(.caption).foregroundStyle(.secondary)
                    } else { Label("Binary file comparison", systemImage: "doc.fill").font(.headline) }
                    HStack(alignment: .top, spacing: 16) { information(before, title: left.title); information(after, title: right.title) }
                    Text(before.exists && after.exists && before.digest == after.digest ? "The file contents are identical." : "The file contents differ.").font(.callout).foregroundStyle(.secondary)
                } else { ProgressView("Loading file comparison…").frame(maxWidth: .infinity).padding(30) }
            }.padding(16)
        }.task(id: BinaryPreviewRequest(path: path, original: originalPath, left: left, right: right, version: version)) {
            sides = []; failure = nil
            do {
                let comparison = try await repository.binaryComparison(path: path, originalPath: originalPath, left: left, right: right)
                let result = await Task.detached(priority: .userInitiated) { [BinaryPreviewSide.make(comparison.left), BinaryPreviewSide.make(comparison.right)] }.value
                try Task.checkCancellation(); sides = result
            } catch is CancellationError { }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
    @ViewBuilder private func preview(_ side: BinaryPreviewSide) -> some View {
        if let bytes = side.thumbnail, let image = NSImage(data: bytes) {
            Image(nsImage: image).resizable().scaledToFit().accessibilityLabel(side.dimensions.map { "Image, " + $0 } ?? "Image preview")
        } else {
            ContentUnavailableView(side.exists ? "No Image Preview" : "File Absent", systemImage: side.exists ? "doc" : "minus.circle")
        }
    }
    private func information(_ side: BinaryPreviewSide, title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(side.exists ? ByteCountFormatter.string(fromByteCount: Int64(side.bytes), countStyle: .file) : "Absent").foregroundStyle(.secondary)
            if let dimensions = side.dimensions { Text(dimensions).font(.caption).foregroundStyle(.secondary) }
            if side.exists { Text("SHA-256 " + side.digest).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
