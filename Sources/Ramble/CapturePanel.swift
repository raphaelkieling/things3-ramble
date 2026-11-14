import AppKit
import SwiftUI

struct RamblePalette {
    static let action = Color(red: 0.03, green: 0.38, blue: 0.81)
    let surface: Color
    let inset: Color
    let line: Color
    let blue: Color

    init(_ scheme: ColorScheme) {
        let dark = scheme == .dark
        surface = dark ? Color(red: 0.145, green: 0.151, blue: 0.166) : .white
        inset = dark ? Color(red: 0.190, green: 0.196, blue: 0.213) : Color(red: 0.959, green: 0.969, blue: 0.982)
        line = .primary.opacity(dark ? 0.14 : 0.10)
        blue = dark ? Color(red: 0.40, green: 0.67, blue: 1) : Color(red: 0.03, green: 0.37, blue: 0.76)
    }
}

enum CapturePhase: Equatable {
    case connecting
    case listening
    case finishing
    case review
    case sending
    case notice(String, success: Bool)

    var canCancel: Bool { self != .sending }
    var canEditTasks: Bool { self == .listening || self == .review }
    var canConfirm: Bool { canEditTasks || self == .connecting }
}

@MainActor
private final class TaskPreview: ObservableObject {
    enum DestinationList {
        case unloaded
        case loading
        case loaded([ThingsDestination])
        case failed(String)
    }

    @Published var tasks: [SpokenTask] = []
    @Published var phase: CapturePhase = .connecting
    @Published var meter: VoiceMeter?
    @Published var previewFailed = false
    @Published var transcript = ""
    @Published var hoveredCard: String?
    @Published var expanded: Set<String> = []
    @Published var destinations: [String: ThingsDestination] = [:]
    @Published var destinationList = DestinationList.unloaded
}

@MainActor
final class CapturePanel: NSPanel {
    var confirm: (() -> Void)?
    var cancel: (() -> Void)?
    private var host: NSHostingController<CaptureView>?
    private var anchorScreen: NSScreen?
    private let preview = TaskPreview()
    private var resizeTask: Task<Void, Never>?
    private var destinationTask: Task<Void, Never>?
    private(set) var dismissedTitles: Set<String> = []
    var destinations: [String: ThingsDestination] { preview.destinations }

    func resetPreview() {
        destinationTask?.cancel()
        preview.destinationList = .unloaded
        preview.destinations.removeAll()
        dismissedTitles.removeAll()
        preview.expanded.removeAll()
        preview.tasks.removeAll()
        preview.transcript = ""
        preview.hoveredCard = nil
    }

    func updateTranscript(_ text: String) {
        guard let view = host?.rootView, view.showsTranscript, preview.transcript != text else { return }
        let visibilityChanged = preview.transcript.isEmpty != text.isEmpty
        preview.transcript = text
        if visibilityChanged { resize() }
    }

