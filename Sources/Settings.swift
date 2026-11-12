import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

// MARK: - Atalho de teclado

struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // modificadores no formato Carbon (cmdKey, shiftKey, ...)
    var keyName: String

    /// Em teclados de PC a tecla Print Screen chega ao macOS como F13.
    static let f13 = HotKeyCombo(keyCode: UInt32(kVK_F13), modifiers: 0, keyName: "F13")
    static let cmdShift2 = HotKeyCombo(keyCode: UInt32(kVK_ANSI_2),
                                       modifiers: UInt32(cmdKey | shiftKey),
                                       keyName: "2")

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        kVK_Help: "Insert",
    ]

    static let specialKeys: [Int: String] = [
        kVK_Space: "Espaço", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// Converte um evento de teclado em atalho. Teclas de função (F1–F20)
    /// podem ser usadas sozinhas; as demais exigem ⌘, ⌃ ou ⌥.
    static func from(event: NSEvent) -> HotKeyCombo? {
        let code = Int(event.keyCode)
        let mods = carbonModifiers(from: event.modifierFlags)
        if let name = functionKeys[code] {
            return HotKeyCombo(keyCode: UInt32(code), modifiers: mods, keyName: name)
        }
        let strongMods = mods & ~UInt32(shiftKey)
        guard strongMods != 0 else { return nil }
        if code == kVK_Escape { return nil }
        let name: String
        if let special = specialKeys[code] {
            name = special
        } else {
            let chars = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?"
            name = chars.uppercased()
        }
        return HotKeyCombo(keyCode: UInt32(code), modifiers: mods, keyName: name)
    }
}

// MARK: - Formato de imagem

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var utType: UTType { self == .png ? .png : .jpeg }
    var title: String { self == .png ? "PNG (sem perdas)" : "JPEG (arquivo menor)" }
}

// MARK: - Preferências persistidas

final class Settings {
    static let shared = Settings()
    static let hotKeysChanged = Notification.Name("PrintShotHotKeysChanged")

    private let d = UserDefaults.standard

    var primaryHotKey: HotKeyCombo? {
        get { combo(forKey: "hotkey.primary", default: .f13) }
        set { setCombo(newValue, forKey: "hotkey.primary") }
    }

    var secondaryHotKey: HotKeyCombo? {
        get { combo(forKey: "hotkey.secondary", default: .cmdShift2) }
        set { setCombo(newValue, forKey: "hotkey.secondary") }
    }

    var askWhereToSave: Bool {
        get { d.object(forKey: "save.ask") as? Bool ?? true }
        set { d.set(newValue, forKey: "save.ask") }
    }

    var saveDirectory: URL {
        get {
            if let p = d.string(forKey: "save.dir") { return URL(fileURLWithPath: p, isDirectory: true) }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        set { d.set(newValue.path, forKey: "save.dir") }
    }

    var lastSaveDirectory: URL? {
        get { d.string(forKey: "save.lastDir").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { d.set(newValue?.path, forKey: "save.lastDir") }
    }

    var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: d.string(forKey: "save.format") ?? "") ?? .png }
        set { d.set(newValue.rawValue, forKey: "save.format") }
    }

    var copyWhenSaving: Bool {
        get { d.bool(forKey: "save.alsoCopy") }
        set { d.set(newValue, forKey: "save.alsoCopy") }
    }

    var defaultColor: NSColor {
        get { NSColor(hex: d.string(forKey: "draw.color") ?? "") ?? .annotationRed }
        set { d.set(newValue.hexString, forKey: "draw.color") }
    }

    var lineWidth: CGFloat {
        get { let v = d.double(forKey: "draw.width"); return v > 0 ? CGFloat(v) : 3 }
        set { d.set(Double(newValue), forKey: "draw.width") }
    }

    var hasLaunchedBefore: Bool {
        get { d.bool(forKey: "app.launchedBefore") }
        set { d.set(newValue, forKey: "app.launchedBefore") }
    }

    private func combo(forKey key: String, default def: HotKeyCombo?) -> HotKeyCombo? {
        guard let data = d.data(forKey: key) else { return def }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(HotKeyCombo.self, from: data)) ?? def
    }

    private func setCombo(_ c: HotKeyCombo?, forKey key: String) {
        if let c, let data = try? JSONEncoder().encode(c) {
            d.set(data, forKey: key)
        } else {
            d.set(Data(), forKey: key)   // vazio = "sem atalho"
        }
        NotificationCenter.default.post(name: Settings.hotKeysChanged, object: nil)
    }
}

// MARK: - Cores

extension NSColor {
    static let annotationRed = NSColor(srgbRed: 1.0, green: 0.12, blue: 0.12, alpha: 1)

    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}
