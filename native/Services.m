#import "ARDM.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <zlib.h>
#import <ctype.h>

#pragma mark - Format viewers (mirrors src/components/viewers/*.vue + src/util.js)

static NSString *ARDMHexDump(NSData *data) {
    const unsigned char *p = data.bytes;
    NSUInteger n = data.length;
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger off = 0; off < n; off += 16) {
        NSMutableString *ascii = [NSMutableString string];
        [out appendFormat:@"%08lx  ", (unsigned long)off];
        for (NSUInteger i = 0; i < 16; i++) {
            if (off + i < n) {
                [out appendFormat:@"%02x ", p[off + i]];
                unsigned char c = p[off + i];
                [ascii appendString:(c >= 32 && c <= 126) ? [NSString stringWithFormat:@"%c", c] : @"."];
            } else { [out appendString:@"   "]; }
        }
        [out appendFormat:@" |%@|\n", ascii];
    }
    return out;
}

static NSString *ARDMBinaryDump(NSData *data) {
    const unsigned char *p = data.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:data.length * 9];
    for (NSUInteger i = 0; i < data.length; i++) {
        for (int b = 7; b >= 0; b--) [out appendString:(p[i] & (1 << b)) ? @"1" : @"0"];
        [out appendString:(i % 4 == 3) ? @"\n" : @" "];
    }
    return out;
}

static NSData *ARDMInflate(NSData *data, int windowBits) {
    z_stream s; memset(&s, 0, sizeof(s));
    if (inflateInit2(&s, windowBits) != Z_OK) return nil;
    s.next_in = (Bytef *)data.bytes;
    s.avail_in = (uInt)data.length;
    NSMutableData *out = [NSMutableData dataWithLength:65536];
    NSMutableData *result = [NSMutableData data];
    int status;
    do {
        s.next_out = (Bytef *)out.mutableBytes;
        s.avail_out = (uInt)out.length;
        status = inflate(&s, Z_NO_FLUSH);
        [result appendBytes:out.bytes length:out.length - s.avail_out];
        if (status != Z_OK && status != Z_STREAM_END) { inflateEnd(&s); return nil; }
    } while (status != Z_STREAM_END && s.avail_in > 0);
    inflateEnd(&s);
    return result;
}


#pragma mark - Encoders (write-back path, mirrors the Vue viewers' encode())

static void ARDMAppendBE(NSMutableData *out, uint64_t value, int bytes) {
    for (int i = bytes - 1; i >= 0; i--) [out appendBytes:(const uint8_t[]){ (uint8_t)(value >> (8 * i)) } length:1];
}

static NSData *ARDMDeflate(NSData *data, int windowBits) {
    z_stream st; memset(&st, 0, sizeof(st));
    if (deflateInit2(&st, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY) != Z_OK) return nil;
    st.next_in = (Bytef *)data.bytes;
    st.avail_in = (uInt)data.length;
    NSMutableData *result = [NSMutableData dataWithCapacity:data.length + 128];
    uint8_t buffer[65536];
    int status;
    do {
        st.next_out = buffer; st.avail_out = sizeof(buffer);
        status = deflate(&st, Z_FINISH);
        [result appendBytes:buffer length:sizeof(buffer) - st.avail_out];
    } while (status == Z_OK);
    deflateEnd(&st);
    return status == Z_STREAM_END ? result : nil;
}

