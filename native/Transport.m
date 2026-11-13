#import "Transport.h"
#import <AppKit/AppKit.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

static NSString *ARDMResourcePath(NSString *name) {
    return [[[NSBundle mainBundle] resourcePath] ?: @"" stringByAppendingPathComponent:name];
}

// Fall back to the checkout's src/commands.js when running unbundled, without
// relying on a machine-specific absolute path.
static NSString *ARDMSourceCommandPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *starts = [NSMutableArray array];
    NSString *env = [NSProcessInfo processInfo].environment[@"ARDM_PROJECT_ROOT"];
    if (env.length) [starts addObject:env];
    NSString *bundle = [[NSBundle mainBundle] bundlePath];
    if (bundle.length) [starts addObject:bundle];
    [starts addObject:[fm currentDirectoryPath]];
    for (NSString *start in starts) {
        NSString *dir = start;
        for (NSInteger i = 0; i < 6 && dir.length > 1; i++) {
            NSString *candidate = [dir stringByAppendingPathComponent:@"src/commands.js"];
            if ([fm fileExistsAtPath:candidate]) return candidate;
            NSString *parent = [dir stringByDeletingLastPathComponent];
            if ([parent isEqualToString:dir]) break;
            dir = parent;
        }
    }
    return nil;
}

@implementation ARDMAppServices

#pragma mark - Fonts (font-list / font-manager.js)

+ (NSArray<NSString *> *)availableFonts {
    NSArray *families = [[NSFontManager sharedFontManager] availableFontFamilies] ?: @[];
    return [families sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

#pragma mark - Command reference (commands.js)

+ (NSDictionary<NSString *, id> *)commandReference {
    NSString *path = ARDMResourcePath(@"commands.js");
    NSString *source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!source) {
        NSString *fallback = ARDMSourceCommandPath();
        if (fallback.length) source = [NSString stringWithContentsOfFile:fallback encoding:NSUTF8StringEncoding error:nil];
    }
    if (!source) return @{};
    JSContext *context = [[JSContext alloc] init];
    [context evaluateScript:@"var module = { exports: {} };"];
    [context evaluateScript:source];
    JSValue *value = [context evaluateScript:@"JSON.stringify(module.exports.allCMD || {})"];
    NSString *json = [value toString] ?: @"{}";
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
}

#pragma mark - Custom formatters (CustomFormatter.vue)

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)customFormatters {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"ARDMCustomFormatters"];
    if (saved.count) return saved;
    return @[@{@"name": @"Default", @"script": @"return new TextDecoder().decode(bytes);"}];
}

+ (void)saveCustomFormatters:(NSArray<NSDictionary<NSString *, NSString *> *> *)items {
    [[NSUserDefaults standardUserDefaults] setObject:items forKey:@"ARDMCustomFormatters"];
}

#pragma mark - Connection import / export (Setting.vue)

+ (NSString *)exportConnectionsJSON {
    NSMutableArray *raw = [NSMutableArray array];
    for (ARDMConnectionConfig *config in [ARDMConnectionConfig loadAll]) [raw addObject:[config toDictionary]];
    NSData *data = [NSJSONSerialization dataWithJSONObject:raw
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    return [[NSString alloc] initWithData:data ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"[]";
}

+ (BOOL)importConnectionsJSON:(NSData *)data error:(NSError **)error {
    NSArray *incoming = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![incoming isKindOfClass:NSArray.class]) {
        if (error) *error = [NSError errorWithDomain:@"me.qii404.ardm.native" code:20
            userInfo:@{NSLocalizedDescriptionKey: @"The file does not contain a connection array"}];
        return NO;
    }
    NSMutableArray *merged = [[ARDMConnectionConfig loadAll] mutableCopy];
    for (id item in incoming) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        ARDMConnectionConfig *config = [ARDMConnectionConfig fromDictionary:item];
        config.identifier = [[NSUUID UUID] UUIDString];
        [merged addObject:config];
    }
    [ARDMConnectionConfig saveAll:merged];
    return YES;
}

#pragma mark - Auto update (UpdateCheck.vue / electron-updater)

// This is the native rewrite's own repository, not the upstream Electron project.
static NSString *const kARDMUpdateAPI =
    @"https://api.github.com/repos/XINKEJU/AnotherRedisDesktopManager-Native/releases/latest";
static NSString *const kARDMBundleIdentifier = @"me.qii404.ardm.native";

