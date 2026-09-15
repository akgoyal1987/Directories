// Directories - a Windows-Explorer-style file navigator for macOS.
//
// Left: an expandable folder tree. Right: folder contents as a list or icon grid.
// Tabs with per-tab history, an Explorer-style breadcrumb address bar that turns
// into an editable path field when you click into it, live filtering, and a
// configurable set of resizable, sortable columns.
//
// Where macOS already provides something, it is used rather than reimplemented:
// Quick Look for previews, NSWorkspace for icons and "Open With", ShareLink for
// the share sheet, and the system sidebar styling.
//
// Every file operation is recoverable. Nothing is ever overwritten -- a name
// collision becomes "x copy" -- copies and moves run off the main thread behind
// a progress sheet with a working cancel, and one level of undo puts things back
// by sending the new copies to the Trash rather than unlinking them.

import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers
import CoreServices

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

    /// NSWorkspace.icon is a Launch Services lookup. It was being called from
    /// every row body on every render, so a single re-render cost dozens of
    /// them. Bounded cache, since icons for a given path do not change often.
    private static let iconCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 2000
        return c
    }()

    static func icon(_ url: URL) -> NSImage {
        let key = url.path as NSString
        if let hit = iconCache.object(forKey: key) { return hit }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 32, height: 32)
        iconCache.setObject(image, forKey: key)
        return image
    }

    static func flushIconCache() { iconCache.removeAllObjects() }

    /// The navigable subfolders of a folder, ordered the way the tree orders
    /// them. Used by the tree and by the address bar's chevron menus.
    static func subfolders(_ url: URL, showHidden: Bool = false) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .localizedNameKey]
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: opts)) ?? []
        return items
            .filter(isNavigableDirectory)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The terminal the user actually uses, not whichever one Apple ships.
    /// First installed candidate wins; `defaults write com.ankitgoyal.directories
    /// terminalBundleID <id>` overrides the list entirely.
    static var terminal: URL {
        let ws = NSWorkspace.shared
        if let chosen = UserDefaults.standard.string(forKey: "terminalBundleID"),
           let url = ws.urlForApplication(withBundleIdentifier: chosen) {
            return url
        }
        let candidates = ["com.googlecode.iterm2", "com.mitchellh.ghostty",
                          "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
                          "com.github.wez.wezterm", "org.alacritty",
                          "co.zeit.hyper", "com.apple.Terminal"]
        for id in candidates {
            if let url = ws.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    }

    /// The folders macOS manages, asked for rather than named.
    ///
    /// Every domain, so this is right whether the app runs as the user or as
    /// root -- as root the permission checks below stop catching /Applications
    /// and /Library, and only this list still does.
    private static let managedDirectories: Set<String> = {
        let kinds: [FileManager.SearchPathDirectory] = [
            .desktopDirectory, .documentDirectory, .downloadsDirectory,
            .libraryDirectory, .moviesDirectory, .musicDirectory,
            .picturesDirectory, .sharedPublicDirectory, .applicationDirectory,
            .adminApplicationDirectory, .developerDirectory, .coreServiceDirectory,
            .userDirectory, .trashDirectory,
        ]
        let domains: [FileManager.SearchPathDomainMask] =
            [.userDomainMask, .localDomainMask, .systemDomainMask]
        var paths: Set<String> = []
        for kind in kinds {
            for domain in domains {
                for url in FileManager.default.urls(for: kind, in: domain) {
                    paths.insert(url.standardizedFileURL.path)
                }
            }
        }
        paths.insert(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        return paths
    }()

    /// Why an item may not be renamed, moved or trashed. nil means it may be.
    /// The text is written to follow "cannot be renamed because ...".
    ///
    /// Finder has no filesystem marker to go on, which is worth knowing before
    /// looking for one: Desktop, Documents, Downloads and Library carry no
    /// immutable flag, no Finder name-locked bit and no read-only permission,
    /// and were measured to be indistinguishable from an ordinary folder by
    /// every URL resource key there is. What identifies them is the
    /// standard-directory list itself, so that is what this asks macOS for.
    /// Deriving the set instead of naming the folders also keeps it correct in
    /// every language, where the names on screen are not the names on disk.
    static func protection(for url: URL) -> String? {
        let standard = url.standardizedFileURL
        let values = try? standard.resourceValues(
            forKeys: [.isVolumeKey, .isUserImmutableKey, .isSystemImmutableKey])

        if values?.isVolume == true { return "it is the root of a volume" }
        if managedDirectories.contains(standard.path) { return "macOS needs this folder" }
        if values?.isSystemImmutable == true { return "the system has locked it" }
        if values?.isUserImmutable == true { return "it is locked" }

        let parent = standard.deletingLastPathComponent()
        if (try? parent.resourceValues(forKeys: [.isWritableKey]))?.isWritable == false {
            return "the enclosing folder is read-only"
        }
        return nil
    }

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

/// Column widths live apart from AppState on purpose. Publishing them there
/// re-rendered the whole window - sidebar, tabs and toolbar - on every frame of
/// a resize drag. Only the header and the list rows observe this.
final class ColumnLayout: ObservableObject {
    @Published private var widths: [Column: CGFloat] = [:]
    private let defaults = UserDefaults.standard

    init() {
        if let data = defaults.data(forKey: "widths"),
           let saved = try? JSONDecoder().decode([String: CGFloat].self, from: data) {
            for (k, v) in saved { if let c = Column(rawValue: k) { widths[c] = v } }
        }
    }

    func width(_ column: Column) -> CGFloat { widths[column] ?? column.defaultWidth }

    func setWidth(_ column: Column, _ value: CGFloat) {
        let clamped = max(column.minWidth, value).rounded()
        guard widths[column] != clamped else { return }
        widths[column] = clamped
    }

    func commit() {
        var raw: [String: CGFloat] = [:]
        for (k, v) in widths { raw[k.rawValue] = v }
        if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: "widths") }
    }

    func reset() { widths = [:]; commit() }
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
            guard isExpanded != oldValue else { return }
            // The set of folders being watched for changes follows what is on
            // screen, and expanding a node puts another folder on screen.
            NotificationCenter.default.post(name: .treeExpansionChanged, object: nil)
            guard isExpanded, !loaded else { return }
            // Reassigning children synchronously here mutates state SwiftUI is
            // in the middle of reading, which duplicates rows. Defer one tick.
            loaded = true
            DispatchQueue.main.async { [weak self] in self?.populate() }
        }
    }
    /// Whether the children have ever been read. A collapsed node that has
    /// never been opened has nothing to reload.
    private(set) var loaded = false

    init(url: URL, label: String? = nil) {
        self.url = url
        self.name = label ?? FS.displayName(url)
    }

    func load() {
        loaded = true
        populate()
    }

    /// Existing child objects are reused for folders that are still there, so
    /// a reload triggered by a change on disk leaves the subtree underneath
    /// expanded and does not make SwiftUI rebuild rows that did not change.
    private func populate() {
        let existing = Dictionary(children.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        children = FS.subfolders(url).map { existing[$0] ?? FileNode(url: $0) }
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

extension Notification.Name {
    static let treeExpansionChanged = Notification.Name("DirectoriesTreeExpansionChanged")
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

    /// Read one item from disk. `readEntries` builds these in bulk for a
    /// listing; the tree has no listing behind it, so Get Info on a tree node
    /// needs to stat the one path it has.
    static func read(_ url: URL, posix: Bool = true) -> Entry {
        readEntries(url.deletingLastPathComponent(), showHidden: true, posix: posix)
            .first { $0.url.standardizedFileURL == url.standardizedFileURL }
            ?? Entry(url: url, name: FS.displayName(url),
                     isFolder: FS.isNavigableDirectory(url), isBundle: false,
                     size: 0, modified: .distantPast, created: .distantPast,
                     added: .distantPast, kind: "", ext: url.pathExtension,
                     owner: "", permissions: "")
    }

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

// MARK: - Range selection

/// The rows a Shift-click covers: everything between the anchor and the clicked
/// row, in the order given. `order` is the order on screen rather than the order
/// on disk, so a range follows the current sort and the current filter -- what
/// was clicked between is what gets selected.
///
/// nil when either end is no longer on screen, which is the caller's cue to
/// treat the click as a plain one rather than to select nothing.
func rangeSelection(from anchor: URL, to target: URL, in order: [URL]) -> Set<URL>? {
    guard let a = order.firstIndex(of: anchor),
          let b = order.firstIndex(of: target) else { return nil }
    return Set(order[min(a, b)...max(a, b)])
}

// MARK: - Click modifiers

/// The modifier keys as they were when the mouse went down.
///
/// `NSEvent.modifierFlags` reports the keyboard *now*, and SwiftUI holds a
/// single tap back while it waits to see whether a second click follows -- a
/// quarter of a second, which is long enough to have let go of Shift. Reading
/// the flags then makes range and toggle clicks miss at random. The mouse-down
/// event carries the flags that were actually held when the click was made, so
/// a local monitor records them before the gesture ever runs.
enum ClickModifiers {
    private(set) static var current: NSEvent.ModifierFlags = []
    private static var monitor: Any?

    static func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            current = event.modifierFlags
            return event
        }
    }
}

// MARK: - New item templates

/// The contents of the Explorer-style "New >" submenu. Each entry is created
/// with the least content that makes the file valid, then handed straight to
/// inline rename so the name can be typed without a second click.
struct FileTemplate: Identifiable, Hashable {
    let label: String
    let name: String
    let body: String
    var executable = false
    var id: String { name }

    static let all: [FileTemplate] = [
        FileTemplate(label: "Text Document",     name: "untitled.txt",  body: ""),
        FileTemplate(label: "Markdown Document", name: "untitled.md",   body: ""),
        FileTemplate(label: "Shell Script",      name: "untitled.sh",   body: "#!/bin/bash\n",
                     executable: true),
        FileTemplate(label: "JSON File",         name: "untitled.json", body: "{\n}\n"),
        FileTemplate(label: "CSV File",          name: "untitled.csv",  body: ""),
    ]
}

// MARK: - Watching the filesystem

/// One FSEvents stream covering every folder currently on screen: the active
/// tab's folder, plus each expanded node of the tree.
///
/// Without this, a listing is only ever re-read when Directories itself changed
/// something, so a download landing or a `git checkout` stayed invisible until
/// you navigated away and back.
///
/// Three things make it cheap. FSEvents is recursive and cannot be told
/// otherwise, so watching a folder near the root reports the whole subtree --
/// events are filtered down to the exact watched paths on a background queue,
/// and only reach the main queue when a folder actually on screen changed. They
/// are then coalesced, so a folder receiving five hundred files causes one
/// reload rather than five hundred. And there is a single stream rather than a
/// descriptor per folder, so an expanded tree costs one kernel resource.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private var watched: Set<String> = []          // main queue only

    private let queue = DispatchQueue(label: "com.ankitgoyal.directories.fsevents")
    private var accepted: Set<String> = []         // `queue` only: the filter
    private var pending: Set<String> = []          // `queue` only
    private var scheduled = false                  // `queue` only

    /// Delivered on the main queue, naming the watched folders that changed.
    var onChange: (Set<String>) -> Void = { _ in }

    static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    func watch(_ paths: [String]) {
        let set = Set(paths.map(Self.normalize))
        guard set != watched else { return }
        stop()
        watched = set
        guard !set.isEmpty else { return }

        queue.async { self.accepted = set }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        // UseCFTypes makes the callback's paths a CFArray of CFStrings. Without
        // it they arrive as a C array of char*, which cannot be read as an
        // NSArray however often that trick is repeated.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagNoDefer
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, fsEventsCallback, &context,
            Array(set) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4, flags) else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    /// Stopped, invalidated and released, every time. A stream is a kernel
    /// resource, and the watch set is rebuilt on every navigation -- leaking one
    /// per folder visited would be a descriptor leak in a process that runs for
    /// days.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watched = []
        queue.async { self.accepted = [] }
    }

    deinit { stop() }

    /// Runs on `queue`.
    fileprivate func received(_ paths: [String]) {
        let hits = Set(paths.map(Self.normalize)).intersection(accepted)
        guard !hits.isEmpty else { return }
        pending.formUnion(hits)
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let batch = self.pending
            self.pending = []
            self.scheduled = false
            guard !batch.isEmpty else { return }
            DispatchQueue.main.async { self.onChange(batch) }
        }
    }
}

