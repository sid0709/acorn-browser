#import "ChromiumInternal.h"

#include <set>
#include <string>
#include <vector>

#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_parser.h"

namespace {

NSString *ToNSString(const CefString &value) {
  const std::string utf8 = value.ToString();
  return [NSString stringWithUTF8String:utf8.c_str()] ?: @"";
}

CefString ToCefString(NSString *value) {
  return CefString(std::string(value.UTF8String ?: ""));
}

// Blocks page-level drag and drop (dragstart/drop) while drag and drop is disabled.
// External drags are also refused natively in OnDragEnter.
constexpr char kDragDropBootstrapScript[] = R"JS(
(function() {
    if (window.__stealthDragDropListenersInstalled) { return; }
    window.__stealthDragDropListenersInstalled = true;
    window.__stealthDragDropEnabled = false;

    function block(event) {
        if (window.__stealthDragDropEnabled) { return; }
        event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation();
        return false;
    }

    ['dragenter', 'dragover', 'dragleave', 'drop', 'dragstart'].forEach(function(type) {
        window.addEventListener(type, block, true);
        document.addEventListener(type, block, true);
    });
})();
)JS";

NSString *DragDropPolicyScript(BOOL enabled) {
  return [NSString stringWithFormat:@"%s\nwindow.__stealthDragDropEnabled = %@;",
                                    kDragDropBootstrapScript, enabled ? @"true" : @"false"];
}

NSString *JoinPhrases(NSArray<NSString *> *phrases) {
  if (phrases.count <= 1) {
    return phrases.firstObject ?: @"";
  }
  NSArray *head = [phrases subarrayWithRange:NSMakeRange(0, phrases.count - 1)];
  return [NSString stringWithFormat:@"%@ and %@", [head componentsJoinedByString:@", "],
                                    phrases.lastObject];
}

NSString *DescribeMediaRequest(uint32_t requested) {
  NSMutableArray<NSString *> *phrases = [NSMutableArray array];
  const BOOL camera = requested & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
  const BOOL microphone = requested & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE;
  if (camera && microphone) {
    [phrases addObject:@"use your camera and microphone"];
  } else if (camera) {
    [phrases addObject:@"use your camera"];
  } else if (microphone) {
    [phrases addObject:@"use your microphone"];
  }
  if (requested & (CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE |
                   CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE)) {
    [phrases addObject:@"share your screen"];
  }
  return phrases.count ? JoinPhrases(phrases) : @"use your media devices";
}

NSString *DescribePermissionRequest(uint32_t requested) {
  static const struct {
    uint32_t flag;
    NSString *phrase;
  } kPhrases[] = {
      {CEF_PERMISSION_TYPE_CAMERA_STREAM, @"use your camera"},
      {CEF_PERMISSION_TYPE_MIC_STREAM, @"use your microphone"},
      {CEF_PERMISSION_TYPE_GEOLOCATION, @"know your location"},
      {CEF_PERMISSION_TYPE_NOTIFICATIONS, @"show notifications"},
      {CEF_PERMISSION_TYPE_CLIPBOARD, @"see text and images copied to the clipboard"},
      {CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, @"download multiple files"},
      {CEF_PERMISSION_TYPE_MIDI_SYSEX, @"use your MIDI devices"},
      {CEF_PERMISSION_TYPE_LOCAL_FONTS, @"use the fonts on your computer"},
      {CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, @"manage windows on all your displays"},
      {CEF_PERMISSION_TYPE_STORAGE_ACCESS, @"use cookies and site data across sites"},
      {CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, @"use cookies and site data across sites"},
      {CEF_PERMISSION_TYPE_IDLE_DETECTION, @"know when you're actively using this device"},
      {CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS, @"edit files on your computer"},
  };

  NSMutableOrderedSet<NSString *> *phrases = [NSMutableOrderedSet orderedSet];
  uint32_t described = 0;
  for (const auto &entry : kPhrases) {
    if (requested & entry.flag) {
      [phrases addObject:entry.phrase];
      described |= entry.flag;
    }
  }
  if (requested & ~described) {
    [phrases addObject:@"use additional browser features"];
  }
  return JoinPhrases(phrases.array);
}

