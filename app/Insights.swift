import Foundation
import SwiftUI
import AppKit

nonisolated enum DiskInsights {
    // Mirrors Mole lib/clean/purge_shared.sh. scripts/check-capabilities.py checks drift.
    static let projectNames: Set<String> = ["node_modules","target","build","dist","venv",".venv",
        ".pytest_cache",".mypy_cache",".tox",".nox",".ruff_cache",".gradle",".terragrunt-cache",
        "__pycache__",".next",".nuxt",".output","vendor","bin","obj",".turbo",".parcel-cache",
        ".dart_tool",".zig-cache","zig-out",".angular",".svelte-kit",".astro","coverage",
        "DerivedData","Pods",".cxx",".expo",".build"]

    /// Mole cmd/analyze/snapshots.go parity: count dates only; never infer snapshot bytes.
    static func localSnapshots() -> Int? {
        let result = AgentLocator.run("/usr/bin/tmutil",["listlocalsnapshotdates","/"],timeout:3)
        guard result.status == 0 else { return nil }
        let pattern = #"^\d{4}-\d{2}-\d{2}-\d{6}$"#
        return result.out.split(separator:"\n").filter {
            String($0).trimmingCharacters(in:.whitespaces).range(of:pattern,options:.regularExpression) != nil
        }.count
    }

    static func find(in tree: Tree) -> [CleanupItem] {
        var found: [Int: CleanupItem] = [:]
        var stack = [0]
        let home = NSHomeDirectory()
        func add(_ node: Int, category: String, reason: String) {
            let path = tree.path(node)
            let display = tree.displayPath(node)
            found[node] = CleanupItem(node:node,path:path,
                display:display.hasPrefix(home + "/") ? "~" + display.dropFirst(home.count) : display,
                kind:reason,bytes:tree.alloc[node],category:category,complete:tree.complete[node] && tree.hasExactPath(node))
        }
        while let parent = stack.popLast() {
            if Task.isCancelled { return [] }
            for child in tree.children(parent) {
                if Task.isCancelled { return [] }
                let node = Int(child), name = tree.name(node)
                if name == ".Trash" || name == ".Trashes" { continue }
                if tree.isDir(node) {
                    if projectNames.contains(name) {
                        add(node,category:"project",reason:"Project artifact; Mole checks ownership, authored content, and recent activity before cleanup.")
                        continue
                    }
                    if name == "Backup", tree.name(parent) == "MobileSync" {
                        add(node,category:"backup",reason:"Device backups. Review in Finder; removing these can lose your recovery copy.")
                    } else if ["Archives","iOS DeviceSupport","CoreSimulator"].contains(name) {
                        add(node,category:"developer",reason:"Xcode or simulator data. Owner-tool cleanup requires a specific supported action.")
                    } else if ["Docker","com.docker.docker","OrbStack","orbstack"].contains(name) {
                        add(node,category:"container",reason:"Container storage may contain volumes and user data; informational only.")
                    } else if tree.name(parent) == "Caches" || name == ".cache" {
                        add(node,category:"cache",reason:"Cache-like data. An owner-specific rule must validate cleanup; the name alone is not permission.")
                    } else if name == "Containers", tree.name(parent) == "Library" {
                        add(node,category:"container-data",reason:"Sandboxed application data. Containers may hold user documents; generic removal is unavailable.")
                    } else if tree.name(parent) == "Application Support" {
                        add(node,category:"app-data",reason:"Application data. Installed-owner and orphan checks are required before any cleanup.")
                    }
                    stack.append(node)
                } else {
                    let ext = (name as NSString).pathExtension.lowercased()
                    if ["dmg","pkg","mpkg","iso","xip"].contains(ext) {
                        add(node,category:"installer",reason:"Installer image or package. Restore from Trash or download it again if needed.")
                    } else if ext == "zip" {
                        add(node,category:"installer-zip",reason:"ZIP archive; Mole inspects a complete bounded listing for installer contents before allowing review.")
                    } else if ["tar","gz","7z","rar"].contains(ext) {
                        add(node,category:"archive",reason:"Archive contents may be unique user data; informational only.")
                    } else if name == "CACHEDIR.TAG" {
                        // The scanner has already avoided dataless folders. Do not hydrate a tag file.
                        let path = tree.path(node)
                        var before = stat()
                        guard lstat(path,&before) == 0, before.st_mode & S_IFMT == S_IFREG,
                              before.st_flags & 0x40000000 == 0 else { continue }
                        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                        if descriptor >= 0 {
                            defer { close(descriptor) }
                            var statValue = stat()
                            if fstat(descriptor,&statValue) == 0, statValue.st_mode & S_IFMT == S_IFREG,
                               statValue.st_flags & 0x40000000 == 0, statValue.st_ino == before.st_ino, statValue.st_dev == before.st_dev {
                                var prefix = [UInt8](repeating:0,count:43)
                                if read(descriptor,&prefix,43) == 43,
                                   Data(prefix) == Data("Signature: 8a477f597d28d172789f06886806bc55".utf8) {
                                    add(parent,category:"tagged-cache",reason:"Validated CACHEDIR.TAG signature. The tag identifies cache data; owner safety still needs validation.")
                                }
                            }
                        }
                    }
                }
                if tree.name(parent) == "Downloads" {
                    var info = stat()
                    if lstat(tree.path(node),&info) == 0, Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > 90*86400,
                       found[node] == nil {
                        add(node,category:"old-download",reason:"Not modified in over 90 days. Age does not prove this is disposable; informational only.")
                    }
                }
            }
        }
        return found.values.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
    }
}

