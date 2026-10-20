import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 앱이 소스에 쓰는 파일을 모아 두는 Documents/Media.
/// 고른 파일의 원래 위치는 앱을 다시 켜면 접근 권한이 사라져서 여기로 복사해 쓴다.
enum MediaFolder {
    static var url: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// base.ext, "base 2.ext", … 중 아직 없는 경로
    static func uniqueURL(base: String, ext: String) -> URL {
        let directory = url
        var destination = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return destination
    }
}

/// 사진 보관함의 사진을 이미지 소스가 읽을 수 있는 파일로 저장한다 (계획 D14).
/// 이미지 디코더(FFmpeg의 png·mjpeg·gif·webp·bmp·targa)는 HEIC를 못 읽고 색 프로필도 보지 않으므로
/// 그 밖의 형식, sRGB가 아닌 사진(아이폰의 Display P3 등), 너무 큰 사진은 방향을 바로 세운 sRGB JPEG로 바꾼다
/// (투명한 부분이 있으면 PNG).
enum PhotoImport {
    /// 긴 변이 이보다 크면 줄인다. 4800만 화소 사진 한 장이 텍스처로 약 200MB라서
    static let maxSide = 4096

    private static let readable: [UTType] = [.jpeg, .png, .gif, .webP]

    /// 고른 순서대로 저장한 파일들. 못 읽은 항목은 빼고 로그에 남긴다.
    static func importItems(_ items: [PhotosPickerItem]) async -> [URL] {
        let stamp = Self.stamp()
        var urls: [URL] = []
        for (index, item) in items.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    appLog("photo import: no data for item \(index + 1)")
                    continue
                }
                if let url = save(data, base: items.count > 1 ? "사진 \(stamp)-\(index + 1)" : "사진 \(stamp)") {
                    urls.append(url)
                }
            } catch {
                appLog("photo import: item \(index + 1) failed: \(error.localizedDescription)")
            }
        }
        return urls
    }

    /// 그대로 읽을 수 있으면 그대로, 아니면 바꿔서 Media에 저장한다
    static func save(_ data: Data, base: String) -> URL? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let typeIdentifier = CGImageSourceGetType(source), let type = UTType(typeIdentifier as String)
        else {
            appLog("photo import: unreadable image data (\(data.count) bytes)")
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let profile = properties[kCGImagePropertyProfileName as String] as? String
        let orientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1

        // GIF는 움직이는 그림일 수 있어 그대로 둔다
        let keep =
            type.conforms(to: .gif)
            || (readable.contains { type.conforms(to: $0) } && max(width, height) <= maxSide
                && (profile.map { $0.contains("sRGB") } ?? true))
        if keep {
            let url = MediaFolder.uniqueURL(base: base, ext: type.preferredFilenameExtension ?? "jpg")
            do {
                try data.write(to: url)
                appLog("photo import: kept \(type.identifier) \(width)x\(height) as \(url.lastPathComponent)")
                return url
            } catch {
                appLog("photo import: write failed: \(error.localizedDescription)")
                return nil
            }
        }

        // 방향(EXIF)을 적용하고 긴 변을 maxSide 이하로
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxSide),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let converted = sRGB(image)
        else {
            appLog("photo import: decode failed (\(type.identifier) \(width)x\(height))")
            return nil
        }

        let opaque = isOpaque(converted)
        let outputType: UTType = opaque ? .jpeg : .png
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, outputType.identifier as CFString, 1, nil) else {
            return nil
        }
        let outputOptions: [CFString: Any] = opaque ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(destination, converted, outputOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            appLog("photo import: encode failed")
            return nil
        }

        let url = MediaFolder.uniqueURL(base: base, ext: opaque ? "jpg" : "png")
        do {
            try (output as Data).write(to: url)
            appLog(
                "photo import: converted \(type.identifier) \(width)x\(height) (orientation \(orientation), \(profile ?? "no profile")) to \(url.lastPathComponent) \(converted.width)x\(converted.height)"
            )
            return url
        } catch {
            appLog("photo import: write failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// 8비트 sRGB로 다시 그린다 (P3·16비트 HDR 사진도 디코더가 그대로 읽는 색으로)
    private static func sRGB(_ image: CGImage) -> CGImage? {
        let opaque = isOpaque(image)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: true
        default: false
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }
}

/// 사진 보관함에서 고르는 버튼. 고른 사진을 Media에 저장한 뒤 그 경로들을 넘긴다.
struct PhotoImportButton: View {
    let title: String
    let multiple: Bool
    let imported: ([URL]) -> Void

    @State private var selection: [PhotosPickerItem] = []
    @State private var importing = false

    var body: some View {
        PhotosPicker(selection: $selection, maxSelectionCount: multiple ? nil : 1, matching: .images) {
            if importing {
                ProgressView()
            } else {
                Text(title)
            }
        }
        .disabled(importing)
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            importing = true
            Task {
                let urls = await PhotoImport.importItems(items)
                await MainActor.run {
                    importing = false
                    selection = []
                    if !urls.isEmpty { imported(urls) }
                }
            }
        }
    }
}