NSString *UniqueDownloadPath(NSString *suggestedName) {
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSURL *downloads = [fileManager URLsForDirectory:NSDownloadsDirectory
                                         inDomains:NSUserDomainMask]
                         .firstObject;
  NSString *name = [suggestedName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  if (name.length == 0) {
    name = @"download";
  }

  NSString *base = name.stringByDeletingPathExtension;
  NSString *extension = name.pathExtension;
  NSString *candidate = [downloads URLByAppendingPathComponent:name].path;
  for (NSInteger index = 1; [fileManager fileExistsAtPath:candidate]; ++index) {
    NSString *numbered = [NSString stringWithFormat:@"%@ (%ld)", base, (long)index];
    if (extension.length) {
      numbered = [numbered stringByAppendingPathExtension:extension];
    }
    candidate = [downloads URLByAppendingPathComponent:numbered].path;
  }
  return candidate;
}

// Schemes Chromium loads itself. Anything else (slack:, zoommtg:, mailto:, ...) belongs to
// another app on the Mac, which Chrome hands the link to after asking.
BOOL IsBrowserHandledScheme(NSString *scheme) {
  static NSSet<NSString *> *schemes = [NSSet setWithArray:@[
    @"http", @"https", @"about", @"data", @"blob", @"file", @"filesystem", @"javascript",
    @"ws", @"wss", @"chrome", @"chrome-error", @"chrome-extension", @"devtools",
    @"view-source"
  ]];
  return scheme.length == 0 || [schemes containsObject:scheme.lowercaseString];
}

NSString *const kExternalProtocolAllowListKey = @"browser.externalProtocolAllowList";

/// "Always allow" choices, keyed by site host, each listing the schemes it may open.
BOOL IsExternalProtocolAllowed(NSString *host, NSString *scheme) {
  NSDictionary *allowList = [NSUserDefaults.standardUserDefaults dictionaryForKey:kExternalProtocolAllowListKey];
  NSArray *schemes = allowList[host];
  return [schemes isKindOfClass:NSArray.class] && [schemes containsObject:scheme];
}

void AllowExternalProtocol(NSString *host, NSString *scheme) {
  NSMutableDictionary *allowList =
      [[NSUserDefaults.standardUserDefaults dictionaryForKey:kExternalProtocolAllowListKey] mutableCopy]
          ?: [NSMutableDictionary dictionary];
  NSMutableArray *schemes = [allowList[host] mutableCopy] ?: [NSMutableArray array];
  if (![schemes containsObject:scheme]) {
    [schemes addObject:scheme];
  }
  allowList[host] = schemes;
  [NSUserDefaults.standardUserDefaults setObject:allowList forKey:kExternalProtocolAllowListKey];
}

NSHashTable<ChromiumBrowserView *> *LiveViews() {
  static NSHashTable *views = [NSHashTable weakObjectsHashTable];
  return views;
}

}  // namespace

#pragma mark - Private interface used by the CEF client

@interface ChromiumBrowserView ()
- (BOOL)cef_shouldBlockPopup:(int)popupID
                 disposition:(cef_window_open_disposition_t)disposition
                 userGesture:(bool)userGesture
                  windowInfo:(CefWindowInfo &)windowInfo
                      client:(CefRefPtr<CefClient> &)client;
- (void)cef_popupAborted:(int)popupID;
- (void)cef_didCreateBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)cef_doClose;
- (void)cef_willCloseBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)cef_setURL:(NSString *)url;
- (void)cef_setTitle:(NSString *)title;
- (void)cef_setLoading:(BOOL)isLoading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)cef_setFullscreen:(BOOL)fullscreen;
- (void)cef_setLoadingProgress:(double)progress;
- (void)cef_setFaviconURLs:(NSArray<NSString *> *)urls;
- (void)cef_frameDidStartLoading:(CefRefPtr<CefFrame>)frame;
- (void)cef_askPermissionTo:(NSString *)action
                     origin:(NSString *)origin
                   promptID:(uint64_t)promptID
                 completion:(void (^)(BOOL allowed))completion;
- (void)cef_dismissPermissionPrompt:(uint64_t)promptID;
- (BOOL)cef_handleExternalURL:(NSString *)url fromPage:(NSString *)pageURL;
- (void)cef_devToolsResult:(int)messageID success:(BOOL)success data:(NSData *)data;
- (void)cef_devToolsEvent:(NSString *)method data:(NSData *)data;
- (BOOL)cef_answerDialog:(ChromiumDialogKind)kind
                 message:(NSString *)message
             defaultText:(NSString *)defaultText
                callback:(CefRefPtr<CefJSDialogCallback>)callback;
- (void)cef_download:(NSString *)fileName finished:(BOOL)finished;
- (void)cef_blockedPopup:(NSString *)url;
@end

#pragma mark - CEF client

namespace {

class FaviconCallback : public CefDownloadImageCallback {
 public:
  using Completion = void (^)(NSImage *_Nullable image);
  explicit FaviconCallback(Completion completion) : completion_(completion) {}

  void OnDownloadImageFinished(const CefString &image_url,
                               int http_status_code,
                               CefRefPtr<CefImage> image) override {
    NSImage *result = nil;
    if (image && !image->IsEmpty()) {
      int pixelWidth = 0;
      int pixelHeight = 0;
      CefRefPtr<CefBinaryValue> png = image->GetAsPNG(2.0f, true, pixelWidth, pixelHeight);
      if (png && png->GetSize() > 0) {
        NSMutableData *data = [NSMutableData dataWithLength:png->GetSize()];
        png->GetData(data.mutableBytes, data.length, 0);
        result = [[NSImage alloc] initWithData:data];
        result.size = NSMakeSize(16, 16);
      }
    }
    completion_(result);
  }