private let fsEventsCallback: FSEventStreamCallback = { _, info, _, paths, _, _ in
    guard let info else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    watcher.received(unsafeBitCast(paths, to: NSArray.self) as? [String] ?? [])
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

    private var allRows: [Entry] = []
    /// Filtered and sorted once per change, not once per read. SwiftUI reads
    /// this many times per render pass, so recomputing here made every drag
    /// re-sort the whole folder.
    @Published private(set) var rows: [Entry] = []
    @Published var selected: Set<URL> = []
    /// Where a Shift range measures from: the last row clicked without Shift.
    /// Explorer and the Finder both extend from that fixed point rather than
    /// from the nearest edge of the current selection, so shift-clicking twice
    /// re-measures instead of growing a row at a time.
    private var selectionAnchor: URL?
    @Published var filter = "" { didSet { recomputeRows() } }
    @Published var sortField: SortField = .name { didSet { recomputeRows() } }
    @Published var sortAscending = true { didSet { recomputeRows() } }
    @Published var viewMode: ViewMode = .list
    @Published var showHidden = false

    /// Visible columns, in display order. Name is implicit and always first.
    @Published var columns: [Column] = [.size, .kind, .modified]

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

    /// True when the folder listed as empty because macOS refused the read, not
    /// because it holds nothing. The Recycle Bin is the case that matters:
    /// `~/.Trash` needs Full Disk Access and, unlike Desktop or Documents, macOS
    /// never prompts for it -- the read just returns nothing. Without this an
    /// empty bin and an unreadable one look identical, and the honest answer is
    /// the difference between a broken feature and a permission to grant.
    @Published var accessDenied = false

    @Published var addressText = ""
    @Published var focusAddress = false
    @Published var renaming: URL?
    @Published var renameText = ""
    @Published var infoTarget: Entry?
    @Published var previewURL: URL?
    @Published var errorText: String?

    /// Live refresh. The watcher follows what is on screen; a reload asked for
    /// while a rename field is open or a transfer is running is deferred rather
    /// than dropped, so it never yanks the field away mid-word.
    private let watcher = FolderWatcher()
    private var expansionToken: NSObjectProtocol?
    private var pendingReload = false

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

        watcher.onChange = { [weak self] changed in self?.foldersChanged(changed) }
        expansionToken = NotificationCenter.default.addObserver(
            forName: .treeExpansionChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.updateWatch() }
    }

    deinit {
        watcher.stop()
        if let expansionToken { NotificationCenter.default.removeObserver(expansionToken) }
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
    }

    // MARK: columns

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
        persist()
        refresh()
    }

    private var needsPOSIX: Bool { columns.contains { $0.needsPOSIX } }

    // MARK: derived

    var activeIndex: Int { tabs.firstIndex { $0.id == activeID } ?? 0 }
    var active: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }
    var folder: URL? { active?.folder }

    private func recomputeRows() {
        let base = filter.isEmpty
            ? allRows
            : allRows.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        rows = sortEntries(base, by: sortField, ascending: sortAscending)
    }

    var selectedEntries: [Entry] { rows.filter { selected.contains($0.url) } }

    /// Why the current selection may not be renamed, moved or trashed, taking
    /// the first reason found. nil when all of it may be.
    var selectionProtection: String? {
        selectedEntries.lazy.compactMap { FS.protection(for: $0.url) }.first
    }

    /// The reason the whole action is refused, naming the item when only some
    /// of the selection is protected.
    private func refuse(_ verb: String, _ entries: [Entry]) -> Bool {
        guard let offender = entries.first(where: { FS.protection(for: $0.url) != nil }),
              let reason = FS.protection(for: offender.url) else { return false }
        errorText = "\"\(offender.name)\" cannot be \(verb) because \(reason)."
        return true
    }

    /// "Copy" for one, "Copy 3 Items" for several, so a menu label says how
    /// much it is about to touch.
    func selectionNoun(_ verb: String) -> String {
        selected.count > 1 ? "\(verb) \(selected.count) Items" : verb
    }

    /// A click on the *name* of a row, which is the only part that starts a
    /// rename. Explorer and the Finder both work this way: the first click
    /// selects, a later click on the name of the item already selected on its
    /// own opens the field, and the icon or the row around the name only ever
    /// selects. A click carrying a modifier is a selection gesture and never a
    /// rename, and a double-click opens instead -- SwiftUI holds the single tap
    /// back until it knows which it was.
    func nameClicked(_ url: URL, shift: Bool, command: Bool) {
        if !shift, !command, renaming == nil, selected == [url],
           FS.protection(for: url) == nil {
            beginRename()
            return
        }
        click(url, shift: shift, command: command)
    }

    /// Every click on a row, from either view. The range runs over `rows`, so it
    /// follows what is on screen: the current sort, and the current filter.
    func click(_ url: URL, shift: Bool, command: Bool) {
        if shift, let anchor = selectionAnchor,
           let range = rangeSelection(from: anchor, to: url, in: rows.map(\.url)) {
            // Command with Shift adds the range instead of replacing the
            // selection, which is how a second run is picked up.
            selected = command ? selected.union(range) : range
            return
        }
        if command {
            if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
        } else {
            selected = [url]
        }
        selectionAnchor = url
    }

    // MARK: startup

    func start() {
        ClickModifiers.startMonitoring()
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

        // The Recycle Bin, last in Locations as it is in Explorer. It is the
        // real ~/.Trash, so what shows here is what the Finder shows.
        //
        // Browsing only: there is deliberately no Empty Trash. Every delete in
        // this app moves to the Trash precisely so it can be undone, and an
        // Empty command would be the one place that destroys something for
        // good. The Finder already has it for anyone who wants it.
        let trash = home.appendingPathComponent(".Trash")
        if FileManager.default.fileExists(atPath: trash.path) {
            locs.append(FileNode(url: trash, label: "Recycle Bin"))
        }
        locations = locs
    }

    // MARK: navigation

    /// A full re-read that resets the pane: used by navigation, where clearing
    /// the selection is the right thing. `reloadListing` is the one to call when
    /// the person has not moved.
    func refresh() {
        guard let folder else { return }
        allRows = readEntries(folder, showHidden: showHidden, posix: needsPOSIX)
        recomputeRows()
        // Only for an empty listing, so the common path pays nothing.
        accessDenied = allRows.isEmpty
            && (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == nil
        selected = []
        selectionAnchor = nil
        addressText = folder.path
        pendingReload = false
        updateWatch()
    }

    // MARK: live refresh

    /// The folders on screen: the active tab's folder, and every expanded node
    /// of the tree. Capped, because each watched path widens the subtree
    /// FSEvents has to report on.
    private func updateWatch() {
        var paths: [String] = []
        if let folder { paths.append(folder.path) }
        func walk(_ node: FileNode) {
            guard node.isExpanded else { return }
            paths.append(node.url.path)
            node.children.forEach(walk)
        }
        (favorites + locations).forEach(walk)
        watcher.watch(Array(paths.prefix(64)))
    }

    private func foldersChanged(_ changed: Set<String>) {
        for path in changed {
            reloadTreeNode(for: URL(fileURLWithPath: path))
        }
        if let folder, changed.contains(FolderWatcher.normalize(folder.path)) {
            reloadListing()
        }
    }

    /// Re-reads the listing without moving anybody: the selection survives for
    /// everything still on disk, the scroll position is untouched, and no
    /// navigation happens. This is what a change on disk triggers.
    func reloadListing() {
        guard let folder else { return }
        // Rebuilding the rows under an open rename field takes the field away
        // mid-word, and re-reading during a transfer fights the transfer's own
        // refresh. Both replay once they finish.
        guard renaming == nil, !opRunning else { pendingReload = true; return }
        let keep = selected
        allRows = readEntries(folder, showHidden: showHidden, posix: needsPOSIX)
        recomputeRows()
        // Only for an empty listing, so the common path pays nothing.
        accessDenied = allRows.isEmpty
            && (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == nil
        let live = Set(allRows.map(\.url))
        selected = keep.intersection(live)
        if let anchor = selectionAnchor, !live.contains(anchor) { selectionAnchor = nil }
        addressText = folder.path
        updateWatch()
    }

    /// View > Refresh, and Refresh in the folder menu: re-read both panes now.
    func reloadCurrent() {
        guard let folder else { return }
        reloadListing()
        reloadTreeNode(for: folder)
    }

    private func drainPendingReload() {
        guard pendingReload else { return }
        pendingReload = false
        reloadListing()
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

    /// Explorer's Open over a multiple selection gives every folder somewhere
    /// of its own to be -- a window each, and the window you started in stays
    /// where it was. Here that is a tab each.
    ///
    /// The old version opened each item in turn, and opening a folder navigates
    /// the current tab, so selecting two folders navigated the one tab twice
    /// and landed on the second. It looked as though only one had opened.
    func openSelection() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        let folders = targets.filter(\.isFolder)

        for entry in targets where !entry.isFolder {
            NSWorkspace.shared.open(entry.url)
        }
        if folders.count == 1 {
            go(folders[0].url)          // as a double-click would
        } else {
            for entry in folders { openInNewTab(entry.url) }
        }
    }

    /// Explorer stops offering Open once the selection passes fifteen, rather
    /// than launching that many windows at once. Same limit here.
    static let multipleOpenLimit = 15

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
        let terminal = FS.terminal
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
        if mode == .move,
           let offender = urls.first(where: { FS.protection(for: $0) != nil }),
           let reason = FS.protection(for: offender) {
            errorText = "\"\(offender.lastPathComponent)\" cannot be moved because \(reason)."
            return
        }
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

    func transfer(_ urls: [URL], into dest: URL, mode: ClipboardMode) {
        // A folder cannot be moved inside itself, and the check must happen
        // before anything is touched.
        for url in urls where mode == .move {
            if dest.path == url.path || dest.path.hasPrefix(url.path + "/") {
                errorText = "Cannot move \"\(url.lastPathComponent)\" into itself."
                return
            }
            // A drag never passes a menu, so the refusal has to live here too.
            if let reason = FS.protection(for: url) {
                errorText = "\"\(url.lastPathComponent)\" cannot be moved because \(reason)."
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
                self.pendingReload = false      // the refresh below covers it
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

    // MARK: drag and drop

    /// The payload of an in-app drag. Held here rather than in the item
    /// provider because SwiftUI gives one provider per view, and dragging a row
    /// inside a multi-selection has to carry the whole selection.
    @Published var dragging: [URL] = []

    func beginDrag(_ url: URL) -> [URL] {
        let payload = selected.contains(url) ? selectedEntries.map(\.url) : [url]
        dragging = payload
        return payload
    }

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: URLResourceKey = .volumeIdentifierKey
        guard let va = try? a.resourceValues(forKeys: [key]).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: [key]).volumeIdentifier
        else { return true }        // unknown: assume same, so the default is a move
        return (va as? NSObject)?.isEqual(vb as? NSObject) ?? true
    }

    /// Explorer rules: within a volume a drag moves, across volumes it copies.
    /// Both platforms' override keys are honoured, since neither conflicts.
    func dropMode(source: URL, destination: URL) -> ClipboardMode {
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) || flags.contains(.control) { return .copy }
        if flags.contains(.command) || flags.contains(.shift) { return .move }
        return sameVolume(source, destination) ? .move : .copy
    }

    func performDrop(_ urls: [URL], into destination: URL) {
        dragging = []
        let files = urls.filter(\.isFileURL)
        guard let first = files.first else { return }
        let mode = dropMode(source: first, destination: destination)
        // Dropping something into the folder it already lives in is a no-op for
        // a move, and a deliberate duplicate for a copy.
        let payload = mode == .copy
            ? files
            : files.filter { $0.deletingLastPathComponent().path != destination.path }
        guard !payload.isEmpty else { return }
        transfer(payload, into: destination, mode: mode)
    }

    /// Returns true when the drop is accepted. An in-app drag uses the payload
    /// recorded at drag start; anything else is read out of the item providers.
    func handleDrop(_ providers: [NSItemProvider], into destination: URL) -> Bool {
        if !dragging.isEmpty {
            let payload = dragging
            DispatchQueue.main.async { self.performDrop(payload, into: destination) }
            return true
        }
        guard !providers.isEmpty else { return false }
        let lock = NSLock()
        var collected: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); collected.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { self.performDrop(collected, into: destination) }
        return true
    }

    // MARK: recoverable file operations

    /// "untitled.txt", then "untitled 2.txt" -- the number goes before the
    /// extension, not after it.
    private func uniqueName(_ proposed: String, in folder: URL) -> String {
        let stem = (proposed as NSString).deletingPathExtension
        let ext = (proposed as NSString).pathExtension
        var name = proposed
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            n += 1
        }
        return name
    }

    /// A new item lands selected and in inline rename, so the name can be typed
    /// straight away. When it was created somewhere other than the folder being
    /// browsed -- from the tree's own menu -- only that tree node is reloaded.
    private func created(_ target: URL, in destination: URL) {
        reloadTreeNode(for: destination)
        guard destination == folder else { return }
        refresh()
        selected = [target]
        selectionAnchor = target
        renaming = target
        renameText = target.lastPathComponent
    }

    func newFolder(in destination: URL? = nil) {
        guard let parent = destination ?? folder else { return }
        let target = parent.appendingPathComponent(uniqueName("untitled folder", in: parent))
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            created(target, in: parent)
        } catch {
            errorText = "Could not create folder: \(error.localizedDescription)"
        }
    }

    func newFile(_ template: FileTemplate, in destination: URL? = nil) {
        guard let parent = destination ?? folder else { return }
        let name = uniqueName(template.name, in: parent)
        let target = parent.appendingPathComponent(name)
        var attributes: [FileAttributeKey: Any] = [:]
        if template.executable { attributes[.posixPermissions] = 0o755 }
        guard FileManager.default.createFile(atPath: target.path,
                                             contents: Data(template.body.utf8),
                                             attributes: attributes) else {
            errorText = "Could not create \"\(name)\" here. The folder may not be writable."
            return
        }
        created(target, in: parent)
    }

    func beginRename() {
        guard let entry = selectedEntries.first else { return }
        guard !refuse("renamed", [entry]) else { return }
        renaming = entry.url
        renameText = entry.name
    }

    /// The single place a rename field closes, so a reload that arrived while
    /// it was open gets replayed rather than lost.
    func endRename() {
        renaming = nil
        drainPendingReload()
    }

    func commitRename() {
        guard let url = renaming else { return }
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        endRename()
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
    /// Compress the selection into a zip beside it, as Explorer's "Compress to
    /// ZIP file" and the Finder's "Compress" both do.
    ///
    /// One item goes through `ditto`, which keeps symlinks, resource forks and
    /// the code signature of a bundle -- a zipped .app made any other way often
    /// will not launch. Several items go through `zip`, because ditto archives
    /// exactly one source; the trade is that a multi-item archive does not
    /// preserve resource forks, which is what the Finder does too.
    ///
    /// The destination never overwrites: a name that is taken becomes "x copy",
    /// the same rule every other transfer in this app follows.
    func compressSelection() {
        let targets = selectedEntries
        guard !targets.isEmpty, let folder else { return }
        let base = targets.count == 1
            ? targets[0].url.deletingPathExtension().lastPathComponent
            : "Archive"
        let destination = Self.uniqueDestination(
            for: folder.appendingPathComponent(base + ".zip"), in: folder)
        let names = targets.map(\.url.lastPathComponent)

        opRunning = true
        opTotal = 1
        opDone = 0
        opCurrent = destination.lastPathComponent

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            if names.count == 1 {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                     names[0], destination.path]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                process.arguments = ["-r", "-q", "-X", destination.path] + names
            }
            process.currentDirectoryURL = folder
            // Output goes nowhere rather than into a pipe nobody drains: a full
            // pipe buffer would block the process forever.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            var failure: String?
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    failure = "the archiver reported an error"
                }
            } catch {
                failure = error.localizedDescription
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.opRunning = false
                self.opDone = 1
                if let failure {
                    self.errorText = "Could not compress: \(failure)"
                } else {
                    // Undo puts the new archive in the Trash, like every other
                    // operation here: undo is itself recoverable.
                    self.lastOperation = [(from: destination, to: destination, mode: .copy)]
                }
                self.refresh()
                self.selected = [destination]
            }
        }
    }

    /// The Recycle Bin's real location.
    static let trashURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".Trash")

    /// True when the pane is showing the bin, which is the only place the two
    /// permanent-delete verbs are offered.
    var isViewingTrash: Bool {
        folder?.standardizedFileURL.path == Self.trashURL.standardizedFileURL.path
    }

    /// Empty the bin.
    ///
    /// This is the one place in the app that destroys something for good, and it
    /// exists because a Recycle Bin you cannot empty is half a bin. Everywhere
    /// else, delete means Trash precisely so it can be undone. It asks first,
    /// says how many items and how much space, and defaults to Cancel.
    func emptyTrash() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.trashURL, includingPropertiesForKeys: [.fileSizeKey],
            options: [])) ?? []
        guard !contents.isEmpty else {
            errorText = "The Recycle Bin is already empty, or macOS will not let "
                + "Directories read it. Granting Full Disk Access fixes the second one."
            return
        }
        let count = contents.count
        guard confirmDestructive(
            title: "Empty the Recycle Bin?",
            body: "\(count) item\(count == 1 ? "" : "s") will be deleted immediately. "
                + "This cannot be undone.",
            verb: "Empty Recycle Bin") else { return }

        var failed: [String] = []
        for url in contents {
            do { try FileManager.default.removeItem(at: url) }
            catch { failed.append(url.lastPathComponent) }
        }
        refresh()
        if !failed.isEmpty {
            errorText = "Could not delete: \(failed.joined(separator: ", "))"
        }
    }

    /// Delete the selection outright. Offered only inside the bin, where the
    /// items are already deleted and the Trash is not somewhere left to put them.
    func deletePermanently() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        guard !refuse("deleted", targets) else { return }
        let names = targets.count == 1 ? "\"\(targets[0].name)\""
            : "\(targets.count) items"
        guard confirmDestructive(
            title: "Delete \(names) permanently?",
            body: "This deletes immediately and cannot be undone.",
            verb: "Delete") else { return }

        var failed: [String] = []
        for entry in targets {
            do { try FileManager.default.removeItem(at: entry.url) }
            catch { failed.append(entry.name) }
        }
        refresh()
        if !failed.isEmpty {
            errorText = "Could not delete: \(failed.joined(separator: ", "))"
        }
    }

    /// A modal that defaults to Cancel and marks the destructive button as such,
    /// so Return does the safe thing.
    private func confirmDestructive(title: String, body: String, verb: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        let destructive = alert.addButton(withTitle: verb)
        destructive.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    func moveToTrash() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        // Refuse the whole thing rather than trashing the part that is allowed:
        // a half-done delete is worse to recover from than one that did not run.
        guard !refuse("moved to the Trash", targets) else { return }
        var failed: [String] = []
        for entry in targets {
            do { try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil) }
            catch { failed.append(entry.name) }
        }
        refresh()
        if let folder { reloadTreeNode(for: folder) }
        if !failed.isEmpty { errorText = "Could not move to Trash: \(failed.joined(separator: ", "))" }
    }

    /// Reloads every tree node showing this path -- the same folder can appear
    /// under both Favorites and Locations. A node that has never been opened is
    /// left alone: it reads itself fresh whenever it is.
    func reloadTreeNode(for url: URL) {
        let target = FolderWatcher.normalize(url.path)
        func walk(_ node: FileNode) {
            if FolderWatcher.normalize(node.url.path) == target {
                if node.loaded { node.reload() }
                return
            }
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

    /// Cheap safety net over FSEvents, which is unreliable on network volumes
    /// and delivers nothing at all while the machine is asleep.
    func windowBecameActive() { reloadCurrent() }

    func toggleSort(_ field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            if !sortAscending { sortAscending = true }   // avoid a second recompute
        }
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
    @State private var isDropTarget = false

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
            .contextMenu { TreeNodeMenu(node: node) }
        }
        .listRowSeparator(.hidden)     // no rules between tree rows
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        .onDrag {
            _ = state.beginDrag(node.url)
            return NSItemProvider(object: node.url as NSURL)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            state.handleDrop(providers, into: node.url)
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
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
    @EnvironmentObject var layout: ColumnLayout

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
        Button("Reset Columns") { state.resetColumns(); layout.reset() }
    }
}

