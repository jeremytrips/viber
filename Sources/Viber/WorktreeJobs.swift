import SwiftUI
import ViberCore

/// Making a worktree for a new session. With a project hook (`pnpm install`, Docker…) this can take minutes,
/// so it shows in the sidebar with its output until the session opens.
@MainActor @Observable
final class WorktreeJob: Identifiable {
    enum Phase: Equatable {
        case running
        case failed(String)
    }

    let id = UUID().uuidString
    let request: NewSessionRequest
    /// The session's title once it opens.
    let title: String
    /// The sidebar section it shows in.
    let project: String
    var phase: Phase = .running
    /// What is happening now.
    var step = "Starting"
    var log = ""
    var startedAt = Date()
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored private var pending = ""
    @ObservationIgnored private var flushScheduled = false

    init(request: NewSessionRequest, title: String) {
        self.request = request
        self.title = title
        self.project = request.folder
    }

    var isRunning: Bool { phase == .running }

    func reset() {
        phase = .running
        step = "Starting"
        log = ""
        pending = ""
        startedAt = Date()
    }

    func apply(_ progress: WorktreeProgress) {
        switch progress {
        case .step(let text): flush(); step = text
        case .output(let text): appendOutput(text)
        }
    }

    /// Output comes in many small pieces; showing them a few times a second keeps the view cheap.
    private func appendOutput(_ text: String) {
        pending += text
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        log += pending
        pending = ""
        if log.count > 120_000 { log = "…\n" + String(log.suffix(100_000)) }
    }
}

struct WorktreeJobRow: View {
    let job: WorktreeJob

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if job.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).lineLimit(1).fontWeight(.medium)
                Text(job.isRunning ? "Setting up the worktree…" : "Worktree setup failed")
                    .font(.caption).foregroundStyle(job.isRunning ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
        .help(job.step)
    }
}

/// The detail view of a worktree being set up: what runs, its output, and what to do if it failed.
struct WorktreeJobView: View {
    @Environment(AppModel.self) private var model
    let job: WorktreeJob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.headline).lineLimit(1)
                    Text((job.request.folder as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if job.isRunning {
                    TimelineView(.periodic(from: job.startedAt, by: 1)) { context in
                        Stat(label: "Running", value: AppModel.duration(context.date.timeIntervalSince(job.startedAt)))
                    }
                    Button("Stop", role: .destructive) { model.cancel(job) }
                        .help("Stop the setup. A hook that is stopped may leave a partly made worktree behind.")
                } else {
                    Button("Dismiss") { model.dismiss(job) }
                    Button("Try Again") { model.retry(job) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                switch job.phase {
                case .running:
                    Label(job.step, systemImage: "gearshape.2").foregroundStyle(.secondary)
                case .failed(let message):
                    Label {
                        Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    Text("No session was started. Fix the problem, then try again; or turn off the worktree option in New Session.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LogView(text: job.log, placeholder: job.isRunning ? "Waiting for output…" : "No output.")
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Command output, monospaced and selectable, kept scrolled to the end while it grows.
struct LogView: View {
    let text: String
    var placeholder = "No output."

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? placeholder : text)
                    .font(.caption.monospaced())
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}