 private:
  Completion completion_;
  IMPLEMENT_REFCOUNTING(FaviconCallback);
};

class DevToolsObserver : public CefDevToolsMessageObserver {
 public:
  explicit DevToolsObserver(ChromiumBrowserView *view) : view_(view) {}

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void *result,
                              size_t result_size) override {
    NSData *data = [NSData dataWithBytes:result length:result_size];
    [view_ cef_devToolsResult:message_id success:success data:data];
  }

  void OnDevToolsEvent(CefRefPtr<CefBrowser> browser,
                       const CefString &method,
                       const void *params,
                       size_t params_size) override {
    NSData *data = [NSData dataWithBytes:params length:params_size];
    [view_ cef_devToolsEvent:ToNSString(method) data:data];
  }

 private:
  __weak ChromiumBrowserView *view_;
  IMPLEMENT_REFCOUNTING(DevToolsObserver);
};

class BrowserClient : public CefClient,
                      public CefLifeSpanHandler,
                      public CefDisplayHandler,
                      public CefLoadHandler,
                      public CefDragHandler,
                      public CefDownloadHandler,
                      public CefPermissionHandler,
                      public CefRequestHandler,
                      public CefJSDialogHandler {
 public:
  explicit BrowserClient(ChromiumBrowserView *view) : view_(view) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDragHandler> GetDragHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }

  // CefJSDialogHandler

  /// Returning false shows Chromium's own dialog; true means the view answered it.
  bool OnJSDialog(CefRefPtr<CefBrowser> browser,
                  const CefString &origin_url,
                  JSDialogType dialog_type,
                  const CefString &message_text,
                  const CefString &default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool &suppress_message) override {
    ChromiumDialogKind kind = ChromiumDialogKindAlert;
    if (dialog_type == JSDIALOGTYPE_CONFIRM) {
      kind = ChromiumDialogKindConfirm;
    } else if (dialog_type == JSDIALOGTYPE_PROMPT) {
      kind = ChromiumDialogKindPrompt;
    }
    return [view_ cef_answerDialog:kind
                           message:ToNSString(message_text)
                       defaultText:ToNSString(default_prompt_text)
                          callback:callback];
  }

  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                            const CefString &message_text,
                            bool is_reload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    return [view_ cef_answerDialog:ChromiumDialogKindBeforeUnload
                           message:ToNSString(message_text)
                       defaultText:@""
                          callback:callback];
  }

  // CefRequestHandler

  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override {
    // Returning true cancels the navigation.
    return [view_ cef_handleExternalURL:ToNSString(request->GetURL())
                               fromPage:ToNSString(frame->GetURL())];
  }

  // CefLifeSpanHandler

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString &target_url,
                     const CefString &target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures &popupFeatures,
                     CefWindowInfo &windowInfo,
                     CefRefPtr<CefClient> &client,
                     CefBrowserSettings &settings,
                     CefRefPtr<CefDictionaryValue> &extra_info,
                     bool *no_javascript_access) override {
    ChromiumBrowserView *view = view_;
    if (!view) {
      return true;
    }
    const BOOL blocked = [view cef_shouldBlockPopup:popup_id
                                        disposition:target_disposition
                                        userGesture:user_gesture
                                         windowInfo:windowInfo
                                             client:client];
    if (blocked) {
      [view cef_blockedPopup:ToNSString(target_url)];
    }
    return blocked;
  }

  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popup_id) override {
    [view_ cef_popupAborted:popup_id];
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    chromium::BrowserCreated();
    [view_ cef_didCreateBrowser:browser];
  }

  /// The app (not the page) is closing this browser: tab closed, app quitting or the view
  /// going away. Safe to call repeatedly.
  void BeginAppClose(CefRefPtr<CefBrowser> browser) {
    app_closing_ = true;
    if (close_accepted_) {
      // The page already agreed to close (DoClose ran); just finish.
      FinishClose(browser);
    } else {
      browser->GetHost()->CloseBrowser(true);
    }
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // The browser lives in a tab, not its own window, so always return true: false would
    // make CEF send performClose: to the whole window. Returning true obliges us to
    // finish the close ourselves.
    close_accepted_ = true;
    ChromiumBrowserView *view = view_;
    if (app_closing_ || !view) {
      FinishClose(browser);
      return true;
    }
    // The page asked to close (window.close()) or passed beforeunload after the close
    // button: let the tab model remove the tab, which comes back through BeginAppClose.
    [view cef_doClose];
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    chromium::BrowserClosed();
    [view_ cef_willCloseBrowser:browser];
  }

  // CefDisplayHandler

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString &url) override {
    if (frame->IsMain()) {
      [view_ cef_setURL:ToNSString(url)];
    }
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
    [view_ cef_setTitle:ToNSString(title)];
  }

  bool OnTooltip(CefRefPtr<CefBrowser> browser, CefString &text) override {
    // Returning true means "handled", which suppresses the tooltip.
    ChromiumBrowserView *view = view_;
    return view != nil && !view.allowsTooltips;
  }

  void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser, bool fullscreen) override {
    [view_ cef_setFullscreen:fullscreen];
  }

  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override {
    [view_ cef_setLoadingProgress:progress];
  }

  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString> &icon_urls) override {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    for (const auto &url : icon_urls) {
      [urls addObject:ToNSString(url)];
    }
    [view_ cef_setFaviconURLs:urls];
  }

  // CefLoadHandler

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override {
    [view_ cef_setLoading:isLoading canGoBack:canGoBack canGoForward:canGoForward];
  }

  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override {
    [view_ cef_frameDidStartLoading:frame];
  }

  // CefDragHandler

  bool OnDragEnter(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefDragData> dragData,
                   DragOperationsMask mask) override {
    // Returning true cancels the drag.
    ChromiumBrowserView *view = view_;
    return view != nil && !view.allowsDragAndDrop;
  }

  // CefDownloadHandler

  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> download_item,
                        const CefString &suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    NSString *path = UniqueDownloadPath(ToNSString(suggested_name));
    callback->Continue(ToCefString(path), false);
    [view_ cef_download:path.lastPathComponent finished:NO];
    return true;
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    if (!download_item->IsComplete() ||
        !completed_downloads_.insert(download_item->GetId()).second) {
      return;
    }
    // Bounces the Downloads stack in the Dock, like Safari and Chrome do.
    NSString *path = ToNSString(download_item->GetFullPath());
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@"com.apple.DownloadFileFinished"
                      object:path];
    [view_ cef_download:path.lastPathComponent finished:YES];
  }

  // CefPermissionHandler

  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      const CefString &requesting_origin,
                                      uint32_t requested_permissions,
                                      CefRefPtr<CefMediaAccessCallback> callback) override {
    ChromiumBrowserView *view = view_;
    if (!view) {
      return false;
    }
    [view cef_askPermissionTo:DescribeMediaRequest(requested_permissions)
                       origin:ToNSString(requesting_origin)
                     promptID:0
                   completion:^(BOOL allowed) {
                     if (allowed) {
                       callback->Continue(requested_permissions);
                     } else {
                       callback->Cancel();
                     }
                   }];
    return true;
  }

  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser,
                              uint64_t prompt_id,
                              const CefString &requesting_origin,
                              uint32_t requested_permissions,
                              CefRefPtr<CefPermissionPromptCallback> callback) override {
    ChromiumBrowserView *view = view_;
    if (!view) {
      return false;
    }
    [view cef_askPermissionTo:DescribePermissionRequest(requested_permissions)
                       origin:ToNSString(requesting_origin)
                     promptID:prompt_id
                   completion:^(BOOL allowed) {
                     callback->Continue(allowed ? CEF_PERMISSION_RESULT_ACCEPT
                                                : CEF_PERMISSION_RESULT_DENY);
                   }];
    return true;
  }

  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser,
                                 uint64_t prompt_id,
                                 cef_permission_request_result_t result) override {
    [view_ cef_dismissPermissionPrompt:prompt_id];
  }

 private:
  __weak ChromiumBrowserView *view_;
  std::set<uint32_t> completed_downloads_;
  bool app_closing_ = false;
  bool close_accepted_ = false;
  bool close_finished_ = false;

  /// CEF destroys a windowed browser (and calls OnBeforeClose) when its host view is
  /// freed, so finishing a close means tearing that view down. Done after the current
  /// CEF callback returns, never from inside it.
  void FinishClose(CefRefPtr<CefBrowser> browser) {
    if (close_finished_) {
      return;
    }
    close_finished_ = true;
    __weak NSView *hostView = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    dispatch_async(dispatch_get_main_queue(), ^{
      @autoreleasepool {
        [hostView removeFromSuperview];
      }
    });
  }

  IMPLEMENT_REFCOUNTING(BrowserClient);
};

}  // namespace

