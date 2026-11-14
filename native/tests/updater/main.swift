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
let parseCase = "# release checksums\n\(digest)  ARDM-Native-1.8.0.dmg\n"
    + "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  other.zip"
check("checksum by filename",
      ARDMAppServices.checksumForAsset(parseCase, "ARDM-Native-1.8.0.dmg") == digest,
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
let destination = (sandbox as NSString).appendingPathComponent("ARDM Native.app")
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

let installedBefore = fm.fileExists(atPath: "/Applications/ARDM Native.app")

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

let installedAfter = fm.fileExists(atPath: "/Applications/ARDM Native.app")
check("refusals never wrote to /Applications", installedBefore == installedAfter, "untouched")

try? fm.removeItem(atPath: root)
print("\n=== result: \(gPass) passed, \(gFail) failed ===")
exit(gFail == 0 ? 0 : 1)
