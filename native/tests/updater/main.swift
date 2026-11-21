// Updater regression probe. Compiles together with swift/AppServices.swift so the
// internal helpers (SHA-256, checksum parsing, signature inspection, bundle swap)
// can be driven directly.
//
// argv[1] is the .app used for the signature tests. tests/run.sh passes the real
// build when one exists, otherwise a minimal ad-hoc-signed fixture so the suite
// still covers signature validation on a clean CI runner.
import Foundation
import AppKit

var gPass = 0
var gFail = 0

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    let padded = name.padding(toLength: 42, withPad: " ", startingAt: 0)
    if ok {
        gPass += 1
        print("[PASS] \(padded) \(detail)")
    } else {
        gFail += 1
        print("[FAIL] \(padded) \(detail)")
    }
}

func runTool(_ path: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

func writeMarker(_ text: String, to directory: String) {
    try? text.write(toFile: (directory as NSString).appendingPathComponent("marker"),
                    atomically: true, encoding: .utf8)
}

func waitForInstall(_ status: Box<String>) {
    let deadline = Date(timeIntervalSinceNow: 30)
    while status.value == nil && deadline.timeIntervalSinceNow > 0 {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
}

final class Box<T> {
    var value: T?
}

let root = (NSTemporaryDirectory() as NSString)
    .appendingPathComponent("ardm-update-probe-\(UUID().uuidString)")
let fm = FileManager.default
try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)

// ---- 1. SHA-256 matches the system tool -------------------------------
let sample = (root as NSString).appendingPathComponent("sample.bin")
var payload = Data(count: 3 * 1024 * 1024 + 17)
payload.withUnsafeMutableBytes { buffer in
    if let base = buffer.baseAddress {
        arc4random_buf(base, buffer.count)
    }
}
try? payload.write(to: URL(fileURLWithPath: sample))

let shasum = Process()
shasum.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
shasum.arguments = ["-a", "256", sample]
let pipe = Pipe()
shasum.standardOutput = pipe
try? shasum.run()
shasum.waitUntilExit()
let shasumOutput = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
let expected = shasumOutput.components(separatedBy: " ").first ?? ""
let actual = ARDMAppServices.sha256OfFile(sample)
check("SHA-256 matches shasum", actual == expected, actual ?? "nil")

// ---- 2. Checksum file parsing ----------------------------------------
let digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
let parseCase = "# release checksums\n\(digest)  RDM-Native-1.8.0.dmg\n"
    + "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  other.zip"
check("checksum by filename",
      ARDMAppServices.checksumForAsset(parseCase, "RDM-Native-1.8.0.dmg") == digest,
      "sha256sum layout")
check("checksum single-entry file",
      ARDMAppServices.checksumForAsset("\(digest)\n", "x.dmg") == digest,
      "bare hash")
check("checksum starred + ./ prefix",
      ARDMAppServices.checksumForAsset("\(digest) *./ARDM.zip", "ARDM.zip") == digest,
      "starred")
check("checksum rejects malformed",
      ARDMAppServices.checksumForAsset("not-a-hash  ARDM.zip", "ARDM.zip") == nil,
      "garbage ignored")

// ---- 3. Signature inspection on the real build -----------------------
let appPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let haveApp = !appPath.isEmpty && fm.fileExists(atPath: appPath)
if !haveApp { print("  no .app supplied — signature tests skipped") }
let inspection = haveApp ? ARDMAppServices.inspectBundle(appPath) : (nil, false, nil)
let valid = haveApp && inspection.2 == nil
check("real bundle passes strict validation", valid,
      inspection.2 ?? "adHoc=\(inspection.1 ? 1 : 0) team=\(inspection.0 ?? "nil")")
check("real bundle is ad-hoc (no team id)",
      valid && inspection.1 && (inspection.0 ?? "").isEmpty,
      inspection.0 ?? "team=nil")

// ---- 4. Tampering is detected ----------------------------------------
let tampered = (root as NSString).appendingPathComponent("Tampered.app")
try? fm.copyItem(atPath: appPath, toPath: tampered)
var sealed = (tampered as NSString).appendingPathComponent("Contents/Resources/commands.js")
if !fm.fileExists(atPath: sealed) {
    sealed = (tampered as NSString).appendingPathComponent("Contents/Info.plist")
}
if let handle = FileHandle(forWritingAtPath: sealed) {
    handle.seekToEndOfFile()
    handle.write("\n// injected".data(using: .utf8)!)
    handle.closeFile()
}
let tamperInspection = ARDMAppServices.inspectBundle(tampered)
check("tampered bundle is rejected", tamperInspection.2 != nil,
      tamperInspection.2 ?? "accepted (BAD)")

// ---- 5. Atomic swap keeps the previous version -----------------------
let sandbox = (root as NSString).appendingPathComponent("Applications")
try? fm.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
let destination = (sandbox as NSString).appendingPathComponent("RDM Native.app")
let backup = destination + ".previous"
let old = (sandbox as NSString).appendingPathComponent(".new-old.app")
let newOne = (sandbox as NSString).appendingPathComponent(".new-new.app")
try? fm.createDirectory(atPath: old, withIntermediateDirectories: true)
try? fm.createDirectory(atPath: newOne, withIntermediateDirectories: true)
writeMarker("old", to: old)
writeMarker("new", to: newOne)
try? fm.moveItem(atPath: old, toPath: destination)
let swapError = ARDMAppServices.installBundle(newOne, destination: destination, backup: backup)
let installedMarker = try? String(contentsOfFile: (destination as NSString).appendingPathComponent("marker"),
                                  encoding: .utf8)
let backupMarker = try? String(contentsOfFile: (backup as NSString).appendingPathComponent("marker"),
                               encoding: .utf8)
check("swap installs new bundle", swapError == nil && installedMarker == "new", swapError ?? "")
check("swap keeps previous as .previous", backupMarker == "old", backupMarker ?? "missing")

// ---- 5b. Install target follows the running bundle --------------------
check("arm64 archive wins over x86 when both are published",
      ARDMAppServices.updateAssetScore("RDM-Native-1.8.0-arm64.zip")
        > ARDMAppServices.updateAssetScore("RDM-Native-1.8.0-x64.zip"))
check("source archives are never install candidates",
      ARDMAppServices.updateAssetScore("Source code.zip") < 0)
let chosen = ARDMAppServices.installDestination(runningBundle: "/tmp/OtherPlace/RDM Native.app")
check("update installs beside the running app",
      chosen.parent == "/tmp/OtherPlace" && chosen.name == "RDM Native.app",
      "\(chosen.parent)/\(chosen.name)")

// ---- 5c. A failed swap preserves the older rollback slot --------------
let failRoot = (root as NSString).appendingPathComponent("RollbackCase")
let failDest = (failRoot as NSString).appendingPathComponent("RDM Native.app")
let failBackup = failDest + ".previous"
try? fm.createDirectory(atPath: (failDest as NSString).appendingPathComponent("nested"),
                        withIntermediateDirectories: true)
try? fm.createDirectory(atPath: failBackup, withIntermediateDirectories: true)
writeMarker("current", to: failDest)
writeMarker("older", to: failBackup)
// The source lives inside the destination; moving the destination away makes
// the source disappear, so the final rename fails without any test-only hook.
let failError = ARDMAppServices.installBundle((failDest as NSString).appendingPathComponent("nested"),
                                              destination: failDest, backup: failBackup)
let failCurrent = try? String(contentsOfFile: (failDest as NSString).appendingPathComponent("marker"), encoding: .utf8)
let failOlder = try? String(contentsOfFile: (failBackup as NSString).appendingPathComponent("marker"), encoding: .utf8)
let staleNames = ((try? fm.contentsOfDirectory(atPath: failRoot)) ?? []).filter { $0.contains(".stale-") }
check("failed swap restores both bundles",
      failError != nil && failCurrent == "current" && failOlder == "older",
      "\(failCurrent ?? "-")/\(failOlder ?? "-")")
check("failed swap leaves no stale rollback slot", staleNames.isEmpty, staleNames.joined(separator: ","))

// ---- 5d. A successful swap retires the older rollback slot ------------
let successRoot = (root as NSString).appendingPathComponent("SuccessCase")
let successDest = (successRoot as NSString).appendingPathComponent("RDM Native.app")
let successBackup = successDest + ".previous"
let successNew = (successRoot as NSString).appendingPathComponent(".new.app")
for dir in [successDest, successBackup, successNew] { try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
writeMarker("current", to: successDest)
writeMarker("older", to: successBackup)
writeMarker("new", to: successNew)
let successError = ARDMAppServices.installBundle(successNew, destination: successDest, backup: successBackup)
let successNow = try? String(contentsOfFile: (successDest as NSString).appendingPathComponent("marker"), encoding: .utf8)
let successPrev = try? String(contentsOfFile: (successBackup as NSString).appendingPathComponent("marker"), encoding: .utf8)
let successStale = ((try? fm.contentsOfDirectory(atPath: successRoot)) ?? []).filter { $0.contains(".stale-") }
check("successful swap retires the old rollback slot",
      successError == nil && successNow == "new" && successPrev == "current" && successStale.isEmpty,
      "\(successNow ?? "-")/\(successPrev ?? "-")")

// ---- 5e. File bookmarks are read back, not just written ---------------
let scopedFile = (root as NSString).appendingPathComponent("scoped.txt")
try? "x".write(toFile: scopedFile, atomically: true, encoding: .utf8)
if let scoped = ARDMAppServices.bookmark(for: URL(fileURLWithPath: scopedFile)) {
    ARDMAppServices.saveScopedBookmark(scoped, forPath: scopedFile)
    check("scoped bookmark is read back", ARDMAppServices.scopedBookmark(forPath: scopedFile) == scoped)
    check("scoped bookmark resolves to its file",
          ARDMAppServices.resolvedScopedURL(forPath: scopedFile)?.standardizedFileURL.path
            == URL(fileURLWithPath: scopedFile).standardizedFileURL.path)
    check("file panel starts in the bookmarked parent",
          ARDMAppServices.lastFileDirectory()?.standardizedFileURL.path == root)
} else {
    check("scoped bookmark is read back", false, "bookmark(for:) returned nil")
}

// ---- 6. Refuses to touch a read-only location ------------------------
let locked = (root as NSString).appendingPathComponent("Locked")
try? fm.createDirectory(atPath: locked, withIntermediateDirectories: true)
writeMarker("keep", to: locked)
try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked)
let lockedDestination = (locked as NSString).appendingPathComponent("ARDM.app")
let reject = ARDMAppServices.installBundle(newOne, destination: lockedDestination,
                                           backup: lockedDestination + ".previous")
check("read-only destination is refused", reject != nil, reject ?? "proceeded (BAD)")
let remaining = (try? fm.contentsOfDirectory(atPath: locked)) ?? []
check("refusal leaves the location untouched", remaining == ["marker"], "no files added")
try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked)

