// Arbor - a Windows-Explorer-style file navigator for macOS.
//
// Left: an expandable folder tree. Right: folder contents as a list or icon grid.
// Tabs with per-tab history, an editable address bar, live filtering, and a
// configurable set of resizable, sortable columns.
//
// Where macOS already provides something, it is used rather than reimplemented:
// Quick Look for previews, NSWorkspace for icons and "Open With", ShareLink for
// the share sheet, and the system sidebar styling.
//
// File operations are limited to the recoverable ones - new folder, rename, and
// move to Trash. There is deliberately no copy/move engine: that needs progress
// reporting, conflict resolution and undo, and a half-built one loses data.

import SwiftUI
import AppKit
import QuickLook

// MARK: - Filesystem helpers

enum FS {
    /// A bundle (.app, .rtfd) is a directory on disk but a single item to a person.
    static func isNavigableDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
    }

    static func displayName(_ url: URL) -> String {
        if url.path == "/" { return "Macintosh HD" }
        let v = try? url.resourceValues(forKeys: [.localizedNameKey])
        return v?.localizedName ?? url.lastPathComponent
    }

    static func icon(_ url: URL) -> NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    /// "rwxr-xr-x" from a POSIX mode.
    static func permissionString(_ mode: Int) -> String {
        let bits = ["r", "w", "x"]
        return (0..<9).map { i in
            (mode & (1 << (8 - i))) != 0 ? bits[i % 3] : "-"
        }.joined()
    }
}

// MARK: - Columns

enum Column: String, CaseIterable, Codable {
    case size, kind, modified, created, added, ext, owner, permissions

    var label: String {
        switch self {
        case .size:        return "Size"
        case .kind:        return "Kind"
        case .modified:    return "Date Modified"
        case .created:     return "Date Created"
        case .added:       return "Date Added"
        case .ext:         return "Extension"
        case .owner:       return "Owner"
        case .permissions: return "Permissions"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .size:        return 82
        case .kind:        return 130
        case .modified:    return 150
        case .created:     return 150
        case .added:       return 150
        case .ext:         return 80
        case .owner:       return 100
        case .permissions: return 100
        }
    }

    var minWidth: CGFloat { 54 }

    var trailing: Bool {
        switch self {
        case .size, .modified, .created, .added: return true
        default: return false
        }
    }

    /// Owner and permissions need a stat() per file, so they are only read when shown.
    var needsPOSIX: Bool { self == .owner || self == .permissions }
}

/// Name is always present and always first, so it is not part of `Column`.
enum SortField: Hashable {
    case name
    case column(Column)

    var label: String {
        switch self {
        case .name: return "Name"
        case .column(let c): return c.label
        }
    }
}

enum ViewMode: String, CaseIterable, Codable {
    case list, icons
    var label: String { self == .list ? "List" : "Icons" }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

// MARK: - Tree model

/// Directories only, loaded when a node is first expanded so the filesystem is
/// never walked ahead of the user.
final class FileNode: ObservableObject, Identifiable, Hashable {
    let url: URL
    let name: String
    let id = UUID()          // per instance: the same path can appear in two sections

    @Published var children: [FileNode] = []
    @Published var isExpanded = false {
        didSet {
            guard isExpanded, !loaded else { return }
            // Reassigning children synchronously here mutates state SwiftUI is
            // in the middle of reading, which duplicates rows. Defer one tick.
            loaded = true
            DispatchQueue.main.async { [weak self] in self?.populate() }
        }
    }
    private var loaded = false

    init(url: URL, label: String? = nil) {
        self.url = url
        self.name = label ?? FS.displayName(url)
    }

    func load() {
        loaded = true
        populate()
    }

    private func populate() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .localizedNameKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        children = items
            .filter(FS.isNavigableDirectory)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { FileNode(url: $0) }
    }

    func reload() {
        loaded = true
        populate()
    }

    /// True when `target` is this node or lives underneath it.
    func contains(_ target: URL) -> Bool {
        let base = url.path == "/" ? "/" : url.path + "/"
        return target.path == url.path || target.path.hasPrefix(base)
    }

    /// Expand down to a path, returning the node that was reached so the caller
    /// can highlight exactly one row.
    @discardableResult
    func reveal(_ target: URL) -> FileNode? {
        guard contains(target) else { return nil }
        if target.path == url.path { return self }
        if !loaded { load() }
        isExpanded = true
        for child in children {
            if let hit = child.reveal(target) { return hit }
        }
        return nil          // inside this node, but not a folder the tree tracks
    }

    static func == (a: FileNode, b: FileNode) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - List model

struct Entry: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    let name: String
    let isFolder: Bool      // navigable directory; bundles count as files
    let isBundle: Bool      // .app and friends: a directory, so it has no own size
    let size: Int64
    let modified: Date
    let created: Date
    let added: Date
    let kind: String
    let ext: String
    let owner: String
    let permissions: String

