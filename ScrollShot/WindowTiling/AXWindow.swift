import AppKit
import ApplicationServices

/// Accessibility helpers to move/resize the focused window of the frontmost app.
///
/// Approach adapted from Rectangle (github.com/rxhanson/Rectangle, MIT).
/// The load-bearing part is `setFrame`: the AX API only lets you set position
/// and size separately, and macOS clamps a size-set to the *current* display, so
/// we do size → position → size, and momentarily disable `AXEnhancedUserInterface`
/// (which some Electron/accessibility-aware apps use and which otherwise fights
/// position changes).
///
/// Coordinate note: AX window position is in **top-left-origin** screen
/// coordinates, while AppKit (`NSScreen.visibleFrame`) is **bottom-left**. We do
/// all geometry in AppKit space and flip exactly once when reading/writing AX
/// (see `CGRect.axFlipped`).

// MARK: - AXValue box/unbox

private extension AXValue {
    func unwrap<T>() -> T? {
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        let ok = AXValueGetValue(self, AXValueGetType(self), ptr)
        return ok ? ptr.pointee : nil
    }

    static func wrap<T>(_ value: T, _ type: AXValueType) -> AXValue? {
        var v = value
        return withUnsafePointer(to: &v) { AXValueCreate(type, $0) }
    }
}

// MARK: - AXUIElement attribute access

private extension AXUIElement {
    func rawValue(_ attribute: NSAccessibility.Attribute) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(self, attribute.rawValue as CFString, &value) == .success
            ? value : nil
    }

    func wrappedValue<T>(_ attribute: NSAccessibility.Attribute) -> T? {
        guard let value = rawValue(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue).unwrap()
    }

    func setWrapped<T>(_ attribute: NSAccessibility.Attribute, _ value: T, _ type: AXValueType) {
        guard let boxed = AXValue.wrap(value, type) else { return }
        AXUIElementSetAttributeValue(self, attribute.rawValue as CFString, boxed)
    }

    func setBool(_ attribute: NSAccessibility.Attribute, _ value: Bool) {
        AXUIElementSetAttributeValue(self, attribute.rawValue as CFString, value as CFTypeRef)
    }

    func isSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(self, attribute.rawValue as CFString, &settable) == .success
            && settable.boolValue
    }

    func elementValue(_ attribute: NSAccessibility.Attribute) -> AXUIElement? {
        guard let value = rawValue(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

private extension NSAccessibility.Attribute {
    static let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
}

/// One accessibility element wrapping a window (or an application) element.
struct AXWindow {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }
    init(pid: pid_t) { self.init(AXUIElementCreateApplication(pid)) }

    // MARK: Geometry

    var position: CGPoint? {
        get { element.wrappedValue(.position) }
        nonmutating set { if let v = newValue { element.setWrapped(.position, v, .cgPoint) } }
    }

    var size: CGSize? {
        get { element.wrappedValue(.size) }
        nonmutating set { if let v = newValue { element.setWrapped(.size, v, .cgSize) } }
    }

    /// The window frame in AX (top-left-origin) coordinates.
    var frame: CGRect {
        guard let position, let size else { return .null }
        return CGRect(origin: position, size: size)
    }

    var isResizable: Bool { element.isSettable(.size) }

    private var pid: pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(element, &p) == .success ? p : nil
    }

    private var appElement: AXWindow? { pid.map { AXWindow(pid: $0) } }

    private var enhancedUserInterface: Bool? {
        element.rawValue(.enhancedUI) as? Bool
    }

    /// Moves/resizes the window to `frame` (AX top-left coordinates).
    func setFrame(_ frame: CGRect, adjustSizeFirst: Bool = true) {
        let app = appElement
        let wasEnhanced = app?.enhancedUserInterface
        if wasEnhanced == true { app?.element.setBool(.enhancedUI, false) }

        if adjustSizeFirst { size = frame.size }
        position = frame.origin
        size = frame.size

        if wasEnhanced == true { app?.element.setBool(.enhancedUI, true) }
    }

    // MARK: Frontmost window discovery

    /// The focused window of the frontmost application, or nil.
    static func frontmost() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXWindow(pid: app.processIdentifier)
        if let focused = appEl.element.elementValue(.focusedWindow) {
            return AXWindow(focused)
        }
        // Fallback: the app's first window.
        if let windows = appEl.element.rawValue(.windows) as? [AXUIElement], let first = windows.first {
            return AXWindow(first)
        }
        return nil
    }
}
