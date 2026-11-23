import AppKit
import Metal
import Syphon

@MainActor
final class SyphonOutput {
    private struct Slot {
        var texture: any MTLTexture
        var lastUse: (any MTLCommandBuffer)?
        var baseGeneration: Int?
        var draftBounds: CGRect = .null

        var available: Bool {
            guard let lastUse else { return true }
            return lastUse.status == .completed || lastUse.status == .error
        }
    }

    private struct FrameBase: Equatable {
        var source: ObjectIdentifier?
        var page: Int
        var marksRevision: Int
    }

    private weak var session: Session?
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let server: SyphonMetalServer
    private var timer: DispatchSourceTimer?
    private var settings = OutputSettings()
    private var slots: [Slot] = []
    private var baseline: CGContext?
    private var canvas: CGContext?
    private var frameBase: FrameBase?
    private var baseGeneration = 0
    private var canvasDraftBounds: CGRect = .null
    private var lastTexture: Int?
    private var lastRevision: Int?
    private var inFlight: [any MTLCommandBuffer] = []

    init(session: Session, name: String = "Audience") throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ProjectError("这台 Mac 无法创建用于 OBS 输出的 Metal 设备。")
        }
        guard let server = SyphonMetalServer(name: name, device: device, options: nil) else {
            throw ProjectError("无法启动 Syphon 画面源。")
        }
        self.session = session
        self.device = device
        self.queue = queue
        self.server = server
    }

    func configure(_ settings: OutputSettings) {
        timer?.cancel()
        self.settings = settings
        slots = []
        baseline = nil
        canvas = nil
        frameBase = nil
        canvasDraftBounds = .null
        lastTexture = nil
        lastRevision = nil
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / settings.fps),
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        server.stop()
    }

    private func tick() {
        guard let session else { return }
        session.setOBSConnected(server.hasClients)
        guard server.hasClients else { return }

        inFlight.removeAll { $0.status == .completed || $0.status == .error }
        guard inFlight.count < 3, let command = queue.makeCommandBuffer() else { return }

        if lastRevision != session.revision || lastTexture == nil {
            guard let index = nextSlot(), updateFrame(session: session, slot: index) else { return }
            lastTexture = index
            lastRevision = session.revision
        }
        guard let index = lastTexture else { return }
        slots[index].lastUse = command
        // The bitmap is top-down. OBS samples Syphon's shared surface bottom-up.
        server.publishFrameTexture(slots[index].texture, on: command,
                                   imageRegion: CGRect(origin: .zero, size: settings.size), flipped: true)
        inFlight.append(command)
        command.commit()
    }

    private func updateFrame(session: Session, slot index: Int) -> Bool {
        if baseline == nil { baseline = makeBitmap() }
        if canvas == nil { canvas = makeBitmap() }
        guard let baseline, let canvas, let baseBytes = baseline.data, let canvasBytes = canvas.data else {
            return false
        }

        let frame = CGRect(origin: .zero, size: settings.size)
        let source = session.source
        let page = settings.pageRect(for: source?.geometries[session.index].size ?? .zero)
        let draft = session.draft
        let draftPath = page.isEmpty ? nil : draft?.path(in: page)
        var draftBounds = CGRect.null
        if let draftPath, !draftPath.isEmpty {
            draftBounds = draftPath.boundingBoxOfPath.insetBy(dx: -2, dy: -2).integral
                .intersection(page.integral).intersection(frame)
        }

        let base = FrameBase(source: source.map(ObjectIdentifier.init), page: session.index,
                             marksRevision: session.baseMarksRevision)
        if frameBase != base {
            paintOutput(source: source, index: session.index, marks: session.baseMarks, settings: settings,
                        in: baseline, bounds: frame, scale: 1)
            baseline.flush()
            // Both bitmaps share the same top-down layout and row stride.
            memcpy(canvasBytes, baseBytes, canvas.bytesPerRow * settings.height)
            frameBase = base
            baseGeneration &+= 1
        } else {
            let dirty = canvasDraftBounds.union(draftBounds)
            if !dirty.isEmpty {
                let start = Int(dirty.minY)
                let xOffset = Int(dirty.minX) * 4
                let rowLength = Int(dirty.width) * 4
                for y in start..<Int(dirty.maxY) {
                    let offset = y * canvas.bytesPerRow + xOffset
                    memcpy(canvasBytes.advanced(by: offset), baseBytes.advanced(by: offset), rowLength)
                }
            }
        }
        if !draftBounds.isEmpty, let draft, let draftPath {
            canvas.saveGState()
            canvas.clip(to: page)
            canvas.setFillColor(draft.color.cgColor)
            canvas.addPath(draftPath)
            canvas.fillPath()
            canvas.restoreGState()
            canvas.flush()
        }
        canvasDraftBounds = draftBounds

        // A recycled texture may hold a different draft than the CPU bitmap.
        let dirty = slots[index].baseGeneration == baseGeneration ? slots[index].draftBounds.union(draftBounds) : frame
        if !dirty.isEmpty {
            let x = Int(dirty.minX)
            let y = Int(dirty.minY)
            slots[index].texture.replace(region: MTLRegionMake2D(x, y, Int(dirty.width), Int(dirty.height)),
                                         mipmapLevel: 0, withBytes: canvasBytes.advanced(by: y * canvas.bytesPerRow + x * 4),
                                         bytesPerRow: canvas.bytesPerRow)
        }
        slots[index].baseGeneration = baseGeneration
        slots[index].draftBounds = draftBounds
        return true
    }

    private func makeBitmap() -> CGContext? {
        let context = CGContext(data: nil, width: settings.width, height: settings.height,
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                                            CGImageAlphaInfo.premultipliedFirst.rawValue)
        context?.translateBy(x: 0, y: CGFloat(settings.height))
        context?.scaleBy(x: 1, y: -1)
        return context
    }

    private func nextSlot() -> Int? {
        if let existing = slots.firstIndex(where: \.available) { return existing }
        guard slots.count < 3 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: settings.width, height: settings.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        slots.append(Slot(texture: texture))
        return slots.count - 1
    }
}
