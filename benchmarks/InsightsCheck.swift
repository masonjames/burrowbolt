import AppKit
import Foundation

@main struct InsightsCheck {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n",stderr);exit(1) }
    }
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("burrowbolt-insights-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        func file(_ name: String, _ data: String = "fixture") throws -> URL {
            let url=root.appendingPathComponent(name)
            try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(data.utf8).write(to:url);return url
        }
        _ = try file("tagged/CACHEDIR.TAG","Signature: 8a477f597d28d172789f06886806bc55\n# valid")
        _ = try file("invalid/CACHEDIR.TAG","not a cache signature")
        _ = try file("node_modules/deep/hidden.dmg")
        _ = try file("Installer.dmg")
        _ = try file("Archive.zip")
        let old=try file("Downloads/old.txt")
        try fm.setAttributes([.modificationDate:Date(timeIntervalSinceNow: -100*86400)],ofItemAtPath:old.path)
        for i in 0..<1100 { _ = try file("search/Needle-\(i).txt") }
        _ = try file("x.dmg")
        let handle=bz_scan_start(root.path)!
        var done:Int32=0,files:UInt64=0,dirs:UInt64=0,bytes:UInt64=0
        while done == 0 { usleep(1000);bz_progress(handle,&files,&dirs,&bytes,&done) }
        let tree=Tree(handle:handle)!
        // APFS refuses invalid UTF-8 filenames. Inject raw bytes after scanning to
        // exercise the foreign-filesystem boundary without relying on APFS behavior.
        let invalidNode=(0..<tree.count).first { tree.name($0)=="x.dmg" }!
        let invalidByte=UnsafeMutablePointer(mutating:tree.nameBlob+Int(tree.nameOff[invalidNode]))
        invalidByte.pointee=0xff
        defer { invalidByte.pointee=UInt8(ascii:"x") }
        check(!tree.hasExactPath(invalidNode),"Lossy raw path was accepted")
        let findings=DiskInsights.find(in:tree)
        func category(_ suffix:String)->String? { findings.first { $0.path.hasSuffix(suffix) }?.category }
        check(category("/tagged")=="tagged-cache","Valid CACHEDIR.TAG was missed")
        check(category("/invalid")==nil,"Invalid cache tag was accepted")
        check(category("/node_modules")=="project","Project target was missed")
        check(category("/hidden.dmg")==nil,"Artifact children were traversed twice")
        check(category("/Installer.dmg")=="installer","Installer was missed")
        check(category("/Archive.zip")=="installer-zip","ZIP was not deferred for inspection")
        check(category("/old.txt")=="old-download","Old Download was missed")
        check(findings.contains { $0.path.hasSuffix("/�.dmg") && !$0.complete },"Lossy filename was eligible")
        let largest=InventoryBrowse.largest(tree)
        check(largest.count==100 && largest.allSatisfy { !tree.isDir($0) },"Largest files is not bounded")
        check(InventoryBrowse.search(tree,query:"needle").count==1000,"Search cap/case matching changed")
        check(InventoryBrowse.search(tree,query:"/Downloads/old").count==1,"Path filtering failed")
        print("PASS: native insight parity, valid/invalid cache tags, artifact pruning, installer/ZIP distinction, old downloads, non-UTF8 safety, largest files and bounded search")
    }
}