    func text(for column: Column) -> String {
        switch column {
        case .size:        return (isFolder || isBundle)
                                ? "--"
                                : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        case .kind:        return kind
        case .modified:    return modified.formatted(date: .abbreviated, time: .shortened)
        case .created:     return created == .distantPast ? "--" : created.formatted(date: .abbreviated, time: .shortened)
        case .added:       return added == .distantPast ? "--" : added.formatted(date: .abbreviated, time: .shortened)
        case .ext:         return ext.isEmpty ? "--" : ext
        case .owner:       return owner
        case .permissions: return permissions
        }
    }
}

func readEntries(_ folder: URL, showHidden: Bool, posix: Bool) -> [Entry] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey,
                                  .contentModificationDateKey, .creationDateKey,
                                  .addedToDirectoryDateKey, .localizedNameKey,
                                  .localizedTypeDescriptionKey]
    let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
    let items = (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: keys, options: opts)) ?? []

    return items.map { url in
        let v = try? url.resourceValues(forKeys: Set(keys))
        let isDir = v?.isDirectory ?? false
        let isPkg = v?.isPackage ?? false

        // A stat() per file is too expensive to do unless a column needs it.
        var owner = ""
        var perms = ""
        if posix, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            owner = attrs[.ownerAccountName] as? String ?? ""
            if let mode = attrs[.posixPermissions] as? NSNumber {
                perms = FS.permissionString(mode.intValue)
            }
        }

        return Entry(url: url,
                     name: v?.localizedName ?? url.lastPathComponent,
                     isFolder: isDir && !isPkg,
                     isBundle: isPkg,
                     size: Int64(v?.fileSize ?? 0),
                     modified: v?.contentModificationDate ?? .distantPast,
                     created: v?.creationDate ?? .distantPast,
                     added: v?.addedToDirectoryDate ?? .distantPast,
                     kind: v?.localizedTypeDescription ?? "",
                     ext: url.pathExtension,
                     owner: owner,
                     permissions: perms)
    }
}

func sortEntries(_ list: [Entry], by field: SortField, ascending: Bool) -> [Entry] {
    func before(_ a: Entry, _ b: Entry) -> Bool {
        switch field {
        case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
        case .column(let c):
            switch c {
            case .size:        return a.size < b.size
            case .modified:    return a.modified < b.modified
            case .created:     return a.created < b.created
            case .added:       return a.added < b.added
            case .kind:        return a.kind.localizedStandardCompare(b.kind) == .orderedAscending
            case .ext:         return a.ext.localizedStandardCompare(b.ext) == .orderedAscending
            case .owner:       return a.owner.localizedStandardCompare(b.owner) == .orderedAscending
            case .permissions: return a.permissions < b.permissions
            }
        }
    }
    // Folders always lead, in both sort directions - the Explorer convention.
    let folders = list.filter(\.isFolder).sorted { ascending ? before($0, $1) : before($1, $0) }
    let files = list.filter { !$0.isFolder }.sorted { ascending ? before($0, $1) : before($1, $0) }
    return folders + files
}

// MARK: - Clipboard

enum ClipboardMode { case copy, move }

struct Clipboard {
    var urls: [URL] = []
    var mode: ClipboardMode = .copy
    var isEmpty: Bool { urls.isEmpty }
}

// MARK: - Tabs

struct Tab: Identifiable {
    let id = UUID()
    private(set) var history: [URL]
    private(set) var index: Int

    init(folder: URL) { history = [folder]; index = 0 }

    var folder: URL { history[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < history.count - 1 }
    var title: String { FS.displayName(folder) }

    mutating func navigate(to url: URL) {
        guard url != folder else { return }
        if index < history.count - 1 { history.removeSubrange((index + 1)...) }
        history.append(url)
        index = history.count - 1
    }
    mutating func back() { if canGoBack { index -= 1 } }
    mutating func forward() { if canGoForward { index += 1 } }
}

// MARK: - State

final class AppState: ObservableObject {
    @Published var tabs: [Tab] = [Tab(folder: FileManager.default.homeDirectoryForCurrentUser)]
    @Published var activeID: UUID?
    @Published var favorites: [FileNode] = []
    @Published var locations: [FileNode] = []

    @Published private var allRows: [Entry] = []
    @Published var selected: Set<URL> = []
    @Published var filter = ""
    @Published var sortField: SortField = .name
    @Published var sortAscending = true
    @Published var viewMode: ViewMode = .list
    @Published var showHidden = false

    /// Visible columns, in display order. Name is implicit and always first.
    @Published var columns: [Column] = [.size, .kind, .modified]
    @Published var widths: [Column: CGFloat] = [:]

    /// Cut/copy staging. Also mirrored onto NSPasteboard so Finder can paste it.
    @Published var clipboard = Clipboard()

    // A transfer runs off the main thread and reports progress back to a sheet.
    @Published var opRunning = false
    @Published var opTotal = 0
    @Published var opDone = 0
    @Published var opCurrent = ""
    private var opCancelled = false
    private var lastOperation: [(from: URL, to: URL, mode: ClipboardMode)] = []

    /// Exactly one tree row is highlighted, and navigation unfolds only one tree.
    @Published var activeNode: UUID?
    private var activeRoot: FileNode?

