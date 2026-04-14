import Foundation

/// Codable application settings stored in UserDefaults with Keychain for secrets.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    // MARK: - Server Connection

    var serverURL: String {
        get { defaults.string(forKey: "serverURL") ?? "" }
        set { defaults.set(newValue, forKey: "serverURL") }
    }

    var serverAuthToken: String {
        get { KeychainHelper.load(key: "serverAuthToken") ?? "" }
        set { KeychainHelper.save(key: "serverAuthToken", value: newValue) }
    }

    var serverEnabled: Bool {
        get { defaults.object(forKey: "serverEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "serverEnabled") }
    }

    // MARK: - Speech Recognition

    var selectedLocaleCode: String {
        get { defaults.string(forKey: "selectedLocaleCode") ?? "zh-CN" }
        set { defaults.set(newValue, forKey: "selectedLocaleCode") }
    }

    var appleDictionaryValidationEnabled: Bool {
        get { defaults.object(forKey: "appleDictionaryValidationEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "appleDictionaryValidationEnabled") }
    }

    // MARK: - Overlay

    var overlayPosition: CGPoint? {
        get {
            guard defaults.object(forKey: "overlayX") != nil else { return nil }
            return CGPoint(
                x: defaults.double(forKey: "overlayX"),
                y: defaults.double(forKey: "overlayY")
            )
        }
        set {
            if let p = newValue {
                defaults.set(p.x, forKey: "overlayX")
                defaults.set(p.y, forKey: "overlayY")
            } else {
                defaults.removeObject(forKey: "overlayX")
                defaults.removeObject(forKey: "overlayY")
            }
        }
    }
}
