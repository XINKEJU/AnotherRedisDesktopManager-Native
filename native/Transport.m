#import "Transport.h"
#import <AppKit/AppKit.h>
#import <JavaScriptCore/JavaScriptCore.h>

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

+ (void)checkForUpdateWithCompletion:(void (^)(NSString *, NSURL * _Nullable))completion {
    NSURL *url = [NSURL URLWithString:@"https://api.github.com/repos/qishibo/AnotherRedisDesktopManager/releases/latest"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"ARDM-Native" forHTTPHeaderField:@"User-Agent"];
    [request setTimeoutInterval:10];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            NSString *status;
            NSURL *download = nil;
            if (networkError) {
                status = [NSString stringWithFormat:@"Update check unavailable: %@", networkError.localizedDescription];
            } else {
                NSDictionary *release = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:nil];
                NSString *tag = [release isKindOfClass:NSDictionary.class] ? release[@"tag_name"] : nil;
                NSString *current = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0";
                if (!tag) {
                    status = @"Update check returned no release information";
                } else if ([tag isEqualToString:current] || [tag isEqualToString:[@"v" stringByAppendingString:current]]) {
                    status = [NSString stringWithFormat:@"You are up to date (%@)", current];
                } else {
                    status = [NSString stringWithFormat:@"New release available: %@ (current %@)", tag, current];
                    NSString *page = release[@"html_url"];
                    if (page) download = [NSURL URLWithString:page];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(status, download); });
        }];
    [task resume];
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
