//
//  WTClipEngine.m
//

#import "WTClipEngine.h"
#import <CommonCrypto/CommonDigest.h>

@implementation WTClipOption
@end

#pragma mark - 工具

static NSString *WTTrim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL WTIsCJK(unichar c) {
    return (c >= 0x4E00 && c <= 0x9FFF) ||   // 基本汉字
           (c >= 0x3400 && c <= 0x4DBF) ||   // 扩展 A
           (c >= 0x3040 && c <= 0x30FF) ||   // 日文假名
           (c >= 0xAC00 && c <= 0xD7AF);     // 韩文
}

static BOOL WTIsASCIIAlnum(unichar c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static BOOL WTIsURLChar(unichar c) {
    if (WTIsASCIIAlnum(c)) return YES;
    NSString *extra = @"-._~:/?#[]@!$&'()*+,;=%";
    return [extra characterAtIndex:0] == c ? YES : [extra rangeOfString:[NSString stringWithCharacters:&c length:1]].location != NSNotFound;
}

static BOOL WTIsURLTrailingPunct(unichar c) {
    return [@".,;:!?)]}'\" " rangeOfString:[NSString stringWithCharacters:&c length:1]].location != NSNotFound;
}

/// getCamelsplits("getOrderId") -> [get, order, id]
static NSArray<NSString *> *WTSplitCamel(NSString *word) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSUInteger n = word.length;
    if (n == 0) return parts;
    NSUInteger start = 0;
    for (NSUInteger i = 1; i < n; i++) {
        unichar prev = [word characterAtIndex:i - 1];
        unichar cur = [word characterAtIndex:i];
        BOOL boundary = NO;
        BOOL curUpper = (cur >= 'A' && cur <= 'Z');
        BOOL prevLower = (prev >= 'a' && prev <= 'z');
        BOOL prevDigit = (prev >= '0' && prev <= '9');
        BOOL prevUpper = (prev >= 'A' && prev <= 'Z');
        if (curUpper) {
            if (prevLower || prevDigit) {
                boundary = YES;
            } else if (prevUpper && i + 1 < n) {
                unichar next = [word characterAtIndex:i + 1];
                if (next >= 'a' && next <= 'z') boundary = YES;
            }
        }
        if (boundary) {
            [parts addObject:[word substringWithRange:NSMakeRange(start, i - start)]];
            start = i;
        }
    }
    [parts addObject:[word substringFromIndex:start]];

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSCharacterSet *trimSet = [NSCharacterSet characterSetWithCharactersInString:@"-_.@%"];
    for (NSString *p in parts) {
        NSString *t = [p stringByTrimmingCharactersInSet:trimSet];
        if (t.length) [out addObject:[t lowercaseString]];
    }
    return out;
}

#pragma mark - 分词

@implementation WTClipEngine

static NSArray<NSString *> *WTMatchURL(NSString *s, NSUInteger i, NSUInteger *consumed) {
    static NSArray<NSString *> *starters = nil;
    if (!starters) starters = @[@"https://", @"http://", @"ftp://", @"www."];

    BOOL hasPrefix = NO;
    for (NSString *p in starters) {
        if (i + p.length <= s.length &&
            [[s substringWithRange:NSMakeRange(i, p.length)] isEqualToString:p]) {
            hasPrefix = YES;
            break;
        }
    }

    if (!hasPrefix) {
        if (!WTIsASCIIAlnum([s characterAtIndex:i])) return nil;
        NSUInteger h = i;
        while (h < s.length) {
            unichar c = [s characterAtIndex:h];
            if (WTIsASCIIAlnum(c) || c == '.' || c == '-') h++;
            else break;
        }
        NSString *host = [s substringWithRange:NSMakeRange(i, h - i)];
        if ([host rangeOfString:@"."].location == NSNotFound) return nil;
        if ([host hasPrefix:@"."] || [host hasSuffix:@"."]) return nil;
        NSString *tld = [[host componentsSeparatedByString:@"."] lastObject];
        if (tld.length < 2) return nil;
        for (NSUInteger k = 0; k < tld.length; k++) {
            unichar c = [tld characterAtIndex:k];
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) return nil;
        }
        if (h < s.length) {
            unichar c = [s characterAtIndex:h];
            if (!(c == '/' || c == ' ' || c == '\n' || c == '\t')) return nil;
        }
    }

    NSUInteger j = i;
    while (j < s.length && WTIsURLChar([s characterAtIndex:j])) j++;
    NSUInteger end = j;
    while (end > i && WTIsURLTrailingPunct([s characterAtIndex:end - 1])) end--;
    if (end - i <= 3) return nil;
    *consumed = end - i;
    return @[[s substringWithRange:NSMakeRange(i, end - i)]];
}