static NSData *ARDMMsgpackEncode(id value);
static void ARDMMsgpackAppend(NSMutableData *out, id value) {
    if (!value || value == NSNull.null) { [out appendBytes:(const uint8_t[]){0xc0} length:1]; return; }
    if ([value isKindOfClass:NSString.class]) {
        NSData *utf8 = [(NSString *)value dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        NSUInteger n = utf8.length;
        if (n <= 31) { [out appendBytes:(const uint8_t[]){(uint8_t)(0xa0 | n)} length:1]; }
        else if (n <= 255) { [out appendBytes:(const uint8_t[]){0xd9, (uint8_t)n} length:2]; }
        else if (n <= 65535) { [out appendBytes:(const uint8_t[]){0xda} length:1]; ARDMAppendBE(out, n, 2); }
        else { [out appendBytes:(const uint8_t[]){0xdb} length:1]; ARDMAppendBE(out, n, 4); }
        [out appendData:utf8];
        return;
    }
    if ([value isKindOfClass:NSNumber.class]) {
        NSNumber *n = value;
        if (CFGetTypeID((__bridge CFTypeRef)n) == CFBooleanGetTypeID()) {
            [out appendBytes:(const uint8_t[]){[n boolValue] ? 0xc3 : 0xc2} length:1]; return;
        }
        double d = [n doubleValue];
        if (d != (double)[n longLongValue]) {
            [out appendBytes:(const uint8_t[]){0xcb} length:1];
            uint64_t bits; memcpy(&bits, &d, 8); ARDMAppendBE(out, bits, 8); return;
        }
        long long i = [n longLongValue];
        if (i >= 0 && i <= 127) { [out appendBytes:(const uint8_t[]){(uint8_t)i} length:1]; return; }
        if (i < 0 && i >= -32) { [out appendBytes:(const uint8_t[]){(uint8_t)i} length:1]; return; }
        [out appendBytes:(const uint8_t[]){0xd3} length:1];
        ARDMAppendBE(out, (uint64_t)i, 8);
        return;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSArray *a = value; NSUInteger n = a.count;
        if (n <= 15) { [out appendBytes:(const uint8_t[]){(uint8_t)(0x90 | n)} length:1]; }
        else if (n <= 65535) { [out appendBytes:(const uint8_t[]){0xdc} length:1]; ARDMAppendBE(out, n, 2); }
        else { [out appendBytes:(const uint8_t[]){0xdd} length:1]; ARDMAppendBE(out, n, 4); }
        for (id item in a) ARDMMsgpackAppend(out, item);
        return;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *d = value; NSUInteger n = d.count;
        if (n <= 15) { [out appendBytes:(const uint8_t[]){(uint8_t)(0x80 | n)} length:1]; }
        else if (n <= 65535) { [out appendBytes:(const uint8_t[]){0xde} length:1]; ARDMAppendBE(out, n, 2); }
        else { [out appendBytes:(const uint8_t[]){0xdf} length:1]; ARDMAppendBE(out, n, 4); }
        for (id key in d) { ARDMMsgpackAppend(out, [key description]); ARDMMsgpackAppend(out, d[key]); }
        return;
    }
    [out appendBytes:(const uint8_t[]){0xc0} length:1];
}
static NSData *ARDMMsgpackEncode(id value) {
    NSMutableData *out = [NSMutableData data];
    ARDMMsgpackAppend(out, value);
    return out;
}

static void ARDMPHPAppend(NSMutableString *out, id value) {
    if (!value || value == NSNull.null) { [out appendString:@"N;"]; return; }
    if ([value isKindOfClass:NSString.class]) {
        NSString *s = value;
        NSUInteger bytes = [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        [out appendFormat:@"s:%lu:\"%@\";", (unsigned long)bytes, s]; return;
    }
    if ([value isKindOfClass:NSNumber.class]) {
        NSNumber *n = value;
        if (CFGetTypeID((__bridge CFTypeRef)n) == CFBooleanGetTypeID()) { [out appendFormat:@"b:%d;", [n boolValue] ? 1 : 0]; }
        else if ([n doubleValue] != (double)[n longLongValue]) { [out appendFormat:@"d:%@;", n]; }
        else { [out appendFormat:@"i:%lld;", [n longLongValue]]; }
        return;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSArray *a = value;
        [out appendFormat:@"a:%lu:{", (unsigned long)a.count];
        for (NSUInteger i = 0; i < a.count; i++) { [out appendFormat:@"i:%lu;", (unsigned long)i]; ARDMPHPAppend(out, a[i]); }
        [out appendString:@"}"]; return;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *d = value;
        [out appendFormat:@"a:%lu:{", (unsigned long)d.count];
        for (id key in d) { ARDMPHPAppend(out, [key description]); ARDMPHPAppend(out, d[key]); }
        [out appendString:@"}"]; return;
    }
    [out appendString:@"N;"];
}

/** Reverse of ARDMHexDump: "00000000  48 65 ...  |Hello|" -> bytes. */
static NSData *ARDMDataFromHexDump(NSString *text) {
    NSMutableData *out = [NSMutableData data];
    for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
        NSRange bar = [rawLine rangeOfString:@" |"];
        NSString *line = bar.location == NSNotFound ? rawLine : [rawLine substringToIndex:bar.location];
        NSArray *tokens = [[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                           componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        BOOL first = YES;
        for (NSString *token in tokens) {
            if (token.length == 0) continue;
            if (first) { first = NO; continue; }   // offset column
            if (token.length != 2) continue;
            unsigned value = 0;
            if ([[NSScanner scannerWithString:token] scanHexInt:&value]) {
                uint8_t byte = (uint8_t)value; [out appendBytes:&byte length:1];
            }
        }
    }
    return out;
}

/** Reverse of ARDMBinaryDump: groups of eight 0/1 characters -> bytes. */
static NSData *ARDMDataFromBinaryDump(NSString *text) {
    NSMutableData *out = [NSMutableData data];
    NSArray *tokens = [text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSString *token in tokens) {
        if (token.length != 8) continue;
        BOOL valid = YES; uint8_t byte = 0;
        for (NSUInteger i = 0; i < 8; i++) {
            unichar c = [token characterAtIndex:i];
            if (c != '0' && c != '1') { valid = NO; break; }
            if (c == '1') byte |= (uint8_t)(1 << (7 - i));
        }
        if (valid) [out appendBytes:&byte length:1];
    }
    return out;
}

static NSDictionary<NSNumber *, NSString *> *sARDMProtobufSchema;

#pragma mark Msgpack

static BOOL ARDMMsgpackIsValid(const unsigned char *p, NSUInteger len);
static id ARDMMsgpackValue(const unsigned char *p, NSUInteger len, NSUInteger *offset) {
    NSUInteger i = *offset;
    if (i >= len) return NSNull.null;
    unsigned char c = p[i++];
    if (c <= 0x7f) { *offset = i; return @(c); }
    if (c >= 0xe0) { *offset = i; return @((int8_t)c); }
    if ((c & 0xe0) == 0xa0) {
        NSUInteger n = c & 0x1f;
        if (i + n > len) return NSNull.null;
        NSData *d = [NSData dataWithBytes:p + i length:n]; i += n; *offset = i;
        return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: d;
    }
    if ((c & 0xf0) == 0x90) {
        NSUInteger n = c & 0x0f; NSMutableArray *a = [NSMutableArray array];
        for (NSUInteger k = 0; k < n; k++) { *offset = i; [a addObject:ARDMMsgpackValue(p, len, offset)]; i = *offset; }
        *offset = i; return a;
    }
    if ((c & 0xf0) == 0x80) {
        NSUInteger n = c & 0x0f; NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSUInteger k = 0; k < n; k++) {
            *offset = i; id key = ARDMMsgpackValue(p, len, offset); i = *offset;
            *offset = i; id val = ARDMMsgpackValue(p, len, offset); i = *offset;
            d[[NSString stringWithFormat:@"%@", key]] = val;
        }
        *offset = i; return d;
    }
    switch (c) {
        case 0xc0: *offset = i; return NSNull.null;
        case 0xc2: *offset = i; return @NO;
        case 0xc3: *offset = i; return @YES;
        case 0xcc: { if (i + 1 > len) return NSNull.null; NSUInteger v = p[i]; *offset = i + 1; return @(v); }
        case 0xcd: { if (i + 2 > len) return NSNull.null; NSUInteger v = (p[i] << 8) | p[i+1]; *offset = i + 2; return @(v); }
        case 0xce: { if (i + 4 > len) return NSNull.null; NSUInteger v = ((NSUInteger)p[i] << 24) | ((NSUInteger)p[i+1] << 16) | ((NSUInteger)p[i+2] << 8) | p[i+3]; *offset = i + 4; return @(v); }
        case 0xd0: { if (i + 1 > len) return NSNull.null; *offset = i + 1; return @((int8_t)p[i]); }
        case 0xd1: { if (i + 2 > len) return NSNull.null; int16_t v = (p[i] << 8) | p[i+1]; *offset = i + 2; return @(v); }
        case 0xd2: { if (i + 4 > len) return NSNull.null; int32_t v = ((int)p[i] << 24) | ((int)p[i+1] << 16) | ((int)p[i+2] << 8) | p[i+3]; *offset = i + 4; return @(v); }
        case 0xca: { if (i + 4 > len) return NSNull.null; uint32_t v = ((uint32_t)p[i] << 24) | ((uint32_t)p[i+1] << 16) | ((uint32_t)p[i+2] << 8) | p[i+3]; float f; memcpy(&f, &v, 4); *offset = i + 4; return @(f); }
        case 0xcb: { if (i + 8 > len) return NSNull.null; uint64_t v = 0; for (int k = 0; k < 8; k++) v = (v << 8) | p[i+k]; double f; memcpy(&f, &v, 8); *offset = i + 8; return @(f); }
        case 0xd9: case 0xda: case 0xdb: {
            NSUInteger h = (c == 0xd9) ? 1 : (c == 0xda ? 2 : 4);
            if (i + h > len) return NSNull.null;
            NSUInteger n = 0; for (NSUInteger k = 0; k < h; k++) n = (n << 8) | p[i + k]; i += h;
            if (i + n > len) return NSNull.null;
            NSData *d = [NSData dataWithBytes:p + i length:n]; *offset = i + n;
            return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: d;
        }
        case 0xdc: case 0xdd: {
            NSUInteger h = (c == 0xdc) ? 2 : 4;
            if (i + h > len) return NSNull.null;
            NSUInteger n = 0; for (NSUInteger k = 0; k < h; k++) n = (n << 8) | p[i + k]; i += h;
            NSMutableArray *a = [NSMutableArray array];
            for (NSUInteger k = 0; k < n; k++) { *offset = i; [a addObject:ARDMMsgpackValue(p, len, offset)]; i = *offset; }
            *offset = i; return a;
        }
        default: *offset = i; return [NSString stringWithFormat:@"<msgpack tag 0x%02x>", c];
    }
}

/** True only when the entire buffer is a single well-formed MessagePack value,
    so detection never mislabels arbitrary binary as Msgpack. */
static BOOL ARDMMsgpackIsValid(const unsigned char *p, NSUInteger len) {
    if (len == 0) return NO;
    NSUInteger off = 0;
    id v = ARDMMsgpackValue(p, len, &off);
    if (off != len) return NO;
    if ([v isKindOfClass:NSString.class] && [(NSString *)v hasPrefix:@"<msgpack tag"]) return NO;
    return YES;
}

#pragma mark PHP serialize

/** Consume up to (and including) the given delimiter, returning the text before it. */
static NSString *ARDMPHPReadUntil(const char *p, NSUInteger len, NSUInteger *off, char delimiter) {
    NSUInteger start = *off, end = start;
    while (end < len && p[end] != delimiter) end++;
    NSString *text = [[NSString alloc] initWithBytes:p + start length:end - start encoding:NSUTF8StringEncoding] ?: @"";
    *off = (end < len) ? end + 1 : end;
    return text;
}

/**
 * Decode PHP serialize() payloads: N; / b:1; / i:42; / d:1.5; /
 * s:4:"name"; / a:2:{key;value;}. Byte lengths in s: are honoured so
 * quotes and semicolons inside a string value are safe.
 */
static id ARDMPHPValue(const char *p, NSUInteger len, NSUInteger *off) {
    if (*off >= len) return NSNull.null;
    char t = p[(*off)++];
    if (t == 'N') {
        if (*off < len && p[*off] == ';') (*off)++;
        return NSNull.null;
    }
    if (*off < len && p[*off] == ':') (*off)++;
    if (t == 'b' || t == 'i' || t == 'd') {
        NSString *num = ARDMPHPReadUntil(p, len, off, ';');
        if (t == 'b') return @([num integerValue] != 0);
        if (t == 'd') return @([num doubleValue]);
        return @([num longLongValue]);
    }
    if (t == 's' || t == 'S') {
        NSUInteger n = (NSUInteger)[ARDMPHPReadUntil(p, len, off, ':') integerValue];
        if (*off < len && p[*off] == '"') (*off)++;
        if (*off + n > len) return NSNull.null;
        NSString *s = [[NSString alloc] initWithBytes:p + *off length:n encoding:NSUTF8StringEncoding] ?: @"<binary>";
        *off += n;
        if (*off < len && p[*off] == '"') (*off)++;
        if (*off < len && p[*off] == ';') (*off)++;
        return s;
    }
    if (t == 'a') {
        NSUInteger n = (NSUInteger)[ARDMPHPReadUntil(p, len, off, ':') integerValue];
        if (*off < len && p[*off] == '{') (*off)++;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSUInteger k = 0; k < n; k++) {
            id key = ARDMPHPValue(p, len, off);
            id val = ARDMPHPValue(p, len, off);
            d[[NSString stringWithFormat:@"%@", key]] = val ?: NSNull.null;
        }
        if (*off < len && p[*off] == '}') (*off)++;
        return d;
    }
    return [NSString stringWithFormat:@"<php tag %c>", t];
}

#pragma mark Protobuf wire

static NSString *ARDMProtobufDump(NSData *data, NSDictionary<NSNumber *, NSString *> *schema) {
    const unsigned char *p = data.bytes; NSUInteger i = 0, len = data.length;
    NSMutableString *out = [NSMutableString string];
    while (i < len) {
        uint64_t tag = 0; int shift = 0;
        while (i < len && shift < 64) { uint8_t b = p[i++]; tag |= (uint64_t)(b & 0x7f) << shift; if (!(b & 0x80)) break; shift += 7; }
        NSUInteger field = tag >> 3, wire = tag & 7;
        // A user-supplied .proto schema labels every wire type, not just fixed32/64.
        NSString *label = schema[@(field)] ?: [NSString stringWithFormat:@"%lu", (unsigned long)field];
        if (wire == 0) {
            uint64_t v = 0; shift = 0;
            while (i < len && shift < 64) { uint8_t b = p[i++]; v |= (uint64_t)(b & 0x7f) << shift; if (!(b & 0x80)) break; shift += 7; }
            [out appendFormat:@"field %@ (varint): %llu\n", label, v];
        } else if (wire == 2) {
            uint64_t n = 0; shift = 0;
            while (i < len && shift < 64) { uint8_t b = p[i++]; n |= (uint64_t)(b & 0x7f) << shift; if (!(b & 0x80)) break; shift += 7; }
            if (i + n > len) break;
            NSData *chunk = [NSData dataWithBytes:p + i length:(NSUInteger)n]; i += (NSUInteger)n;
            NSString *s = [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding];
            [out appendFormat:@"field %@ (bytes, %llu): %@\n", label, n,
                (s && [[NSCharacterSet controlCharacterSet] isSupersetOfSet:[NSCharacterSet characterSetWithCharactersInString:s]] == NO) ? s : ARDMHexDump(chunk)];
        } else if (wire == 5) {
            if (i + 4 > len) break;
            [out appendFormat:@"field %@ (fixed32): %@\n", label, ARDMHexDump([NSData dataWithBytes:p + i length:4])];
            i += 4;
        } else if (wire == 1) {
            if (i + 8 > len) break;
            [out appendFormat:@"field %@ (fixed64): %@\n", label, ARDMHexDump([NSData dataWithBytes:p + i length:8])];
            i += 8;
        } else break;
    }
    return out.length ? out : @"<no protobuf fields decoded>";
}

static NSString *ARDMJSONString(id obj) {
    if (![NSJSONSerialization isValidJSONObject:obj]) return [NSString stringWithFormat:@"%@", obj];
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted error:nil];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"<invalid json>";
}

