//
//  WTGuard.m  ·  v3（去掉 DNS interpose + 分阶段自诊断）
//
//  v1 的实测结果：键盘扩展正常（胶囊显示已拦 187 次），但主 App 一开就闪退。
//  主 App 是我们第一次注入的进程，所以先把「注入本身」和「拦截逻辑」分开验证。
//
//  v2 的做法：所有拦截按 stage 分级，主 App 默认 stage 0（只写日志，不做任何事）。
//  键盘上那个胶囊就是控制台：
//      单击  → 把 wtguard.log 的最后 15 行直接插进当前输入框（不用文件管理器）
//      长按  → 主 App 的 stage +1（0→1→2→3→0），下次启动 App 生效
//
//  分阶段含义：
//      S0  只加载、只写 PROBE 日志（验证注入与签名）
//      S1  + ObjC 层埋点 hook（KBIMEMgr / WBBusinessMgr / 各 SDK）
//      S2  + NSURLProtocol 域名/路径拦截
//      S3  + NSURLProtocol（v3 起不再有 DNS interpose，见下方说明）
//
//  另外两处加固：
//      · 所有 hook 与构造逻辑都包了 @try
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <netdb.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const kGroupID        = @"group.com.tencent.wetype";
static NSString *const kKeyEnabled     = @"wtguard_enabled";
static NSString *const kKeyAllowCrash  = @"wtguard_allow_crash";
static NSString *const kKeyAllowUpload = @"wtguard_allow_uploads";
static NSString *const kKeyAppStage    = @"wtguard_app_stage";

static atomic_int  g_enabled = 1;
static atomic_int  g_stage   = 0;
static atomic_bool g_isApp   = false;

#pragma mark - 日志

static NSString *WTGLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *group = [[NSFileManager defaultManager]
                        containerURLForSecurityApplicationGroupIdentifier:kGroupID];
        if (group) path = [[group URLByAppendingPathComponent:@"wtguard.log"] path];
        if (!path) path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wtguard.log"];
    });
    return path;
}

static NSMutableSet<NSString *> *WTGSeen(void) {
    static NSMutableSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static void WTGLog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list args; va_start(args, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
        va_end(args);
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                          [f stringFromDate:[NSDate date]],
                          atomic_load(&g_isApp) ? @"app" : @"kb", msg];
        FILE *fp = fopen(WTGLogPath().UTF8String, "a");
        if (fp) { fputs(line.UTF8String, fp); fclose(fp); }
    }
}

static NSString *WTGLogTail(NSUInteger lines) {
    NSString *all = [NSString stringWithContentsOfFile:WTGLogPath()
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    if (all.length == 0) return @"(空日志)";
    NSArray *ls = [all componentsSeparatedByString:@"\n"];
    if (ls.count <= lines) return all;
    NSArray *tail = [ls subarrayWithRange:NSMakeRange(ls.count - lines, lines)];
    return [tail componentsJoinedByString:@"\n"];
}

#pragma mark - 状态

static void WTGLoadState(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id en = [d objectForKey:kKeyEnabled];
    atomic_store(&g_enabled, en ? ([en boolValue] ? 1 : 0) : 1);
    id st = [d objectForKey:kKeyAppStage];
    int s = st ? [st intValue] : 2;      // S0-S2 已验证可用，新装默认 S2
    atomic_store(&g_stage, MAX(0, MIN(4, s)));
}

static int WTGAppStageDisplay(void) {
    id st = [[NSUserDefaults standardUserDefaults] objectForKey:kKeyAppStage];
    return st ? [st intValue] : 2;
}

static BOOL WTGOn(void)      { return atomic_load(&g_enabled) != 0; }
static int  WTGStage(void)   { return atomic_load(&g_stage); }
static BOOL WTGAllowUploads(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kKeyAllowUpload];
    return v ? [v boolValue] : NO;
}
static BOOL WTGAllowCrash(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kKeyAllowCrash];
    return v ? [v boolValue] : NO;
}

static NSUInteger WTGCount = 0;
static void WTGHit(NSString *what) {
    WTGCount++;
    WTGLog(@"拦截 %@ (累计 %lu)", what, (unsigned long)WTGCount);
}

#pragma mark - hook 工具

