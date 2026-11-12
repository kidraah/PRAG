import AppKit
import Observation
import UniformTypeIdentifiers
import PRAGCore

enum ShelfMode: Equatable {
    case collapsed
    case peek       // a drag is approaching: magnetic glow, slight swell
    case expanded
}

enum ExpansionReason: Equatable {
    case hover, drag, shiftTap, shake, hotkey, screenshot, statusMenu

    /// Reasons tied to an in-flight drag: the shelf closes again when the drag ends elsewhere.
    var isDragDriven: Bool { self == .drag || self == .shiftTap || self == .shake }
}

enum ShelfPage: Equatable { case shelf, settings }
enum ShelfViewMode: String { case grid, list }

struct PipelineJob: Identifiable, Equatable {
    let id = UUID()
    let pipeline: ActionPipeline
    let inputIDs: [UUID]
    var progress: Double = 0
}

/// A user-made tab that items can be parked in.
struct ShelfGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// Tabs across the top of the shelf.
enum ShelfTab: Hashable {
    case recent                 // everything not parked in a group (new drops land here)
    case screenshots            // auto-caught screenshots not parked in a group
    case group(UUID)

    var groupID: UUID? {
        if case .group(let id) = self { return id }
        return nil
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var message: String
    var isError = false
}

/// Central app state. Everything UI-facing is MainActor; heavy work runs in PRAGCore actors.
@MainActor
@Observable
final class AppState {
    // Shelf contents
    private(set) var items: [StashedItem] = []
    var selection: Set<UUID> = []
    private(set) var jobs: [PipelineJob] = []
    /// Item IDs that were just created, for a one-shot "pop" highlight.
    private(set) var freshItemIDs: Set<UUID> = []

