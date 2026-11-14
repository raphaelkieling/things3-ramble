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
    let vocabulary = Vocabulary.current
    let timing: CaptureTiming?
    var revision = 0
    var segment = "turn"
    var rangeEnd: Double?
    var finishing = false
    var transcript = ""
    var preview: [SpokenTask] = []
    var finalTasks: [SpokenTask]?
    var previewFailed = false
    var requestedTranscript = ""
    var renderedTranscript = ""
    var renderedDismissals: Set<String> = []
    var previewTask: Task<Void, Never>?
    var transcriptionTask: Task<Void, Never>?
    var timeoutTask: Task<Void, Never>?

    init(id: UUID, credentials: Credentials, audio: AudioCapture, timing: CaptureTiming?) {
        self.id = id
        self.credentials = credentials
        self.audio = audio
        self.timing = timing
    }

    func cancel() {
        transcriptionTask?.cancel()
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
    private var pendingTiming: CaptureTiming?
    private var measuredConfigurations: Set<String> = []
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
        let triggered = ContinuousClock.now
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
        if UserDefaults.standard.bool(forKey: "recordTimings") {
            let provider = TranscriptionProvider.current.rawValue
            let language = RambleLanguage.current.rawValue
            let first = measuredConfigurations.insert("\(provider):\(language)").inserted
            pendingTiming = CaptureTiming(transcriber: provider, model: ExtractionProfile().model, language: language,
                                          strategy: "current", first: first, vocabulary: !Vocabulary.current.isEmpty)
            pendingTiming?.mark("trigger", at: triggered)
        }
        watchConnectingEscape()
        panel.render(.connecting)
        Task {
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard pendingPermission == id else { return }
            pendingPermission = nil
            guard allowed else {
                stopConnectingEscape()
                persistTiming(pendingTiming, outcome: "failure")
                pendingTiming = nil
                showNotice(tr("Ative o microfone em Ajustes do Sistema → Privacidade e Segurança → Microfone."))
                return
            }
            let run = CaptureRun(id: id, credentials: credentials, audio: AudioCapture(), timing: pendingTiming)
            pendingTiming = nil
            capture = run
            transcribe(run)
        }
    }

    private func transcribe(_ run: CaptureRun) {
        let id = run.id
        let onPartial: @Sendable (TranscriptUpdate) async -> Void = { [weak self] partial in
            await self?.receiveTranscript(partial, id: id)
        }
        run.transcriptionTask = Task {
            do {
                let transcript = try await runTranscriber(run, onPartial: onPartial)
                guard let current = capture, current.id == id, current.finishing, !Task.isCancelled else { return }
                current.timeoutTask?.cancel()
                try await finalize(current, transcript: transcript)
            } catch {
                guard capture?.id == id, !Task.isCancelled else { return }
                failCapture(message(for: error))
            }
        }
    }

    private func runTranscriber(_ run: CaptureRun, onPartial: @escaping @Sendable (TranscriptUpdate) async -> Void) async throws -> String {
        if TranscriptionProvider.current == .apple {
            guard #available(macOS 26, *) else {
                throw RambleError(tr("A transcrição da Apple não está disponível neste Mac. Escolha GPT."))
            }
            let local: LocalTranscriber?
            do {
                local = try await LocalTranscriber.prepare(locale: RambleLanguage.current.speechLocale, vocabulary: run.vocabulary)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw RambleError(tr("Não foi possível preparar a transcrição local."))
            }
            try Task.checkCancellation()
            if let local {
                guard !run.finishing else { return "" }
                try run.audio.start(format: local.format, timing: run.timing)
                transcriptionReady(run.id)
                do {
                    return try await local.run(audio: run.audio.stream, onPartial: onPartial)
                } catch let error as RambleError {
                    throw error
                } catch {
                    throw RambleError(tr("Não foi possível transcrever a gravação no Mac."))
                }
            }
            throw RambleError(tr("A transcrição da Apple não está disponível para este idioma ou Mac. Escolha GPT nos Ajustes."))
        }

        guard !run.finishing else { return "" }
        try run.audio.start(timing: run.timing)
        let id = run.id
        run.timeoutTask = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, capture?.id == id else { return }
            failCapture(tr("A conexão com a OpenAI demorou demais."))
        }
        return try await RealtimeTranscriber(apiKey: run.credentials.openAIKey, vocabulary: run.vocabulary).run(
            audio: run.audio.stream,
            onReady: { [weak self] in await self?.transcriptionReady(id) },
            onPartial: onPartial
        )
    }

    private func transcriptionReady(_ id: UUID) {
        guard let run = capture, run.id == id, !run.finishing else { return }
        stopConnectingEscape()
        run.timing?.mark("ready")
        run.timeoutTask?.cancel()
        panel.render(.listening, meter: run.audio.meter)
    }

    private func receiveTranscript(_ update: TranscriptUpdate, id: UUID) {
        guard let run = capture, run.id == id else { return }
        run.timing?.mark(update.isFinal ? "segment_final" : "segment_partial",
                         segment: update.segment, audioEndMS: update.audioEndMS)
        guard !run.finishing else { return }
        let transcript = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcript != run.transcript else { return }
        run.revision += 1
        run.segment = update.segment
        run.rangeEnd = update.audioEndMS
        run.timing?.mark("transcript", segment: "\(run.segment)/\(run.revision)", audioEndMS: run.rangeEnd)
        run.transcript = transcript
        panel.updateTranscript(run.transcript)
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
                let segment = "\(run.segment)/\(run.revision)"
                run.timing?.mark("extract_start", segment: segment)
                let result = try await OpenAI(apiKey: run.credentials.openAIKey).extract(from: snapshot, today: run.date, dismissed: dismissed)
                run.timing?.mark("extract_end", segment: segment, usage: result.usage)
                let tasks = result.tasks
                guard capture?.id == id, !run.finishing, !Task.isCancelled else { return }
                let changed = tasks != run.preview || run.previewFailed
                run.preview = tasks
                run.renderedTranscript = snapshot
                run.renderedDismissals = dismissed
                run.previewFailed = false
                if changed {
                    panel.render(.listening, tasks: tasks, meter: run.audio.meter,
                                 onViewUpdate: { run.timing?.mark("preview", segment: segment) })
                }
            } catch {
                guard capture?.id == id, !run.finishing, !Task.isCancelled else { return }
                run.timing?.mark("preview_failure")
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
        run.timing?.mark("enter")
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
            failCapture(tr("A transcrição demorou para terminar."))
        }
    }

    private func finalize(_ run: CaptureRun, transcript: String) async throws {
        run.timing?.mark("final_transcript", segment: "final")
        let tasks: [SpokenTask]
        if transcript.isEmpty {
            tasks = []
        } else if transcript == run.renderedTranscript, run.renderedDismissals == panel.dismissedTitles {
            tasks = run.preview
        } else {
            run.timing?.mark("extract_start", segment: "final")
            let result = try await OpenAI(apiKey: run.credentials.openAIKey).extract(from: transcript, today: run.date, dismissed: panel.dismissedTitles)
            run.timing?.mark("extract_end", segment: "final", usage: result.usage)
            tasks = result.tasks
        }
        guard capture?.id == run.id, !Task.isCancelled else { return }
        run.transcriptionTask = nil
        let visible = panel.visibleTasks(tasks)
        if !visible.isEmpty, Set(visible) != Set(panel.visibleTasks(run.preview)) {
            run.finalTasks = visible
            panel.render(.review, tasks: visible, onViewUpdate: { run.timing?.mark("final_preview") })
            persistTiming(run.timing, outcome: "success")
            return
        }
        run.timing?.mark("final_unchanged")
        persistTiming(run.timing, outcome: "success")
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
        cancelCapture(outcome: "failure")
        showNotice(message, tasks: tasks)
    }

    private func persistTiming(_ timing: CaptureTiming?, outcome: String) {
        guard let timing else { return }
        timing.mark(outcome, once: true)
        let record = timing.record
        Task { await CaptureTiming.write(record) }
    }

    private func cancelCapture(outcome: String = "canceled") {
        #if DEBUG
        if fixtureActive { finishVisualFixture(confirmed: false); return }
        #endif
        guard delivery == nil else { return }
        stopConnectingEscape()
        pendingPermission = nil
        persistTiming(pendingTiming, outcome: outcome)
        pendingTiming = nil
        if capture?.finalTasks == nil { persistTiming(capture?.timing, outcome: outcome) }
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
            bringSettingsToFront(settingsWindow)
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
        bringSettingsToFront(window)
    }

    private func bringSettingsToFront(_ window: NSWindow) {
        NSApp.activate()
        window.orderFrontRegardless()
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
            checklist: ["Revisar a cláusula de pagamento", "Anexar o PDF"]
        )
        let call = SpokenTask(title: "Ligar para a gráfica", notes: nil, deadline: nil, when: "2026-11-12@14:00", checklist: [])
        panel.render(.listening, meter: meter, demoDestinations: [
            ThingsDestination(id: "work", name: "Work", isProject: false),
            ThingsDestination(id: "contracts", name: "Contratos", isProject: true),
        ])
        fixtureTask = Task {
            for frame in 0... {
                if Task.isCancelled { return }
                if frame == 10 { panel.render(.listening, tasks: [contract], meter: meter) }
                if frame == 25 { panel.render(.listening, tasks: [contract, call], meter: meter) }
                if frame == 5 { panel.updateTranscript("Enviar o contrato à Marina até segunda.") }
                if frame == 20 { panel.updateTranscript("Enviar o contrato à Marina até segunda. Ligar para a gráfica na quinta às 14h.") }
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
