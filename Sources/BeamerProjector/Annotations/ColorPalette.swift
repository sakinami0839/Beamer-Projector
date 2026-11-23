import SwiftUI

struct HexPalette: View {
    var color: InkColor
    let select: (InkColor) -> Void
    @State private var hue: CGFloat = 0
    @State private var saturation: CGFloat = 1
    @State private var brightness: CGFloat = 1
    @State private var field = ""

    var body: some View {
        VStack(spacing: 9) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                    LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    Circle()
                        .strokeBorder(.white, lineWidth: 2)
                        .frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.7), radius: 1)
                        .position(x: min(geometry.size.width - 6, max(6, geometry.size.width * saturation)),
                                  y: min(geometry.size.height - 6, max(6, geometry.size.height * (1 - brightness))))
                }
                .clipShape(.rect(cornerRadius: 5))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    saturation = min(1, max(0, value.location.x / geometry.size.width))
                    brightness = min(1, max(0, 1 - value.location.y / geometry.size.height))
                    updateFromPalette()
                })
                .accessibilityHidden(true)
            }
            .frame(height: 104)
            hueSpectrum
            HStack {
                TextField("十六进制色值", text: $field, prompt: Text("#DB1F3B"))
                    .font(.body.monospaced())
                    .onSubmit(applyHex)
                Button("应用", action: applyHex).disabled(InkColor(hex: field) == nil)
            }
            .frame(height: 26)
        }
        .onAppear { updateControls(color) }
    }

    private var hueSpectrum: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 10
            let width = max(1, geometry.size.width - 2 * inset)
            let centerY = geometry.size.height / 2
            ZStack {
                Capsule()
                    .fill(LinearGradient(colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) },
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: width, height: 12)
                    .position(x: geometry.size.width / 2, y: centerY)
                Circle()
                    .fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .frame(width: 18, height: 18)
                    .position(x: inset + hue * width, y: centerY)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                selectHue(min(1, max(0, (value.location.x - inset) / width)))
            })
        }
        .frame(height: 26)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { hue }, set: selectHue), in: 0...1, step: 1.0 / 360) {
                Text("色相")
            }
            .accessibilityValue(Text("\(Int((hue * 360).rounded()))°"))
        }
    }

    private func selectHue(_ value: CGFloat) {
        hue = value
        updateFromPalette()
    }

    private func updateFromPalette() {
        let converted = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        let color = InkColor(red: converted.redComponent, green: converted.greenComponent, blue: converted.blueComponent)
        field = "#" + color.hex
        select(color)
    }

    private func applyHex() {
        guard let color = InkColor(hex: field) else { return }
        select(color)
        updateControls(color)
    }

    private func updateControls(_ color: InkColor) {
        let rgb = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        field = "#" + color.hex
    }
}

extension InkColor {
    init?(hex input: String) {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = raw.first == "#" ? String(raw.dropFirst()) : raw
        guard digits.utf8.count == 6,
              digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                  blue: Double(value & 255) / 255)
    }

    var hex: String {
        String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}