// MARK: - Header

/// A draggable divider sitting to the LEFT of the column it controls.
///
/// Dragging right must make that column narrower, not wider: the row is a fixed
/// width, so a wider right-hand column squeezes the flexible Name column and
/// pulls the divider away from the cursor. The delta is therefore subtracted.
struct ResizeHandle: View {
    let width: CGFloat
    let minWidth: CGFloat
    var maxWidth: CGFloat = 420      // stop one column swallowing the whole row
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    @State private var startWidth: CGFloat?
    @State private var cursorPushed = false

    var body: some View {
        ZStack {
            Color.clear.frame(width: 9, height: 18)
            Rectangle().fill(Color.secondary.opacity(0.30)).frame(width: 1, height: 12)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            // push/pop must be balanced. Firing push() on every hover callback
            // corrupts the cursor stack and makes the pointer flicker.
            if inside, !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
            if !inside, cursorPushed { NSCursor.pop(); cursorPushed = false }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if startWidth == nil { startWidth = width }
                    let base = startWidth ?? width
                    // Whole points only: subpixel churn republishes state for
                    // changes too small to see.
                    let next = min(maxWidth, max(minWidth, base - g.translation.width)).rounded()
                    guard next != width else { return }
                    // Without this, SwiftUI interpolates every intermediate
                    // width and the overlapping animations read as flicker.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { onChange(next) }
                }
                .onEnded { _ in
                    startWidth = nil
                    if cursorPushed { NSCursor.pop(); cursorPushed = false }
                    onEnd()
                }
        )
    }
}