    @Published var addressText = ""
    @Published var focusAddress = false
    @Published var renaming: URL?
    @Published var renameText = ""
    @Published var infoTarget: Entry?
    @Published var previewURL: URL?
    @Published var errorText: String?

    private let defaults = UserDefaults.standard

    init() {
        // Inherit the user's last choices rather than resetting every launch.
        if defaults.object(forKey: "sortAscending") != nil { sortAscending = defaults.bool(forKey: "sortAscending") }
        if let raw = defaults.string(forKey: "sortColumn") {
            sortField = raw == "name" ? .name : (Column(rawValue: raw).map(SortField.column) ?? .name)
        }
        if let raw = defaults.string(forKey: "viewMode"), let m = ViewMode(rawValue: raw) { viewMode = m }
        showHidden = defaults.bool(forKey: "showHidden")
        if let data = defaults.data(forKey: "columns"),
           let saved = try? JSONDecoder().decode([Column].self, from: data) {
            columns = saved
        }
        if let data = defaults.data(forKey: "widths"),
           let saved = try? JSONDecoder().decode([String: CGFloat].self, from: data) {
            for (k, v) in saved { if let c = Column(rawValue: k) { widths[c] = v } }
        }
    }

    private func persist() {
        switch sortField {
        case .name: defaults.set("name", forKey: "sortColumn")
        case .column(let c): defaults.set(c.rawValue, forKey: "sortColumn")
        }
        defaults.set(sortAscending, forKey: "sortAscending")
        defaults.set(viewMode.rawValue, forKey: "viewMode")
        defaults.set(showHidden, forKey: "showHidden")
        if let data = try? JSONEncoder().encode(columns) { defaults.set(data, forKey: "columns") }
        var w: [String: CGFloat] = [:]
        for (k, v) in widths { w[k.rawValue] = v }
        if let data = try? JSONEncoder().encode(w) { defaults.set(data, forKey: "widths") }
    }

    // MARK: columns

    func width(_ column: Column) -> CGFloat { widths[column] ?? column.defaultWidth }

    func setWidth(_ column: Column, _ value: CGFloat) {
        widths[column] = max(column.minWidth, value)
    }

    func commitWidths() { persist() }

    func isVisible(_ column: Column) -> Bool { columns.contains(column) }

    func toggleColumn(_ column: Column) {
        if let i = columns.firstIndex(of: column) {
            columns.remove(at: i)
            // Never leave the sort pointing at a hidden column.
            if case .column(let c) = sortField, c == column { sortField = .name; sortAscending = true }
        } else {
            columns.append(column)
            columns = Column.allCases.filter { columns.contains($0) }   // keep a stable order
        }
        persist()
        refresh()   // owner and permissions need a re-read
    }

    func resetColumns() {
        columns = [.size, .kind, .modified]
        widths = [:]
        persist()
        refresh()
    }

    private var needsPOSIX: Bool { columns.contains { $0.needsPOSIX } }

    // MARK: derived

    var activeIndex: Int { tabs.firstIndex { $0.id == activeID } ?? 0 }
    var active: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }
    var folder: URL? { active?.folder }

    var rows: [Entry] {
        let base = filter.isEmpty
            ? allRows
            : allRows.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        return sortEntries(base, by: sortField, ascending: sortAscending)
    }

    var selectedEntries: [Entry] { rows.filter { selected.contains($0.url) } }

    // MARK: startup

    func start() {
        if activeID == nil { activeID = tabs.first?.id }
        if favorites.isEmpty { buildSidebar() }
        refresh()
    }

    private func buildSidebar() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let favs: [(String, URL)] = [
            ("Home", home),
            ("Desktop", home.appendingPathComponent("Desktop")),
            ("Documents", home.appendingPathComponent("Documents")),
            ("Downloads", home.appendingPathComponent("Downloads")),
            ("Projects", home.appendingPathComponent("projects")),
            ("Applications", URL(fileURLWithPath: "/Applications")),
        ]
        favorites = favs
            .filter { FileManager.default.fileExists(atPath: $0.1.path) }
            .map { FileNode(url: $0.1, label: $0.0) }

