import Foundation

// Public API contract — the app target depends on these signatures. Pure functions.
public enum TextPipeService {
    public static func prettyJSON(_ text: String) -> String? { nil }
    public static func decodeJWT(_ token: String) -> String? { nil }          // pretty header + payload JSON
    public static func decodeBase64(_ text: String) -> String? { nil }      // supports base64url
    public static func stripTrackingParams(_ urlString: String) -> String? { nil } // utm_*, fbclid, gclid, si, ...
}