#pragma mark - ChromiumBrowserView

@implementation ChromiumBrowserView {
  CefRefPtr<BrowserClient> _client;
  CefRefPtr<CefBrowser> _browser;
  NSString *_pendingURL;
  BOOL _isPopupHost;
  BOOL _destroyed;
  BOOL _closeNotified;
  NSMapTable<NSNumber *, ChromiumBrowserView *> *_pendingPopups;
  NSMutableDictionary<NSNumber *, NSAlert *> *_permissionAlerts;
  BOOL _externalPromptVisible;
  CefRefPtr<CefRegistration> _devToolsRegistration;
  NSMutableDictionary<NSNumber *, void (^)(BOOL, NSDictionary *)> *_devToolsCallbacks;
  int _nextDevToolsMessageID;
}

- (instancetype)initWithURL:(NSString *)url {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _client = new BrowserClient(self);
    _pendingURL = [url copy];
    _currentURL = [url copy];
    _title = @"";
    _pendingPopups = [NSMapTable strongToWeakObjectsMapTable];
    _permissionAlerts = [NSMutableDictionary dictionary];
    _devToolsCallbacks = [NSMutableDictionary dictionary];
    _nextDevToolsMessageID = 1000;
    self.wantsLayer = YES;

    // The browser is created when this view joins a window, never earlier: SwiftUI can
    // build and discard extra copies of a view's state, and a browser started for one of
    // those would never be closed (it kept the app from quitting).
    if (!ChromiumEngine.isReady) {
      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(engineDidStart:)
                                                   name:ChromiumEngineDidStartNotification
                                                 object:nil];
    }
  }
  return self;
}

