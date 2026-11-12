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
    case sending
    case notice(String, success: Bool)

    var canCancel: Bool { self != .sending }
    var canConfirm: Bool { self == .listening || self == .connecting }
}

@MainActor
private final class TaskPreview: ObservableObject {
    @Published var tasks: [SpokenTask] = []
    @Published var expanded: Set<String> = []
}

@MainActor
final class CapturePanel: NSPanel {
    var confirm: (() -> Void)?
    var cancel: (() -> Void)?
    private var host: NSHostingController<CaptureView>?
    private var anchorScreen: NSScreen?
    private var phase: CapturePhase = .connecting
    private let preview = TaskPreview()
    private var resizeTask: Task<Void, Never>?
    private(set) var dismissedTitles: Set<String> = []

    func resetPreview() {
        dismissedTitles.removeAll()
        preview.expanded.removeAll()
        preview.tasks.removeAll()
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
        title = "Captura do Ramble"
    }

    override var canBecomeKey: Bool { true }

    func render(_ phase: CapturePhase, tasks: [SpokenTask] = [], meter: VoiceMeter? = nil, previewFailed: Bool = false) {
        self.phase = phase
        if !isVisible {
            anchorScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? .main
        }
        guard let visible = (anchorScreen ?? .main)?.visibleFrame else { return }

        let view = CaptureView(
            phase: phase, preview: preview, meter: meter, previewFailed: previewFailed,
            cardWidth: min(408, visible.width - 42),
            maxCardsHeight: max(150, min(490, visible.height - 154)),
            confirm: { [weak self] in self?.confirm?() },
            cancel: { [weak self] in self?.cancel?() },
            toggleDetails: { [weak self] task in self?.toggleDetails(task) },
            remove: { [weak self] task in self?.remove(task) }
        )
        if let host {
            host.rootView = view
        } else {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = []
            contentViewController = host
            self.host = host
        }
        updatePreview(visibleTasks(tasks))
        if !isVisible { makeKeyAndOrderFront(nil) }
    }

    private func toggleDetails(_ task: SpokenTask) {
        withAnimation(animation) {
            if !preview.expanded.insert(task.previewKey).inserted { preview.expanded.remove(task.previewKey) }
        }
        resize()
    }

    private func remove(_ task: SpokenTask) {
        guard phase == .listening else { return }
        dismissedTitles.insert(task.previewKey)
        updatePreview(visibleTasks(preview.tasks))
    }

    private var animation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.19)
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
        let root = host.rootView
        let sizing = NSHostingController(rootView: root)
        let size = sizing.sizeThatFits(in: NSSize(width: root.cardWidth + 32, height: root.maxCardsHeight + 120))
        let target = NSRect(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 42,
                            width: ceil(size.width), height: ceil(size.height))
        if isVisible, animation != nil, (target.height < frame.height || target.width < frame.width) {
            resizeTask = Task {
                try? await Task.sleep(for: .milliseconds(210))
                if !Task.isCancelled { setFrame(target, display: true) }
            }
        } else {
            setFrame(target, display: true)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, phase.canCancel {
            cancel?()
        } else if event.type == .keyDown, [36, 76].contains(event.keyCode), phase.canConfirm, !event.isARepeat {
            confirm?()
        } else {
            super.sendEvent(event)
        }
    }
}

private struct CaptureView: View {
    @Environment(\.colorScheme) private var scheme
    let phase: CapturePhase
    @ObservedObject var preview: TaskPreview
    let meter: VoiceMeter?
    let previewFailed: Bool
    let cardWidth: CGFloat
    let maxCardsHeight: CGFloat
    let confirm: () -> Void
    let cancel: () -> Void
    let toggleDetails: (SpokenTask) -> Void
    let remove: (SpokenTask) -> Void

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
            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var cards: some View {
        VStack(spacing: 6) {
            ForEach(preview.tasks, id: \.previewKey) { task in
                TaskCard(
                    task: task, expanded: preview.expanded.contains(task.previewKey),
                    removable: phase == .listening,
                    toggleDetails: { toggleDetails(task) },
                    remove: { remove(task) }
                )
                .transition(.offset(y: 7).combined(with: .opacity))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Prévia das tarefas")
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
                .help("Cancelar (Esc)")
                .accessibilityLabel("Cancelar captura")
            }

            switch phase {
            case .listening:
                if previewFailed {
                    Text("Prévia indisponível")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Waveform(meter: meter)
                    .foregroundStyle(palette.blue)
                    .accessibilityLabel("Gravando")
            case .connecting:
                progress("Conectando…")
            case .finishing:
                progress("Finalizando…")
            case .sending:
                progress("Enviando ao Things…")
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

            if phase == .listening {
                Button(action: confirm) {
                    Image(systemName: "return")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 28)
                        .background(RamblePalette.action, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Adicionar ao Things (Enter)")
                .accessibilityLabel("Adicionar ao Things")
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
    let removable: Bool
    let toggleDetails: () -> Void
    let remove: () -> Void

    var body: some View {
        let palette = RamblePalette(scheme)
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
                if let when = task.when {
                    dateLabel(when, symbol: "calendar", name: "Agendada para")
                        .foregroundStyle(palette.blue)
                }
                if let deadline = task.deadline {
                    dateLabel(deadline, symbol: "flag", name: "Prazo")
                        .foregroundStyle(scheme == .dark ? Color(red: 1, green: 0.53, blue: 0.57) : .red)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 3) {
                if task.notes != nil || !task.checklist.isEmpty {
                    icon(expanded ? "chevron.up" : "chevron.down", label: expanded ? "Recolher detalhes" : "Mostrar detalhes",
                         action: toggleDetails)
                }
                if removable {
                    icon("xmark", label: "Remover tarefa", action: remove)
                }
            }
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
        return parts.count == 2 ? "\(date) às \(parts[1])" : date
    }
}

private struct Waveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let meter: VoiceMeter?
    private let weights: [Double] = [0.43, 0.75, 1, 0.83, 0.50]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let energy = reduceMotion ? 0.22 : Double(meter?.level ?? 0)
            HStack(spacing: 4) {
                ForEach(weights.indices, id: \.self) { index in
                    let modulation = 0.83 + 0.17 * sin(context.date.timeIntervalSinceReferenceDate * 12 + Double(index))
                    Capsule()
                        .frame(width: 3.5, height: 4.5 + 19 * weights[index] * energy * modulation)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.11), value: energy)
                }
            }
            .frame(width: 58, height: 24)
        }
    }
}
