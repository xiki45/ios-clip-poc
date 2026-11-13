#import <Foundation/Foundation.h>
#import "WTClipEngine.h"

static int pass = 0, fail = 0;
static void check(BOOL cond, NSString *name, NSString *detail) {
    if (cond) { pass++; printf("  ✓ %s\n", name.UTF8String); }
    else { fail++; printf("  ✗ %s  %s\n", name.UTF8String, detail.UTF8String); }
}
static void eq(NSString *got, NSString *want, NSString *name) {
    check([got isEqualToString:want], name,
          [NSString stringWithFormat:@"got=%@ want=%@", got, want]);
}
static NSString *apply(WTRewriteOp op, NSString *t) {
    NSString *e = nil;
    NSString *r = [WTClipEngine applyOp:op toText:t error:&e];
    return r ?: [NSString stringWithFormat:@"<ERR:%@>", e];
}
static BOOL hasOp(NSArray<WTClipOption *> *opts, WTRewriteOp op) {
    for (WTClipOption *o in opts) if (o.op == op) return YES;
    return NO;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        printf("== 算子 ==\n");
        eq(apply(WTRewriteOpBase64Encode, @"hello"), @"aGVsbG8=", @"base64 encode");
        eq(apply(WTRewriteOpBase64Decode, @"aGVsbG8="), @"hello", @"base64 decode");
        eq(apply(WTRewriteOpBase64Decode, @"aGVsbG8"), @"hello", @"base64 decode 无 padding");
        eq(apply(WTRewriteOpBase64Decode, @"Pz8_Pg=="), @"???>", @"base64 urlsafe decode");
        eq(apply(WTRewriteOpURLEncode, @"a b&c"), @"a%20b%26c", @"url encode");
        eq(apply(WTRewriteOpURLDecode, @"a%20b%26c"), @"a b&c", @"url decode");
        eq(apply(WTRewriteOpHexEncode, @"hi"), @"6869", @"hex encode");
        eq(apply(WTRewriteOpHexDecode, @"6869"), @"hi", @"hex decode");
        check([apply(WTRewriteOpJSONPretty, @"{\"b\":1,\"a\":2}") containsString:@"\"a\" : 2"], @"json pretty", apply(WTRewriteOpJSONPretty, @"{\"b\":1,\"a\":2}"));
        eq(apply(WTRewriteOpJSONMinify, @"{\n  \"a\" : 1\n}"), @"{\"a\":1}", @"json minify");
        eq(apply(WTRewriteOpTrim, @"  x  "), @"x", @"trim");
        eq(apply(WTRewriteOpUpper, @"abc"), @"ABC", @"upper");
        eq(apply(WTRewriteOpLower, @"ABC"), @"abc", @"lower");
        eq(apply(WTRewriteOpDedupeLines, @"b\na\nb"), @"b\na", @"dedupe lines");
        eq(apply(WTRewriteOpSortLines, @"b\na"), @"a\nb", @"sort lines");
        eq(apply(WTRewriteOpNumberLines, @"a\nb"), @"1. a\n2. b", @"number lines");
        eq(apply(WTRewriteOpCollapseSpaces, @"a   b\t\tc"), @"a b c", @"合并空白");
        eq(apply(WTRewriteOpStripBlankLines, @"a\n\n\nb\n"), @"a\nb", @"去空行");
        check(apply(WTRewriteOpSHA256, @"x").length == 64, @"sha256 长度", apply(WTRewriteOpSHA256, @"x"));
        eq(apply(WTRewriteOpSHA256, @"abc"),
           @"BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD", @"sha256 已知向量");
        check([apply(WTRewriteOpBase64Decode, @"!!!") hasPrefix:@"<ERR"], @"非法 base64 应失败", apply(WTRewriteOpBase64Decode, @"!!!"));
        check([apply(WTRewriteOpJSONPretty, @"notjson") hasPrefix:@"<ERR"], @"非 JSON 应失败", @"");

        printf("== 分词 ==\n");
        NSArray *t1 = [WTClipEngine tokens:@"支付回调日志"];
        check([t1 isEqualToArray:@[@"支付", @"回调", @"日志"]], @"中文 2-gram 不重叠", [t1 description]);
        NSArray *t2 = [WTClipEngine tokens:@"getOrderId 你好"];
        check([t2 containsObject:@"get"] && [t2 containsObject:@"order"] && [t2 containsObject:@"id"],
              @"驼峰拆分", [t2 description]);
        NSArray *seg = [WTClipEngine tokens:@"文本 https://example.com/a?b=1 支付回调"];
        check([seg containsObject:@"https://example.com/a?b=1"], @"URL 整体保留", [seg description]);
        check([seg containsObject:@"文本"] && [seg containsObject:@"支付"], @"URL 前后文本正常切", [seg description]);
        NSArray *seg2 = [WTClipEngine tokens:@"联系 a@b.com 或 2026-11-13 或 Infoway"];
        check([seg2 containsObject:@"a@b.com"], @"邮箱整体", [seg2 description]);
        check([seg2 containsObject:@"2026-11-13"], @"日期整体", [seg2 description]);
        check([seg2 containsObject:@"infoway"], @"英文整词小写", [seg2 description]);
        NSArray *seg3 = [WTClipEngine tokens:@"支付回调日"];
        check([seg3 isEqualToArray:@[@"支付", @"回调", @"日"]], @"奇数尾字保留", [seg3 description]);
        NSArray *seg4 = [WTClipEngine tokens:@"见 https://infoway.com/x."];
        check([seg4 containsObject:@"https://infoway.com/x"], @"URL 尾部句点剥离", [seg4 description]);
        check([WTClipEngine matches:@"见 https://example.com/x" query:@"example.com"], @"域名可搜", @"");
        check([WTClipEngine matches:@"geTUserName 接口" query:@"user"], @"驼峰内单词可搜", @"");
        check([WTClipEngine matches:@"支付接口回调失败" query:@"支付 回调"], @"多 token AND", @"");
        check(![WTClipEngine matches:@"支付接口失败" query:@"支付 回调"], @"缺 token 不匹配", @"");

        printf("== 选项过滤 ==\n");
        NSString *plain = @"Syscon Infoway Pvt. Ltd";
        NSArray<WTClipOption *> *po = [WTClipEngine optionsForText:plain];
        check(!hasOp(po, WTRewriteOpURLDecode), @"纯文本不出现 URL 解码", @"");
        check(!hasOp(po, WTRewriteOpJSONPretty), @"纯文本不出现美化 JSON", @"");
        check(!hasOp(po, WTRewriteOpDedupeLines), @"单行不出现按行去重", @"");
        check(hasOp(po, WTRewriteOpBase64Encode), @"纯文本保留 Base64", @"");
        check(hasOp(po, WTRewriteOpUpper), @"纯文本保留转大写", @"");
        check(hasOp(po, WTRewriteOpSHA256), @"纯文本保留 SHA-256", @"");
        check(po.count >= 5, @"纯文本至少 5 个可用", [NSString stringWithFormat:@"%lu", (unsigned long)po.count]);
        check(hasOp([WTClipEngine optionsForText:@"{\"a\":1}"], WTRewriteOpJSONPretty), @"JSON 出现美化", @"");
        check(hasOp([WTClipEngine optionsForText:@"b\na\nb"], WTRewriteOpDedupeLines), @"多行出现去重", @"");
        check(hasOp([WTClipEngine optionsForText:@"aGVsbG8="], WTRewriteOpBase64Decode), @"Base64 串出现解码", @"");

        NSArray *samples = @[plain, @"{\"a\":1}", @"b\na\nb", @"aGVsbG8=", @"a%20b", @"  空格  "];
        for (NSString *s in samples) {
            BOOL all = YES;
            for (WTClipOption *o in [WTClipEngine optionsForText:s]) {
                NSString *r = [WTClipEngine applyOp:o.op toText:s error:NULL];
                if (!r || [r isEqualToString:s]) all = NO;
            }
            check(all, [NSString stringWithFormat:@"列出的算子都有效果: %@", s], @"");
        }

        printf("\n结果: pass=%d fail=%d\n", pass, fail);
        return fail == 0 ? 0 : 1;
    }
}
