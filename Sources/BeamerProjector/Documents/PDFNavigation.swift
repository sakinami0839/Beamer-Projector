import PDFKit

struct OutlineEntry {
    let id: String
    let title: String
    let page: Int?
}

struct NavigationEntry: Identifiable {
    let id: String
    let title: String
    let page: Int?
    let children: [NavigationEntry]
    let isPage: Bool

    var branches: [String] {
        children.isEmpty ? [] : [id] + children.flatMap(\.branches)
    }

    static func tree(from outline: [OutlineEntry], pageCount: Int) -> [Self] {
        let destinations = Set(outline.compactMap(\.page)).sorted()
        let byParent = Dictionary(grouping: outline) { entry in
            String(entry.id[..<(entry.id.lastIndex(of: ".") ?? entry.id.startIndex)])
        }
        func pageEntry(_ index: Int, parent: String) -> Self {
            Self(id: "\(parent)/page-\(index)", title: "第 \(index + 1) 页", page: index, children: [], isPage: true)
        }
        func branch(_ entry: OutlineEntry) -> Self {
            var children = byParent[entry.id, default: []].map(branch)
            if children.isEmpty, let start = entry.page {
                let end = destinations.first(where: { $0 > start }) ?? pageCount
                if end - start > 1 {
                    children = (start..<end).map { pageEntry($0, parent: entry.id) }
                }
            }
            return Self(id: entry.id, title: entry.title, page: entry.page, children: children, isPage: false)
        }
        let leading = (0..<(destinations.first ?? 0)).map { pageEntry($0, parent: "") }
        return leading + byParent["", default: []].map(branch)
    }
}

extension OutlineEntry {
    static func read(from document: PDFDocument) -> [OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        var result: [OutlineEntry] = []
        func walk(_ parent: PDFOutline, prefix: String) {
            for index in 0..<parent.numberOfChildren {
                guard let item = parent.child(at: index) else { continue }
                let path = "\(prefix).\(index)"
                let target = item.destination ?? (item.action as? PDFActionGoTo)?.destination
                let page = target?.page.map { document.index(for: $0) }
                result.append(OutlineEntry(id: path, title: item.label ?? "章节",
                    page: page.flatMap { (0..<document.pageCount).contains($0) ? $0 : nil }))
                walk(item, prefix: path)
            }
        }
        walk(root, prefix: "")
        return result
    }
}