// ---- 7/8. installUpdate: rejects foreign bundles and bad digests -----
let foreign = (root as NSString).appendingPathComponent("Foreign.app")
let foreignContents = (foreign as NSString).appendingPathComponent("Contents")
try? fm.createDirectory(atPath: foreignContents, withIntermediateDirectories: true)
let foreignInfo: [String: Any] = ["CFBundleIdentifier": "com.example.notardm",
                                  "CFBundleShortVersionString": "9.9.9",
                                  "CFBundleExecutable": "x"]
(foreignInfo as NSDictionary).write(toFile: (foreignContents as NSString).appendingPathComponent("Info.plist"),
                                    atomically: true)
let zip = (root as NSString).appendingPathComponent("foreign.zip")
runTool("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", foreign, zip])

let installedBefore = fm.fileExists(atPath: "/Applications/RDM Native.app")

let installStatus = Box<String>()
ARDMAppServices.updateSHA256 = ARDMAppServices.sha256OfFile(zip)   // digest is fine, bundle identity is not
ARDMAppServices.installUpdate(URL(fileURLWithPath: zip)) { status in
    installStatus.value = status
}
waitForInstall(installStatus)
check("foreign bundle is refused", installStatus.value?.contains("com.example.notardm") == true,
      installStatus.value ?? "nil")

installStatus.value = nil
ARDMAppServices.updateSHA256 = "0000000000000000000000000000000000000000000000000000000000000000"
ARDMAppServices.installUpdate(URL(fileURLWithPath: zip)) { status in
    installStatus.value = status
}
waitForInstall(installStatus)
check("digest mismatch aborts before install",
      installStatus.value?.contains("no longer matches") == true,
      installStatus.value ?? "nil")

let installedAfter = fm.fileExists(atPath: "/Applications/RDM Native.app")
check("refusals never wrote to /Applications", installedBefore == installedAfter, "untouched")

try? fm.removeItem(atPath: root)
print("\n=== result: \(gPass) passed, \(gFail) failed ===")
exit(gFail == 0 ? 0 : 1)