static void WTGHook(Class cls, SEL sel, IMP newImp, IMP *orig) {
    if (!cls || !sel) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (orig) *orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

#pragma mark - S1：键盘扩展 KBIMEMgr

typedef void (*two_id_t)(id, SEL, id, id);
static two_id_t o_kb_report_pb, o_kb_report_b64, o_kb_report_inst, o_kb_report_sa;

static void g_kb_report_pb(id s, SEL c, id rid, id pb) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"KBIMEMgr reportID:pb: %@", rid]); return; }
    if (o_kb_report_pb) o_kb_report_pb(s, c, rid, pb);
}
static void g_kb_report_b64(id s, SEL c, id rid, id d) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"KBIMEMgr reportID:pbBase64Content: %@", rid]); return; }
    if (o_kb_report_b64) o_kb_report_b64(s, c, rid, d);
}
static void g_kb_report_inst(id s, SEL c, id rid, id pb) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"KBIMEMgr reportInstance:pb: %@", rid]); return; }
    if (o_kb_report_inst) o_kb_report_inst(s, c, rid, pb);
}
static void g_kb_report_sa(id s, SEL c, id rid, id pb) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"KBIMEMgr reportForStandAloneMode:pb: %@", rid]); return; }
    if (o_kb_report_sa) o_kb_report_sa(s, c, rid, pb);
}
static void g_kb_keystroke(id s, SEL c, id a, unsigned char t, id kc, id content) {
    if (WTGOn()) WTGHit(@"reportKeystroke(含 keyContent)");
}
static void g_kb_keystroke_end(id s, SEL c, id a, unsigned char t, id finalText) {
    if (WTGOn()) WTGHit(@"reportKeystrokeSessionEnd(含 sessionFinalText)");
}
static void g_kb_emoji(id s, SEL c, id a, id b, unsigned long long t, id text) {
    if (WTGOn()) WTGHit(@"reportEmojiEvent(含 beforeText)");
}
static void g_kb_sticker(id s, SEL c, id a, id b, id cand, id last) {
    if (WTGOn()) WTGHit(@"reportStickerEvent");
}
static void g_kb_candclick(id s, SEL c, id a, id b, id cands,
                           long long v, long long idx, long long src, long long panel,
                           unsigned long long n) {
    if (WTGOn()) WTGHit(@"reportCandidateClick(含候选词)");
}
static void g_kb_noarg(id s, SEL c) {
    if (WTGOn()) WTGHit([NSString stringWithFormat:@"KBIMEMgr %@", NSStringFromSelector(c)]);
}

#pragma mark - S1：主 App WBBusinessMgr

static two_id_t o_bb_rid_c, o_bb_rid_b, o_bb_dorid_b, o_bb_inst_c, o_bb_inst_b;

static void g_bb_rid_c(id s, SEL c, id rid, id v) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr reportID:content: %@", rid]); return; }
    if (o_bb_rid_c) o_bb_rid_c(s, c, rid, v);
}
static void g_bb_rid_b(id s, SEL c, id rid, id v) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr reportID:base64Content: %@", rid]); return; }
    if (o_bb_rid_b) o_bb_rid_b(s, c, rid, v);
}
static void g_bb_dorid_b(id s, SEL c, id rid, id v) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr doReportID:base64Content: %@", rid]); return; }
    if (o_bb_dorid_b) o_bb_dorid_b(s, c, rid, v);
}
static void g_bb_inst_c(id s, SEL c, id rid, id v) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr reportInstantID:content: %@", rid]); return; }
    if (o_bb_inst_c) o_bb_inst_c(s, c, rid, v);
}
static void g_bb_inst_b(id s, SEL c, id rid, id v) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr reportInstantID:base64Content: %@", rid]); return; }
    if (o_bb_inst_b) o_bb_inst_b(s, c, rid, v);
}
static void g_bb_bugly(id s, SEL c, unsigned long long uin) {
    if (WTGOn()) WTGHit(@"WBBusinessMgr updateBuglyUserId");
}

#pragma mark - S1：SDK 埋点

typedef int (*ratio_t)(id, SEL, id);
static ratio_t o_ratio;
static int g_ratio(id s, SEL c, id rid) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"采样拒绝 %@", rid]); return 0; }
    return o_ratio ? o_ratio(s, c, rid) : 100;
}

static void g_noop(id s, SEL c) {
    if (WTGOn()) WTGHit([NSString stringWithFormat:@"%@ %@", NSStringFromClass([s class]), NSStringFromSelector(c)]);
}
static void g_noop_1(id s, SEL c, id a) { g_noop(s, c); }
static void g_noop_3(id s, SEL c, id a, id b, id d) { g_noop(s, c); }
static void g_noop_b(id s, SEL c, id a, id b, BOOL v) { g_noop(s, c); }
static void g_noop_bi(id s, SEL c, id a, id b, BOOL v, int i) { g_noop(s, c); }

#pragma mark - S2：NSURLProtocol

