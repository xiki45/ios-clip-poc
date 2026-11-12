//
//  WeTypeInject.m
//  阶段 2 最小注入验证：往微信输入法键盘扩展里加一个按钮，点一下插入 INJECT-OK。
//
//  目标进程：wxkb_plugin.appex（键盘扩展），不是主 App。
//  宿主类：  WBInputViewController（NSExtensionPrincipalClass，ObjC 类，无 Swift 前缀）
//
//  设计原则：只做一件事，并且做到「失败也留痕」。
//    - 每条路径都写日志（App Group 优先，退回 tmp），装完能知道卡在哪一步
//    - 所有 hook 幂等，重复调用不会堆叠按钮
//    - 拿不到类 / 拿不到 proxy 都只记日志，不崩
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kTag = @"[wtinject]";

#pragma mark - 日志

static NSString *WTLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 优先写到微信输入法自己的 App Group，方便用 Filza / 主 App 捞
        NSURL *group = [[NSFileManager defaultManager]
                        containerURLForSecurityApplicationGroupIdentifier:@"group.com.tencent.wetype"];
        if (group) {
            path = [[group URLByAppendingPathComponent:@"wtinject.log"] path];
        }
        if (!path) {
            path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wtinject.log"];
        }
    });
    return path;
}

static void WTLog(NSString *fmt, ...) {
    @try {
        va_list args;
        va_start(args, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
        va_end(args);

        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ %@ %@\n",
                          [f stringFromDate:[NSDate date]], kTag, msg];

        NSLog(@"[wtinject] %@", msg);
        FILE *fp = fopen(WTLogPath().UTF8String, "a");
        if (fp) {
            fputs(line.UTF8String, fp);
            fclose(fp);
        }
    } @catch (NSException *e) {
        NSLog(@"[wtinject] 日志失败: %@", e);
    }
}

#pragma mark - 前向声明

static void WTInsertProbeText(UIViewController *vc);

#pragma mark - 点击处理（不依赖目标类，避免对外部类挂分类）

@interface WTTapHandler : NSObject
@property (nonatomic, weak) UIViewController *host;
@end

@implementation WTTapHandler
- (void)onTap:(id)sender {
    WTLog(@"按钮被点击");
    WTInsertProbeText(self.host);
}
@end

#pragma mark - 插入

static void WTInsertProbeText(UIViewController *vc) {
    if (![vc isKindOfClass:[UIInputViewController class]]) {
        WTLog(@"不是 UIInputViewController（类: %@）", NSStringFromClass([vc class]));
        return;
    }
    id proxy = [(UIInputViewController *)vc textDocumentProxy];
    if (![proxy respondsToSelector:@selector(insertText:)]) {
        WTLog(@"textDocumentProxy 不可用");
        return;
    }
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"HH:mm:ss";
    NSString *text = [NSString stringWithFormat:@"INJECT-OK %@", [f stringFromDate:[NSDate date]]];
    [proxy insertText:text];
    WTLog(@"已插入: %@", text);
}

#pragma mark - 按钮

static const void *kButtonKey = &kButtonKey;
static const void *kHandlerKey = &kHandlerKey;

static void WTLayoutButton(UIViewController *vc) {
    UIButton *btn = objc_getAssociatedObject(vc, kButtonKey);
    if (!btn) return;
    CGRect bounds = vc.view.bounds;
    btn.frame = CGRectMake(bounds.size.width - 50, 5, 44, 30);
}

static void WTInstallButton(UIViewController *vc) {
    UIButton *existing = objc_getAssociatedObject(vc, kButtonKey);
    if (existing) {
        WTLayoutButton(vc);
        return;
    }

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"注入" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor colorWithRed:0.0 green:0.62 blue:0.42 alpha:1.0];
    btn.layer.cornerRadius = 8;
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;

    WTTapHandler *handler = [WTTapHandler new];
    handler.host = vc;
    [btn addTarget:handler action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(btn, kHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [vc.view addSubview:btn];
    objc_setAssociatedObject(vc, kButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WTLayoutButton(vc);

    WTLog(@"按钮已挂上（view=%@ bounds=%@）",
          NSStringFromClass([vc.view class]), NSStringFromCGRect(vc.view.bounds));
}

#pragma mark - hook

static void (*orig_viewDidLoad)(id, SEL);
static void (*orig_viewDidLayoutSubviews)(id, SEL);

static void wt_viewDidLoad(id self, SEL _cmd) {
    orig_viewDidLoad(self, _cmd);
    @try {
        WTLog(@"WBInputViewController viewDidLoad");
        WTInstallButton((UIViewController *)self);
    } @catch (NSException *e) {
        WTLog(@"viewDidLoad 异常: %@", e);
    }
}

static void wt_viewDidLayoutSubviews(id self, SEL _cmd) {
    orig_viewDidLayoutSubviews(self, _cmd);
    @try {
        UIViewController *vc = (UIViewController *)self;
        UIButton *btn = objc_getAssociatedObject(vc, kButtonKey);
        if (!btn) return;
        if (btn.superview != vc.view) {
            [vc.view addSubview:btn];
            WTLog(@"按钮被移出视图，已重新挂上");
        }
        WTLayoutButton(vc);
    } @catch (NSException *e) {
        WTLog(@"layout 异常: %@", e);
    }
}

static void WTSwizzle(Class cls, SEL sel, void *replacement, void **original) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        WTLog(@"方法不存在: %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }
    *original = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)replacement);
    WTLog(@"已 hook %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
}

static void WTInitInner(void) {
    WTLog(@"===== dylib loaded =====");
    WTLog(@"log path: %@", WTLogPath());

    Class cls = objc_getClass("WBInputViewController");
    if (!cls) {
        WTLog(@"!! 找不到 WBInputViewController —— 注入目标多半是主 App，不是 wxkb_plugin.appex");
        return;
    }
    WTLog(@"找到 WBInputViewController: %p", cls);

    WTSwizzle(cls, @selector(viewDidLoad), (void *)wt_viewDidLoad, (void **)&orig_viewDidLoad);
    WTSwizzle(cls, @selector(viewDidLayoutSubviews), (void *)wt_viewDidLayoutSubviews,
              (void **)&orig_viewDidLayoutSubviews);
}

__attribute__((constructor)) static void wt_init(void) {
    @try {
        WTInitInner();
    } @catch (NSException *e) {
        WTLog(@"初始化异常: %@", e);
    }
}