+ (NSArray<NSString *> *)tokens:(NSString *)text {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (text.length == 0) return out;
    NSUInteger i = 0, n = text.length;

    while (i < n) {
        unichar c = [text characterAtIndex:i];

        // URL
        NSUInteger consumed = 0;
        NSArray<NSString *> *url = WTMatchURL(text, i, &consumed);
        if (url) { [out addObject:url[0]]; i += consumed; continue; }

        // ASCII 词（含 email / 日期 / 驼峰）
        if (WTIsASCIIAlnum(c)) {
            NSUInteger j = i;
            while (j < n) {
                unichar d = [text characterAtIndex:j];
                if (WTIsASCIIAlnum(d)) { j++; continue; }
                if ((d == '-' || d == '_' || d == '.' || d == '@' || d == '%') &&
                    j + 1 < n && WTIsASCIIAlnum([text characterAtIndex:j + 1])) { j++; continue; }
                break;
            }
            if (j > i) {
                [out addObjectsFromArray:WTSplitCamel([text substringWithRange:NSMakeRange(i, j - i)])];
                i = j;
                continue;
            }
        }

        // 中文块
        if (WTIsCJK(c)) {
            NSUInteger j = i;
            while (j < n && WTIsCJK([text characterAtIndex:j])) j++;
            NSUInteger k = i;
            while (k < j) {
                NSUInteger end = MIN(k + 2, j);
                [out addObject:[text substringWithRange:NSMakeRange(k, end - k)]];
                k = end;
            }
            i = j;
            continue;
        }

        i++;
    }
    return out;
}

+ (BOOL)matches:(NSString *)text query:(NSString *)query {
    NSString *q = WTTrim(query ?: @"");
    if (q.length == 0) return YES;
    NSString *lower = [text lowercaseString];
    for (NSString *t in [self tokens:q]) {
        if ([lower rangeOfString:t].location == NSNotFound) return NO;
    }
    return YES;
}

#pragma mark - 算子

+ (NSString *)displayNameFor:(WTRewriteOp)op {
    switch (op) {
        case WTRewriteOpBase64Encode: return @"Base64 编码";
        case WTRewriteOpBase64Decode: return @"Base64 解码";
        case WTRewriteOpURLEncode:    return @"URL 编码";
        case WTRewriteOpURLDecode:    return @"URL 解码";
        case WTRewriteOpHexEncode:    return @"Hex 编码";
        case WTRewriteOpHexDecode:    return @"Hex 解码";
        case WTRewriteOpJSONPretty:   return @"美化 JSON";
        case WTRewriteOpJSONMinify:   return @"压缩 JSON";
        case WTRewriteOpTrim:         return @"去首尾空白";
        case WTRewriteOpUpper:        return @"转大写";
        case WTRewriteOpLower:        return @"转小写";
        case WTRewriteOpSortLines:    return @"按行排序";
        case WTRewriteOpDedupeLines:  return @"按行去重";
        case WTRewriteOpNumberLines:  return @"加行号";
        case WTRewriteOpSHA256:       return @"SHA-256";
        case WTRewriteOpCollapseSpaces: return @"合并空白";
        case WTRewriteOpStripBlankLines: return @"去空行";
        case WTRewriteOpTokenize:     return @"分词";
    }
    return @"?";
}

+ (NSString *)sectionFor:(WTRewriteOp)op {
    switch (op) {
        case WTRewriteOpBase64Encode: case WTRewriteOpBase64Decode:
        case WTRewriteOpURLEncode: case WTRewriteOpURLDecode:
        case WTRewriteOpHexEncode: case WTRewriteOpHexDecode:
        case WTRewriteOpJSONPretty: case WTRewriteOpJSONMinify:
            return @"编码";
        case WTRewriteOpSHA256:
            return @"哈希";
        default:
            return @"文本";
    }
}

+ (NSString *)sha256:(NSString *)text {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *out = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [out appendFormat:@"%02X", digest[i]];
    return out;
}

