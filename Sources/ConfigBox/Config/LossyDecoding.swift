import Foundation

/// Tolerant decoding for config.json: one entry that cannot be read (a hand edit gone wrong, or a kind of
/// rule written by a newer build) is skipped instead of failing the whole file. What was skipped is
/// collected here so the loader can keep a copy of the file before anything is saved over it.
/// Main thread only, like every config load.
enum LossyDecoding {
    private(set) static var skipped: [String] = []

    static func reset() { skipped = [] }

    static func note(_ what: String, _ error: Error) {
        skipped.append("\(what): \(summary(of: error))")
    }

    private static func summary(of error: Error) -> String {
        func path(_ c: DecodingError.Context) -> String {
            let p = c.codingPath.map(\.stringValue).joined(separator: ".")
            return p.isEmpty ? c.debugDescription : "\(p): \(c.debugDescription)"
        }
        switch error {
        case DecodingError.keyNotFound(let key, let c): return "missing “\(key.stringValue)” (\(path(c)))"
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c), DecodingError.dataCorrupted(let c): return path(c)
        default: return error.localizedDescription
        }
    }
}

/// One array element that decodes to nil instead of throwing.
private struct LossyElement<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        do {
            value = try T(from: decoder)
        } catch {
            value = nil
            LossyDecoding.note(decoder.codingPath.map(\.stringValue).joined(separator: "."), error)
        }
    }
}

extension KeyedDecodingContainer {
    /// An array whose unreadable elements are skipped. A missing key gives an empty array.
    func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T] {
        guard let items = try decodeIfPresent([LossyElement<T>].self, forKey: key) else { return [] }
        return items.compactMap(\.value)
    }

    /// A value that falls back to `fallback` when the key is missing or its content cannot be read.
    func lossy<T: Decodable>(_ type: T.Type, forKey key: Key, default fallback: T) -> T {
        do {
            return try decodeIfPresent(type, forKey: key) ?? fallback
        } catch {
            LossyDecoding.note(key.stringValue, error)
            return fallback
        }
    }
}
