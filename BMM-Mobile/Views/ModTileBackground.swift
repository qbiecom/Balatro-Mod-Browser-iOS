import SwiftUI

struct ModTileBackground: View {
    let colors: ModColors?
    let key: String
    let isMuted: Bool

    var body: some View {
        ZStack {
            RepeatingDiagonalStripes(first: palette.first, second: palette.second, stripeWidth: 11)

            // Keep disabled cards recognizable without letting the background compete with controls.
            if isMuted {
                Color.black.opacity(0.34)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(isMuted ? 0.08 : 0.16), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var palette: (first: Color, second: Color) {
        let pair = colors.flatMap { pair in
            ColorPair(first: pair.first, second: pair.second).isValid ? ColorPair(first: pair.first, second: pair.second) : nil
        } ?? ColorPair.lightFallback(for: key)
        return (Color(hex: pair.first), Color(hex: pair.second))
    }
}

private struct ColorPair {
    let first: String
    let second: String

    static func lightFallback(for key: String) -> ColorPair {
        let palette = [
            ColorPair(first: "#4F6367", second: "#425556"),
            ColorPair(first: "#AA778D", second: "#906577"),
            ColorPair(first: "#A2615E", second: "#89534F"),
            ColorPair(first: "#A48447", second: "#8B703C"),
            ColorPair(first: "#4F7869", second: "#436659"),
            ColorPair(first: "#728DBF", second: "#6177A3"),
            ColorPair(first: "#5D5E8F", second: "#4F4F78"),
            ColorPair(first: "#796E9E", second: "#655D86"),
            ColorPair(first: "#64825D", second: "#556E4E"),
            ColorPair(first: "#86A367", second: "#728A57"),
            ColorPair(first: "#748C8A", second: "#627775")
        ]
        guard !key.isEmpty else { return palette[0] }
        var hash = 0
        for scalar in key.unicodeScalars {
            hash = (hash &* 31) &+ Int(scalar.value)
        }
        return palette[abs(hash) % palette.count]
    }

    var isValid: Bool {
        Color.isValidHex(first) && Color.isValidHex(second)
    }
}

private extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard Self.isValidHex(value), let number = UInt64(value, radix: 16) else {
            self = Color(red: 0.18, green: 0.20, blue: 0.23)
            return
        }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }

    static func isValidHex(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return trimmed.count == 6 && UInt64(trimmed, radix: 16) != nil
    }
}

private struct RepeatingDiagonalStripes: View {
    let first: Color
    let second: Color
    let stripeWidth: CGFloat

    var body: some View {
        Canvas { context, size in
            // Rotation needs a generously oversized paint area; otherwise its far corner can expose the parent background.
            let extent = max(size.width, size.height) * 6
            let stripeCount = Int(ceil(extent / (stripeWidth * 2))) + 2
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: .radians(-.pi / 4))

            for index in -stripeCount...stripeCount {
                let x = CGFloat(index) * stripeWidth * 2
                let firstStripe = CGRect(x: x, y: -extent, width: stripeWidth, height: extent * 2)
                let secondStripe = CGRect(x: x + stripeWidth, y: -extent, width: stripeWidth, height: extent * 2)
                context.fill(Path(firstStripe), with: .color(first))
                context.fill(Path(secondStripe), with: .color(second))
            }
        }
    }
}
