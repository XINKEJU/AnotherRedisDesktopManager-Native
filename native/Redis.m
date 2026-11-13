#import "ARDM.h"
#import <CoreFoundation/CoreFoundation.h>
#import <Security/Security.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import <stdlib.h>
#import <errno.h>

#pragma mark - Helpers

static NSError *ARDMError(NSString *message, NSInteger code) {
    return [NSError errorWithDomain:@"me.qii404.ardm.native"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"unknown error"}];
}

/** Build the kCFStreamSSLCertificates chain for mutual TLS.
    Supports PKCS#12 (tlsIdentityPath) and a PEM certificate + private key pair. */
static NSArray *ARDMMutualTLSChain(ARDMConnectionConfig *c) {
    SecIdentityRef identity = NULL;
    if (c.tlsIdentityPath.length) {
        NSData *p12 = [NSData dataWithContentsOfFile:c.tlsIdentityPath];
        if (p12) {
            NSDictionary *opts = @{(__bridge id)kSecImportExportPassphrase: c.tlsKey ?: @""};
            CFArrayRef items = NULL;
            OSStatus st = SecPKCS12Import((__bridge CFDataRef)p12, (__bridge CFDictionaryRef)opts, &items);
            if (st == errSecSuccess && items && CFArrayGetCount(items) > 0) {
                NSDictionary *first = (__bridge NSDictionary *)CFArrayGetValueAtIndex(items, 0);
                id value = first[(__bridge id)kSecImportItemIdentity];
                if (value) { identity = (__bridge SecIdentityRef)value; CFRetain(identity); }
            }
            if (items) CFRelease(items);
        }
    }
    if (!identity && c.tlsCert.length && c.tlsKey.length) {
        NSMutableData *pem = [NSMutableData data];
        NSData *cert = [NSData dataWithContentsOfFile:c.tlsCert];
        NSData *key = [NSData dataWithContentsOfFile:c.tlsKey];
        if (cert) [pem appendData:cert];
        if (key) [pem appendData:key];
        if (pem.length) {
            SecItemImportExportKeyParameters params; memset(&params, 0, sizeof(params));
            params.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;
            SecExternalFormat format = kSecFormatPEMSequence;
            SecExternalItemType type = kSecItemTypeAggregate;
            CFArrayRef imported = NULL;
            OSStatus st = SecItemImport((__bridge CFDataRef)pem, NULL, &format, &type,
                                        0, &params, NULL, &imported);
            if (st == errSecSuccess && imported) {
                NSArray *found = (__bridge NSArray *)imported;
                for (id item in found) {
                    if (CFGetTypeID((__bridge CFTypeRef)item) == SecIdentityGetTypeID()) {
                        identity = (__bridge SecIdentityRef)item;
                        break;
                    }
                }
                // Keep the identity alive after releasing the array.
                if (identity) CFRetain(identity);
                CFRelease(imported);
            }
        }
    }
    if (!identity) return nil;
    NSMutableArray *chain = [NSMutableArray array];
    [chain addObject:(__bridge id)identity];
    SecCertificateRef certificate = NULL;
    if (SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess && certificate) {
        [chain addObject:(__bridge id)certificate];
        CFRelease(certificate);
    }
    CFRelease(identity);
    return chain;
}

static NSString *ARDMReplyToString(id reply) {
    if (!reply || reply == NSNull.null) return @"(nil)";
    if ([reply isKindOfClass:NSString.class]) return reply;
    if ([reply isKindOfClass:NSData.class]) {
        NSString *s = [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding];
        return s ?: [NSString stringWithFormat:@"<binary %lu bytes>", (unsigned long)[(NSData *)reply length]];
    }
    if ([reply isKindOfClass:NSNumber.class]) return [(NSNumber *)reply stringValue];
    if ([reply isKindOfClass:NSArray.class]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id item in (NSArray *)reply) [parts addObject:ARDMReplyToString(item)];
        return [parts componentsJoinedByString:@"\n"];
    }
    return [NSString stringWithFormat:@"%@", reply];
}

static NSArray *ARDMNormalizeArray(id reply) {
    if ([reply isKindOfClass:NSArray.class]) return reply;
    if (!reply || reply == NSNull.null) return @[];
    return @[reply];
}

/** Build the command-line string recorded in the command log.
    Masks AUTH secrets, drops keepalive PINGs, and truncates over-long args so
    credentials never leak into the on-screen / persisted log (upstream CommandLog.vue). */
