import AppKit
import Combine
import ServiceManagement
import UserNotifications

/// Central app state: user settings (persisted to UserDefaults), the audio
/// engine, the key listener, and keystroke stats.
final class AppState: ObservableObject {
    static let shared = AppState()

    let engine = SoundEngine()
    let listener = KeyListener()
    private(set) var packs: [SoundPack] = []

    // MARK: - Persisted settings

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "enabled") }
    }
    @Published var volume: Float {
        didSet {
            defaults.set(volume, forKey: "volume")
            engine.volume = volume
        }
    }
    @Published var selectedPackID: String {
        didSet {
            defaults.set(selectedPackID, forKey: "pack")
            applyPack(notify: oldValue != selectedPackID)
        }
    }
    @Published var toneX: Float {
        didSet {
            defaults.set(toneX, forKey: "toneX")
            engine.setTone(x: toneX, y: toneY)
        }
    }
    @Published var toneY: Float {
        didSet {
            defaults.set(toneY, forKey: "toneY")
            engine.setTone(x: toneX, y: toneY)
        }
    }
    @Published var pitchVariation: Float {
        didSet {
            defaults.set(pitchVariation, forKey: "pitchVariation")
            engine.pitchVariationCents = pitchVariation
        }
    }
    @Published var muteModifiers: Bool {
        didSet { defaults.set(muteModifiers, forKey: "muteModifiers") }
    }
    @Published var functionKeysAudible: Bool {
        didSet { defaults.set(functionKeysAudible, forKey: "functionKeysAudible") }
    }
    @Published var returnDing: Bool {
        didSet { defaults.set(returnDing, forKey: "returnDing") }
    }
    @Published var mouseClicks: Bool {
        didSet { defaults.set(mouseClicks, forKey: "mouseClicks") }
    }
    @Published var hapticFeedback: Bool {
        didSet { defaults.set(hapticFeedback, forKey: "hapticFeedback") }
    }
    @Published var notifyOnSwitchChange: Bool {
        didSet { defaults.set(notifyOnSwitchChange, forKey: "notifyOnSwitchChange") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            updateLoginItem()
        }
    }
    @Published var outputDeviceUID: String? {
        didSet {
            defaults.set(outputDeviceUID, forKey: "outputDeviceUID")
            applyOutputDevice()
        }
    }

    // MARK: - Stats

    @Published private(set) var totalKeystrokes: Int
    @Published private(set) var todayKeystrokes: Int
    private var todayStamp: String

    @Published private(set) var accessibilityTrusted = Permissions.isTrusted

    private let defaults = UserDefaults.standard
    private var dingBuffersLoaded = false

    private init() {
        defaults.register(defaults: [
            "enabled": true, "volume": 0.55, "pack": "cream",
            "toneX": 0.0, "toneY": 0.0, "pitchVariation": 60.0,
            "muteModifiers": false, "functionKeysAudible": true,
            "returnDing": false, "mouseClicks": false,
            "hapticFeedback": false, "notifyOnSwitchChange": false,
            "launchAtLogin": false,
            "statsTotal": 0, "statsToday": 0, "statsTodayStamp": "",
        ])
        enabled = defaults.bool(forKey: "enabled")
        volume = defaults.float(forKey: "volume")
        selectedPackID = defaults.string(forKey: "pack") ?? "cream"
        toneX = defaults.float(forKey: "toneX")
        toneY = defaults.float(forKey: "toneY")
        pitchVariation = defaults.float(forKey: "pitchVariation")
        muteModifiers = defaults.bool(forKey: "muteModifiers")
        functionKeysAudible = defaults.bool(forKey: "functionKeysAudible")
        returnDing = defaults.bool(forKey: "returnDing")
        mouseClicks = defaults.bool(forKey: "mouseClicks")
        hapticFeedback = defaults.bool(forKey: "hapticFeedback")
        notifyOnSwitchChange = defaults.bool(forKey: "notifyOnSwitchChange")
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        outputDeviceUID = defaults.string(forKey: "outputDeviceUID")
        totalKeystrokes = defaults.integer(forKey: "statsTotal")
        todayKeystrokes = defaults.integer(forKey: "statsToday")
        todayStamp = defaults.string(forKey: "statsTodayStamp") ?? ""
    }

    // MARK: - Lifecycle

    func startUp() {
        packs = SoundPack.discover(in: Self.soundsDirectory())
        engine.volume = volume
        engine.pitchVariationCents = pitchVariation
        engine.setTone(x: toneX, y: toneY)
        applyPack(notify: false)
        engine.loadExtras(from: Self.soundsDirectory().appendingPathComponent("_extras"))
        try? engine.start()
        applyOutputDevice()

        listener.handler = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        accessibilityTrusted = Permissions.requestIfNeeded()
        listener.start()

        // The permission can be granted after launch; poll until it lands so
        // the UI banner clears and monitors start delivering events.
        if !accessibilityTrusted {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                if Permissions.isTrusted {
                    timer.invalidate()
                    self.accessibilityTrusted = true
                    self.listener.start()
                }
            }
        }
    }

    var currentPack: SoundPack? {
        packs.first { $0.id == selectedPackID } ?? packs.first
    }

    private func applyPack(notify: Bool) {
        guard let pack = currentPack else { return }
        engine.load(pack: pack)
        if notify && notifyOnSwitchChange {
            postNotification(title: "Switch changed", body: pack.name)
        }
    }

    func selectNextPack() {
        guard let current = currentPack,
              let idx = packs.firstIndex(where: { $0.id == current.id }),
              !packs.isEmpty else { return }
        selectedPackID = packs[(idx + 1) % packs.count].id
    }

    // MARK: - Event handling

    static let toggleKeycode: UInt16 = 40 // 'k'

    private func handle(_ event: KeyListener.Event) {
        switch event {
        case let .keyDown(keycode, isRepeat):
            // ⌘⌃K toggles Klack-style, even while disabled.
            if keycode == Self.toggleKeycode && !isRepeat,
               NSEvent.modifierFlags.contains(.command),
               NSEvent.modifierFlags.contains(.control) {
                enabled.toggle()
                return
            }
            guard enabled, !isRepeat, audible(keycode) else { return }
            recordKeystroke()
            let info = KeyMap.info(for: keycode)
            if returnDing, KeyMap.returnKeycodes.contains(keycode) {
                engine.playKey(keyClass: .enter, up: false, x: info.x)
                playDing()
            } else {
                engine.playKey(keyClass: info.keyClass, up: false, x: info.x)
            }
            if hapticFeedback {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        case let .keyUp(keycode):
            guard enabled, audible(keycode) else { return }
            let info = KeyMap.info(for: keycode)
            engine.playKey(keyClass: info.keyClass, up: true, x: info.x)
        case .mouseDown:
            guard enabled, mouseClicks else { return }
            engine.playExtra(named: "click_down", gain: 0.9)
        case .mouseUp:
            guard enabled, mouseClicks else { return }
            engine.playExtra(named: "click_up", gain: 0.7)
        }
    }

    private func audible(_ keycode: UInt16) -> Bool {
        if muteModifiers && KeyMap.modifierKeycodes.contains(keycode) { return false }
        if !functionKeysAudible && KeyMap.functionKeycodes.contains(keycode) { return false }
        return true
    }

    private func playDing() {
        // The typewriter ding ships as a shared extra, outside any pack.
        engine.playExtra(named: "ding")
    }

    // MARK: - Stats

    private func recordKeystroke() {
        let stamp = Self.dayStamp()
        if stamp != todayStamp {
            todayStamp = stamp
            todayKeystrokes = 0
            defaults.set(stamp, forKey: "statsTodayStamp")
        }
        todayKeystrokes += 1
        totalKeystrokes += 1
        // Writing defaults on every keystroke is cheap (in-memory cache), but
        // batch the sync anyway.
        defaults.set(todayKeystrokes, forKey: "statsToday")
        defaults.set(totalKeystrokes, forKey: "statsTotal")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dayStamp() -> String {
        dayFormatter.string(from: Date())
    }

    // MARK: - System integration

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("OpenKlack: login item update failed: \(error)")
        }
    }

    private func applyOutputDevice() {
        if let uid = outputDeviceUID,
           let device = AudioDevices.outputDevices().first(where: { $0.uid == uid }) {
            engine.setOutputDevice(device.id)
        } else {
            engine.setOutputDevice(nil)
        }
    }

    private func postNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }
    }

    /// Sounds live in the app bundle's Resources/Sounds; during `swift run`
    /// development, fall back to ./Resources/Sounds in the working directory.
    static func soundsDirectory() -> URL {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("Sounds")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Sounds")
    }
}