struct HeaderCell: View {
    /// Shared with `ListRow` so the header and the rows shrink in step.
    static let minimumNameWidth: CGFloat = 140

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
        // The name column is the flexible one, so it absorbs every bit of
        // squeeze when the fixed columns are wider than the window. Without a
        // floor it collapses to nothing and the list shows icons, sizes and
        // dates with no names at all -- see the note on ListRow.
        .frame(minWidth: width == nil ? Self.minimumNameWidth : nil,
               maxWidth: width == nil ? .infinity : nil,
               alignment: trailing ? .trailing : .leading)
        .frame(width: width, alignment: trailing ? .trailing : .leading)
        .foregroundStyle(state.sortField == field ? Color.primary : Color.secondary)
        .contentShape(Rectangle())
        .onTapGesture { state.toggleSort(field) }
    }
}

struct ColumnHeaders: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var layout: ColumnLayout

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 33)     // icon gutter
            HeaderCell(field: .name, width: nil, trailing: false)
            ForEach(state.columns, id: \.self) { column in
                ResizeHandle(width: layout.width(column), minWidth: column.minWidth,
                             onChange: { layout.setWidth(column, $0) },
                             onEnd: { layout.commit() })
                HeaderCell(field: .column(column), width: layout.width(column), trailing: column.trailing)
            }
            Spacer().frame(width: 12)
        }
        .frame(height: 22)
        .background(Color.secondary.opacity(0.06))
        .contextMenu { ColumnMenu() }     // right-click the header to choose columns
    }
}

