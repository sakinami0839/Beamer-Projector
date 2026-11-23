import Foundation

enum PDFFixture {
    static func temporaryPresentation() throws -> URL {
        let id = UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appending(path: "Beamer-Test-\(id).pdf")
        var data = presentation()
        data.append(contentsOf: "% Fixture \(id)\n".utf8)
        try data.write(to: url)
        return url
    }

    private static func presentation() -> Data {
        let pageCount = 22
        let firstPage = 5
        let sections = [1, 5, 8, 15, 21]
        let firstSection = firstPage + pageCount
        let firstLink = firstSection + sections.count
        let pageReferences = (firstPage..<(firstPage + pageCount)).map { "\($0) 0 R" }.joined(separator: " ")
        let body = """
            0.13 0.15 0.17 rg 0 0 1600 900 re f
            0.20 0.33 0.63 rg 70 745 240 60 re f
            0.28 0.43 0.51 rg 70 118 320 32 re f

            """
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R >>",
            "<< /Type /Pages /Kids [\(pageReferences)] /Count \(pageCount) /MediaBox [0 0 1600 900] /Resources << >> >>",
            stream(body),
            "<< /Type /Outlines /First \(firstSection) 0 R /Last \(firstLink - 1) 0 R /Count \(sections.count) >>",
        ]
        var links: [String] = []
        for _ in 0..<pageCount {
            var references: [String] = []
            for destination in 0..<min(pageCount, 480 - links.count) {
                let x = 40 + destination * 60
                references.append("\(firstLink + links.count) 0 R")
                links.append("<< /Type /Annot /Subtype /Link /Rect [\(x) 840 \(x + 50) 870] /Border [0 0 0] /Dest [\(firstPage + destination) 0 R /Fit] >>")
            }
            let annotations = references.joined(separator: " ")
            objects.append("<< /Type /Page /Parent 2 0 R /Contents 3 0 R /Annots [\(annotations)] >>")
        }
        for (index, page) in sections.enumerated() {
            let entry = firstSection + index
            let previous = index > 0 ? " /Prev \(entry - 1) 0 R" : ""
            let next = index + 1 < sections.count ? " /Next \(entry + 1) 0 R" : ""
            objects.append("<< /Title (Section \(index + 1)) /Parent 4 0 R\(previous)\(next) /Dest [\(firstPage + page) 0 R /Fit] >>")
        }
        return encode(objects + links)
    }

    static func repeatedLabels() -> Data {
        let body = "1 0 0 rg 20 30 40 40 re f 0 0 1 rg 200 130 40 40 re f\n"
        return encode([
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /P <FEFF91CD> >> 1 << /P <FEFF91CD> >> 2 << /S /D /St 3 >>] >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 /MediaBox [0 0 260 200] /Resources << >> >>",
            "<< /Type /Page /Parent 2 0 R /CropBox [20 30 240 170] /Contents 6 0 R >>",
            "<< /Type /Page /Parent 2 0 R /CropBox [20 30 240 170] /Rotate 90 /Contents 6 0 R >>",
            "<< /Type /Page /Parent 2 0 R /Contents 6 0 R >>",
            stream(body),
        ])
    }

    private static func stream(_ body: String) -> String {
        "<< /Length \(body.utf8.count) >>\nstream\n\(body)endstream"
    }

    private static func encode(_ objects: [String]) -> Data {
        var data = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.utf8.count)
            data += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = data.utf8.count
        data += "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { data += String(format: "%010d 00000 n \n", offset) }
        data += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(data.utf8)
    }
}