static NSURL *sARDMUpdateAssetURL;
static NSString *sARDMUpdateAssetName;
static NSString *sARDMUpdateVersion;
static NSString *sARDMUpdateSHA256;
static NSString *sARDMUpdateChecksumSource;

#pragma mark Update primitives

static NSString *ARDMHexString(const unsigned char *bytes, size_t count) {
    NSMutableString *out = [NSMutableString stringWithCapacity:count * 2];
    for (size_t i = 0; i < count; i++) [out appendFormat:@"%02x", bytes[i]];
    return out;
}

/** Streaming SHA-256 of a file; nil when the file cannot be read. */
static NSString *ARDMSHA256OfFile(NSString *path) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    while (YES) {
        @autoreleasepool {
            NSData *chunk = [handle readDataOfLength:1 << 20];
            if (chunk.length == 0) break;
            CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [handle closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    return ARDMHexString(digest, sizeof(digest));
}

static BOOL ARDMIsHexDigest(NSString *text) {
    if (text.length != 64) return NO;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    return [hex isSupersetOfSet:[NSCharacterSet characterSetWithCharactersInString:[text lowercaseString]]];
}

/**
 Pull the digest for `assetName` out of a checksum file. Accepts the common
 layouts: `sha256sum` output ("<hash>  <name>" / "<hash> *<name>"), a
 single-entry "<asset>.sha256" (bare hash, or one line), and one hash per line.
*/
static NSString *ARDMChecksumForAsset(NSString *text, NSString *assetName) {
    if (text.length == 0) return nil;
    NSString *wanted = assetName.lowercaseString;
    NSString *wantedLeaf = wanted.lastPathComponent;
    for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;
        if ([line hasPrefix:@"#"]) continue;
        NSArray<NSString *> *parts = [line componentsSeparatedByCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray<NSString *> *tokens = [NSMutableArray array];
        for (NSString *token in parts) if (token.length) [tokens addObject:token];
        if (tokens.count == 0) continue;
        NSString *digest = tokens[0].lowercaseString;
        if (!ARDMIsHexDigest(digest)) continue;
        if (tokens.count == 1) return digest;               // bare hash: single-entry file
        NSString *name = tokens.lastObject.lowercaseString;
        if ([name hasPrefix:@"*"]) name = [name substringFromIndex:1];
        while ([name hasPrefix:@"./"]) name = [name substringFromIndex:2];
        if ([name isEqualToString:wanted] || [name isEqualToString:wantedLeaf] ||
            [name.lastPathComponent isEqualToString:wantedLeaf]) {
            return digest;
        }
    }
    // A "<asset>.sha256" attachment often has a header line; a lone digest is
    // still unambiguous, so accept it when nothing matched by name.
    for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (ARDMIsHexDigest(line.lowercaseString)) return line.lowercaseString;
    }
    return nil;
}

/**
 Verify the bundle's code signature (seal integrity, all architectures) and
 report its team identifier. Ad-hoc signatures carry no provenance, which is
 why an ad-hoc build additionally requires a published SHA-256.
*/
static BOOL ARDMInspectBundle(NSString *appPath, NSString **teamID, BOOL *adHoc, NSString **reason) {
    if (teamID) *teamID = nil;
    if (adHoc) *adHoc = NO;
    if (reason) *reason = nil;
    SecStaticCodeRef code = NULL;
    OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:appPath],
                                                 kSecCSDefaultFlags, &code);
    if (status != errSecSuccess || code == NULL) {
        if (reason) *reason = [NSString stringWithFormat:@"无法读取代码签名（OSStatus %d）", (int)status];
        if (code) CFRelease(code);
        return NO;
    }
    status = SecStaticCodeCheckValidity(code, (SecCSFlags)(kSecCSCheckAllArchitectures | kSecCSStrictValidate), NULL);
    if (status != errSecSuccess) {
        if (reason) *reason = [NSString stringWithFormat:
            @"代码签名校验失败（OSStatus %d），安装包可能被篡改或未正确签名", (int)status];
        CFRelease(code);
        return NO;
    }
    CFDictionaryRef info = NULL;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info) == errSecSuccess && info) {
        CFTypeRef team = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
        if (teamID && team != NULL && CFGetTypeID(team) == CFStringGetTypeID()) {
            *teamID = [(__bridge NSString *)team copy];
        }
        CFTypeRef flagsValue = CFDictionaryGetValue(info, kSecCodeInfoFlags);
        if (adHoc && flagsValue && CFGetTypeID(flagsValue) == CFNumberGetTypeID()) {
            int flags = 0;
            CFNumberGetValue((CFNumberRef)flagsValue, kCFNumberIntType, &flags);
            *adHoc = (flags & kSecCodeSignatureAdhoc) != 0;
        }
        CFRelease(info);
    }
    CFRelease(code);
    return YES;
}

