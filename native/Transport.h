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

/** UpdateCheck.vue / electron-updater replacement (GitHub Releases API). */
+ (void)checkForUpdateWithCompletion:(void (^)(NSString *status, NSURL * _Nullable downloadURL))completion;

/** FileInput.vue security-scoped bookmarks for TLS / SSH key files. */
+ (NSData * _Nullable)bookmarkForURL:(NSURL *)url;
+ (NSURL * _Nullable)resolveBookmark:(NSData *)bookmark;

@end

NS_ASSUME_NONNULL_END
