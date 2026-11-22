import Foundation
import Observation

/// Owns the copy queue. The heavy lifting runs off the main actor; only job
/// state is mutated here so the UI can read it directly.
@MainActor
@Observable
final class TransferCenter {
    static let shared = TransferCenter()

    private(set) var jobs: [TransferJob] = []
    /// Set by the files window so conflicts can be resolved with a sheet.
    var conflictHandler: ((FileConflict) async -> (ConflictChoice, Bool))?
    var onFinished: (() -> Void)?

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var pending: [UUID] = []
    private var running = 0
    private var lastNotification = Date.distantPast
    private let limit = 3

    var activeCount: Int { jobs.filter(\.state.isActive).count }
    var aggregateSpeed: Double {
        jobs.filter(\.state.isActive).reduce(0) { $0 + $1.speed }
    }
    var activeJobs: [TransferJob] {
        jobs.filter(\.state.isActive)
    }

    @discardableResult
    func enqueue(
        items: [FileItem],
        from source: any FileBackend,
        to destination: any FileBackend,
        directory: String
    ) -> [UUID] {
        guard !items.isEmpty else { return [] }
        var ids: [UUID] = []
        for item in items {
            let job = TransferJob(
                source: item,
                sourceBackend: source,
                destinationBackend: destination,
                destinationDirectory: directory,
                destinationName: item.name
            )
            jobs.append(job)
            pending.append(job.id)
            ids.append(job.id)
        }
        pump()
        return ids
    }

    func cancel(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state.isActive else { return }
        jobs[index].state = .cancelled
        tasks[id]?.cancel()
    }

    func cancelAll() {
        for job in activeJobs { cancel(id: job.id) }
    }

    func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
    }

    // MARK: - Scheduling

    private func pump() {
        while running < limit, let id = pending.first {
            pending.removeFirst()
            running += 1
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                await self.run(id)
            }
        }
    }

    private func run(_ id: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            running -= 1
            pump()
            return
        }
        var job = jobs[index]
        job.state = .preparing
        jobs[index] = job
        postChange()

        do {
            try Task.checkCancellation()
            let totals = try await job.sourceBackend.measure(job.source.path)
            await setTotals(id: id, bytes: totals.bytes, files: totals.files)

            try Task.checkCancellation()
            try await copyTree(
                job.source,
                from: job.sourceBackend,
                to: job.destinationBackend,
                directory: job.destinationDirectory,
                jobID: id
            )
            try Task.checkCancellation()
            await finish(id: id, state: .finished, message: nil)
        } catch is CancellationError {
            await finish(id: id, state: .cancelled, message: nil)
        } catch {
            await finish(id: id, state: .failed, message: error.localizedDescription)
        }

        tasks[id] = nil
        running -= 1
        pump()
        onFinished?()
    }

    // MARK: - Main-actor state updates

    private func setTotals(id: UUID, bytes: Int64, files: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].bytesTotal = bytes
        jobs[index].filesTotal = files
        jobs[index].state = .running
        postChange()
    }

    private func addBytes(_ id: UUID, _ delta: Int64) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].bytesDone += delta
        let elapsed = Date().timeIntervalSince(jobs[index].started)
        if elapsed > 0.2 {
            jobs[index].speed = Double(jobs[index].bytesDone) / elapsed
        }
        postChange()
    }

    private func fileDone(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].filesDone += 1
        postChange()
    }

    private func skipFile(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].filesDone += 1
        postChange()
    }

    private func finish(id: UUID, state: TransferJob.State, message: String?) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        jobs[index].message = message
        jobs[index].finished = Date()
        jobs[index].speed = 0
        postChange()
    }

    private func resolveConflict(_ id: UUID, _ conflict: FileConflict) async -> ConflictChoice {
        if let index = jobs.firstIndex(where: { $0.id == id }),
           let policy = jobs[index].policy {
            return policy
        }
        let answer = await conflictHandler?(conflict) ?? (.keepBoth, false)
        if answer.1, let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].policy = answer.0
        }
        return answer.0
    }

    private func postChange() {
        let now = Date()
        guard now.timeIntervalSince(lastNotification) > 0.15 else { return }
        lastNotification = now
        NotificationCenter.default.post(name: .bezelTransfersChanged, object: self)
    }

    // MARK: - Off-main work

    /// `nonisolated` so the blocking stream work never runs on the main actor.
    private nonisolated func copyTree(
        _ item: FileItem,
        from source: any FileBackend,
        to destination: any FileBackend,
        directory: String,
        jobID: UUID
    ) async throws {
        try Task.checkCancellation()

        var name = item.name
        var target = FilePath.join(directory, name)
        if try await destination.exists(target) {
            if item.isDirectory {
                // Folders merge, the way Finder merges a copied folder.
            } else {
                let conflict = FileConflict(
                    name: item.name,
                    existingSize: (try? await destination.info(target).size) ?? 0,
                    newSize: item.size,
                    isDirectory: false
                )
                let choice = await resolveConflict(jobID, conflict)
                switch choice {
                case .skip:
                    await skipFile(jobID)
                    return
                case .replace:
                    try await destination.delete([target])
                case .keepBoth:
                    var attempt = 2
                    while try await destination.exists(FilePath.join(directory, FilePath.conflictName(for: item.name, attempt: attempt))) {
                        attempt += 1
                        if attempt > 999 { throw FileError.failed("Too many files with the same name.") }
                    }
                    name = FilePath.conflictName(for: item.name, attempt: attempt)
                    target = FilePath.join(directory, name)
                }
            }
        }

        if item.isDirectory {
            try await destination.makeDirectory(target)
            let children = try await source.list(item.path)
            for child in children {
                try await copyTree(child, from: source, to: destination, directory: target, jobID: jobID)
            }
            return
        }

        let report: @Sendable (Int64) -> Void = { [weak self] delta in
            Task { @MainActor [weak self] in self?.addBytes(jobID, delta) }
        }

        if source.id == destination.id {
            try await source.copy(item.path, to: target)
            report(item.size)
        } else if !source.isRemote && destination.isRemote {
            guard let remote = destination as? ADBBackend else {
                throw FileError.failed("Unsupported device connection.")
            }
            try await remote.upload(URL(fileURLWithPath: item.path), to: target, onBytes: report)
        } else if source.isRemote && !destination.isRemote {
            let localURL = URL(fileURLWithPath: target)
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            try await source.download(item.path, to: localURL, onBytes: report)
        } else {
            // Different Android devices (or two exotic backends): stage on the Mac.
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("bezel-transfer-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try await source.download(item.path, to: staging, onBytes: { _ in })
            try await destination.upload(staging, to: target, onBytes: report)
        }

        await fileDone(jobID)
    }
}
