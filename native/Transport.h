#import "ARDM.h"

NS_ASSUME_NONNULL_BEGIN

/** Services replacing the Electron main-process / Node-only helpers. */
@interface ARDMAppServices : NSObject

/** font-manager.js replacement: every installed font family. */
+ (NSArray<NSString *> *)availableFonts;

/** commands.js replacement: {commandName: signatureOrArray} loaded via JavaScriptCore. */
+ (NSDictionary<NSString *, id> *)commandReference;

/** CustomFormatter.vue persistence (name + script). */
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)customFormatters;
+ (void)saveCustomFormatters:(NSArray<NSDictionary<NSString *, NSString *> *> *)items;

/** Setting.vue connection import / export. */
+ (NSString *)exportConnectionsJSON;
+ (BOOL)importConnectionsJSON:(NSData *)data error:(NSError **)error;

/** UpdateCheck.vue / electron-updater replacement (this native repo's Releases API). */
+ (void)checkForUpdateWithCompletion:(void (^)(NSString *status, NSURL * _Nullable releasePage))completion;
/** Info about the release found by the last successful check (nil before that). */
+ (NSString * _Nullable)pendingUpdateVersion;
+ (NSString * _Nullable)pendingUpdateAssetName;
/** YES when the release published a SHA-256 the downloader could consume. */
+ (BOOL)pendingUpdateHasChecksum;

/**
 Downloads the latest macOS release asset into ~/Downloads and verifies it.
 A published SHA-256 is mandatory when this build is ad-hoc signed, because an
 ad-hoc signature carries no provenance; mismatches delete the file.
 */
+ (void)downloadUpdateWithCompletion:(void (^)(NSString *status, NSURL * _Nullable localFile))completion;

/**
 Extracts, re-verifies the archive and the bundle's code signature, stages the
 new bundle next to the destination, and swaps it in atomically. The previous
 version is kept as `<App>.app.previous`; a failed swap restores it.
 */
+ (void)installUpdateAtURL:(NSURL *)url completion:(void (^)(NSString *status))completion
    NS_SWIFT_NAME(installUpdate(_:completion:));

/** FileInput.vue security-scoped bookmarks for TLS / SSH key files. */
+ (NSData * _Nullable)bookmarkForURL:(NSURL *)url;
+ (NSURL * _Nullable)resolveBookmark:(NSData *)bookmark;

@end

NS_ASSUME_NONNULL_END
