import Foundation

public enum GatewayChoice: String, CaseIterable, Identifiable {
    case deepSeek, magpie, custom

    public var id: Self { self }

    public var title: String {
        switch self {
        case .deepSeek: "DeepSeek 官方"
        case .magpie: "Magpie"
        case .custom: "自定义"
        }
    }

    public var address: String {
        switch self {
        case .deepSeek: "https://api.deepseek.com"
        case .magpie: "http://127.0.0.1:3425/v1"
        case .custom: ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .deepSeek: "deepseek-flash"
        case .magpie: "sdu/ByteDance-volcengine/DeepSeek-V4.1-Flash"
        case .custom: ""
        }
    }
}

public struct GatewayPreferences {
    private let defaults: UserDefaults
    private let legacyEndpoint: GatewayEndpoint?
    public let choice: GatewayChoice
    public let customAddress: String

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        let legacyAddress = defaults.string(forKey: "llmURL") ?? GatewayChoice.magpie.address
        let legacyEndpoint = GatewayEndpoint(legacyAddress)
        self.legacyEndpoint = legacyEndpoint
        let legacyChoice = [GatewayChoice.magpie, .deepSeek].first {
            legacyEndpoint != nil && GatewayEndpoint($0.address) == legacyEndpoint
        } ?? .custom
        choice = defaults.string(forKey: "gatewayChoice").flatMap(GatewayChoice.init(rawValue:)) ?? legacyChoice
        customAddress = defaults.string(forKey: "customGatewayAddress") ?? (legacyChoice == .custom ? legacyAddress : "")
    }

    public func model(for endpoint: GatewayEndpoint?, choice: GatewayChoice) -> String {
        guard let endpoint else { return choice.defaultModel }
        return defaults.string(forKey: "gatewayModel:" + endpoint.identity)
            ?? (endpoint == legacyEndpoint ? defaults.string(forKey: "llmModel") : nil)
            ?? choice.defaultModel
    }

    public func allowsLegacyKey(for endpoint: GatewayEndpoint) -> Bool {
        endpoint == legacyEndpoint
    }

    public func levels(for endpoint: GatewayEndpoint, model: String) -> [String]? {
        defaults.array(forKey: modelKey(endpoint, model: model)) as? [String]
    }

    public func saveLevels(_ levels: [String], for endpoint: GatewayEndpoint, model: String) {
        defaults.set(levels, forKey: modelKey(endpoint, model: model))
    }

    private func modelKey(_ endpoint: GatewayEndpoint, model: String) -> String {
        "gatewayLevels:" + endpoint.identity + "\n" + model
    }
}