static NSArray<NSString *> *WTGBlockedHosts(void) {
    return @[ @"trace.qq.com", @"rqd.qq.com", @"rdelivery.qq.com", @"rconfig.qq.com",
              @"tdos.vip", @"weread.qq.com", @"bugly.qq.com", @"buglybugly.qq.com",
              @"android.bugly.qq.com" ];
}

static BOOL WTGHostBlocked(NSString *host) {
    if (host.length == 0) return NO;
    NSString *h = host.lowercaseString;
    for (NSString *b in WTGBlockedHosts()) {
        if ([h isEqualToString:b] || [h hasSuffix:[@"." stringByAppendingString:b]]) return YES;
    }
    return NO;
}

static BOOL WTGPathBlocked(NSURL *url) {
    if (WTGAllowUploads()) return NO;
    NSString *p = url.path.lowercaseString;
    if (p.length == 0) return NO;
    if ([p containsString:@"/upload-file"]) return YES;
    if ([p containsString:@"/v1/"] && [p containsString:@"upload-json"]) return YES;
    return NO;
}

@interface WTGBlockProtocol : NSURLProtocol @end
@implementation WTGBlockProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!WTGOn()) return NO;
    static NSString *const kH = @"WTGHandled";
    if ([NSURLProtocol propertyForKey:kH inRequest:request]) return NO;
    NSURL *u = request.URL;
    if (WTGHostBlocked(u.host)) { WTGHit([NSString stringWithFormat:@"URL 域名 %@", u.host]); return YES; }
    if (WTGPathBlocked(u)) { WTGHit([NSString stringWithFormat:@"URL 路径 %@", u.path]); return YES; }
    return NO;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }
- (void)startLoading {
    NSError *e = [NSError errorWithDomain:@"WTGuard" code:-999
                                 userInfo:@{NSLocalizedDescriptionKey: @"blocked"}];
    [self.client URLProtocol:self didFailWithError:e];
}
- (void)stopLoading {}
@end

#pragma mark - S3：DNS 拦截已移除（v3）

// v1/v2 用 __DATA,__interpose 替换 getaddrinfo，这是主 App 闪退的头号嫌疑：
//   该 interpose 在 dylib 一被 dyld 加载时就生效（早于 constructor），
//   而替换函数里要 dlsym(RTLD_NEXT) 取原函数；进程早期解析可能拿到空/错值，
//   一旦调用就是立刻崩溃 —— 而扩展是在进程跑热之后才加载，所以扩展没事。
// v3 直接删掉这一层：埋点收口 + NSURLProtocol 已经覆盖绝大部分，
// 换取「主 App 一定能启动」这个确定性。


#pragma mark - S4：DNS 层（安全版，只改自己镜像的导入槽）

// 实测发现：WeType 自己不用 getaddrinfo，它走的是 CFHost（CFNetwork）。
//   wxkb        : 导入 _CFHostCreateWithName / _CFHostStartInfoResolution …
//   wxkb_plugin : 同上
// 所以 v1 那个全局 getaddrinfo interpose 拦到的其实是系统框架内部的调用 —— 范围太大、
// 时机太早（镜像加载即生效，早于 constructor），这正是主 App 启动即崩的原因。
//
// v5 改成：constructor 里（dyld 已稳定）遍历主镜像的 chained fixups，
// 把导入名为 CFHost* 的槽位换成我们的函数，原地址存下来照常调用。
// 只影响 WeType 自己的镜像，系统/框架一概不碰，也不可能在启动早期被触发。

#include <mach-o/dyld.h>
#include <mach-o/loader.h>

typedef CFHostRef (*cfhost_create_t)(CFAllocatorRef, CFStringRef);
typedef Boolean  (*cfhost_resolve_t)(CFHostRef, CFHostInfoType, CFErrorRef *);

static cfhost_create_t  WTGOrigHostCreate;
static cfhost_resolve_t WTGOrigHostResolve;
static NSMapTable *WTGHostNames;      // CFHostRef -> CFStringRef(host)

static NSMapTable *WTGHostMap(void) {
    static NSMapTable *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory
                                  valueOptions:NSPointerFunctionsStrongMemory];
    });
    return m;
}

static CFHostRef wtg_host_create(CFAllocatorRef alloc, CFStringRef name) {
    CFHostRef host = WTGOrigHostCreate ? WTGOrigHostCreate(alloc, name) : NULL;
    if (host && name) {
        @synchronized (WTGHostMap()) { [WTGHostMap() setObject:(__bridge id)name forKey:(__bridge id)host]; }
    }
    return host;
}

