#import "ChromiumInternal.h"

#include <crt_externs.h>
#include <cxxabi.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <unordered_map>
#include <utility>
#include <vector>

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
    // Not timed on its own: a menu or a window drag runs its whole loop inside one event.
    chromium::PerfScope scope("input event", false);
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
// How many times the pump has run, for the hitch watcher to tell one long run from many.
std::atomic<uint64_t> gPumpRuns{0};
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
  {
    chromium::PerfScope scope("chromium pump");
    CefDoMessageLoopWork();
  }
  gPumpRuns.fetch_add(1, std::memory_order_relaxed);
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

// Read by the hitch watcher's thread as well.
std::atomic<int> gLiveBrowserCount{0};

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

#pragma mark - Hitch watch

namespace {

constexpr useconds_t kPingIntervalUs = 100 * 1000;
constexpr useconds_t kSampleIntervalUs = 10 * 1000;
constexpr double kStallMs = 250;
constexpr double kSlowSectionMs = 30;
const char *const kNoSection = "AppKit/SwiftUI";

/// The section the main thread is in now, read by the watcher's thread.
std::atomic<const char *> gSection{nullptr};
/// The last ping the main thread answered, and whether the app was frontmost then.
std::atomic<uint64_t> gAnsweredPing{0};
std::atomic<bool> gAppActive{true};
/// perf.log and its clock, on the log's queue only.
NSFileHandle *gPerfFile = nil;
NSISO8601DateFormatter *gPerfStamp = nil;

struct OpenSection {
  const char *name;
  CFAbsoluteTime start;
  bool reportsSlow;
};

/// The sections the main thread is in, innermost last. Main thread only.
std::vector<OpenSection> &SectionStack() {
  static std::vector<OpenSection> stack;
  return stack;
}

dispatch_queue_t PerfLogQueue() {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.acorn.browser.perf-log", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

/// To the system log, and to perf.log beside the Chromium folder (started afresh past 5 MB).
void PerfLog(NSString *line) {
  NSLog(@"[acorn-perf] %@", line);
  NSDate *now = [NSDate date];
  dispatch_async(PerfLogQueue(), ^{
    if (!gPerfFile) {
      NSString *path = [ChromiumDataDirectory().stringByDeletingLastPathComponent
          stringByAppendingPathComponent:@"perf.log"];
      NSFileManager *files = NSFileManager.defaultManager;
      NSNumber *size = [files attributesOfItemAtPath:path error:nil][NSFileSize];
      if (![files fileExistsAtPath:path] || size.unsignedLongLongValue > 5 * 1024 * 1024) {
        [files createDirectoryAtPath:path.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:nil];
        [files createFileAtPath:path contents:nil attributes:nil];
      }
      gPerfFile = [NSFileHandle fileHandleForWritingAtPath:path];
      [gPerfFile seekToEndOfFile];
      gPerfStamp = [[NSISO8601DateFormatter alloc] init];
      gPerfStamp.formatOptions =
          NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    }
    NSString *entry = [NSString stringWithFormat:@"%@ %@\n", [gPerfStamp stringFromDate:now], line];
    [gPerfFile writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
  });
}

void EnterSection(const char *name, bool reportsSlow = true) {
  SectionStack().push_back({name, CFAbsoluteTimeGetCurrent(), reportsSlow});
  gSection.store(name, std::memory_order_relaxed);
}

void LeaveSection() {
  std::vector<OpenSection> &stack = SectionStack();
  if (stack.empty()) {
    return;
  }
  const OpenSection open = stack.back();
  stack.pop_back();
  gSection.store(stack.empty() ? nullptr : stack.back().name, std::memory_order_relaxed);
  const double ms = (CFAbsoluteTimeGetCurrent() - open.start) * 1000;
  if (open.reportsSlow && ms > kSlowSectionMs) {
    PerfLog([NSString stringWithFormat:@"%s took %.0f ms (%d browsers)", open.name, ms,
                                       chromium::LiveBrowserCount()]);
  }
}

/// Swift's section names as C strings that live as long as the app. Main thread only.
const char *InternSection(NSString *name) {
  static NSMutableDictionary<NSString *, NSValue *> *names = [NSMutableDictionary dictionary];
  NSValue *known = names[name];
  if (known) {
    return (const char *)known.pointerValue;
  }
  const char *copy = strdup(name.UTF8String ?: "?");
  names[name] = [NSValue valueWithPointer:copy];
  return copy;
}

/// The main thread's call stack at one moment: return addresses, innermost first.
struct MainStack {
  static constexpr int kMaxFrames = 48;
  int count = 0;
  uintptr_t frames[kMaxFrames];
  bool operator==(const MainStack &other) const {
    return count == other.count && std::equal(frames, frames + count, other.frames);
  }
};

/// An address as code can be found at: without the pointer-signing bits an arm64e system
/// library leaves in the return addresses it saves.
uintptr_t CodeAddress(uintptr_t address) {
  return address & 0x00007FFFFFFFFFFFULL;
}

/// Stops the main thread for a moment and walks its frame pointers. Nothing between suspend
/// and resume takes a lock or allocates: the main thread may be holding the lock.
bool SampleMainStack(MainStack &stack) {
  pthread_t main = pthread_main_thread_np();
  const mach_port_t thread = pthread_mach_thread_np(main);
  const uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(main);
  const uintptr_t bottom = top - pthread_get_stacksize_np(main);
  if (thread_suspend(thread) != KERN_SUCCESS) {
    return false;
  }
  stack.count = 0;
  uintptr_t fp = 0;
#if defined(__arm64__)
  arm_thread_state64_t state;
  mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
  if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count) == KERN_SUCCESS) {
    stack.frames[stack.count++] = CodeAddress((uintptr_t)arm_thread_state64_get_pc(state));
    // A leaf function may not have saved its frame yet: its caller is in the link register.
    stack.frames[stack.count++] = CodeAddress((uintptr_t)arm_thread_state64_get_lr(state));
    fp = (uintptr_t)arm_thread_state64_get_fp(state);
  }
#elif defined(__x86_64__)
  x86_thread_state64_t state;
  mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
  if (thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &count) == KERN_SUCCESS) {
    stack.frames[stack.count++] = (uintptr_t)state.__rip;
    fp = (uintptr_t)state.__rbp;
  }
#endif
  while (fp >= bottom && fp + 2 * sizeof(uintptr_t) <= top && fp % sizeof(uintptr_t) == 0 &&
         stack.count < MainStack::kMaxFrames) {
    const uintptr_t next = ((const uintptr_t *)fp)[0];
    const uintptr_t returnAddress = CodeAddress(((const uintptr_t *)fp)[1]);
    if (returnAddress == 0) {
      break;
    }
    stack.frames[stack.count++] = returnAddress;
    if (next <= fp) {
      break;
    }
    fp = next;
  }
  thread_resume(thread);
  return stack.count > 0;
}

