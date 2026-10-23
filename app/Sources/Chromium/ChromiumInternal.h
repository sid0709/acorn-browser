// Shared between ChromiumEngine.mm and ChromiumBrowserView.mm. Objective-C++ only.
#pragma once

#import "ChromiumBridge.h"

namespace chromium {

/// Number of browsers between OnAfterCreated and OnBeforeClose.
int LiveBrowserCount();
void BrowserCreated();
void BrowserClosed();

/// Marks a stretch of the main thread's work for `ChromiumPerf`, for as long as it lives.
/// `section` must outlive the app: a string literal. `reportsSlow` NO keeps a long stretch
/// from being written on its own (the watcher still counts time spent in it).
class PerfScope {
 public:
  explicit PerfScope(const char *section, bool reportsSlow = true);
  ~PerfScope();
  PerfScope(const PerfScope &) = delete;
  PerfScope &operator=(const PerfScope &) = delete;
};

}  // namespace chromium

/// Shared between the browser view and its input category (ChromiumInput.mm).
@interface ChromiumBrowserView (Internal)
/// Gives the page keyboard focus, whatever has it now.
- (void)cef_focusPage;
/// Keeps the agent's pointer drawn above the page, after a subview joined.
- (void)cef_keepPointerOnTop;
@end
