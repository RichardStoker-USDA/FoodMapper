import CryptoKit
import Foundation

enum ProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI
    case localOpenAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .localOpenAICompatible: return "Local OpenAI-compatible"
        }
    }

    var fixedBaseURL: URL? {
        switch self {
        case .openAI: return URL(string: "https://api.openai.com/v1")
        case .localOpenAICompatible: return nil
        }
    }
}

struct ProviderProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var kind: ProviderKind
    var baseURL: String
    var model: String
    var maximumOutputTokens: Int
    var requestOptionsJSON: String

    init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        baseURL: String = "",
        model: String,
        maximumOutputTokens: Int = 128,
        requestOptionsJSON: String = "{}"
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.maximumOutputTokens = maximumOutputTokens
        self.requestOptionsJSON = requestOptionsJSON
    }

    func validated() throws -> ProviderProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 80 else { throw ProviderProfileError.invalidName }
        guard !trimmedModel.isEmpty, trimmedModel.count <= 160 else { throw ProviderProfileError.invalidModel }
        guard maximumOutputTokens == 128 else { throw ProviderProfileError.invalidTokenLimit }

        let url = try ProviderEndpointPolicy.canonicalURL(kind: kind, value: baseURL)
        var value = self
        value.name = trimmedName
        value.model = trimmedModel
        value.baseURL = url.absoluteString
        value.requestOptionsJSON = try ProviderRequestOptions.normalizedJSON(requestOptionsJSON)
        return value
    }

    func nonsecretFingerprint() throws -> String {
        let checked = try validated()
        let record = [
            "adapter": ProviderAdapterMetadata.version,
            "endpoint": checked.baseURL,
            "kind": checked.kind.rawValue,
            "model": checked.model,
            "response_mode": ProviderAdapterMetadata.responseMode
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, model, maximumOutputTokens, requestOptionsJSON
        case legacyAllowsReasoning = "allowsReasoning"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(ProviderKind.self, forKey: .kind)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        model = try values.decode(String.self, forKey: .model)
        maximumOutputTokens = 128
        requestOptionsJSON = try values.decodeIfPresent(String.self, forKey: .requestOptionsJSON) ?? "{}"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(kind, forKey: .kind)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encode(model, forKey: .model)
        try values.encode(maximumOutputTokens, forKey: .maximumOutputTokens)
        try values.encode(requestOptionsJSON, forKey: .requestOptionsJSON)
    }
}

enum ProviderRequestOptions {
    private static let maximumBytes = 8_192
    static func normalizedJSON(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "{}" : trimmed
        guard let data = candidate.data(using: .utf8), data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw ProviderProfileError.invalidRequestOptions
        }
        guard dictionary.isEmpty else {
            throw ProviderProfileError.customRequestOptionsNotSupported
        }
        return "{}"
    }
}

enum ProviderAdapterMetadata {
    static let version = "openai-chat-completions-v1"
    static let responseMode = "strict-json-schema"
}

enum ProviderEndpointPolicy {
    static func canonicalURL(kind: ProviderKind, value: String) throws -> URL {
        if let fixed = kind.fixedBaseURL { return fixed }

        let submitted = value
        guard submitted == submitted.trimmingCharacters(in: .whitespacesAndNewlines),
              submitted.hasPrefix("http://"),
              submitted.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) }),
              !submitted.contains("%"),
              !submitted.contains("\\"),
              !submitted.contains("@"),
              let components = URLComponents(string: submitted),
              components.scheme?.lowercased() == "http",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let rawHost = components.host?.lowercased(),
              components.percentEncodedPath == "/v1",
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw ProviderProfileError.endpointNotAllowed
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard host == "127.0.0.1" || host == "::1" else {
            throw ProviderProfileError.endpointNotAllowed
        }

        guard let url = components.url, url.absoluteString == submitted else {
            throw ProviderProfileError.endpointNotAllowed
        }
        return url
    }
}

enum ProviderProfileError: LocalizedError, Equatable {
    case invalidName
    case invalidModel
    case invalidTokenLimit
    case endpointNotAllowed
    case invalidRequestOptions
    case customRequestOptionsNotSupported

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a provider name under 80 characters."
        case .invalidModel: return "Enter a model name under 160 characters."
        case .invalidTokenLimit: return "Provider output is fixed at 128 tokens."
        case .endpointNotAllowed: return "Local providers must use an exact http://127.0.0.1[:port]/v1 or http://[::1][:port]/v1 address."
        case .invalidRequestOptions: return "Request options must be an empty JSON object."
        case .customRequestOptionsNotSupported: return "Custom request fields are not available for automatic provider decisions."
        }
    }
}
