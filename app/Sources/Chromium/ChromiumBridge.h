#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ChromiumBrowserView;

/// Posted on the main thread once Chromium has finished initializing and can create
/// browsers (shortly after `start` returns).
extern NSNotificationName const ChromiumEngineDidStartNotification;

/// Owns the Chromium (CEF) runtime: startup and the message pump.
NS_SWIFT_UI_ACTOR
@interface ChromiumEngine : NSObject

/// Loads the CEF framework and initializes Chromium. Call once, on the main thread,
/// from applicationWillFinishLaunching: or later.
+ (BOOL)start;

/// When NO, Chromium encrypts cookies and saved logins with a fixed built-in key instead of
/// one stored in the macOS Keychain. That skips a Keychain check that delays the first
/// page by several seconds. Must be set before `start`. Defaults to YES.
@property (class, nonatomic) BOOL usesSystemKeychain;

/// Ends the app right away. Chromium is not shut down gracefully (its helper processes exit
/// with the app); the only thing done first is a quick flush of the cookie store so a recent
/// login isn't lost. Never returns normally: the process exits within about a second.
+ (void)quitImmediately;

@property (class, nonatomic, readonly) BOOL isRunning;
/// YES once Chromium can create browsers (see ChromiumEngineDidStartNotification).
@property (class, nonatomic, readonly) BOOL isReady;
@property (class, nonatomic, readonly, copy) NSString *chromiumVersion;
@property (class, nonatomic, readonly, copy) NSString *cefVersion;
@property (class, nonatomic, readonly, copy) NSString *userAgent;

@end

NS_SWIFT_UI_ACTOR
@protocol ChromiumBrowserViewDelegate <NSObject>

/// URL, title, loading or history state changed.
- (void)browserViewDidUpdateState:(ChromiumBrowserView *)browserView;

/// The page opened a new window or tab. Return YES after placing `popup` in a new tab,
/// or NO to block it.
- (BOOL)browserView:(ChromiumBrowserView *)browserView
         adoptPopup:(ChromiumBrowserView *)popup
       inBackground:(BOOL)inBackground;

/// The page agreed to close (window.close() or a requested close that passed beforeunload).
/// The browser is destroyed right after this returns; remove the tab.
- (void)browserViewDidRequestClose:(ChromiumBrowserView *)browserView;

/// The page entered or left HTML fullscreen (e.g. a video).
- (void)browserView:(ChromiumBrowserView *)browserView didChangeFullscreen:(BOOL)fullscreen;

/// A find-in-page search (`find:forward:matchCase:findNext:`) reported results: how many
/// matches there are now and which one is current (1-based, 0 if none yet).
- (void)browserView:(ChromiumBrowserView *)browserView
    didUpdateFindCount:(NSInteger)count
            activeMatch:(NSInteger)activeMatch;

@end

typedef NS_ENUM(NSInteger, ChromiumDialogKind) {
  ChromiumDialogKindAlert,
  ChromiumDialogKindConfirm,
  ChromiumDialogKindPrompt,
  /// The page asks whether to leave (beforeunload).
  ChromiumDialogKindBeforeUnload,
};

/// Answers a page's dialog without showing it: nil dismisses it (Cancel, or stay on the page);
/// a string accepts it (OK, or leave), and is the answer to a prompt.
typedef NSString *_Nullable (^ChromiumDialogHandler)(ChromiumDialogKind kind,
                                                      NSString *message,
                                                      NSString *defaultText);

/// A DevTools protocol event for a domain the page enabled (`Network.enable`, `Page.enable`).
typedef void (^ChromiumDevToolsEventHandler)(NSString *method, NSDictionary *_Nullable params);

typedef NS_ENUM(NSInteger, ChromiumMouseButton) {
  ChromiumMouseButtonLeft,
  ChromiumMouseButtonRight,
};

typedef NS_ENUM(NSInteger, ChromiumScreenshotArea) {
  /// What's currently on screen in the tab.
  ChromiumScreenshotAreaVisible,
  /// The whole scrollable page.
  ChromiumScreenshotAreaFullPage,
};

/// An NSView hosting one Chromium browser. The browser is created when the view first
/// joins a window, so tabs that are never shown cost nothing.
NS_SWIFT_UI_ACTOR
@interface ChromiumBrowserView : NSView

- (instancetype)initWithURL:(NSString *)url NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<ChromiumBrowserViewDelegate> delegate;

@property (nonatomic, readonly, copy) NSString *currentURL;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
/// Page load progress from 0 to 1 while loading.
@property (nonatomic, readonly) double loadingProgress;
/// The site's favicon, or nil until one has loaded.
@property (nonatomic, readonly, nullable) NSImage *favicon;

@property (nonatomic) BOOL allowsPopups;
@property (nonatomic) BOOL allowsDragAndDrop;
@property (nonatomic) BOOL allowsTooltips;
@property (nonatomic) BOOL audioMuted;

- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;

/// The page's zoom, in CEF's zoom levels (0 is 100%; each whole step is about 20%). Settable
/// before the browser exists; applied once it is created.
@property (nonatomic) double zoomLevel;

/// Opens the system print panel for the page.
- (void)printPage;

