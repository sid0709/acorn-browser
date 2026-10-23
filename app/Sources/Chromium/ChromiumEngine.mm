#import "ChromiumInternal.h"

#include <crt_externs.h>
#include <objc/runtime.h>

#include <algorithm>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_cookie.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

NSNotificationName const ChromiumEngineDidStartNotification = @"ChromiumEngineDidStartNotification";

#pragma mark - CefAppProtocol support

// Chromium requires NSApp to implement CefAppProtocol. SwiftUI always installs its own
// NSApplication subclass (and ignores NSPrincipalClass), so the protocol's methods are
// added to whatever class NSApp is at runtime instead of subclassing.
namespace {

BOOL gHandlingSendEvent = NO;

void InstallCefAppProtocol(Class appClass) {
  if (class_conformsToProtocol(appClass, @protocol(CefAppProtocol))) {
    return;
  }

  class_addMethod(appClass, @selector(isHandlingSendEvent),
                  imp_implementationWithBlock(^BOOL(id) {
                    return gHandlingSendEvent;
                  }),
                  "B@:");
  class_addMethod(appClass, @selector(setHandlingSendEvent:),
                  imp_implementationWithBlock(^(id, BOOL handlingSendEvent) {
                    gHandlingSendEvent = handlingSendEvent;
                  }),
                  "v@:B");

  // Wrap sendEvent: so Chromium knows when AppKit is dispatching an event.
  SEL sendEvent = @selector(sendEvent:);
  Method method = class_getInstanceMethod(appClass, sendEvent);
  using SendEventIMP = void (*)(id, SEL, NSEvent *);
  auto original = reinterpret_cast<SendEventIMP>(method_getImplementation(method));
  IMP wrapped = imp_implementationWithBlock(^(id app, NSEvent *event) {
    CefScopedSendingEvent sendingEventScoper;
    original(app, sendEvent, event);
  });
  // Adds an override if sendEvent: is inherited; replaces it if the class defines it.
  if (!class_addMethod(appClass, sendEvent, wrapped, method_getTypeEncoding(method))) {
    method_setImplementation(method, wrapped);
  }

  class_addProtocol(appClass, @protocol(CrAppProtocol));
  class_addProtocol(appClass, @protocol(CrAppControlProtocol));
  class_addProtocol(appClass, @protocol(CefAppProtocol));
}

}  // namespace

#pragma mark - Message pump

// CEF runs inside AppKit's run loop (SwiftUI owns the loop), so Chromium work is
// driven by CefDoMessageLoopWork() whenever CEF asks for it via
// OnScheduleMessagePumpWork(), plus a slow fallback timer. Mirrors cefclient's
// MainMessageLoopExternalPump.
namespace {

constexpr int64_t kMaxTimerDelayMs = 1000 / 30;
constexpr int64_t kTimerDelayPlaceholder = INT64_MAX;

NSTimer *gPumpTimer = nil;
bool gPumpActive = false;
bool gPumpReentrant = false;
bool gRunning = false;
bool gReady = false;
bool gUsesSystemKeychain = true;
NSArray<NSString *> *gExtensionDirectories = @[];

void SchedulePumpWorkOnMain(int64_t delayMs);

void KillPumpTimer() {
  [gPumpTimer invalidate];
  gPumpTimer = nil;
}

void PostPumpWork(int64_t delayMs) {
  dispatch_async(dispatch_get_main_queue(), ^{
    SchedulePumpWorkOnMain(delayMs);
  });
}

// Returns true if CefDoMessageLoopWork() was re-entered during this call.
bool PerformPumpWork() {
  if (gPumpActive) {
    gPumpReentrant = true;
    return false;
  }
  gPumpActive = true;
  CefDoMessageLoopWork();
  gPumpActive = false;

  const bool reentrant = gPumpReentrant;
  gPumpReentrant = false;
  return reentrant;
}

void DoPumpWork() {
  if (!gRunning) {
    return;
  }
  if (PerformPumpWork()) {
    PostPumpWork(0);
  } else if (gPumpTimer == nil) {
    PostPumpWork(kTimerDelayPlaceholder);
  }
}

void SchedulePumpWorkOnMain(int64_t delayMs) {
  if (!gRunning) {
    return;
  }
  if (delayMs == kTimerDelayPlaceholder && gPumpTimer != nil) {
    return;
  }
  KillPumpTimer();

  if (delayMs <= 0) {
    DoPumpWork();
    return;
  }

  const int64_t clamped = std::min(delayMs, kMaxTimerDelayMs);
  gPumpTimer = [NSTimer timerWithTimeInterval:clamped / 1000.0
                                      repeats:NO
                                        block:^(NSTimer *) {
                                          gPumpTimer = nil;
                                          DoPumpWork();
                                        }];
  [[NSRunLoop mainRunLoop] addTimer:gPumpTimer forMode:NSRunLoopCommonModes];
}

class ChromiumApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnBeforeCommandLineProcessing(const CefString &process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    // Only the browser process touches the Keychain.
    if (process_type.empty() && !gUsesSystemKeychain) {
      command_line->AppendSwitch("use-mock-keychain");
    }
    // Extensions the app installed itself, unpacked. Chromium turns --load-extension off by
    // default now; the feature that does so is turned off with it.
    if (process_type.empty() && gExtensionDirectories.count > 0) {
      NSString *joined = [gExtensionDirectories componentsJoinedByString:@","];
      command_line->AppendSwitchWithValue("load-extension", joined.UTF8String);
      command_line->AppendSwitchWithValue("disable-features", "DisableLoadExtensionCommandLineSwitch");
    }
  }