static Boolean wtg_host_resolve(CFHostRef host, CFHostInfoType info, CFErrorRef *err) {
    if (host) {
        @try {
            NSString *name = nil;
            @synchronized (WTGHostMap()) {
                id stored = [WTGHostMap() objectForKey:(__bridge id)host];
                if (stored) name = [(NSString *)stored copy];
            }
            if (name.length) {
                BOOL fresh = NO;
                @synchronized (WTGSeen()) {
                    if (![WTGSeen() containsObject:name]) { [WTGSeen() addObject:name]; fresh = YES; }
                }
                if (fresh) WTGLog(@"DNS 看到 %@", name);
                if (WTGOn() && WTGHostBlocked(name)) {
                    WTGHit([NSString stringWithFormat:@"DNS 拦截 %@", name]);
                    return false;      // 走 CFHost 正常的失败分支
                }
            }
        } @catch (NSException *e) {}
    }
    return WTGOrigHostResolve ? WTGOrigHostResolve(host, info, err) : false;
}

#define WTG_MAX_SEC 24
static struct { uint64_t addr; uint64_t size; } g_secs[WTG_MAX_SEC];
static int g_secCount;

static BOOL wtg_addr_in_sections(uintptr_t a) {
    for (int i = 0; i < g_secCount; i++) {
        if (a >= g_secs[i].addr && a < g_secs[i].addr + g_secs[i].size) return YES;
    }
    return NO;
}

static void wtg_collect_sections(const struct mach_header_64 *mh, uintptr_t base, uint64_t textVm) {
    g_secCount = 0;
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            const struct section_64 *sc = (const struct section_64 *)(sg + 1);
            for (uint32_t j = 0; j < sg->nsects && g_secCount < WTG_MAX_SEC; j++) {
                if (!strcmp(sc[j].sectname, "__la_symbol_ptr") ||
                    !strcmp(sc[j].sectname, "__got") ||
                    !strcmp(sc[j].sectname, "__auth_got")) {
                    g_secs[g_secCount].addr = base + (sc[j].addr - textVm);
                    g_secs[g_secCount].size = sc[j].size;
                    g_secCount++;
                }
            }
        }
        p += lc->cmdsize;
    }
}

struct wtg_fixups_header {
    uint32_t fixups_version, starts_offset, imports_offset, symbols_offset;
    uint32_t imports_count, imports_format, symbols_format;
};
struct wtg_starts_in_image { uint32_t seg_count; uint32_t seg_info_offset[1]; };
struct wtg_starts_in_segment {
    uint32_t size; uint16_t page_size, pointer_format;
    uint64_t segment_offset; uint32_t max_valid_pointer; uint16_t page_count, page_start[1];
};

