// Core regression probe: drives ARDMRedisClient against the scripted RESP server
// in fake_redis.py, plus every formatter/localization/keychain surface.
//
// Run it through tests/run.sh — the probe expects argv[1] to be the port the
// fake server is listening on and ARDM_PROJECT_ROOT to point at the checkout so
// it can load src/i18n/langs/*.js and src/commands.js without an .app bundle.
#import "ARDM.h"
#import "Transport.h"
#include <stdio.h>
#include <CoreFoundation/CoreFoundation.h>

static void check(const char *label, BOOL ok, NSString *detail) {
    printf("[%s] %-34s %s\n", ok ? "PASS" : "FAIL", label, [[detail description] UTF8String]);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSInteger port = argc > 1 ? [[NSString stringWithUTF8String:argv[1]] integerValue] : 16379;
        ARDMConnectionConfig *c = [[ARDMConnectionConfig alloc] init];
        c.host = @"127.0.0.1"; c.port = port; c.name = @"verification";
        ARDMRedisClient *client = [[ARDMRedisClient alloc] initWithConfig:c];
        NSError *err = nil;
        BOOL connected = [client connect:&err];
        check("connect / PING", connected && !err, err.localizedDescription ?: @"connected");
        if (!connected) return 1;

        check("GET bulk string", [[client send:@[@"GET", @"str:foo"] error:&err] isEqualToData:[@"bar" dataUsingEncoding:NSUTF8StringEncoding]] ? YES : NO, @"str:foo => bar");
        err = nil;
        check("TYPE", [[client send:@[@"TYPE", @"str:foo"] error:&err] isEqualToString:@"string"] ? YES : NO, @"string");
        err = nil;
        NSArray *scanned = [client scanKeysMatching:@"*" cursor:&(NSUInteger){0} count:500 error:&err];
        check("SCAN cursor + key list", [scanned containsObject:@"str:foo"], [scanned componentsJoinedByString:@","]);
        err = nil;
        check("TTL", [[client send:@[@"TTL", @"str:foo"] error:&err] integerValue] == 3600 ? YES : NO, @"3600");
        err = nil;
        check("HGETALL array", [[client send:@[@"HGETALL", @"hash:h"] error:&err] isKindOfClass:NSArray.class] ? YES : NO, @"array reply");
        err = nil;
        check("SET allowed (read-write)", [[client send:@[@"SET", @"str:foo", @"baz"] error:&err] isEqualToString:@"OK"] ? YES : NO, @"OK");
        err = nil;
        // Regression: the editor save path sends the encoded value as raw Data.
        // The command-log builder used to call -substringToIndex: on it (NSData
        // answers -length with its byte count) and the process aborted with
        // "unrecognized selector sent to instance". >200 bytes so the old
        // truncation branch is exercised too.
        NSMutableData *payload = [NSMutableData dataWithCapacity:300];
        for (int i = 0; i < 300; i++) [payload appendBytes:"\x89PNGbinary" length:10];
        id binReply = [client send:(NSArray *)@[@"SET", @"bin:payload", payload] error:&err];
        check("SET raw Data payload (save path)", [binReply isEqual:@"OK"] || (binReply && !err) ? YES : NO,
              err.localizedDescription ?: [NSString stringWithFormat:@"reply=%@", binReply]);
        err = nil;
        NSInteger size = [client dbSize:&err];
        check("DBSIZE", size == 3 ? YES : NO, [NSString stringWithFormat:@"%ld", (long)size]);
        err = nil;
        NSString *info = [client infoSection:@"server" error:&err];
        check("INFO section", [info containsString:@"redis_version"] ? YES : NO, @"contains redis_version");
        err = nil;
        check("Command log recorded", client.logs.count >= 8 ? YES : NO,
              [NSString stringWithFormat:@"%lu entries", (unsigned long)client.logs.count]);
        [client disconnect];

        ARDMConnectionConfig *ro = [[ARDMConnectionConfig alloc] init];
        ro.host = @"127.0.0.1"; ro.port = port; ro.readOnly = YES;
        ARDMRedisClient *roClient = [[ARDMRedisClient alloc] initWithConfig:ro];
        NSError *roErr = nil;
        [roClient connect:nil];
        id blocked = [roClient send:@[@"SET", @"k", @"v"] error:&roErr];
        check("Read-only blocks write", blocked == nil && roErr.code == 11, roErr.localizedDescription ?: @"no error");
        [roClient disconnect];

        NSData *json = [@"{\"a\":1,\"b\":[2,3]}" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *rendered = [ARDMFormatters render:json as:@"Json" error:nil];
        check("Viewer: Json", [rendered containsString:@"\"a\""] ? YES : NO, @"pretty printed");
        check("Viewer: Hex", [[ARDMFormatters render:json as:@"Hex" error:nil] containsString:@"7b"] ? YES : NO, @"hex dump");
        const UInt8 gzipMagic[2] = {0x1f, 0x8b};
        NSData *gzipSample = [NSData dataWithBytes:gzipMagic length:2];
        check("Viewer: detect gzip", [[ARDMFormatters detectViewerForData:gzipSample] isEqualToString:@"Gzip"] ? YES : NO, @"Gzip");
        check("Viewer: msgpack", [[ARDMFormatters render:[NSData dataWithBytes:(const UInt8[]){0x92, 0x01, 0xa3, 'f', 'o', 'o'} length:6] as:@"Msgpack" error:nil] containsString:@"foo"] ? YES : NO, @"[1, foo]");
        check("Viewer: custom (JavaScriptCore)", [[ARDMFormatters renderCustom:json script:@"return bytes.length;" error:nil] isEqualToString:@"17"] ? YES : NO, @"byte length via JS");

        ARDMLocalization *loc = [ARDMLocalization shared];
        check("Localization: 13 languages loaded", loc.languages.count == 13 ? YES : NO,
              [NSString stringWithFormat:@"%lu", (unsigned long)loc.languages.count]);
        loc.currentLanguage = @"cn";
        NSString *translated = [loc t:@"message.host"];
        check("Localization: cn table usable", ![translated isEqualToString:@"message.host"], translated);
        NSInteger resolvedTables = 0;
        NSMutableArray<NSString *> *samples = [NSMutableArray array];
        for (NSString *code in loc.languages) {
            loc.currentLanguage = code;
            NSString *translatedLabel = [loc t:@"message.new_connection"];
            // t: falls back to the key when a table failed to load, so an exact
            // match means "missing table", not a valid translation.
            BOOL loaded = ![translatedLabel isEqualToString:@"message.new_connection"]
                          && ![translatedLabel isEqualToString:@"New Connection"];
            if (loaded) resolvedTables++;
            [samples addObject:[NSString stringWithFormat:@"%@=%@", code, translatedLabel]];
        }
        check("Localization: 12 non-en tables resolve", resolvedTables == 12,
              [samples componentsJoinedByString:@" "]);
        loc.currentLanguage = @"cn";

        // ---- New transport-layer capabilities ----
        ARDMConnectionConfig *c2 = [[ARDMConnectionConfig alloc] init];
        c2.host = @"127.0.0.1"; c2.port = port; c2.name = @"transport-probe";
        c2.natMap = @{@"10.0.0.1:6379": @"203.0.113.9:6380"};
        c2.autoReconnect = YES;
        ARDMRedisClient *c2Client = [[ARDMRedisClient alloc] initWithConfig:c2];
        NSError *e2 = nil;
        check("Reconnect/backoff capable config", [c2Client connect:&e2], e2.localizedDescription ?: @"connected");

        e2 = nil;
        NSData *binaryKey = [@"str:foo" dataUsingEncoding:NSUTF8StringEncoding];
        id binaryReply = [c2Client sendArguments:@[@"GET", binaryKey] error:&e2];
        check("Binary arguments (NSData)", [binaryReply isEqualToData:[@"bar" dataUsingEncoding:NSUTF8StringEncoding]] ? YES : NO, @"GET <NSData> => bar");

        e2 = nil;
        NSDictionary *topology = [c2Client clusterTopology:&e2];
        NSArray *slots = topology[@"slots"] ?: @[];
        NSString *master = slots.count ? slots[0][@"master"] : @"";
        check("Cluster SLOTS + NODES topology", slots.count == 1 && [topology[@"nodes"] count] == 1,
              [NSString stringWithFormat:@"%lu slots", (unsigned long)slots.count]);
        check("Cluster NAT mapping applied", [master isEqualToString:@"203.0.113.9:6380"], master);

        e2 = nil;
        check("Reconnect with backoff", [c2Client reconnectWithBackoff:&e2], e2.localizedDescription ?: @"reconnected");

        NSArray *viewers = [ARDMFormatters viewerNames];
        BOOL allViewers = YES;
        for (NSString *viewer in viewers) {
            NSString *out = [ARDMFormatters render:json as:viewer error:nil];
            if (!out) allViewers = NO;
        }
        check("All 15 viewers render without crash", viewers.count == 15 && allViewers,
              [NSString stringWithFormat:@"%lu viewers", (unsigned long)viewers.count]);

        check("Font enumeration (font-list)", [ARDMAppServices availableFonts].count > 10,
              [NSString stringWithFormat:@"%lu families", (unsigned long)[ARDMAppServices availableFonts].count]);
        check("Command reference (commands.js)", [ARDMAppServices commandReference].count > 100,
              [NSString stringWithFormat:@"%lu commands", (unsigned long)[ARDMAppServices commandReference].count]);

        NSArray *formatters = @[@{@"name": @"probe", @"script": @"return bytes.length;"}];
        [ARDMAppServices saveCustomFormatters:formatters];
        check("Custom formatter persistence", [[ARDMAppServices customFormatters].firstObject[@"name"] isEqualToString:@"probe"], @"saved + reloaded");
        check("Connection JSON export", [[ARDMAppServices exportConnectionsJSON] hasPrefix:@"["], @"JSON array");

        NSURL *tempURL = [NSURL fileURLWithPath:NSTemporaryDirectory()];
        NSData *bookmark = [ARDMAppServices bookmarkForURL:tempURL];
        NSURL *resolved = bookmark ? [ARDMAppServices resolveBookmark:bookmark] : nil;
        check("Security-scoped bookmark", bookmark != nil && resolved != nil, [resolved path] ?: NSTemporaryDirectory());

        // ---- Pub/Sub + MONITOR live streams ----
        __block int events = 0;
        [c2Client startLiveWithCommand:@[@"SUBSCRIBE", @"channel"]
                              onEvent:^(NSArray *rows) { if (rows.count) events++; }
                              onError:^(NSString *message) { printf("  live error: %s\n", [message UTF8String]); }];
        // Callbacks dispatch to the main queue; drain it via the main run loop.
        for (int i = 0; i < 100 && events == 0; i++) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        }
        BOOL liveOK = events > 0;
        check("Pub/Sub live push stream", liveOK, [NSString stringWithFormat:@"%d events", events]);
        [c2Client stopLive];
        check("Live stream stop", !c2Client.liveRunning, @"stopped");

        // ---- New feature parity checks ----
        e2 = nil;
        NSString *jsonText = @"{\"name\":\"foo\",\"n\":42,\"list\":[1,2]}";
        NSData *mp = [ARDMFormatters encode:jsonText as:@"Msgpack" error:&e2];
        NSString *mpBack = [ARDMFormatters render:mp as:@"Msgpack" error:nil];
        check("Msgpack encode -> decode", mp.length > 0 && [mpBack containsString:@"foo"] && [mpBack containsString:@"42"],
              [NSString stringWithFormat:@"%lu bytes", (unsigned long)mp.length]);

        NSData *php = [ARDMFormatters encode:jsonText as:@"PHPSerialize" error:&e2];
        NSString *phpBack = [ARDMFormatters render:php as:@"PHPSerialize" error:nil];
        check("PHP serialize encode -> decode", [phpBack containsString:@"foo"],
              [[NSString alloc] initWithData:php encoding:NSUTF8StringEncoding] ?: @"");

        NSString *plain = @"hello compression";
        for (NSString *codec in @[@"Gzip", @"Deflate", @"DeflateRaw"]) {
            NSData *packed = [ARDMFormatters encode:plain as:codec error:nil];
            NSString *unpacked = [ARDMFormatters render:packed as:codec error:nil];
            check([[NSString stringWithFormat:@"%@ encode -> decode", codec] UTF8String],
                  [unpacked isEqualToString:plain], [NSString stringWithFormat:@"%lu bytes", (unsigned long)packed.length]);
        }

        NSData *sample = [@"Hello" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *hexDump = [ARDMFormatters render:sample as:@"Hex" error:nil];
        NSData *hexBack = [ARDMFormatters encode:hexDump as:@"Hex" error:nil];
        check("Hex dump -> bytes", [hexBack isEqualToData:sample], hexDump.lastPathComponent ?: @"hex");
        NSString *binDump = [ARDMFormatters render:sample as:@"Binary" error:nil];
        NSData *binBack = [ARDMFormatters encode:binDump as:@"Binary" error:nil];
        check("Binary dump -> bytes", [binBack isEqualToData:sample], @"01001000 ...");

        NSString *big = @"{\"id\":123456789012345678901}";
        NSData *bigData = [ARDMFormatters encode:big as:@"Json" error:nil];
        check("Json BigInt preserved verbatim", [bigData isEqualToData:[big dataUsingEncoding:NSUTF8StringEncoding]], big);
        check("12 viewers support write-back", [ARDMFormatters encodableViewers].count == 12,
              [NSString stringWithFormat:@"%lu", (unsigned long)[ARDMFormatters encodableViewers].count]);

        [ARDMFormatters setProtobufSchema:@{@1: @"user_name"}];
        const unsigned char pbBytes[] = {0x08, 0x07};
        NSData *pb = [NSData dataWithBytes:pbBytes length:2];
        NSString *pbOut = [ARDMFormatters render:pb as:@"Protobuf" error:nil];
        check("Protobuf schema field names", [pbOut containsString:@"user_name"], pbOut);

        // Scoped .proto schema: nested message + repeated field.
        NSDictionary *pbScopes = @{
            @"User": @{ @1: @"varint|id", @2: @"string|name",
                        @3: @"message|address|User.Address", @4: @"varint|tag" },
            @"User.Address": @{ @1: @"string|city" },
        };
        [ARDMFormatters setProtobufScopes:pbScopes root:@"User"];
        const unsigned char nestedBytes[] = {
            0x08, 0x07,                         // id = 7
            0x12, 0x03, 0x62, 0x6F, 0x62,       // name = "bob"
            0x1A, 0x04, 0x0A, 0x02, 0x4E, 0x59, // address { city = "NY" }
            0x20, 0x01, 0x20, 0x02,             // tag = [1, 2]
        };
        NSData *nested = [NSData dataWithBytes:nestedBytes length:sizeof(nestedBytes)];
        NSString *nestedOut = [ARDMFormatters render:nested as:@"Protobuf" error:nil];
        check("Protobuf nested message decoded",
              [nestedOut containsString:@"\"city\" : \"NY\""] ? YES : NO, nestedOut);
        check("Protobuf repeated field becomes an array",
              [nestedOut containsString:@"\"tag\" : [" ] ? YES : NO, nestedOut);

        NSString *jsonInput = @"{\"id\":7,\"name\":\"bob\",\"address\":{\"city\":\"NY\"},\"tag\":[1,2]}";
        NSError *pbErr = nil;
        NSData *reencoded = [ARDMFormatters encode:jsonInput as:@"Protobuf" error:&pbErr];
        NSDictionary *roundTrip = nil;
        if (reencoded.length) {
            NSString *again = [ARDMFormatters render:reencoded as:@"Protobuf" error:nil];
            roundTrip = [NSJSONSerialization JSONObjectWithData:[again dataUsingEncoding:NSUTF8StringEncoding]
                                                        options:0 error:nil];
        }
        check("Protobuf JSON writes back to wire",
              [roundTrip[@"id"] isEqual:@7] && [roundTrip[@"name"] isEqual:@"bob"]
              && [roundTrip[@"address"][@"city"] isEqual:@"NY"] ? YES : NO,
              pbErr.localizedDescription ?: [reencoded description]);

        // OverSize viewer pages through a 10 KB value instead of clipping at 4 KB.
        NSMutableData *bigValue = [NSMutableData data];
        for (NSUInteger i = 0; i < 10000; i++) { unsigned char b = (unsigned char)(i & 0xFF); [bigValue appendBytes:&b length:1]; }
        NSString *chunk = [ARDMFormatters render:bigValue as:@"OverSize" offset:4096 length:4096 error:nil];
        check("OverSize viewer pages by offset",
              [chunk containsString:@"Bytes 4096"] && [chunk containsString:@"of 10000"] ? YES : NO,
              [chunk componentsSeparatedByString:@"\n"].firstObject);

        e2 = nil;
        NSArray *tx = [c2Client sendTransaction:@[@[@"SET", @"a", @"1"], @[@"INCR", @"counter"]] error:&e2];
        check("MULTI / QUEUED / EXEC", tx.count == 4 && [tx.lastObject isKindOfClass:NSArray.class],
              [NSString stringWithFormat:@"%lu replies", (unsigned long)tx.count]);

        // ---- MULTI ... EXEC must be one critical section ----
        // A second thread hammers PING while a 60-command transaction runs. The
        // gap that matters is the one between two send: round-trips — the lock in
        // send: is released there, so without a transaction-wide lock a PING gets
        // written inside the transaction, the server queues it, and it comes back
        // as "QUEUED" instead of "PONG".
        {
            ARDMConnectionConfig *txCfg = [[ARDMConnectionConfig alloc] init];
            txCfg.host = @"127.0.0.1"; txCfg.port = port; txCfg.name = @"tx-probe";
            ARDMRedisClient *txClient = [[ARDMRedisClient alloc] initWithConfig:txCfg];
            NSError *txErr = nil;
            [txClient connect:&txErr];

            NSMutableArray<NSArray *> *txCommands = [NSMutableArray array];
            for (int i = 0; i < 60; i++) {
                [txCommands addObject:@[@"SET", [NSString stringWithFormat:@"tx:probe:%d", i], @"1"]];
            }

            __block BOOL txRunning = YES;
            __block NSArray *txReplies = nil;
            NSMutableArray *pingReplies = [NSMutableArray array];
            dispatch_group_t group = dispatch_group_create();

            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                // Hammer until the transaction has finished.
                while (txRunning && pingReplies.count < 4000) {
                    id reply = [txClient send:@[@"PING"] error:nil];
                    [pingReplies addObject:reply ?: @"nil"];
                }
            });
            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSError *inner = nil;
                txReplies = [txClient sendTransaction:txCommands error:&inner];
                txRunning = NO;
            });
            long timedOut = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
            check("transaction finishes while another thread hammers PING", timedOut == 0,
                  [NSString stringWithFormat:@"%lu pings", (unsigned long)pingReplies.count]);

            NSError *seqErr = nil;
            NSArray *seq = [txClient send:@[@"PROBE.SEQ"] error:&seqErr];
            NSMutableArray<NSString *> *verbs = [NSMutableArray array];
            for (id item in seq) {
                [verbs addObject:[item isKindOfClass:NSString.class] ? item
                    : ([[NSString alloc] initWithData:item encoding:NSUTF8StringEncoding] ?: @"?")];
            }
            NSUInteger multiAt = NSNotFound;
            for (NSUInteger i = verbs.count; i > 0; i--) {
                if ([verbs[i - 1] isEqualToString:@"MULTI"]) { multiAt = i - 1; break; }
            }
            NSUInteger execAt = NSNotFound;
            for (NSUInteger i = (multiAt == NSNotFound ? 0 : multiAt); i < verbs.count; i++) {
                if ([verbs[i] isEqualToString:@"EXEC"]) { execAt = i; break; }
            }
            BOOL interleaved = NO;
            if (multiAt == NSNotFound || execAt == NSNotFound) {
                interleaved = YES;   // a transaction that never opened is just as wrong
            } else {
                for (NSUInteger i = multiAt + 1; i < execAt; i++) {
                    if ([verbs[i] isEqualToString:@"PING"]) interleaved = YES;
                }
            }
            NSString *detail = [NSString stringWithFormat:@"%lu pings, %lu tx replies",
                                (unsigned long)pingReplies.count, (unsigned long)txReplies.count];
            if (interleaved && multiAt != NSNotFound) {
                NSRange window = NSMakeRange(multiAt, MIN((NSUInteger)10, verbs.count - multiAt));
                detail = [[verbs subarrayWithRange:window] componentsJoinedByString:@" "];
            }
            check("PING cannot interleave into MULTI...EXEC", !interleaved, detail);

            NSUInteger queued = 0;
            for (id reply in pingReplies) {
                if (![reply isKindOfClass:NSString.class] || ![reply isEqualToString:@"PONG"]) queued++;
            }
            check("no PING is answered with QUEUED", queued == 0,
                  [NSString stringWithFormat:@"%lu non-PONG replies", (unsigned long)queued]);
            check("transaction still returns its own replies",
                  txReplies.count == txCommands.count + 2
                      && [txReplies.lastObject isKindOfClass:NSArray.class],
                  [NSString stringWithFormat:@"%lu replies", (unsigned long)txReplies.count]);
            [txClient disconnect];
        }

        e2 = nil;
        id hscan = [c2Client send:@[@"HSCAN", @"hash:h", @"0", @"COUNT", @"10"] error:&e2];
        check("HSCAN cursor streaming", [hscan isKindOfClass:NSArray.class] && [hscan count] == 2, @"cursor + flat array");

        // ---- Security: AUTH password must never appear in the command log ----
        ARDMConnectionConfig *authC = [[ARDMConnectionConfig alloc] init];
        authC.host = @"127.0.0.1"; authC.port = port; authC.name = @"auth-probe"; authC.auth = @"supersecret";
        ARDMRedisClient *authClient = [[ARDMRedisClient alloc] initWithConfig:authC];
        NSError *ae = nil;
        [authClient connect:&ae];
        [authClient send:@[@"GET", @"str:foo"] error:&ae];
        BOOL leaked = NO, masked = NO;
        for (ARDMCommandLog *lg in authClient.logs) {
            if ([lg.command containsString:@"supersecret"]) leaked = YES;
            if ([lg.command isEqualToString:@"AUTH ***"]) masked = YES;
        }
        check("AUTH password not leaked in log", !leaked, leaked ? @"LEAK" : @"no plaintext");
        check("AUTH masked as 'AUTH ***'", masked, masked ? @"masked" : @"not found");
        [authClient disconnect];

        // ---- Read-only must also block two-token administrative commands ----
        ARDMConnectionConfig *ro3 = [[ARDMConnectionConfig alloc] init];
        ro3.host = @"127.0.0.1"; ro3.port = port; ro3.name = @"ro2"; ro3.readOnly = YES;
        ARDMRedisClient *roClient3 = [[ARDMRedisClient alloc] initWithConfig:ro3];
        [roClient3 connect:nil];
        NSError *re1 = nil, *re2 = nil;
        id b1 = [roClient3 send:@[@"CONFIG", @"SET", @"foo", @"bar"] error:&re1];
        id b2 = [roClient3 send:@[@"CLIENT", @"KILL", @"1"] error:&re2];
        check("Read-only blocks CONFIG SET", b1 == nil && re1 != nil, re1.localizedDescription ?: @"blocked");
        check("Read-only blocks CLIENT KILL", b2 == nil && re2 != nil, re2.localizedDescription ?: @"blocked");
        [roClient3 disconnect];

        // ---- Cluster MOVED redirect (IPv4 + IPv6 literal) ----
        // Use a dedicated client; the MOVED reply permanently repoints the connection,
        // so we must not contaminate c2Client (still used for HTTL/PTTL/RESTORE).
        ARDMConnectionConfig *redirC = [[ARDMConnectionConfig alloc] init];
        redirC.host = @"127.0.0.1"; redirC.port = port; redirC.name = @"moved-probe";
        ARDMRedisClient *redirClient = [[ARDMRedisClient alloc] initWithConfig:redirC];
        NSError *me = nil;
        [redirClient connect:&me];
        e2 = nil;
        id redirected = [redirClient send:@[@"GET", @"redirect:probe"] error:&e2];
        check("MOVED redirect followed (IPv4)", [redirected isEqualToData:[@"cross-node-ok" dataUsingEncoding:NSUTF8StringEncoding]], [redirected description]);
        e2 = nil;
        id redirected6 = [redirClient send:@[@"GET", @"ipv6:probe"] error:&e2];
        check("MOVED IPv6 address parsed", [redirected6 isEqualToData:[@"cross-node-ok" dataUsingEncoding:NSUTF8StringEncoding]], [redirected6 description]);
        [redirClient disconnect];

        e2 = nil;
        id httl = [c2Client send:@[@"HTTL", @"hash:h", @"FIELDS", @"1", @"f1"] error:&e2];
        check("HTTL field TTL", [httl isKindOfClass:NSArray.class], [httl description]);
        e2 = nil;
        id pttl = [c2Client send:@[@"PTTL", @"str:foo"] error:&e2];
        check("PTTL milliseconds", [pttl integerValue] == 3600000, [pttl description]);
        e2 = nil;
        NSData *dumpPayload = [NSData dataWithBytes:(const uint8_t[]){0x00, 0x01, 0x02} length:3];
        id restored = [c2Client sendArguments:@[@"RESTORE", @"k", @"0", dumpPayload, @"REPLACE"] error:&e2];
        check("RESTORE binary DUMP payload", [restored isEqualToString:@"OK"], [restored description]);

        ARDMConnectionConfig *roConfig = [[ARDMConnectionConfig alloc] init];
        roConfig.host = @"127.0.0.1"; roConfig.port = port; roConfig.name = @"readonly";
        roConfig.readOnly = YES;
        ARDMRedisClient *roClient2 = [[ARDMRedisClient alloc] initWithConfig:roConfig];
        NSError *roErr2 = nil;
        [roClient2 connect:&roErr2];
        NSError *blockError = nil;
        id blockedReply = [roClient2 send:@[@"HEXPIRE", @"hash:h", @"60", @"FIELDS", @"1", @"f1"] error:&blockError];
        check("Read-only blocks HEXPIRE", blockedReply == nil && blockError != nil, blockError.localizedDescription ?: @"blocked");
        blockError = nil;
        [roClient2 send:@[@"RESTORE", @"k", @"0", @"x", @"REPLACE"] error:&blockError];
        check("Read-only blocks RESTORE", blockError != nil, blockError.localizedDescription ?: @"blocked");
        [roClient2 disconnect];

        // ---- Round 5: integer precision, write detection, real deserializers, viewer detection ----
        e2 = nil;
        id bigIntReply = [c2Client send:@[@"BIGINT"] error:&e2];
        check("RESP integer > INT64 keeps digits",
              [bigIntReply isKindOfClass:NSString.class] && [bigIntReply isEqualToString:@"9223372036854775808"],
              [bigIntReply description]);

        check("isWriteCommand FAILOVER = YES", [c2Client isWriteCommand:@[@"FAILOVER"]] ? YES : NO, @"admin write");
        check("isWriteCommand GET = NO", ![c2Client isWriteCommand:@[@"GET", @"x"]] ? YES : NO, @"read command");

        const unsigned char javaBytes[] = {0xAC,0xED,0x00,0x05,0x74,0x00,0x03,'f','o','o'};
        NSData *java = [NSData dataWithBytes:javaBytes length:sizeof(javaBytes)];
        NSString *javaOut = [ARDMFormatters render:java as:@"JavaSerialize" error:nil];
        check("Java stream deserialized", [javaOut containsString:@"foo"], javaOut);

        // TC_OBJECT + TC_CLASSDESC("A", 1 int field x) + classdata(42)
        const unsigned char javaObj[] = {0xAC,0xED,0x00,0x05,0x73,0x72,0x00,0x01,'A',
            0,0,0,0,0,0,0,0, 0x02, 0x00,0x01, 0x49, 0x00,0x01,'x', 0x78, 0x70, 0x00,0x00,0x00,0x2A};
        NSString *javaObjOut = [ARDMFormatters render:[NSData dataWithBytes:javaObj length:sizeof(javaObj)]
                                                   as:@"JavaSerialize" error:nil];
        check("Java object fields decoded", [javaObjOut containsString:@"x (field I) = 42"], javaObjOut);

        const unsigned char pickleBytes[] = {0x80,0x04,0x95,0,0,0,0,0,0,0,0,0x8C,0x05,'h','e','l','l','o',0x94,0x2E};
        NSData *pickle = [NSData dataWithBytes:pickleBytes length:sizeof(pickleBytes)];
        NSString *pickleOut = [ARDMFormatters render:pickle as:@"Pickle" error:nil];
        check("Pickle deserialized", [pickleOut containsString:@"hello"], @"SHORT_BINUNICODE");

        check("detect Brotli", [[ARDMFormatters detectViewerForData:[NSData dataWithBytes:(const unsigned char[]){0xCE,0xB2,0x81} length:3]] isEqualToString:@"Brotli"] ? YES : NO, @"ce b2 81");
        check("detect PHP serialize", [[ARDMFormatters detectViewerForData:[@"a:1:{s:1:\"x\";i:1;}" dataUsingEncoding:NSUTF8StringEncoding]] isEqualToString:@"PHPSerialize"] ? YES : NO, @"a:1:{...}");
        check("detect Deflate", [[ARDMFormatters detectViewerForData:[NSData dataWithBytes:(const unsigned char[]){0x78,0x9C,0x00,0x00} length:4]] isEqualToString:@"Deflate"] ? YES : NO, @"78 9c");
        check("detect DeflateRaw", [[ARDMFormatters detectViewerForData:[NSData dataWithBytes:(const unsigned char[]){0x03,0x00,0x01} length:3]] isEqualToString:@"DeflateRaw"] ? YES : NO, @"raw deflate block");
        check("detect Protobuf", [[ARDMFormatters detectViewerForData:[NSData dataWithBytes:(const unsigned char[]){0x08,0x07} length:2]] isEqualToString:@"Protobuf"] ? YES : NO, @"field 1 varint");

        // ---- Round 6: Keychain secrets + token-preserving JSON ----
        NSData *jsonData = [@"{\"big\":123456789012345678901,\"s\":\"x\"}" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *pretty = [ARDMFormatters formatJSON:jsonData pretty:YES];
        check("formatJSON keeps 21-digit integer",
              [pretty containsString:@"123456789012345678901"] ? YES : NO, pretty);
        NSString *compact = [ARDMFormatters formatJSON:jsonData pretty:NO];
        check("minifyJSON keeps 21-digit integer",
              [compact isEqualToString:@"{\"big\":123456789012345678901,\"s\":\"x\"}"] ? YES : NO, compact);

        NSData *scalarData = [@"123456789012345678901" dataUsingEncoding:NSUTF8StringEncoding];
        check("formatJSON keeps bare big-number scalar",
              [[ARDMFormatters formatJSON:scalarData pretty:NO] isEqualToString:@"123456789012345678901"] ? YES : NO, @"scalar");
        check("Json viewer keeps big-number scalar",
              [[ARDMFormatters render:scalarData as:@"Json" error:nil] isEqualToString:@"123456789012345678901"] ? YES : NO, @"render");

        check("validateJSON accepts object",
              [ARDMFormatters validateJSON:jsonData] ? YES : NO, @"valid");
        check("validateJSON rejects unclosed object",
              ![ARDMFormatters validateJSON:[@"{\"a\":1" dataUsingEncoding:NSUTF8StringEncoding]] ? YES : NO, @"unclosed");
        check("validateJSON rejects mismatched brackets",
              ![ARDMFormatters validateJSON:[@"{\"a\":[1}]" dataUsingEncoding:NSUTF8StringEncoding]] ? YES : NO, @"mismatch");
        check("validateJSON rejects unterminated string",
              ![ARDMFormatters validateJSON:[@"{\"a\":\"x}" dataUsingEncoding:NSUTF8StringEncoding]] ? YES : NO, @"unterminated");

        ARDMConnectionConfig *secretCfg = [[ARDMConnectionConfig alloc] init];
        secretCfg.auth = @"pw";
        secretCfg.sshPassword = @"sshpw";
        secretCfg.sshPassphrase = @"phrase";
        secretCfg.sentinelNodePassword = @"sentinelpw";
        NSDictionary *redacted = [secretCfg toDictionary];
        check("toDictionary redacts every secret",
              ([redacted[@"auth"] length] == 0 && [redacted[@"sshPassword"] length] == 0 &&
               [redacted[@"sshPassphrase"] length] == 0 && [redacted[@"sentinelNodePassword"] length] == 0) ? YES : NO,
              @"no plaintext");
        check("toDictionary records hasStoredSecret",
              [redacted[@"hasStoredSecret"] boolValue] ? YES : NO, @"hasStoredSecret=1");

        NSString *account = @"ardm-verify/auth";
        [ARDMKeychain deleteSecretForAccount:account];
        BOOL stored = [ARDMKeychain setSecret:@"s3cret" forAccount:account];
        NSString *fetched = [ARDMKeychain secretForAccount:account];
        check("Keychain stores and returns a secret",
              stored && [fetched isEqualToString:@"s3cret"] ? YES : NO, fetched ?: @"nil");
        check("Keychain reports existence",
              [ARDMKeychain hasSecretForAccount:account] ? YES : NO, @"present");
        BOOL removed = [ARDMKeychain deleteSecretForAccount:account];
        check("Keychain deletes a secret",
              removed && [ARDMKeychain secretForAccount:account] == nil ? YES : NO, @"gone");

        ARDMConnectionConfig *persistCfg = [[ARDMConnectionConfig alloc] init];
        persistCfg.auth = @"keepme";
        NSString *authAccount = [NSString stringWithFormat:@"%@/auth", persistCfg.identifier];
        [ARDMKeychain deleteSecretForAccount:authAccount];
        NSDictionary *fallback = [persistCfg persistenceDictionary];
        check("persistenceDictionary keeps a secret the Keychain refused",
              [fallback[@"auth"] isEqualToString:@"keepme"] ? YES : NO, @"fallback to file");
        [ARDMKeychain setSecret:persistCfg.auth forAccount:authAccount];
        NSDictionary *redacted2 = [persistCfg persistenceDictionary];
        check("persistenceDictionary redacts once the Keychain has it",
              [redacted2[@"auth"] length] == 0 ? YES : NO, @"redacted");
        [ARDMKeychain deleteSecretForAccount:authAccount];

        // Legacy plaintext hydration (the path loadAll takes on first launch).
        ARDMConnectionConfig *legacy = [ARDMConnectionConfig fromDictionary:@{
            @"identifier": @"probe-migrate", @"name": @"probe", @"host": @"127.0.0.1",
            @"port": @6379, @"auth": @"legacypw", @"sshPassword": @"sshpw",
        }];
        NSDictionary *legacySource = @{@"auth": @"legacypw", @"sshPassword": @"sshpw"};
        BOOL migrated = [legacy hydrateSecretsFromKeychain:legacySource];
        check("legacy plaintext hydrates the in-memory config",
              migrated && [legacy.auth isEqualToString:@"legacypw"] && [legacy.sshPassword isEqualToString:@"sshpw"] ? YES : NO,
              [NSString stringWithFormat:@"auth=%@ ssh=%@", legacy.auth, legacy.sshPassword]);
        check("hydrated config still redacts its snapshot",
              [[legacy toDictionary][@"auth"] length] == 0 ? YES : NO, @"redacted");

        // The migration counter is consumed once and then resets.
        NSInteger firstCount = [ARDMConnectionConfig consumeKeychainMigrationCount];
        NSInteger secondCount = [ARDMConnectionConfig consumeKeychainMigrationCount];
        check("migration counter is consumed once",
              secondCount == 0 ? YES : NO,
              [NSString stringWithFormat:@"first=%ld second=%ld", (long)firstCount, (long)secondCount]);

        [c2Client disconnect];
    }
    return 0;
}
