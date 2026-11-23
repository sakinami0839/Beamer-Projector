import AppKit
import Metal
import Syphon
import XCTest
@testable import BeamerProjector

private final class Frames: @unchecked Sendable {
    private let lock = NSLock()
    private var frameCount = 0

    func count() -> Int { lock.withLock { frameCount } }
    func received() { lock.withLock { frameCount += 1 } }
}

final class SyphonTests: XCTestCase {
    @MainActor
    func testHeadlessSyphonOutput() throws {
        let testID = UUID().uuidString
        let source = try PDFFixture.temporaryPresentation()
        defer { try? FileManager.default.removeItem(at: source) }
        let session = Session()
        session.open(source)
        guard session.source?.count == 22, let device = MTLCreateSystemDefaultDevice() else {
            throw ProjectError("Could not open the sample or access Metal.")
        }
        let serverName = "Beamer Projector Test " + testID
        let publisher = try SyphonOutput(session: session, name: serverName)
        defer { publisher.stop() }
        let initial = OutputSettings()
        session.updateOutput(initial, persist: false)
        publisher.configure(initial)
        let directory = SyphonServerDirectory.shared()
        var description: [String: NSCoding]?
        let timeout = Date().addingTimeInterval(5)
        while description == nil && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            description = directory.servers.first { $0[SyphonServerDescriptionNameKey] as? String == serverName }
        }
        guard let description else { throw ProjectError("Syphon server did not appear.") }
        let frames = Frames()
        let client = SyphonMetalClient(serverDescription: description, device: device, options: nil) { _ in
            frames.received()
        }
        defer { client.stop() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let background = client.newFrameImage(), background.width == 1920, background.height == 1080 else {
            throw ProjectError("Syphon did not deliver a 1920×1080 frame.")
        }
        let base = obsPixel(background, x: 960, y: 270)
        let before = frames.count()
        let start = ProcessInfo.processInfo.systemUptime
        let red = InkColor(red: 1, green: 0, blue: 0)
        for i in 0..<240 {
            let mark = Mark(kind: .pen, width: 0.04, color: red, paths: [[
                InkPoint(x: 0.40, y: 0.25, pressure: 0.15),
                InkPoint(x: 0.50, y: 0.25, pressure: 1),
                InkPoint(x: 0.55 + Double(i % 50) / 300, y: 0.25, pressure: 0.4),
            ]])
            session.setDraft(mark)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
        }
        let fps = Double(frames.count() - before) / (ProcessInfo.processInfo.systemUptime - start)
        guard let ink = client.newFrameImage() else { throw ProjectError("The updated frame did not arrive.") }
        let marked = obsPixel(ink, x: 960, y: 270)
        let opposite = obsPixel(ink, x: 960, y: 810)
        print("1080p, live updates \(String(format: "%.1f", fps)) received fps, BGRA \(base) → \(marked), opposite \(opposite)")
        guard marked[2] > 190, marked[1] < 50, opposite[2] < 150,
              fps >= 55, !session.projectorOpen else {
            throw ProjectError("Unexpected Syphon output: \(fps) fps, pen \(marked), opposite \(opposite).")
        }

        let uhd = OutputSettings(width: 3840, height: 2160, fps: 60)
        session.setDraft(nil)
        let blue = InkColor(red: 0, green: 0, blue: 1)
        session.setWorking((0..<48).map { index in
            let row = 0.63 + Double(index) * 0.006
            let samples = (0..<96).map { sample in
                let t = Double(sample) / 95
                return InkPoint(x: 0.12 + t * 0.76, y: row + sin(t * 12) * 0.007, pressure: 0.4 + t * 0.5)
            }
            return Mark(kind: .pen, width: 0.007, color: blue, paths: [samples])
        })
        session.updateOutput(uhd, persist: false)
        publisher.configure(uhd)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let clean = try XCTUnwrap(client.newFrameImage())
        XCTAssertEqual(clean.width, uhd.width)
        XCTAssertEqual(clean.height, uhd.height)
        let geometry = try XCTUnwrap(session.source?.geometries[session.index])
        let page = uhd.pageRect(for: geometry.size)
        func pixel(_ texture: any MTLTexture, at point: InkPoint) -> [UInt8] {
            let position = point.inRect(page)
            return obsPixel(texture, x: Int(position.x), y: Int(position.y))
        }
        func isRed(_ color: [UInt8]) -> Bool { color[2] > 230 && color[1] < 50 && color[0] < 50 }

        let firstPoint = InkPoint(x: 0.2, y: 0.28, pressure: 0.3)
        let movedPoint = InkPoint(x: 0.73, y: 0.54)
        let historyPoint = InkPoint(x: 0.12, y: 0.63)
        let beforeDraft = pixel(clean, at: firstPoint)
        let historyPixel = pixel(clean, at: historyPoint)
        XCTAssertGreaterThan(historyPixel[0], 230)
        XCTAssertLessThan(historyPixel[2], 50)
        var stroke = Mark(kind: .fountainPen, width: 0.016, color: red, paths: [[firstPoint]])
        let samples = (1...180).map { i in
            let t = Double(i) / 180
            return InkPoint(x: firstPoint.x + t * 0.58, y: firstPoint.y + sin(t * 10) * 0.075,
                            pressure: 0.52 + sin(t * 9) * 0.43)
        }
        let uhdBefore = frames.count()
        let uhdStart = ProcessInfo.processInfo.systemUptime
        for (i, sample) in samples.enumerated() {
            stroke.paths[0].append(sample)
            session.setDraft(stroke)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
            if i > 0, i.isMultiple(of: 30) {
                let liveFrame = try XCTUnwrap(client.newFrameImage())
                XCTAssertTrue(isRed(pixel(liveFrame, at: samples[i - 8])), "The stroke stalled near sample \(i).")
                XCTAssertFalse(isRed(pixel(liveFrame, at: samples[i + 20])))
            }
        }
        let uhdFPS = Double(frames.count() - uhdBefore) / (ProcessInfo.processInfo.systemUptime - uhdStart)
        print("4K, fountain pen over 48 existing strokes: \(String(format: "%.1f", uhdFPS)) received fps")
        XCTAssertGreaterThanOrEqual(uhdFPS, 55)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let drawn = try XCTUnwrap(client.newFrameImage())
        XCTAssertTrue(isRed(pixel(drawn, at: firstPoint)))
        XCTAssertTrue(isRed(pixel(drawn, at: stroke.paths[0][140])))
        XCTAssertTrue(isRed(pixel(drawn, at: stroke.paths[0][180])))
        XCTAssertEqual(pixel(drawn, at: historyPoint), historyPixel)

        stroke.paths = [[movedPoint]]
        session.setDraft(stroke)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let replaced = try XCTUnwrap(client.newFrameImage())
        XCTAssertEqual(pixel(replaced, at: firstPoint), beforeDraft)
        XCTAssertTrue(isRed(pixel(replaced, at: movedPoint)))
        XCTAssertEqual(pixel(replaced, at: historyPoint), historyPixel)

        session.setDraft(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let cleared = try XCTUnwrap(client.newFrameImage())
        XCTAssertFalse(isRed(pixel(cleared, at: movedPoint)))
        XCTAssertEqual(pixel(cleared, at: historyPoint), historyPixel)

        var custom = OutputSettings(width: 1440, height: 1080, fps: 60)
        custom.left = 48
        custom.top = 300
        publisher.configure(custom)
        session.updateOutput(custom, persist: false)
        session.cancelGesture()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        guard let padded = client.newFrameImage(), padded.width == 1440, padded.height == 1080,
              obsPixel(padded, x: 720, y: 200) == [0, 0, 0, 255],
              obsPixel(padded, x: 18, y: 540) == [0, 0, 0, 255],
              obsPixel(padded, x: 720, y: 1000) != [0, 0, 0, 255] else {
            throw ProjectError("The 4:3 output or asymmetric margins were not preserved in OBS.")
        }
        print("Headless Syphon frame and output margins passed")
    }

    private func obsPixel(_ texture: any MTLTexture, x: Int, y: Int) -> [UInt8] {
        var bytes: [UInt8] = [0, 0, 0, 0]
        // OBS's Syphon source maps the top of the frame to the last IOSurface row.
        texture.getBytes(&bytes, bytesPerRow: 4,
                         from: MTLRegionMake2D(x, texture.height - 1 - y, 1, 1), mipmapLevel: 0)
        return bytes
    }
}
