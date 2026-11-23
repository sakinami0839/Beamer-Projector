import CoreGraphics

struct OutputSettings: Codable, Equatable {
    var width = 1920
    var height = 1080
    var fps = 60
    var left = 0
    var right = 0
    var top = 0
    var bottom = 0

    var size: CGSize { CGSize(width: width, height: height) }

    var isValid: Bool {
        (16...4096).contains(width) && (16...4096).contains(height) &&
        width.isMultiple(of: 2) && height.isMultiple(of: 2) &&
        [30, 60].contains(fps) &&
        (0..<width).contains(left) && (0..<width).contains(right) && left + right < width &&
        (0..<height).contains(top) && (0..<height).contains(bottom) && top + bottom < height
    }

    func pageRect(for pageSize: CGSize) -> CGRect {
        aspectFit(pageSize, in: CGRect(x: left, y: top, width: width - left - right,
                                      height: height - top - bottom))
    }
}

struct OutputLayout {
    let canvas: CGRect
    let page: CGRect

    init(settings: OutputSettings, pageSize: CGSize, bounds: CGRect) {
        canvas = aspectFit(settings.size, in: bounds)
        let fitted = settings.pageRect(for: pageSize)
        let scale = canvas.width / CGFloat(settings.width)
        page = CGRect(x: canvas.minX + fitted.minX * scale, y: canvas.minY + fitted.minY * scale,
                      width: fitted.width * scale, height: fitted.height * scale)
    }
}

func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return .zero }
    let scale = min(rect.width / size.width, rect.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                  width: fitted.width, height: fitted.height)
}

func presenterBounds(_ bounds: CGRect) -> CGRect {
    bounds.insetBy(dx: min(16, bounds.width / 8), dy: min(16, bounds.height / 8))
}