static NSString *ARDMSpaces(NSInteger depth) {
    NSInteger n = depth * 2;
    if (n <= 0) return @"";
    NSMutableString *s = [NSMutableString stringWithCapacity:n];
    for (NSInteger k = 0; k < n; k++) [s appendString:@" "];
    return s;
}

/** Re-indent a JSON document while preserving every token verbatim. Unlike
    NSJSONSerialization, this never re-encodes numbers, so 64-bit-and-beyond
    integers (e.g. 123456789012345678901) survive exactly as stored, matching
    the upstream JSON editor's verbatim behaviour. Returns nil for non-object JSON. */
static NSString *ARDMPrettyJSON(NSData *data) {
    const char *p = data.bytes;
    NSUInteger n = data.length, i = 0;
    while (i < n && (p[i] == ' ' || p[i] == '\n' || p[i] == '\r' || p[i] == '\t')) i++;
    if (i >= n || (p[i] != '{' && p[i] != '[')) return nil;
    NSMutableString *out = [NSMutableString string];
    NSInteger depth = 0;
    BOOL inString = NO, escape = NO;
    for (; i < n; i++) {
        char c = p[i];
        if (inString) {
            [out appendFormat:@"%c", c];
            if (escape) escape = NO;
            else if (c == '\\') escape = YES;
            else if (c == '"') inString = NO;
            continue;
        }
        switch (c) {
            case '"': inString = YES; [out appendFormat:@"%c", c]; break;
            case '{': case '[':
                [out appendFormat:@"%c", c]; depth++;
                [out appendString:@"\n"]; [out appendString:ARDMSpaces(depth)]; break;
            case '}': case ']':
                depth--; [out appendString:@"\n"]; [out appendString:ARDMSpaces(depth)];
                [out appendFormat:@"%c", c]; break;
            case ',':
                [out appendString:@",\n"]; [out appendString:ARDMSpaces(depth)]; break;
            case ':': [out appendString:@": "]; break;
            case ' ': case '\n': case '\r': case '\t': break; // drop original whitespace
            default: [out appendFormat:@"%c", c]; break;
        }
    }
    return out;
}

#pragma mark - Java Object Serialization (real deserialization)

@interface ARDMJavaReader : NSObject
@property (nonatomic, assign) const unsigned char *p;
@property (nonatomic, assign) NSUInteger n;
@property (nonatomic, assign) NSUInteger off;
@property (nonatomic, strong) NSMutableArray *handles;
- (id)readContent:(NSInteger)depth;
- (NSDictionary *)readClassDesc:(NSInteger)depth;
@end

@implementation ARDMJavaReader

- (BOOL)hasBytes:(NSUInteger)count { return self.off + count <= self.n; }
- (uint8_t)u8 {
    if (self.off >= self.n) { self.off = self.n; return 0; }
    return self.p[self.off++];
}
- (uint16_t)u16 { uint16_t v = 0; for (int k = 0; k < 2; k++) v = (v << 8) | [self u8]; return v; }
- (uint32_t)u32 { uint32_t v = 0; for (int k = 0; k < 4; k++) v = (v << 8) | [self u8]; return v; }
- (uint64_t)u64 { uint64_t v = 0; for (int k = 0; k < 8; k++) v = (v << 8) | [self u8]; return v; }
- (void)skip:(NSUInteger)count { self.off = MIN(self.n, self.off + count); }