    // Presentation
    private(set) var mode: ShelfMode = .collapsed
    private(set) var openScreenID: CGDirectDisplayID?
    private(set) var reason: ExpansionReason?
    var page: ShelfPage = .shelf
    var viewMode: ShelfViewMode = .grid {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    var isPinned = false
    var isDropTargeted = false
    var isExternalDragActive = false
    var isPointerInside = false

    // Chain builder
    var isBuildingChain = false
    var chainDraft: [ActionStep] = []

    var toast: Toast?

    // Tabs / groups
    private(set) var groups: [ShelfGroup] = []
    var activeTab: ShelfTab = .recent {
        didSet { if oldValue != activeTab { selection = []; isBuildingChain = false; chainDraft = [] } }
    }
    /// Tab under an in-flight drag (highlighted; a drop there parks items in it).
    var dropTargetTab: ShelfTab?
    /// Tab frames in the shelf's coordinate space (top-left origin), for AppKit drop hit-testing.
    @ObservationIgnored var tabFrames: [ShelfTab: CGRect] = [:]
    /// Set while an item drag from the shelf lands on one of its own tabs.
    @ObservationIgnored var internalMoveHappened = false
    /// Makes the open shelf's panel key (for text entry). Set by AppDelegate.
    @ObservationIgnored var keyFocusRequest: (() -> Void)?

    func requestKeyFocus() { keyFocusRequest?() }

    let settings = Settings()

    @ObservationIgnored weak var quickLook: QuickLookCoordinator?
    /// Live check of whether the pointer is over the open shelf (set by AppDelegate).
    @ObservationIgnored var pointerProbe: (() -> Bool)?

    @ObservationIgnored let storage = StashStorageService(
        rootURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PRAG", isDirectory: true))
    @ObservationIgnored private(set) lazy var chainer = PipelineChainer(storage: storage)
    @ObservationIgnored private var jobTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var collapseWork: DispatchWorkItem?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    @ObservationIgnored private var expiryTimers: [UUID: DispatchWorkItem] = [:]

    init() {
        if let raw = UserDefaults.standard.string(forKey: "viewMode"), let m = ShelfViewMode(rawValue: raw) {
            viewMode = m
        }
        if let data = UserDefaults.standard.data(forKey: "groups"),
           let saved = try? JSONDecoder().decode([ShelfGroup].self, from: data) {
            groups = saved
        }
    }

    // MARK: - Derived

    var isOpen: Bool { mode != .collapsed }
    var selectedItems: [StashedItem] { items.filter { selection.contains($0.id) } }
    /// Items shown in the active tab.
    var visibleItems: [StashedItem] { items(in: activeTab) }
    /// Actions apply to the selection, or to the whole tab when nothing is selected.
    var actionTargets: [StashedItem] { selection.isEmpty ? visibleItems : selectedItems }

    func items(in tab: ShelfTab) -> [StashedItem] {
        switch tab {
        case .recent: items.filter { $0.groupID == nil }
        case .screenshots: items.filter { $0.groupID == nil && $0.origin == .screenshot }
        case .group(let id): items.filter { $0.groupID == id }
        }
    }

    /// Screenshots tab shows while Auto-Catch is on or any caught screenshot is unparked.
    var showsScreenshotsTab: Bool {
        settings.autoCatchScreenshots || items.contains { $0.groupID == nil && $0.origin == .screenshot }
    }

    /// Where new drops go: the open group, otherwise Recent.
    private var dropGroupID: UUID? { activeTab.groupID }
    var actionKinds: Set<ItemKind> { Set(actionTargets.map(\.kind)) }

    func mode(for screen: CGDirectDisplayID) -> ShelfMode {
        openScreenID == screen ? mode : .collapsed
    }

    // MARK: - Presentation state machine

    func expand(on screen: CGDirectDisplayID, reason: ExpansionReason) {
        cancelScheduledCollapse()
        if openScreenID != screen { page = .shelf }
        openScreenID = screen
        // Don't downgrade a stronger reason (e.g. hotkey) to a weaker drag one.
        if mode != .expanded || self.reason == nil || self.reason?.isDragDriven == true {
            self.reason = reason
        }
        mode = .expanded
    }

    func peek(on screen: CGDirectDisplayID) {
        guard mode == .collapsed || (openScreenID == screen && mode == .peek) || openScreenID != screen else { return }
        if mode == .expanded && openScreenID == screen { return }
        cancelScheduledCollapse()
        openScreenID = screen
        mode = .peek
        reason = .drag
    }

    func collapse() {
        cancelScheduledCollapse()
        guard mode != .collapsed else { return }
        mode = .collapsed
        reason = nil
        isBuildingChain = false
        chainDraft = []
        isDropTargeted = false
    }

    /// After a successful drop, behave like a hover-opened shelf: stay while the pointer is
    /// over it, close shortly after it leaves.
    func droppedOnShelf() {
        reason = .hover
        scheduleCollapse(after: 2.2)
    }

    func toggle(on screen: CGDirectDisplayID, reason: ExpansionReason) {
        if mode == .expanded && openScreenID == screen { collapse() } else { expand(on: screen, reason: reason) }
    }

    /// Collapse later unless something (pointer re-entry, drop, pin) cancels it.
    func scheduleCollapse(after delay: TimeInterval) {
        guard !isPinned, mode != .collapsed else { return }
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.collapseWork = nil
                guard !self.isPinned, !self.isDropTargeted else { return }
                if self.pointerProbe?() ?? self.isPointerInside { return }
                self.collapse()
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    var isCollapseScheduled: Bool { collapseWork != nil }

    func cancelScheduledCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    // MARK: - Items

    func restore() {
        Task {
            let loaded = await storage.load()
            // Merge: anything stashed before the restore finished stays.
            let fresh = self.items.filter { new in !loaded.contains { $0.url == new.url } }
            self.items = loaded + fresh
        }
    }

    @discardableResult
    func add(urls: [URL], origin: ItemOrigin = .dropped, group: UUID? = nil) -> [StashedItem] {
        var added: [StashedItem] = []
        for url in urls {
            let std = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: std.path) else { continue }
            let target = origin == .screenshot ? nil : (group ?? dropGroupID)
            if let existing = items.firstIndex(where: { $0.url.standardizedFileURL == std }) {
                // Already parked elsewhere: bring it to the tab it was dropped on.
                if origin != .screenshot && items[existing].groupID != target {
                    items[existing].groupID = target
                    scheduleSave()
                }
                continue
            }
            let item = StashedItem(url: std, bookmark: storage.makeBookmark(for: std), origin: origin,
                                   groupID: target)
            added.append(item)
        }
        insert(added)
        if origin == .screenshot && settings.screenshotExpiry {
            for item in added { scheduleExpiry(for: item.id, after: 5 * 60) }
        }
        return added
    }

    private func insert(_ new: [StashedItem], after anchor: UUID? = nil) {
        guard !new.isEmpty else { return }
        if let anchor, let idx = items.firstIndex(where: { $0.id == anchor }) {
            items.insert(contentsOf: new, at: idx + 1)
        } else {
            items.append(contentsOf: new)
        }
        let ids = Set(new.map(\.id))
        freshItemIDs.formUnion(ids)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated { self?.freshItemIDs.subtract(ids) }
        }
        scheduleSave()
    }

    func remove(_ ids: Set<UUID>) {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        for id in ids { expiryTimers.removeValue(forKey: id)?.cancel() }
        let storage = self.storage
        Task {
            // Only workspace outputs are deleted — never the user's source files.
            for item in removed where item.isProcessed || item.origin == .clipboard {
                await storage.discardOutput(of: item)
            }
        }
        scheduleSave()
    }

    func removeSelected() { remove(selection) }
    /// Clears the active tab (other tabs are left alone).
    func clearAll() { remove(Set(visibleItems.map(\.id))) }
    func clearEverything() { remove(Set(items.map(\.id))) }

    func selectAll() { selection = Set(visibleItems.map(\.id)) }

    // MARK: - Groups

    @discardableResult
    func createGroup(named name: String? = nil, moving ids: Set<UUID> = []) -> ShelfGroup {
        let base = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let group = ShelfGroup(name: base ?? nextGroupName())
        groups.append(group)
        saveGroups()
        if !ids.isEmpty { move(ids, to: group.id) }
        return group
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = trimmed
        saveGroups()
    }

    /// Deletes the tab; its items go back to Recent (nothing is removed).
    func deleteGroup(_ id: UUID) {
        for i in items.indices where items[i].groupID == id { items[i].groupID = nil }
        groups.removeAll { $0.id == id }
        if activeTab == .group(id) { activeTab = .recent }
        saveGroups()
        scheduleSave()
    }

    func move(_ ids: Set<UUID>, to group: UUID?) {
        guard !ids.isEmpty else { return }
        for i in items.indices where ids.contains(items[i].id) { items[i].groupID = group }
        selection.subtract(ids)
        scheduleSave()
        let name = group.flatMap { g in groups.first { $0.id == g }?.name } ?? "Recent"
        showToast("Moved \(ids.count) to \(name)", symbol: "folder")
    }

    func groupName(_ id: UUID) -> String { groups.first { $0.id == id }?.name ?? "Group" }

    private func nextGroupName() -> String {
        var n = groups.count + 1
        while groups.contains(where: { $0.name == "Group \(n)" }) { n += 1 }
        return "Group \(n)"
    }

    private func saveGroups() {
        if let data = try? JSONEncoder().encode(groups) { UserDefaults.standard.set(data, forKey: "groups") }
    }

    /// Finder-like click selection.
    func click(_ id: UUID, command: Bool, shift: Bool) {
        if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if shift, case let visible = visibleItems,
                  let anchor = visible.firstIndex(where: { selection.contains($0.id) }),
                  let target = visible.firstIndex(where: { $0.id == id }) {
            let range = anchor <= target ? anchor...target : target...anchor
            selection = Set(visible[range].map(\.id))
        } else {
            selection = [id]
        }
    }

    private func scheduleExpiry(for id: UUID, after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.selection.contains(id) else { return }
                self.remove([id])
            }
        }
        expiryTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let snapshot = self.items
                let storage = self.storage
                Task { try? await storage.save(snapshot) }
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Ingest from a drag/paste