+ (NSString *)applyOp:(WTRewriteOp)op toText:(NSString *)text error:(NSString **)error {
    if (error) *error = nil;
    NSString *fail = nil;

    switch (op) {
        case WTRewriteOpBase64Encode:
            return [[text dataUsingEncoding:NSUTF8StringEncoding]
                    base64EncodedStringWithOptions:0];

        case WTRewriteOpBase64Decode: {
            NSMutableString *s = [[WTTrim(text) mutableCopy] ?: @"" mutableCopy];
            s = [[s stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                 stringByReplacingOccurrencesOfString:@"_" withString:@"/"] ?: s;
            while (s.length % 4 != 0) s = [[s stringByAppendingString:@"="] mutableCopy];
            NSData *d = [[NSData alloc] initWithBase64EncodedString:s
                                                           options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (!d) { fail = @"不是有效的 Base64"; break; }
            NSString *r = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            if (!r) { fail = @"Base64 解码结果不是 UTF-8"; break; }
            return r;
        }

        case WTRewriteOpURLEncode: {
            NSMutableCharacterSet *set = [NSMutableCharacterSet alphanumericCharacterSet];
            [set addCharactersInString:@"-._~"];
            return [text stringByAddingPercentEncodingWithAllowedCharacters:set] ?: text;
        }

        case WTRewriteOpURLDecode: {
            NSString *r = [text stringByRemovingPercentEncoding];
            if (!r) { fail = @"不是有效的 URL 编码"; break; }
            return r;
        }

        case WTRewriteOpHexEncode: {
            NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
            const unsigned char *b = d.bytes;
            NSMutableString *s = [NSMutableString stringWithCapacity:d.length * 2];
            for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", b[i]];
            return s;
        }

        case WTRewriteOpHexDecode: {
            NSString *clean = [[text stringByReplacingOccurrencesOfString:@" " withString:@""]
                               stringByReplacingOccurrencesOfString:@"0x" withString:@""];
            clean = [clean stringByReplacingOccurrencesOfString:@"\n" withString:@""];
            if (clean.length % 2 != 0) { fail = @"Hex 长度不是偶数"; break; }
            NSMutableData *md = [NSMutableData dataWithCapacity:clean.length / 2];
            for (NSUInteger i = 0; i < clean.length; i += 2) {
                NSString *pair = [clean substringWithRange:NSMakeRange(i, 2)];
                unsigned int v = 0;
                if (![[NSScanner scannerWithString:pair] scanHexInt:&v]) { fail = @"包含非 Hex 字符"; break; }
                unsigned char byte = (unsigned char)v;
                [md appendBytes:&byte length:1];
            }
            if (fail) break;
            NSString *r = [[NSString alloc] initWithData:md encoding:NSUTF8StringEncoding];
            if (!r) { fail = @"解码结果不是 UTF-8"; break; }
            return r;
        }

        case WTRewriteOpJSONPretty:
        case WTRewriteOpJSONMinify: {
            NSData *in = [text dataUsingEncoding:NSUTF8StringEncoding];
            NSError *e = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:in options:0 error:&e];
            if (!obj) { fail = @"不是合法 JSON"; break; }
            NSJSONWritingOptions o = (op == WTRewriteOpJSONPretty)
                ? (NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys) : 0;
            NSData *out = [NSJSONSerialization dataWithJSONObject:obj options:o error:&e];
            if (!out) { fail = @"JSON 序列化失败"; break; }
            return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: text;
        }

        case WTRewriteOpTrim:  return WTTrim(text);
        case WTRewriteOpUpper: return [text uppercaseString];
        case WTRewriteOpLower: return [text lowercaseString];

        case WTRewriteOpSortLines: {
            NSArray *lines = [[text componentsSeparatedByString:@"\n"]
                              sortedArrayUsingSelector:@selector(compare:)];
            return [lines componentsJoinedByString:@"\n"];
        }

        case WTRewriteOpDedupeLines: {
            NSMutableSet *seen = [NSMutableSet set];
            NSMutableArray *out = [NSMutableArray array];
            for (NSString *l in [text componentsSeparatedByString:@"\n"]) {
                if (![seen containsObject:l]) { [seen addObject:l]; [out addObject:l]; }
            }
            return [out componentsJoinedByString:@"\n"];
        }

        case WTRewriteOpNumberLines: {
            NSMutableArray *out = [NSMutableArray array];
            NSInteger n = 1;
            for (NSString *l in [text componentsSeparatedByString:@"\n"]) {
                [out addObject:[NSString stringWithFormat:@"%ld. %@", (long)n++, l]];
            }
            return [out componentsJoinedByString:@"\n"];
        }

        case WTRewriteOpSHA256:
            return [self sha256:text];

        case WTRewriteOpCollapseSpaces: {
            NSMutableArray *lines = [NSMutableArray array];
            for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
                NSMutableString *o = [NSMutableString string];
                BOOL lastSpace = NO;
                for (NSUInteger i = 0; i < line.length; i++) {
                    unichar c = [line characterAtIndex:i];
                    if (c == ' ' || c == '\t' || c == 0x3000) {
                        if (!lastSpace) [o appendString:@" "];
                        lastSpace = YES;
                    } else {
                        [o appendFormat:@"%C", c];
                        lastSpace = NO;
                    }
                }
                [lines addObject:WTTrim(o)];
            }
            return [lines componentsJoinedByString:@"\n"];
        }

        case WTRewriteOpStripBlankLines: {
            NSMutableArray *out = [NSMutableArray array];
            for (NSString *l in [text componentsSeparatedByString:@"\n"]) {
                if (WTTrim(l).length) [out addObject:l];
            }
            return [out componentsJoinedByString:@"\n"];
        }

        case WTRewriteOpTokenize:
            return [[self tokens:text] componentsJoinedByString:@" "];
    }

    if (error) *error = fail ?: @"未知错误";
    return nil;
}

