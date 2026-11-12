import Testing
import Foundation
@testable import PRAGCore

// MARK: JSON

@Test func prettyJSONFormatsObjectsAndArrays() {
    let out = TextPipeService.prettyJSON(#"{"b":1,"a":[1,2,{"x":null}],"s":"he said \"hi\", ok: {fine}"}"#)
    #expect(out == """
    {
      "b": 1,
      "a": [
        1,
        2,
        {
          "x": null
        }
      ],
      "s": "he said \\"hi\\", ok: {fine}"
    }
    """)
    #expect(TextPipeService.prettyJSON("[]") == "[]")
    #expect(TextPipeService.prettyJSON(#"  {"a":{},"b":[ ]}  "#) == "{\n  \"a\": {},\n  \"b\": []\n}")
    #expect(TextPipeService.prettyJSON("[1,2]") == "[\n  1,\n  2\n]")
}

@Test func prettyJSONPreservesNumbersAndIsIdempotent() throws {
    let src = #"{"big":12345678901234567890,"f":1.0,"e":1e10,"u":"éé"}"#
    let out = try #require(TextPipeService.prettyJSON(src))
    #expect(out.contains("12345678901234567890"))
    #expect(out.contains("1.0"))
    #expect(out.contains("1e10"))
    #expect(TextPipeService.prettyJSON(out) == out)
}

@Test func prettyJSONRejectsNonJSON() {
    #expect(TextPipeService.prettyJSON("hello") == nil)
    #expect(TextPipeService.prettyJSON("") == nil)
    #expect(TextPipeService.prettyJSON("{not json}") == nil)
    #expect(TextPipeService.prettyJSON(#"{"a":1,}"#) == nil)
    #expect(TextPipeService.prettyJSON("42") == nil)
    #expect(TextPipeService.prettyJSON("\"str\"") == nil)
}

// MARK: JWT

private func b64url(_ s: String) -> String {
    Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

@Test func decodeJWTPrettyPrintsHeaderAndPayloadWithSortedKeys() throws {
    let token = b64url(#"{"typ":"JWT","alg":"HS256"}"#) + "." + b64url(#"{"sub":"1234567890","name":"John Doe","iat":1516239022}"#) + ".c2lnbmF0dXJl"
    let out = try #require(TextPipeService.decodeJWT(token))
    #expect(out == """
    {
      "header": {
        "alg": "HS256",
        "typ": "JWT"
      },
      "payload": {
        "iat": 1516239022,
        "name": "John Doe",
        "sub": "1234567890"
      }
    }
    """)
    // Valid JSON itself.
    #expect(TextPipeService.prettyJSON(out) == out)
}

@Test func decodeJWTRealWorldSampleAndBearerPrefix() throws {
    let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    let out = try #require(TextPipeService.decodeJWT(jwt))
    #expect(out.contains("\"name\": \"John Doe\""))
    #expect(out.contains("\"alg\": \"HS256\""))
    #expect(TextPipeService.decodeJWT("  Bearer \(jwt)\n") == out)
    // unsecured JWT with empty signature
    let unsecured = b64url(#"{"alg":"none"}"#) + "." + b64url(#"{"a":1}"#) + "."
    #expect(TextPipeService.decodeJWT(unsecured) != nil)
}

@Test func decodeJWTRejectsGarbage() {
    #expect(TextPipeService.decodeJWT("hello") == nil)
    #expect(TextPipeService.decodeJWT("a.b.c") == nil)
    #expect(TextPipeService.decodeJWT("") == nil)
    #expect(TextPipeService.decodeJWT(b64url("{}") + "." + b64url("{}")) == nil)                // 2 parts
    #expect(TextPipeService.decodeJWT(b64url("[1]") + "." + b64url("{}") + ".x") == nil)        // header not an object
    #expect(TextPipeService.decodeJWT(b64url("nope") + "." + b64url("{}") + ".x") == nil)
}

// MARK: Base64

@Test func decodeBase64Variants() {
    #expect(TextPipeService.decodeBase64("SGVsbG8sIFdvcmxkIQ==") == "Hello, World!")
    #expect(TextPipeService.decodeBase64("SGVsbG8sIFdvcmxkIQ") == "Hello, World!")            // missing padding
    #expect(TextPipeService.decodeBase64("  SGVsbG8s\nIFdvcmxkIQ==\n") == "Hello, World!")    // whitespace / line breaks
    // url alphabet: "???>>>" is "Pz8/Pj4+" in standard base64 and "Pz8_Pj4-" in base64url
    #expect(TextPipeService.decodeBase64("Pz8/Pj4+") == "???>>>")
    #expect(TextPipeService.decodeBase64("Pz8_Pj4-") == "???>>>")
    #expect(TextPipeService.decodeBase64("4pyTIMOgIGxhIG1vZGU=") == "✓ à la mode")           // multi-byte UTF-8
    #expect(TextPipeService.decodeBase64("data:text/plain;base64,SGk=") == "Hi")
}

@Test func decodeBase64RejectsNonTextAndNonBase64() {
    #expect(TextPipeService.decodeBase64("") == nil)
    #expect(TextPipeService.decodeBase64("   ") == nil)
    #expect(TextPipeService.decodeBase64("not base64!") == nil)
    #expect(TextPipeService.decodeBase64("A") == nil)                                           // impossible length
    #expect(TextPipeService.decodeBase64("/9j/4AAQSkZJRg==") == nil)                            // JPEG bytes: not UTF-8
    #expect(TextPipeService.decodeBase64("AAECAwQ=") == nil)                                    // control characters
}

// MARK: Tracking params

@Test func stripTrackingParamsRemovesKnownTrackers() {
    #expect(TextPipeService.stripTrackingParams("https://example.com/p?utm_source=x&id=7&utm_medium=y&fbclid=abc") == "https://example.com/p?id=7")
    #expect(TextPipeService.stripTrackingParams("https://example.com/p?id=7&gclid=1&dclid=2&msclkid=3&mc_eid=4&mc_cid=5&igshid=6&si=7&ref_src=8&_hsenc=9&_hsmi=10&yclid=11&keep=ok") == "https://example.com/p?id=7&keep=ok")
    // everything removed → no dangling "?"
    #expect(TextPipeService.stripTrackingParams("https://example.com/?utm_source=a&utm_campaign=b") == "https://example.com/")
    // fragment and other params preserved verbatim (order, encoding)
    #expect(TextPipeService.stripTrackingParams("https://example.com/a?q=hello%20world&utm_term=z&b=%C3%A9#section-2") == "https://example.com/a?q=hello%20world&b=%C3%A9#section-2")
    #expect(TextPipeService.stripTrackingParams("https://example.com/a?utm_x=1#frag") == "https://example.com/a#frag")
    // case-insensitive names, tracker-named values untouched
    #expect(TextPipeService.stripTrackingParams("https://example.com/?UTM_Source=a&q=fbclid") == "https://example.com/?q=fbclid")
    #expect(TextPipeService.stripTrackingParams("  https://youtu.be/abc?si=XYZ&t=30\n") == "https://youtu.be/abc?t=30")
    // lookalikes that are NOT trackers survive
    #expect(TextPipeService.stripTrackingParams("https://example.com/?session=1&utm=2&reference=3&ref=4") == nil)
}

@Test func stripTrackingParamsReturnsNilWhenNotApplicable() {
    #expect(TextPipeService.stripTrackingParams("https://example.com/page") == nil)            // nothing to strip
    #expect(TextPipeService.stripTrackingParams("https://example.com/page?id=1") == nil)
    #expect(TextPipeService.stripTrackingParams("not a url") == nil)
    #expect(TextPipeService.stripTrackingParams("") == nil)
    #expect(TextPipeService.stripTrackingParams("ftp://example.com/?utm_source=x") == nil)
    #expect(TextPipeService.stripTrackingParams("example.com/?utm_source=x") == nil)
    #expect(TextPipeService.stripTrackingParams("see https://example.com/?utm_source=x") == nil)
}