        var locs = [FileNode(url: URL(fileURLWithPath: "/"), label: "Macintosh HD")]
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        locs.append(contentsOf: volumes.filter(FS.isNavigableDirectory).map { FileNode(url: $0) })
        locations = locs
    }

    // MARK: navigation

    func refresh() {
        guard let folder else { return }
        allRows = readEntries(folder, showHidden: showHidden, posix: needsPOSIX)
        selected = []
        addressText = folder.path
    }

    /// `activate` is the tree row the user clicked, when the navigation came from
    /// the sidebar. Otherwise the best-matching tree is unfolded instead.
    func go(_ url: URL, activate: FileNode? = nil) {
        guard tabs.indices.contains(activeIndex) else { return }
        tabs[activeIndex].navigate(to: url)
        filter = ""
        refresh()

        if let activate {
            activeRoot = root(containing: activate)
            activeNode = activate.id
            return
        }

        // Stay inside the tree already in use if it still covers the target,
        // so walking up and down does not make the highlight jump sections.
        let target: FileNode? = {
            if let current = activeRoot, current.contains(url) { return current }
            return bestRoot(for: url)
        }()
        activeRoot = target
        activeNode = target?.reveal(url)?.id
    }

    /// The most specific root containing this path - the deepest prefix match.
    private func bestRoot(for url: URL) -> FileNode? {
        (favorites + locations)
            .filter { $0.contains(url) }
            .max { $0.url.path.count < $1.url.path.count }
    }

    private func root(containing node: FileNode) -> FileNode? {
        func holds(_ n: FileNode) -> Bool {
            n === node || n.children.contains(where: holds)
        }
        return (favorites + locations).first(where: holds)
    }

    func back()    { guard tabs.indices.contains(activeIndex) else { return }
                     tabs[activeIndex].back(); refresh() }
    func forward() { guard tabs.indices.contains(activeIndex) else { return }
                     tabs[activeIndex].forward(); refresh() }

    func up() {
        guard let folder, folder.path != "/" else { return }
        go(folder.deletingLastPathComponent())
    }

    /// Address bar commit: accepts ~, and lands on a file's parent with it selected.
    func commitAddress() {
        let raw = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            NSSound.beep()
            addressText = folder?.path ?? ""
            return
        }
        let url = URL(fileURLWithPath: path)
        if isDir.boolValue && FS.isNavigableDirectory(url) {
            go(url)
        } else {
            go(url.deletingLastPathComponent())
            selected = [url]
        }
    }

    func cancelAddress() { addressText = folder?.path ?? "" }

    // MARK: opening

    func open(_ entry: Entry) {
        if entry.isFolder { go(entry.url) } else { NSWorkspace.shared.open(entry.url) }
    }

    func openSelection() { selectedEntries.forEach(open) }

    func openInNewTab(_ url: URL) { newTab(); go(url) }

    /// Space bar preview, using the system Quick Look panel.
    func quickLook() { previewURL = selectedEntries.first?.url }

    /// The system's own list of apps that can open this file.
    func applications(for url: URL) -> [URL] { NSWorkspace.shared.urlsForApplications(toOpen: url) }

    func open(_ url: URL, with app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func showInFinder() {
        let urls = selectedEntries.map(\.url)
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } else if let folder {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        }
    }

    func openTerminal(at url: URL? = nil) {
        guard let target = url ?? folder else { return }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([target], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyLocation() { copyToPasteboard(selectedEntries.first?.url.path ?? folder?.path ?? "") }

    // MARK: cut, copy, paste

    func copySelection() { stage(selectedEntries.map(\.url), .copy) }
    func cutSelection()  { stage(selectedEntries.map(\.url), .move) }

    func stage(_ urls: [URL], _ mode: ClipboardMode) {
        guard !urls.isEmpty else { return }
        clipboard = Clipboard(urls: urls, mode: mode)
        // Mirror onto the system pasteboard so Finder and other apps can paste.
        // A cut cannot be expressed there, so cross-app it behaves as a copy.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    var canPaste: Bool {
        !clipboard.isEmpty || !(NSPasteboard.general.readObjects(forClasses: [NSURL.self]) ?? []).isEmpty
    }

    func paste(into destination: URL? = nil) {
        guard let dest = destination ?? folder else { return }
        var urls = clipboard.urls
        var mode = clipboard.mode
        if urls.isEmpty {
            // Nothing of ours staged: accept whatever Finder put on the pasteboard.
            urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [])
                .filter(\.isFileURL)
            mode = .copy
        }
        guard !urls.isEmpty else { return }
        transfer(urls, into: dest, mode: mode)
    }

    func duplicateSelection() {
        let urls = selectedEntries.map(\.url)
        guard !urls.isEmpty, let dest = folder else { return }
        transfer(urls, into: dest, mode: .copy)
    }

    /// Never overwrites. A name collision produces "x copy", "x copy 2", ...
    private static func uniqueDestination(for source: URL, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(source.lastPathComponent)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var n = 1
        repeat {
            let suffix = n == 1 ? "copy" : "copy \(n)"
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            candidate = dir.appendingPathComponent(name)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private func transfer(_ urls: [URL], into dest: URL, mode: ClipboardMode) {
        // A folder cannot be moved inside itself, and the check must happen
        // before anything is touched.
        for url in urls where mode == .move {
            if dest.path == url.path || dest.path.hasPrefix(url.path + "/") {
                errorText = "Cannot move \"\(url.lastPathComponent)\" into itself."
                return
            }
        }

        opRunning = true
        opTotal = urls.count
        opDone = 0
        opCurrent = ""
        opCancelled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            var performed: [(from: URL, to: URL, mode: ClipboardMode)] = []
            var failures: [String] = []

            for url in urls {
                if self.opCancelled { break }
                DispatchQueue.main.async { self.opCurrent = url.lastPathComponent }
                let target = Self.uniqueDestination(for: url, in: dest)
                do {
                    if mode == .move { try fm.moveItem(at: url, to: target) }
                    else            { try fm.copyItem(at: url, to: target) }
                    performed.append((from: url, to: target, mode: mode))
                } catch {
                    failures.append(url.lastPathComponent)
                }
                DispatchQueue.main.async { self.opDone += 1 }
            }

            DispatchQueue.main.async {
                self.opRunning = false
                self.lastOperation = performed
                if mode == .move { self.clipboard = Clipboard() }
                self.refresh()
                self.reloadTreeNode(for: dest)
                if !failures.isEmpty {
                    self.errorText = "Could not complete for: \(failures.joined(separator: ", "))"
                }
            }
        }
    }

    func cancelOperation() { opCancelled = true }

    var canUndo: Bool { !lastOperation.isEmpty }

    /// Reverses the last transfer. An undone copy goes to the Trash rather than
    /// being unlinked, so undo itself is recoverable.
    func undoLastOperation() {
        let ops = lastOperation
        lastOperation = []
        guard !ops.isEmpty else { return }
        let fm = FileManager.default
        var failures: [String] = []
        for op in ops.reversed() {
            do {
                if op.mode == .move { try fm.moveItem(at: op.to, to: op.from) }
                else                { try fm.trashItem(at: op.to, resultingItemURL: nil) }
            } catch {
                failures.append(op.to.lastPathComponent)
            }
        }
        refresh()
        if let folder { reloadTreeNode(for: folder) }
        if !failures.isEmpty { errorText = "Could not undo: \(failures.joined(separator: ", "))" }
    }

    // MARK: recoverable file operations

    func newFolder() {
        guard let folder else { return }
        var name = "untitled folder"
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "untitled folder \(n)"; n += 1
        }
        let target = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            refresh()
            reloadTreeNode(for: folder)
            selected = [target]
            renaming = target
            renameText = name
        } catch {
            errorText = "Could not create folder: \(error.localizedDescription)"
        }
    }

    func beginRename() {
        guard let entry = selectedEntries.first else { return }
        renaming = entry.url
        renameText = entry.name
    }

    func commitRename() {
        guard let url = renaming else { return }
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !newName.isEmpty, newName != url.lastPathComponent, !newName.contains("/") else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            errorText = "An item named \"\(newName)\" already exists."
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            refresh()
            if let folder { reloadTreeNode(for: folder) }
            selected = [target]
        } catch {
            errorText = "Could not rename: \(error.localizedDescription)"
        }
    }

    /// Trash, never unlink - every deletion stays recoverable from the Finder.
    func moveToTrash() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        var failed: [String] = []
        for entry in targets {
            do { try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil) }
            catch { failed.append(entry.name) }
        }
        refresh()
        if let folder { reloadTreeNode(for: folder) }
        if !failed.isEmpty { errorText = "Could not move to Trash: \(failed.joined(separator: ", "))" }
    }

    func reloadTreeNode(for url: URL) {
        func walk(_ node: FileNode) {
            if node.url == url { node.reload(); return }
            for child in node.children { walk(child) }
        }
        for node in favorites + locations { walk(node) }
    }

    // MARK: tabs and view

    func newTab() {
        let tab = Tab(folder: folder ?? FileManager.default.homeDirectoryForCurrentUser)
        tabs.append(tab)
        activeID = tab.id
        refresh()
    }

    func closeTab() {
        guard tabs.count > 1 else { NSApp.keyWindow?.performClose(nil); return }
        let id = activeID
        tabs.removeAll { $0.id == id }
        activeID = tabs.last?.id
        refresh()
    }

    func selectTab(_ tab: Tab) {
        activeID = tab.id
        filter = ""
        refresh()
    }

    func toggleSort(_ field: SortField) {
        if sortField == field { sortAscending.toggle() } else { sortField = field; sortAscending = true }
        persist()
    }

    func setViewMode(_ mode: ViewMode) { viewMode = mode; persist() }
    func toggleHidden() { showHidden.toggle(); persist(); refresh() }
    func selectAll() { selected = Set(rows.map(\.url)) }
}

