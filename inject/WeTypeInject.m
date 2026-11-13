//
//  WeTypeInject.m  ·  v7
//
//  阶段 3：把「剪贴板 + 重写」做进微信输入法键盘。
//
//  已验证的前置（v5/v6）：
//    dylib 能加载 → UI 能加 → window 级手势能收到点击 → insertText 能写字
//    → 完全访问打开后能读剪贴板
//
//  v7 行为：
//    点右上角「重写」→ 菜单列出当前剪贴板内容可用的算子（推荐在前）
//    点某一项 → 结果插进光标，菜单关闭
//    点菜单外面 → 关闭；条目多时最后一行是「更多」
//
//  点击一律走 window 级手势 + 坐标分发，不依赖按钮/子视图的 hitTest
//  （这条经验是被 v4/v5 的坑换来的：微信输入法在 vc.view 之上还有东西）。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "WTClipEngine.h"
#import "WTPanelView.h"

static NSString *const kTag = @"[wtinject]";

#pragma mark - 日志

static NSString *WTLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *group = [[NSFileManager defaultManager]
                        containerURLForSecurityApplicationGroupIdentifier:@"group.com.tencent.wetype"];
        if (group) path = [[group URLByAppendingPathComponent:@"wtinject.log"] path];
        if (!path) path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wtinject.log"];
    });
    return path;
}

static void WTLog(NSString *fmt, ...) {
    @try {
        va_list args; va_start(args, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
        va_end(args);
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ %@ %@\n",
                          [f stringFromDate:[NSDate date]], kTag, msg];
        NSLog(@"[wtinject] %@", msg);
        FILE *fp = fopen(WTLogPath().UTF8String, "a");
        if (fp) { fputs(line.UTF8String, fp); fclose(fp); }
    } @catch (NSException *e) { NSLog(@"[wtinject] log fail: %@", e); }
}

#pragma mark - 颜色 / 关联键

static const void *kButtonKey  = &kButtonKey;
static const void *kHandlerKey = &kHandlerKey;
static const void *kGestureKey = &kGestureKey;
static const void *kPanelKey   = &kPanelKey;

static UIColor *WTGreen(void) { return [UIColor colorWithRed:0.00 green:0.62 blue:0.42 alpha:1]; }
static UIColor *WTOrange(void){ return [UIColor colorWithRed:0.95 green:0.52 blue:0.10 alpha:1]; }
static UIColor *WTRed(void)   { return [UIColor colorWithRed:0.85 green:0.20 blue:0.20 alpha:1]; }
static UIColor *WTBlue(void)  { return [UIColor colorWithRed:0.10 green:0.45 blue:0.90 alpha:1]; }

static void WTSetState(UIButton *btn, NSString *title, UIColor *bg) {
    if (!btn) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [btn setTitle:title forState:UIControlStateNormal];
        btn.backgroundColor = bg;
    });
}

#pragma mark - 剪贴板

static NSString *WTClipboardText(void) {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *s = pb.string;
    if (s.length == 0) s = [pb.strings firstObject];
    return s.length ? s : nil;
}

static BOOL WTInsert(UIViewController *vc, NSString *text) {
    if (![vc isKindOfClass:[UIInputViewController class]]) return NO;
    if (text.length == 0) return NO;
    id proxy = [(UIInputViewController *)vc textDocumentProxy];
    if (![proxy respondsToSelector:@selector(insertText:)]) return NO;
    [proxy insertText:text];
    WTLog(@"插入 %lu 字", (unsigned long)text.length);
    return YES;
}

#pragma mark - 排序：推荐 → 编码 → 文本 → 哈希

static NSArray<WTClipOption *> *WTSortedOptions(NSString *text) {
    NSArray<WTClipOption *> *all = [WTClipEngine optionsForText:text];
    NSArray<NSNumber *> *recommended = [WTClipEngine recommendedOpsForText:text];

    NSMutableArray<WTClipOption *> *out = [NSMutableArray array];
    NSMutableSet<NSNumber *> *used = [NSMutableSet set];

    for (NSNumber *op in recommended) {
        for (WTClipOption *o in all) {
            if (o.op == (WTRewriteOp)op.integerValue && ![used containsObject:@(o.op)]) {
                WTClipOption *copy = [WTClipOption new];
                copy.op = o.op;
                copy.title = [@"★ " stringByAppendingString:o.title];
                copy.detail = o.detail;
                copy.section = o.section;
                [out addObject:copy];
                [used addObject:@(o.op)];
                break;
            }
        }
    }
    for (NSString *sec in @[@"编码", @"文本", @"哈希"]) {
        for (WTClipOption *o in all) {
            if ([o.section isEqualToString:sec] && ![used containsObject:@(o.op)]) {
                [out addObject:o];
                [used addObject:@(o.op)];
            }
        }
    }
    return out;
}