- (NSString *)utf {
    if (![self hasBytes:2]) return @"";
    uint16_t len = [self u16];
    if (![self hasBytes:len]) { self.off = self.n; return @""; }
    NSString *s = [[NSString alloc] initWithBytes:self.p + self.off length:len encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithBytes:self.p + self.off length:len encoding:NSISOLatin1StringEncoding];
    self.off += len;
    return s ?: @"";
}

- (void)addHandle:(id)value { [self.handles addObject:value ?: [NSNull null]]; }

- (NSString *)describe:(id)value {
    if (!value || value == [NSNull null]) return @"null";
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value description];
    if ([value isKindOfClass:[NSDictionary class]]) return [value[@"name"] description] ?: @"<object>";
    return [value description];
}

- (void)skipAnnotations {
    while (self.off < self.n) {
        if (self.p[self.off] == 0x78) { self.off++; return; }
        NSUInteger before = self.off;
        (void)[self readContent:0];
        if (self.off <= before) break;
    }
}

- (NSDictionary *)readClassDesc:(NSInteger)depth {
    if (depth > 40) return nil;
    uint8_t token = [self u8];
    if (token == 0x70) return nil; // TC_NULL
    if (token == 0x71) { // TC_REFERENCE
        uint32_t handle = [self u32];
        if (handle < self.handles.count) {
            id target = self.handles[handle];
            if ([target isKindOfClass:[NSDictionary class]]) return target;
        }
        return nil;
    }
    if (token == 0x7D) { // TC_PROXYCLASSDESC
        uint32_t count = [self u32];
        for (uint32_t k = 0; k < count; k++) [self utf];
        NSMutableDictionary *desc = [@{@"name": @"<proxy>", @"fields": @[]} mutableCopy];
        [self addHandle:desc];
        [self skipAnnotations];
        NSDictionary *super = [self readClassDesc:depth + 1];
        if (super) desc[@"super"] = super;
        return desc;
    }
    if (token != 0x72) return nil; // TC_CLASSDESC
    NSString *name = [self utf];
    [self skip:8]; // serialVersionUID
    (void)[self u8]; // flags
    uint16_t fieldCount = [self u16];
    NSMutableArray *fields = [NSMutableArray arrayWithCapacity:fieldCount];
    for (uint16_t k = 0; k < fieldCount; k++) {
        uint8_t type = [self u8];
        NSString *fieldName = [self utf];
        if (type == 'L' || type == '[') (void)[self readContent:depth + 1];
        [fields addObject:@{@"type": [NSString stringWithFormat:@"%c", type], @"name": fieldName}];
    }
    [self skipAnnotations];
    NSMutableDictionary *desc = [@{@"name": name, @"fields": fields} mutableCopy];
    [self addHandle:desc]; // classDesc handle precedes its super descriptor
    NSDictionary *super = [self readClassDesc:depth + 1];
    if (super) desc[@"super"] = super;
    return desc;
}

- (id)readFieldValue:(NSString *)type depth:(NSInteger)depth {
    unichar c = type.length ? [type characterAtIndex:0] : 'L';
    switch (c) {
        case 'B': return @((int8_t)[self u8]);
        case 'C': return [NSString stringWithFormat:@"%C", (unichar)[self u16]];
        case 'S': return @((int16_t)[self u16]);
        case 'I': return @((int32_t)[self u32]);
        case 'J': return @((int64_t)[self u64]);
        case 'F': { uint32_t bits = [self u32]; float f; memcpy(&f, &bits, 4); return @(f); }
        case 'D': { uint64_t bits = [self u64]; double d; memcpy(&d, &bits, 8); return @(d); }
        case 'Z': return [self u8] ? @YES : @NO;
        default: return [self readContent:depth + 1];
    }
}

- (NSString *)readObject:(NSInteger)depth {
    NSDictionary *desc = [self readClassDesc:depth];
    NSString *className = [desc[@"name"] description] ?: @"object";
    [self addHandle:[NSString stringWithFormat:@"<object %@>", className]];
    NSMutableArray *chain = [NSMutableArray array];
    id cursor = desc;
    NSInteger guard = 0;
    while ([cursor isKindOfClass:[NSDictionary class]] && guard++ < 40) {
        [chain insertObject:cursor atIndex:0];
        cursor = ((NSDictionary *)cursor)[@"super"];
    }
    NSMutableString *body = [NSMutableString string];
    for (NSDictionary *classDesc in chain) {
        for (NSDictionary *field in (classDesc[@"fields"] ?: @[])) {
            id value = [self readFieldValue:field[@"type"] depth:depth + 1];
            [body appendFormat:@"  %@ (field %@) = %@\n", field[@"name"], field[@"type"], [self describe:value]];
        }
    }
    return [NSString stringWithFormat:@"%@ {\n%@}", className, body];
}

- (NSString *)readArray:(NSInteger)depth {
    NSDictionary *desc = [self readClassDesc:depth];
    NSString *name = [desc[@"name"] description] ?: @"[?";
    [self addHandle:[NSString stringWithFormat:@"<array %@>", name]];
    uint32_t length = [self u32];
    unichar component = name.length > 1 ? [name characterAtIndex:1] : 'L';
    NSString *fieldType = (component == 'L' || component == '[') ? @"L" : [NSString stringWithFormat:@"%C", component];
    NSMutableString *body = [NSMutableString string];
    uint32_t limit = MIN(length, 2000);
    for (uint32_t k = 0; k < limit; k++) {
        id value = [self readFieldValue:fieldType depth:depth + 1];
        [body appendFormat:@"  [%u] = %@\n", k, [self describe:value]];
    }
    if (length > limit) [body appendFormat:@"  … %u more\n", length - limit];
    return [NSString stringWithFormat:@"array %@ (length %u) {\n%@}", name, length, body];
}

- (NSString *)readEnum:(NSInteger)depth {
    NSDictionary *desc = [self readClassDesc:depth];
    NSString *name = [desc[@"name"] description] ?: @"enum";
    [self addHandle:[NSString stringWithFormat:@"<enum %@>", name]];
    id constant = [self readContent:depth + 1];
    return [NSString stringWithFormat:@"%@.%@", name, [self describe:constant]];
}

- (id)readContent:(NSInteger)depth {
    if (depth > 60 || self.off >= self.n) return @"<truncated>";
    uint8_t token = [self u8];
    switch (token) {
        case 0x70: return [NSNull null];
        case 0x71: {
            uint32_t handle = [self u32];
            if (handle < self.handles.count) return self.handles[handle];
            return [NSString stringWithFormat:@"<ref #%u>", handle];
        }
        case 0x74: { NSString *s = [self utf]; [self addHandle:s]; return s; }
        case 0x7C: {
            uint64_t length = [self u64];
            NSUInteger take = (NSUInteger)MIN(length, (uint64_t)(self.n - self.off));
            NSString *s = [[NSString alloc] initWithBytes:self.p + self.off length:take encoding:NSUTF8StringEncoding] ?: @"<binary string>";
            self.off += take;
            [self addHandle:s];
            return s;
        }
        case 0x72: { NSDictionary *d = [self readClassDesc:depth]; return d ?: @"<classdesc>"; }
        case 0x73: return [self readObject:depth];
        case 0x75: return [self readArray:depth];
        case 0x76: { NSDictionary *d = [self readClassDesc:depth]; [self addHandle:d ?: [NSNull null]]; return [NSString stringWithFormat:@"class %@", [d[@"name"] description] ?: @"?"]; }
        case 0x7E: return [self readEnum:depth];
        case 0x77: { uint8_t length = [self u8]; [self skip:length]; return [NSString stringWithFormat:@"<blockdata %u>", length]; }
        case 0x7A: { uint32_t length = [self u32]; [self skip:length]; return [NSString stringWithFormat:@"<blockdatalong %u>", length]; }
        case 0x78: return @"<endblockdata>";
        case 0x79: return @"<reset>";
        case 0x7B: { id ex = [self readContent:depth + 1]; return [NSString stringWithFormat:@"<exception %@>", [self describe:ex]]; }
        default: return [NSString stringWithFormat:@"<unknown tc 0x%02x>", token];
    }
}

