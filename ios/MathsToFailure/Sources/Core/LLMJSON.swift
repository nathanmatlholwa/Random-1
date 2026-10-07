import Foundation

/// Turns model replies into typed values.
///
/// Models write LaTeX inside JSON. A lone backslash before f, t, b, r or n silently becomes a control
/// character when the JSON is parsed (\frac turns into form feed + "rac"), and an unknown escape such as \alpha
/// makes the JSON invalid. Both are repaired here.
enum LLMJSON {
    static func decode<T: Decodable>(_ text: String, as type: T.Type) throws -> T {
        let object = try parseObject(text)
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AppError.badResponse("The model's reply had an unexpected shape. Try again.")
        }
    }

    static func parseObject(_ text: String) throws -> Any {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        guard let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end else {
            throw AppError.badResponse("The model did not return usable JSON. Try again.")
        }
        let slice = String(t[start...end])
        var parsed: Any?
        if let d = slice.data(using: .utf8) { parsed = try? JSONSerialization.jsonObject(with: d) }
        if parsed == nil, let d = escapeInvalidBackslashes(slice).data(using: .utf8) {
            parsed = try? JSONSerialization.jsonObject(with: d)
        }
        guard let obj = parsed else { throw AppError.badResponse("The model returned malformed JSON. Try again.") }
        return repair(obj)
    }

    /// Doubles every backslash that is not a valid JSON escape.
    static func escapeInvalidBackslashes(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        let valid: Set<Character> = ["\"", "\\", "/", "b", "f", "n", "r", "t"]
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                let n = chars[i + 1]
                if valid.contains(n) {
                    out.append(c); out.append(n); i += 2; continue
                }
                if n == "u" && i + 5 < chars.count && chars[(i + 2)...(i + 5)].allSatisfy({ $0.isHexDigit }) {
                    out.append(contentsOf: chars[i...(i + 5)]); i += 6; continue
                }
                out.append("\\\\"); i += 1; continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    static func repair(_ value: Any) -> Any {
        if let s = value as? String { return repairString(s) }
        if let a = value as? [Any] { return a.map { repair($0) } }
        if let d = value as? [String: Any] { return d.mapValues { repair($0) } }
        return value
    }

    /// Restores LaTeX commands that were mangled into control characters.
    static func repairString(_ s: String) -> String {
        let rules: [(control: Character, letter: String, suffixes: [String])] = [
            ("\u{0C}", "f", ["rac", "orall"]),
            ("\t", "t", ["heta", "imes", "ext", "an", "o", "ilde", "au"]),
            ("\u{08}", "b", ["eta", "ar", "inom", "egin", "ig"]),
            ("\r", "r", ["ight", "ho", "angle"]),
            ("\n", "n", ["eq", "u", "abla", "ot", "eg"]),
        ]
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            var replaced = false
            for rule in rules where c == rule.control {
                let rest = String(chars[(i + 1)...])
                for suffix in rule.suffixes where rest.hasPrefix(suffix) {
                    // Short suffixes must end the word, so ordinary text such as a newline before "equation" is untouched.
                    let after = rest.dropFirst(suffix.count).first
                    let needsBoundary = ["an", "o", "u", "ot", "eg", "eq", "ho", "ar", "au"].contains(suffix)
                    if needsBoundary, let a = after, a.isLetter { continue }
                    out.append("\\")
                    out.append(rule.letter)
                    replaced = true
                    break
                }
                if replaced { break }
            }
            if !replaced { out.append(c) }
            i += 1
        }
        return out
    }
}

// MARK: - Lenient decoding helpers (models sometimes send numbers as strings and vice versa)

struct FlexInt: Decodable {
    let value: Int
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = Int(d.rounded()) }
        else if let s = try? c.decode(String.self), let i = Int(s.trimmingCharacters(in: .whitespaces)) { value = i }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a number") }
    }
}

struct FlexString: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not text") }
    }
}
