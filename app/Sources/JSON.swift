import Foundation

/// C 브리지가 넘기는 JSON의 값 (소스 설정처럼 모양이 정해지지 않은 값)
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            // 정수는 정수로 보내야 obs_data가 int로 읽는다
            if value.rounded() == value, abs(value) < 9e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var number: Double? {
        switch self {
        case .number(let value): return value
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        default: return nil
        }
    }
}

/// C 브리지가 돌려준 JSON 문자열을 디코드하고 해제한다
func decodeCoreJSON<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?, as type: T.Type) -> T? {
    guard let pointer else { return nil }
    defer { core_free(pointer) }

    let data = Data(String(cString: pointer).utf8)
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        appLog("JSON decode failed for \(type): \(error)")
        return nil
    }
}

func encodeJSON(_ object: [String: JSONValue]) -> String {
    guard let data = try? JSONEncoder().encode(object) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}
