import Foundation

struct Config: Codable, Sendable {
    let port: Int
    let apiKey: String

    static func load(from path: String? = nil) throws -> Config {
        let configPath = path ?? "config.json"
        let url = URL(fileURLWithPath: configPath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.fileNotFound(configPath)
        }

        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(Config.self, from: data)

        guard config.port > 0, config.port <= 65535 else {
            throw ConfigError.invalidPort(config.port)
        }

        guard !config.apiKey.isEmpty else {
            throw ConfigError.missingAPIKey
        }

        return config
    }

    static func generateAPIKey() -> String {
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

enum ConfigError: LocalizedError {
    case fileNotFound(String)
    case invalidPort(Int)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Config file not found: \(path). Create a config.json with {\"port\": 3030, \"apiKey\": \"your-key\"}"
        case .invalidPort(let port):
            return "Invalid port: \(port). Must be between 1 and 65535"
        case .missingAPIKey:
            return "apiKey must not be empty in config.json"
        }
    }
}
