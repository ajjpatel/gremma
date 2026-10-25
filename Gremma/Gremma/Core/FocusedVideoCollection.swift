import Foundation

/// A user-selected set of recordings. Labels are UI metadata, never model evidence.
struct FocusedVideoCollection: Codable {
    struct Entry: Codable { let videoID: String; let title: String }
    let createdAt: Date
    let videos: [Entry]
    var videoIDs: Set<String> { Set(videos.map(\.videoID)) }
    func title(for id: String) -> String? { videos.first { $0.videoID == id }?.title }

    static func load() -> FocusedVideoCollection? {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("FocusCollection.json")),
              let value = try? decoder.decode(Self.self, from: data),
              (1...5).contains(value.videos.count), value.videoIDs.count == value.videos.count,
              value.videos.allSatisfy({ !$0.videoID.isEmpty && !$0.title.isEmpty && $0.title.count <= 80 }) else { return nil }
        return value
    }
}