/// A symbol's name as written in its source: Swift's and C++'s names come mangled.
NSString *ReadableName(const char *name) {
  using SwiftDemangle = char *(*)(const char *, size_t, char *, size_t *, uint32_t);
  static SwiftDemangle swiftDemangle = (SwiftDemangle)dlsym(RTLD_DEFAULT, "swift_demangle");
  char *readable = nullptr;
  if (strncmp(name, "$s", 2) == 0 && swiftDemangle) {
    readable = swiftDemangle(name, strlen(name), nullptr, nullptr, 0);
  } else if (strncmp(name, "_Z", 2) == 0) {
    int status = 0;
    readable = abi::__cxa_demangle(name, nullptr, nullptr, &status);
  }
  NSString *result = [NSString stringWithUTF8String:readable ? readable : name] ?: @"?";
  free(readable);
  // Swift's full names run long; the line stays readable without the parameter list.
  return result.length > 160 ? [[result substringToIndex:160] stringByAppendingString:@"…"] : result;
}

/// One line per frame: the library, the nearest symbol and how far past it. Library and offset
/// let a stripped frame (Chromium's) be looked up later with the framework's own symbols.
NSString *DescribeStack(const MainStack &stack) {
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  for (int i = 0; i < stack.count; i++) {
    const uintptr_t address = stack.frames[i];
    Dl_info info = {};
    // A return address points just past the call; look up the call itself.
    if (dladdr((const void *)(i == 0 ? address : address - 1), &info) == 0) {
      [lines addObject:[NSString stringWithFormat:@"    #%-2d ? 0x%lx", i, (unsigned long)address]];
      continue;
    }
    NSString *library = info.dli_fname ? @(info.dli_fname).lastPathComponent : @"?";
    const uintptr_t imageOffset = address - (uintptr_t)info.dli_fbase;
    if (info.dli_sname) {
      [lines addObject:[NSString stringWithFormat:@"    #%-2d %@  %@ + %lu  (image +0x%lx)", i, library,
                                                  ReadableName(info.dli_sname),
                                                  (unsigned long)(address - (uintptr_t)info.dli_saddr),
                                                  (unsigned long)imageOffset]];
    } else {
      [lines addObject:[NSString stringWithFormat:@"    #%-2d %@  +0x%lx", i, library, (unsigned long)imageOffset]];
    }
  }
  return [lines componentsJoinedByString:@"\n"];
}

/// CPU time the main thread has used, in ms: against the wall clock it tells a main thread
/// that was working from one that was waiting.
double MainThreadCPUMs() {
  thread_basic_info_data_t info;
  mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
  const mach_port_t thread = pthread_mach_thread_np(pthread_main_thread_np());
  if (thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&info, &count) != KERN_SUCCESS) {
    return 0;
  }
  return (info.user_time.seconds + info.system_time.seconds) * 1000.0 +
         (info.user_time.microseconds + info.system_time.microseconds) / 1000.0;
}