static NSString *ARDMCommandLogString(NSArray<NSString *> *args) {
    if (args.count == 0) return @"";
    NSString *verb = [[args.firstObject uppercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
    if ([verb isEqualToString:@"PING"]) return nil; // keepalive pings must not flood the command log
    NSMutableArray *redacted = [args mutableCopy];
    if ([verb isEqualToString:@"AUTH"] && redacted.count >= 2) {
        [redacted replaceObjectsInRange:NSMakeRange(1, redacted.count - 1)
                    withObjectsFromArray:@[@"***"]];
    } else if ([verb isEqualToString:@"AUTH"]) {
        redacted[0] = @"AUTH ***";
    }
    for (NSUInteger i = 0; i < redacted.count; i++) {
        NSString *s = redacted[i];
        if (s.length > 200) redacted[i] = [[s substringToIndex:200] stringByAppendingString:@"…(truncated)"];
    }
    return [redacted componentsJoinedByString:@" "];
}

#pragma mark - Connection config

@implementation ARDMConnectionConfig

- (instancetype)init {
    if ((self = [super init])) {
        _identifier = [[NSUUID UUID] UUIDString];
        _name = @"New Connection";
        _host = @"127.0.0.1";
        _port = 6379;
        _auth = @"";
        _username = @"";
        _db = 0;
        _group = @"";
        _separator = @":";
        _connectionName = @"";
        _sshPort = 22;
        _sshTimeout = 30;
        _sshHost = @"";
        _sshUser = @"";
        _sshPassword = @"";
        _sshPrivateKey = @"";
        _sshPassphrase = @"";
        _sshKeepaliveInterval = 0;
        _sshReadyTimeout = 10;
        _sshAutoClose = YES;
        _tlsCA = @"";
        _tlsCert = @"";
        _tlsKey = @"";
        _tlsSNI = @"";
        _tlsInsecure = NO;
        _sentinelMaster = @"";
        _sentinelNodePassword = @"";
        _natMap = @{};
        _tlsIdentityPath = @"";
        _autoReconnect = YES;
        _connectTimeout = 30000;
        _retryTimes = 3;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    ARDMConnectionConfig *c = [[ARDMConnectionConfig allocWithZone:zone] init];
    c.identifier = self.identifier;
    c.name = self.name; c.host = self.host; c.port = self.port;
    c.auth = self.auth; c.username = self.username; c.db = self.db;
    c.group = self.group; c.separator = self.separator;
    c.readOnly = self.readOnly; c.cluster = self.cluster;
    c.connectionName = self.connectionName;
    c.sshEnabled = self.sshEnabled; c.sshHost = self.sshHost; c.sshPort = self.sshPort;
    c.sshUser = self.sshUser; c.sshPassword = self.sshPassword;
    c.sshPrivateKey = self.sshPrivateKey; c.sshPassphrase = self.sshPassphrase; c.sshTimeout = self.sshTimeout;
    c.sshKeepaliveInterval = self.sshKeepaliveInterval; c.sshReadyTimeout = self.sshReadyTimeout; c.sshAutoClose = self.sshAutoClose;
    c.tlsEnabled = self.tlsEnabled; c.tlsCA = self.tlsCA; c.tlsCert = self.tlsCert;
    c.tlsKey = self.tlsKey; c.tlsSNI = self.tlsSNI; c.tlsInsecure = self.tlsInsecure;
    c.sentinelEnabled = self.sentinelEnabled; c.sentinelMaster = self.sentinelMaster;
    c.sentinelNodePassword = self.sentinelNodePassword;
    c.natMap = self.natMap; c.tlsIdentityPath = self.tlsIdentityPath;
    c.autoReconnect = self.autoReconnect;
    return c;
}

+ (NSString *)storePath {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@".config/ardm-native"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"connections.json"];
}

+ (NSArray<ARDMConnectionConfig *> *)loadAll {
    NSData *d = [NSData dataWithContentsOfFile:[self storePath]];
    if (!d) return @[];
    NSArray *raw = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *item in raw) {
        if ([item isKindOfClass:NSDictionary.class]) [out addObject:[self fromDictionary:item]];
    }
    return out;
}

+ (void)saveAll:(NSArray<ARDMConnectionConfig *> *)items {
    NSMutableArray *raw = [NSMutableArray array];
    for (ARDMConnectionConfig *c in items) [raw addObject:[c toDictionary]];
    NSData *d = [NSJSONSerialization dataWithJSONObject:raw options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToFile:[self storePath] atomically:YES];
}

#define STR(k) c.k = ([d[@#k] isKindOfClass:NSString.class] ? d[@#k] : c.k)
#define NUM(k) c.k = ([d[@#k] respondsToSelector:@selector(integerValue)] ? [d[@#k] integerValue] : c.k)
#define BOOLV(k) c.k = ([d[@#k] respondsToSelector:@selector(boolValue)] ? [d[@#k] boolValue] : c.k)

+ (instancetype)fromDictionary:(NSDictionary *)d {
    ARDMConnectionConfig *c = [[ARDMConnectionConfig alloc] init];
    STR(identifier); STR(name); STR(host); NUM(port); STR(auth); STR(username); NUM(db);
    STR(group); STR(separator); BOOLV(readOnly); BOOLV(cluster); STR(connectionName);
    BOOLV(sshEnabled); STR(sshHost); NUM(sshPort); STR(sshUser); STR(sshPassword);
    STR(sshPrivateKey); STR(sshPassphrase); NUM(sshTimeout);
    BOOLV(tlsEnabled); STR(tlsCA); STR(tlsCert); STR(tlsKey); STR(tlsSNI); BOOLV(tlsInsecure);
    BOOLV(sentinelEnabled); STR(sentinelMaster); STR(sentinelNodePassword);
    STR(tlsIdentityPath); BOOLV(autoReconnect);
    NUM(connectTimeout); NUM(retryTimes);
    NUM(sshKeepaliveInterval); NUM(sshReadyTimeout); BOOLV(sshAutoClose);
    if ([d[@"natMap"] isKindOfClass:NSDictionary.class]) c.natMap = d[@"natMap"];
    return c;
}

- (NSDictionary *)toDictionary {
    return @{
        @"identifier": self.identifier ?: @"", @"name": self.name ?: @"", @"host": self.host ?: @"",
        @"port": @(self.port), @"auth": self.auth ?: @"", @"username": self.username ?: @"",
        @"db": @(self.db), @"group": self.group ?: @"", @"separator": self.separator ?: @"",
        @"readOnly": @(self.readOnly), @"cluster": @(self.cluster),
        @"connectionName": self.connectionName ?: @"",
        @"sshEnabled": @(self.sshEnabled), @"sshHost": self.sshHost ?: @"", @"sshPort": @(self.sshPort),
        @"sshUser": self.sshUser ?: @"", @"sshPassword": self.sshPassword ?: @"",
        @"sshPrivateKey": self.sshPrivateKey ?: @"", @"sshPassphrase": self.sshPassphrase ?: @"",
        @"sshTimeout": @(self.sshTimeout),
        @"tlsEnabled": @(self.tlsEnabled), @"tlsCA": self.tlsCA ?: @"", @"tlsCert": self.tlsCert ?: @"",
        @"tlsKey": self.tlsKey ?: @"", @"tlsSNI": self.tlsSNI ?: @"", @"tlsInsecure": @(self.tlsInsecure),
        @"sentinelEnabled": @(self.sentinelEnabled), @"sentinelMaster": self.sentinelMaster ?: @"",
        @"sentinelNodePassword": self.sentinelNodePassword ?: @"",
        @"natMap": self.natMap ?: @{},         @"tlsIdentityPath": self.tlsIdentityPath ?: @"",
        @"autoReconnect": @(self.autoReconnect),
        @"connectTimeout": @(self.connectTimeout),
        @"retryTimes": @(self.retryTimes),
        @"sshKeepaliveInterval": @(self.sshKeepaliveInterval),
        @"sshReadyTimeout": @(self.sshReadyTimeout),
        @"sshAutoClose": @(self.sshAutoClose),
    };
}
@end

@implementation ARDMCommandLog
@end

#pragma mark - RESP stream reader

@interface ARDMRESPStream : NSObject {
    CFReadStreamRef _read;
    CFWriteStreamRef _write;
    NSMutableData *_buffer;
}
- (instancetype)initWithRead:(CFReadStreamRef)read write:(CFWriteStreamRef)write;
- (BOOL)writeData:(NSData *)data error:(NSError **)error;
- (id)readReply:(NSError **)error;
- (void)close;
@end

@implementation ARDMRESPStream

- (instancetype)initWithRead:(CFReadStreamRef)read write:(CFWriteStreamRef)write {
    if ((self = [super init])) {
        _read = read; _write = write; _buffer = [NSMutableData data];
    }
    return self;
}

- (BOOL)fillBuffer:(NSError **)error {
    UInt8 chunk[8192];
    CFIndex n = CFReadStreamRead(_read, chunk, sizeof(chunk));
    if (n > 0) { [_buffer appendBytes:chunk length:(NSUInteger)n]; return YES; }
    if (error) *error = ARDMError(@"Connection closed by Redis server", 2);
    return NO;
}

- (NSData *)readLine:(NSError **)error {
    const char *bytes = _buffer.bytes;
    NSUInteger length = _buffer.length;
    NSRange found = {NSNotFound, 0};
    for (NSUInteger i = 0; i + 1 < length; i++) {
        if (bytes[i] == '\r' && bytes[i + 1] == '\n') { found = NSMakeRange(i, 2); break; }
    }
    while (found.location == NSNotFound) {
        if (![self fillBuffer:error]) return nil;
        bytes = _buffer.bytes; length = _buffer.length;
        for (NSUInteger i = 0; i + 1 < length; i++) {
            if (bytes[i] == '\r' && bytes[i + 1] == '\n') { found = NSMakeRange(i, 2); break; }
        }
    }
    NSData *line = [_buffer subdataWithRange:NSMakeRange(0, found.location)];
    [_buffer replaceBytesInRange:NSMakeRange(0, found.location + 2) withBytes:NULL length:0];
    return line;
}

- (NSData *)readExactly:(NSUInteger)count error:(NSError **)error {
    while (_buffer.length < count) if (![self fillBuffer:error]) return nil;
    NSData *out = [_buffer subdataWithRange:NSMakeRange(0, count)];
    [_buffer replaceBytesInRange:NSMakeRange(0, count) withBytes:NULL length:0];
    return out;
}

- (id)readReply:(NSError **)error {
    NSData *line = [self readLine:error];
    if (!line) return nil;
    const char *p = line.bytes;
    char kind = p[0];
    NSString *body = [[NSString alloc] initWithData:[line subdataWithRange:NSMakeRange(1, line.length - 1)]
                                           encoding:NSUTF8StringEncoding] ?: @"";
    switch (kind) {
        case '+': return body;
        case '-':
            if (error) *error = ARDMError(body, 3);
            return nil;
        case ':': {
            // Redis integer replies are signed 64-bit, so a parsed long long is exact for the
            // normal range. Beyond INT64 bounds we keep the verbatim decimal string so the
            // value survives without precision loss (mirrors upstream's no-re-encode policy).
            const char *cstr = [body UTF8String];
            errno = 0;
            char *end = NULL;
            long long ll = strtoll(cstr, &end, 10);
            if (errno == 0 && end != cstr && *end == '\0') return @(ll);
            return body;
        }
        case '$': {
            NSInteger len = [body integerValue];
            if (len < 0) return NSNull.null;
            NSData *bulk = [self readExactly:(NSUInteger)len error:error];
            if (!bulk) return nil;
            [self readExactly:2 error:error];
            return bulk;
        }
        case '*': {
            NSInteger count = [body integerValue];
            if (count < 0) return NSNull.null;
            NSMutableArray *arr = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
            for (NSInteger i = 0; i < count; i++) {
                id item = [self readReply:error];
                if (!item) return nil;
                [arr addObject:item];
            }
            return arr;
        }
        case '#': return [body isEqualToString:@"t"] ? @YES : @NO;
        case ',': return @([body doubleValue]);
        case '_': return NSNull.null;
        case '(': return body;
        case '%': case '~': case '>': {
            NSInteger count = [body integerValue];
            NSMutableArray *arr = [NSMutableArray array];
            for (NSInteger i = 0; i < count * (kind == '%' ? 2 : 1); i++) {
                id item = [self readReply:error];
                if (!item) return nil;
                [arr addObject:item];
            }
            return arr;
        }
        default: return body;
    }
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error {
    const UInt8 *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        CFIndex n = CFWriteStreamWrite(_write, bytes, (CFIndex)remaining);
        if (n <= 0) { if (error) *error = ARDMError(@"Failed to write to Redis", 4); return NO; }
        bytes += n; remaining -= (NSUInteger)n;
    }
    return YES;
}

- (void)close {
    if (_read) { CFReadStreamClose(_read); CFRelease(_read); _read = NULL; }
    if (_write) { CFWriteStreamClose(_write); CFRelease(_write); _write = NULL; }
}
@end

#pragma mark - Redis client

static NSSet<NSString *> *ARDMWriteCommands(void) {
    static NSSet *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Covers single-token verbs plus two-token administrative commands
        // (the send: check tests both the first token and the first two tokens
        // joined, so "CONFIG SET" / "CLIENT KILL" / "XGROUP DESTROY" are caught).
        s = [NSSet setWithArray:@[
            @"SET",@"SETNX",@"SETEX",@"PSETEX",@"MSET",@"MSETNX",@"GETSET",@"APPEND",@"INCR",@"DECR",@"INCRBY",@"DECRBY",
            @"INCRBYFLOAT",@"DECRBYFLOAT",@"COPY",@"DEL",@"UNLINK",@"EXPIRE",@"PEXPIRE",@"EXPIREAT",@"PEXPIREAT",@"PERSIST",
            @"EXPIRETIME",@"PEXPIRETIME",@"RENAME",@"RENAMENX",@"MOVE",@"SWAPDB",@"RESTORE",@"RESTORE-ASKING",@"DUMP",
            @"MIGRATE",@"OBJECT",@"SORT",@"LMOVE",@"BLMOVE",@"RPOPLPUSH",
            @"HSET",@"HSETNX",@"HMSET",@"HDEL",@"HINCRBY",@"HINCRBYFLOAT",@"HPEXPIRE",@"HPEXPIREAT",@"HEXPIRE",@"HEXPIREAT",
            @"HPERSIST",@"HRANDFIELD",
            @"LPUSH",@"RPUSH",@"LPUSHX",@"RPUSHX",@"LPOP",@"RPOP",@"LSET",@"LREM",@"LTRIM",@"LINSERT",
            @"SADD",@"SREM",@"SPOP",@"SMOVE",@"SINTERSTORE",@"SUNIONSTORE",@"SDIFFSTORE",
            @"ZADD",@"ZREM",@"ZINCRBY",@"ZINTERSTORE",@"ZUNIONSTORE",@"ZDIFFSTORE",@"ZPOPMIN",@"ZPOPMAX",@"BZPOPMIN",
            @"BZPOPMAX",@"ZRANGESTORE",
            @"XADD",@"XDEL",@"XTRIM",@"XGROUP",@"XACK",@"XCLAIM",@"XAUTOCLAIM",@"XGROUP DESTROY",@"XGROUP CREATE",
            @"JSON.SET",@"JSON.DEL",@"JSON.MSET",@"JSON.MERGE",@"JSON.NUMINCRBY",@"JSON.STRAPPEND",@"JSON.ARRAPPEND",
            @"JSON.ARRPOP",@"JSON.ARRINSERT",@"JSON.ARRTRIM",@"JSON.CLEAR",@"JSON.FORGET",
            @"TS.ADD",@"TS.CREATE",@"TS.DEL",@"TS.ALTER",@"TS.INCRBY",@"TS.DECRBY",@"TS.CREATERULE",@"TS.DELETERULE",
            @"VADD",@"VREM",@"VSETATTR",@"SETATTR",@"ARSET",@"ARDEL",@"ARINSERT",@"ARAPPEND",@"ARPOP",@"ARTRIM",
            @"SETBIT",@"SETRANGE",@"BITFIELD",@"GEOADD",@"GEOSEARCHSTORE",@"PFADD",@"PFMERGE",
            @"EVAL",@"EVALSHA",@"SCRIPT",@"FUNCTION",@"DEBUG",@"MODULE",@"REPLICAOF",@"SLAVEOF",@"ACL",
            @"CONFIG SET",@"CONFIG REWRITE",@"CONFIG RESETSTAT",@"SHUTDOWN",@"FLUSHDB",@"FLUSHALL",@"SAVE",@"BGSAVE",
            @"CLIENT KILL",@"CLIENT SETNAME",@"CLIENT SETINFO",@"CLIENT PAUSE",@"CLIENT UNPAUSE",@"CLIENT UNBLOCK",@"SCRIPT FLUSH",
            @"FAILOVER",@"FAILOVER AUTH",
            @"CLUSTER ADDSLOTS",@"CLUSTER DELSLOTS",@"CLUSTER SETSLOT",@"CLUSTER MEET",@"CLUSTER FORGET",
            @"CLUSTER REPLICATE",@"CLUSTER RESET",@"CLUSTER SAVECONFIG",@"CLUSTER BUMPEPOCH",@"CLUSTER MYID",
            @"SCHEDULE",@"LATENCY",@"SWAPDB",
            @"PUBLISH",@"SPUBLISH",@"MULTI",@"EXEC",@"DISCARD",@"WATCH",@"UNWATCH",
            @"FT.CREATE",@"FT.ADD",@"FT.ALTER",@"FT.DROPINDEX",@"FT.ALIASADD",@"FT.ALIASDEL",@"FT.ALIASUPDATE",
            @"FT.DICTADD",@"FT.DICTDEL",@"FT.SYNUPDATE",@"FT.SYNDFUPDATE"]];
    });
    return s;
}