#pragma mark - 点击处理器

@interface WTTapHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) UIButton *button;
@end

@implementation WTTapHandler {
    NSArray<WTClipOption *> *_allOptions;
    NSString *_clipText;
    NSInteger _page;
    BOOL _busy;
}

- (UIView *)container { return self.host.view.window ?: self.host.view; }

- (WTPanelView *)panel { return objc_getAssociatedObject(self.host, kPanelKey); }

- (void)closePanel {
    WTPanelView *p = [self panel];
    [p removeFromSuperview];
    objc_setAssociatedObject(self.host, kPanelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    _allOptions = nil;
    _page = 0;
    WTSetState(self.button, @"重写", WTGreen());
}

- (void)showPage:(NSInteger)page {
    WTPanelView *panel = [self panel];
    if (!panel) return;
    NSInteger perPage = 7;
    NSInteger start = page * perPage;
    if (start >= (NSInteger)_allOptions.count) return;
    NSInteger len = MIN(perPage, (NSInteger)_allOptions.count - start);
    NSArray *slice = [_allOptions subarrayWithRange:NSMakeRange(start, len)];
    _page = page;
    [panel setOptions:slice];
    [panel layoutIfNeeded];
}

- (void)openPanel {
    NSString *text = WTClipboardText();
    if (text.length == 0) {
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        NSString *diag = [NSString stringWithFormat:@"[诊断]items=%lu hasStrings=%d cc=%ld",
                          (unsigned long)pb.numberOfItems, (int)pb.hasStrings, (long)pb.changeCount];
        WTLog(@"%@", diag);
        WTInsert(self.host, diag);
        WTSetState(self.button, @"读空", WTRed());
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WTSetState(self.button, @"重写", WTGreen()); });
        return;
    }

    _clipText = text;
    _allOptions = WTSortedOptions(text);
    WTLog(@"剪贴板 %lu 字，可用算子 %lu 个", (unsigned long)text.length,
          (unsigned long)_allOptions.count);
    if (_allOptions.count == 0) {
        WTInsert(self.host, text);
        return;
    }

    UIView *container = [self container];
    WTPanelView *panel = objc_getAssociatedObject(self.host, kPanelKey);
    if (!panel) {
        panel = [WTPanelView new];
        objc_setAssociatedObject(self.host, kPanelKey, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak typeof(self) weakSelf = self;
        panel.onMore = ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            NSInteger next = s->_page + 1;
            if (next * 7 >= (NSInteger)s->_allOptions.count) next = 0;
            [s showPage:next];
        };
    }

    CGRect anchor = [self.host.view convertRect:self.host.view.bounds toView:container];
    CGFloat w = MIN(anchor.size.width - 16, 420);
    CGFloat h = MIN(anchor.size.height - 12, 230);
    panel.frame = CGRectMake(anchor.origin.x + (anchor.size.width - w) / 2,
                             anchor.origin.y + 6, w, h);
    [container addSubview:panel];
    [self showPage:0];
    WTSetState(self.button, @"选择", WTBlue());
    WTLog(@"菜单已展开 %@", NSStringFromCGRect(panel.frame));
}

- (void)applyOption:(WTClipOption *)opt {
    if (!opt || _clipText.length == 0) return;
    NSString *err = nil;
    NSString *result = [WTClipEngine applyOp:opt.op toText:_clipText error:&err];
    if (!result) {
        WTLog(@"算子失败 %@: %@", opt.title, err);
        WTSetState(self.button, @"失败", WTRed());
        return;
    }
    BOOL ok = WTInsert(self.host, result);
    WTSetState(self.button, ok ? @"✓" : @"✗", ok ? WTGreen() : WTRed());
    [self closePanel];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ WTSetState(self.button, @"重写", WTGreen()); });
}

- (void)onDown:(id)sender {
    WTSetState(self.button, @"①", WTOrange());
}

- (void)onTap:(id)sender {
    [self openPanel];
}

