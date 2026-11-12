import AppKit
import AVFAudio
import Carbon
import SwiftUI

@main
struct RambleApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = RambleDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class CaptureRun {
    let id: UUID
    let credentials: Credentials
    let audio: AudioCapture
    let date = Date()
    var finishing = false
    var transcript = ""
    var preview: [SpokenTask] = []
    var finalTasks: [SpokenTask]?
    var previewFailed = false
    var requestedTranscript = ""
    var renderedTranscript = ""
    var renderedDismissals: Set<String> = []
    var previewTask: Task<Void, Never>?
    var socketTask: Task<Void, Never>?
    var timeoutTask: Task<Void, Never>?

    init(id: UUID, credentials: Credentials, audio: AudioCapture) {
        self.id = id
        self.credentials = credentials
        self.audio = audio
    }

    func cancel() {
        socketTask?.cancel()
        previewTask?.cancel()
        timeoutTask?.cancel()
        audio.stop()
    }
}

@MainActor
final class RambleDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let panel = CapturePanel()
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var hotKey: EventHotKeyRef?
    private var connectingEscape: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var pendingPermission: UUID?
    private var capture: CaptureRun?
    private var delivery: ThingsRequest?
    private var deliveryTimeout: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.confirm = { [weak self] in self?.confirmCapture() }
        panel.cancel = { [weak self] in self?.cancelCapture() }
        installMenus(hotKeyAvailable: registerHotKey())
        #if DEBUG
        if startVisualFixture() { return }
        #endif
        do {
            if try Credentials.load() == nil { showSettings() }
        } catch {
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        #if DEBUG
        if fixtureActive { panel.makeKeyAndOrderFront(nil); return false }
        #endif
        if pendingPermission != nil || capture != nil || delivery != nil {
            panel.makeKeyAndOrderFront(nil)
        } else {
            showSettings()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopConnectingEscape()
        capture?.cancel()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let delivery else { return }
        for url in urls {
            if let result = delivery.result(for: url) {
                finishDelivery(result)
                return
            }
        }
    }

    @objc private func startCapture() {
        #if DEBUG
        if fixtureEnabled {
            settingsWindow?.close()
            if fixtureActive { panel.makeKeyAndOrderFront(nil) } else { playVisualFixture() }
            return
        }
        #endif
        guard delivery == nil else { return }
        if pendingPermission != nil || capture != nil {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        dismissal?.cancel()
        panel.orderOut(nil)

        let credentials: Credentials
        do {
            guard let stored = try Credentials.load() else {
                showSettings()
                return
            }
            credentials = stored
        } catch {
            showSettings()
            return
        }

        settingsWindow?.close()
        panel.resetPreview()
        let id = UUID()
        pendingPermission = id
        watchConnectingEscape()
        panel.render(.connecting)
        Task {
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard pendingPermission == id else { return }
            pendingPermission = nil
            guard allowed else {
                stopConnectingEscape()
                showNotice(tr("Ative o microfone em Ajustes do Sistema → Privacidade e Segurança → Microfone."))
                return
            }
            do {
                let audio = AudioCapture()
                try audio.start()
                let run = CaptureRun(id: id, credentials: credentials, audio: audio)
                capture = run
                panel.makeKeyAndOrderFront(nil)
                connect(run)
            } catch {
                stopConnectingEscape()
                showNotice(message(for: error))
            }
        }
    }

    private func connect(_ run: CaptureRun) {
        let id = run.id
        let stream = run.audio.stream
        let realtime = RealtimeTranscriber(apiKey: run.credentials.openAIKey)
        run.timeoutTask = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, capture?.id == id else { return }
            failCapture(tr("A conexão com a OpenAI demorou demais."))
        }
        run.socketTask = Task { [self] in
            do {
                let transcript = try await realtime.run(audio: stream, onReady: { [weak self] in
                    await self?.transcriptionReady(id)
                }, onPartial: { [weak self] partial in
                    await self?.receiveTranscript(partial, id: id)
                })
                guard let current = capture, current.id == id, current.finishing, !Task.isCancelled else { return }
                current.timeoutTask?.cancel()
                try await finalize(current, transcript: transcript)
            } catch {
                guard capture?.id == id, !Task.isCancelled else { return }
                failCapture(message(for: error))
            }
        }
    }

    private func transcriptionReady(_ id: UUID) {
        guard let run = capture, run.id == id, !run.finishing else { return }
        stopConnectingEscape()
        run.timeoutTask?.cancel()
        panel.render(.listening, meter: run.audio.meter)
    }

    private func receiveTranscript(_ transcript: String, id: UUID) {
        guard let run = capture, run.id == id, !run.finishing else { return }
        run.transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        queuePreview(run)
    }

    private func queuePreview(_ run: CaptureRun) {
        guard run.previewTask == nil, !run.transcript.isEmpty, run.transcript != run.requestedTranscript else { return }
        let id = run.id
        run.previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(run.requestedTranscript.isEmpty ? 180 : 600))
                guard capture?.id == id, !run.finishing else { return }
                let snapshot = run.transcript
                run.requestedTranscript = snapshot
                let dismissed = panel.dismissedTitles
                let tasks = try await OpenAI(apiKey: run.credentials.openAIKey).extractTasks(from: snapshot, today: run.date, dismissed: dismissed)
                guard capture?.id == id, !run.finishing, !Task.isCancelled else { return }
                let changed = tasks != run.preview || run.previewFailed
                run.preview = tasks
                run.renderedTranscript = snapshot
                run.renderedDismissals = dismissed
                run.previewFailed = false
                if changed { panel.render(.listening, tasks: tasks, meter: run.audio.meter) }
            } catch {
                guard capture?.id == id, !run.finishing, !Task.isCancelled else { return }
                run.previewFailed = true
                panel.render(.listening, tasks: run.preview, meter: run.audio.meter, previewFailed: true)
            }
            run.previewTask = nil
            queuePreview(run)
        }
    }

    private func confirmCapture() {
        #if DEBUG
        if fixtureActive { finishVisualFixture(confirmed: true); return }
        #endif
        guard let run = capture else { return }
        if let tasks = run.finalTasks {
            deliver(tasks, from: run)
            return
        }
        guard !run.finishing else { return }
        stopConnectingEscape()
        run.finishing = true
        run.audio.stop()
        run.previewTask?.cancel()
        run.previewTask = nil
        run.timeoutTask?.cancel()
        panel.render(.finishing, tasks: run.preview)
        let id = run.id
        run.timeoutTask = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, capture?.id == id else { return }
            failCapture(tr("A OpenAI demorou para concluir a transcrição."))
        }
    }

    private func finalize(_ run: CaptureRun, transcript: String) async throws {
        let tasks: [SpokenTask]
        if transcript.isEmpty {
            tasks = []
        } else if transcript == run.renderedTranscript, run.renderedDismissals == panel.dismissedTitles {
            tasks = run.preview
        } else {
            tasks = try await OpenAI(apiKey: run.credentials.openAIKey).extractTasks(from: transcript, today: run.date, dismissed: panel.dismissedTitles)
        }
        guard capture?.id == run.id, !Task.isCancelled else { return }
        run.socketTask = nil
        let visible = panel.visibleTasks(tasks)
        if !visible.isEmpty, Set(visible.map(\.previewKey)) != panel.visibleTaskKeys {
            run.finalTasks = visible
            panel.render(.review, tasks: visible)
            return
        }
        deliver(visible, from: run)
    }

    private func deliver(_ tasks: [SpokenTask], from run: CaptureRun) {
        capture = nil
        let visibleTasks = panel.visibleTasks(tasks)
        guard !visibleTasks.isEmpty else {
            showNotice(tr("Nenhuma ação encontrada."))
            return
        }
        do {
            try sendToThings(visibleTasks, token: run.credentials.thingsToken)
        } catch {
            showNotice(message(for: error), tasks: tasks)
        }
    }

    private func sendToThings(_ tasks: [SpokenTask], token: String) throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ThingsRequest.bundleID) else {
            throw RambleError(tr("Abra ou instale o Things 3 neste Mac para adicionar as tarefas."))
        }
        let request = ThingsRequest(tasks: tasks, destinations: panel.destinations)
        let url = try request.url(token: token)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        delivery = request
        panel.render(.sending, tasks: tasks)

        Task {
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
            } catch {
                guard delivery?.id == request.id else { return }
                finishDelivery(.unconfirmed)
            }
        }
        deliveryTimeout = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, delivery?.id == request.id else { return }
            finishDelivery(.unconfirmed)
        }
    }

    private func finishDelivery(_ result: ThingsRequest.Result) {
        guard let delivery else { return }
        self.delivery = nil
        deliveryTimeout?.cancel()
        deliveryTimeout = nil
        switch result {
        case .success(let count):
            showNotice(count == 1 ? tr("1 tarefa adicionada ao Things") : String(format: tr("%d tarefas adicionadas ao Things"), count), success: true)
        case .rejected:
            showNotice(tr("O Things recusou o envio. Confira se as URLs estão ativadas e se o token está correto."), tasks: delivery.tasks)
        case .canceled:
            showNotice(tr("Envio cancelado no Things."), tasks: delivery.tasks)
        case .unconfirmed:
            showNotice(tr("O Things não confirmou o envio. Confira as listas antes de tentar novamente."), tasks: delivery.tasks)
        }
    }

    private func failCapture(_ message: String) {
        let tasks = capture?.preview ?? []
        cancelCapture()
        showNotice(message, tasks: tasks)
    }

    private func cancelCapture() {
        #if DEBUG
        if fixtureActive { finishVisualFixture(confirmed: false); return }
        #endif
        guard delivery == nil else { return }
        stopConnectingEscape()
        pendingPermission = nil
        capture?.cancel()
        capture = nil
        dismissal?.cancel()
        panel.orderOut(nil)
    }

    private func showNotice(_ text: String, success: Bool = false, tasks: [SpokenTask] = []) {
        dismissal?.cancel()
        panel.render(.notice(text, success: success), tasks: tasks)
        if success {
            dismissal = Task {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { panel.orderOut(nil) }
            }
        }
    }

    private func message(for error: Error) -> String {
        if let error = error as? RambleError { return error.message }
        if let error = error as? URLError {
            if error.code == .timedOut { return tr("A OpenAI demorou para responder. Tente uma nova captura.") }
            if error.code == .userAuthenticationRequired { return OpenAI.httpError(401).message }
            return tr("A conexão com a OpenAI falhou. Confira a internet e a chave de API.")
        }
        return tr("Não foi possível concluir a captura. Tente novamente.")
    }

    @objc private func showSettings() {
        guard pendingPermission == nil, capture == nil, delivery == nil else { return }
        panel.orderOut(nil)
        if let settingsWindow {
            NSApp.activate()
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        #if DEBUG
        if fixtureEnabled {
            presentSettings(credentials: nil, saveCredentials: { _ in })
            return
        }
        #endif
        let credentials: Credentials?
        let failure: String?
        do {
            credentials = try Credentials.load()
            failure = nil
        } catch {
            credentials = nil
            failure = error.localizedDescription
        }
        presentSettings(credentials: credentials, failure: failure)
    }

    private func presentSettings(
        credentials: Credentials?,
        failure: String? = nil,
        saveCredentials: @escaping (Credentials) throws -> Void = { try $0.save() }
    ) {
        let form = SettingsForm(credentials: credentials, error: failure)
        let view = SettingsView(form: form, saveCredentials: saveCredentials, onLanguageChange: { [weak self] in
            guard let self else { return }
            self.installMenus(hotKeyAvailable: self.hotKey != nil)
        }) { [weak self] in
            self?.settingsWindow?.close()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Things 3 Ramble"
        window.styleMask = [.titled, .closable]
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            settingsWindow = nil
        }
    }

    private func installMenus(hotKeyAvailable: Bool) {
        let menu = NSMenu()
        let captureTitle = hotKeyAvailable ? tr("Capturar voz") : tr("Capturar voz (atalho indisponível)")
        let start = NSMenuItem(title: captureTitle, action: #selector(startCapture), keyEquivalent: hotKeyAvailable ? "." : "")
        start.keyEquivalentModifierMask = [.command, .shift]
        start.target = self
        menu.addItem(start)
        let settings = NSMenuItem(title: tr("Ajustes…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Encerrar Ramble"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let waveform = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            NSColor.black.setFill()
            let barWidth: CGFloat = 3.5
            let heights: [CGFloat] = [7, 14, 10, 6]
            for (index, height) in heights.enumerated() {
                let bar = NSRect(x: 0.5 + CGFloat(index) * 4.5, y: bounds.midY - height / 2,
                                 width: barWidth, height: height)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        waveform.isTemplate = true
        waveform.accessibilityDescription = "Things 3 Ramble"
        item.button?.image = waveform
        item.button?.toolTip = "Things 3 Ramble"
        item.menu = menu
        statusItem = item

        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        for item in [start, settings] {
            if let copy = item.copy() as? NSMenuItem { appMenu.addItem(copy) }
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Encerrar Ramble"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        main.setSubmenu(appMenu, for: appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr("Editar"))
        edit.addItem(withTitle: tr("Desfazer"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Recortar"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Copiar"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Colar"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Selecionar tudo"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(editItem)
        main.setSubmenu(edit, for: editItem)
        NSApp.mainMenu = main
    }

    private func registerHotKey() -> Bool {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x52414D42 else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<RambleDelegate>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if id.id == 2 {
                    if delegate.connectingEscape != nil { delegate.cancelCapture() }
                } else {
                    delegate.startCapture()
                }
            }
            return noErr
        }, 1, &event, context, &hotKeyHandler)
        guard installed == noErr else { return false }

        let id = EventHotKeyID(signature: 0x52414D42, id: 1)
        return RegisterEventHotKey(UInt32(kVK_ANSI_Period), UInt32(cmdKey | shiftKey), id,
                                   GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey) == noErr
    }

    private func watchConnectingEscape() {
        guard hotKeyHandler != nil, connectingEscape == nil else { return }
        let id = EventHotKeyID(signature: 0x52414D42, id: 2)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(),
                            OptionBits(kEventHotKeyExclusive), &connectingEscape)
    }

    private func stopConnectingEscape() {
        if let connectingEscape { UnregisterEventHotKey(connectingEscape) }
        connectingEscape = nil
    }

    #if DEBUG
    private var fixtureEnabled = false
    private var fixtureActive = false
    private var fixtureTask: Task<Void, Never>?

    private func startVisualFixture() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard Bundle.main.bundleIdentifier == "com.raphaelkieling.things3ramble.demo" else { return false }
        fixtureEnabled = true
        NSApp.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        panel.appearance = NSApp.appearance
        if args.contains("--fixture-settings") {
            showSettings()
        } else {
            playVisualFixture()
        }
        return true
    }

    private func playVisualFixture() {
        dismissal?.cancel()
        fixtureActive = true
        panel.resetPreview()
        if ProcessInfo.processInfo.arguments.contains("--connecting") {
            watchConnectingEscape()
            panel.render(.connecting)
            return
        }
        let meter = VoiceMeter()
        let contract = SpokenTask(
            title: "Enviar o contrato à Marina",
            notes: "Anexar a versão revisada e pedir retorno por e-mail.",
            deadline: "2026-11-16",
            when: nil,
            checklist: ["Revisar a cláusula de pagamento", "Anexar o PDF"]
        )
        let call = SpokenTask(title: "Ligar para a gráfica", notes: nil, deadline: nil, when: "2026-11-12@09:30", checklist: [])
        panel.render(.listening, meter: meter, demoDestinations: [
            ThingsDestination(id: "work", name: "Work", isProject: false),
            ThingsDestination(id: "contracts", name: "Contratos", isProject: true),
        ])
        fixtureTask = Task {
            for frame in 0... {
                if Task.isCancelled { return }
                if frame == 10 { panel.render(.listening, tasks: [contract], meter: meter) }
                if frame == 25 { panel.render(.listening, tasks: [contract, call], meter: meter) }
                let beat = Double(frame) * 0.43
                meter.update(Float(max(0, sin(beat)) * (0.62 + 0.26 * sin(beat * 2.7))))
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    private func finishVisualFixture(confirmed: Bool) {
        stopConnectingEscape()
        fixtureActive = false
        fixtureTask?.cancel()
        if confirmed {
            showNotice(tr("Confirmação simulada"), success: true)
        } else {
            panel.orderOut(nil)
        }
    }
    #endif
}
