import Foundation

var failures = 0
func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("playdesk-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let store = ProfileStore(url: root.appendingPathComponent("nested/profiles.json"))
check(try store.load().isEmpty, "missing store loads empty")
let profile = GameProfile(package: "example.synthetic", name: "Synthetic", mappings: [])
try store.save([profile])
check(try store.load() == [profile], "new store roundtrip")
try store.save([])
check(try store.load().isEmpty, "valid store can be replaced")
let legacy = Data("[{\"package\":\"example.legacy\"}]".utf8)
try legacy.write(to: store.url)
check(try store.load() == [GameProfile(package: "example.legacy", mappings: [])], "legacy optional fields decode")
for (label, bytes) in [("truncated JSON", Data("[{\"package\":".utf8)), ("unknown schema", Data("{\"version\":999}".utf8))] {
    try bytes.write(to: store.url)
    var rejected = false
    do { try store.save([profile]) } catch { rejected = true }
    check(rejected, "reject save over \(label)")
    check(try Data(contentsOf: store.url) == bytes, "preserve original \(label) bytes")
}
// Forward-compatible reads must not silently discard newer fields on save.
let futureFixtures = [
    "profile": #"[{"package":"example.future","futureSetting":true}]"#,
    "mapping": #"[{"package":"example.future","mappings":[{"id":"00000000-0000-0000-0000-000000000001","key":"a","x":1,"y":2,"futureSetting":true}]}]"#,
    "macro": #"[{"package":"example.future","macros":[{"id":"00000000-0000-0000-0000-000000000001","name":"test","steps":[],"repeatCount":1,"intervalMs":100,"referenceWidth":100,"referenceHeight":100,"futureSetting":true}]}]"#,
    "step": #"[{"package":"example.future","macros":[{"id":"00000000-0000-0000-0000-000000000001","name":"test","steps":[{"id":"00000000-0000-0000-0000-000000000002","x":1,"y":2,"futureSetting":true}],"repeatCount":1,"intervalMs":100,"referenceWidth":100,"referenceHeight":100}]}]"#
]
for label in futureFixtures.keys.sorted() {
    let bytes = Data(futureFixtures[label]!.utf8)
    try bytes.write(to: store.url)
    check(try store.load().count == 1, "future \(label) remains readable")
    var rejected = false
    do { try store.save([profile]) } catch { rejected = true }
    check(rejected, "reject lossy save of future \(label)")
    check(try Data(contentsOf: store.url) == bytes, "preserve future \(label) bytes")
}
try legacy.write(to: store.url)
try store.save([profile])
check(try store.load() == [profile], "legacy remains writable")

// Additional storage contracts: nested valid data and malformed nested input.
let rich = GameProfile(package: "example.rich", name: "합성 프로필", mappings: [KeyMapping(key: "a", x: 10, y: 20)], macros: [ClickMacro(name: "synthetic", steps: [MacroStep(x: 30, y: 40)], repeatCount: 2, repeatForever: true, continueInBackground: true, intervalMs: 100, referenceWidth: 1080, referenceHeight: 1920)])
try store.save([rich])
check(try store.load() == [rich], "nested mapping and macro roundtrip preserves values and IDs")
let malformedFixtures = [
    "wrong mapping container": #"[{"package":"example.bad","mappings":42}]"#,
    "bad mapping UUID": #"[{"package":"example.bad","mappings":[{"id":"bad-id","key":"a","x":1,"y":2}]}]"#,
    "missing macro fields": #"[{"package":"example.bad","macros":[{"name":"incomplete"}]}]"#,
    "null package": #"[{"package":null}]"#
]
for label in malformedFixtures.keys.sorted() {
    let bytes = Data(malformedFixtures[label]!.utf8)
    try bytes.write(to: store.url)
    var loadRejected = false
    do { _ = try store.load() } catch { loadRejected = true }
    check(loadRejected, "reject malformed read: \(label)")
    var saveRejected = false
    do { try store.save([rich]) } catch { saveRejected = true }
    check(saveRejected, "reject overwrite: \(label)")
    check(try Data(contentsOf: store.url) == bytes, "preserve malformed bytes: \(label)")
}
let directoryURL = root.appendingPathComponent("directory-profiles.json")
try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
let sentinel = directoryURL.appendingPathComponent("keep.txt")
let sentinelBytes = Data("synthetic sentinel".utf8)
try sentinelBytes.write(to: sentinel)
var directoryRejected = false
do { try ProfileStore(url: directoryURL).save([rich]) } catch { directoryRejected = true }
check(directoryRejected, "reject profile target that is a directory")
check(try Data(contentsOf: sentinel) == sentinelBytes, "preserve directory child on failed save")

exit(failures == 0 ? 0 : 1)