#pragma mark - 选项

+ (NSArray<NSNumber *> *)recommendedOpsForText:(NSString *)text {
    NSString *t = WTTrim(text);
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    if (t.length == 0) return out;

    if ([t hasPrefix:@"{"] || [t hasPrefix:@"["]) {
        if ([NSJSONSerialization JSONObjectWithData:[t dataUsingEncoding:NSUTF8StringEncoding]
                                            options:0 error:NULL]) {
            [out addObject:@(WTRewriteOpJSONPretty)];
        }
    }
    if ([t containsString:@"%"] && ([t stringByRemovingPercentEncoding] != t)) {
        [out addObject:@(WTRewriteOpURLDecode)];
    }
    if (t.length >= 8 && t.length % 4 == 0) {
        NSData *d = [[NSData alloc] initWithBase64EncodedString:
                     [[t stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                      stringByReplacingOccurrencesOfString:@"_" withString:@"/"]
                                                       options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (d && d.length && [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]) {
            [out addObject:@(WTRewriteOpBase64Decode)];
        }
    }
    if ([t hasPrefix:@"http://"] || [t hasPrefix:@"https://"]) {
        if (![out containsObject:@(WTRewriteOpURLDecode)]) [out addObject:@(WTRewriteOpURLDecode)];
    }
    if ([[t componentsSeparatedByString:@"\n"] count] >= 3) {
        [out addObject:@(WTRewriteOpDedupeLines)];
    }
    return [out count] > 3 ? [out subarrayWithRange:NSMakeRange(0, 3)] : out;
}

+ (NSArray<WTClipOption *> *)optionsForText:(NSString *)text {
    NSMutableArray<WTClipOption *> *out = [NSMutableArray array];
    if (text.length == 0) return out;

    NSUInteger lineCount = [[text componentsSeparatedByString:@"\n"] count];
    BOOL hasLetter = [text rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound;

    WTRewriteOp all[] = {
        WTRewriteOpBase64Encode, WTRewriteOpURLEncode, WTRewriteOpHexEncode,
        WTRewriteOpSHA256, WTRewriteOpJSONPretty, WTRewriteOpJSONMinify,
        WTRewriteOpBase64Decode, WTRewriteOpURLDecode, WTRewriteOpHexDecode,
        WTRewriteOpDedupeLines, WTRewriteOpSortLines, WTRewriteOpNumberLines,
        WTRewriteOpStripBlankLines, WTRewriteOpTrim, WTRewriteOpCollapseSpaces,
        WTRewriteOpTokenize,
    };
    NSMutableSet<NSNumber *> *added = [NSMutableSet set];

    for (size_t i = 0; i < sizeof(all) / sizeof(all[0]); i++) {
        WTRewriteOp op = all[i];
        // 行算子只在多行时出现
        if ((op == WTRewriteOpDedupeLines || op == WTRewriteOpSortLines ||
             op == WTRewriteOpNumberLines || op == WTRewriteOpStripBlankLines) && lineCount < 2) continue;
        NSString *err = nil;
        NSString *r = [self applyOp:op toText:text error:&err];
        if (!r || [r isEqualToString:text]) continue;   // no-op 不展示
        if ([added containsObject:@(op)]) continue;
        [added addObject:@(op)];

        WTClipOption *o = [WTClipOption new];
        o.op = op;
        o.title = [self displayNameFor:op];
        o.section = [self sectionFor:op];
        NSString *flat = [[r stringByReplacingOccurrencesOfString:@"\n" withString:@" ⏎ "]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        o.detail = flat.length <= 24 ? flat : [[flat substringToIndex:24] stringByAppendingString:@"…"];
        [out addObject:o];
    }

    if (hasLetter) {
        for (NSNumber *opNum in @[@(WTRewriteOpUpper), @(WTRewriteOpLower)]) {
            NSNumber *op = opNum;
            NSString *r = [self applyOp:op.integerValue toText:text error:NULL];
            if (r && ![r isEqualToString:text] && ![added containsObject:op]) {
                [added addObject:op];
                WTClipOption *o = [WTClipOption new];
                o.op = (WTRewriteOp)op.integerValue;
                o.title = [self displayNameFor:(WTRewriteOp)op.integerValue];
                o.section = [self sectionFor:(WTRewriteOp)op.integerValue];
                o.detail = r.length <= 24 ? r : [[r substringToIndex:24] stringByAppendingString:@"…"];
                [out addObject:o];
            }
        }
    }
    return out;
}

@end
