import Foundation

struct AnnotationRecovery {
    let directory: URL

    func location(for source: PDFSource) -> URL {
        directory.appending(path: source.diskFingerprint + ".json")
    }

    func load(for source: PDFSource) -> [Int: [Mark]]? {
        guard let data = try? Data(contentsOf: location(for: source)),
              let saved = try? JSONDecoder().decode([Int: [Mark]].self, from: data) else { return nil }
        let groups = Set(source.groups)
        return saved.mapValues { $0.filter(\.isValid) }.filter { groups.contains($0.key) && !$0.value.isEmpty }
    }

    func write(_ marks: [Int: [Mark]], to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(marks).write(to: url, options: .atomic)
    }

    func remove(at url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }
}