@interface ARDMRedisClient () {
    ARDMRESPStream *_stream;
    dispatch_queue_t _queue;
    NSTask *_sshTask;
    NSString *_connectHost;
    NSInteger _connectPort;
    NSString *_effectiveAuth;
    BOOL _didRetry;
    ARDMRedisClient *_liveClient;
    dispatch_queue_t _liveQueue;
    volatile BOOL _liveRunning;
}
@property (nonatomic, strong) ARDMConnectionConfig *config;
@property (nonatomic, assign, readwrite) BOOL isConnected;
@property (nonatomic, assign) NSInteger logLimit;
@property (nonatomic, strong, readwrite) NSMutableArray<ARDMCommandLog *> *logs;
@end

@implementation ARDMRedisClient

- (instancetype)initWithConfig:(ARDMConnectionConfig *)config {
    if ((self = [super init])) {
        _config = config;
        _logs = [NSMutableArray array];
        _queue = dispatch_queue_create("me.qii404.ardm.redis", DISPATCH_QUEUE_SERIAL);
        _logLimit = 5000;
    }
    return self;
}

static uint16_t ARDMFreeLocalPort(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return 0;
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); addr.sin_port = 0;
    uint16_t port = 0;
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        socklen_t len = sizeof(addr);
        if (getsockname(s, (struct sockaddr *)&addr, &len) == 0) port = ntohs(addr.sin_port);
    }
    close(s);
    return port;
}

