// Updater regression probe. Includes Transport.m so the file-scope helpers
// (SHA-256, checksum parsing, signature inspection, bundle swap) can be driven
// directly; link with Redis.o / Services.o only.
//
// argv[1] is the .app used for the signature tests. tests/run.sh passes the real
// build when one exists, otherwise a minimal ad-hoc-signed fixture so the suite
// still covers signature validation on a clean CI runner.
#import "Transport.m"
#import <Foundation/Foundation.h>

static int gPass = 0, gFail = 0;

static void check(NSString *name, BOOL ok, NSString *detail) {
    if (ok) { gPass++; printf("[PASS] %-42s %s\n", name.UTF8String, (detail ?: @"").UTF8String); }
    else { gFail++; printf("[FAIL] %-42s %s\n", name.UTF8String, (detail ?: @"").UTF8String); }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"ardm-update-probe-%@", [[NSUUID UUID] UUIDString]]];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];

        // ---- 1. SHA-256 matches the system tool -------------------------------
        NSString *sample = [root stringByAppendingPathComponent:@"sample.bin"];
        NSMutableData *payload = [NSMutableData dataWithLength:3 * 1024 * 1024 + 17];
        arc4random_buf(payload.mutableBytes, payload.length);
        [payload writeToFile:sample atomically:YES];
        NSTask *shasum = [[NSTask alloc] init];
        shasum.executableURL = [NSURL fileURLWithPath:@"/usr/bin/shasum"];
        shasum.arguments = @[@"-a", @"256", sample];
        NSPipe *pipe = [NSPipe pipe];
        shasum.standardOutput = pipe;
        [shasum launch];
        [shasum waitUntilExit];
        NSString *expected = [[[NSString alloc] initWithData:[pipe.fileHandleForReading readDataToEndOfFile]
                                                   encoding:NSUTF8StringEncoding] componentsSeparatedByString:@" "].firstObject;
        NSString *actual = ARDMSHA256OfFile(sample);
        check(@"SHA-256 matches shasum", [actual isEqualToString:expected], actual ?: @"nil");

        // ---- 2. Checksum file parsing ----------------------------------------
        NSString *parseCase = [NSString stringWithFormat:
            @"# release checksums\n%@  ARDM-Native-1.8.0.dmg\nffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  other.zip",
            @"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"];
        check(@"checksum by filename",
              [ARDMChecksumForAsset(parseCase, @"ARDM-Native-1.8.0.dmg")
                isEqualToString:@"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"],
              @"sha256sum layout");
        check(@"checksum single-entry file",
              [ARDMChecksumForAsset(@"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n", @"x.dmg")
                isEqualToString:@"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"],
              @"bare hash");
        check(@"checksum starred + ./ prefix",
              [ARDMChecksumForAsset([NSString stringWithFormat:
                    @"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef *./ARDM.zip"], @"ARDM.zip")
                isEqualToString:@"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"],
              @"starred");
        check(@"checksum rejects malformed",
              ARDMChecksumForAsset(@"not-a-hash  ARDM.zip", @"ARDM.zip") == nil, @"garbage ignored");

        // ---- 3. Signature inspection on the real build -----------------------
        NSString *appPath = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : nil;
        BOOL haveApp = appPath.length > 0 && [fm fileExistsAtPath:appPath];
        if (!haveApp) { printf("  no .app supplied — signature tests skipped\n"); }
        NSString *team = nil; BOOL adHoc = NO; NSString *reason = nil;
        BOOL valid = haveApp && ARDMInspectBundle(appPath, &team, &adHoc, &reason);
        check(@"real bundle passes strict validation", valid, reason ?: [NSString stringWithFormat:@"adHoc=%d team=%@", adHoc, team ?: @"nil"]);
        check(@"real bundle is ad-hoc (no team id)", valid && adHoc && team.length == 0, team ?: @"team=nil");

        // ---- 4. Tampering is detected ----------------------------------------
        NSString *tampered = [root stringByAppendingPathComponent:@"Tampered.app"];
        [fm copyItemAtPath:appPath toPath:tampered error:nil];
        NSString *sealed = [tampered stringByAppendingPathComponent:@"Contents/Resources/commands.js"];
        if (![fm fileExistsAtPath:sealed]) {
            sealed = [tampered stringByAppendingPathComponent:@"Contents/Info.plist"];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:sealed];
        [handle seekToEndOfFile];
        [handle writeData:[@"\n// injected" dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
        NSString *tamperReason = nil;
        BOOL tamperOK = ARDMInspectBundle(tampered, NULL, NULL, &tamperReason);
        check(@"tampered bundle is rejected", !tamperOK, tamperReason ?: @"accepted (BAD)");

        // ---- 5. Atomic swap keeps the previous version -----------------------
        NSString *sandbox = [root stringByAppendingPathComponent:@"Applications"];
        [fm createDirectoryAtPath:sandbox withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *dest = [sandbox stringByAppendingPathComponent:@"ARDM Native.app"];
        NSString *backup = [dest stringByAppendingString:@".previous"];
        NSString *old = [sandbox stringByAppendingPathComponent:@".new-old.app"];
        NSString *newOne = [sandbox stringByAppendingPathComponent:@".new-new.app"];
        [fm createDirectoryAtPath:old withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:newOne withIntermediateDirectories:YES attributes:nil error:nil];
        [@"old" writeToFile:[old stringByAppendingPathComponent:@"marker"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"new" writeToFile:[newOne stringByAppendingPathComponent:@"marker"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [fm moveItemAtPath:old toPath:dest error:nil];
        NSString *swapError = nil;
        BOOL swapped = ARDMInstallBundle(newOne, dest, backup, &swapError);
        NSString *installedMarker = [NSString stringWithContentsOfFile:
            [dest stringByAppendingPathComponent:@"marker"] encoding:NSUTF8StringEncoding error:nil];
        NSString *backupMarker = [NSString stringWithContentsOfFile:
            [backup stringByAppendingPathComponent:@"marker"] encoding:NSUTF8StringEncoding error:nil];
        check(@"swap installs new bundle", swapped && [installedMarker isEqualToString:@"new"], swapError ?: @"");
        check(@"swap keeps previous as .previous", [backupMarker isEqualToString:@"old"], backupMarker ?: @"missing");

        // ---- 6. Refuses to touch a read-only location ------------------------
        NSString *locked = [root stringByAppendingPathComponent:@"Locked"];
        [fm createDirectoryAtPath:locked withIntermediateDirectories:YES attributes:nil error:nil];
        [@"keep" writeToFile:[locked stringByAppendingPathComponent:@"marker"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [fm setAttributes:@{NSFilePosixPermissions: @(0500)} ofItemAtPath:locked error:nil];
        NSString *lockedDest = [locked stringByAppendingPathComponent:@"ARDM.app"];
        NSString *reject = nil;
        BOOL refused = !ARDMInstallBundle(newOne, lockedDest, [lockedDest stringByAppendingString:@".previous"], &reject);
        check(@"read-only destination is refused", refused, reject ?: @"proceeded (BAD)");
        check(@"refusal leaves the location untouched",
              [[fm contentsOfDirectoryAtPath:locked error:nil] isEqualToArray:@[@"marker"]], @"no files added");
        [fm setAttributes:@{NSFilePosixPermissions: @(0700)} ofItemAtPath:locked error:nil];

        // ---- 7/8. installUpdateAtURL: rejects foreign bundles and bad digests --
        NSString *foreign = [root stringByAppendingPathComponent:@"Foreign.app"];
        NSString *foreignContents = [foreign stringByAppendingPathComponent:@"Contents"];
        [fm createDirectoryAtPath:foreignContents withIntermediateDirectories:YES attributes:nil error:nil];
        NSDictionary *foreignInfo = @{@"CFBundleIdentifier": @"com.example.notardm",
                                      @"CFBundleShortVersionString": @"9.9.9",
                                      @"CFBundleExecutable": @"x"};
        [foreignInfo writeToFile:[foreignContents stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
        NSString *zip = [root stringByAppendingPathComponent:@"foreign.zip"];
        NSTask *ditto = [[NSTask alloc] init];
        ditto.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ditto"];
        ditto.arguments = @[@"-c", @"-k", @"--sequesterRsrc", @"--keepParent", foreign, zip];
        [ditto launch]; [ditto waitUntilExit];

        BOOL installedBefore = [fm fileExistsAtPath:@"/Applications/ARDM Native.app"];

        __block NSString *installStatus = nil;
        void (^waitForInstall)(void) = ^{
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
            while (!installStatus && [deadline timeIntervalSinceNow] > 0) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
        };

        sARDMUpdateSHA256 = ARDMSHA256OfFile(zip);   // digest is fine, bundle identity is not
        [ARDMAppServices installUpdateAtURL:[NSURL fileURLWithPath:zip] completion:^(NSString *s) {
            installStatus = s;
        }];
        waitForInstall();
        check(@"foreign bundle is refused", [installStatus containsString:@"com.example.notardm"], installStatus ?: @"nil");

        installStatus = nil;
        sARDMUpdateSHA256 = @"0000000000000000000000000000000000000000000000000000000000000000";
        [ARDMAppServices installUpdateAtURL:[NSURL fileURLWithPath:zip] completion:^(NSString *s) {
            installStatus = s;
        }];
        waitForInstall();
        check(@"digest mismatch aborts before install", [installStatus containsString:@"no longer matches"], installStatus ?: @"nil");

        BOOL installedAfter = [fm fileExistsAtPath:@"/Applications/ARDM Native.app"];
        check(@"refusals never wrote to /Applications",
              installedBefore == installedAfter, @"untouched");

        [fm removeItemAtPath:root error:nil];
        printf("\n=== result: %d passed, %d failed ===\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