@end

static NSString *ARDMJavaDeserialize(NSData *data) {
    if (data.length < 4) return @"<not a Java serialized stream>";
    const unsigned char *p = data.bytes;
    if (p[0] != 0xac || p[1] != 0xed) return @"<not a Java serialized stream>";
    ARDMJavaReader *reader = [ARDMJavaReader new];
    reader.p = p;
    reader.n = data.length;
    reader.off = 4;
    reader.handles = [NSMutableArray array];
    NSMutableString *out = [NSMutableString stringWithFormat:@"Java Object Serialization Stream (AC ED %02X %02X)\n", p[2], p[3]];
    NSInteger guard = 0;
    while (reader.off < reader.n && guard < 5000) {
        NSUInteger before = reader.off;
        id value = [reader readContent:0];
        NSString *line = [reader describe:value];
        if (line.length && ![line hasPrefix:@"<endblockdata>"] && ![line hasPrefix:@"<reset>"]) {
            [out appendFormat:@"%@\n", line];
        }
        if (reader.off <= before) break;
        guard++;
    }
    return out;
}

#pragma mark - Python Pickle (real deserialization)

static NSString *ARDMPickleDescribe(id value, NSInteger depth) {
    if (depth > 30) return @"<deep>";
    if (!value || value == [NSNull null]) return @"None";
    if ([value isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"'%@'", value];
    if ([value isKindOfClass:[NSNumber class]]) {
        if (strcmp([value objCType], @encode(BOOL)) == 0) return [value boolValue] ? @"True" : @"False";
        return [value description];
    }
    if ([value isKindOfClass:[NSData class]]) return [NSString stringWithFormat:@"<bytes %lu>", (unsigned long)[value length]];
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id item in value) [parts addObject:ARDMPickleDescribe(item, depth + 1)];
        return [NSString stringWithFormat:@"[%@]", [parts componentsJoinedByString:@", "]];
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id key in value) [parts addObject:[NSString stringWithFormat:@"%@: %@", key, ARDMPickleDescribe(value[key], depth + 1)]];
        return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
    }
    if ([value isKindOfClass:[NSSet class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id item in value) [parts addObject:ARDMPickleDescribe(item, depth + 1)];
        return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
    }
    return [value description];
}

