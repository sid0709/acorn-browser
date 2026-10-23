// Shared between ChromiumEngine.mm and ChromiumBrowserView.mm. Objective-C++ only.
#pragma once

#import "ChromiumBridge.h"

namespace chromium {

/// Number of browsers between OnAfterCreated and OnBeforeClose.
int LiveBrowserCount();
void BrowserCreated();
void BrowserClosed();

}  // namespace chromium

/// Shared between the browser view and its input category (ChromiumInput.mm).
@interface ChromiumBrowserView (Internal)
/// Gives the page keyboard focus, whatever has it now.
- (void)cef_focusPage;
@end
