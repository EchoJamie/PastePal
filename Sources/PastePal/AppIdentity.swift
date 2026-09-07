import Foundation

enum AppIdentity {
    static let bundleID = "local.jamie.PastePal"
    static var displayName: String {
        Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? "PastePal"
    }
}

enum AppResources {
    static let bundle: Bundle = {
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent("PastePal_PastePal.bundle")) {
            return bundle
        }
        return .module
    }()
}
