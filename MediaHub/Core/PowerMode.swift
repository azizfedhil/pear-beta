import Foundation
import Observation

/// Battery-aware switch shared by the whole app.
///
/// While Low Power Mode is on, or the phone is running hot, purely decorative motion (the hero zoom, shimmer sweeps)
/// and glass drawn over live video give way to static, flat versions. Nothing functional changes. Views read
/// `PowerMode.shared.saving` in their body, so they update by themselves the moment the system state flips.
@MainActor @Observable
final class PowerMode {
    static let shared = PowerMode()

    private(set) var saving: Bool

    private init() {
        saving = Self.current()
        let center = NotificationCenter.default
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private static func current() -> Bool {
        let p = ProcessInfo.processInfo
        return p.isLowPowerModeEnabled || p.thermalState == .serious || p.thermalState == .critical
    }

    private func refresh() {
        let now = Self.current()
        if now != saving { saving = now }
    }
}