- (BOOL)openSSHtunnel:(NSError **)error {
    uint16_t local = ARDMFreeLocalPort();
    if (!local) { if (error) *error = ARDMError(@"Cannot allocate a local SSH tunnel port", 5); return NO; }
    NSInteger sshTimeout = _config.sshTimeout > 0 ? _config.sshTimeout : 10;
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"-N", @"-o", @"StrictHostKeyChecking=accept-new",
        @"-o", @"ExitOnForwardFailure=yes", @"-o",
        [NSString stringWithFormat:@"ConnectTimeout=%ld", (long)sshTimeout],
        @"-L", [NSString stringWithFormat:@"%d:%@:%ld", local, _config.host, (long)_config.port],
        @"-p", [NSString stringWithFormat:@"%ld", (long)(_config.sshPort ?: 22)]]];
    if (_config.sshKeepaliveInterval > 0) {
        [args addObjectsFromArray:@[@"-o", [NSString stringWithFormat:@"ServerAliveInterval=%ld", (long)_config.sshKeepaliveInterval],
            @"-o", @"ServerAliveCountMax=3"]];
    }
    if (_config.sshAutoClose) {
        // Drop the tunnel once all forwarded connections have closed (upstream autoClose).
        [args addObjectsFromArray:@[@"-o", @"ServerAliveInterval=15"]];
    }
    if (_config.sshPrivateKey.length) [args addObjectsFromArray:@[@"-i", _config.sshPrivateKey]];
    [args addObject:[NSString stringWithFormat:@"%@@%@", _config.sshUser ?: @"root", _config.sshHost]];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ssh"];
    task.arguments = args;
    if (_config.sshPassword.length) {
        NSString *script = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ardm_askpass.sh"];
        NSString *body = [NSString stringWithFormat:@"#!/bin/sh\necho %@\n",
                          [NSString stringWithFormat:@"'%@'", [_config.sshPassword stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]]];
        [[body dataUsingEncoding:NSUTF8StringEncoding] writeToFile:script atomically:YES];
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0700} ofItemAtPath:script error:nil];
        task.environment = [@{@"SSH_ASKPASS": script, @"SSH_ASKPASS_REQUIRE": @"force", @"DISPLAY": @"ardm:0"}
                            mutableCopy];
    }
    NSPipe *errPipe = [NSPipe pipe];
    task.standardError = errPipe;
    @try { [task launch]; } @catch (NSException *e) {
        if (error) *error = ARDMError([NSString stringWithFormat:@"SSH failed: %@", e.reason], 6);
        return NO;
    }
    _sshTask = task;
    _connectHost = @"127.0.0.1";
    _connectPort = local;
    NSInteger readyTimeout = _config.sshReadyTimeout > 0 ? _config.sshReadyTimeout : 10;
    NSInteger attempts = readyTimeout * 4; // poll every 250 ms
    for (int i = 0; i < (int)attempts; i++) {
        int s = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in a; memset(&a, 0, sizeof(a));
        a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); a.sin_port = htons(local);
        int ok = connect(s, (struct sockaddr *)&a, sizeof(a));
        close(s);
        if (ok == 0) return YES;
        usleep(250000);
    }
    if (error) *error = ARDMError([NSString stringWithFormat:@"SSH tunnel did not become ready within %ld seconds", (long)readyTimeout], 7);
    return NO;
}

