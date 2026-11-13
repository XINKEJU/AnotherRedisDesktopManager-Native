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
/** Downloads the latest macOS release asset into ~/Downloads and returns its file URL. */
+ (void)downloadUpdateWithCompletion:(void (^)(NSString *status, NSURL * _Nullable localFile))completion;
/** Mounts a downloaded .dmg/.zip, replaces the installed .app bundle, and relaunches it. */
+ (void)installUpdateAtURL:(NSURL *)url completion:(void (^)(NSString *status))completion
    NS_SWIFT_NAME(installUpdate(_:completion:));

/** FileInput.vue security-scoped bookmarks for TLS / SSH key files. */
+ (NSData * _Nullable)bookmarkForURL:(NSURL *)url;
+ (NSURL * _Nullable)resolveBookmark:(NSData *)bookmark;

@end

NS_ASSUME_NONNULL_END
