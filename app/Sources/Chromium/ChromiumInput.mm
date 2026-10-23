// Real input for the agent: mouse and keyboard events posted to the system as hardware would
// send them, so the page cannot tell them from a person's. Needs the Accessibility permission.
#import "ChromiumInternal.h"

#import <Carbon/Carbon.h>

namespace {

/// The keyboard input source that was selected before the agent switched to a Latin one.
TISInputSourceRef gSavedInputSource = nullptr;

/// The buttons the agent holds down (bit 0 left, bit 1 right), kept here rather than read from
/// the system, which learns of a posted event a moment later.
NSUInteger gHeldButtons = 0;

CGEventType MouseType(ChromiumMouseButton button, BOOL down) {
  if (button == ChromiumMouseButtonRight) {
    return down ? kCGEventRightMouseDown : kCGEventRightMouseUp;
  }
  return down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
}

CGMouseButton CGButton(ChromiumMouseButton button) {
  return button == ChromiumMouseButtonRight ? kCGMouseButtonRight : kCGMouseButtonLeft;
}

void Post(CGEventRef event) {
  CGEventPost(kCGHIDEventTap, event);
  CFRelease(event);
}

}  // namespace

@implementation ChromiumBrowserView (Input)

+ (BOOL)canSendInput:(BOOL)ask {
  NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @(ask)};
  return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

- (void)takeFront {
  NSWindow *window = self.window;
  if (!window) {
    return;
  }
  if (window.isMiniaturized) {
    [window deminiaturize:nil];
  }
  [NSApp activateIgnoringOtherApps:YES];
  [window makeKeyAndOrderFront:nil];
  // The deepest view at the middle of the page is Chromium's; it takes the keys.
  NSPoint middle = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
  NSView *page = [self hitTest:[self convertPoint:middle toView:self.superview]] ?: self;
  if (window.firstResponder != page) {
    [window makeFirstResponder:page];
  }
  [self cef_focusPage];
}

- (void)useLatinKeyboard {
  if (gSavedInputSource) {
    return;
  }
  TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
  if (!current) {
    return;
  }
  CFBooleanRef ascii = (CFBooleanRef)TISGetInputSourceProperty(current, kTISPropertyInputSourceIsASCIICapable);
  if (ascii && CFBooleanGetValue(ascii)) {
    CFRelease(current);
    return;
  }
  TISInputSourceRef latin = TISCopyCurrentASCIICapableKeyboardInputSource();
  if (latin && TISSelectInputSource(latin) == noErr) {
    gSavedInputSource = current;
  } else {
    CFRelease(current);
  }
  if (latin) {
    CFRelease(latin);
  }
}

- (void)restoreKeyboard {
  if (!gSavedInputSource) {
    return;
  }
  TISSelectInputSource(gSavedInputSource);
  CFRelease(gSavedInputSource);
  gSavedInputSource = nullptr;
}

/// Where a point of the page is on the screen, in the coordinates events are posted in (the
/// main display's top left is the origin). NO when the view is not in a window on screen.
- (BOOL)screenPointForX:(double)x y:(double)y into:(CGPoint *)out {
  NSWindow *window = self.window;
  if (!window || !window.isVisible || window.isMiniaturized) {
    return NO;
  }
  NSPoint local = self.isFlipped ? NSMakePoint(x, y) : NSMakePoint(x, NSHeight(self.bounds) - y);
  NSPoint inWindow = [self convertPoint:local toView:nil];
  NSPoint onScreen = [window convertPointToScreen:inWindow];
  NSScreen *primary = NSScreen.screens.firstObject;
  *out = CGPointMake(onScreen.x, NSHeight(primary.frame) - onScreen.y);
  return YES;
}

- (BOOL)pointerMoveToX:(double)x y:(double)y flags:(CGEventFlags)flags {
  CGPoint point;
  if (![self screenPointForX:x y:y into:&point]) {
    return NO;
  }
  // While a button is held the move is a drag, which is how the page sees a stroke.
  const NSUInteger held = gHeldButtons;
  CGEventType type = kCGEventMouseMoved;
  CGMouseButton button = kCGMouseButtonLeft;
  if (held & 1) {
    type = kCGEventLeftMouseDragged;
  } else if (held & 2) {
    type = kCGEventRightMouseDragged;
    button = kCGMouseButtonRight;
  }
  CGEventRef event = CGEventCreateMouseEvent(nullptr, type, point, button);
  CGEventSetFlags(event, flags);
  Post(event);
  return YES;
}

- (BOOL)pointerButton:(ChromiumMouseButton)button
                 down:(BOOL)down
                    x:(double)x
                    y:(double)y
           clickCount:(NSInteger)clickCount
                flags:(CGEventFlags)flags {
  CGPoint point;
  if (![self screenPointForX:x y:y into:&point]) {
    return NO;
  }
  CGEventRef event = CGEventCreateMouseEvent(nullptr, MouseType(button, down), point, CGButton(button));
  CGEventSetIntegerValueField(event, kCGMouseEventClickState, clickCount);
  CGEventSetFlags(event, flags);
  Post(event);
  const NSUInteger bit = button == ChromiumMouseButtonRight ? 2 : 1;
  gHeldButtons = down ? (gHeldButtons | bit) : (gHeldButtons & ~bit);
  return YES;
}

- (BOOL)wheelAtX:(double)x y:(double)y deltaX:(double)deltaX deltaY:(double)deltaY flags:(CGEventFlags)flags {
  CGPoint point;
  if (![self screenPointForX:x y:y into:&point]) {
    return NO;
  }
  // A wheel's first axis is vertical, and positive turns scroll up: the page's down is negative.
  CGEventRef event = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2,
                                                   (int32_t)lround(-deltaY), (int32_t)lround(-deltaX));
  CGEventSetLocation(event, point);
  CGEventSetFlags(event, flags);
  Post(event);
  return YES;
}

- (BOOL)keyCode:(CGKeyCode)keyCode down:(BOOL)down flags:(CGEventFlags)flags characters:(NSString *)characters {
  if (!self.window) {
    return NO;
  }
  CGEventRef event = CGEventCreateKeyboardEvent(nullptr, keyCode, down);
  if (characters.length) {
    unichar buffer[8];
    const NSUInteger length = MIN(characters.length, (NSUInteger)8);
    [characters getCharacters:buffer range:NSMakeRange(0, length)];
    CGEventKeyboardSetUnicodeString(event, length, buffer);
  }
  CGEventSetFlags(event, flags);
  Post(event);
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
