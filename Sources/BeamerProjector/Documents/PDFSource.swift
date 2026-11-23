import AppKit
import CryptoKit
import PDFKit

struct PageGeometry {
    let page: CGPDFPage

    var crop: CGRect { page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox)) }

    var size: CGSize {
        page.rotationAngle.isMultiple(of: 180)
            ? crop.size : CGSize(width: crop.height, height: crop.width)
    }

    // Native PDF coordinates are bottom-left. Every UI and annotation model uses top-left.
    func transform(to rect: CGRect) -> CGAffineTransform {
        let local = CGRect(origin: .zero, size: rect.size)
        let native = page.getDrawingTransform(.cropBox, rect: local, rotate: 0, preserveAspectRatio: false)
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: rect.minX, ty: rect.maxY)
        return native.concatenating(flip)
    }
}

final class PDFSource {
    let url: URL
    let fingerprint: String
    private(set) var diskFingerprint: String
    let pdf: PDFDocument
    let geometries: [PageGeometry]
    let labels: [String]
    let groups: [Int]
    let outline: [OutlineEntry]
    let embeddedMarks: [Int: [Mark]]
    private(set) lazy var navigation = NavigationEntry.tree(from: outline, pageCount: count)
    private let source: Data
    private let importedNames: [Int: Set<String>]
    private typealias CachedPage = (page: Int, size: CGSize, image: CGImage)
    private var pageCache: [CachedPage] = []
    private var thumbnailCache: [CachedPage] = []

    var count: Int { geometries.count }

    init(url: URL) throws {
        self.url = url
        let source = try Data(contentsOf: url)
        self.source = source
        guard let input = PDFDocument(data: source), !input.isLocked, input.pageCount > 0 else {
            throw ProjectError("请选择可以打开且至少包含一页的 PDF。")
        }
        let native = try NativePDF(source)
        let imported = try native.readMarks()
        importedNames = imported.names
        let document: PDFDocument
        if imported.names.isEmpty {
            document = input
        } else {
            try native.removeMarks(imported.names)
            guard let clean = try PDFDocument(data: native.data()), clean.pageCount == input.pageCount else {
                throw ProjectError("无法恢复导出 PDF 中的可编辑批注。")
            }
            document = clean
        }
        pdf = document
        fingerprint = Self.digest(of: source)
        diskFingerprint = fingerprint
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        let geometries = pages.compactMap { $0.pageRef }.map { PageGeometry(page: $0) }
        guard geometries.count == document.pageCount,
              geometries.allSatisfy({ $0.size.width.isFinite && $0.size.height.isFinite && $0.size.width > 0 && $0.size.height > 0 }) else {
            throw ProjectError("至少有一页缺少有效的页面尺寸。")
        }
        self.geometries = geometries
        let labelValues = pages.enumerated().map { $0.element.label ?? String($0.offset + 1) }
        labels = labelValues
        var groups: [Int] = []
        for index in pages.indices {
            let repeats = index > 0 && pages[index].label != nil && labelValues[index] == labelValues[index - 1]
            groups.append(repeats ? groups[index - 1] : index)
        }
        self.groups = groups
        var embedded: [Int: [Mark]] = [:]
        var seen: [Int: Set<UUID>] = [:]
        for page in pages.indices {
            let group = groups[page]
            for mark in imported.byPage[page, default: []] where seen[group, default: []].insert(mark.id).inserted {
                embedded[group, default: []].append(mark)
            }
        }
        embeddedMarks = embedded
        outline = OutlineEntry.read(from: document)
    }

    func link(at position: CGPoint, in rect: CGRect, page index: Int) -> Int? {
        guard rect.contains(position), let page = pdf.page(at: index) else { return nil }
        let nativePoint = position.applying(geometries[index].transform(to: rect).inverted())
        guard let link = page.annotations.first(where: { $0.type == "Link" && $0.bounds.contains(nativePoint) }),
              let destination = link.destination ?? (link.action as? PDFActionGoTo)?.destination,
              let target = destination.page else { return nil }
        let targetIndex = pdf.index(for: target)
        return (0..<count).contains(targetIndex) ? targetIndex : nil
    }

    func image(at index: Int, size requested: CGSize) -> CGImage? {
        let width = max(1, Int(requested.width.rounded()))
        let height = max(1, Int(requested.height.rounded()))
        let size = CGSize(width: width, height: height)
        let isThumbnail = max(width, height) <= 500
        if isThumbnail {
            return renderImage(index: index, size: size, cache: &thumbnailCache, limit: 44)
        }
        return renderImage(index: index, size: size, cache: &pageCache, limit: 7)
    }

    private func renderImage(index: Int, size: CGSize, cache: inout [CachedPage], limit: Int) -> CGImage? {
        if let hit = cache.firstIndex(where: { $0.page == index && $0.size == size }) {
            let entry = cache.remove(at: hit)
            cache.append(entry)
            return entry.image
        }
        guard let page = pdf.page(at: index), let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let geometry = geometries[index]
        context.scaleBy(x: size.width / geometry.size.width, y: size.height / geometry.size.height)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { return nil }
        cache.append((index, size, image))
        if cache.count > limit { cache.removeFirst() }
        return image
    }

    func export(marks: [Int: [Mark]], to output: URL) throws {
        guard output.standardizedFileURL.resolvingSymlinksInPath() != url.standardizedFileURL.resolvingSymlinksInPath()
        else { throw ProjectError("请选择与原课件不同的文件名。") }
        try annotatedData(marks: marks).write(to: output, options: .atomic)
    }

    func save(marks: [Int: [Mark]]) throws {
        let output = url.standardizedFileURL.resolvingSymlinksInPath()
        let data = try annotatedData(marks: marks)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: output, options: .forReplacing, error: &coordinationError) { target in
            do {
                guard try Self.digest(of: Data(contentsOf: target)) == diskFingerprint else {
                    throw ProjectError("原 PDF 已被其他程序修改。批注仍在当前窗口中，可以通过「导出批注 PDF」另存为副本。")
                }
                try data.write(to: target, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError { throw error }
        diskFingerprint = Self.digest(of: data)
    }

    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func annotatedData(marks: [Int: [Mark]]) throws -> Data {
        let native = try NativePDF(source)
        try native.removeMarks(importedNames)
        for (index, geometry) in geometries.enumerated() {
            for mark in marks[groups[index], default: []] {
                try native.append(mark, page: index, geometry: geometry)
            }
        }
        return try native.data()
    }
}
