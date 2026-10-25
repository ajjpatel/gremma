import Foundation
import CryptoKit

/// Explicitly imported public demonstration footage. This manifest does not
/// supply activity answers, object labels, or occurrence dates to the model.
struct DemoVideoManifest: Decodable {
    struct Clip: Decodable {
        let filename: String
        let title: String
        let sourceURL: String
        let license: String
    }
    let clips: [Clip]

    /// Content identity survives a manifest reorder or a renamed source file.
    static func contentKey(for file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            digest.update(data: bytes)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func load(from directory: URL) throws -> DemoVideoManifest {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard !value.clips.isEmpty, value.clips.count <= 15 else {
            throw GremmaError.message("The demo import list is empty or too large.")
        }
        var names = Set<String>()
        var titles = Set<String>()
        for clip in value.clips {
            guard !clip.filename.isEmpty, clip.filename == URL(fileURLWithPath: clip.filename).lastPathComponent,
                  !clip.filename.contains(".."), ["mp4", "mov", "m4v"].contains(URL(fileURLWithPath: clip.filename).pathExtension.lowercased()),
                  !clip.title.isEmpty, clip.title.count <= 70, names.insert(clip.filename).inserted,
                  titles.insert(clip.title).inserted,
                  let source = URL(string: clip.sourceURL), source.scheme == "https", source.host != nil,
                  !clip.license.isEmpty else { throw GremmaError.message("A demo import entry is invalid.") }
        }
        return value
    }
}
