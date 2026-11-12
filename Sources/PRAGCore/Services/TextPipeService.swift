import Foundation

// Public API contract — the app target depends on these signatures. Pure functions.
public enum TextPipeService {
    /// Pretty-prints a JSON object/array (2-space indent). Key order and number formatting of the
    /// input are preserved. Returns nil when the text is not a JSON object or array.
    public static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isJSONContainer(trimmed) else { return nil }
        return reformat(trimmed)
    }

    /// Decodes a JWT's header and payload (base64url) into one pretty JSON document:
    /// `{ "header": {...}, "payload": {...} }` with keys sorted. The signature is not verified.
    public static func decodeJWT(_ token: String) -> String? {
        var t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("bearer ") { t = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        guard let header = compactSortedJSONObject(fromBase64URL: String(parts[0])),
              let payload = compactSortedJSONObject(fromBase64URL: String(parts[1])) else { return nil }
        return reformat("{\"header\":\(header),\"payload\":\(payload)}")
    }

    /// Decodes Base64 (standard or URL-safe alphabet, padding optional, whitespace ignored).
    /// Returns nil unless the result is valid UTF-8 text.
    public static func decodeBase64(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // data:text/plain;base64,XXXX
        if s.lowercased().hasPrefix("data:"), let range = s.range(of: ";base64,", options: .caseInsensitive) {
            s = String(s[range.upperBound...])
        }
        guard let data = base64Data(s), !data.isEmpty, let decoded = String(data: data, encoding: .utf8) else { return nil }
        // Random bytes that happen to be valid UTF-8 are overwhelmingly control characters.
        let hasBinary = decoded.unicodeScalars.contains {
            $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }
        return hasBinary ? nil : decoded
    }

    /// Removes tracking query parameters (utm_*, fbclid, gclid, dclid, msclkid, mc_eid, mc_cid, igshid, si,
    /// ref_src, _hsenc, _hsmi, yclid) from an http(s) URL, preserving everything else (including the
    /// fragment and the raw encoding of the remaining parameters).
    /// Returns nil when the text is not an http(s) URL or when there was nothing to remove.
    public static func stripTrackingParams(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else { return nil }

        var rest = Substring(trimmed)
        var fragment = ""
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[hash...])
            rest = rest[..<hash]
        }
        guard let q = rest.firstIndex(of: "?") else { return nil }
        let base = rest[..<q]
        let query = rest[rest.index(after: q)...]

        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        let kept = pairs.filter { pair in
            let rawName = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let name = (rawName.removingPercentEncoding ?? rawName).lowercased()
            return !isTrackingParam(name)
        }
        guard kept.count != pairs.count else { return nil }
        let newQuery = kept.joined(separator: "&")
        return String(base) + (newQuery.isEmpty ? "" : "?" + newQuery) + fragment
    }

    // MARK: - Internals

    private static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "mc_eid", "mc_cid", "igshid", "si", "ref_src", "_hsenc", "_hsmi", "yclid",
    ]

    private static func isTrackingParam(_ lowercasedName: String) -> Bool {
        lowercasedName.hasPrefix("utm_") || trackingNames.contains(lowercasedName)
    }

    private static func base64Data(_ input: String) -> Data? {
        var s = String(input.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.hasSuffix("=") { s.removeLast() }
        guard !s.isEmpty, s.count % 4 != 1 else { return nil }
        if s.contains("=") { return nil }
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }

    private static func isJSONContainer(_ text: String) -> Bool {
        guard let first = text.first, first == "{" || first == "[" else { return false }
        // JSONSerialization is lenient (accepts trailing commas), so validate strictly ourselves.
        var parser = StrictJSONValidator(text)
        return parser.validate()
    }

    /// base64url → JSON object → compact JSON string with sorted keys.
    private static func compactSortedJSONObject(fromBase64URL part: String) -> String? {
        guard let data = base64Data(part),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: out, encoding: .utf8) else { return nil }
        return string
    }

    /// Token-level pretty printer for already-validated JSON: preserves key order, escapes and numbers.
    private static func reformat(_ json: String, indent: String = "  ") -> String {
        var out = ""
        var depth = 0
        var inString = false
        var escaped = false
        let chars = Array(json)
        var i = 0

        func newline() {
            out += "\n" + String(repeating: indent, count: depth)
        }
        func nextSignificant(after index: Int) -> Character? {
            var j = index + 1
            while j < chars.count {
                if !chars[j].isWhitespace { return chars[j] }
                j += 1
            }
            return nil
        }

        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"":
                    inString = true
                    out.append(c)
                case "{", "[":
                    out.append(c)
                    let closer: Character = c == "{" ? "}" : "]"
                    if nextSignificant(after: i) == closer {
                        // Empty container stays compact.
                        while chars[i] != closer { i += 1 }
                        out.append(closer)
                    } else {
                        depth += 1
                        newline()
                    }
                case "}", "]":
                    depth -= 1
                    newline()
                    out.append(c)
                case ",":
                    out.append(c)
                    newline()
                case ":":
                    out += ": "
                default:
                    if !c.isWhitespace { out.append(c) }
                }
            }
            i += 1
        }
        return out
    }
}

