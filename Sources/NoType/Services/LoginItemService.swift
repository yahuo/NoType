import Foundation
import ServiceManagement

@MainActor
final class LoginItemService {
    func setLaunchAtLogin(enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