/// Starts or continues a find-in-page search for `text`; results arrive as
/// `browserView:didUpdateFindCount:activeMatch:`. An empty `text` stops the search. Changing
/// `text` or `matchCase` restarts it; `findNext` moves to the next (or, backward, previous) match
/// of a search already running.
- (void)find:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext;
/// Ends the current search, clearing its highlight if asked.
- (void)stopFinding:(BOOL)clearSelection;

/// Gives keyboard focus to the page unless a text field (e.g. the address bar) has it.
- (void)focusBrowser;

/// Asks the page to close, running beforeunload handlers. If the page agrees the
/// delegate receives browserViewDidRequestClose:.
- (void)requestClose;

/// Destroys the browser immediately, skipping beforeunload. Safe to call repeatedly.
- (void)destroyBrowser;

/// Runs one Chrome DevTools Protocol method on this page (for example `Page.navigate` or
/// `Input.dispatchMouseEvent`). Calls back on the main thread with whether it worked and the
/// method's result (or the protocol's error). Events go to `devToolsEventHandler`.
- (void)sendDevToolsMethod:(NSString *)method
                    params:(nullable NSDictionary *)params
                completion:(void (^)(BOOL success, NSDictionary *_Nullable result))completion;

/// Receives the DevTools events of the domains that were enabled with `sendDevToolsMethod`
/// (`Network.requestWillBeSent`, `Page.fileChooserOpened`, ...), on the main thread.
@property (nonatomic, copy, nullable) ChromiumDevToolsEventHandler devToolsEventHandler;

/// While set, the page's JavaScript dialogs are answered by this block instead of being shown.
/// For an agent driving the page, which cannot click a native dialog.
@property (nonatomic, copy, nullable) ChromiumDialogHandler dialogHandler;

/// Called on the main thread when a download starts (`finished` NO) and when it completes
/// (`finished` YES), with the file's name.
@property (nonatomic, copy, nullable) void (^downloadHandler)(NSString *fileName, BOOL finished);

/// Called on the main thread when the page asked for a new window that this view did not get
/// a tab for (its delegate declined, or popups are off), with the window's URL. The handler
/// may open it in this tab.
@property (nonatomic, copy, nullable) void (^blockedPopupHandler)(NSString *url);

#pragma mark The agent's own pointer and keyboard

/// Input for the agent that is real to the page and invisible to the system: the events are
/// built as the system builds them from the hardware (NSEvent) and handed to Chromium's view
/// the way the window hands them over, so the page sees a person's click, drag or key, while
/// the person's own mouse and keyboard are left alone. The agent's pointer is drawn on the
/// page as an arrow of its own. Points are CSS pixels of the page, from its top left.

/// Brings the window on screen and gives the page the keyboard, without taking the person's
/// focus from another app.
- (void)takeFront;

/// Shows the agent's pointer on the page, or hides it.
- (void)showPointer:(BOOL)shown;

/// Moves the pointer to the point: a move, or a drag while a button is held. `flags` are the
/// modifier keys held meanwhile. Returns NO when the view is not in a window.
- (BOOL)pointerMoveToX:(double)x y:(double)y flags:(CGEventFlags)flags
    NS_SWIFT_NAME(pointerMove(toX:y:flags:));
- (BOOL)pointerButton:(ChromiumMouseButton)button
                 down:(BOOL)down
                    x:(double)x
                    y:(double)y
           clickCount:(NSInteger)clickCount
                flags:(CGEventFlags)flags NS_SWIFT_NAME(pointerButton(_:down:x:y:clickCount:flags:));
/// Forgets a held button without an event, when the page took the drag over as a drop.
- (void)releasePointer;
/// One turn of the wheel at the point: positive deltas scroll right and down, in pixels.
- (BOOL)wheelAtX:(double)x y:(double)y deltaX:(double)deltaX deltaY:(double)deltaY flags:(CGEventFlags)flags
    NS_SWIFT_NAME(wheel(atX:y:deltaX:deltaY:flags:));

/// A key going down or up, by its macOS virtual key code, with the characters the key event
/// carries (as modified, and without the modifiers) and the modifier keys held. A modifier
/// key's own code (Shift, Command, ...) makes a flags-changed event.
- (BOOL)keyCode:(CGKeyCode)keyCode
           down:(BOOL)down
          flags:(CGEventFlags)flags
     characters:(NSString *)characters
     unmodified:(NSString *)unmodified NS_SWIFT_NAME(keyCode(_:down:flags:characters:unmodified:));

/// Hands the focused control text as an input method does when it commits a composition: how
/// characters a keyboard cannot type (Chinese, say) arrive. NO when nothing takes text.
- (BOOL)insertText:(NSString *)text;

/// Renders the page inside Chromium (no screen recording involved, so it works while the
/// window is hidden from capture). Calls back on the main thread with PNG data and an
/// image sized in points, or an error message.
- (void)captureScreenshotOfArea:(ChromiumScreenshotArea)area
                     completion:(void (^)(NSData *_Nullable pngData,
                                          NSImage *_Nullable image,
                                          NSString *_Nullable errorMessage))completion;

@end

NS_ASSUME_NONNULL_END