// MARK: - Menus over a folder

/// The "New >" submenu, shared by the folder menu, the tree and the menu bar.
/// `target` is nil for the folder being browsed.
struct NewItemMenu: View {
    @EnvironmentObject var state: AppState
    var target: URL? = nil

    var body: some View {
        Menu("New") {
            Button("Folder") { state.newFolder(in: target) }
            Divider()
            ForEach(FileTemplate.all) { template in
                Button(template.label) { state.newFile(template, in: target) }
            }
        }
    }
}

/// The background menu: right-click the empty space of the folder pane, the way
/// Explorer does it. Everything here acts on the folder being browsed rather
/// than on a selection, which is what makes it useful in an empty folder --
/// there is no row to aim at.
struct FolderMenu: View {
    @EnvironmentObject var state: AppState
    var target: URL? = nil

    private var subject: URL? { target ?? state.folder }

    var body: some View {
        // The bin is not a folder you put things in, so the verbs that would
        // create or paste into it are not offered there.
        if state.isViewingTrash {
            Button("Empty Recycle Bin") { state.emptyTrash() }
            Button("Select All") { state.selectAll() }
            Divider()
        } else {
            NewItemMenu(target: target)
            Divider()
            Button("Paste") { state.paste(into: target) }.disabled(!state.canPaste)
            Button("Select All") { state.selectAll() }
            Button("Undo Last File Operation") { state.undoLastOperation() }
                .disabled(!state.canUndo)
            Divider()
        }
        Button("Open in Terminal") { state.openTerminal(at: subject) }
        Button("Show in Finder") {
            if let subject {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: subject.path)
            }
        }
        Button("Copy Path") { state.copyToPasteboard(subject?.path ?? "") }
        Divider()
        Menu("Sort By") {
            Button("Name") { state.toggleSort(.name) }
            ForEach(state.columns, id: \.self) { column in
                Button(column.label) { state.toggleSort(.column(column)) }
            }
        }
        Menu("View As") {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Button(mode.label) { state.setViewMode(mode) }
            }
        }
        Menu("Columns") { ColumnMenu() }
        // A leading check mark reads correctly in an AppKit context menu.
        Button(state.showHidden ? "\u{2713}  Show Hidden Files" : "     Show Hidden Files") {
            state.toggleHidden()
        }
        Divider()
        Button("Refresh") { state.reloadCurrent() }
    }
}

// MARK: - Rows

/// The tree's context menu.
///
/// A separate view rather than an inline `.contextMenu { }` because SwiftUI
/// builders are type-checked as a single expression, and this one grew past
/// what the compiler will solve in reasonable time -- it fails with "unable to
/// type-check this expression" rather than anything about the menu.
struct TreeNodeMenu: View {
    let node: FileNode
    @EnvironmentObject var state: AppState