- (void)onGesture:(UITapGestureRecognizer *)g {
    UIView *host = g.view;
    if (!host) return;
    CGPoint p = [g locationInView:host];

    WTPanelView *panel = [self panel];
    if (panel) {
        CGRect pf = panel.frame;
        if (CGRectContainsPoint(pf, p)) {
            WTClipOption *opt = [panel optionAtPoint:p inView:host];
            if (opt) [self applyOption:opt];
            return;
        }
        [self closePanel];
        return;
    }

    UIButton *btn = self.button;
    if (!btn || !btn.superview) return;
    CGRect bf = [btn.superview convertRect:btn.frame toView:host];
    if (CGRectContainsPoint(CGRectInset(bf, -6, -6), p)) [self openPanel];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
@end

#pragma mark - 安装

static UIView *WTContainer(UIViewController *vc) {
    return vc.view.window ?: vc.view;
}

static void WTLayoutButton(UIViewController *vc) {
    UIButton *btn = objc_getAssociatedObject(vc, kButtonKey);
    if (!btn) return;
    UIView *container = WTContainer(vc);
    if (btn.superview != container) {
        [container addSubview:btn];
    }
    CGRect anchor = [vc.view convertRect:vc.view.bounds toView:container];
    btn.frame = CGRectMake(anchor.origin.x + anchor.size.width - 56,
                           anchor.origin.y + 5, 50, 30);
    [btn.superview bringSubviewToFront:btn];

    WTPanelView *panel = objc_getAssociatedObject(vc, kPanelKey);
    if (panel && panel.superview == container) {
        [container bringSubviewToFront:panel];
    }
}

static void WTInstallGesture(UIViewController *vc, UIButton *btn) {
    UIView *container = WTContainer(vc);
    if (objc_getAssociatedObject(container, kGestureKey)) return;

    WTTapHandler *handler = [WTTapHandler new];
    handler.host = vc;
    handler.button = btn;

    UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:handler
                                                                      action:@selector(onGesture:)];
    g.delegate = handler;
    g.cancelsTouchesInView = NO;
    g.delaysTouchesBegan = NO;
    g.delaysTouchesEnded = NO;
    [container addGestureRecognizer:g];
    objc_setAssociatedObject(container, kGestureKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WTLog(@"手势挂到 %@", NSStringFromClass([container class]));
}

static void WTInstallButton(UIViewController *vc) {
    UIButton *btn = objc_getAssociatedObject(vc, kButtonKey);
    if (!btn) {
        btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:@"重写" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.backgroundColor = WTGreen();
        btn.layer.cornerRadius = 8;
        btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;

        WTTapHandler *handler = [WTTapHandler new];
        handler.host = vc;
        handler.button = btn;
        [btn addTarget:handler action:@selector(onDown:) forControlEvents:UIControlEventTouchDown];
        [btn addTarget:handler action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(btn, kHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, kButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        WTLog(@"按钮已装");
    }
    WTLayoutButton(vc);
    WTInstallGesture(vc, btn);
}

#pragma mark - hook

static void (*orig_viewDidLoad)(id, SEL);
static void (*orig_viewDidLayoutSubviews)(id, SEL);

static void wt_viewDidLoad(id self, SEL _cmd) {
    orig_viewDidLoad(self, _cmd);
    @try { WTInstallButton((UIViewController *)self); }
    @catch (NSException *e) { WTLog(@"viewDidLoad 异常: %@", e); }
}

static void wt_viewDidLayoutSubviews(id self, SEL _cmd) {
    orig_viewDidLayoutSubviews(self, _cmd);
    @try { WTLayoutButton((UIViewController *)self); }
    @catch (NSException *e) { WTLog(@"layout 异常: %@", e); }
}

static void WTSwizzle(Class cls, SEL sel, void *replacement, void **original) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { WTLog(@"方法不存在: %@", NSStringFromSelector(sel)); return; }
    *original = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)replacement);
    WTLog(@"已 hook %@", NSStringFromSelector(sel));
}

static void WTInitInner(void) {
    WTLog(@"===== dylib v7 loaded =====");
    Class cls = objc_getClass("WBInputViewController");
    if (!cls) { WTLog(@"!! 找不到 WBInputViewController"); return; }
    WTSwizzle(cls, @selector(viewDidLoad), (void *)wt_viewDidLoad, (void **)&orig_viewDidLoad);
    WTSwizzle(cls, @selector(viewDidLayoutSubviews), (void *)wt_viewDidLayoutSubviews,
              (void **)&orig_viewDidLayoutSubviews);
}

__attribute__((constructor)) static void wt_init(void) {
    @try { WTInitInner(); } @catch (NSException *e) { WTLog(@"init 异常: %@", e); }
}
