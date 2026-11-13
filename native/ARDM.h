#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Connection configuration (mirrors NewConnectionDialog.vue)

@interface ARDMConnectionConfig : NSObject <NSCopying>
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, copy) NSString *auth;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, assign) NSInteger db;
@property (nonatomic, copy) NSString *group;
@property (nonatomic, copy) NSString *separator;
@property (nonatomic, assign) BOOL readOnly;
@property (nonatomic, assign) BOOL cluster;
@property (nonatomic, copy) NSString *connectionName;

@property (nonatomic, assign) BOOL sshEnabled;
@property (nonatomic, copy) NSString *sshHost;
@property (nonatomic, assign) NSInteger sshPort;
@property (nonatomic, copy) NSString *sshUser;
@property (nonatomic, copy) NSString *sshPassword;
@property (nonatomic, copy) NSString *sshPrivateKey;
@property (nonatomic, copy) NSString *sshPassphrase;
@property (nonatomic, assign) NSInteger sshTimeout;
/** SSH ServerAliveInterval (seconds); 0 = use default. Mirrors upstream keepaliveInterval. */
@property (nonatomic, assign) NSInteger sshKeepaliveInterval;
/** Max seconds to wait for the tunnel to become ready (mirrors upstream readyTimeout). */
@property (nonatomic, assign) NSInteger sshReadyTimeout;
/** Close the local forward when the connection drops (mirrors upstream autoClose). */
@property (nonatomic, assign) BOOL sshAutoClose;

@property (nonatomic, assign) BOOL tlsEnabled;
@property (nonatomic, copy) NSString *tlsCA;
@property (nonatomic, copy) NSString *tlsCert;
@property (nonatomic, copy) NSString *tlsKey;
@property (nonatomic, copy) NSString *tlsSNI;
@property (nonatomic, assign) BOOL tlsInsecure;

@property (nonatomic, assign) BOOL sentinelEnabled;
@property (nonatomic, copy) NSString *sentinelMaster;
@property (nonatomic, copy) NSString *sentinelNodePassword;

/** Cluster NAT map: keys are "internalHost:port", values are "publicHost:port". */
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *natMap;
/** PEM bundle containing certificate + private key for mutual TLS. */
@property (nonatomic, copy) NSString *tlsIdentityPath;
/** Reconnect with exponential backoff after a dropped connection (default YES). */
@property (nonatomic, assign) BOOL autoReconnect;
/** Socket connect timeout in milliseconds (mirrors upstream connectTimeout, default 30000). */
@property (nonatomic, assign) NSInteger connectTimeout;
/** Number of linear reconnect attempts before surfacing a failure (mirrors upstream, default 3). */
@property (nonatomic, assign) NSInteger retryTimes;
/** YES when connections.json recorded a stored secret but the Keychain returned
    nothing (locked keychain / different user). Surfaced as a UI warning so the
    user is not left with a silent NOAUTH failure. Not persisted. */
@property (nonatomic, assign) BOOL secretUnavailable;

+ (NSArray<ARDMConnectionConfig *> *)loadAll;
+ (void)saveAll:(NSArray<ARDMConnectionConfig *> *)items;
/** Number of connections whose plaintext secrets were moved into the Keychain by
    the most recent loadAll, then reset to zero. Drives a one-shot UI notice so
    the user knows why passwords disappeared from connections.json. */
+ (NSInteger)consumeKeychainMigrationCount;
+ (instancetype)fromDictionary:(NSDictionary *)d;
/** Moves any plaintext secret found in a stored (or imported) dictionary into the
    macOS Keychain and blanked the in-memory copy. YES when something was moved. */
- (BOOL)hydrateSecretsFromKeychain:(NSDictionary *)source;
/** Redacted snapshot: password / passphrase fields are always empty. */
- (NSDictionary *)toDictionary;
/** Snapshot used for connections.json. Falls back to keeping a secret in the
    file when the Keychain refused to store it, so a password is never lost. */
- (NSDictionary *)persistenceDictionary;
@end

#pragma mark - Keychain secret storage (replaces plaintext credentials)

/** Generic-password items in the login keychain, one per connection + field.
    Secrets never reach connections.json; the JSON only records that one exists. */
@interface ARDMKeychain : NSObject
+ (BOOL)setSecret:(NSString *)secret forAccount:(NSString *)account;
+ (nullable NSString *)secretForAccount:(NSString *)account;
+ (BOOL)deleteSecretForAccount:(NSString *)account;
+ (BOOL)hasSecretForAccount:(NSString *)account;
@end

#pragma mark - Command log (mirrors the ioredis sendCommand wrapper)

@interface ARDMCommandLog : NSObject
@property (nonatomic, strong) NSDate *time;
@property (nonatomic, copy) NSString *connectionName;
@property (nonatomic, copy) NSString *command;
@property (nonatomic, assign) NSTimeInterval cost;
@end

#pragma mark - RESP client (replaces ioredis / tunnel-ssh)

typedef NS_ENUM(NSUInteger, ARDMKeyType) {
    ARDMKeyTypeString = 0,
    ARDMKeyTypeList,
    ARDMKeyTypeSet,
    ARDMKeyTypeZSet,
    ARDMKeyTypeHash,
    ARDMKeyTypeStream,
    ARDMKeyTypeReJSON,
    ARDMKeyTypeTimeSeries,
    ARDMKeyTypeVector,
    ARDMKeyTypeArray,
    ARDMKeyTypeUnknown
};

