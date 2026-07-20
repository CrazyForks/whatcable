import Testing
@testable import WhatCableCore

@Suite("Terminal field encoder")
struct TerminalFieldEncoderTests {
    @Test("C0, DEL, and C1 controls become visible text")
    func controlRangesBecomeVisibleText() {
        var controls = ""
        for value in Array(0x00...0x1F) + Array(0x7F...0x9F) {
            controls.unicodeScalars.append(UnicodeScalar(value)!)
        }

        let encoded = TerminalFieldEncoder.encode(controls)
        let remainingControls = encoded.unicodeScalars.filter {
            (0x00...0x1F).contains($0.value) || (0x7F...0x9F).contains($0.value)
        }

        #expect(remainingControls.isEmpty)
        #expect(encoded.contains(#"\u{0}\u{1}"#))
        #expect(encoded.contains(#"\u{1B}"#))
        #expect(encoded.contains(#"\u{7F}\u{80}"#))
        #expect(encoded.hasSuffix(#"\u{9F}"#))
    }

    @Test("Ordinary Unicode is preserved verbatim")
    func ordinaryUnicodeIsPreserved() {
        let value = "Café 显示器 🚀 e\u{301}"
        #expect(TerminalFieldEncoder.encode(value) == value)
    }
}