/// The watcher: pings the main thread, and while an answer is late, notes which section the
/// main thread is in every 10 ms, and from 400 ms on takes its call stack every half second.
void WatchMainThread() {
  constexpr double kFirstStackMs = 400;
  constexpr double kStackEveryMs = 500;
  constexpr size_t kMaxStacksShown = 3;
  uint64_t ping = 0;
  for (;;) {
    usleep(kPingIntervalUs);
    const uint64_t mine = ++ping;
    const CFAbsoluteTime sent = CFAbsoluteTimeGetCurrent();
    const uint64_t pumpRunsBefore = gPumpRuns.load(std::memory_order_relaxed);
    const double cpuBefore = MainThreadCPUMs();
    dispatch_async(dispatch_get_main_queue(), ^{
      gAppActive.store(NSApp.isActive, std::memory_order_relaxed);
      gAnsweredPing.store(mine, std::memory_order_release);
    });

    std::unordered_map<const char *, int> samples;
    // Distinct stacks seen, with how many times each.
    std::vector<std::pair<MainStack, int>> stacks;
    double nextStackMs = kFirstStackMs;
    while (gAnsweredPing.load(std::memory_order_acquire) < mine) {
      usleep(kSampleIntervalUs);
      const char *section = gSection.load(std::memory_order_relaxed);
      samples[section ? section : kNoSection]++;
      const double late = (CFAbsoluteTimeGetCurrent() - sent) * 1000;
      if (late >= nextStackMs) {
        nextStackMs += kStackEveryMs;
        MainStack stack;
        if (gAnsweredPing.load(std::memory_order_acquire) < mine && SampleMainStack(stack)) {
          auto seen = std::find_if(stacks.begin(), stacks.end(),
                                   [&](const auto &entry) { return entry.first == stack; });
          if (seen != stacks.end()) {
            seen->second++;
          } else {
            stacks.push_back({stack, 1});
          }
        }
      }
    }

    const double waited = (CFAbsoluteTimeGetCurrent() - sent) * 1000;
    if (waited < kStallMs) {
      continue;
    }
    const double cpu = MainThreadCPUMs() - cpuBefore;
    std::vector<std::pair<const char *, int>> ranked(samples.begin(), samples.end());
    std::sort(ranked.begin(), ranked.end(), [](const auto &a, const auto &b) { return a.second > b.second; });
    int total = 0;
    for (const auto &entry : ranked) {
      total += entry.second;
    }
    NSMutableArray<NSString *> *shares = [NSMutableArray array];
    for (const auto &entry : ranked) {
      [shares addObject:[NSString stringWithFormat:@"%s %.0f ms", entry.first,
                                                   waited * entry.second / std::max(total, 1)]];
    }
    const uint64_t pumpRuns = gPumpRuns.load(std::memory_order_relaxed) - pumpRunsBefore;
    NSMutableString *report = [NSMutableString
        stringWithFormat:@"main thread stuck %.0f ms, %.0f ms of it on the CPU (%d browsers, %llu pump runs%@): %@",
                         waited, cpu, chromium::LiveBrowserCount(), pumpRuns,
                         gAppActive.load(std::memory_order_relaxed) ? @"" : @", app in background",
                         [shares componentsJoinedByString:@", "]];
    std::sort(stacks.begin(), stacks.end(), [](const auto &a, const auto &b) { return a.second > b.second; });
    int stackSamples = 0;
    for (const auto &entry : stacks) {
      stackSamples += entry.second;
    }
    for (size_t i = 0; i < stacks.size() && i < kMaxStacksShown; i++) {
      [report appendFormat:@"\n  main thread's stack, %d of %d samples:\n%@", stacks[i].second, stackSamples,
                           DescribeStack(stacks[i].first)];
    }
    PerfLog(report);
  }
}

}  // namespace

namespace chromium {

int LiveBrowserCount() {
  return gLiveBrowserCount.load(std::memory_order_relaxed);
}

void BrowserCreated() {
  gLiveBrowserCount.fetch_add(1, std::memory_order_relaxed);
}

void BrowserClosed() {
  gLiveBrowserCount.store(std::max(0, LiveBrowserCount() - 1), std::memory_order_relaxed);
}

PerfScope::PerfScope(const char *section, bool reportsSlow) {
  EnterSection(section, reportsSlow);
}

PerfScope::~PerfScope() {
  LeaveSection();
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

#pragma mark - ChromiumPerf

@implementation ChromiumPerf

+ (void)startWatching {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSNumber *wanted = [NSUserDefaults.standardUserDefaults objectForKey:@"perfWatch"];
    if (wanted && !wanted.boolValue) {
      return;
    }
    NSThread *watcher = [[NSThread alloc] initWithBlock:^{
      WatchMainThread();
    }];
    watcher.name = @"acorn-perf-watch";
    watcher.qualityOfService = NSQualityOfServiceUserInteractive;
    [watcher start];
    PerfLog(@"watching the main thread");
  });
}

+ (void)enter:(NSString *)section {
  EnterSection(InternSection(section));
}

+ (void)leave {
  LeaveSection();
}

+ (void)note:(NSString *)message {
  PerfLog(message);
}

@end
