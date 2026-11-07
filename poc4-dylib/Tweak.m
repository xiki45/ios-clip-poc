//
//  Tweak.m  —— POC 4（可选，仅自用设备）
//
//  验证：被注入到 SpringBoard 后，能否观测到系统剪贴板写入事件。
//  若成立，采集就不再依赖“键盘是否可见”，可以做到接近 Android 默认输入法的体验。
//
//  注意：
//   - 只在**自己的**设备 / 自己的系统进程上使用。
//   - 落盘路径选 /var/mobile/Library/Preferences/（SpringBoard 通常可写）。
//   - 这条路线只验证“能不能观测到”，不做持久化、不做上传。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kLogPath = @"/var/mobile/Library/Preferences/poc-pasteboard.log";

static void POCAppend(NSString *line) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"HH:mm:ss.SSS";
    NSString *full = [NSString stringWithFormat:@"%@ [%d] %@\n",
                      [f stringFromDate:[NSDate date]],
                      getpid(), line];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kLogPath]) {
        [fm createFileAtPath:kLogPath contents:nil attributes:nil];
    }
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (h) {
        @try {
            [h seekToEndOfFile];
            [h writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (NSException *e) {
            // 忽略：POC 只关心能否观测
        } @finally {
            [h closeFile];
        }
    }
    NSLog(@"[POC4] %@", line);
}

#pragma mark - Hook

static IMP gOrigSetString;
static IMP gOrigSetItems;

static void POCSetString(id self, SEL _cmd, NSString *s) {
    POCAppend([NSString stringWithFormat:@"setString len=%lu preview=%@",
               (unsigned long)s.length,
               [s substringToIndex:MIN((NSUInteger)40, s.length)]]);
    if (gOrigSetString) {
        ((void (*)(id, SEL, NSString *))gOrigSetString)(self, _cmd, s);
    }
}

static void POCSetItems(id self, SEL _cmd, NSArray *items) {
    POCAppend([NSString stringWithFormat:@"setItems count=%lu", (unsigned long)items.count]);
    if (gOrigSetItems) {
        ((void (*)(id, SEL, NSArray *))gOrigSetItems)(self, _cmd, items);
    }
}

__attribute__((constructor))
static void poc4_init(void) {
    POCAppend(@"dylib loaded");

    Class cls = objc_getClass("UIPasteboard");
    if (!cls) {
        POCAppend(@"UIPasteboard 不存在（注入到了错误的进程？）");
        return;
    }

    Method m1 = class_getInstanceMethod(cls, @selector(setString:));
    if (m1) {
        gOrigSetString = method_getImplementation(m1);
        method_setImplementation(m1, (IMP)POCSetString);
        POCAppend(@"hooked -[UIPasteboard setString:]");
    }

    Method m2 = class_getInstanceMethod(cls, @selector(setItems:));
    if (m2) {
        gOrigSetItems = method_getImplementation(m2);
        method_setImplementation(m2, (IMP)POCSetItems);
        POCAppend(@"hooked -[UIPasteboard setItems:]");
    }
}