/** Apply TLS settings, including a client identity chain for mutual TLS.
    By default the certificate chain is validated. Only when the connection is
    explicitly marked insecure (rejectUnauthorized=false) is validation relaxed. */
- (void)configureTLSForRead:(CFReadStreamRef)read write:(CFWriteStreamRef)write {
    BOOL insecure = _config.tlsInsecure;
    NSMutableDictionary *ssl = [@{@"kCFStreamSSLLevel": @"kCFStreamSocketSecurityLevelNegotiatedSSL",
                                  @"kCFStreamSSLValidatesCertificateChain": @(!insecure)} mutableCopy];
    if (_config.tlsSNI.length) ssl[@"kCFStreamSSLPeerName"] = _config.tlsSNI;
    if (insecure) {
        ssl[@"kCFStreamSSLAllowsAnyRoot"] = @YES;
    }
    // Build the certificate chain: mutual-TLS identity (if any) plus an optional CA.
    NSMutableArray *chain = [ARDMMutualTLSChain(_config) mutableCopy] ?: [NSMutableArray array];
    if (_config.tlsCA.length) {
        NSData *ca = [NSData dataWithContentsOfFile:_config.tlsCA];
        if (ca) {
            SecCertificateRef cert = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)ca);
            if (cert) { [chain addObject:(__bridge id)cert]; CFRelease(cert); }
        }
    }
    if (chain.count) ssl[@"kCFStreamSSLCertificates"] = chain;
    CFReadStreamSetProperty(read, kCFStreamPropertySSLSettings, (__bridge CFDictionaryRef)ssl);
    CFWriteStreamSetProperty(write, kCFStreamPropertySSLSettings, (__bridge CFDictionaryRef)ssl);
}

/** Translate a cluster-internal address through the configured NAT map. */
- (NSString *)mappedAddress:(NSString *)host port:(NSInteger)port {
    NSString *key = [NSString stringWithFormat:@"%@:%ld", host, (long)port];
    NSString *mapped = _config.natMap[key];
    if (!mapped) return key;
    return mapped;
}

- (id)sendArguments:(NSArray *)args error:(NSError **)error {
    return [self send:(NSArray<NSString *> *)args error:error];
}

/** CLUSTER SLOTS + CLUSTER NODES, normalised into a displayable topology. */
- (NSDictionary *)clusterTopology:(NSError **)error {
    id slots = [self send:@[@"CLUSTER", @"SLOTS"] error:error];
    NSMutableArray *out = [NSMutableArray array];
    for (id slot in ARDMNormalizeArray(slots)) {
        NSArray *row = ARDMNormalizeArray(slot);
        if (row.count < 3) continue;
        NSArray *master = ARDMNormalizeArray(row[2]);
        NSString *host = master.count > 0 ? ARDMReplyToString(master[0]) : @"";
        NSInteger port = master.count > 1 ? [ARDMReplyToString(master[1]) integerValue] : 0;
        NSMutableArray *replicas = [NSMutableArray array];
        for (NSUInteger i = 3; i < row.count; i++) {
            NSArray *r = ARDMNormalizeArray(row[i]);
            if (r.count > 1) [replicas addObject:[NSString stringWithFormat:@"%@:%@",
                ARDMReplyToString(r[0]), ARDMReplyToString(r[1])]];
        }
        [out addObject:@{@"start": row[0], @"end": row[1],
                         @"master": [self mappedAddress:host port:port],
                         @"replicas": replicas}];
    }
    id nodes = [self send:@[@"CLUSTER", @"NODES"] error:nil];
    NSMutableArray *nodeList = [NSMutableArray array];
    NSString *text = ARDMReplyToString(nodes);
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        NSArray *cols = [line componentsSeparatedByString:@" "];
        if (cols.count > 7) {
            [nodeList addObject:@{@"id": cols[0], @"address": cols[1],
                                  @"flags": cols[2],
                                  @"slots": [cols subarrayWithRange:NSMakeRange(8, cols.count - 8)]}];
        }
    }
    return @{@"slots": out, @"nodes": nodeList};
}