  // Browsers can only be created from here on; CefInitialize() returns before this.
  void OnContextInitialized() override {
    // Announce it after this callback returns: browsers created from inside it don't
    // start loading.
    dispatch_async(dispatch_get_main_queue(), ^{
      gReady = true;
      [[NSNotificationCenter defaultCenter] postNotificationName:ChromiumEngineDidStartNotification
                                                          object:nil];
    });
  }

  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    // May be called on any thread.
    PostPumpWork(delay_ms);
  }

 private:
  IMPLEMENT_REFCOUNTING(ChromiumApp);
};

int gLiveBrowserCount = 0;

NSString *ChromiumDataDirectory() {
  NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask]
                       .firstObject;
  NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"com.acorn.browser";
  return [[support URLByAppendingPathComponent:bundleID] URLByAppendingPathComponent:@"Chromium"]
      .path;
}

// _exit skips static destructors, which Chromium's framework doesn't expect to run while it
// is still active. Preferences are saved first because _exit would drop pending writes.
[[noreturn]] void ChromiumExitNow() {
  [NSUserDefaults.standardUserDefaults synchronize];
  _exit(0);
}

// Reports when Chromium has written its cookies to disk.
class CookieFlushCallback : public CefCompletionCallback {
 public:
  void OnComplete() override {
    ChromiumExitNow();
  }

 private:
  IMPLEMENT_REFCOUNTING(CookieFlushCallback);
};

}  // namespace

namespace chromium {

int LiveBrowserCount() {
  return gLiveBrowserCount;
}

void BrowserCreated() {
  ++gLiveBrowserCount;
}

void BrowserClosed() {
  gLiveBrowserCount = std::max(0, gLiveBrowserCount - 1);
}

}  // namespace chromium

#pragma mark - Engine

@implementation ChromiumEngine

+ (BOOL)start {
  if (gRunning) {
    return YES;
  }

  if (NSApp == nil) {
    NSLog(@"ChromiumEngine: start called before NSApplication exists.");
    return NO;
  }
  InstallCefAppProtocol([NSApp class]);

  // Intentionally leaked: the framework stays loaded for the life of the process.
  static CefScopedLibraryLoader *libraryLoader = new CefScopedLibraryLoader();
  if (!libraryLoader->LoadInMain()) {
    NSLog(@"ChromiumEngine: failed to load Chromium Embedded Framework.");
    return NO;
  }

  NSString *dataDirectory = ChromiumDataDirectory();
  NSString *profileDirectory = [dataDirectory stringByAppendingPathComponent:@"Default"];
  [[NSFileManager defaultManager] createDirectoryAtPath:profileDirectory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];

  CefSettings settings;
  settings.no_sandbox = false;
  settings.external_message_pump = true;
  settings.persist_session_cookies = true;
  settings.background_color = CefColorSetARGB(255, 255, 255, 255);
  settings.log_severity = LOGSEVERITY_ERROR;
  CefString(&settings.root_cache_path) = dataDirectory.UTF8String;
  CefString(&settings.cache_path) = profileDirectory.UTF8String;
  CefString(&settings.log_file) =
      [dataDirectory stringByAppendingPathComponent:@"chromium.log"].UTF8String;

  CefMainArgs mainArgs(*_NSGetArgc(), *_NSGetArgv());
  CefRefPtr<ChromiumApp> app(new ChromiumApp());
  if (!CefInitialize(mainArgs, settings, app, nullptr)) {
    NSLog(@"ChromiumEngine: CefInitialize failed (exit code %d).", CefGetExitCode());
    return NO;
  }

  gRunning = true;
  PostPumpWork(0);
  return YES;
}

+ (void)quitImmediately {
  // Whatever happens below, the process ends within a second, so a quit can never leave
  // the app half-alive with its hotkeys dead.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                 dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                   ChromiumExitNow();
                 });

  if (!gRunning) {
    ChromiumExitNow();
  }
  CefRefPtr<CefCookieManager> cookies = CefCookieManager::GetGlobalManager(nullptr);
  if (!cookies || !cookies->FlushStore(new CookieFlushCallback())) {
    ChromiumExitNow();
  }
}

+ (BOOL)isRunning {
  return gRunning;
}

+ (BOOL)isReady {
  return gReady;
}

+ (BOOL)usesSystemKeychain {
  return gUsesSystemKeychain;
}

+ (void)setUsesSystemKeychain:(BOOL)usesSystemKeychain {
  gUsesSystemKeychain = usesSystemKeychain;
}

+ (NSArray<NSString *> *)extensionDirectories {
  return gExtensionDirectories;
}

+ (void)setExtensionDirectories:(NSArray<NSString *> *)extensionDirectories {
  gExtensionDirectories = [extensionDirectories copy];
}

+ (NSString *)chromiumVersion {
  return [NSString stringWithFormat:@"%d.%d.%d.%d", CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR,
                                    CHROME_VERSION_BUILD, CHROME_VERSION_PATCH];
}

+ (NSString *)cefVersion {
  return @CEF_VERSION;
}

+ (NSString *)userAgent {
  // Chromium's reduced user agent: the macOS version is frozen at 10_15_7 and only the
  // major Chrome version is exposed. Chromium sends this by default; nothing overrides it.
  return [NSString stringWithFormat:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                                    @"AppleWebKit/537.36 (KHTML, like Gecko) "
                                    @"Chrome/%d.0.0.0 Safari/537.36",
                                    CHROME_VERSION_MAJOR];
}

@end
