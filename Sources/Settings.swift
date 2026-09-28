import Foundation

/// User settings, saved between launches.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private func num(_ key: String, _ def: Double) -> Double {
        return d.object(forKey: key) == nil ? def : d.double(forKey: key)
    }

    private func flag(_ key: String, _ def: Bool) -> Bool {
        return d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }

    // video
    var videoOn: Bool {
        get { return flag("videoOn", true) }
        set { d.set(newValue, forKey: "videoOn") }
    }
    var videoSize: Int {
        get { return Int(num("videoSize", 1080)) }
        set { d.set(newValue, forKey: "videoSize") }
    }
    var videoQuality: Int {
        get { return Int(num("videoQuality", 75)) }
        set { d.set(newValue, forKey: "videoQuality") }
    }

    // overlay / layout
    var outlineOpacity: Double {
        get { return num("outlineOpacity", 0.4) }
        set { d.set(newValue, forKey: "outlineOpacity") }
    }
    var glowOpacity: Double {
        get { return num("glowOpacity", 0.10) }
        set { d.set(newValue, forKey: "glowOpacity") }
    }
    // 0.85 by default: an iPad isn't the cabinet's 9:16 shape, so a full-width ring looks oversized;
    // the real screen (and reference emulators like Majdata) leave a visible margin around it.
    var ringScale: Double {
        get { return num("ringScale", 0.85) }
        set { d.set(newValue, forKey: "ringScale") }
    }
    var leftHanded: Bool {
        get { return flag("leftHanded", false) }
        set { d.set(newValue, forKey: "leftHanded") }
    }

    // touch
    var touchSensitivity: Double {
        get { return num("touchSensitivity", 0) }
        set { d.set(newValue, forKey: "touchSensitivity") }
    }

    // sound
    var soundOn: Bool {
        get { return flag("soundOn", false) }
        set { d.set(newValue, forKey: "soundOn") }
    }
    var soundVolume: Double {
        get { return num("soundVolume", 0.5) }
        set { d.set(newValue, forKey: "soundVolume") }
    }

    // info
    var showReadout: Bool {
        get { return flag("showReadout", false) }
        set { d.set(newValue, forKey: "showReadout") }
    }

    // portrait top-screen strip
    var topStripOn: Bool {
        get { return flag("topStripOn", false) }
        set { d.set(newValue, forKey: "topStripOn") }
    }
    var topStripWidth: Int {
        get { return Int(num("topStripWidth", 900)) }
        set { d.set(newValue, forKey: "topStripWidth") }
    }

    // custom background photo (the file itself lives in Documents/background.jpg)
    var customBackgroundOn: Bool {
        get { return flag("customBackgroundOn", false) }
        set { d.set(newValue, forKey: "customBackgroundOn") }
    }
    static var backgroundURL: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("background.jpg")
    }
    var hasBackgroundFile: Bool {
        return FileManager.default.fileExists(atPath: Settings.backgroundURL.path)
    }

    func reset() {
        for k in ["videoOn", "videoSize", "videoQuality", "outlineOpacity", "glowOpacity", "ringScale",
                  "leftHanded", "touchSensitivity", "soundOn", "soundVolume", "showReadout",
                  "topStripOn", "topStripWidth", "customBackgroundOn"] {
            d.removeObject(forKey: k)
        }
    }
}
