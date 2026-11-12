import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Carbon.HIToolbox

@MainActor
final class PreferencesModel: ObservableObject {
    enum Slot { case primary, secondary }

    @Published var primary: HotKeyCombo? { didSet { Settings.shared.primaryHotKey = primary } }
    @Published var secondary: HotKeyCombo? { didSet { Settings.shared.secondaryHotKey = secondary } }
    @Published var recording: Slot? = nil
    @Published var askWhereToSave: Bool { didSet { Settings.shared.askWhereToSave = askWhereToSave } }
    @Published var saveDirectory: URL { didSet { Settings.shared.saveDirectory = saveDirectory } }
    @Published var format: ImageFormat { didSet { Settings.shared.imageFormat = format } }
    @Published var copyWhenSaving: Bool { didSet { Settings.shared.copyWhenSaving = copyWhenSaving } }
    @Published var color: Color { didSet { Settings.shared.defaultColor = NSColor(color) } }
    @Published var lineWidth: Double { didSet { Settings.shared.lineWidth = CGFloat(lineWidth) } }
    @Published var launchAtLogin: Bool
    @Published var hasScreenPermission: Bool = CGPreflightScreenCaptureAccess()
    @Published var message: String? = nil

    private var monitor: Any?

    init() {
        let s = Settings.shared
        primary = s.primaryHotKey
        secondary = s.secondaryHotKey
        askWhereToSave = s.askWhereToSave
        saveDirectory = s.saveDirectory
        format = s.imageFormat
        copyWhenSaving = s.copyWhenSaving
        color = Color(nsColor: s.defaultColor)
        lineWidth = Double(s.lineWidth)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refresh() {
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch {
            message = "Não foi possível alterar: \(error.localizedDescription). Mova o app para a pasta Aplicativos e tente de novo."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Gravação de atalho

    func startRecording(_ slot: Slot) {
        stopRecording(notify: false)
        recording = slot
        message = nil
        HotKeyManager.shared.unregisterAll()   // para a tecla chegar aqui
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard let slot = recording else { return }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if Int(event.keyCode) == kVK_Escape && mods.isEmpty {
            stopRecording()
            return
        }
        guard let combo = HotKeyCombo.from(event: event) else {
            NSSound.beep()
            message = "Use uma tecla de função (F1–F20) ou combine a tecla com ⌘, ⌃ ou ⌥."
            return
        }
        if [3, 4, 5, 6].contains(where: { combo.keyCode == UInt32(Self.digitKeyCode($0)) })
            && combo.modifiers == UInt32(cmdKey | shiftKey) {
            message = "Aviso: ⌘⇧\(combo.keyName) é usado pelo macOS. Desative-o em Ajustes › Teclado › Atalhos › Capturas de Tela."
        }
        switch slot {
        case .primary: primary = combo
        case .secondary: secondary = combo
        }
        stopRecording()
    }

    private static func digitKeyCode(_ d: Int) -> Int {
        [3: kVK_ANSI_3, 4: kVK_ANSI_4, 5: kVK_ANSI_5, 6: kVK_ANSI_6][d] ?? -1
    }

    func stopRecording(notify: Bool = true) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        if notify { NotificationCenter.default.post(name: Settings.hotKeysChanged, object: nil) }
    }

    func clear(_ slot: Slot) {
        stopRecording(notify: false)
        switch slot {
        case .primary: primary = nil
        case .secondary: secondary = nil
        }
    }

    func restoreDefaults() {
        stopRecording(notify: false)
        primary = .f13
        secondary = .cmdShift2
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveDirectory
        panel.prompt = "Escolher"
        if panel.runModal() == .OK, let url = panel.url { saveDirectory = url }
    }

    func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        Form {
            Section {
                shortcutRow("Atalho principal", slot: .primary, combo: model.primary)
                shortcutRow("Atalho alternativo", slot: .secondary, combo: model.secondary)
                HStack {
                    Text("No teclado de PC, a tecla Print Screen aparece no Mac como F13.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restaurar padrão") { model.restoreDefaults() }
                        .controlSize(.small)
                }
                if let msg = model.message {
                    Text(msg).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Atalhos de captura")
            }

            Section {
                Picker("Ao salvar", selection: $model.askWhereToSave) {
                    Text("Perguntar onde salvar").tag(true)
                    Text("Salvar direto na pasta padrão").tag(false)
                }
                LabeledContent("Pasta padrão") {
                    HStack {
                        Text(model.saveDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Escolher…") { model.chooseFolder() }
                    }
                }
                Picker("Formato", selection: $model.format) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Copiar também para a área de transferência ao salvar", isOn: $model.copyWhenSaving)
            } header: {
                Text("Salvar")
            }

            Section {
                ColorPicker("Cor inicial das anotações", selection: $model.color, supportsOpacity: false)
                Picker("Espessura inicial", selection: $model.lineWidth) {
                    Text("Fina").tag(2.0)
                    Text("Média").tag(3.0)
                    Text("Grossa").tag(5.0)
                    Text("Extra").tag(8.0)
                }
            } header: {
                Text("Anotações")
            }

            Section {
                Toggle("Abrir automaticamente ao iniciar sessão", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                LabeledContent("Permissão de Gravação de Tela") {
                    HStack {
                        Label(model.hasScreenPermission ? "Concedida" : "Não concedida",
                              systemImage: model.hasScreenPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(model.hasScreenPermission ? .green : .orange)
                        if !model.hasScreenPermission {
                            Button("Abrir Ajustes…") { model.openScreenRecordingSettings() }
                        }
                    }
                }
            } header: {
                Text("Sistema")
            }

            Section {
                VStack(spacing: 4) {
                    Text("PrintShot \(Self.appVersion)")
                        .font(.headline)
                    Text("Criado e desenvolvido por: Thiago Borsati")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refresh()
        }
        .onDisappear { model.stopRecording() }
    }

    @ViewBuilder
    private func shortcutRow(_ title: String, slot: PreferencesModel.Slot, combo: HotKeyCombo?) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Button {
                    if model.recording == slot { model.stopRecording() } else { model.startRecording(slot) }
                } label: {
                    Text(model.recording == slot ? "Pressione as teclas…" : (combo?.displayString ?? "Nenhum"))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .frame(minWidth: 150)
                }
                .buttonStyle(.bordered)
                .tint(model.recording == slot ? Color.accentColor : nil)
                Button {
                    model.clear(slot)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remover atalho")
                .disabled(combo == nil)
            }
        }
    }
}