static NSString *ARDMBundleIdentifierAtPath(NSString *appPath) {
    NSString *plist = [appPath stringByAppendingPathComponent:@"Contents/Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
    id identifier = info[@"CFBundleIdentifier"];
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

static NSString *ARDMBundleVersionAtPath(NSString *appPath) {
    NSString *plist = [appPath stringByAppendingPathComponent:@"Contents/Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
    id version = info[@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] ? version : nil;
}

/** Team identifier of the running app; nil for ad-hoc / unsigned builds. */
static NSString *ARDMRunningTeamIdentifier(void) {
    NSString *team = nil;
    BOOL adHoc = NO;
    NSString *reason = nil;
    if (!ARDMInspectBundle([[NSBundle mainBundle] bundlePath], &team, &adHoc, &reason)) return nil;
    return adHoc ? nil : team;
}

/** Small text asset, fetched synchronously (the caller is already off the main thread). */
static NSString *ARDMFetchText(NSString *urlString, NSTimeInterval timeout) {
    NSURL *url = urlString.length ? [NSURL URLWithString:urlString] : nil;
    if (!url) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"ARDM-Native" forHTTPHeaderField:@"User-Agent"];
    [request setTimeoutInterval:timeout];
    __block NSData *payload = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger code = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (!error && code == 200 && data.length > 0 && data.length <= 65536) payload = data;
            dispatch_semaphore_signal(done);
        }];
    [task resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        [task cancel];
        return nil;
    }
    return payload ? [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] : nil;
}

/**
 Move the verified bundle into place without ever destroying the only copy:
 prepare → rename old to the rollback slot → rename new in → restore on failure.
 All three paths live in the same directory, so each rename is atomic.
*/
static BOOL ARDMInstallBundle(NSString *newApp, NSString *destination, NSString *backup, NSString **errorText) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *parent = [destination stringByDeletingLastPathComponent];
    if (![fm isWritableFileAtPath:parent]) {
        if (errorText) *errorText = [NSString stringWithFormat:
            @"没有写入 %@ 的权限，请把应用移到可写位置或手动安装。", parent];
        return NO;
    }
    BOOL hadPrevious = [fm fileExistsAtPath:destination];
    [fm removeItemAtPath:backup error:nil];   // single rollback slot
    if (hadPrevious) {
        NSError *moveOld = nil;
        if (![fm moveItemAtPath:destination toPath:backup error:&moveOld]) {
            if (errorText) *errorText = [NSString stringWithFormat:
                @"无法备份当前版本，已中止（未改动任何文件）：%@", moveOld.localizedDescription];
            return NO;
        }
    }
    NSError *moveNew = nil;
    if (![fm moveItemAtPath:newApp toPath:destination error:&moveNew]) {
        NSString *restore = @"";
        if (hadPrevious && [fm moveItemAtPath:backup toPath:destination error:nil]) restore = @"，旧版本已恢复";
        if (errorText) *errorText = [NSString stringWithFormat:
            @"替换失败（%@）%@。", moveNew.localizedDescription, restore];
        return NO;
    }
    return YES;
}

#pragma mark Update API