- (void)dealloc {
  [self destroyBrowser];
}

#pragma mark Layout

- (BOOL)isOpaque {
  return YES;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) {
    [self createBrowserIfNeeded];
  }
}

- (void)didAddSubview:(NSView *)subview {
  [super didAddSubview:subview];
  subview.frame = self.bounds;
  subview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  for (NSView *subview in self.subviews) {
    subview.frame = self.bounds;
  }
}

#pragma mark Browser lifetime

- (void)engineDidStart:(NSNotification *)notification {
  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:ChromiumEngineDidStartNotification
                                                object:nil];
  if (self.window) {
    [self createBrowserIfNeeded];
  }
}

- (void)createBrowserIfNeeded {
  if (_browser || _isPopupHost || _destroyed || !ChromiumEngine.isReady) {
    return;
  }

  const NSRect bounds = self.bounds;
  CefWindowInfo windowInfo;
  windowInfo.SetAsChild((__bridge void *)self,
                        CefRect(0, 0, (int)bounds.size.width, (int)bounds.size.height));
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

  CefBrowserSettings browserSettings;
  CefRefPtr<CefBrowser> browser = CefBrowserHost::CreateBrowserSync(
      windowInfo, _client.get(), ToCefString(_pendingURL), browserSettings, nullptr, nullptr);
  if (browser) {
    [self cef_didCreateBrowser:browser];
  }
}

- (void)requestClose {
  if (_browser && !_destroyed) {
    _browser->GetHost()->CloseBrowser(false);
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [self finishClose];
  });
}

- (void)finishClose {
  if (_closeNotified) {
    return;
  }
  _closeNotified = YES;
  [self.delegate browserViewDidRequestClose:self];
  [self destroyBrowser];
}

- (void)destroyBrowser {
  if (_destroyed) {
    return;
  }
  _destroyed = YES;

  for (NSAlert *alert in _permissionAlerts.allValues) {
    [self.window endSheet:alert.window returnCode:NSModalResponseAbort];
  }
  [_permissionAlerts removeAllObjects];

  if (_browser) {
    _client->BeginAppClose(_browser);
  } else {
    for (NSView *subview in [self.subviews copy]) {
      [subview removeFromSuperview];
    }
  }
}

#pragma mark Navigation

- (void)loadURL:(NSString *)url {
  if (![[NSURL URLWithString:url].host isEqualToString:[NSURL URLWithString:_currentURL].host]) {
    _favicon = nil;
  }
  _currentURL = [url copy];
  if (_browser) {
    _browser->GetMainFrame()->LoadURL(ToCefString(url));
  } else {
    _pendingURL = [url copy];
  }
}

- (void)goBack {
  if (_browser) {
    _browser->GoBack();
  }
}

- (void)goForward {
  if (_browser) {
    _browser->GoForward();
  }
}

- (void)reload {
  if (_browser) {
    _browser->Reload();
  }
}

- (void)stopLoading {
  if (_browser) {
    _browser->StopLoad();
  }
}

- (void)focusBrowser {
  if (!_browser || _destroyed) {
    return;
  }
  if ([self.window.firstResponder isKindOfClass:NSText.class]) {
    return;
  }
  _browser->GetHost()->SetFocus(true);
}

- (void)cef_focusPage {
  if (_browser && !_destroyed) {
    _browser->GetHost()->SetFocus(true);
  }
}

#pragma mark Settings

- (void)setAudioMuted:(BOOL)audioMuted {
  if (_audioMuted == audioMuted) {
    return;
  }
  _audioMuted = audioMuted;
  if (_browser) {
    _browser->GetHost()->SetAudioMuted(audioMuted);
  }
}

- (void)setAllowsDragAndDrop:(BOOL)allowsDragAndDrop {
  if (_allowsDragAndDrop == allowsDragAndDrop) {
    return;
  }
  _allowsDragAndDrop = allowsDragAndDrop;
  if (!_browser) {
    return;
  }

  const CefString script = ToCefString(DragDropPolicyScript(allowsDragAndDrop));
  std::vector<CefString> frameIDs;
  _browser->GetFrameIdentifiers(frameIDs);
  for (const auto &frameID : frameIDs) {
    if (CefRefPtr<CefFrame> frame = _browser->GetFrameByIdentifier(frameID)) {
      frame->ExecuteJavaScript(script, frame->GetURL(), 0);
    }
  }
}

#pragma mark CEF callbacks