static void wtg_patch_host_image(void) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!mh || mh->magic != MH_MAGIC_64) { WTGLog(@"DNS：取不到主镜像头"); return; }
    uintptr_t base = (uintptr_t)mh;

    uint64_t textVm = 0, leVm = 0, leOff = 0;
    BOOL hasLe = NO;
    const struct linkedit_data_command *cf = NULL;
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            if (!strcmp(sg->segname, "__TEXT")) textVm = sg->vmaddr;
            if (!strcmp(sg->segname, "__LINKEDIT")) { leVm = sg->vmaddr; leOff = sg->fileoff; hasLe = YES; }
        } else if (lc->cmd == LC_DYLD_CHAINED_FIXUPS) {
            cf = (const struct linkedit_data_command *)lc;
        }
        p += lc->cmdsize;
    }
    if (!cf || !hasLe) { WTGLog(@"DNS：镜像缺 chained fixups / __LINKEDIT，跳过"); return; }

    wtg_collect_sections(mh, base, textVm);
    if (g_secCount == 0) { WTGLog(@"DNS：没找到 __got/__la_symbol_ptr"); return; }

    const uint8_t *fix = (const uint8_t *)(base + (leVm - textVm) + (cf->dataoff - leOff));
    const struct wtg_fixups_header *h = (const struct wtg_fixups_header *)fix;
    if (h->imports_format != 1 && h->imports_format != 3) {
        WTGLog(@"DNS：imports_format=%u 不支持", h->imports_format);
        return;
    }
    const uint8_t *imports = fix + h->imports_offset;
    const char *syms = (const char *)(fix + h->symbols_offset);

    NSMutableDictionary<NSNumber *, NSNumber *> *plan = [NSMutableDictionary dictionary];  // ordinal -> 0/1/2
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (uint32_t i = 0; i < h->imports_count; i++) {
        uint32_t nameOff = 0;
        if (h->imports_format == 1) {
            struct { uint32_t lib:8, weak:1, name:23; } im;
            memcpy(&im, imports + i * 4, 4);
            nameOff = im.name;
        } else {
            struct { uint64_t ord:16, weak:1, res:15, name:32; uint64_t addend; } im;
            memcpy(&im, imports + i * 16, 16);
            nameOff = (uint32_t)im.name;
        }
        NSString *sym = [NSString stringWithUTF8String:(syms + nameOff)];
        if (!sym) continue;
        NSString *t = sym;
        if ([t hasPrefix:@"_"]) t = [t substringFromIndex:1];
        if ([t isEqualToString:@"CFHostCreateWithName"])       plan[@(i)] = @0;
        else if ([t isEqualToString:@"CFHostStartInfoResolution"]) plan[@(i)] = @1;
        else continue;
        [names addObject:sym];
    }
    if (plan.count == 0) { WTGLog(@"DNS：镜像里没有 CFHost 导入"); return; }

    const struct wtg_starts_in_image *si = (const struct wtg_starts_in_image *)(fix + h->starts_offset);
    int patched = 0;
    for (uint32_t seg = 0; seg < si->seg_count; seg++) {
        uint32_t off = si->seg_info_offset[seg];
        if (off == 0) continue;
        const struct wtg_starts_in_segment *ss =
            (const struct wtg_starts_in_segment *)(((const uint8_t *)si) + off);
        for (uint16_t pg = 0; pg < ss->page_count; pg++) {
            uint16_t start = ss->page_start[pg];
            if (start == 0xFFFF) continue;
            uintptr_t cur = base + ss->segment_offset + (uintptr_t)pg * ss->page_size + start;
            for (int guard = 0; guard < 400000; guard++) {
                uint64_t v = *(volatile uint64_t *)cur;
                // PTR_64 / PTR_64_OFFSET 家族的 bind 位在 bit63（arm64e 才是 bit62）
                BOOL isBind = (v >> 63) & 1;
                uint32_t next = (uint32_t)((v >> 51) & 0xFFF);
                if (isBind) {
                    NSNumber *kind = plan[@((uint32_t)(v & 0xFFFFFF))];
                    if (kind && wtg_addr_in_sections(cur)) {
                        if (kind.intValue == 0) {
                            if (!WTGOrigHostCreate) WTGOrigHostCreate = (cfhost_create_t)(uintptr_t)v;
                            *(uint64_t *)cur = (uint64_t)(uintptr_t)&wtg_host_create;
                        } else {
                            if (!WTGOrigHostResolve) WTGOrigHostResolve = (cfhost_resolve_t)(uintptr_t)v;
                            *(uint64_t *)cur = (uint64_t)(uintptr_t)&wtg_host_resolve;
                        }
                        patched++;
                    }
                }
                if (next == 0) break;
                cur += next * 4;
            }
        }
    }
    WTGLog(@"DNS：CFHost 槽位打了 %d 个，导入=%@", patched, names);
}

#pragma mark - 胶囊控制台（仅键盘扩展）

static const void *kChipKey = &kChipKey;
static const void *kTapKey  = &kTapKey;
static const void *kLongKey = &kLongKey;

@interface WTGChip : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *host;
- (void)render;
@end

@implementation WTGChip

- (UILabel *)label { return objc_getAssociatedObject(self.host, kChipKey); }

- (void)render {
    UILabel *l = [self label];
    if (!l) return;
    UILabel *chip = l;
    chip.text = [NSString stringWithFormat:@"盾%lu·A%d", (unsigned long)WTGCount, WTGAppStageDisplay()];
    chip.backgroundColor = WTGOn() ? [UIColor colorWithRed:0.15 green:0.45 blue:0.85 alpha:0.92]
                                   : [UIColor colorWithWhite:0.4 alpha:0.8];
}

- (void)insertTail {
    NSString *tail = WTGLogTail(15);
    if (tail.length > 900) tail = [tail substringFromIndex:tail.length - 900];
    UIViewController *vc = self.host;
    if (![vc isKindOfClass:[UIInputViewController class]]) return;
    id proxy = [(UIInputViewController *)vc textDocumentProxy];
    if ([proxy respondsToSelector:@selector(insertText:)]) [proxy insertText:tail];
    WTGLog(@"日志尾已插入（15 行）");
}

- (void)tap:(UITapGestureRecognizer *)g {
    UIView *v = g.view; UILabel *chip = [self label];
    if (!v || !chip) return;
    CGPoint p = [g locationInView:v];
    CGRect f = [chip.superview convertRect:chip.frame toView:v];
    if (!CGRectContainsPoint(CGRectInset(f, -8, -8), p)) return;
    [self insertTail];
    [self render];
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIView *v = g.view; UILabel *chip = [self label];
    if (!v || !chip) return;
    CGPoint p = [g locationInView:v];
    CGRect f = [chip.superview convertRect:chip.frame toView:v];
    if (!CGRectContainsPoint(CGRectInset(f, -10, -10), p)) return;

    int next = (WTGAppStageDisplay() + 1) % 5;
    [[NSUserDefaults standardUserDefaults] setInteger:next forKey:kKeyAppStage];
    [[NSUserDefaults standardUserDefaults] synchronize];
    WTGLog(@"主 App stage → S%d（杀掉微信输入法 App 重开生效；键盘本身恒为全开）", next);
    [self render];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return YES; }