+ (void)checkForUpdateWithCompletion:(void (^)(NSString *, NSURL * _Nullable))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kARDMUpdateAPI]];
    [request setValue:@"ARDM-Native" forHTTPHeaderField:@"User-Agent"];
    [request setTimeoutInterval:10];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            NSString *status;
            NSURL *page = nil;
            sARDMUpdateAssetURL = nil;
            sARDMUpdateAssetName = nil;
            sARDMUpdateVersion = nil;
            sARDMUpdateSHA256 = nil;
            sARDMUpdateChecksumSource = nil;
            if (networkError) {
                status = [NSString stringWithFormat:@"Update check unavailable: %@", networkError.localizedDescription];
            } else {
                NSDictionary *release = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:nil];
                NSString *tag = [release isKindOfClass:NSDictionary.class] ? release[@"tag_name"] : nil;
                NSString *current = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0";
                if (!tag) {
                    status = @"No release published for this native build yet.";
                } else if ([tag isEqualToString:current] || [tag isEqualToString:[@"v" stringByAppendingString:current]]) {
                    status = [NSString stringWithFormat:@"You are up to date (%@)", current];
                } else {
                    NSArray *assets = [release[@"assets"] isKindOfClass:NSArray.class] ? release[@"assets"] : @[];
                    NSString *checksumURL = nil;
                    NSArray *checksumNames = @[@"sha256sums", @"sha256sums.txt", @"checksums.txt",
                                               @"sha256.txt", @"sha256sum.txt"];
                    for (NSDictionary *asset in assets) {
                        if (![asset isKindOfClass:NSDictionary.class]) continue;
                        NSString *name = asset[@"name"];
                        if (![name isKindOfClass:NSString.class]) continue;
                        NSString *lower = name.lowercaseString;
                        if ([lower hasSuffix:@".dmg"] || [lower hasSuffix:@".zip"]) {
                            if (!sARDMUpdateAssetURL) {
                                sARDMUpdateAssetURL = [NSURL URLWithString:asset[@"browser_download_url"]];
                                sARDMUpdateAssetName = name;
                            }
                        } else if ([lower hasSuffix:@".sha256"] || [checksumNames containsObject:lower]) {
                            if (!checksumURL) checksumURL = asset[@"browser_download_url"];
                        }
                    }
                    sARDMUpdateVersion = tag;
                    if (sARDMUpdateAssetURL && checksumURL.length) {
                        NSString *text = ARDMFetchText(checksumURL, 8);
                        sARDMUpdateSHA256 = ARDMChecksumForAsset(text, sARDMUpdateAssetName);
                        if (sARDMUpdateSHA256) {
                            sARDMUpdateChecksumSource = [NSURL URLWithString:checksumURL].lastPathComponent;
                        }
                    }
                    NSString *detail = sARDMUpdateAssetName ?: @"no macOS asset";
                    NSString *trust = sARDMUpdateSHA256
                        ? [NSString stringWithFormat:@"SHA-256 ✓ (from %@)", sARDMUpdateChecksumSource]
                        : @"no SHA-256 published";
                    status = [NSString stringWithFormat:@"New release %@ (current %@) — %@ · %@",
                              tag, current, detail, trust];
                    NSString *html = release[@"html_url"];
                    if (html) page = [NSURL URLWithString:html];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(status, page); });
        }];
    [task resume];
}

+ (NSString *)pendingUpdateVersion { return sARDMUpdateVersion; }
+ (NSString *)pendingUpdateAssetName { return sARDMUpdateAssetName; }
+ (BOOL)pendingUpdateHasChecksum { return sARDMUpdateSHA256.length > 0; }

+ (void)downloadUpdateWithCompletion:(void (^)(NSString *, NSURL * _Nullable))completion {
    NSURL *asset = sARDMUpdateAssetURL;
    if (!asset) {
        completion(@"Run 'Check for Updates' first; no downloadable macOS asset was found.", nil);
        return;
    }
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:asset
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            NSString *status; NSURL *local = nil;
            NSInteger httpCode = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (!location || error || (httpCode != 0 && httpCode != 200)) {
                status = [NSString stringWithFormat:@"Download failed: %@",
                          error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)httpCode]];
            } else {
                NSFileManager *fm = [NSFileManager defaultManager];
                NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
                [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *dest = [dir stringByAppendingPathComponent:asset.lastPathComponent ?: @"ARDM-Native-Update.dmg"];
                [fm removeItemAtPath:dest error:nil];
                NSError *moveError = nil;
                if (![fm moveItemAtPath:location.path toPath:dest error:&moveError]) {
                    status = [NSString stringWithFormat:@"Could not save update: %@", moveError.localizedDescription];
                } else {
                    NSString *actual = ARDMSHA256OfFile(dest);
                    NSString *team = ARDMRunningTeamIdentifier();
                    if (sARDMUpdateSHA256.length) {
                        if ([actual isEqualToString:sARDMUpdateSHA256]) {
                            status = [NSString stringWithFormat:@"Downloaded and verified (SHA-256 ✓) → %@", dest];
                            local = [NSURL fileURLWithPath:dest];
                        } else {
                            [fm removeItemAtPath:dest error:nil];
                            status = @"Verification failed: the downloaded file's SHA-256 does not match the "
                                     "value published by the release. The file was deleted.";
                        }
                    } else if (team.length) {
                        // A Developer ID signature provides provenance, so a missing
                        // checksum is tolerable here; it is still verified at install.
                        status = [NSString stringWithFormat:
                            @"Downloaded → %@ (no checksum published; the Developer ID signature will be verified)", dest];
                        local = [NSURL fileURLWithPath:dest];
                    } else {
                        [fm removeItemAtPath:dest error:nil];
                        status = @"Refused: this ad-hoc build has no code-signing identity, so a published "
                                 "SHA-256 is required to establish provenance. Ask the release owner to attach "
                                 "SHA256SUMS (see native/package.sh).";
                    }
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(status, local); });
        }];
    [task resume];
}