static NSString *ARDMUnpickle(NSData *data) {
    const unsigned char *p = data.bytes;
    NSUInteger n = data.length, i = 0;
    NSMutableArray *stack = [NSMutableArray array];
    NSMutableDictionary *memo = [NSMutableDictionary dictionary];
    NSObject *marker = [NSObject new];
    NSString *error = nil;
    NSInteger guard = 0;
    while (i < n && guard++ < 2000000) {
        uint8_t op = p[i++];
        switch (op) {
            case 0x80: i += 1; break; // PROTO
            case 0x95: i += 8; break; // FRAME
            case '.': i = n; break;   // STOP
            case '(': [stack addObject:marker]; break; // MARK
            case '0': if (stack.count) [stack removeLastObject]; break; // POP
            case '1': while (stack.count && [stack lastObject] != marker) [stack removeLastObject]; if (stack.count) [stack removeLastObject]; break; // POP_MARK
            case '2': [stack addObject:[stack lastObject] ?: [NSNull null]]; break; // DUP
            case 'N': [stack addObject:[NSNull null]]; break; // NONE
            case 'I': {
                NSMutableString *s = [NSMutableString string];
                while (i < n && p[i] != '\n') { [s appendFormat:@"%c", p[i]]; i++; }
                if (i < n) i++;
                if ([s isEqualToString:@"00"]) [stack addObject:@NO];
                else if ([s isEqualToString:@"01"]) [stack addObject:@YES];
                else [stack addObject:@([s longLongValue])];
                break;
            }
            case 'J': { int32_t v = 0; if (i + 4 <= n) memcpy(&v, p + i, 4); i += 4; [stack addObject:@(v)]; break; }
            case 'K': { uint8_t v = i < n ? p[i] : 0; i += 1; [stack addObject:@(v)]; break; }
            case 'M': { uint16_t v = 0; if (i + 2 <= n) memcpy(&v, p + i, 2); i += 2; [stack addObject:@(v)]; break; }
            case 'L': {
                NSMutableString *s = [NSMutableString string];
                while (i < n && p[i] != 'L') { [s appendFormat:@"%c", p[i]]; i++; }
                if (i < n) i++;
                [stack addObject:@([s longLongValue])];
                break;
            }
            case 0x8A: { uint8_t len = i < n ? p[i] : 0; i++; long long v = 0; for (int k = (int)len - 1; k >= 0; k--) v = (v << 8) | (i + k < n ? p[i + k] : 0); i += len; [stack addObject:@(v)]; break; }
            case 0x8B: { uint32_t len = 0; if (i + 4 <= n) memcpy(&len, p + i, 4); i += 4; long long v = 0; for (int k = (int)len - 1; k >= 0 && i + k < n; k--) v = (v << 8) | p[i + k]; i += len; [stack addObject:@(v)]; break; }
            case 'F': {
                NSMutableString *s = [NSMutableString string];
                while (i < n && p[i] != '\n') { [s appendFormat:@"%c", p[i]]; i++; }
                if (i < n) i++;
                [stack addObject:@([s doubleValue])];
                break;
            }
            case 'G': { uint64_t bits = 0; for (int k = 0; k < 8 && i < n; k++) bits = (bits << 8) | p[i++]; double d; memcpy(&d, &bits, 8); [stack addObject:@(d)]; break; }
            case 'S': {
                NSMutableString *s = [NSMutableString string];
                if (i < n && p[i] == '\'') i++;
                while (i < n && p[i] != '\n') { [s appendFormat:@"%c", p[i]]; i++; }
                if (i < n) i++;
                if (s.length && [s characterAtIndex:s.length - 1] == '\'') s = [[s substringToIndex:s.length - 1] mutableCopy];
                [stack addObject:s];
                break;
            }
            case 'V': {
                NSMutableString *s = [NSMutableString string];
                while (i < n && p[i] != '\n') { [s appendFormat:@"%c", p[i]]; i++; }
                if (i < n) i++;
                [stack addObject:s];
                break;
            }
            case 'T': { uint32_t len = 0; if (i + 4 <= n) memcpy(&len, p + i, 4); i += 4; NSString *s = len <= n - i ? [[NSString alloc] initWithBytes:p + i length:len encoding:NSUTF8StringEncoding] : @""; i += len; [stack addObject:s ?: @""]; break; }
            case 'U': { uint8_t len = i < n ? p[i] : 0; i++; NSString *s = len <= n - i ? [[NSString alloc] initWithBytes:p + i length:len encoding:NSUTF8StringEncoding] : @""; i += len; [stack addObject:s ?: @""]; break; }
            case 'B': { uint32_t len = 0; if (i + 4 <= n) memcpy(&len, p + i, 4); i += 4; NSData *d = len <= n - i ? [NSData dataWithBytes:p + i length:len] : [NSData data]; i += len; [stack addObject:d]; break; }
            case 'C': { uint8_t len = i < n ? p[i] : 0; i++; NSData *d = len <= n - i ? [NSData dataWithBytes:p + i length:len] : [NSData data]; i += len; [stack addObject:d]; break; }
            case 0x8C: { uint8_t len = i < n ? p[i] : 0; i++; NSString *s = len <= n - i ? [[NSString alloc] initWithBytes:p + i length:len encoding:NSUTF8StringEncoding] : @""; i += len; [stack addObject:s ?: @""]; break; }
            case 'X': { uint32_t len = 0; if (i + 4 <= n) memcpy(&len, p + i, 4); i += 4; NSString *s = len <= n - i ? [[NSString alloc] initWithBytes:p + i length:len encoding:NSUTF8StringEncoding] : @""; i += len; [stack addObject:s ?: @""]; break; }
            case 0x8D: { uint64_t len = 0; if (i + 8 <= n) memcpy(&len, p + i, 8); i += 8; NSString *s = len <= (uint64_t)(n - i) ? [[NSString alloc] initWithBytes:p + i length:(NSUInteger)len encoding:NSUTF8StringEncoding] : @""; i += (NSUInteger)len; [stack addObject:s ?: @""]; break; }
            case ')': [stack addObject:@[]]; break; // EMPTY_TUPLE
            case 0x85: case 0x86: case 0x87: case 't': {
                NSMutableArray *items = [NSMutableArray array];
                if (op == 't') {
                    while (stack.count && [stack lastObject] != marker) { [items insertObject:[stack lastObject] atIndex:0]; [stack removeLastObject]; }
                    if (stack.count) [stack removeLastObject];
                } else {
                    int count = op == 0x85 ? 1 : (op == 0x86 ? 2 : 3);
                    for (int k = 0; k < count && stack.count; k++) { [items insertObject:[stack lastObject] atIndex:0]; [stack removeLastObject]; }
                }
                [stack addObject:items];
                break;
            }
            case ']': [stack addObject:[NSMutableArray array]]; break; // EMPTY_LIST
            case 'l': {
                NSMutableArray *items = [NSMutableArray array];
                while (stack.count && [stack lastObject] != marker) { [items insertObject:[stack lastObject] atIndex:0]; [stack removeLastObject]; }
                if (stack.count) [stack removeLastObject];
                [stack addObject:items];
                break;
            }
            case 'a': { id v = [stack lastObject]; if (stack.count) [stack removeLastObject]; id list = [stack lastObject]; if ([list isKindOfClass:[NSMutableArray class]]) [list addObject:v ?: [NSNull null]]; break; } // APPEND
            case 'e': {
                NSMutableArray *items = [NSMutableArray array];
                while (stack.count && [stack lastObject] != marker) { [items insertObject:[stack lastObject] atIndex:0]; [stack removeLastObject]; }
                if (stack.count) [stack removeLastObject];
                id list = [stack lastObject];
                if ([list isKindOfClass:[NSMutableArray class]]) [list addObjectsFromArray:items];
                break;
            }
            case '}': [stack addObject:[NSMutableDictionary dictionary]]; break; // EMPTY_DICT
            case 'd': {
                NSMutableDictionary *dict = [NSMutableDictionary dictionary];
                NSMutableArray *items = [NSMutableArray array];
                while (stack.count && [stack lastObject] != marker) { [items insertObject:[stack lastObject] atIndex:0]; [stack removeLastObject]; }
                if (stack.count) [stack removeLastObject];
                for (NSUInteger k = 0; k + 1 < items.count; k += 2) dict[[items[k] description]] = items[k + 1];
                [stack addObject:dict];
                break;
            }
            case 's': { id v = [stack lastObject]; if (stack.count) [stack removeLastObject]; id key = [stack lastObject]; if (stack.count) [stack removeLastObject]; id dict = [stack lastObject]; if ([dict isKindOfClass:[NSMutableDictionary class]]) dict[[key description]] = v ?: [NSNull null]; break; } // SETITEM
            case 'u': {
                NSMutableArray *items = [NSMutableArray array];
                while (stack.count && [stack lastObject] != marker) { [items insertObject:[stack lastObject] atIndex:0]; [stack removeLastObject]; }
                if (stack.count) [stack removeLastObject];
                id dict = [stack lastObject];
                if ([dict isKindOfClass:[NSMutableDictionary class]]) for (NSUInteger k = 0; k + 1 < items.count; k += 2) dict[[items[k] description]] = items[k + 1];
                break;
            }
            case 0x8F: [stack addObject:[NSMutableSet set]]; break; // EMPTY_SET
            case 0x90: {
                NSMutableArray *items = [NSMutableArray array];
                while (stack.count && [stack lastObject] != marker) { [items insertObject:[stack lastObject] atIndex:0]; [stack removeLastObject]; }
                if (stack.count) [stack removeLastObject];
                id set = [stack lastObject];
                if ([set isKindOfClass:[NSMutableSet class]]) [set addObjectsFromArray:items];
                break;
            }
            case 'p': { NSInteger idx = 0; while (i < n && p[i] != '\n') { idx = idx * 10 + (p[i] - '0'); i++; } if (i < n) i++; memo[@(idx)] = [stack lastObject] ?: [NSNull null]; break; } // PUT
            case 'q': { uint8_t idx = i < n ? p[i] : 0; i++; memo[@(idx)] = [stack lastObject] ?: [NSNull null]; break; } // BINPUT
            case 'r': { uint32_t idx = 0; if (i + 4 <= n) memcpy(&idx, p + i, 4); i += 4; memo[@(idx)] = [stack lastObject] ?: [NSNull null]; break; }
            case 0x94: memo[@(memo.count)] = [stack lastObject] ?: [NSNull null]; break; // MEMOIZE
            case 'g': { NSInteger idx = 0; while (i < n && p[i] != '\n') { idx = idx * 10 + (p[i] - '0'); i++; } if (i < n) i++; [stack addObject:memo[@(idx)] ?: [NSNull null]]; break; } // GET
            case 'h': { uint8_t idx = i < n ? p[i] : 0; i++; [stack addObject:memo[@(idx)] ?: [NSNull null]]; break; }
            case 'j': { uint32_t idx = 0; if (i + 4 <= n) memcpy(&idx, p + i, 4); i += 4; [stack addObject:memo[@(idx)] ?: [NSNull null]]; break; }
            case 'c': {
                NSMutableString *mod = [NSMutableString string];
                while (i < n && p[i] != '\n') { [mod appendFormat:@"%c", p[i]]; i++; }
                if (i < n) i++;
                NSMutableString *name = [NSMutableString string];
                while (i < n && p[i] != '\n') { [name appendFormat:@"%c", p[i]]; i++; }
                if (i < n) i++;
                [stack addObject:[NSString stringWithFormat:@"%@.%@", mod, name]];
                break;
            }
            case 0x93: { id name = [stack lastObject]; if (stack.count) [stack removeLastObject]; id mod = [stack lastObject]; if (stack.count) [stack removeLastObject]; [stack addObject:[NSString stringWithFormat:@"%@.%@", mod, name]]; break; } // STACK_GLOBAL
            case 'R': { id args = [stack lastObject]; if (stack.count) [stack removeLastObject]; id callable = [stack lastObject]; if (stack.count) [stack removeLastObject]; [stack addObject:[NSString stringWithFormat:@"%@(%@)", callable, args]]; break; } // REDUCE
            case 'b': break; // BUILD: object stays on stack
            case 0x81: { id args = [stack lastObject]; if (stack.count) [stack removeLastObject]; id cls = [stack lastObject]; if (stack.count) [stack removeLastObject]; [stack addObject:[NSString stringWithFormat:@"%@(%@)", cls, args]]; break; } // NEWOBJ
            case 0x92: { id kwargs = [stack lastObject]; if (stack.count) [stack removeLastObject]; id args = [stack lastObject]; if (stack.count) [stack removeLastObject]; id cls = [stack lastObject]; if (stack.count) [stack removeLastObject]; [stack addObject:[NSString stringWithFormat:@"%@(%@%@)", cls, args, kwargs]]; break; } // NEWOBJ_EX
            default:
                error = [NSString stringWithFormat:@"unsupported opcode 0x%02X at %lu", op, (unsigned long)(i - 1)];
                i = n;
                break;
        }
    }
    id result = stack.count ? [stack lastObject] : [NSNull null];
    NSMutableString *out = [NSMutableString stringWithString:@"Python Pickle (decoded)\n"];
    [out appendString:ARDMPickleDescribe(result, 0)];
    [out appendString:@"\n"];
    if (error) [out appendFormat:@"<stopped: %@>\n", error];
    return out;
}