@end

static void WTGLayoutChip(UIViewController *vc) {
    UIView *container = vc.view.window ?: vc.view;
    UILabel *chip = objc_getAssociatedObject(vc, kChipKey);
    if (!chip) {
        chip = [UILabel new];
        chip.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        chip.textColor = [UIColor whiteColor];
        chip.textAlignment = NSTextAlignmentCenter;
        chip.layer.cornerRadius = 7;
        chip.layer.masksToBounds = YES;
        objc_setAssociatedObject(vc, kChipKey, chip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        WTGChip *h = [WTGChip new];
        h.host = vc;

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:h action:@selector(tap:)];
        tap.delegate = h; tap.cancelsTouchesInView = NO;
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
                                            initWithTarget:h action:@selector(longPress:)];
        lp.minimumPressDuration = 0.6; lp.delegate = h; lp.cancelsTouchesInView = NO;

        if (!objc_getAssociatedObject(container, kTapKey)) {
            [container addGestureRecognizer:tap];
            [container addGestureRecognizer:lp];
            objc_setAssociatedObject(container, kTapKey, h, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(container, kLongKey, h, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        WTGLog(@"胶囊控制台已装");
    }
    if (chip.superview != container) [container addSubview:chip];

    CGRect anchor = [vc.view convertRect:vc.view.bounds toView:container];
    chip.frame = CGRectMake(anchor.origin.x + 6, anchor.origin.y + 4, 64, 19);
    [chip.superview bringSubviewToFront:chip];

    WTGChip *h = objc_getAssociatedObject(container, kTapKey);
    [h render];
}

#pragma mark - 安装

static void (*o_viewDidLoad)(id, SEL);
static void (*o_viewDidLayout)(id, SEL);

static void g_viewDidLoad(id self, SEL c) {
    if (o_viewDidLoad) o_viewDidLoad(self, c);
    @try { WTGLayoutChip((UIViewController *)self); } @catch (NSException *e) {}
}
static void g_viewDidLayout(id self, SEL c) {
    if (o_viewDidLayout) o_viewDidLayout(self, c);
    @try { WTGLayoutChip((UIViewController *)self); } @catch (NSException *e) {}
}

static void WTGInstallAppHooks(int stage) {
    Class bb = objc_getClass("WBBusinessMgr");
    if (bb) {
        WTGHook(bb, @selector(reportID:content:), (IMP)g_bb_rid_c, (IMP *)&o_bb_rid_c);
        WTGHook(bb, @selector(reportID:base64Content:), (IMP)g_bb_rid_b, (IMP *)&o_bb_rid_b);
        WTGHook(bb, @selector(doReportID:base64Content:), (IMP)g_bb_dorid_b, (IMP *)&o_bb_dorid_b);
        WTGHook(bb, @selector(reportInstantID:content:), (IMP)g_bb_inst_c, (IMP *)&o_bb_inst_c);
        WTGHook(bb, @selector(reportInstantID:base64Content:), (IMP)g_bb_inst_b, (IMP *)&o_bb_inst_b);
        WTGHook(bb, @selector(updateBuglyUserId:), (IMP)g_bb_bugly, NULL);
    }
    WTGLog(@"S%d 业务收口 hook 完成", stage);
    if (stage < 2) return;

    Class rd = objc_getClass("RDeliveyDataReporter");
    if (rd) WTGHook(rd, @selector(reportEvent:params:forceReport:), (IMP)g_noop_b, NULL);
    Class raft = objc_getClass("RAFTMeasureService");
    if (raft) {
        WTGHook(raft, @selector(reportSuccess:key:success:), (IMP)g_noop_b, NULL);
        WTGHook(raft, @selector(reportSuccess:key:success:samplingRate:), (IMP)g_noop_bi, NULL);
        WTGHook(raft, @selector(reportDistribution:key:sValue:), (IMP)g_noop_3, NULL);
        WTGHook(raft, @selector(reportStartup:), (IMP)g_noop_1, NULL);
    }
    if (!WTGAllowCrash()) {
        Class dau = objc_getClass("BuglyDAUReporter");
        if (dau) {
            WTGHook(dau, @selector(reportDAUEvent), (IMP)g_noop, NULL);
            WTGHook(dau, @selector(reportDAUWithActivateModules:), (IMP)g_noop_1, NULL);
        }
        Class bly = objc_getClass("BLYAnalyticsManager");
        if (bly) WTGHook(bly, @selector(reportAnalyticsEvent), (IMP)g_noop, NULL);
        Class mt = objc_getClass("WBMetrics");
        if (mt) WTGHook(mt, @selector(uploadDiagnosticZipFile), (IMP)g_noop, NULL);
        // 崩溃本体也不再外发（含设备信息与堆栈）
        Class blyMgr = objc_getClass("BLYSDKManager");
        if (blyMgr) {
            WTGHook(blyMgr, @selector(reportException:reason:extraInfo:), (IMP)g_noop_3, NULL);
            WTGHook(blyMgr, @selector(reportError:reason:extraInfo:), (IMP)g_noop_3, NULL);
        }
        Class bugly = objc_getClass("Bugly");
        if (bugly) {
            WTGHook(bugly, @selector(reportException:), (IMP)g_noop_1, NULL);
            WTGHook(bugly, @selector(reportError:), (IMP)g_noop_1, NULL);
        }
    }

    // Sentry：设置页/反馈页的 JS 错误上报
    Class hub = objc_getClass("SentryHub");
    if (hub) {
        WTGHook(hub, @selector(captureEvent:), (IMP)g_noop_1, NULL);
        WTGHook(hub, @selector(captureMessage:), (IMP)g_noop_1, NULL);
    }
    Class client = objc_getClass("SentryClient");
    if (client) {
        WTGHook(client, @selector(captureEnvelope:), (IMP)g_noop_1, NULL);
    }
    WTGLog(@"S%d SDK 埋点 hook 完成", stage);
}

static void WTGInstallHooks(void) {
    Class kbi = objc_getClass("KBIMEMgr");
    if (kbi) {
        WTGHook(kbi, @selector(reportID:pb:), (IMP)g_kb_report_pb, (IMP *)&o_kb_report_pb);
        WTGHook(kbi, @selector(reportID:pbBase64Content:), (IMP)g_kb_report_b64, (IMP *)&o_kb_report_b64);
        WTGHook(kbi, @selector(reportInstance:pb:), (IMP)g_kb_report_inst, (IMP *)&o_kb_report_inst);
        WTGHook(kbi, @selector(reportForStandAloneMode:pb:), (IMP)g_kb_report_sa, (IMP *)&o_kb_report_sa);
        WTGHook(kbi, @selector(reportKeystrokeForSession:keyType:keyCode:keyContent:), (IMP)g_kb_keystroke, NULL);
        WTGHook(kbi, @selector(reportKeystrokeSessionEndForSession:triggerType:sessionFinalText:), (IMP)g_kb_keystroke_end, NULL);
        WTGHook(kbi, @selector(reportEmojiEvent:session:emojiType:beforeText:), (IMP)g_kb_emoji, NULL);
        WTGHook(kbi, @selector(reportStickerEvent:session:sourceCandidate:lastDisplayCandidate:), (IMP)g_kb_sticker, NULL);
        WTGHook(kbi, @selector(reportCandidateClick:session:candidates:cloudServiceVersion:firstScreenFullVisibleLastCellIndex:hwClickSource:currentPanelType:typingNum:), (IMP)g_kb_candclick, NULL);
        WTGHook(kbi, @selector(reportProcessInfo), (IMP)g_kb_noarg, NULL);
        WTGHook(kbi, @selector(reportFullAccessStat), (IMP)g_kb_noarg, NULL);
    }

    Class bb = objc_getClass("WBBusinessMgr");
    if (bb) {
        WTGHook(bb, @selector(reportID:content:), (IMP)g_bb_rid_c, (IMP *)&o_bb_rid_c);
        WTGHook(bb, @selector(reportID:base64Content:), (IMP)g_bb_rid_b, (IMP *)&o_bb_rid_b);
        WTGHook(bb, @selector(doReportID:base64Content:), (IMP)g_bb_dorid_b, (IMP *)&o_bb_dorid_b);
        WTGHook(bb, @selector(reportInstantID:content:), (IMP)g_bb_inst_c, (IMP *)&o_bb_inst_c);
        WTGHook(bb, @selector(reportInstantID:base64Content:), (IMP)g_bb_inst_b, (IMP *)&o_bb_inst_b);
        WTGHook(bb, @selector(updateBuglyUserId:), (IMP)g_bb_bugly, NULL);
    }

    // 注：v1 曾把 sampleRatioForReportID: 改成返回 0，怀疑正是主 App 闪退的原因之一
    // （调用方若把它当除数 / 取模基数就会 SIGFPE）。这里不再动它，靠上面的收口拦就够了。
    Class rd = objc_getClass("RDeliveyDataReporter");
    if (rd) WTGHook(rd, @selector(reportEvent:params:forceReport:), (IMP)g_noop_b, NULL);
    Class raft = objc_getClass("RAFTMeasureService");
    if (raft) {
        WTGHook(raft, @selector(reportSuccess:key:success:), (IMP)g_noop_b, NULL);
        WTGHook(raft, @selector(reportSuccess:key:success:samplingRate:), (IMP)g_noop_bi, NULL);
        WTGHook(raft, @selector(reportDistribution:key:sValue:), (IMP)g_noop_3, NULL);
        WTGHook(raft, @selector(reportStartup:), (IMP)g_noop_1, NULL);
    }
    if (!WTGAllowCrash()) {
        Class dau = objc_getClass("BuglyDAUReporter");
        if (dau) {
            WTGHook(dau, @selector(reportDAUEvent), (IMP)g_noop, NULL);
            WTGHook(dau, @selector(reportDAUWithActivateModules:), (IMP)g_noop_1, NULL);
        }
        Class bly = objc_getClass("BLYAnalyticsManager");
        if (bly) WTGHook(bly, @selector(reportAnalyticsEvent), (IMP)g_noop, NULL);
        Class mt = objc_getClass("WBMetrics");
        if (mt) WTGHook(mt, @selector(uploadDiagnosticZipFile), (IMP)g_noop, NULL);
        // 崩溃本体也不再外发（含设备信息与堆栈）
        Class blyMgr = objc_getClass("BLYSDKManager");
        if (blyMgr) {
            WTGHook(blyMgr, @selector(reportException:reason:extraInfo:), (IMP)g_noop_3, NULL);
            WTGHook(blyMgr, @selector(reportError:reason:extraInfo:), (IMP)g_noop_3, NULL);
        }
        Class bugly = objc_getClass("Bugly");
        if (bugly) {
            WTGHook(bugly, @selector(reportException:), (IMP)g_noop_1, NULL);
            WTGHook(bugly, @selector(reportError:), (IMP)g_noop_1, NULL);
        }
    }

    // Sentry：设置页/反馈页的 JS 错误上报
    Class hub = objc_getClass("SentryHub");
    if (hub) {
        WTGHook(hub, @selector(captureEvent:), (IMP)g_noop_1, NULL);
        WTGHook(hub, @selector(captureMessage:), (IMP)g_noop_1, NULL);
    }
    Class client = objc_getClass("SentryClient");
    if (client) {
        WTGHook(client, @selector(captureEnvelope:), (IMP)g_noop_1, NULL);
    }
    WTGLog(@"S1 hook 完成");
}

__attribute__((constructor)) static void wtg_init(void) {
    @autoreleasepool {
        NSString *bundle = [[NSBundle mainBundle] bundlePath];
        BOOL inApp = [bundle hasSuffix:@".app"];
        atomic_store(&g_isApp, inApp);
        WTGLoadState();

        WTGLog(@"===== PROBE-1 loaded stage=S%d app=%d path=%@ =====",
               WTGStage(), (int)inApp, bundle.lastPathComponent);

        @try {
            if (!inApp) {
                // 键盘扩展：一直全开（上一版已验证可用）
                atomic_store(&g_stage, 3);
                WTGInstallHooks();
                [NSURLProtocol registerClass:[WTGBlockProtocol class]];
                Class vc = objc_getClass("WBInputViewController");
                WTGHook(vc, @selector(viewDidLoad), (IMP)g_viewDidLoad, (IMP *)&o_viewDidLoad);
                WTGHook(vc, @selector(viewDidLayoutSubviews), (IMP)g_viewDidLayout, (IMP *)&o_viewDidLayout);
                @try { wtg_patch_host_image(); }
                @catch (NSException *e) { WTGLog(@"DNS 层异常 %@", e); }
                WTGLog(@"键盘扩展：S4 全量拦截已启用");
            } else {
                int s = WTGStage();
                if (s >= 1) { WTGInstallAppHooks(s); }
                if (s >= 3) { [NSURLProtocol registerClass:[WTGBlockProtocol class]]; }
                if (s >= 4) {
                    @try { wtg_patch_host_image(); }
                    @catch (NSException *e) { WTGLog(@"DNS 层异常 %@", e); }
                }
                WTGLog(@"主 App：S%d 已启用（S0=只观测 S1=埋点 S2=URL S3=DNS）", s);
            }
        } @catch (NSException *e) {
            WTGLog(@"init 异常 %@", e);
        }

        WTGLog(@"===== PROBE-2 init done =====");
    }
}
