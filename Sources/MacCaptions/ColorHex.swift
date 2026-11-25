import SwiftUI
import AppKit

extension Color {
    /// "#RRGGBB" (sRGB). Falls back to white when malformed.
    init(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if h.count != 6 { h = "FFFFFF" }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255,
                  blue: Double(v & 255) / 255, opacity: 1)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}