@implementation ARDMFormatters

+ (NSArray<NSString *> *)viewerNames {
    return @[@"Text", @"Hex", @"Json", @"Binary", @"Msgpack", @"PHPSerialize", @"JavaSerialize",
             @"Pickle", @"Brotli", @"Gzip", @"Deflate", @"DeflateRaw", @"Protobuf", @"OverSize", @"Custom"];
}

+ (NSString *)detectViewerForData:(NSData *)data {
    const unsigned char *p = data.bytes; NSUInteger n = data.length;
    if (n == 0) return @"Text";
    // Gzip magic: 1f 8b
    if (n >= 2 && p[0] == 0x1f && p[1] == 0x8b) return @"Gzip";
    // Brotli magic: ce b2 81 (RFC 7932 typical start bytes)
    if (n >= 3 && p[0] == 0xce && p[1] == 0xb2 && p[2] == 0x81) return @"Brotli";
    // Java serialization magic: ac ed
    if (n >= 2 && p[0] == 0xac && p[1] == 0xed) return @"JavaSerialize";
    // Pickle protocol header: 0x80 <version 1..5>, or a known pickle opcode in first byte
    if (n >= 2 && p[0] == 0x80 && p[1] >= 0x01 && p[1] <= 0x05) return @"Pickle";
    if (n >= 1 && (p[0] == '(' || p[0] == 'I' || p[0] == 'S' || p[0] == 'V' ||
                    p[0] == 'l' || p[0] == 'd' || p[0] == 'c' || p[0] == 't')) return @"Pickle";
    // PHP serialize: an alphanumeric tag followed by ':' (a:/i:/s:/b:/N; ...)
    if (n >= 2 && isalpha(p[0]) && p[1] == ':') return @"PHPSerialize";
    // Deflate (zlib) header: 0x78 then a valid zlib second byte
    if (n >= 2 && p[0] == 0x78 && (p[1] == 0x01 || p[1] == 0x9c || p[1] == 0xda ||
                                    p[1] == 0x5e || p[1] == 0x7e || p[1] == 0x3e)) return @"Deflate";
    // DeflateRaw: a raw DEFLATE block header (BTYPE=01/10) that is not a zlib stream
    if (n >= 2 && (p[0] == 0x03 || p[0] == 0x05 || p[0] == 0x01 || p[0] == 0x02)) return @"DeflateRaw";
    // JSON object / array
    if (p[0] == '{' || p[0] == '[') return @"Json";
    // Any NUL byte in the first 512 bytes means binary -> Hex, not Text/Msgpack
    NSUInteger scan = MIN(n, 512);
    for (NSUInteger i = 0; i < scan; i++) if (p[i] == 0) return @"Hex";
    // Protobuf: first byte is a low field tag (field 1..15, wire 0..5)
    if ((p[0] & 0x07) <= 5 && (p[0] >> 3) >= 1 && (p[0] >> 3) <= 15) return @"Protobuf";
    // Msgpack: only when the whole buffer is one valid value
    if (ARDMMsgpackIsValid(p, n)) return @"Msgpack";
    // Otherwise, valid UTF-8 is Text, anything else is binary Hex
    if ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]) return @"Text";
    return @"Hex";
}

+ (NSString *)render:(NSData *)data as:(NSString *)viewer error:(NSError **)error {
    if (!data) return @"";
    if ([viewer isEqualToString:@"Text"]) {
        NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        return s ?: ARDMHexDump(data);
    }
    if ([viewer isEqualToString:@"Hex"]) return ARDMHexDump(data);
    if ([viewer isEqualToString:@"Binary"]) return ARDMBinaryDump(data);
    if ([viewer isEqualToString:@"Json"]) {
        NSString *pretty = ARDMPrettyJSON(data);
        if (pretty) return pretty;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil];
        return obj ? ARDMJSONString(obj) : ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"<invalid json>");
    }
    if ([viewer isEqualToString:@"Msgpack"]) {
        NSUInteger off = 0;
        id v = ARDMMsgpackValue(data.bytes, data.length, &off);
        return ARDMJSONString(v);
    }
    if ([viewer isEqualToString:@"PHPSerialize"]) {
        NSUInteger off = 0;
        id v = ARDMPHPValue(data.bytes, data.length, &off);
        return ARDMJSONString(v);
    }
    if ([viewer isEqualToString:@"JavaSerialize"]) return ARDMJavaDeserialize(data);
    if ([viewer isEqualToString:@"Pickle"]) return ARDMUnpickle(data);
    if ([viewer isEqualToString:@"Gzip"] || [viewer isEqualToString:@"Deflate"] || [viewer isEqualToString:@"DeflateRaw"]) {
        int bits = [viewer isEqualToString:@"Gzip"] ? 31 : ([viewer isEqualToString:@"Deflate"] ? 15 : -15);
        NSData *inflated = ARDMInflate(data, bits);
        if (!inflated) { if (error) *error = [NSError errorWithDomain:@"me.qii404.ardm.native" code:20 userInfo:@{NSLocalizedDescriptionKey: @"Decompression failed"}]; return @""; }
        return [[NSString alloc] initWithData:inflated encoding:NSUTF8StringEncoding] ?: ARDMHexDump(inflated);
    }
    if ([viewer isEqualToString:@"Brotli"]) {
        NSString *tmpIn = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ardm_br_in"];
        [data writeToFile:tmpIn atomically:YES];
        NSTask *t = [[NSTask alloc] init];
        t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
        t.arguments = @[@"brotli", @"-d", @"-c", tmpIn];
        NSPipe *pipe = [NSPipe pipe]; t.standardOutput = pipe;
        // Brotli writes "corrupt input" to stderr for non-brotli payloads; keep
        // that noise out of the app's console instead of inheriting the handle.
        t.standardError = [NSFileHandle fileHandleWithNullDevice];
        @try { [t launch]; } @catch (NSException *e) { return @"Brotli: system decoder unavailable (install brotli CLI for this viewer)"; }
        NSData *outData = [pipe.fileHandleForReading readDataToEndOfFile];
        [t waitUntilExit];
        if (outData.length) return [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: ARDMHexDump(outData);
        return @"Brotli: system decoder unavailable (install brotli CLI for this viewer)";
    }
    if ([viewer isEqualToString:@"Protobuf"]) return ARDMProtobufDump(data, sARDMProtobufSchema);
    if ([viewer isEqualToString:@"OverSize"]) {
        return [NSString stringWithFormat:@"Value too large to display inline (%lu bytes).\nFirst 4 KB (hex):\n%@",
                (unsigned long)data.length, ARDMHexDump([data subdataWithRange:NSMakeRange(0, MIN(data.length, 4096))])];
    }
    if ([viewer isEqualToString:@"Custom"]) return @"Supply a JavaScript formatter in Settings > Custom Viewer.";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: ARDMHexDump(data);
}


+ (NSArray<NSString *> *)encodableViewers {
    return @[@"Text", @"Hex", @"Binary", @"Json", @"Msgpack", @"PHPSerialize",
             @"Gzip", @"Deflate", @"DeflateRaw", @"Brotli", @"Custom"];
}

+ (void)setProtobufSchema:(NSDictionary<NSNumber *, NSString *> * _Nullable)schema {
    sARDMProtobufSchema = [schema copy];
}
+ (NSDictionary<NSNumber *, NSString *> * _Nullable)protobufSchema { return sARDMProtobufSchema; }