    func visibleTasks(_ tasks: [SpokenTask]) -> [SpokenTask] {
        tasks.filter { !dismissedTitles.contains($0.previewKey) }
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    func render(_ phase: CapturePhase, tasks: [SpokenTask] = [], meter: VoiceMeter? = nil,
                previewFailed: Bool = false, demoDestinations: [ThingsDestination]? = nil,
                onViewUpdate: (() -> Void)? = nil) {
        if let demoDestinations { preview.destinationList = .loaded(demoDestinations) }
        if !isVisible {
            anchorScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? .main
        }
        guard let visible = (anchorScreen ?? .main)?.visibleFrame else { return }

        if !isVisible || host == nil {
            let showsTranscript = UserDefaults.standard.object(forKey: TranscriptionProvider.showTranscriptPreference) as? Bool ?? true
            let view = CaptureView(
                preview: preview,
                showsTranscript: showsTranscript,
                cardWidth: min(408, visible.width - 42),
                maxCardsHeight: max(150, min(490, visible.height - (showsTranscript ? 234 : 154))),
                confirm: { [weak self] in self?.confirm?() },
                cancel: { [weak self] in self?.cancel?() },
                toggleDetails: { [weak self] task in self?.toggleDetails(task) },
                remove: { [weak self] task in self?.remove(task) },
                loadDestinations: { [weak self] in self?.loadDestinations() }
            )
            let host = NSHostingController(rootView: view)
            host.sizingOptions = []
            contentViewController = host
            self.host = host
        }
        withAnimation(isVisible ? animation : nil) {
            if preview.phase != phase { preview.phase = phase }
            if preview.meter !== meter { preview.meter = meter }
            if preview.previewFailed != previewFailed { preview.previewFailed = previewFailed }
            let tasks = visibleTasks(tasks)
            if preview.tasks != tasks { preview.tasks = tasks }
        }
        title = tr("Captura do Ramble")
        resize()
        if !isVisible { makeKeyAndOrderFront(nil) }
        if let onViewUpdate {
            displayIfNeeded()
            onViewUpdate()
        }
    }

    private func toggleDetails(_ task: SpokenTask) {
        withAnimation(animation) {
            if !preview.expanded.insert(task.previewKey).inserted { preview.expanded.remove(task.previewKey) }
        }
        resize()
    }

    private func remove(_ task: SpokenTask) {
        guard preview.phase.canEditTasks else { return }
        dismissedTitles.insert(task.previewKey)
        preview.destinations.removeValue(forKey: task.previewKey)
        updatePreview(visibleTasks(preview.tasks))
    }

    private func loadDestinations() {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: ThingsRequest.bundleID) != nil else {
            preview.destinationList = .failed(tr("Instale o Things para escolher projetos e áreas."))
            return
        }
        preview.destinationList = .loading
        destinationTask = Task { [weak self] in
            do {
                let destinations = try await ThingsDestination.load()
                guard !Task.isCancelled else { return }
                self?.preview.destinationList = .loaded(destinations)
            } catch {
                guard !Task.isCancelled else { return }
                self?.preview.destinationList = .failed(error.localizedDescription)
            }
        }
    }

    private var animation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .smooth(duration: 0.24)
    }

    private func updatePreview(_ tasks: [SpokenTask]) {
        if preview.tasks != tasks {
            withAnimation(animation) { preview.tasks = tasks }
        }
        resize()
    }

    private func resize() {
        resizeTask?.cancel()
        guard let host, let visible = (anchorScreen ?? .main)?.visibleFrame else { return }
        var root = host.rootView
        root.fillsWindow = false
        let sizing = NSHostingController(rootView: root)
        let size = sizing.sizeThatFits(in: NSSize(width: root.cardWidth + 32, height: root.maxCardsHeight + 120))
        let target = NSRect(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 42,
                            width: ceil(size.width), height: ceil(size.height))
        if isVisible, animation != nil, (target.height < frame.height || target.width < frame.width) {
            resizeTask = Task {
                try? await Task.sleep(for: .milliseconds(260))
                if !Task.isCancelled { setFrame(target, display: true) }
            }
        } else {
            setFrame(target, display: true)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, preview.phase.canCancel {
            cancel?()
        } else if event.type == .keyDown, [36, 76].contains(event.keyCode), preview.phase.canConfirm, !event.isARepeat {
            confirm?()
        } else {
            super.sendEvent(event)
        }
    }
}

