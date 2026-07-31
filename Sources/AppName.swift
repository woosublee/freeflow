import Foundation

enum AppName {
    static let displayName: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Quill"

    static var applicationSupportDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent(displayName, isDirectory: true)
    }
}