/** Reconnect with linear backoff (300ms * attempt), up to `retryTimes` attempts (default 3). */
- (BOOL)reconnectWithBackoff:(NSError **)error {
    if (!_config.autoReconnect) { if (error) *error = ARDMError(@"Auto reconnect disabled", 12); return NO; }
    NSInteger attempts = _config.retryTimes > 0 ? _config.retryTimes : 3;
    NSError *last = nil;
    for (NSInteger attempt = 1; attempt <= attempts; attempt++) {
        usleep((useconds_t)(300000 * attempt));
        last = nil;
        if ([self connect:&last]) return YES;
    }
    if (error) *error = last ?: ARDMError(@"Reconnect failed", 13);
    return NO;
}

- (BOOL)connect:(NSError **)error {
    [self disconnect];
    _connectHost = _config.host;
    _connectPort = _config.port;
    _effectiveAuth = _config.auth;
    if (_config.sshEnabled) {
        if (![self openSSHtunnel:error]) return NO;
    }
    CFReadStreamRef read = NULL;
    CFWriteStreamRef write = NULL;
    CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)_connectHost, (UInt32)_connectPort, &read, &write);
    if (!read || !write) { if (error) *error = ARDMError(@"Cannot create network stream", 8); return NO; }
    if (_config.tlsEnabled) [self configureTLSForRead:read write:write];
    if (!CFReadStreamOpen(read) || !CFWriteStreamOpen(write)) {
        CFRelease(read); CFRelease(write);
        if (error) *error = ARDMError(@"Cannot open connection to Redis", 9);
        return NO;
    }
    _stream = [[ARDMRESPStream alloc] initWithRead:read write:write];
    self.isConnected = YES;

    if (_config.sentinelEnabled) {
        NSArray *reply = ARDMNormalizeArray([self send:@[@"SENTINEL", @"get-master-addr-by-name", _config.sentinelMaster] error:nil]);
        if (reply.count >= 2) {
            NSString *master = ARDMReplyToString(reply[0]);
            NSInteger masterPort = [ARDMReplyToString(reply[1]) integerValue];
            _effectiveAuth = _config.sentinelNodePassword.length ? _config.sentinelNodePassword : _config.auth;
            [_stream close]; _stream = nil;
            CFReadStreamRef r2 = NULL; CFWriteStreamRef w2 = NULL;
            CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)master, (UInt32)masterPort, &r2, &w2);
            if (_config.tlsEnabled) [self configureTLSForRead:r2 write:w2];
            CFReadStreamOpen(r2); CFWriteStreamOpen(w2);
            _stream = [[ARDMRESPStream alloc] initWithRead:r2 write:w2];
            _connectHost = master; _connectPort = masterPort;
        }
    }

    if (_effectiveAuth.length) {
        NSArray *authArgs = _config.username.length
            ? @[@"AUTH", _config.username, _effectiveAuth]
            : @[@"AUTH", _effectiveAuth];
        NSError *authErr = nil;
        [self send:authArgs error:&authErr];
        if (authErr) { if (error) *error = authErr; [self disconnect]; return NO; }
    }
    if (_config.connectionName.length) [self send:@[@"CLIENT", @"SETNAME", _config.connectionName] error:nil];
    if (_config.db > 0) [self send:@[@"SELECT", [NSString stringWithFormat:@"%ld", (long)_config.db]] error:nil];
    self.selectedDB = _config.db;
    NSError *pingErr = nil;
    [self send:@[@"PING"] error:&pingErr];
    if (pingErr) { if (error) *error = pingErr; [self disconnect]; return NO; }
    return YES;
}

- (void)disconnect {
    [_stream close]; _stream = nil; self.isConnected = NO;
    if (_sshTask) { [_sshTask terminate]; _sshTask = nil; }
}

- (NSString *)hostUsed { return _connectHost ?: _config.host; }
- (NSInteger)portUsed { return _connectPort ?: _config.port; }

static NSData *ARDMEncodeCommand(NSArray *args) {
    NSMutableData *out = [NSMutableData data];
    [out appendData:[[NSString stringWithFormat:@"*%lu\r\n", (unsigned long)args.count] dataUsingEncoding:NSUTF8StringEncoding]];
    for (id arg in args) {
        NSData *d = [arg isKindOfClass:NSData.class] ? arg
                  : [[NSString stringWithFormat:@"%@", arg] dataUsingEncoding:NSUTF8StringEncoding];
        [out appendData:[[NSString stringWithFormat:@"$%lu\r\n", (unsigned long)d.length] dataUsingEncoding:NSUTF8StringEncoding]];
        [out appendData:d];
        [out appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    }
    return out;
}

- (NSArray *)sendTransaction:(NSArray<NSArray<NSString *> *> *)commands error:(NSError **)error {
    if (!_stream) { if (error) *error = ARDMError(@"Not connected", 10); return nil; }
    if (_config.readOnly) {
        if (error) *error = ARDMError(@"You are in readonly mode! Unable to execute MULTI/EXEC!", 11);
        return nil;
    }
    NSMutableArray<NSArray *> *pipeline = [NSMutableArray arrayWithObject:@[@"MULTI"]];
    [pipeline addObjectsFromArray:commands];
    [pipeline addObject:@[@"EXEC"]];
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:pipeline.count];
    for (NSArray *args in pipeline) {
        NSError *inner = nil;
        id reply = [self send:args error:&inner];
        if (inner || !reply) {
            if (error) *error = inner ?: ARDMError(@"Transaction failed", 12);
            // Best effort rollback so the connection is not left inside MULTI.
            if (![args.firstObject isEqual:@"EXEC"]) [self send:@[@"DISCARD"] error:nil];
            return nil;
        }
        [results addObject:reply];
    }
    return results;
}

