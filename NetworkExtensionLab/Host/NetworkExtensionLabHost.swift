import Foundation
@preconcurrency import NetworkExtension

@main
struct NetworkExtensionLabHost {
    private static let providerBundleIdentifier =
        "com.nanvon.ByteTrace.NetworkExtensionLab.FilterProvider"

    static func main() {
        let command = CommandLine.arguments.dropFirst().first ?? "--describe"

        switch command {
        case "--describe":
            describe()
        case "--save-disabled-config":
            saveDisabledConfiguration()
        default:
            print("Usage: ByteTraceNetworkExtensionLab [--describe|--save-disabled-config]")
        }
    }

    private static func describe() {
        print("Network Extension lab is compile-only by default.")
        print("provider bundle: \(providerBundleIdentifier)")
        print("mode: NEFilterDataProvider pass-through + flow-close reports")
        print("state change: none")
    }

    private static func saveDisabledConfiguration() {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { error in
            if let error {
                print("load filter preferences failed: \(error.localizedDescription)")
                Foundation.exit(1)
            }

            let configuration = NEFilterProviderConfiguration()
            configuration.filterSockets = true
            configuration.filterDataProviderBundleIdentifier = providerBundleIdentifier

            manager.localizedDescription = "ByteTrace Network Extension lab"
            manager.providerConfiguration = configuration
            manager.grade = .inspector
            manager.isEnabled = false

            manager.saveToPreferences { error in
                if let error {
                    print("save disabled filter configuration failed: \(error.localizedDescription)")
                    Foundation.exit(1)
                }

                print("saved a disabled filter configuration")
                print("state change: NEFilterManager preferences only; filter remains disabled")
                Foundation.exit(0)
            }
        }

        RunLoop.main.run()
    }
}