- (BOOL)cef_shouldBlockPopup:(int)popupID
                 disposition:(cef_window_open_disposition_t)disposition
                 userGesture:(bool)userGesture
                  windowInfo:(CefWindowInfo &)windowInfo
                      client:(CefRefPtr<CefClient> &)client {
  if (_destroyed || (!self.allowsPopups && !userGesture)) {
    return YES;
  }
  id<ChromiumBrowserViewDelegate> delegate = self.delegate;
  if (!delegate) {
    return YES;
  }

  // The popup keeps its window.opener link, so sign-in flows (Google, Apple, etc.)
  // can report back to this page.
  ChromiumBrowserView *popup = [[ChromiumBrowserView alloc] initWithURL:@"about:blank"];
  popup->_isPopupHost = YES;
  popup.frame = self.bounds;
  popup.allowsPopups = self.allowsPopups;
  popup.allowsDragAndDrop = self.allowsDragAndDrop;
  popup.allowsTooltips = self.allowsTooltips;
  popup.audioMuted = self.audioMuted;

  const BOOL inBackground = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
  if (![delegate browserView:self adoptPopup:popup inBackground:inBackground]) {
    return YES;
  }

  const NSRect bounds = popup.bounds;
  windowInfo.SetAsChild((__bridge void *)popup,
                        CefRect(0, 0, (int)bounds.size.width, (int)bounds.size.height));
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  client = popup->_client.get();
  [_pendingPopups setObject:popup forKey:@(popupID)];
  return NO;
}

- (void)cef_popupAborted:(int)popupID {
  ChromiumBrowserView *popup = [_pendingPopups objectForKey:@(popupID)];
  [_pendingPopups removeObjectForKey:@(popupID)];
  [popup finishClose];
}

- (void)cef_didCreateBrowser:(CefRefPtr<CefBrowser>)browser {
  if (_browser && _browser->IsSame(browser)) {
    return;
  }
  _browser = browser;
  [LiveViews() addObject:self];

  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  host->SetAudioMuted(_audioMuted);
  if (_destroyed) {
    // Closed before Chromium finished creating it.
    _client->BeginAppClose(browser);
    return;
  }
  [self resizeSubviewsWithOldSize:self.bounds.size];
  [self.delegate browserViewDidUpdateState:self];
}

- (void)cef_doClose {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self finishClose];
  });
}

- (void)cef_willCloseBrowser:(CefRefPtr<CefBrowser>)browser {
  if (_browser && _browser->IsSame(browser)) {
    _browser = nullptr;
  }
  for (NSView *subview in [self.subviews copy]) {
    [subview removeFromSuperview];
  }
  _devToolsRegistration = nullptr;
  for (void (^pending)(BOOL, NSDictionary *) in _devToolsCallbacks.allValues) {
    pending(NO, nil);
  }
  [_devToolsCallbacks removeAllObjects];
  [LiveViews() removeObject:self];
}

- (void)cef_setURL:(NSString *)url {
  // A different site gets its own icon; drop the old one until it arrives.
  NSString *oldHost = [NSURL URLWithString:_currentURL].host;
  NSString *newHost = [NSURL URLWithString:url].host;
  if (oldHost != newHost && ![oldHost isEqualToString:newHost]) {
    _favicon = nil;
  }
  _currentURL = [url copy];
  [self.delegate browserViewDidUpdateState:self];
}

- (void)cef_setTitle:(NSString *)title {
  _title = [title copy];
  [self.delegate browserViewDidUpdateState:self];
}

- (void)cef_setLoading:(BOOL)isLoading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward {
  _isLoading = isLoading;
  _canGoBack = canGoBack;
  _canGoForward = canGoForward;
  [self.delegate browserViewDidUpdateState:self];
}

- (void)cef_setFullscreen:(BOOL)fullscreen {
  [self.delegate browserView:self didChangeFullscreen:fullscreen];
}

- (void)cef_setLoadingProgress:(double)progress {
  _loadingProgress = progress;
  [self.delegate browserViewDidUpdateState:self];
}

- (void)cef_setFaviconURLs:(NSArray<NSString *> *)urls {
  NSString *url = urls.firstObject;
  if (!_browser || url.length == 0) {
    _favicon = nil;
    [self.delegate browserViewDidUpdateState:self];
    return;
  }

  __weak ChromiumBrowserView *weakSelf = self;
  _browser->GetHost()->DownloadImage(
      ToCefString(url), true, 64, false, new FaviconCallback(^(NSImage *image) {
        ChromiumBrowserView *strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }
        // Keep the previous icon if this one failed, like Chrome.
        if (image) {
          strongSelf->_favicon = image;
          [strongSelf.delegate browserViewDidUpdateState:strongSelf];
        }
      }));
}

- (void)cef_frameDidStartLoading:(CefRefPtr<CefFrame>)frame {
  if (!self.allowsDragAndDrop) {
    frame->ExecuteJavaScript(ToCefString(DragDropPolicyScript(NO)), frame->GetURL(), 0);
  }
}

