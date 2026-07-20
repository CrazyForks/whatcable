/// Encodes untrusted, single-field text before it is embedded in terminal
/// output. Hardware descriptors and IOKit properties can contain C0/C1
/// controls, including ESC/OSC sequences and embedded line breaks. Rendering
/// those bytes verbatim lets a device alter terminal state or forge rows.
///
/// Formatter-owned ANSI sequences and newlines must be added after this
/// encoder runs. Structured JSON deliberately does not use this representation.
public enum TerminalFieldEncoder {
    /// Replaces C0/C1 control scalars with visible Unicode escape sequences.
    public static func encode(_ value: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count)

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                encoded += "\\u{\(hex)}"
            default:
                encoded.unicodeScalars.append(scalar)
            }
        }

        return encoded
    }
}
