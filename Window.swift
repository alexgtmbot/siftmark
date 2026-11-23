import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum Review: Equatable {
    case folder, installers, uninstall(String)
    var isUninstall: Bool { if case .uninstall = self { return true }; return false }
}

private struct TrashBatch: Identifiable {
    let id = UUID()
    let items: [Item]
}

private struct DiskIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let resolved: String

    init?(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        resolved = url.resolvingSymlinksInPath().path
    }
}

private struct Item: Identifiable {
    let url: URL
    let bytes: Int64
    let folder: Bool
    let identity: DiskIdentity?
    let partial: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

@main
struct SiftmarkApp: App {
    var body: some Scene {
        Window("Siftmark", id: "main") { Browser() }
            .defaultSize(width: 820, height: 530)
    }
}

struct Browser: View {
    @State private var root: URL?
    @State private var rows = [Item]()
    @State private var selected = Set<URL>()
    @State private var batch: TrashBatch?
    @State private var sort = [KeyPathComparator(\Item.bytes, order: .reverse)]
    @State private var worker: Process?
    @State private var message = "Choose a folder to inspect its disk usage."
    @State private var total: Double = 0

    @State private var review = Review.folder
    @State private var reviewError: String?
    @State private var isTrashing = false
    @State private var deniedItems = [URL]()
    @State private var errorTitle = "Review unavailable"