- (id)send:(NSArray<NSString *> *)args error:(NSError **)error {
    if (!_stream) { if (error) *error = ARDMError(@"Not connected", 10); return nil; }
    NSString *verb = [[args.firstObject uppercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
    NSString *two = args.count >= 2 ? [[NSString stringWithFormat:@"%@ %@", args[0], args[1]] uppercaseString] : verb;
    if (_config.readOnly && ([ARDMWriteCommands() containsObject:verb] || [ARDMWriteCommands() containsObject:two])) {
        if (error) *error = ARDMError(@"You are in readonly mode! Unable to execute write command!", 11);
        return nil;
    }
    NSDate *start = [NSDate date];
    @synchronized (self) {
        NSError *writeErr = nil;
        if (![_stream writeData:ARDMEncodeCommand(args) error:&writeErr]) {
            if (error) *error = writeErr;
            return nil;
        }
        NSError *readErr = nil;
        id reply = [_stream readReply:&readErr];
        if (readErr) {
            NSString *msg = readErr.localizedDescription;
            if ([msg hasPrefix:@"MOVED "] || [msg hasPrefix:@"ASK "]) {
                NSArray *parts = [msg componentsSeparatedByString:@" "];
                NSString *addr = parts.count > 2 ? parts[2] : nil;
                if (addr.length) {
                    // Strip an IPv6 bracket wrapper ([]host]:port) if present, then split on the
                    // LAST colon so IPv6 literals (which contain colons) parse correctly.
                    NSString *clean = addr;
                    if ([clean hasPrefix:@"["]) {
                        NSRange close = [clean rangeOfString:@"]"];
                        if (close.location != NSNotFound)
                            clean = [clean substringWithRange:NSMakeRange(1, close.location - 1)];
                    }
                    NSRange colon = [clean rangeOfString:@":" options:NSBackwardsSearch];
                    NSString *hpHost = colon.location != NSNotFound ? [clean substringToIndex:colon.location] : clean;
                    NSInteger hpPort = colon.location != NSNotFound ? [[clean substringFromIndex:colon.location + 1] integerValue] : _connectPort;
                    NSString *mapped = [self mappedAddress:hpHost port:hpPort];
                    NSRange mcolon = [mapped rangeOfString:@":" options:NSBackwardsSearch];
                    NSString *targetHost = mcolon.location == NSNotFound ? mapped : [mapped substringToIndex:mcolon.location];
                    NSInteger targetPort = mcolon.location == NSNotFound ? hpPort
                        : [[mapped substringFromIndex:mcolon.location + 1] integerValue];
                    BOOL asking = [msg hasPrefix:@"ASK "];
                    if (asking) {
                        // ASK: one-shot redirect. Open a temporary stream, answer ASKING, then
                        // restore the original connection (ASK must not permanently repoint us).
                        CFReadStreamRef r = NULL; CFWriteStreamRef w = NULL;
                        CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)targetHost, (UInt32)targetPort, &r, &w);
                        if (_config.tlsEnabled) [self configureTLSForRead:r write:w];
                        CFReadStreamOpen(r); CFWriteStreamOpen(w);
                        ARDMRESPStream *temp = [[ARDMRESPStream alloc] initWithRead:r write:w];
                        ARDMRESPStream *restore = _stream;
                        _stream = temp;
                        if (_effectiveAuth.length) {
                            NSArray *auth = _config.username.length
                                ? @[@"AUTH", _config.username, _effectiveAuth] : @[@"AUTH", _effectiveAuth];
                            [self send:auth error:nil];
                        }
                        [self send:@[@"ASKING"] error:nil];
                        id retry = [self send:args error:error];
                        _stream = restore;
                        [temp close];
                        return retry;
                    }
                    // MOVED: the slot has migrated; permanently repoint the connection.
                    _connectHost = targetHost; _connectPort = targetPort;
                    CFReadStreamRef r = NULL; CFWriteStreamRef w = NULL;
                    CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)targetHost, (UInt32)targetPort, &r, &w);
                    if (_config.tlsEnabled) [self configureTLSForRead:r write:w];
                    CFReadStreamOpen(r); CFWriteStreamOpen(w);
                    [_stream close];
                    _stream = [[ARDMRESPStream alloc] initWithRead:r write:w];
                    if (_effectiveAuth.length) {
                        NSArray *auth = _config.username.length
                            ? @[@"AUTH", _config.username, _effectiveAuth] : @[@"AUTH", _effectiveAuth];
                        [self send:auth error:nil];
                    }
                    id retry = [self send:args error:error];
                    return retry;
                }
            }
            // Transparent reconnect: one exponential-backoff attempt before surfacing the error.
            if (_config.autoReconnect && !_didRetry) {
                _didRetry = YES;
                NSError *reconnectError = nil;
                if ([self reconnectWithBackoff:&reconnectError]) {
                    id retry = [self send:args error:error];
                    _didRetry = NO;
                    return retry;
                }
                _didRetry = NO;
            }
            if (error) *error = readErr;
            return nil;
        }
        NSString *logged = ARDMCommandLogString(args);
        if (logged) {
            ARDMCommandLog *log = [[ARDMCommandLog alloc] init];
            log.time = [NSDate date];
            log.connectionName = _config.name;
            log.command = logged;
            log.cost = [[NSDate date] timeIntervalSinceDate:start] * 1000.0;
            [self.logs addObject:log];
            if (self.logs.count > self.logLimit) [self.logs removeObjectsInRange:NSMakeRange(0, self.logs.count - self.logLimit)];
            if (self.onLog) self.onLog(log);
        }
        return reply ?: NSNull.null;
    }
}

