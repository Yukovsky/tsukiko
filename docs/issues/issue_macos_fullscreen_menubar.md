# Issue: Menu Bar Popover Fails to Open in macOS Fullscreen Mode

**Type**: Bug  
**Platform**: macOS (AppKit / Swift)  
**Component**: Menu Bar Popover (`macos/Runner/TrayPanel.swift`, `macos/Runner/Dictation.swift`)  
**Status**: Investigated / Documented  

---

## 1. Description

When macOS has an application running in native fullscreen mode (e.g. Safari, Xcode, Terminal, VS Code in a fullscreen Space), moving the cursor to the top of the display causes macOS WindowServer to slide down the auto-hidden menu bar.

If the user clicks on the **Tsukiko** status bar icon:
- **Expected Behavior**: The Tsukiko popover panel slides down smoothly under the status icon and remains interactive, just like system menu items (Wi-Fi, Battery, Control Center) and third-party menu bar utilities.
- **Actual Behavior**: The popover does not open, or vanishes so quickly (within milliseconds) that it appears completely blocked and unresponsive.
- **Note**: If the user right-clicks the status icon in fullscreen mode, the context menu (`NSMenu`: *«Открыть tsukiko»*, *«Завершить tsukiko»*) opens and works properly.

---

## 2. Reproduction Steps

1. Launch **Tsukiko** on macOS.
2. Open any app (e.g. Safari or Terminal) and enter native macOS Fullscreen mode (click the green window button or press `Ctrl + Cmd + F`).
3. Move the mouse pointer to the top edge of the screen to reveal the auto-hidden menu bar.
4. Left-click on Tsukiko's status item icon.
5. **Observe**: The popover window fails to open or appear.

---

## 3. Technical Root Cause Analysis

Investigation of `macos/Runner/TrayPanel.swift` reveals three distinct, compounded bugs causing this failure:

### Cause 1: `activationObserver` Instant Dismissal (Primary Cause)

In `TrayPanel.swift` (lines 273–284), an observer for `NSWorkspace.didActivateApplicationNotification` is registered when the panel is shown:

```swift
// macos/Runner/TrayPanel.swift:273-284
activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
  forName: NSWorkspace.didActivateApplicationNotification,
  object: nil,
  queue: .main
) { [weak self] notification in
  guard let self,
    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
    app.bundleIdentifier != Bundle.main.bundleIdentifier
  else { return }
  self.hide()
}
```

1. Tsukiko is configured as an accessory application (`LSUIElement = true`).
2. The panel is created as a non-activating panel:
   ```swift
   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView]
   ```
3. When `show()` is executed, it calls:
   ```swift
   panel.makeKeyAndOrderFront(nil)
   NSApp.activate(ignoringOtherApps: true)
   installDismissMonitors()
   ```
4. In macOS native fullscreen spaces, an accessory application with a `.nonactivatingPanel` **cannot become the active application of the fullscreen Space**.
5. The fullscreen application (e.g. `com.apple.Safari`) remains active, or macOS AppKit immediately posts a `didActivateApplicationNotification` re-affirming the fullscreen app as the frontmost process.
6. The `activationObserver` catches this notification:
   `app.bundleIdentifier` (`com.apple.Safari`) != `Bundle.main.bundleIdentifier` (`ru.yukovsky.tsukiko`).
7. `activationObserver` immediately invokes `self.hide()`.
8. The panel is dismissed within 1–2 run loop turns (under 16 ms), long before the 160 ms entrance animation (`NSAnimationContext`) can render. To the user, clicking the icon did nothing.

> **Developer Note in Code**:  
> In `TrayPanel.swift` (lines 317–321), the author specifically recognized that focus fluctuates in fullscreen mode:
> ```swift
> func windowDidResignKey(_ notification: Notification) {
>   // Не гасим панель по resignKey: в полноэкранном режиме и при открытии
>   // меню системный фокус прыгает между вспомогательными окнами, из-за чего
>   // панель моментально схлопывалась. Закрытием управляют click-мониторы.
> }
> ```
> The author intentionally disabled closing on `windowDidResignKey`, but unknowingly reintroduced the exact same instant-dismissal bug via `activationObserver`.

---

### Cause 2: Observer Memory Leak in `removeDismissMonitors`

