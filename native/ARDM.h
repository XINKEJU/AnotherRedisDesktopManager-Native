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

@property (nonatomic, assign) BOOL tlsEnabled;
@property (nonatomic, copy) NSString *tlsCA;
@property (nonatomic, copy) NSString *tlsCert;
@property (nonatomic, copy) NSString *tlsKey;
@property (nonatomic, copy) NSString *tlsSNI;

@property (nonatomic, assign) BOOL sentinelEnabled;
@property (nonatomic, copy) NSString *sentinelMaster;
@property (nonatomic, copy) NSString *sentinelNodePassword;

/** Cluster NAT map: keys are "internalHost:port", values are "publicHost:port". */
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *natMap;
/** PEM bundle containing certificate + private key for mutual TLS. */
@property (nonatomic, copy) NSString *tlsIdentityPath;
/** Reconnect with exponential backoff after a dropped connection (default YES). */
@property (nonatomic, assign) BOOL autoReconnect;

+ (NSArray<ARDMConnectionConfig *> *)loadAll;
+ (void)saveAll:(NSArray<ARDMConnectionConfig *> *)items;
+ (instancetype)fromDictionary:(NSDictionary *)d;
- (NSDictionary *)toDictionary;
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
+ (NSString *)renderCustom:(NSData *)data script:(NSString *)script error:(NSError **)error;
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
