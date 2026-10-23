// Shared between ChromiumEngine.mm and ChromiumBrowserView.mm. Objective-C++ only.
#pragma once

#import "ChromiumBridge.h"

namespace chromium {

/// Number of browsers between OnAfterCreated and OnBeforeClose.
int LiveBrowserCount();
void BrowserCreated();
void BrowserClosed();

}  // namespace chromium