- (void)cef_askPermissionTo:(NSString *)action
                     origin:(NSString *)origin
                   promptID:(uint64_t)promptID
                 completion:(void (^)(BOOL allowed))completion {
  NSWindow *window = self.window;
  if (!window || _destroyed) {
    completion(NO);
    return;
  }

  NSString *site = [NSURL URLWithString:origin].host ?: origin;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:@"%@ wants to %@", site, action];
  alert.informativeText = @"Reload the page to be asked again.";
  [alert addButtonWithTitle:@"Allow"];
  [alert addButtonWithTitle:@"Block"];
  alert.window.sharingType = NSWindowSharingNone;

  NSNumber *key = @(promptID);
  if (promptID != 0) {
    _permissionAlerts[key] = alert;
  }

  __weak ChromiumBrowserView *weakSelf = self;
  [alert beginSheetModalForWindow:window
                completionHandler:^(NSModalResponse response) {
                  ChromiumBrowserView *strongSelf = weakSelf;
                  if (promptID != 0) {
                    // Chromium already dismissed this prompt (navigation, tab closed).
                    if (!strongSelf || !strongSelf->_permissionAlerts[key]) {
                      return;
                    }
                    [strongSelf->_permissionAlerts removeObjectForKey:key];
                  }
                  completion(response == NSAlertFirstButtonReturn);
                }];
}

- (void)cef_dismissPermissionPrompt:(uint64_t)promptID {
  NSNumber *key = @(promptID);
  NSAlert *alert = _permissionAlerts[key];
  if (!alert) {
    return;
  }
  [_permissionAlerts removeObjectForKey:key];
  [self.window endSheet:alert.window returnCode:NSModalResponseAbort];
}

#pragma mark External apps

- (BOOL)cef_handleExternalURL:(NSString *)urlString fromPage:(NSString *)pageURL {
  NSURL *url = [NSURL URLWithString:urlString];
  if (!url || IsBrowserHandledScheme(url.scheme)) {
    return NO;
  }

  // Ask macOS which app handles this kind of link; nothing installed means nothing to do,
  // which is what Chrome does too.
  NSURL *appURL = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:url];
  if (!appURL) {
    return YES;
  }

  NSString *scheme = url.scheme.lowercaseString;
  NSString *site = [NSURL URLWithString:pageURL].host;
  if (site.length && IsExternalProtocolAllowed(site, scheme)) {
    [NSWorkspace.sharedWorkspace openURL:url];
    return YES;
  }

  NSWindow *window = self.window;
  if (!window || _externalPromptVisible || _destroyed) {
    return YES;
  }

  NSString *appName = [NSFileManager.defaultManager displayNameAtPath:appURL.path]
                          .stringByDeletingPathExtension;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:@"Open %@?", appName];
  alert.informativeText =
      site.length ? [NSString stringWithFormat:@"%@ wants to open this application.", site]
                  : @"A website wants to open this application.";
  alert.icon = [NSWorkspace.sharedWorkspace iconForFile:appURL.path];
  [alert addButtonWithTitle:[NSString stringWithFormat:@"Open %@", appName]];
  [alert addButtonWithTitle:@"Cancel"];
  if (site.length) {
    alert.showsSuppressionButton = YES;
    alert.suppressionButton.title = [NSString
        stringWithFormat:@"Always allow %@ to open links of this type in the associated app", site];
  }
  alert.window.sharingType = NSWindowSharingNone;

  _externalPromptVisible = YES;
  __weak ChromiumBrowserView *weakSelf = self;
  [alert beginSheetModalForWindow:window
                completionHandler:^(NSModalResponse response) {
                  ChromiumBrowserView *strongSelf = weakSelf;
                  if (strongSelf) {
                    strongSelf->_externalPromptVisible = NO;
                  }
                  if (response != NSAlertFirstButtonReturn) {
                    return;
                  }
                  if (site.length && alert.suppressionButton.state == NSControlStateValueOn) {
                    AllowExternalProtocol(site, scheme);
                  }
                  [NSWorkspace.sharedWorkspace openURL:url];
                }];
  return YES;
}

#pragma mark Screenshots

- (void)sendDevToolsMethod:(NSString *)method
                    params:(NSDictionary *)params
                completion:(void (^)(BOOL success, NSDictionary *result))completion {
  if (!_browser || _destroyed) {
    completion(NO, nil);
    return;
  }

  CefRefPtr<CefBrowserHost> host = _browser->GetHost();
  if (!_devToolsRegistration) {
    _devToolsRegistration = host->AddDevToolsMessageObserver(new DevToolsObserver(self));
  }

  CefRefPtr<CefDictionaryValue> cefParams;
  if (params.count) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:params options:0 error:nil];
    NSString *jsonString = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    CefRefPtr<CefValue> value = CefParseJSON(ToCefString(jsonString), JSON_PARSER_RFC);
    if (value && value->GetType() == VTYPE_DICTIONARY) {
      cefParams = value->GetDictionary();
    }
  }

  const int messageID = ++_nextDevToolsMessageID;
  NSNumber *key = @(messageID);
  _devToolsCallbacks[key] = [completion copy];
  if (host->ExecuteDevToolsMethod(messageID, ToCefString(method), cefParams) == 0) {
    [_devToolsCallbacks removeObjectForKey:key];
    completion(NO, nil);
    return;
  }

  // Chromium only paints visible windows; don't wait forever if it can't.
  __weak ChromiumBrowserView *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    ChromiumBrowserView *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    void (^pending)(BOOL, NSDictionary *) = strongSelf->_devToolsCallbacks[key];
    if (pending) {
      [strongSelf->_devToolsCallbacks removeObjectForKey:key];
      pending(NO, nil);
    }
  });
}

