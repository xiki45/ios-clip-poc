//
//  WTClipEngine.h
//  剪贴板内容重写引擎（ObjC 版，纯 Foundation，可在 macOS 上直接跑测试）
//
//  移植自我们自研键盘的 Rewriter.swift / Tokenizer.swift（64 项测试的同一套语义），
//  这样注入层和自研键盘共用一套规则，行为一致。
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, WTRewriteOp) {
    WTRewriteOpBase64Encode = 0,
    WTRewriteOpBase64Decode,
    WTRewriteOpURLEncode,
    WTRewriteOpURLDecode,
    WTRewriteOpHexEncode,
    WTRewriteOpHexDecode,
    WTRewriteOpJSONPretty,
    WTRewriteOpJSONMinify,
    WTRewriteOpTrim,
    WTRewriteOpUpper,
    WTRewriteOpLower,
    WTRewriteOpSortLines,
    WTRewriteOpDedupeLines,
    WTRewriteOpNumberLines,
    WTRewriteOpSHA256,
    WTRewriteOpCollapseSpaces,
    WTRewriteOpStripBlankLines,
    WTRewriteOpTokenize,
};

/// 一个「点了确实会变」的选项
@interface WTClipOption : NSObject
@property (nonatomic) WTRewriteOp op;
@property (nonatomic, copy) NSString *title;   // 中文名，用于菜单
@property (nonatomic, copy) NSString *detail;  // 结果预览，前 24 字
@property (nonatomic, copy) NSString *section; // 编码 / 文本 / 哈希
@end

@interface WTClipEngine : NSObject

/// 当前内容真正可用的算子：失败的不列，点了不变的也不列
+ (NSArray<WTClipOption *> *)optionsForText:(NSString *)text;

/// 执行一个算子；失败返回 nil 并填 error
+ (NSString *)applyOp:(WTRewriteOp)op toText:(NSString *)text error:(NSString **)error;

/// 自动识别出的「推荐算子」（最多 3 个）
+ (NSArray<NSNumber *> *)recommendedOpsForText:(NSString *)text;

/// 块感知分词
+ (NSArray<NSString *> *)tokens:(NSString *)text;

/// 分词检索：所有 token 都要出现（AND）
+ (BOOL)matches:(NSString *)text query:(NSString *)query;

@end