    /// Reads files, file promises, URLs, images and text from a pasteboard.
    func ingest(pasteboard: NSPasteboard) {
        // 1) Plain file URLs (Finder, most apps)
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            add(urls: fileURLs)
            return
        }
        // 2) File promises (Photos, Mail attachments, browser images)
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            receivePromises(receivers)
            return
        }
        // 3) Web URL → .webloc so it can be dragged back out as a link
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, !url.isFileURL {
            materialize(name: url.host() ?? "Link", ext: "webloc") { dest in
                let plist: [String: String] = ["URL": url.absoluteString]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: dest)
            }
            return
        }
        // 4) Raw image data
        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            materialize(name: "Image", ext: "png") { try png.write(to: $0) }
            return
        }
        // 5) Text
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? "Text"
            let name = String(firstLine.prefix(32)).trimmingCharacters(in: .whitespaces)
            materialize(name: name.isEmpty ? "Text" : name, ext: "txt") { try Data(text.utf8).write(to: $0) }
        }
    }

    private func materialize(name: String, ext: String, write: @escaping @Sendable (URL) throws -> Void) {
        let storage = self.storage
        let group = dropGroupID
        Task {
            do {
                let dir = try await storage.makeStepDirectory()
                let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                let dest = dir.appendingPathComponent(safe).appendingPathExtension(ext)
                try write(dest)
                let item = StashedItem(url: dest, origin: .clipboard, groupID: group)
                self.insert([item])
            } catch {
                self.showToast("Couldn't stash that: \(error.localizedDescription)", symbol: "exclamationmark.triangle", isError: true)
            }
        }
    }

    private func receivePromises(_ receivers: [NSFilePromiseReceiver]) {
        let storage = self.storage
        let group = dropGroupID
        Task {
            guard let dir = try? await storage.makeStepDirectory() else { return }
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, error in
                    guard error == nil else { return }
                    MainActor.assumeIsolated {
                        let item = StashedItem(url: url, origin: .clipboard, groupID: group)
                        self.insert([item])
                    }
                }
            }
        }
    }

    // MARK: - Pipelines

    func run(_ pipeline: ActionPipeline, on targets: [StashedItem]? = nil) {
        let inputs = targets ?? actionTargets
        guard !inputs.isEmpty else { return }
        guard pipeline.isApplicable(kinds: Set(inputs.map(\.kind)), count: inputs.count) else {
            showToast("\(pipeline.name) doesn't apply to this selection", symbol: "nosign", isError: true)
            return
        }
        var job = PipelineJob(pipeline: pipeline, inputIDs: inputs.map(\.id))
        job.progress = 0
        jobs.append(job)
        let jobID = job.id
        let anchor = inputs.last?.id
        let sourceGroup = inputs.first?.groupID
        let chainer = self.chainer

        let task = Task { [weak self] in
            do {
                let output = try await chainer.run(pipeline, on: inputs) { value in
                    Task { @MainActor in self?.updateProgress(jobID, value) }
                }
                guard let self else { return }
                self.finishJob(jobID)
                switch output {
                case .items(var produced):
                    for i in produced.indices { produced[i].groupID = sourceGroup }
                    self.insert(produced, after: anchor)
                    // Select the outputs only if they're in the tab being looked at.
                    let visible = Set(self.visibleItems.map(\.id))
                    self.selection = Set(produced.map(\.id)).intersection(visible)
                    self.announce(produced, pipeline: pipeline)
                case .text(let text):
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self.showToast(text.isEmpty ? "No text found" : "Copied \(text.count) characters", symbol: "doc.on.clipboard")
                }
            } catch {
                guard let self else { return }
                self.finishJob(jobID)
                if Task.isCancelled || (error as? PipelineError) == .cancelled || error is CancellationError {
                    self.showToast("Cancelled \(pipeline.name)", symbol: "xmark.circle")
                } else {
                    self.showToast(error.localizedDescription, symbol: "exclamationmark.triangle", isError: true)
                }
            }
        }
        jobTasks[jobID] = task
    }

    func cancel(job id: UUID) {
        jobTasks[id]?.cancel()
    }

    private func updateProgress(_ id: UUID, _ value: Double) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].progress = max(jobs[idx].progress, min(1, value))
    }

    private func finishJob(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        jobTasks[id] = nil
    }

    private func announce(_ produced: [StashedItem], pipeline: ActionPipeline) {
        let before = produced.compactMap(\.delta).reduce(Int64(0)) { $0 + $1.before }
        let after = produced.compactMap(\.delta).reduce(Int64(0)) { $0 + $1.after }
        if before > 0 {
            let d = ByteDelta(before: before, after: after)
            showToast("\(pipeline.name) · \(d.percentString) · \(d.summary)", symbol: "checkmark.circle.fill")
        } else {
            showToast("\(pipeline.name) done", symbol: "checkmark.circle.fill")
        }
    }

    // MARK: - Chain builder

    func appendToChain(_ step: ActionStep) {
        guard chainDraft.count < 3 else { return }
        chainDraft.append(step)
    }

    var chainDraftPipeline: ActionPipeline {
        ActionPipeline(name: "Custom Chain", symbol: "link", steps: chainDraft)
    }

    /// Steps that may follow the current draft (or start it).
    func chainCandidates() -> [ActionStep] {
        let all = ActionCatalog.singleActions(kinds: actionKinds, count: actionTargets.count)
        guard let last = chainDraft.last else { return all }
        guard let out = last.outputKind, !last.isTerminalText else { return [] }
        let pool = ActionCatalog.singleActions(kinds: [out], count: out == .pdf ? 1 : actionTargets.count)
        return pool.filter { $0.acceptedKinds.contains(out) && $0 != last }
    }

    // MARK: - Toasts

    func showToast(_ message: String, symbol: String, isError: Bool = false) {
        toast = Toast(symbol: symbol, message: message, isError: isError)
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 4 : 2.6), execute: work)
    }
}
