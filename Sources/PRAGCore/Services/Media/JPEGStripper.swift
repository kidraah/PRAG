import Foundation

/// Lossless JPEG metadata removal: rewrites the marker stream, dropping EXIF/XMP/IPTC/comments/MPF/thumbnails and
/// any trailing data after EOI, while keeping the entropy-coded image bytes untouched. ICC profile (APP2),
/// JFIF (APP0) and Adobe (APP14) segments are kept. If the original orientation is not 1 a minimal EXIF segment
/// containing only the orientation is re-inserted so the picture still displays upright.
enum JPEGStripper {

    static func strip(_ input: Data, orientation: Int) -> Data? {
        let d = [UInt8](input)
        guard d.count > 4, d[0] == 0xFF, d[1] == 0xD8 else { return nil }

        var out = [UInt8]()
        out.reserveCapacity(d.count)
        out.append(contentsOf: [0xFF, 0xD8])

        var pos = 2
        var insertedOrientation = orientation == 1 || orientation < 1 || orientation > 8
        var sawSOS = false

        func appendOrientationIfNeeded() {
            guard !insertedOrientation else { return }
            insertedOrientation = true
            out.append(contentsOf: orientationSegment(orientation))
        }

        while pos < d.count {
            // find next marker
            guard d[pos] == 0xFF else { return nil }
            while pos < d.count, d[pos] == 0xFF { pos += 1 }
            guard pos < d.count else { return nil }
            let marker = d[pos]
            pos += 1

            if marker == 0xD9 { // EOI
                out.append(contentsOf: [0xFF, 0xD9])
                return sawSOS ? Data(out) : nil
            }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { // standalone
                out.append(contentsOf: [0xFF, marker])
                continue
            }
            guard pos + 2 <= d.count else { return nil }
            let len = Int(d[pos]) << 8 | Int(d[pos + 1])
            guard len >= 2, pos + len <= d.count else { return nil }
            let payload = d[(pos + 2)..<(pos + len)]
            let segmentEnd = pos + len

            var keep = false
            switch marker {
            case 0xE0: // APP0 JFIF (JFXX thumbnails dropped)
                keep = payload.starts(with: Array("JFIF\0".utf8))
            case 0xE2: // APP2: keep ICC only (drops MPF)
                keep = payload.starts(with: Array("ICC_PROFILE\0".utf8))
            case 0xEE: // APP14 Adobe
                keep = payload.starts(with: Array("Adobe".utf8))
            case 0xE1, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xEB, 0xEC, 0xED, 0xEF, 0xFE:
                keep = false
            default:
                keep = true // SOFn, DHT, DQT, DRI, SOS, ...
            }

            if marker != 0xE0 { appendOrientationIfNeeded() }
            if keep {
                out.append(0xFF); out.append(marker)
                out.append(contentsOf: d[pos..<segmentEnd])
            } else if marker == 0xE0 {
                // dropped APP0 variant; nothing to emit
            }
            pos = segmentEnd

            if marker == 0xDA { // SOS: skip entropy-coded data to the next real marker
                sawSOS = true
                let start = pos
                var i = pos
                while i + 1 < d.count {
                    if d[i] == 0xFF {
                        let n = d[i + 1]
                        if n == 0x00 || (0xD0...0xD7).contains(n) { i += 2; continue }
                        if n == 0xFF { i += 1; continue }
                        break
                    }
                    i += 1
                }
                guard i + 1 < d.count else { return nil }
                out.append(contentsOf: d[start..<i])
                pos = i
            }
        }
        return nil // no EOI found
    }

    /// APP1 "Exif" segment holding only the Orientation tag (big-endian TIFF).
    private static func orientationSegment(_ o: Int) -> [UInt8] {
        var s: [UInt8] = [0xFF, 0xE1, 0x00, 0x22]
        s += Array("Exif".utf8) + [0, 0]
        s += [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]   // TIFF header, IFD0 at 8
        s += [0x00, 0x01]                                        // one entry
        s += [0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01]   // Orientation, SHORT, count 1
        s += [0x00, UInt8(o), 0x00, 0x00]                        // value
        s += [0x00, 0x00, 0x00, 0x00]                            // no next IFD
        return s
    }
}