// MARK: - Sidebar

struct TreeRow: View {
    @ObservedObject var node: FileNode
    @EnvironmentObject var state: AppState

    private var isCurrent: Bool { state.activeNode == node.id }

    var body: some View {
        DisclosureGroup(isExpanded: $node.isExpanded) {
            ForEach(node.children) { child in TreeRow(node: child) }
        } label: {
            HStack(spacing: 6) {
                Image(nsImage: FS.icon(node.url)).resizable().frame(width: 16, height: 16)
                Text(node.name).lineLimit(1).font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2).padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isCurrent ? Color.accentColor.opacity(0.20) : Color.clear)
            )
            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
            .contentShape(Rectangle())
            .onTapGesture { state.go(node.url, activate: node) }
            .contextMenu {
                Button("Open in New Tab") { state.openInNewTab(node.url) }
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: node.url.path)
                }
                Button("Open in Terminal") { state.openTerminal(at: node.url) }
                Divider()
                Button("Cut") { state.stage([node.url], .move) }
                Button("Copy") { state.stage([node.url], .copy) }
                Button("Paste Into Folder") { state.paste(into: node.url) }
                    .disabled(!state.canPaste)
                Divider()
                Button("Copy Path") { state.copyToPasteboard(node.url.path) }
            }
        }
        .listRowSeparator(.hidden)     // no rules between tree rows
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
    }
}