- (void)cef_devToolsResult:(int)messageID success:(BOOL)success data:(NSData *)data {
  NSNumber *key = @(messageID);
  void (^completion)(BOOL, NSDictionary *) = _devToolsCallbacks[key];
  if (!completion) {
    return;
  }
  [_devToolsCallbacks removeObjectForKey:key];
  id result = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  completion(success, [result isKindOfClass:NSDictionary.class] ? result : nil);
}

- (void)cef_devToolsEvent:(NSString *)method data:(NSData *)data {
  ChromiumDevToolsEventHandler handler = self.devToolsEventHandler;
  if (!handler) {
    return;
  }
  id params = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  handler(method, [params isKindOfClass:NSDictionary.class] ? params : nil);
}

#pragma mark Dialogs, downloads and popups

- (BOOL)cef_answerDialog:(ChromiumDialogKind)kind
                 message:(NSString *)message
             defaultText:(NSString *)defaultText
                callback:(CefRefPtr<CefJSDialogCallback>)callback {
  ChromiumDialogHandler handler = self.dialogHandler;
  if (!handler || _destroyed) {
    return NO;
  }
  NSString *answer = handler(kind, message, defaultText);
  callback->Continue(answer != nil, ToCefString(answer ?: @""));
  return YES;
}

- (void)cef_download:(NSString *)fileName finished:(BOOL)finished {
  void (^handler)(NSString *, BOOL) = self.downloadHandler;
  if (handler) {
    handler(fileName, finished);
  }
}

- (void)cef_blockedPopup:(NSString *)url {
  void (^handler)(NSString *) = self.blockedPopupHandler;
  if (handler && !_destroyed) {
    handler(url);
  }
}

- (void)captureScreenshotOfArea:(ChromiumScreenshotArea)area
                     completion:(void (^)(NSData *, NSImage *, NSString *))completion {
  if (!_browser || _destroyed) {
    completion(nil, nil, @"This tab hasn't loaded a page yet.");
    return;
  }

  const CGFloat scale = self.window.backingScaleFactor ?: 2;
  void (^capture)(NSDictionary *) = ^(NSDictionary *params) {
    [self sendDevToolsMethod:@"Page.captureScreenshot"
                      params:params
                  completion:^(BOOL success, NSDictionary *result) {
                    NSString *base64 = result[@"data"];
                    NSData *png = [base64 isKindOfClass:NSString.class]
                                      ? [[NSData alloc] initWithBase64EncodedString:base64 options:0]
                                      : nil;
                    NSBitmapImageRep *rep = png ? [[NSBitmapImageRep alloc] initWithData:png] : nil;
                    if (!success || !rep) {
                      completion(nil, nil, @"Chromium couldn't capture this page. Make sure the window is visible and try again.");
                      return;
                    }
                    NSImage *image = [[NSImage alloc]
                        initWithSize:NSMakeSize(rep.pixelsWide / scale, rep.pixelsHigh / scale)];
                    [image addRepresentation:rep];
                    completion(png, image, nil);
                  }];
  };

  if (area == ChromiumScreenshotAreaVisible) {
    capture(@{@"format" : @"png", @"fromSurface" : @YES});
    return;
  }

  // Full page: measure the document first, then capture beyond the viewport.
  [self sendDevToolsMethod:@"Page.getLayoutMetrics"
                    params:@{}
                completion:^(BOOL success, NSDictionary *result) {
                  NSDictionary *size = result[@"cssContentSize"] ?: result[@"contentSize"];
                  double width = [size[@"width"] doubleValue];
                  double height = [size[@"height"] doubleValue];
                  if (!success || width <= 0 || height <= 0) {
                    completion(nil, nil, @"Chromium couldn't measure this page.");
                    return;
                  }
                  // Stay within the largest texture Chromium can produce.
                  const double maxPoints = 16384 / scale;
                  capture(@{
                    @"format" : @"png",
                    @"captureBeyondViewport" : @YES,
                    @"clip" : @{
                      @"x" : @0,
                      @"y" : @0,
                      @"width" : @(MIN(width, maxPoints)),
                      @"height" : @(MIN(height, maxPoints)),
                      @"scale" : @1,
                    },
                  });
                }];
}

@end
