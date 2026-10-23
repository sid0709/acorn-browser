// The agent's own pointer and keyboard: events built as the system builds them from the
// hardware and handed to Chromium's view the way the window hands them over. The page cannot
// tell them from a person's, and the person's mouse and keyboard are left alone.
#import "ChromiumInternal.h"

#import <Carbon/Carbon.h>
#import <objc/runtime.h>

#pragma mark - The pointer drawn on the page

/// An arrow where the agent's pointer is, above the page. It takes no events of its own, so the
/// person's clicks go through it to the page as before.
@interface AgentPointerView : NSView
@property (nonatomic) NSPoint position;
@property (nonatomic) BOOL pressed;
@end

@implementation AgentPointerView

- (BOOL)isFlipped {
  return YES;
}

- (NSView *)hitTest:(NSPoint)point {
  return nil;
}

/// The arrow's extent around the point, for redrawing only what moved.
- (NSRect)arrowRectAt:(NSPoint)p {
  return NSMakeRect(p.x - 14, p.y - 14, 40, 44);
}

- (void)setPosition:(NSPoint)position {
  [self setNeedsDisplayInRect:[self arrowRectAt:_position]];
  _position = position;
  [self setNeedsDisplayInRect:[self arrowRectAt:_position]];
}

- (void)setPressed:(BOOL)pressed {
  _pressed = pressed;
  [self setNeedsDisplayInRect:[self arrowRectAt:_position]];
}

- (void)drawRect:(NSRect)dirtyRect {
  const NSPoint p = self.position;
  // The classic arrow, in a colour of its own so it is never taken for the person's.
  NSBezierPath *arrow = [NSBezierPath bezierPath];
  [arrow moveToPoint:NSMakePoint(p.x, p.y)];
  [arrow lineToPoint:NSMakePoint(p.x, p.y + 21)];
  [arrow lineToPoint:NSMakePoint(p.x + 5.5, p.y + 16.5)];
  [arrow lineToPoint:NSMakePoint(p.x + 9.5, p.y + 25)];
  [arrow lineToPoint:NSMakePoint(p.x + 12.5, p.y + 23.5)];
  [arrow lineToPoint:NSMakePoint(p.x + 8.5, p.y + 15)];
  [arrow lineToPoint:NSMakePoint(p.x + 15, p.y + 15)];
  [arrow closePath];
  arrow.lineJoinStyle = NSLineJoinStyleRound;
  [[NSColor colorWithSRGBRed:0.07 green:0.07 blue:0.07 alpha:0.9] setStroke];
  arrow.lineWidth = 3;
  [arrow stroke];
  [(self.pressed ? [NSColor colorWithSRGBRed:1.0 green:0.35 blue:0.1 alpha:1]
                 : [NSColor colorWithSRGBRed:1.0 green:0.6 blue:0.15 alpha:1]) setFill];
  [arrow fill];
  [[NSColor whiteColor] setStroke];
  arrow.lineWidth = 1;
  [arrow stroke];
  if (self.pressed) {
    NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - 9, p.y - 9, 18, 18)];
    [[NSColor colorWithSRGBRed:1.0 green:0.35 blue:0.1 alpha:0.6] setStroke];
    ring.lineWidth = 2;
    [ring stroke];
  }
}

@end

#pragma mark - Events

namespace {

/// The buttons the agent holds down (bit 0 left, bit 1 right). Chromium asks the system which
/// buttons are down when it builds a mouse event (for `event.buttons`); the agent's are added
/// to the answer below.
NSUInteger gHeldButtons = 0;
NSInteger gEventNumber = 1;
NSUInteger (*gPressedMouseButtons)(id, SEL) = nullptr;

/// The id of a Latin keyboard layout, for the page's input context while the agent types: a
/// Korean or Japanese input source would turn the keys into other characters.
NSString *LatinInputSourceID() {
  static NSString *latin = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    TISInputSourceRef source = TISCopyCurrentASCIICapableKeyboardInputSource();
    if (source) {
      CFStringRef sourceID = (CFStringRef)TISGetInputSourceProperty(source, kTISPropertyInputSourceID);
      latin = sourceID ? [(__bridge NSString *)sourceID copy] : nil;
      CFRelease(source);
    }
  });
  return latin;
}

void AddHeldButtonsToTheSystemsAnswer() {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Method method = class_getClassMethod(NSEvent.class, @selector(pressedMouseButtons));
    gPressedMouseButtons = (NSUInteger(*)(id, SEL))method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^NSUInteger(id receiver) {
      return gPressedMouseButtons(receiver, @selector(pressedMouseButtons)) | gHeldButtons;
    });
    method_setImplementation(method, replacement);
  });
}