struct Sidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List {
            Section("Favorites") { ForEach(state.favorites) { TreeRow(node: $0) } }
            Section("Locations") { ForEach(state.locations) { TreeRow(node: $0) } }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 22)
    }
}

// MARK: - Column chooser

struct ColumnMenu: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ForEach(Column.allCases, id: \.self) { column in
            Button {
                state.toggleColumn(column)
            } label: {
                // A leading check mark reads correctly in an AppKit context menu.
                Text(state.isVisible(column) ? "\u{2713}  \(column.label)" : "     \(column.label)")
            }
        }
        Divider()
        Button("Reset Columns") { state.resetColumns() }
    }
}

// MARK: - Header

/// A draggable divider that resizes the column to its left.
struct ResizeHandle: View {
    let width: CGFloat
    let minWidth: CGFloat
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    @State private var startWidth: CGFloat?

    var body: some View {
        ZStack {
            Color.clear.frame(width: 9, height: 18)
            Rectangle().fill(Color.secondary.opacity(0.30)).frame(width: 1, height: 12)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if startWidth == nil { startWidth = width }
                    onChange(max(minWidth, (startWidth ?? width) + g.translation.width))
                }
                .onEnded { _ in startWidth = nil; onEnd() }
        )
    }
}

struct HeaderCell: View {
    let field: SortField
    let width: CGFloat?
    let trailing: Bool
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 3) {
            if trailing { Spacer(minLength: 0) }
            Text(field.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
            if state.sortField == field {
                Image(systemName: state.sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            if !trailing { Spacer(minLength: 0) }
        }
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: trailing ? .trailing : .leading)
        .frame(width: width, alignment: trailing ? .trailing : .leading)
        .foregroundStyle(state.sortField == field ? Color.primary : Color.secondary)
        .contentShape(Rectangle())
        .onTapGesture { state.toggleSort(field) }
    }
}

struct ColumnHeaders: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 33)     // icon gutter
            HeaderCell(field: .name, width: nil, trailing: false)
            ForEach(state.columns, id: \.self) { column in
                ResizeHandle(width: state.width(column), minWidth: column.minWidth,
                             onChange: { state.setWidth(column, $0) },
                             onEnd: { state.commitWidths() })
                HeaderCell(field: .column(column), width: state.width(column), trailing: column.trailing)
            }
            Spacer().frame(width: 12)
        }
        .frame(height: 22)
        .background(Color.secondary.opacity(0.06))
        .contextMenu { ColumnMenu() }     // right-click the header to choose columns
    }
}

// MARK: - Rows

struct RenameField: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $state.renameText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12.5))
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { state.commitRename() }
            .onExitCommand { state.renaming = nil }
    }
}

struct ListRow: View {
    let entry: Entry
    @EnvironmentObject var state: AppState

    private var isSelected: Bool { state.selected.contains(entry.url) }

    var body: some View {
        HStack(spacing: 0) {
            Image(nsImage: FS.icon(entry.url))
                .resizable().frame(width: 17, height: 17)
                .padding(.leading, 8).padding(.trailing, 8)

            Group {
                if state.renaming == entry.url {
                    RenameField()
                } else {
                    Text(entry.name).lineLimit(1).font(.system(size: 12.5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(state.columns, id: \.self) { column in
                Spacer().frame(width: 9)      // matches the header's resize handle
                Text(entry.text(for: column)).lineLimit(1)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: state.width(column), alignment: column.trailing ? .trailing : .leading)
            }
            Spacer().frame(width: 12)
        }
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .opacity(state.clipboard.mode == .move && state.clipboard.urls.contains(entry.url) ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.open(entry) }
        .onTapGesture { toggleSelect() }
        .contextMenu { EntryMenu(entry: entry) }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    private func toggleSelect() {
        if NSEvent.modifierFlags.contains(.command) {
            if isSelected { state.selected.remove(entry.url) } else { state.selected.insert(entry.url) }
        } else {
            state.selected = [entry.url]
        }
    }
}

struct IconCell: View {
    let entry: Entry
    @EnvironmentObject var state: AppState

    private var isSelected: Bool { state.selected.contains(entry.url) }

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: FS.icon(entry.url)).resizable().frame(width: 46, height: 46)
            if state.renaming == entry.url {
                RenameField().frame(width: 96)
            } else {
                Text(entry.name).font(.system(size: 11)).multilineTextAlignment(.center)
                    .lineLimit(2).frame(width: 96)
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.open(entry) }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                if isSelected { state.selected.remove(entry.url) } else { state.selected.insert(entry.url) }
            } else {
                state.selected = [entry.url]
            }
        }
        .contextMenu { EntryMenu(entry: entry) }
    }
}

// MARK: - Shared row context menu

struct EntryMenu: View {
    let entry: Entry
    @EnvironmentObject var state: AppState

    /// Right-clicking a row outside the current selection acts on that row.
    private func ensureSelected() {
        if !state.selected.contains(entry.url) { state.selected = [entry.url] }
    }