    private var blocked: String? { FS.protection(for: node.url) }

    var body: some View {
        Button("Open in New Tab") { state.openInNewTab(node.url) }
        Button("Show in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: node.url.path)
        }
        Button("Open in Terminal") { state.openTerminal(at: node.url) }
        Divider()
        NewItemMenu(target: node.url)
        Divider()
        clipboardSection
        Divider()
        Button("Copy Path") { state.copyToPasteboard(node.url.path) }
        Button("Get Info") { state.infoTarget = Entry.read(node.url) }
        Divider()
        destructiveSection
        Divider()
        Button("Refresh") { node.reload() }
    }

    @ViewBuilder
    private var clipboardSection: some View {
        Button(blocked.map { "Cut (\($0))" } ?? "Cut") { state.stage([node.url], .move) }
            .disabled(blocked != nil).help(blocked ?? "")
        Button("Copy") { state.stage([node.url], .copy) }
        Button("Paste Into Folder") { state.paste(into: node.url) }
            .disabled(!state.canPaste)
    }

    @ViewBuilder
    private var destructiveSection: some View {
        Button(blocked.map { "Rename (\($0))" } ?? "Rename") {
            // Renaming happens in the list, so the folder has to be showing
            // before the field can open on it.
            state.go(node.url.deletingLastPathComponent())
            state.selected = [node.url]
            state.beginRename()
        }
        .disabled(blocked != nil).help(blocked ?? "")
        Button(blocked.map { "Move to Trash (\($0))" } ?? "Move to Trash") {
            state.selected = [node.url]
            state.moveToTrash()
        }
        .disabled(blocked != nil).help(blocked ?? "")
    }
}

struct RenameField: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool
    /// Escape has to be caught before AppKit's field editor sees it. The editor
    /// treats it as its own cancel and consumes the event, so `onExitCommand`
    /// on the text field never fired and Escape did nothing. A local monitor
    /// runs first. It is created with the field and removed with it, so exactly
    /// one exists while a rename is open and none otherwise.
    @State private var escapeMonitor: Any?

    var body: some View {
        TextField("", text: $state.renameText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12.5))
            .focused($focused)
            .onAppear {
                focused = true
                guard escapeMonitor == nil else { return }
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
                    guard event.keyCode == 53 else { return event }      // Escape
                    state.endRename()
                    return nil
                }
            }
            .onDisappear {
                if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
                escapeMonitor = nil
            }
            .onSubmit { state.commitRename() }
    }
}

struct ListRow: View {
    let entry: Entry
    @EnvironmentObject var state: AppState
    @EnvironmentObject var layout: ColumnLayout
    @State private var isDropTarget = false

    private var isSelected: Bool { state.selected.contains(entry.url) }

