import AppKit
import Carbon.HIToolbox

/// Atalhos globais via Carbon (RegisterEventHotKey). Funciona com o app em
/// segundo plano e não exige permissão de Acessibilidade.
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onPress: (@MainActor () -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    HotKeyManager.shared.onPress?()
                }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Registra os atalhos e devolve os que não puderam ser registrados
    /// (normalmente porque outro app já usa a mesma combinação).
    @discardableResult
    func register(_ combos: [HotKeyCombo]) -> [HotKeyCombo] {
        unregisterAll()
        var failed: [HotKeyCombo] = []
        for (i, combo) in combos.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5053_4854), id: UInt32(i + 1)) // 'PSHT'
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                failed.append(combo)
            }
        }
        return failed
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }
}