NSEventModifierFlags ModifierFlags(CGEventFlags flags) {
  // The bits are the same in both (Shift 1 << 17, Control 1 << 18, Option 1 << 19, Command 1 << 20).
  return (NSEventModifierFlags)flags & NSEventModifierFlagDeviceIndependentFlagsMask;
}

NSTimeInterval Now() {
  return NSProcessInfo.processInfo.systemUptime;
}

BOOL IsModifierKey(CGKeyCode keyCode) {
  switch (keyCode) {
    case 54: case 55: case 56: case 57: case 58: case 59: case 60: case 61: case 62: case 63:
      return YES;
    default:
      return NO;
  }
}

}  // namespace

@implementation ChromiumBrowserView (Input)

#pragma mark Where the page is

/// The point of the page in the view's own coordinates.
- (NSPoint)localPointForX:(double)x y:(double)y {
  return self.isFlipped ? NSMakePoint(x, y) : NSMakePoint(x, NSHeight(self.bounds) - y);
}

/// Chromium's view at the point, which takes the events; nil when the page is not there.
- (NSView *)pageViewAtX:(double)x y:(double)y {
  if (!self.window) {
    return nil;
  }
  NSPoint local = [self localPointForX:x y:y];
  NSPoint inSuperview = self.superview ? [self convertPoint:local toView:self.superview] : local;
  NSView *hit = [self hitTest:inSuperview];
  if (!hit || hit == self) {
    return nil;
  }
  return hit;
}

- (NSView *)pageView {
  return [self pageViewAtX:NSMidX(self.bounds) y:NSMidY(self.bounds)];
}

- (AgentPointerView *)pointerView {
  for (NSView *subview in self.subviews) {
    if ([subview isKindOfClass:AgentPointerView.class]) {
      return (AgentPointerView *)subview;
    }
  }
  return nil;
}

- (void)cef_keepPointerOnTop {
  AgentPointerView *pointer = [self pointerView];
  if (pointer && self.subviews.lastObject != pointer) {
    [pointer removeFromSuperview];
    [self addSubview:pointer];
  }
}

- (void)takeFront {
  NSWindow *window = self.window;
  if (!window) {
    return;
  }
  if (window.isMiniaturized) {
    [window deminiaturize:nil];
  }
  [window makeKeyAndOrderFront:nil];
  NSView *page = [self pageView];
  if (page && window.firstResponder != page) {
    [window makeFirstResponder:page];
  }
  [self cef_focusPage];
}

- (void)showPointer:(BOOL)shown {
  AgentPointerView *pointer = [self pointerView];
  if (shown && !pointer) {
    AddHeldButtonsToTheSystemsAnswer();
    pointer = [[AgentPointerView alloc] initWithFrame:self.bounds];
    pointer.wantsLayer = YES;
    pointer.position = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
    [self addSubview:pointer];
  } else if (!shown && pointer) {
    [pointer removeFromSuperview];
    gHeldButtons = 0;
  }
}

#pragma mark The mouse

- (NSEvent *)mouseEventOfType:(NSEventType)type
                            x:(double)x
                            y:(double)y
                        flags:(CGEventFlags)flags
                   clickCount:(NSInteger)clickCount
                     pressure:(float)pressure {
  return [NSEvent mouseEventWithType:type
                            location:[self convertPoint:[self localPointForX:x y:y] toView:nil]
                       modifierFlags:ModifierFlags(flags)
                           timestamp:Now()
                        windowNumber:self.window.windowNumber
                             context:nil
                         eventNumber:++gEventNumber
                          clickCount:clickCount
                            pressure:pressure];
}

- (BOOL)pointerMoveToX:(double)x y:(double)y flags:(CGEventFlags)flags {
  NSView *page = [self pageViewAtX:x y:y];
  if (!page) {
    return NO;
  }
  [self pointerView].position = NSMakePoint(x, y);
  // While a button is held the move is a drag, which is how the page sees a stroke.
  NSEvent *event;
  if (gHeldButtons & 1) {
    event = [self mouseEventOfType:NSEventTypeLeftMouseDragged x:x y:y flags:flags clickCount:1 pressure:1];
    [page mouseDragged:event];
  } else if (gHeldButtons & 2) {
    event = [self mouseEventOfType:NSEventTypeRightMouseDragged x:x y:y flags:flags clickCount:1 pressure:1];
    [page rightMouseDragged:event];
  } else {
    event = [self mouseEventOfType:NSEventTypeMouseMoved x:x y:y flags:flags clickCount:0 pressure:0];
    [page mouseMoved:event];
  }
  return YES;
}

