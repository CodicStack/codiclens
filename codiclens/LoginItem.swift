import Foundation
import ServiceManagement

/// The app as its own login item. A fake in tests: nothing under test adds
/// a login item to the Mac.
protocol LoginItemService {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// `SMAppService.mainApp`: the app itself, listed in System Settings →
/// General → Login Items.
struct MainAppLoginItem: LoginItemService {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Open at login, as Setup's row and the Settings toggle both show it: what
/// macOS has, read again on `refresh()` because the user can change it in
/// System Settings too.
@Observable
final class OpenAtLogin {
    @ObservationIgnored private let service: LoginItemService
    private(set) var isOn: Bool

    init(service: LoginItemService) {
        self.service = service
        isOn = service.isEnabled
    }

    func setOn(_ isOn: Bool) {
        do {
            try service.setEnabled(isOn)
        } catch {
            NSLog("[codiclens] open at login %@ failed: %@", isOn ? "on" : "off", "\(error)")
        }
        refresh()
    }

    func refresh() {
        isOn = service.isEnabled
    }
}