    private func scan(_ url: URL, as mode: Review = .folder) {
        guard !isTrashing else { return }
        review = mode
        if let worker, worker.isRunning { worker.terminate() }
        root = url
        selected.removeAll()
        rows = []
        message = "Scanning…"
        let task = Process()
        task.executableURL = Bundle.main.url(forAuxiliaryExecutable: "siftmark-scan")
        switch mode {
        case .folder: task.arguments = [url.path]
        case .installers: task.arguments = [url.path, "installers"]
        case .uninstall(let id): task.arguments = [url.path, "uninstall", id]
        }
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch {
            worker = nil
            message = error.localizedDescription
            return
        }
        worker = task
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            var items = [Item]()
            var skipped = 0
            for record in data.split(separator: 0) {
                let fields = record.split(separator: 9, maxSplits: 2)
                guard fields.count == 3, let size = Int64(String(decoding: fields[0], as: UTF8.self)),
                      let name = String(bytes: fields[2], encoding: .utf8) else { skipped += 1; continue }
                let child = mode.isUninstall ? URL(fileURLWithPath: name) : url.appendingPathComponent(name)
                let kind = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                items.append(Item(url: child, bytes: size, folder: kind?.isDirectory == true && kind?.isSymbolicLink != true, identity: DiskIdentity(child), partial: fields[1].first == 49))
            }
            DispatchQueue.main.async {
                guard worker === task else { return }
                worker = nil
                total = items.reduce(0) { $0 + Double($1.bytes) }
                rows = items.sorted(using: sort)
                message = task.terminationStatus == 0 && skipped == 0
                    ? "\(items.count) \(items.count == 1 ? "item" : "items") · Allocated space · \(items.filter(\.partial).count) partial"
                    : "Incomplete scan. Some entries could not be read."
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url { scan(url) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Review"
        guard panel.runModal() == .OK, let app = panel.url else { return }
        guard let id = Bundle(url: app)?.bundleIdentifier else {
            errorTitle = "Review unavailable"
            deniedItems = []
            reviewError = "This app has no readable bundle identifier."
            return
        }
        scan(app, as: .uninstall(id))
    }

    private static func moveToTrash(_ item: Item) throws {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            return
        } catch {
            let cause = error as NSError
            let denied = (cause.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(cause.code))
                || (cause.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(cause.code))
            guard denied else { throw error }
        }

        guard let identity = item.identity, identity == DiskIdentity(item.url) else {
            throw NSError(domain: "Siftmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "This item changed since the scan."])
        }
        // Pass the exact file URL as an Apple event descriptor, independent of Finder selection.
        let event = NSAppleEventDescriptor(eventClass: kAECoreSuite, eventID: kAEDelete,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let target = NSAppleEventDescriptor(fileURL: item.url)
        guard let alias = target.coerce(toDescriptorType: typeAlias) else {
            throw CocoaError(.fileReadUnknown)
        }
        event.setParam(alias, forKeyword: keyDirectObject)
        let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 600)
        if let number = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, number != 0 {
            let detail = reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(number),
                userInfo: [NSLocalizedDescriptionKey: detail ?? "Finder could not move this item to Trash (\(number))."])
        }
    }

    @MainActor private func trash(_ items: [Item]) async {
        defer { isTrashing = false }
        var moved = Set<URL>()
        var failures = [String]()
        deniedItems = []
        for item in items {
            if review.isUninstall && NSWorkspace.shared.runningApplications.contains(where: {
                $0.bundleURL?.resolvingSymlinksInPath() == root?.resolvingSymlinksInPath()
            }) {
                failures.append("Quit the app before moving it or its related files to Trash.")
                break
            }
            guard let identity = item.identity, identity == DiskIdentity(item.url) else {
                failures.append("\(item.url.path) changed since the scan.")
                continue
            }
            do {
                try await Task.detached { try Self.moveToTrash(item) }.value
                moved.insert(item.url)
            } catch {
                let cause = error as NSError
                if (cause.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(cause.code)) ||
                    (cause.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(cause.code)) {
                    deniedItems.append(item.url)
                }
                if cause.domain == NSOSStatusErrorDomain && cause.code == -128 {
                    failures.append("Canceled. Remaining items were left in place.")
                    break
                }
                if cause.domain == NSOSStatusErrorDomain && cause.code == -1743 {
                    failures.append("Allow Siftmark to control Finder in System Settings → Privacy & Security → Automation, then retry.")
                    break
                }
                failures.append("\(item.url.path): \(error.localizedDescription)")
            }
        }
        rows.removeAll { moved.contains($0.url) }
        selected.subtract(moved)
        total = rows.reduce(0) { $0 + Double($1.bytes) }
        message = "Moved \(moved.count) to Trash · \(rows.count) remaining"
        if !failures.isEmpty {
            errorTitle = "Couldn’t move all selected items to Trash"
            reviewError = ([message] + failures + (deniedItems.isEmpty ? [] : [
                "Reveal the blocked items in Finder and choose File → Move to Trash. Finder may ask for administrator approval."
            ])).joined(separator: "\n\n")
        }
    }

    private var reviewActions: some View {
        Menu("Cleanup Review") {
            Button("Installers in Downloads") {
                if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                    scan(downloads, as: .installers)
                }
            }
            if let root, review == .folder {
                Button("Installers in This Folder") { scan(root, as: .installers) }
            }
            Button("Review App for Uninstall…", action: chooseApp)
        }.fixedSize()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let root {
                HStack {
                    Image(systemName: "folder.fill").font(.title).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(review.isUninstall ? "Bundle-ID matches · " + root.lastPathComponent : review == .installers ? "Installer files" : root.lastPathComponent.isEmpty ? "/" : root.lastPathComponent)
                            .font(.title2.bold()).lineLimit(1)
                        Text(root.path).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer()
                    if worker != nil {
                        ProgressView().controlSize(.small)
                        Button("Cancel Scan") {
                            let task = worker
                            worker = nil
                            if let task, task.isRunning { task.terminate() }
                            message = "Scan canceled."
                        }
                    }
                }.padding()
                Divider()
                Table(rows, selection: $selected, sortOrder: $sort) {
                    TableColumn("Name", value: \.name) { row in
                        Label(review.isUninstall ? row.url.path.replacingOccurrences(of: NSHomeDirectory() + "/", with: "~/", options: .anchored) : row.name, systemImage: row.folder ? "folder.fill" : "doc")
                            .lineLimit(1).truncationMode(.middle).help(row.url.path)
                    }
                    TableColumn("Allocated", value: \.bytes) { row in
                        Text(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file) + (row.partial ? " (partial)" : ""))
                            .monospacedDigit()
                    }.width(min: 110, ideal: 140)
                    TableColumn("Share of scan") { row in
                        let fraction = total > 0 ? Double(row.bytes) / total : 0
                        HStack {
                            ProgressView(value: fraction).progressViewStyle(.linear)
                                .accessibilityHidden(true)
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().frame(width: 42, alignment: .trailing)
                        }
                    }.width(min: 115, ideal: 145)
                }
                .onChange(of: sort) { _, order in rows.sort(using: order) }
                .overlay {
                    if rows.isEmpty {
                        Text(worker == nil ? (message.hasPrefix("0 items") ? (review == .installers ? "No installer files in this folder." : "This folder is empty.") : message) : "Measuring allocated space…")
                            .foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
                Divider()
                HStack {
                    Text(selected.isEmpty ? message : "\(selected.count) selected").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Inspect") { if let url = selected.first { scan(url) } }
                        .disabled(review.isUninstall || selected.count != 1 || !rows.contains { selected.contains($0.url) && $0.folder })
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(selected)) }
                        .disabled(selected.isEmpty)
                    Button("Trash…") {
                        batch = TrashBatch(items: rows.filter { selected.contains($0.url) })
                    }.disabled(selected.isEmpty).keyboardShortcut(.delete, modifiers: .command)
                }.padding(12)
            } else {
                VStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84).accessibilityHidden(true)
                    Text("Inspect folder storage").font(.largeTitle.bold())
                    Text("See which files and folders use the most disk space.").foregroundStyle(.secondary)
                    Button("Choose Folder…", action: choose).buttonStyle(.borderedProminent)
                        .controlSize(.large).keyboardShortcut("o").padding(.top, 4)
                    reviewActions
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 710, minHeight: 350)
        .toolbar {
            if let root {
                reviewActions
                Button("Parent Folder", systemImage: "arrow.up", action: { scan(root.deletingLastPathComponent()) })
                    .disabled(root.path == "/").help("Go to parent folder")
                Button("Refresh", systemImage: "arrow.clockwise", action: { scan(root, as: review) })
                    .keyboardShortcut("r").help("Scan again (⌘R)")
                Button("Choose Folder…", systemImage: "folder", action: choose)
                    .keyboardShortcut("o").help("Choose folder (⌘O)")
            }
        }
        .disabled(isTrashing)
        .onDisappear { if let worker, worker.isRunning { worker.terminate() } }
        .sheet(item: $batch) { request in
            let pending = request.items
            VStack(alignment: .leading, spacing: 14) {
                Text("Move \(pending.count == 1 ? pending[0].name : "\(pending.count) items") to Trash?")
                    .font(.title2.bold())
                List(pending) { item in Text(item.url.path).textSelection(.enabled) }
                HStack {
                    Spacer()
                    Button("Cancel") { batch = nil }.keyboardShortcut(.cancelAction)
                    Button("Move to Trash", role: .destructive) {
                        batch = nil
                        isTrashing = true
                        Task { await trash(pending) }
                    }
                }
            }.padding().frame(minWidth: 500, minHeight: 240)
        }
        .alert(errorTitle, isPresented: Binding(get: { reviewError != nil }, set: { if !$0 { reviewError = nil } })) {
            if !deniedItems.isEmpty {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(deniedItems) }
            }
            Button("OK", role: .cancel) { reviewError = nil }
        } message: { Text(reviewError ?? "") }
    }
}
