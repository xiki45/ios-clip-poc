//
//  WTPanelView.h  ·  v8
//
//  键盘内的重写菜单面板。
//
//  与 v7 的差别：
//    - 不再靠「按 y 算第几行」猜命中，而是 reload 时生成一份命中表（WTPanelHit），
//      绘制和命中用同一份数据 —— 坐标错位这一类 bug 从根上消失
//    - 视觉按 POC（ClipKeyboard v11）的风格重做：卡片 + 分区标题 + 双行条目 + 翻页脚
//

#import <UIKit/UIKit.h>
#import "WTClipEngine.h"

typedef NS_ENUM(NSInteger, WTPanelHitKind) {
    WTPanelHitKindNone = 0,
    WTPanelHitKindRow,
    WTPanelHitKindClose,
    WTPanelHitKindPrev,
    WTPanelHitKindNext,
};

@interface WTPanelHit : NSObject
@property (nonatomic) WTPanelHitKind kind;
@property (nonatomic, strong) WTClipOption *option;
@property (nonatomic) CGRect rect;   // 面板坐标系
+ (instancetype)kind:(WTPanelHitKind)kind rect:(CGRect)rect option:(WTClipOption *)option;
@end

@interface WTPanelView : UIView

@property (nonatomic, copy) NSArray<WTClipOption *> *options;
@property (nonatomic) NSInteger pageStart;
@property (nonatomic) CGFloat maxHeight;      // 可用高度（键盘区域高 - 边距）
@property (nonatomic) NSInteger sourceLength; // 头部显示的「N 字」

@property (nonatomic, readonly) NSInteger shownStart;
@property (nonatomic, readonly) NSInteger shownCount;
@property (nonatomic, readonly) BOOL hasPrev;
@property (nonatomic, readonly) BOOL hasNext;

@property (nonatomic, copy) void (^onPage)(NSInteger newStart);

/// 重建内容并自适应高度（宽度取当前 frame.width，高度由内容决定，上限 maxHeight）
- (void)reload;

/// 命中测试，point 为面板坐标
- (WTPanelHit *)hitAtPoint:(CGPoint)point;

/// 点中后的高亮反馈
- (void)flashRect:(CGRect)rect;

@end