private struct CaptureView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var preview: TaskPreview
    var fillsWindow = true
    private var phase: CapturePhase { preview.phase }
    let showsTranscript: Bool
    let cardWidth: CGFloat
    let maxCardsHeight: CGFloat
    let confirm: () -> Void
    let cancel: () -> Void
    let toggleDetails: (SpokenTask) -> Void
    let remove: (SpokenTask) -> Void
    let loadDestinations: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if !preview.tasks.isEmpty {
                ViewThatFits(in: .vertical) {
                    cards.fixedSize(horizontal: false, vertical: true)
                    ScrollView { cards.padding(.vertical, 4) }
                        .frame(height: maxCardsHeight)
                }
                .frame(width: cardWidth)
                .frame(maxHeight: maxCardsHeight)
                .transition(.offset(y: 7).combined(with: .opacity))
            }
            if showsTranscript, phase == .listening, !preview.transcript.isEmpty {
                transcript
            }
            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .fixedSize(horizontal: true, vertical: true)
        .frame(maxWidth: fillsWindow ? .infinity : nil, maxHeight: fillsWindow ? .infinity : nil,
               alignment: .bottom)
    }

    private var transcript: some View {
        let palette = RamblePalette(scheme)
        return Text(verbatim: preview.transcript)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(3, reservesSpace: true)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .frame(width: (cardWidth * 0.84).rounded())
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(palette.line, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    private var cards: some View {
        VStack(spacing: 6) {
            ForEach(preview.tasks, id: \.previewKey) { task in
                let lifted = fillsWindow && phase.canEditTasks && preview.hoveredCard == task.previewKey
                TaskCard(
                    task: task, expanded: preview.expanded.contains(task.previewKey),
                    editable: phase.canEditTasks,
                    destination: Binding(
                        get: { preview.destinations[task.previewKey] },
                        set: { preview.destinations[task.previewKey] = $0 }
                    ),
                    destinationList: preview.destinationList,
                    loadDestinations: loadDestinations,
                    toggleDetails: { toggleDetails(task) },
                    remove: { remove(task) }
                )
                .offset(y: lifted && !reduceMotion ? -2 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: lifted)
                .onHover { isHovering in
                    guard fillsWindow else { return }
                    if isHovering {
                        preview.hoveredCard = task.previewKey
                    } else if preview.hoveredCard == task.previewKey {
                        preview.hoveredCard = nil
                    }
                }
                .transition(.asymmetric(
                    insertion: .offset(y: 10).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .bottom)),
                    removal: .offset(y: 5).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .bottom))
                ))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Prévia das tarefas"))
    }

    private var controls: some View {
        let palette = RamblePalette(scheme)
        return HStack(spacing: 12) {
            if phase.canCancel {
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(palette.inset, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(tr("Cancelar (Esc)"))
                .accessibilityLabel(tr("Cancelar captura"))
            }

            switch phase {
            case .listening:
                if preview.previewFailed {
                    Text(tr("Prévia indisponível"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Waveform(meter: preview.meter)
                    .foregroundStyle(palette.blue)
                    .accessibilityLabel(tr("Gravando"))
            case .connecting:
                progress(tr("Preparando transcrição…"))
            case .finishing:
                progress(tr("Finalizando…"))
            case .review:
                Text(tr("Revise as tarefas"))
                    .font(.system(size: 13, weight: .medium))
            case .sending:
                progress(tr("Enviando ao Things…"))
            case .notice(let message, let success):
                if success {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.blue)
                        .accessibilityHidden(true)
                }
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 275)
            }

            if phase.canEditTasks {
                Button(action: confirm) {
                    Image(systemName: "return")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 28)
                        .background(RamblePalette.action, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("Adicionar ao Things (Enter)"))
                .accessibilityLabel(tr("Adicionar ao Things"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 17))
        .overlay {
            RoundedRectangle(cornerRadius: 17).strokeBorder(palette.line, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.34 : 0.18), radius: 9, y: 4)
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

private struct TaskCard: View {
    @Environment(\.colorScheme) private var scheme
    let task: SpokenTask
    let expanded: Bool
    let editable: Bool
    @Binding var destination: ThingsDestination?
    let destinationList: TaskPreview.DestinationList
    let loadDestinations: () -> Void
    let toggleDetails: () -> Void
    let remove: () -> Void

    var body: some View {
        let palette = RamblePalette(scheme)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.secondary.opacity(0.58), lineWidth: 1.2)
                    .frame(width: 13, height: 13)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .semibold))
                    if expanded, let notes = task.notes {
                        Text(notes)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    }
                    if expanded, !task.checklist.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(task.checklist.enumerated()), id: \.offset) { _, item in
                                Label(item, systemImage: "circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 3) {
                    if task.notes != nil || !task.checklist.isEmpty {
                        icon(expanded ? "chevron.up" : "chevron.down", label: expanded ? tr("Recolher detalhes") : tr("Mostrar detalhes"),
                             action: toggleDetails)
                    }
                    if editable {
                        icon("xmark", label: tr("Remover tarefa"), action: remove)
                    }
                }
            }
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    if let deadline = task.deadline {
                        dateLabel(deadline, symbol: "flag", name: tr("Prazo"))
                            .foregroundStyle(scheme == .dark ? Color(red: 1, green: 0.53, blue: 0.57) : .red)
                    }
                    if let when = task.when {
                        dateLabel(when, symbol: "calendar", name: tr("Agendada para"))
                            .foregroundStyle(palette.blue)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                ViewThatFits(in: .horizontal) {
                    destinationControl.fixedSize(horizontal: true, vertical: false)
                    destinationControl
                }
            }
            .padding(.leading, 23)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(palette.line, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.22 : 0.13), radius: 6, y: 2)
    }

    private var destinationLabel: some View {
        Label(destination?.name ?? defaultDestinationName,
              systemImage: destination.map { $0.isProject ? "checklist" : "square.stack" } ?? "tray")
            .lineLimit(1)
    }

    private var defaultDestinationName: String {
        task.when == nil ? tr("Caixa de Entrada") : tr("Sem projeto ou área")
    }

    private var destinationControl: some View {
        Group {
            if editable {
                Menu {
                    Button(defaultDestinationName) { destination = nil }
                    switch destinationList {
                    case .unloaded:
                        Button(tr("Carregar projetos e áreas"), action: loadDestinations)
                    case .loading:
                        Text(tr("Carregando projetos e áreas…"))
                    case .loaded(let choices):
                        ForEach(choices) { choice in
                            Button {
                                destination = choice
                            } label: {
                                Label(choice.name, systemImage: choice.isProject ? "checklist" : "square.stack")
                            }
                        }
                        if choices.isEmpty { Text(tr("Nenhum projeto ou área")) }
                    case .failed(let message):
                        Text(message)
                        Button(tr("Tentar novamente"), action: loadDestinations)
                    }
                } label: {
                    destinationLabel
                }
                .menuStyle(.borderlessButton)
                .help(tr("Escolher destino no Things"))
            } else {
                destinationLabel
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func icon(_ name: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func dateLabel(_ value: String, symbol: String, name: String) -> some View {
        Label(Self.displayDate(value), systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .accessibilityLabel("\(name) \(Self.displayDate(value))")
    }

    private static func displayDate(_ value: String) -> String {
        let parts = value.components(separatedBy: "@")
        let date = parts[0].split(separator: "-").reversed().joined(separator: "/")
        return parts.count == 2 ? "\(date) · \(parts[1])" : date
    }
}

private struct Waveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let meter: VoiceMeter?
    private static let quiet = [Float](repeating: 0, count: VoiceMeter.barCount)
    private static let still: [Float] = [0, 0, 0.05, 0.1, 0.2, 0.4, 0.27, 0.65, 0.5,
                                        0.74, 0.55, 0.33, 0.42, 0.22, 0.1, 0.05, 0]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { _ in
            let levels = reduceMotion ? Self.still : (meter?.levels ?? Self.quiet)
            HStack(spacing: 3) {
                ForEach(levels.indices, id: \.self) { index in
                    let level = Double(levels[index])
                    let edge = Double(min(index, levels.count - 1 - index))
                    Capsule()
                        .frame(width: 3, height: 3.5 + 20 * level)
                        .opacity((0.28 + 0.72 * level) * min(1, 0.45 + edge * 0.23))
                }
            }
            .frame(height: 24)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.085), value: levels)
        }
    }
}