In `TrayPanel.swift`, the observer is registered with:
```swift
// Line 273
activationObserver = NSWorkspace.shared.notificationCenter.addObserver(...)
```
However, in `removeDismissMonitors()` (lines 295–298), it attempts to remove the observer from the **default** notification center:
```swift
// Line 296
if let observer = activationObserver {
  NotificationCenter.default.removeObserver(observer) // BUG: Wrong NotificationCenter!
  activationObserver = nil
}
```
- `NotificationCenter.default` and `NSWorkspace.shared.notificationCenter` are two separate instances.
- Calling `NotificationCenter.default.removeObserver(...)` does **not** remove observers registered on `NSWorkspace.shared.notificationCenter`.
- As a result, every single time `show()` is called during an application session, a new closure is leaked in `NSWorkspace.shared.notificationCenter`. Because `PanelController` is retained by `Dictation.swift`, all previously leaked closures remain permanently active. Any subsequent app activation fires all leaked observers, instantly triggering `self.hide()`.

---

### Cause 3: Auto-Hide Menu Bar Retraction vs Custom `NSPanel`

1. When an application uses a standard `NSMenu` (such as Tsukiko's right-click menu):
   AppKit enters a modal event tracking run loop (`NSEventTrackingRunLoopMode`). The macOS WindowServer detects that an active status menu is tracking and **pins the auto-hidden menu bar in place** until the menu is dismissed.
2. Tsukiko uses a custom `NSPanel` (`TrayPanel`) for left-clicks. Because `TrayPanel` is not an `NSMenu` or `NSPopover`:
   As soon as the user releases the mouse button (`leftMouseUp`), WindowServer considers the status item interaction complete.
3. Unless prevented, WindowServer initiates the auto-hide slide-up animation for the menu bar.
4. As the menu bar slides up:
   - `button.window` moves out of the screen.
   - Any subsequent mouse click outside the panel is caught by `outsideClickMonitor`.
   - `outsideClickMonitor` checks `self.isClickOnStatusItem()`:
     ```swift
     private func isClickOnStatusItem() -> Bool {
       guard let button = statusItem?.button, let window = button.window else { return false }
       return window.frame.contains(NSEvent.mouseLocation)
     }
     ```
   - Because `window.frame` has moved with the retracting menu bar, `isClickOnStatusItem()` returns `false`, causing the monitor to immediately trigger `self.hide()`.

---

## 4. Proposed Solution

### Step 1: Fix Observer Cleanup
Remove from `NSWorkspace.shared.notificationCenter`:
```swift
if let observer = activationObserver {
  NSWorkspace.shared.notificationCenter.removeObserver(observer)
  activationObserver = nil
}
```

### Step 2: Guard `activationObserver` Against Fullscreen App Re-Activation
Instead of unconditionally hiding when any other app activates:
1. When opening the panel in a fullscreen space (or when `NSScreen.main?.visibleFrame == NSScreen.main?.frame`), do not dismiss on `didActivateApplicationNotification` if the activated application was already the frontmost application prior to clicking Tsukiko.
2. Rely strictly on `outsideClickMonitor` and `localClickMonitor` to close the panel when the user clicks away, honoring the author's stated design in line 318.
3. Alternatively, listen to `NSWorkspace.activeSpaceDidChangeNotification` instead of `didActivateApplicationNotification` to only dismiss when the user actually switches macOS Spaces.

### Step 3: Handle Status Item Coordinates in Fullscreen
In `isClickOnStatusItem()`, when in fullscreen mode:
Check if the click coordinate is within the top screen status item area regardless of whether the status window frame is currently animating, or cache the button's screen frame when opened.

### Step 4 (Architectural Alternative): Wrap in `NSPopover`
If deeper native integration is preferred:
Wrap the Flutter view controller in an `NSPopover` attached to `statusItem.button`. macOS AppKit automatically handles menu bar pinning, outside click monitoring, and Space transitions for `NSPopover` natively in fullscreen mode.

---

## 5. Verification Checklist

- [ ] Open Safari in native macOS Fullscreen mode.
- [ ] Move cursor to top, left-click Tsukiko icon in menu bar.
- [ ] Verify popover opens smoothly and remains visible while typing/clicking inside it.
- [ ] Click outside the popover onto the fullscreen app: verify popover closes smoothly.
- [ ] Open popover in regular desktop mode, verify it still works as expected.
- [ ] Verify no observer leak by repeatedly opening and closing the popover and checking memory/notification counts.