@interface ARDMRedisClient : NSObject
- (instancetype)initWithConfig:(ARDMConnectionConfig *)config;
- (BOOL)connect:(NSError **)error;
- (void)disconnect;
@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) NSString *hostUsed;
@property (nonatomic, readonly) NSInteger portUsed;

- (id)send:(NSArray<NSString *> *)args error:(NSError **)error;
/** Heuristic used by the UI to decide whether a command mutates state (e.g. to refresh the key list). */
- (BOOL)isWriteCommand:(NSArray<NSString *> *)args;
/** Atomic MULTI ... EXEC: returns the replies of every queued command plus EXEC's result array. */
- (NSArray *)sendTransaction:(NSArray<NSArray<NSString *> *> *)commands error:(NSError **)error;
/** Variant accepting NSData arguments for binary keys / values. */
- (id)sendArguments:(NSArray *)args error:(NSError **)error;
- (void)asyncSend:(NSArray<NSString *> *)args completion:(void (^)(id _Nullable reply, NSError * _Nullable error))completion;
/** Full cluster topology via CLUSTER SLOTS / CLUSTER NODES, including NAT-mapped addresses. */
- (NSDictionary *)clusterTopology:(NSError **)error;
/** Force a reconnect with exponential backoff; used after a dropped connection. */
- (BOOL)reconnectWithBackoff:(NSError **)error;
/** Dedicated long-lived connection for SUBSCRIBE / PSUBSCRIBE / MONITOR push streams. */
- (void)startLiveWithCommand:(NSArray<NSString *> *)args
                     onEvent:(void (^)(NSArray *reply))onEvent
                     onError:(void (^)(NSString *message))onError;
- (void)stopLive;
@property (nonatomic, readonly) BOOL liveRunning;

- (NSArray<NSString *> *)scanKeysMatching:(NSString *)pattern cursor:(NSUInteger *)cursor count:(NSUInteger)count error:(NSError **)error;
- (ARDMKeyType)typeOfKey:(NSString *)key error:(NSError **)error;
- (NSInteger)ttlOfKey:(NSString *)key error:(NSError **)error;
- (id)valueOfKey:(NSString *)key type:(ARDMKeyType)type error:(NSError **)error;
- (NSInteger)dbSize:(NSError **)error;
- (NSString *)infoSection:(NSString * _Nullable)section error:(NSError **)error;

@property (nonatomic, strong, readonly) NSMutableArray<ARDMCommandLog *> *logs;
@property (nonatomic, copy, nullable) void (^onLog)(ARDMCommandLog *log);
@property (nonatomic, assign) NSInteger selectedDB;
@end

#pragma mark - Viewers (mirrors FormatViewer.vue / util.js)

@interface ARDMFormatters : NSObject
+ (NSArray<NSString *> *)viewerNames;
+ (NSString *)detectViewerForData:(NSData *)data;
+ (NSString *)render:(NSData *)data as:(NSString *)viewer error:(NSError **)error;
/** Chunked variant used by the OverSize viewer: renders `length` bytes starting at
    `offset` and reports the absolute range, so huge values can be paged. */
+ (NSString *)render:(NSData *)data as:(NSString *)viewer
              offset:(NSUInteger)offset length:(NSUInteger)length error:(NSError **)error;
+ (NSString *)renderCustom:(NSData *)data script:(NSString *)script error:(NSError **)error;
/** Viewers that support editing and writing the encoded bytes back to Redis. */
+ (NSArray<NSString *> *)encodableViewers;
+ (NSData *)encode:(NSString *)text as:(NSString *)viewer error:(NSError **)error;
/** Optional {fieldNumber: fieldName} map for the Protobuf viewer. */
+ (void)setProtobufSchema:(NSDictionary<NSNumber *, NSString *> * _Nullable)schema;
+ (NSDictionary<NSNumber *, NSString *> * _Nullable)protobufSchema;
/** Scoped schema produced from a .proto file: messageName → {fieldNumber: "kind|name|childType"}.
    `root` is the message used for the top level. Nested messages are decoded
    recursively through their own scope, and repeated fields render as arrays. */
+ (void)setProtobufScopes:(NSDictionary<NSString *, NSDictionary<NSNumber *, NSString *> *> * _Nullable)scopes
                     root:(NSString * _Nullable)root;
/** Re-indent (pretty) or compact a JSON document token by token. Numbers are
    copied verbatim, so integers beyond 2^53 keep every digit. Returns nil when
    the input is not structurally valid JSON. */
+ (nullable NSString *)formatJSON:(NSData *)data pretty:(BOOL)pretty;
/** Structural JSON check that does not re-encode numbers. */
+ (BOOL)validateJSON:(NSData *)data;
@end

#pragma mark - Localization (mirrors src/i18n/langs/*.js)

@interface ARDMLocalization : NSObject
+ (instancetype)shared;
@property (nonatomic, strong, readonly) NSArray<NSString *> *languages;
@property (nonatomic, copy) NSString *currentLanguage;
- (NSString *)t:(NSString *)key;
/** Reverse lookup: translate an English UI label by matching it against en.js, then
    resolving the same key in the currently selected language. Falls back to the input. */
- (NSString *)tText:(NSString *)english;
@end

#pragma mark - UI

@interface ARDMAppDelegate : NSObject <NSApplicationDelegate>
@end

@interface ARDMMainWindowController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate>
- (void)showSettings:(id)sender;
@end

@interface ARDMConnectionSheetController : NSObject
+ (void)presentForConfig:(ARDMConnectionConfig * _Nullable)config
                inWindow:(NSWindow *)window
              completion:(void (^)(ARDMConnectionConfig * _Nullable saved))completion;
@end

NS_ASSUME_NONNULL_END