- (BOOL)isWriteCommand:(NSArray<NSString *> *)args {
    if (args.count == 0) return NO;
    NSString *verb = [[args.firstObject uppercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
    NSString *two = args.count >= 2 ? [[NSString stringWithFormat:@"%@ %@", args[0], args[1]] uppercaseString] : verb;
    return [ARDMWriteCommands() containsObject:verb] || [ARDMWriteCommands() containsObject:two];
}

- (void)asyncSend:(NSArray<NSString *> *)args completion:(void (^)(id, NSError *))completion {
    dispatch_async(_queue, ^{
        NSError *err = nil;
        id reply = [self send:args error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(reply, err); });
    });
}

#pragma mark - Push streams (Pub/Sub, MONITOR)

- (BOOL)liveRunning { return _liveRunning; }

- (void)stopLive {
    _liveRunning = NO;
    ARDMRedisClient *live = _liveClient;
    _liveClient = nil;
    if (live) [live disconnect];
}

- (void)startLiveWithCommand:(NSArray<NSString *> *)args
                     onEvent:(void (^)(NSArray *))onEvent
                     onError:(void (^)(NSString *))onError {
    [self stopLive];
    if (!_liveQueue) _liveQueue = dispatch_queue_create("me.qii404.ardm.live", DISPATCH_QUEUE_SERIAL);
    _liveRunning = YES;
    __weak ARDMRedisClient *weakSelf = self;
    dispatch_async(_liveQueue, ^{
        ARDMRedisClient *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_liveRunning) return;
        // Honour read-only mode on the live stream too: refuse any write verb so the
        // dedicated MONITOR/SUBSCRIBE channel cannot be used to bypass the write lock.
        NSString *liveVerb = [[args.firstObject uppercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
        NSString *liveTwo = args.count >= 2 ? [[NSString stringWithFormat:@"%@ %@", args[0], args[1]] uppercaseString] : liveVerb;
        if (strongSelf->_config.readOnly &&
            ([ARDMWriteCommands() containsObject:liveVerb] || [ARDMWriteCommands() containsObject:liveTwo])) {
            strongSelf->_liveRunning = NO;
            NSString *message = @"You are in readonly mode! Unable to execute write command!";
            dispatch_async(dispatch_get_main_queue(), ^{ onError(message); });
            return;
        }
        ARDMRedisClient *live = [[ARDMRedisClient alloc] initWithConfig:strongSelf->_config];
        NSError *connectError = nil;
        if (![live connect:&connectError]) {
            strongSelf->_liveRunning = NO;
            NSString *message = connectError.localizedDescription ?: @"Cannot open live connection";
            dispatch_async(dispatch_get_main_queue(), ^{ onError(message); });
            return;
        }
        strongSelf->_liveClient = live;
        NSError *writeError = nil;
        @synchronized (live) {
            [live->_stream writeData:ARDMEncodeCommand(args) error:&writeError];
        }
        if (writeError) {
            strongSelf->_liveRunning = NO;
            NSString *message = writeError.localizedDescription;
            dispatch_async(dispatch_get_main_queue(), ^{ onError(message); });
            [live disconnect];
            return;
        }
        while (strongSelf->_liveRunning) {
            @autoreleasepool {
                NSError *readError = nil;
                id reply = nil;
                @synchronized (live) {
                    reply = [live->_stream readReply:&readError];
                }
                if (readError || !reply) break;
                NSArray *event = ARDMNormalizeArray(reply);
                dispatch_async(dispatch_get_main_queue(), ^{ onEvent(event); });
            }
        }
        strongSelf->_liveRunning = NO;
        [live disconnect];
        if (strongSelf->_liveClient == live) strongSelf->_liveClient = nil;
    });
}

- (NSArray<NSString *> *)scanKeysMatching:(NSString *)pattern cursor:(NSUInteger *)cursor count:(NSUInteger)count error:(NSError **)error {
    NSArray *reply = ARDMNormalizeArray([self send:@[@"SCAN", [NSString stringWithFormat:@"%lu", (unsigned long)*cursor],
        @"MATCH", pattern.length ? pattern : @"*", @"COUNT", [NSString stringWithFormat:@"%lu", (unsigned long)count]] error:error]);
    if (reply.count < 2) return @[];
    *cursor = (NSUInteger)[ARDMReplyToString(reply[0]) integerValue];
    NSMutableArray *keys = [NSMutableArray array];
    for (id k in ARDMNormalizeArray(reply[1])) [keys addObject:ARDMReplyToString(k)];
    return keys;
}

- (ARDMKeyType)typeOfKey:(NSString *)key error:(NSError **)error {
    NSString *t = [ARDMReplyToString([self send:@[@"TYPE", key] error:error]) lowercaseString];
    if ([t isEqualToString:@"string"]) return ARDMKeyTypeString;
    if ([t isEqualToString:@"list"]) return ARDMKeyTypeList;
    if ([t isEqualToString:@"set"]) return ARDMKeyTypeSet;
    if ([t isEqualToString:@"zset"]) return ARDMKeyTypeZSet;
    if ([t isEqualToString:@"hash"]) return ARDMKeyTypeHash;
    if ([t isEqualToString:@"stream"]) return ARDMKeyTypeStream;
    if ([t isEqualToString:@"rejson-rl"] || [t isEqualToString:@"rejson"]) return ARDMKeyTypeReJSON;
    if ([t isEqualToString:@"mbbloomcf"] || [t isEqualToString:@"tsdb-type"]) return ARDMKeyTypeTimeSeries;
    if ([t containsString:@"vector"]) return ARDMKeyTypeVector;
    if ([t containsString:@"array"]) return ARDMKeyTypeArray;
    return ARDMKeyTypeUnknown;
}

- (NSInteger)ttlOfKey:(NSString *)key error:(NSError **)error {
    return [ARDMReplyToString([self send:@[@"TTL", key] error:error]) integerValue];
}

- (id)valueOfKey:(NSString *)key type:(ARDMKeyType)type error:(NSError **)error {
    switch (type) {
        case ARDMKeyTypeString: case ARDMKeyTypeReJSON: case ARDMKeyTypeVector:
            return [self send:@[@"GET", key] error:error];
        case ARDMKeyTypeList:
            return [self send:@[@"LRANGE", key, @"0", @"-1"] error:error];
        case ARDMKeyTypeSet:
            return [self send:@[@"SMEMBERS", key] error:error];
        case ARDMKeyTypeZSet:
            return [self send:@[@"ZRANGE", key, @"0", @"-1", @"WITHSCORES"] error:error];
        case ARDMKeyTypeHash:
            return [self send:@[@"HGETALL", key] error:error];
        case ARDMKeyTypeStream:
            return [self send:@[@"XRANGE", key, @"-", @"+"] error:error];
        case ARDMKeyTypeTimeSeries:
            return [self send:@[@"TS.RANGE", key, @"-", @"+"] error:error];
        case ARDMKeyTypeArray:
            return [self send:@[@"ARGET", key, @"0", @"-1"] error:error];
        default:
            return [self send:@[@"GET", key] error:error];
    }
}

- (NSInteger)dbSize:(NSError **)error {
    return [ARDMReplyToString([self send:@[@"DBSIZE"] error:error]) integerValue];
}

- (NSString *)infoSection:(NSString *)section error:(NSError **)error {
    NSArray *args = section.length ? @[@"INFO", section] : @[@"INFO"];
    return ARDMReplyToString([self send:args error:error]);
}
@end