- (BOOL)pointerButton:(ChromiumMouseButton)button
                 down:(BOOL)down
                    x:(double)x
                    y:(double)y
           clickCount:(NSInteger)clickCount
                flags:(CGEventFlags)flags {
  NSView *page = [self pageViewAtX:x y:y];
  if (!page) {
    return NO;
  }
  const BOOL right = button == ChromiumMouseButtonRight;
  const NSUInteger bit = right ? 2 : 1;
  AgentPointerView *pointer = [self pointerView];
  pointer.position = NSMakePoint(x, y);
  pointer.pressed = down;
  if (down) {
    // The window would make the view the first responder before a click; so does this.
    if (self.window.firstResponder != page && [page acceptsFirstResponder]) {
      [self.window makeFirstResponder:page];
    }
    gHeldButtons |= bit;
  } else {
    gHeldButtons &= ~bit;
  }
  NSEventType type = right ? (down ? NSEventTypeRightMouseDown : NSEventTypeRightMouseUp)
                           : (down ? NSEventTypeLeftMouseDown : NSEventTypeLeftMouseUp);
  NSEvent *event = [self mouseEventOfType:type x:x y:y flags:flags clickCount:clickCount pressure:down ? 1 : 0];
  if (right) {
    down ? [page rightMouseDown:event] : [page rightMouseUp:event];
  } else {
    down ? [page mouseDown:event] : [page mouseUp:event];
  }
  return YES;
}

- (void)releasePointer {
  gHeldButtons = 0;
  [self pointerView].pressed = NO;
}

- (BOOL)wheelAtX:(double)x y:(double)y deltaX:(double)deltaX deltaY:(double)deltaY flags:(CGEventFlags)flags {
  NSView *page = [self pageViewAtX:x y:y];
  if (!page) {
    return NO;
  }
  [self pointerView].position = NSMakePoint(x, y);
  // A wheel's first axis is vertical, and positive turns scroll up: the page's down is negative.
  CGEventRef wheel = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2,
                                                   (int32_t)lround(-deltaY), (int32_t)lround(-deltaX));
  // An event made this way belongs to no window, so its location is read as screen
  // coordinates and taken as window coordinates by the view: set it so that reading comes out
  // at the point in the window (screen coordinates have their origin at the bottom left of the
  // main display, the event's at its top left).
  NSPoint inWindow = [self convertPoint:[self localPointForX:x y:y] toView:nil];
  const CGFloat mainHeight = NSHeight(NSScreen.screens.firstObject.frame);
  CGEventSetLocation(wheel, CGPointMake(inWindow.x, mainHeight - inWindow.y));
  CGEventSetFlags(wheel, flags);
  NSEvent *event = [NSEvent eventWithCGEvent:wheel];
  CFRelease(wheel);
  if (!event) {
    return NO;
  }
  [page scrollWheel:event];
  return YES;
}

#pragma mark The keyboard

- (BOOL)keyCode:(CGKeyCode)keyCode
           down:(BOOL)down
          flags:(CGEventFlags)flags
     characters:(NSString *)characters
     unmodified:(NSString *)unmodified {
  NSView *page = [self pageView];
  if (!page) {
    return NO;
  }
  if (self.window.firstResponder != page) {
    [self.window makeFirstResponder:page];
  }
  // While the agent types, the page's input context uses a Latin layout, whatever the person's
  // keyboard is set to; the context is the page's alone, so the person's setting stays.
  NSTextInputContext *context = page.inputContext;
  NSString *latin = LatinInputSourceID();
  if (context && latin && ![context.selectedKeyboardInputSource isEqualToString:latin]) {
    context.selectedKeyboardInputSource = latin;
  }

  const BOOL modifier = IsModifierKey(keyCode);
  NSEvent *event = [NSEvent keyEventWithType:modifier ? NSEventTypeFlagsChanged : (down ? NSEventTypeKeyDown : NSEventTypeKeyUp)
                                    location:NSZeroPoint
                               modifierFlags:ModifierFlags(flags)
                                   timestamp:Now()
                                windowNumber:self.window.windowNumber
                                     context:nil
                                  characters:modifier ? @"" : (characters ?: @"")
                 charactersIgnoringModifiers:modifier ? @"" : (unmodified ?: characters ?: @"")
                                   isARepeat:NO
                                     keyCode:keyCode];
  if (modifier) {
    [page flagsChanged:event];
  } else if (!down) {
    [page keyUp:event];
  } else if (flags & kCGEventFlagMaskCommand) {
    // The window offers a Command chord as a key equivalent first, and Chromium's view takes
    // it there; what it declines goes on as a key.
    if (![page performKeyEquivalent:event]) {
      [page keyDown:event];
    }
  } else {
    [page keyDown:event];
  }
  return YES;
}

- (BOOL)insertText:(NSString *)text {
  id responder = self.window.firstResponder;
  if (![responder conformsToProtocol:@protocol(NSTextInputClient)]) {
    return NO;
  }
  [(id<NSTextInputClient>)responder insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
  return YES;
}

@end