/** Reverse of render:as:. Returns the exact bytes to write back with SET. */
+ (NSData *)encode:(NSString *)text as:(NSString *)viewer error:(NSError **)error {
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    if ([viewer isEqualToString:@"Text"] || [viewer isEqualToString:@"Json"] || [viewer isEqualToString:@"Custom"]) {
        // Json is passed through verbatim: NSJSONSerialization would round large integers
        // through Double and lose precision, so no re-serialisation happens here.
        return utf8;
    }
    if ([viewer isEqualToString:@"Hex"]) return ARDMDataFromHexDump(text);
    if ([viewer isEqualToString:@"Binary"]) return ARDMDataFromBinaryDump(text);
    if ([viewer isEqualToString:@"Msgpack"] || [viewer isEqualToString:@"PHPSerialize"]) {
        id value = [NSJSONSerialization JSONObjectWithData:utf8 options:NSJSONReadingAllowFragments error:nil];
        if (!value) {
            if (error) *error = [NSError errorWithDomain:@"me.qii404.ardm.native" code:30
                userInfo:@{NSLocalizedDescriptionKey: @"Edited value is not valid JSON"}];
            return [NSData data];
        }
        if ([viewer isEqualToString:@"Msgpack"]) return ARDMMsgpackEncode(value);
        NSMutableString *php = [NSMutableString string];
        ARDMPHPAppend(php, value);
        return [php dataUsingEncoding:NSUTF8StringEncoding];
    }
    if ([viewer isEqualToString:@"Gzip"] || [viewer isEqualToString:@"Deflate"] || [viewer isEqualToString:@"DeflateRaw"]) {
        int bits = [viewer isEqualToString:@"Gzip"] ? 31 : ([viewer isEqualToString:@"Deflate"] ? 15 : -15);
        NSData *compressed = ARDMDeflate(utf8, bits);
        if (!compressed) {
            if (error) *error = [NSError errorWithDomain:@"me.qii404.ardm.native" code:31
                userInfo:@{NSLocalizedDescriptionKey: @"Compression failed"}];
            return [NSData data];
        }
        return compressed;
    }
    if ([viewer isEqualToString:@"Brotli"]) {
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ardm_br_out"];
        [utf8 writeToFile:tmp atomically:YES];
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
        task.arguments = @[@"brotli", @"-c", tmp];
        NSPipe *pipe = [NSPipe pipe]; task.standardOutput = pipe;
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        @try { [task launch]; } @catch (NSException *e) {
            if (error) *error = [NSError errorWithDomain:@"me.qii404.ardm.native" code:32
                userInfo:@{NSLocalizedDescriptionKey: @"System brotli CLI is required to encode"}];
            return [NSData data];
        }
        NSData *out = [pipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        if (!out.length) {
            if (error) *error = [NSError errorWithDomain:@"me.qii404.ardm.native" code:32
                userInfo:@{NSLocalizedDescriptionKey: @"System brotli CLI is required to encode"}];
            return [NSData data];
        }
        return out;
    }
    if (error) *error = [NSError errorWithDomain:@"me.qii404.ardm.native" code:33
        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Viewer %@ is decode-only", viewer]}];
    return [NSData data];
}

+ (NSString *)renderCustom:(NSData *)data script:(NSString *)script error:(NSError **)error {
    JSContext *ctx = [[JSContext alloc] init];
    NSMutableArray *bytes = [NSMutableArray arrayWithCapacity:data.length];
    const unsigned char *p = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [bytes addObject:@(p[i])];
    ctx[@"ARDM_BYTES"] = bytes;
    ctx.exceptionHandler = ^(JSContext *c, JSValue *exception) {
        NSLog(@"custom viewer exception: %@", exception);
    };
    NSString *wrapped = [NSString stringWithFormat:
        @"var bytes = new Uint8Array(ARDM_BYTES); var result = (function(bytes) { %@ })(bytes); String(result);", script];
    JSValue *value = [ctx evaluateScript:wrapped];
    return [value toString] ?: @"<no result>";
}
@end

#pragma mark - Localization (loads the project's existing 13 language files)

// Locate the checkout's source tree without any machine-specific absolute path.
// Bundled resources take precedence; the fallback walks up from the app bundle
// and the working directory (or ARDM_PROJECT_ROOT) so a fresh clone also works.
static NSString *ARDMSourceRoot(void) {
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
            NSString *marker = [dir stringByAppendingPathComponent:@"src/i18n/langs/en.js"];
            if ([fm fileExistsAtPath:marker]) return dir;
            NSString *parent = [dir stringByDeletingLastPathComponent];
            if ([parent isEqualToString:dir]) break;
            dir = parent;
        }
    }
    return nil;
}

@implementation ARDMLocalization {
    NSDictionary<NSString *, NSDictionary *> *_tables;
}

+ (instancetype)shared {
    static ARDMLocalization *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[ARDMLocalization alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _languages = @[@"cn", @"de", @"en", @"es", @"fr", @"it", @"ko", @"pt", @"ru", @"tr", @"tw", @"ua", @"vi"];
        _currentLanguage = [[NSUserDefaults standardUserDefaults] stringForKey:@"ARDMLanguage"] ?: @"en";
        NSMutableDictionary *tables = [NSMutableDictionary dictionary];
        NSMutableArray<NSString *> *roots = [NSMutableArray arrayWithObject:
            [[[NSBundle mainBundle] resourcePath] ?: @"" stringByAppendingPathComponent:@"langs"]];
        NSString *sourceRoot = ARDMSourceRoot();
        if (sourceRoot.length) [roots addObject:[sourceRoot stringByAppendingPathComponent:@"src/i18n/langs"]];
        for (NSString *lang in _languages) {
            for (NSString *root in roots) {
                NSString *path = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.js", lang]];
                NSString *source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
                if (!source) continue;
                NSString *js = [source stringByReplacingOccurrencesOfString:@"export default" withString:@"var __ARDMLANG ="];
                JSContext *ctx = [[JSContext alloc] init];
                [ctx evaluateScript:js];
                NSString *json = [[ctx evaluateScript:@"JSON.stringify(__ARDMLANG)"] toString];
                NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *table = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
                if ([table isKindOfClass:NSDictionary.class]) { tables[lang] = table; break; }
            }
        }
        _tables = tables;
    }
    return self;
}

- (void)setCurrentLanguage:(NSString *)currentLanguage {
    _currentLanguage = currentLanguage;
    [[NSUserDefaults standardUserDefaults] setObject:currentLanguage forKey:@"ARDMLanguage"];
}

- (NSString *)t:(NSString *)key {
    NSDictionary *table = _tables[_currentLanguage] ?: _tables[@"en"];
    id value = table[key];
    if ([value isKindOfClass:NSString.class]) return value;
    NSArray *parts = [key componentsSeparatedByString:@"."];
    id nested = table;
    for (NSString *part in parts) nested = [nested isKindOfClass:NSDictionary.class] ? nested[part] : nil;
    return [nested isKindOfClass:NSString.class] ? nested : key;
}

/** Build (once) an English-label -> i18n-key index from the project's en.js table. */
- (NSDictionary<NSString *, NSString *> *)englishIndex {
    static NSDictionary *index;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        NSDictionary *english = _tables[@"en"][@"message"];
        if ([english isKindOfClass:NSDictionary.class]) {
            for (NSString *key in english) {
                id value = english[key];
                if (![value isKindOfClass:NSString.class]) continue;
                NSString *label = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (label.length) map[label.lowercaseString] = key;
            }
        }
        index = map;
    });
    return index;
}

- (NSString *)tText:(NSString *)english {
    NSString *trimmed = [english stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *key = [self englishIndex][trimmed.lowercaseString];
    if (!key) return english;
    NSString *translated = [self t:[@"message." stringByAppendingString:key]];
    return [translated isEqualToString:[@"message." stringByAppendingString:key]] ? english : translated;
}
@end