+ (void)installUpdateAtURL:(NSURL *)url completion:(void (^)(NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *status = nil;
        NSString *work = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        [fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];

        // 1. Re-verify the archive. It sat in ~/Downloads, so anything could have
        //    touched it between download and install (TOCTOU).
        if (sARDMUpdateSHA256.length) {
            NSString *actual = ARDMSHA256OfFile(url.path);
            if (![actual isEqualToString:sARDMUpdateSHA256]) {
                [fm removeItemAtPath:work error:nil];
                status = @"Installation refused: the downloaded archive no longer matches its published "
                         "SHA-256 (re-download the update).";
                dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(status); });
                return;
            }
        }

        // 2. Extract into a private temporary directory.
        NSString *ext = url.pathExtension.lowercaseString;
        NSString *mountPoint = nil;
        if ([ext isEqualToString:@"dmg"]) {
            mountPoint = [work stringByAppendingPathComponent:@"vol"];
            [fm createDirectoryAtPath:mountPoint withIntermediateDirectories:YES attributes:nil error:nil];
            NSTask *attach = [[NSTask alloc] init];
            attach.executableURL = [NSURL fileURLWithPath:@"/usr/bin/hdiutil"];
            attach.arguments = @[@"attach", url.path, @"-nobrowse", @"-quiet", @"-mountpoint", mountPoint];
            attach.standardError = [NSFileHandle fileHandleWithNullDevice];
            @try { [attach launch]; [attach waitUntilExit]; } @catch (NSException *e) {}
        } else if ([ext isEqualToString:@"zip"]) {
            NSTask *unzip = [[NSTask alloc] init];
            unzip.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ditto"];
            unzip.arguments = @[@"-x", @"-k", url.path, work];
            unzip.standardError = [NSFileHandle fileHandleWithNullDevice];
            @try { [unzip launch]; [unzip waitUntilExit]; } @catch (NSException *e) {}
        }

        // 3. Locate the bundle and reject anything that is not this application.
        NSString *searchRoot = mountPoint ?: work;
        NSString *sourceApp = nil;
        NSString *foundOther = nil;
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        for (NSString *entry in [fm contentsOfDirectoryAtPath:searchRoot error:nil]) {
            NSString *full = [searchRoot stringByAppendingPathComponent:entry];
            if ([entry hasSuffix:@".app"]) {
                [candidates addObject:full];
            } else if ([fm fileExistsAtPath:[full stringByAppendingPathComponent:@"Contents/Info.plist"]]) {
                [candidates addObject:full];
            }
        }
        if ([ext isEqualToString:@"zip"] && candidates.count == 0) {
            // ditto may keep a wrapping folder; search one level down.
            NSDirectoryEnumerator *walk = [fm enumeratorAtPath:work];
            for (NSString *relative in walk) {
                if ([relative hasSuffix:@".app"]) {
                    [candidates addObject:[work stringByAppendingPathComponent:relative]];
                    break;
                }
            }
        }
        for (NSString *candidate in candidates) {
            NSString *identifier = ARDMBundleIdentifierAtPath(candidate);
            if ([identifier isEqualToString:kARDMBundleIdentifier]) { sourceApp = candidate; break; }
            if (identifier.length && !foundOther) foundOther = identifier;
        }

        if (!sourceApp) {
            status = foundOther
                ? [NSString stringWithFormat:@"The update contains “%@”, not %@. Refusing to install.",
                   foundOther, kARDMBundleIdentifier]
                : @"The update package did not contain an installable .app bundle. "
                   "(Zips must keep the enclosing .app folder — use `ditto -c -k --keepParent`.)";
        } else {
            // 4. Verify the signature before it touches /Applications.
            NSString *team = nil;
            BOOL adHoc = NO;
            NSString *reason = nil;
            NSString *installTeam = ARDMRunningTeamIdentifier();
            if (!ARDMInspectBundle(sourceApp, &team, &adHoc, &reason)) {
                status = [NSString stringWithFormat:@"Installation refused: %@.", reason ?: @"invalid signature"];
            } else if (installTeam.length && ![installTeam isEqualToString:team ?: @""]) {
                status = [NSString stringWithFormat:
                    @"Installation refused: the update is signed by team “%@”, but this build is signed by “%@”.",
                    team ?: @"none", installTeam];
            } else if (team.length == 0 && sARDMUpdateSHA256.length == 0) {
                status = @"Installation refused: unsigned update with no published SHA-256 — provenance "
                         "cannot be established.";
            } else {
                // 5. Stage inside /Applications so the swap is a same-volume rename.
                NSString *currentApp = [[NSBundle mainBundle] bundlePath];
                NSString *destName = [currentApp.lastPathComponent hasSuffix:@".app"]
                    ? currentApp.lastPathComponent : [sourceApp.lastPathComponent copy];
                NSString *dest = [@"/Applications" stringByAppendingPathComponent:destName];
                NSString *backup = [dest stringByAppendingString:@".previous"];
                NSString *staged = [@"/Applications" stringByAppendingPathComponent:
                    [NSString stringWithFormat:@".ardm-new-%@.app", [[NSUUID UUID] UUIDString]]];

                NSError *copyError = nil;
                if (![fm copyItemAtPath:sourceApp toPath:staged error:&copyError]) {
                    NSString *downloads = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
                    NSString *fallback = [downloads stringByAppendingPathComponent:destName];
                    [fm removeItemAtPath:fallback error:nil];
                    if ([fm copyItemAtPath:sourceApp toPath:fallback error:nil]) {
                        status = [NSString stringWithFormat:
                            @"没有写入 /Applications 的权限，未做任何替换。新版本已放到 %@，可手动拖入「应用程序」文件夹。",
                            fallback];
                    } else {
                        status = [NSString stringWithFormat:@"Install failed while staging: %@",
                                  copyError.localizedDescription];
                    }
                } else {
                    // 6. Re-check the staged copy, then swap with rollback.
                    NSString *stagedReason = nil;
                    if (!ARDMInspectBundle(staged, NULL, NULL, &stagedReason)) {
                        [fm removeItemAtPath:staged error:nil];
                        status = [NSString stringWithFormat:@"Installation refused: %@.", stagedReason];
                    } else {
                        NSString *swapError = nil;
                        if (ARDMInstallBundle(staged, dest, backup, &swapError)) {
                            NSString *version = ARDMBundleVersionAtPath(dest) ?: @"?";
                            status = [NSString stringWithFormat:
                                @"Installed %@ to %@. The previous version is kept as “%@” — rename it back "
                                "to .app to roll back, or delete it once the new version checks out.",
                                version, dest, backup.lastPathComponent];
                            [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dest]];
                        } else {
                            [fm removeItemAtPath:staged error:nil];
                            status = [NSString stringWithFormat:@"Install failed: %@", swapError];
                        }
                    }
                }
            }
        }

        if (mountPoint) {
            NSTask *detach = [[NSTask alloc] init];
            detach.executableURL = [NSURL fileURLWithPath:@"/usr/bin/hdiutil"];
            detach.arguments = @[@"detach", mountPoint, @"-quiet", @"-force"];
            detach.standardError = [NSFileHandle fileHandleWithNullDevice];
            @try { [detach launch]; [detach waitUntilExit]; } @catch (NSException *e) {}
        }
        [fm removeItemAtPath:work error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(status ?: @"Install finished."); });
    });
}

#pragma mark - Security-scoped bookmarks (FileInput.vue)

+ (NSData * _Nullable)bookmarkForURL:(NSURL *)url {
    NSData *data = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
             includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
    // Non-sandboxed builds cannot create security-scoped bookmarks for arbitrary paths.
    if (!data) {
        data = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil
                              relativeToURL:nil error:nil];
    }
    return data;
}

+ (NSURL * _Nullable)resolveBookmark:(NSData *)bookmark {
    BOOL stale = NO;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                           options:NSURLBookmarkResolutionWithSecurityScope
                                     relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
    if (!url) {
        url = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil
                          bookmarkDataIsStale:&stale error:nil];
    }
    if (url) [url startAccessingSecurityScopedResource];
    return url;
}

@end