    var body: some View {
        // Only folders accept a drop; a file row must stay inert so the drop
        // falls through to the folder being browsed.
        if entry.isFolder {
            row
                .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
                    state.handleDrop(providers, into: entry.url)
                }
                .overlay {
                    if isDropTarget {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 0) {
            Image(nsImage: FS.icon(entry.url))
                .resizable().frame(width: 17, height: 17)
                .padding(.leading, 8).padding(.trailing, 8)

            Group {
                if state.renaming == entry.url {
                    RenameField()
                } else {
                    // The gestures sit on the text rather than on the Group, so
                    // the rename target is the name itself and not the empty
                    // run of column beside it.
                    Text(entry.name).lineLimit(1).font(.system(size: 12.5))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { state.open(entry) }
                        .onTapGesture { nameTapped() }
                }
            }
            // A floor under the name.
            //
            // The name is the only flexible child of the row, so when the
            // chosen columns are together wider than the window, SwiftUI takes
            // the whole difference out of this one view and squeezes it to zero
            // -- a list of icons, sizes and dates with no names, which is what
            // it did after a few columns were widened and the window was made
            // narrower. Explorer keeps the name and lets the columns to its
            // right run off the edge instead, which is the right trade: the
            // name is the thing you are reading.
            .frame(minWidth: HeaderCell.minimumNameWidth, maxWidth: .infinity, alignment: .leading)

            ForEach(state.columns, id: \.self) { column in
                Spacer().frame(width: 9)      // matches the header's resize handle
                Text(entry.text(for: column)).lineLimit(1)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: layout.width(column), alignment: column.trailing ? .trailing : .leading)
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
        .onDrag {
            _ = state.beginDrag(entry.url)
            return NSItemProvider(object: entry.url as NSURL)
        }
    }

    private func toggleSelect() {
        let flags = ClickModifiers.current
        state.click(entry.url, shift: flags.contains(.shift), command: flags.contains(.command))
    }

    private func nameTapped() {
        let flags = ClickModifiers.current
        state.nameClicked(entry.url, shift: flags.contains(.shift), command: flags.contains(.command))
    }
}

struct IconCell: View {
    let entry: Entry
    @EnvironmentObject var state: AppState
    @State private var isDropTarget = false

    private var isSelected: Bool { state.selected.contains(entry.url) }

    var body: some View {
        if entry.isFolder {
            cell
                .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
                    state.handleDrop(providers, into: entry.url)
                }
                .overlay {
                    if isDropTarget {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        } else {
            cell
        }
    }

    private var cell: some View {
        VStack(spacing: 5) {
            Image(nsImage: FS.icon(entry.url)).resizable().frame(width: 46, height: 46)
            if state.renaming == entry.url {
                RenameField().frame(width: 96)
            } else {
                Text(entry.name).font(.system(size: 11)).multilineTextAlignment(.center)
                    .lineLimit(2).frame(width: 96)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { state.open(entry) }
                    .onTapGesture {
                        let flags = ClickModifiers.current
                        state.nameClicked(entry.url,
                                          shift: flags.contains(.shift),
                                          command: flags.contains(.command))
                    }
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
            let flags = ClickModifiers.current
            state.click(entry.url, shift: flags.contains(.shift), command: flags.contains(.command))
        }
        .contextMenu { EntryMenu(entry: entry) }
        .onDrag {
            _ = state.beginDrag(entry.url)
            return NSItemProvider(object: entry.url as NSURL)
        }
    }
}

// MARK: - Shared row context menu

/// The row menu, shaped by what is actually selected.
///
/// Right-clicking inside a selection acts on all of it; right-clicking outside
/// one moves the selection to that row first. Both Explorer and the Finder
/// behave this way.
///
/// Anything that only makes sense for a single item, or only for a folder, is
/// left out rather than shown and quietly doing the wrong thing. That was not
/// cosmetic: every one of these used to reset the selection to the row under
/// the cursor first, so "Move to Trash" on five selected files trashed one and
/// left the other four looking as though they had gone.
struct EntryMenu: View {
    let entry: Entry
    @EnvironmentObject var state: AppState

    /// What the menu will act on: the whole selection when the clicked row is
    /// part of it, otherwise just that row.
    private var targets: [Entry] {
        state.selected.contains(entry.url) ? state.selectedEntries : [entry]
    }
    private var count: Int { targets.count }
    private var isSingle: Bool { count == 1 }
    private var allFolders: Bool { targets.allSatisfy(\.isFolder) }

    /// Appended to a verb so a label says what it will touch: "Copy 3 Items".
    private var noun: String { isSingle ? "" : " \(count) Items" }

    /// Right-clicking a row outside the current selection selects it first, so
    /// the action and the label the person read agree.
    private func act(_ body: () -> Void) {
        if !state.selected.contains(entry.url) { state.selected = [entry.url] }
        body()
    }

    /// The files in the selection, and whether they are all of one type.
    /// Explorer offers "Open with" for a run of files that share an extension
    /// and drops it the moment a folder or a second type joins them.
    private var files: [Entry] { targets.filter { !$0.isFolder } }
    private var oneFileType: Bool {
        files.count == count && !files.isEmpty
            && Set(files.map { $0.ext.lowercased() }).count == 1
    }

    /// Past fifteen items Explorer stops offering the verbs that would open a
    /// window each, rather than opening fifteen of them. Same limit here.
    private var withinOpenLimit: Bool { count <= AppState.multipleOpenLimit }

    /// Why this selection may not be renamed, moved or trashed; nil when it may.
    private var blocked: String? {
        targets.lazy.compactMap { FS.protection(for: $0.url) }.first
    }

    /// Disabled entries say why in the label as well as the tooltip, so the
    /// reason is there whether or not the menu chooses to show a tooltip.
    private func label(_ verb: String) -> String {
        let base = "\(verb)\(noun)"
        return blocked.map { "\(base) (\($0))" } ?? base
    }

    var body: some View {
        if withinOpenLimit {
            Button("Open\(noun)") { act { state.openSelection() } }
            if allFolders {
                Button(isSingle ? "Open in New Tab" : "Open in \(count) New Tabs") {
                    act { for target in targets { state.openInNewTab(target.url) } }
                }
            }
            if oneFileType {
                let apps = state.applications(for: entry.url)
                if !apps.isEmpty {
                    Menu("Open With") {      // the system's own association list
                        ForEach(apps, id: \.self) { app in
                            Button(FS.displayName(app)) {
                                act { for file in files { state.open(file.url, with: app) } }
                            }
                        }
                    }
                }
            }
            Divider()
        }
        // Quick Look and Get Info each show exactly one item, so they only
        // appear when exactly one is meant.
        if isSingle {
            Button("Quick Look") { act { state.quickLook() } }
            Button("Get Info") { state.infoTarget = entry }
        }
        Button("Show in Finder") { act { state.showInFinder() } }
        if isSingle && entry.isFolder {
            Button("Open in Terminal") { state.openTerminal(at: entry.url) }
        }
        Divider()
        Button(label("Cut")) { act { state.cutSelection() } }
            .disabled(blocked != nil).help(blocked ?? "")
        Button("Copy\(noun)") { act { state.copySelection() } }
        if isSingle && entry.isFolder {
            Button("Paste Into Folder") { state.paste(into: entry.url) }.disabled(!state.canPaste)
        } else {
            Button("Paste") { state.paste() }.disabled(!state.canPaste)
        }
        Button("Duplicate\(noun)") { act { state.duplicateSelection() } }
        if !state.isViewingTrash {
            Button(isSingle ? "Compress to ZIP" : "Compress \(count) Items to ZIP") {
                act { state.compressSelection() }
            }
        }
        Divider()
        ShareLink(items: targets.map(\.url)) { Text("Share\(noun)") }
        if isSingle {
            Button(label("Rename")) { state.selected = [entry.url]; state.beginRename() }
                .disabled(blocked != nil).help(blocked ?? "")
        }
        Divider()
        Button(isSingle ? "Copy Path" : "Copy \(count) Paths") {
            state.copyToPasteboard(targets.map(\.url.path).joined(separator: "\n"))
        }
        Button(isSingle ? "Copy Name" : "Copy \(count) Names") {
            state.copyToPasteboard(targets.map(\.name).joined(separator: "\n"))
        }
        Divider()
        // Inside the bin the items are already deleted, so there is nowhere
        // left to move them to and the only delete that means anything is the
        // permanent one. Everywhere else it is the only delete NOT offered.
        if state.isViewingTrash {
            Button(blocked.map { "Delete\(noun) Permanently (\($0))" }
                   ?? "Delete\(noun) Permanently") {
                act { state.deletePermanently() }
            }
            .disabled(blocked != nil).help(blocked ?? "")
            Button("Empty Recycle Bin") { state.emptyTrash() }
        } else {
            Button(blocked.map { "Move\(noun) to Trash (\($0))" }
                   ?? (isSingle ? "Move to Trash" : "Move\(noun) to Trash")) {
                act { state.moveToTrash() }
            }
            .disabled(blocked != nil).help(blocked ?? "")
            // Explorer swaps this item in when Shift is held. A SwiftUI menu
            // cannot see the modifier, so it is listed with its shortcut
            // instead of hidden behind a key nobody would guess.
            Button(blocked.map { "Delete\(noun) Permanently (\($0))" }
                   ?? "Delete\(noun) Permanently") {
                act { state.deletePermanently() }
            }
            .disabled(blocked != nil).help(blocked ?? "")
        }
        Divider()
        Button("Refresh") { state.reloadCurrent() }
    }
}

// MARK: - Address bar

/// The address bar, in the two states Explorer gives it.
///
/// Unfocused it is a row of breadcrumbs: every component of the path is a button
/// that navigates to it, and the chevron after a component lists that folder's
/// subfolders, so stepping sideways does not mean going up first. Clicking the
/// empty run to the right of the last crumb -- or Go > Open Location -- turns the
/// strip into the editable path field with the path selected, ready to be
/// replaced or copied whole. Return commits, Escape reverts, and clicking away
/// puts the breadcrumbs back.
///
/// Both states are pinned to the same height so the toolbar does not shift when
/// you click into it.
struct AddressBar: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool
    @State private var editing = false

    private static let height: CGFloat = 22

    var body: some View {
        Group {
            if editing { field } else { breadcrumbs }
        }
        .frame(height: Self.height)
        // Go > Open Location, which is a request for the editable form.
        .onChange(of: state.focusAddress) { _, wanted in
            if wanted { state.focusAddress = false; startEditing() }
        }
    }

    // MARK: editable

    private var field: some View {
        TextField("Path", text: $state.addressText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .focused($focused)
            .onSubmit { state.commitAddress(); stopEditing() }
            .onExitCommand { state.cancelAddress(); stopEditing() }
            .onChange(of: focused) { _, isFocused in
                // Clicking elsewhere means the same as Escape: a path half typed
                // is not a path, and leaving it on screen would misreport where
                // the window actually is.
                if !isFocused { state.cancelAddress(); editing = false }
            }
            .onAppear(perform: takeFocus)
    }

    private func startEditing() {
        // The field focuses itself as it appears; if it is already up, this is
        // a second Open Location and only the focus needs renewing.
        if editing { takeFocus() } else { editing = true }
    }

    private func stopEditing() {
        editing = false
        focused = false
    }

    private func takeFocus() {
        focused = true
        // Explorer hands over the whole path selected, so it can be replaced or
        // copied in one action. The field only exists once focus has landed, so
        // the select-all has to wait a turn.
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    // MARK: breadcrumbs

    /// Root first, current folder last.
    private var components: [URL] {
        guard let folder = state.folder?.standardizedFileURL else { return [] }
        var list = [folder]
        var url = folder
        while url.path != "/" {
            let parent = url.deletingLastPathComponent().standardizedFileURL
            guard parent.path != url.path else { break }
            list.append(parent)
            url = parent
        }
        return list.reversed()
    }

    private var breadcrumbs: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(components, id: \.path) { url in
                        Crumb(url: url) { state.go(url) }
                        CrumbChevron(folder: url, showHidden: state.showHidden) { state.go($0) }
                            .frame(width: 15, height: Self.height)
                    }
                    // The empty run after the last crumb is what turns the strip
                    // into a text field, as it does in Explorer. It has to stretch
                    // to the full width of the bar, or a short path would leave
                    // nowhere to click.
                    Color.clear
                        .frame(minWidth: 30)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: startEditing)
                }
                .padding(.horizontal, 3)
                // A deep path scrolls rather than squeezing, and rests at the
                // trailing end, so the folder you are in is the one on screen.
                .frame(minWidth: geo.size.width, alignment: .leading)
            }
            .defaultScrollAnchor(.trailing)
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

/// One path component. Clicking navigates to it.
private struct Crumb: View {
    let url: URL
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(FS.displayName(url))
            .font(.system(size: 12))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(hovering ? Color.secondary.opacity(0.18) : Color.clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(url.path)
    }
}

/// The chevron after a crumb: it opens that folder's subfolders, which is how
/// Explorer lets you step sideways without going up first.
///
/// AppKit rather than a SwiftUI `Menu` because the items are a directory
/// listing, and SwiftUI builds a menu's contents whenever the surrounding body
/// is evaluated -- every keystroke in the filter field, among others. That would
/// read every folder on the path over and over for menus nobody opened.
/// `menuNeedsUpdate` runs only when one is genuinely about to appear.
private struct CrumbChevron: NSViewRepresentable {
    let folder: URL
    let showHidden: Bool
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = ChevronButton()
        button.image = NSImage(systemSymbolName: "chevron.right",
                               accessibilityDescription: "Subfolders")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.title = ""
        button.contentTintColor = .secondaryLabelColor
        let menu = NSMenu()
        menu.delegate = context.coordinator
        button.menu = menu
        apply(context.coordinator)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) { apply(context.coordinator) }

    private func apply(_ coordinator: Coordinator) {
        coordinator.folder = folder
        coordinator.showHidden = showHidden
        coordinator.onPick = onPick
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var folder = URL(fileURLWithPath: "/")
        var showHidden = false
        var onPick: (URL) -> Void = { _ in }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let subfolders = FS.subfolders(folder, showHidden: showHidden)
            guard !subfolders.isEmpty else {
                let empty = NSMenuItem(title: "No subfolders", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
                return
            }
            for url in subfolders {
                let item = NSMenuItem(title: FS.displayName(url),
                                      action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                // A copy, because the cache hands out one shared image per path
                // and menu items want it at a different size than the rows do.
                if let icon = FS.icon(url).copy() as? NSImage {
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }
                menu.addItem(item)
            }
        }

        @objc private func pick(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            onPick(url)
        }
    }
}

/// A borderless button that drops its menu on a plain left click. `NSButton`
/// only does that for a pull-down `NSPopUpButton`, which brings its own bezel
/// and title with it.
private final class ChevronButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        guard let menu else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: isFlipped ? bounds.height : 0),
                   in: self)
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var panelDropTarget = false

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
                // Right-clicking anywhere that is not a row gets the folder
                // menu. A row's own menu is nested deeper and so wins over this
                // one wherever there is a row to hit.
                .contextMenu { FolderMenu() }
                // Empty space in the panel targets the folder being browsed, so
                // a drag from the tree can land without aiming at a row.
                .onDrop(of: [.fileURL], isTargeted: $panelDropTarget) { providers in
                    guard let folder = state.folder else { return false }
                    return state.handleDrop(providers, into: folder)
                }
                .overlay {
                    if panelDropTarget {
                        Rectangle()
                            .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(minWidth: 940, minHeight: 540)
        .onAppear { state.start() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            state.windowBecameActive()
        }
        .quickLookPreview($state.previewURL)          // the system preview panel
        .sheet(item: $state.infoTarget) { InfoSheet(entry: $0) }
        .sheet(isPresented: Binding(
            get: { state.opRunning }, set: { if !$0 { state.cancelOperation() } }
        )) { TransferSheet() }
        .alert("Directories", isPresented: Binding(
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

            AddressBar()

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
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .contextMenu { FolderMenu() }
            }
        }
    }

    /// An empty folder is exactly where the background menu matters most, so
    /// this carries its own copy rather than relying on the pane's.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if state.accessDenied {
                Text("macOS will not let Directories read this folder")
                    .foregroundStyle(.secondary).font(.system(size: 13))
                Text("The Recycle Bin and a few other locations need Full Disk "
                     + "Access. macOS never asks for it, so it has to be granted "
                     + "by hand -- until it is, they look empty rather than "
                     + "refused.")
                    .foregroundStyle(.secondary).font(.system(size: 11))
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
                Button("Open Full Disk Access Settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference."
                                  + "security?Privacy_AllFiles")!
                    NSWorkspace.shared.open(url)
                }
                .font(.system(size: 11))
            } else {
                Text(state.filter.isEmpty ? "This folder is empty" : "No items match \"\(state.filter)\"")
                    .foregroundStyle(.secondary).font(.system(size: 13))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .contentShape(Rectangle())
        .contextMenu { FolderMenu() }
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
    @ObservedObject var layout: ColumnLayout

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { state.newTab() }.keyboardShortcut("t")
            Button("New Folder") { state.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Menu("New File") {
                ForEach(FileTemplate.all) { template in
                    Button(template.label) { state.newFile(template) }
                }
            }
            Button("Close Tab") { state.closeTab() }.keyboardShortcut("w")
            Divider()
            Button("Open") { state.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command).disabled(state.selected.isEmpty)
            // Both show exactly one item, so both need exactly one selected -
            // with several they used to act on whichever happened to sort first.
            Button("Quick Look") { state.quickLook() }
                .keyboardShortcut(.space, modifiers: []).disabled(state.selected.count != 1)
            Button("Get Info") { state.infoTarget = state.selectedEntries.first }
                .keyboardShortcut("i").disabled(state.selected.count != 1)
            Button("Open in Terminal") { state.openTerminal() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) {
            Button(state.selectionNoun("Cut")) { state.cutSelection() }
                .keyboardShortcut("x")
                .disabled(state.selected.isEmpty || state.selectionProtection != nil)
                .help(state.selectionProtection ?? "")
            Button(state.selectionNoun("Copy")) { state.copySelection() }
                .keyboardShortcut("c").disabled(state.selected.isEmpty)
            Button("Paste") { state.paste() }
                .keyboardShortcut("v").disabled(!state.canPaste)
            Button(state.selectionNoun("Duplicate")) { state.duplicateSelection() }
                .keyboardShortcut("d").disabled(state.selected.isEmpty)
            Divider()
            Button("Undo Last File Operation") { state.undoLastOperation() }
                .keyboardShortcut("z").disabled(!state.canUndo)
            Divider()
            Button("Select All") { state.selectAll() }.keyboardShortcut("a")
            Button("Rename") { state.beginRename() }
                .disabled(state.selected.count != 1 || state.selectionProtection != nil)
                .help(state.selectionProtection ?? "")
            Button(state.selected.count > 1
                   ? "Move \(state.selected.count) Items to Trash" : "Move to Trash") {
                state.moveToTrash()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(state.selected.isEmpty || state.selectionProtection != nil)
            .help(state.selectionProtection ?? "")
            // Windows' Shift+Delete, with Command added because Delete alone is
            // a text key on a Mac and Command+Delete is already the trash. It
            // always asks first: this is the one gesture in the app that cannot
            // be undone, and it is one modifier away from the one that can.
            Button(state.selected.count > 1
                   ? "Delete \(state.selected.count) Items Permanently"
                   : "Delete Permanently") {
                state.deletePermanently()
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(state.selected.isEmpty || state.selectionProtection != nil)
            .help(state.selectionProtection ?? "")
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
            Menu("Columns") { ColumnMenu().environmentObject(state).environmentObject(layout) }
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
            Button("Refresh") { state.reloadCurrent() }.keyboardShortcut("r")
        }
    }
}

@main
struct DirectoriesApp: App {
    @StateObject private var state = AppState()
    @StateObject private var layout = ColumnLayout()

    var body: some Scene {
        WindowGroup("Directories") {
            ContentView()
                .environmentObject(state)
                .environmentObject(layout)
        }
        .commands { AppCommands(state: state, layout: layout) }
    }
}