    var body: some View {
        Button("Open") { state.open(entry) }
        if entry.isFolder { Button("Open in New Tab") { state.openInNewTab(entry.url) } }

        let apps = state.applications(for: entry.url)
        if !apps.isEmpty {
            Menu("Open With") {          // the system's own association list
                ForEach(apps, id: \.self) { app in
                    Button(FS.displayName(app)) { state.open(entry.url, with: app) }
                }
            }
        }
        Divider()
        Button("Quick Look") { state.selected = [entry.url]; state.quickLook() }
        Button("Get Info") { state.infoTarget = entry }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        if entry.isFolder { Button("Open in Terminal") { state.openTerminal(at: entry.url) } }
        Divider()
        Button("Cut") { ensureSelected(); state.cutSelection() }
        Button("Copy") { ensureSelected(); state.copySelection() }
        if entry.isFolder {
            Button("Paste Into Folder") { state.paste(into: entry.url) }.disabled(!state.canPaste)
        } else {
            Button("Paste") { state.paste() }.disabled(!state.canPaste)
        }
        Button("Duplicate") { ensureSelected(); state.duplicateSelection() }
        Divider()
        ShareLink(item: entry.url) { Text("Share") }
        Button("Rename") { state.selected = [entry.url]; state.beginRename() }
        Divider()
        Button("Copy Path") { state.copyToPasteboard(entry.url.path) }
        Button("Copy Name") { state.copyToPasteboard(entry.name) }
        Divider()
        Button("Move to Trash") { state.selected = [entry.url]; state.moveToTrash() }
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            toolbar
            Divider()
            HSplitView {
                Sidebar().frame(minWidth: 150, idealWidth: 195, maxWidth: 340)
                VStack(spacing: 0) {
                    if state.viewMode == .list {
                        ColumnHeaders()
                        Divider()
                        listBody
                    } else {
                        iconBody
                    }
                    Divider()
                    statusBar
                }
                .frame(minWidth: 440)
            }
        }
        .frame(minWidth: 940, minHeight: 540)
        .onAppear { state.start() }
        .quickLookPreview($state.previewURL)          // the system preview panel
        .sheet(item: $state.infoTarget) { InfoSheet(entry: $0) }
        .sheet(isPresented: Binding(
            get: { state.opRunning }, set: { if !$0 { state.cancelOperation() } }
        )) { TransferSheet() }
        .alert("Arbor", isPresented: Binding(
            get: { state.errorText != nil },
            set: { if !$0 { state.errorText = nil } }
        )) {
            Button("OK") { state.errorText = nil }
        } message: {
            Text(state.errorText ?? "")
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(state.tabs) { tab in
                    HStack(spacing: 6) {
                        Image(nsImage: FS.icon(tab.folder)).resizable().frame(width: 13, height: 13)
                        Text(tab.title).lineLimit(1).font(.system(size: 12))
                        if state.tabs.count > 1 {
                            Button {
                                state.activeID = tab.id; state.closeTab()
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tab.id == state.activeID
                                  ? Color.accentColor.opacity(0.20)
                                  : Color.secondary.opacity(0.10))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { state.selectTab(tab) }
                }
                Button { state.newTab() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("New tab (Cmd+T)")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { state.back() } label: { Image(systemName: "chevron.left") }
                .disabled(!(state.active?.canGoBack ?? false)).help("Back (Cmd+[)")
            Button { state.forward() } label: { Image(systemName: "chevron.right") }
                .disabled(!(state.active?.canGoForward ?? false)).help("Forward (Cmd+])")
            Button { state.up() } label: { Image(systemName: "arrow.up") }
                .disabled(state.folder?.path == "/").help("Enclosing folder (Cmd+Up)")

            // Editable address bar: type a path, Return to go, Escape to revert.
            TextField("Path", text: $state.addressText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($addressFocused)
                .onSubmit { state.commitAddress(); addressFocused = false }
                .onExitCommand { state.cancelAddress(); addressFocused = false }
                .onChange(of: state.focusAddress) { _, want in
                    if want { addressFocused = true; state.focusAddress = false }
                }

            Picker("", selection: Binding(
                get: { state.viewMode }, set: { state.setViewMode($0) }
            )) {
                ForEach(ViewMode.allCases, id: \.self) { Image(systemName: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 76).labelsHidden()

            Menu {
                ColumnMenu()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton).frame(width: 30).help("Choose columns")

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Filter", text: $state.filter)
                    .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 120)
                if !state.filter.isEmpty {
                    Button { state.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    @ViewBuilder
    private var listBody: some View {
        if state.rows.isEmpty {
            emptyState
        } else {
            List {
                ForEach(state.rows) { ListRow(entry: $0) }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 24)
        }
    }

    @ViewBuilder
    private var iconBody: some View {
        if state.rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                    ForEach(state.rows) { IconCell(entry: $0) }
                }
                .padding(12)
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text(state.filter.isEmpty ? "This folder is empty" : "No items match \"\(state.filter)\"")
                .foregroundStyle(.secondary).font(.system(size: 13))
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text("\(state.rows.count) item\(state.rows.count == 1 ? "" : "s")")
            if !state.selected.isEmpty {
                Text("\(state.selected.count) selected")
                let bytes = state.selectedEntries.filter { !$0.isFolder && !$0.isBundle }.reduce(Int64(0)) { $0 + $1.size }
                if bytes > 0 { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
            }
            Spacer()
            if let free = freeSpace() { Text("\(free) available") }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func freeSpace() -> String? {
        guard let folder = state.folder,
              let v = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Transfer progress

struct TransferSheet: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copying items").font(.headline)
            ProgressView(value: Double(state.opDone), total: Double(max(state.opTotal, 1)))
            Text(state.opCurrent.isEmpty ? " " : state.opCurrent)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Text("\(state.opDone) of \(state.opTotal)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                // Cancel stops before the next item; it cannot interrupt a file
                // already being written.
                Button("Cancel") { state.cancelOperation() }
            }
        }
        .padding(20).frame(width: 360)
    }
}

// MARK: - Get Info

struct InfoSheet: View {
    let entry: Entry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                Image(nsImage: FS.icon(entry.url)).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.headline)
                    Text(entry.kind).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                row("Where", entry.url.deletingLastPathComponent().path)
                row("Size", (entry.isFolder || entry.isBundle) ? "--"
                    : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                row("Modified", entry.modified.formatted(date: .long, time: .standard))
                if entry.created != .distantPast {
                    row("Created", entry.created.formatted(date: .long, time: .standard))
                }
                if !entry.ext.isEmpty { row("Extension", entry.ext) }
            }
            HStack {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.url.path, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 470)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11)).textSelection(.enabled)
                .frame(maxWidth: 330, alignment: .leading).lineLimit(3)
        }
    }
}

// MARK: - Menu bar

struct AppCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { state.newTab() }.keyboardShortcut("t")
            Button("New Folder") { state.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Close Tab") { state.closeTab() }.keyboardShortcut("w")
            Divider()
            Button("Open") { state.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command).disabled(state.selected.isEmpty)
            Button("Quick Look") { state.quickLook() }
                .keyboardShortcut(.space, modifiers: []).disabled(state.selected.isEmpty)
            Button("Get Info") { state.infoTarget = state.selectedEntries.first }
                .keyboardShortcut("i").disabled(state.selected.isEmpty)
            Button("Open in Terminal") { state.openTerminal() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) {
            Button("Cut") { state.cutSelection() }
                .keyboardShortcut("x").disabled(state.selected.isEmpty)
            Button("Copy") { state.copySelection() }
                .keyboardShortcut("c").disabled(state.selected.isEmpty)
            Button("Paste") { state.paste() }
                .keyboardShortcut("v").disabled(!state.canPaste)
            Button("Duplicate") { state.duplicateSelection() }
                .keyboardShortcut("d").disabled(state.selected.isEmpty)
            Divider()
            Button("Undo Last File Operation") { state.undoLastOperation() }
                .keyboardShortcut("z").disabled(!state.canUndo)
            Divider()
            Button("Select All") { state.selectAll() }.keyboardShortcut("a")
            Button("Rename") { state.beginRename() }.disabled(state.selected.count != 1)
            Button("Move to Trash") { state.moveToTrash() }
                .keyboardShortcut(.delete, modifiers: .command).disabled(state.selected.isEmpty)
        }

        CommandMenu("Go") {
            Button("Back") { state.back() }
                .keyboardShortcut("[").disabled(!(state.active?.canGoBack ?? false))
            Button("Forward") { state.forward() }
                .keyboardShortcut("]").disabled(!(state.active?.canGoForward ?? false))
            Button("Enclosing Folder") { state.up() }
                .keyboardShortcut(.upArrow, modifiers: .command).disabled(state.folder?.path == "/")
            Divider()
            Button("Open Location...") { state.focusAddress = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Show Location in Finder") { state.showInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .control])
            Button("Copy Location") { state.copyLocation() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Divider()
            Button("Home") { state.go(FileManager.default.homeDirectoryForCurrentUser) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Computer") { state.go(URL(fileURLWithPath: "/")) }
            Button("Applications") { state.go(URL(fileURLWithPath: "/Applications")) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Utilities") { state.go(URL(fileURLWithPath: "/System/Applications/Utilities")) }
        }

        CommandMenu("View") {
            Picker("View As", selection: Binding(
                get: { state.viewMode }, set: { state.setViewMode($0) }
            )) {
                ForEach(ViewMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Divider()
            Menu("Columns") { ColumnMenu().environmentObject(state) }
            Divider()
            Button("Sort by Name") { state.toggleSort(.name) }
                .keyboardShortcut("1", modifiers: .command)
            ForEach(Array(state.columns.enumerated()), id: \.element) { index, column in
                Button("Sort by \(column.label)") { state.toggleSort(.column(column)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(min(index + 2, 9))")), modifiers: .command)
            }
            Divider()
            Toggle("Show Hidden Files", isOn: Binding(
                get: { state.showHidden }, set: { _ in state.toggleHidden() }
            )).keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Refresh") { state.refresh() }.keyboardShortcut("r")
        }
    }
}

@main
struct ArborApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Arbor") {
            ContentView().environmentObject(state)
        }
        .commands { AppCommands(state: state) }
    }
}