nonisolated enum InventoryBrowse {
    static func largest(_ tree: Tree) -> [Int] {
        var result: [Int] = []
        for node in 1..<tree.count where !tree.isDir(node) {
            if Task.isCancelled { return [] }
            if result.count == 100, tree.alloc[node] <= tree.alloc[result.last!] { continue }
            let index = result.firstIndex { tree.alloc[node] > tree.alloc[$0] } ?? result.count
            result.insert(node,at:index)
            if result.count > 100 { result.removeLast() }
        }
        return result
    }
    static func search(_ tree: Tree, query: String) -> [Int] {
        var result: [Int] = []
        let pathQuery = query.contains("/")
        for node in 1..<tree.count {
            if Task.isCancelled { return [] }
            let value = pathQuery ? tree.displayPath(node) : tree.name(node)
            if value.localizedCaseInsensitiveContains(query) {
                result.append(node)
                if result.count == 1000 { break }
            }
        }
        return result.sorted { tree.alloc[$0] > tree.alloc[$1] }
    }
}

struct InventoryResults: View {
    let model: ScanModel
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            Text(model.searchText.isEmpty ? "Largest files (\(model.largestFiles.count))" : (model.searchLimited ? "First 1,000 matches" : "\(model.searchResults.count) matches"))
                .font(.headline).padding(12)
            if let tree = model.tree {
                List(model.searchText.isEmpty ? model.largestFiles : model.searchResults,id:\.self) { node in
                    Button { model.reveal(node) } label: {
                        HStack {
                            VStack(alignment:.leading) {
                                Text(tree.name(node)).lineLimit(1).truncationMode(.middle)
                                Text(tree.displayPath(node)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                            Spacer()
                            Text(Fmt.size(tree.alloc[node])).monospacedDigit()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

struct FindingInspector: View {
    let model: ScanModel
    @State private var inspecting = false
    var body: some View {
        if let tree = model.tree, let node = model.selection {
            VStack(alignment:.leading,spacing:6) {
                Text(tree.name(node)).font(.headline).lineLimit(2)
                Text(tree.displayPath(node)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Allocated: \(Fmt.size(tree.alloc[node])) · Logical: \(Fmt.size(tree.logical[node]))").font(.caption)
                if !tree.complete[node] { Label("Incomplete scan; observed size is a lower bound",systemImage:"exclamationmark.triangle").font(.caption) }
                if let candidate = model.cleanup.first(where: { $0.node == node }) {
                    Text(candidate.kind).font(.callout)
                    if let reason = candidate.blockingReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    if candidate.category == "installer-zip", !candidate.canReview, candidate.complete {
                        Button(inspecting ? "Inspecting…" : "Inspect archive") {
                            inspecting = true
                            Task { await model.inspectArchive(candidate); inspecting = false }
                        }.disabled(inspecting || model.scanning || CleanupCoordinator.shared.running)
                    }
                    if candidate.canReview { Text("Review before cleanup. Trash is recoverable until permanently emptied.").font(.caption) }
                }
            }.padding(12)
            Divider()
        }
    }
}