/// Minimal strict RFC 8259 validator (no trailing commas, no comments, no bare tokens).
private struct StrictJSONValidator {
    private let c: [UInt8]
    private var i = 0

    init(_ text: String) { c = Array(text.utf8) }

    mutating func validate() -> Bool {
        skipWS()
        guard value(depth: 0) else { return false }
        skipWS()
        return i == c.count
    }

    private mutating func skipWS() {
        while i < c.count, c[i] == 0x20 || c[i] == 0x09 || c[i] == 0x0A || c[i] == 0x0D { i += 1 }
    }

    private mutating func value(depth: Int) -> Bool {
        guard depth < 512, i < c.count else { return false }
        switch c[i] {
        case UInt8(ascii: "{"): return object(depth: depth)
        case UInt8(ascii: "["): return array(depth: depth)
        case UInt8(ascii: "\""): return string()
        case UInt8(ascii: "t"): return literal("true")
        case UInt8(ascii: "f"): return literal("false")
        case UInt8(ascii: "n"): return literal("null")
        default: return number()
        }
    }

    private mutating func literal(_ word: String) -> Bool {
        let bytes = Array(word.utf8)
        guard i + bytes.count <= c.count, Array(c[i..<i + bytes.count]) == bytes else { return false }
        i += bytes.count
        return true
    }

    private mutating func object(depth: Int) -> Bool {
        i += 1; skipWS()
        if i < c.count, c[i] == UInt8(ascii: "}") { i += 1; return true }
        while true {
            skipWS()
            guard i < c.count, c[i] == UInt8(ascii: "\""), string() else { return false }
            skipWS()
            guard i < c.count, c[i] == UInt8(ascii: ":") else { return false }
            i += 1; skipWS()
            guard value(depth: depth + 1) else { return false }
            skipWS()
            guard i < c.count else { return false }
            if c[i] == UInt8(ascii: ",") { i += 1; continue }
            if c[i] == UInt8(ascii: "}") { i += 1; return true }
            return false
        }
    }

    private mutating func array(depth: Int) -> Bool {
        i += 1; skipWS()
        if i < c.count, c[i] == UInt8(ascii: "]") { i += 1; return true }
        while true {
            skipWS()
            guard value(depth: depth + 1) else { return false }
            skipWS()
            guard i < c.count else { return false }
            if c[i] == UInt8(ascii: ",") { i += 1; continue }
            if c[i] == UInt8(ascii: "]") { i += 1; return true }
            return false
        }
    }

    private mutating func string() -> Bool {
        i += 1
        while i < c.count {
            let b = c[i]
            if b == UInt8(ascii: "\"") { i += 1; return true }
            if b < 0x20 { return false }
            if b == UInt8(ascii: "\\") {
                i += 1
                guard i < c.count else { return false }
                switch c[i] {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                     UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                    i += 1
                case UInt8(ascii: "u"):
                    guard i + 4 < c.count else { return false }
                    for k in 1...4 where !Self.isHex(c[i + k]) { return false }
                    i += 5
                default: return false
                }
            } else {
                i += 1
            }
        }
        return false
    }

    private static func isHex(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
    }

    private mutating func digits() -> Bool {
        let start = i
        while i < c.count, c[i] >= 0x30, c[i] <= 0x39 { i += 1 }
        return i > start
    }

    private mutating func number() -> Bool {
        if i < c.count, c[i] == UInt8(ascii: "-") { i += 1 }
        guard i < c.count else { return false }
        if c[i] == UInt8(ascii: "0") { i += 1 }
        else if !digits() { return false }
        if i < c.count, c[i] == UInt8(ascii: ".") {
            i += 1
            guard digits() else { return false }
        }
        if i < c.count, c[i] == UInt8(ascii: "e") || c[i] == UInt8(ascii: "E") {
            i += 1
            if i < c.count, c[i] == UInt8(ascii: "+") || c[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() else { return false }
        }
        return true
    }
}
