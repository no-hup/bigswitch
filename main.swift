import Cocoa
import Carbon

func trace(_ m: String) {
    let line = "\(Date()) \(m)\n"
    let path = "/tmp/bigswitch-trace.log"
    if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); fh.closeFile() }
    else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}

// ── WindowServer (CoreGraphics private). No TCC permission is involved in any of these. ──
typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID
// Both return nullable — a display hot-unplug or a WindowServer hiccup can hand back NULL, and a
// non-optional declaration would turn that into a crash on the next cast.
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?
@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
func CGSCopyWindowsWithOptionsAndTags(_ cid: CGSConnectionID, _ owner: Int, _ spaces: CFArray, _ options: Int,
                                      _ setTags: UnsafeMutablePointer<Int>, _ clearTags: UnsafeMutablePointer<Int>) -> CFArray?
@_silgen_name("CGSCopyWindowProperty") @discardableResult
func CGSCopyWindowProperty(_ cid: CGSConnectionID, _ wid: CGWindowID, _ property: CFString,
                           _ value: UnsafeMutablePointer<CFTypeRef?>) -> CGError
@_silgen_name("CGSGetWindowLevel") @discardableResult
func CGSGetWindowLevel(_ cid: CGSConnectionID, _ wid: CGWindowID, _ level: UnsafeMutablePointer<CGWindowLevel>) -> CGError
@_silgen_name("_SLPSSetFrontProcessWithOptions") @discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: UInt32) -> CGError
@_silgen_name("SLPSPostEventRecordTo") @discardableResult
func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError
@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID_(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ e: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError
@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?
@_silgen_name("CGSManagedDisplayGetCurrentSpace")
func CGSManagedDisplayGetCurrentSpace(_ cid: CGSConnectionID, _ display: CFString) -> CGSSpaceID
@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID, _ display: CFString, _ space: CGSSpaceID)
@_silgen_name("CGSShowSpaces") func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: CFArray)
@_silgen_name("CGSHideSpaces") func CGSHideSpaces(_ cid: CGSConnectionID, _ spaces: CFArray)

let CGS = CGSMainConnectionID()

/// Flags for CGSCopyWindowsWithOptionsAndTags. 2 = windows currently mapped on a Space (includes other
/// Spaces and fullscreen ones, excludes minimized); 7 = those plus minimized/unmapped.
private let optionMapped = 2, optionAll = 7

private func spaceIds() -> CFArray {
    displaySpaces().flatMap { $0.spaces } as CFArray
}

private func windowIds(_ options: Int) -> [CGWindowID] {
    var setTags = 0, clearTags = 0
    return (CGSCopyWindowsWithOptionsAndTags(CGS, 0, spaceIds(), options, &setTags, &clearTags) as? [CGWindowID]) ?? []
}

/// (display uuid, the Spaces on it) for every display. Every shape assumption about these private
/// dictionaries is a soft one: a missing key yields an empty result, never a trap.
func displaySpaces() -> [(uuid: CFString, spaces: [CGSSpaceID])] {
    ((CGSCopyManagedDisplaySpaces(CGS) as? [NSDictionary]) ?? []).compactMap { d in
        guard let uuid = d["Display Identifier"] as? String else { return nil }
        let spaces = (d["Spaces"] as? [NSDictionary] ?? []).compactMap { $0["id64"] as? CGSSpaceID }
        return (uuid as CFString, spaces)
    }
}

func currentSpace() -> CGSSpaceID {
    guard let first = displaySpaces().first else { return 0 }
    return CGSManagedDisplayGetCurrentSpace(CGS, first.uuid)
}

/// Which Space each window sits on. Minimized windows belong to none, so they simply do not appear.
func spaceByWindow() -> [CGWindowID: CGSSpaceID] {
    var map = [CGWindowID: CGSSpaceID]()
    for display in displaySpaces() {
        for sid in display.spaces {
            for w in windowsIn(space: sid) where map[w] == nil { map[w] = sid }
        }
    }
    return map
}

func spaceOf(_ wid: CGWindowID) -> CGSSpaceID { spaceByWindow()[wid] ?? 0 }

/// Window ids mapped on one specific Space. Needed to ask "is this window on the Space I am on",
/// which `spaceOf` cannot answer for a window that joins every Space.
func windowsIn(space: CGSSpaceID) -> [CGWindowID] {
    var setTags = 0, clearTags = 0
    return (CGSCopyWindowsWithOptionsAndTags(CGS, 0, [space] as CFArray, optionMapped, &setTags, &clearTags) as? [CGWindowID]) ?? []
}

/// Does `wid` still exist and still belong to `pid`? The list the user picked from can be minutes old:
/// the app may have quit, and macOS recycles window ids, so a stale id can name a live window of some
/// other process. Acting on either would switch Space for nothing.
func windowStillOwned(_ wid: CGWindowID, by pid: pid_t) -> Bool {
    let info = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    return info.contains {
        ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == wid &&
        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
    }
}

/// Move the display to `space`.
///
/// Activating an app is the usual way to reach another Space, but it does nothing when the target window
/// belongs to the app that is ALREADY frontmost — switching between two fullscreen VS Code windows, which
/// is the main case here. So ask the WindowServer directly instead of hoping activation drags us along.
func switchTo(space: CGSSpaceID) {
    guard let display = displaySpaces().first(where: { $0.spaces.contains(space) }) else { return }
    let from = CGSManagedDisplayGetCurrentSpace(CGS, display.uuid)
    guard from != space else { return }
    CGSShowSpaces(CGS, [space] as CFArray)
    CGSHideSpaces(CGS, [from] as CFArray)
    CGSManagedDisplaySetCurrentSpace(CGS, display.uuid, space)
}

private func title(_ wid: CGWindowID) -> String {
    var value: CFTypeRef?
    CGSCopyWindowProperty(CGS, wid, "kCGSWindowTitle" as CFString, &value)
    return (value as? String) ?? ""
}

private func level(_ wid: CGWindowID) -> CGWindowLevel {
    var l = CGWindowLevel(0)
    CGSGetWindowLevel(CGS, wid, &l)
    return l
}

// ── Model ──
struct Win {
    let wid: CGWindowID
    let app: NSRunningApplication
    let title: String
    let minimized: Bool
    let space: CGSSpaceID   // 0 when minimized (a minimized window is on no Space)
}

func listWindows() -> [Win] {
    let byPid = Dictionary(
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { ($0.processIdentifier, $0) },
        uniquingKeysWith: { a, _ in a })

    let info = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    let ownerByWid = Dictionary(info.compactMap { d -> (CGWindowID, pid_t)? in
        guard let w = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let p = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
        return (w, p)
    }, uniquingKeysWith: { a, _ in a })

    let spaces = spaceByWindow()
    let mapped = Set(spaces.keys)
    let me = ProcessInfo.processInfo.processIdentifier
    var seen = Set<CGWindowID>()

    let all = windowIds(optionAll).compactMap { wid -> Win? in
        guard !seen.contains(wid), level(wid) == 0,                  // level 0 = ordinary app window
              let pid = ownerByWid[wid], pid != me,
              let app = byPid[pid] else { return nil }
        let name = title(wid)
        guard !name.isEmpty else { return nil }                       // untitled = Electron ghost window
        seen.insert(wid)
        return Win(wid: wid, app: app, title: name, minimized: !mapped.contains(wid), space: spaces[wid] ?? 0)
    }
    // VS Code first, then everything else, minimized last; z-order (most recent) kept inside each group
    func rank(_ w: Win) -> Int {
        let id = w.app.bundleIdentifier ?? ""
        return priorityApps.contains(where: id.contains) ? 0 : 1
    }
    return all.enumerated()
        .sorted { a, b in
            let ka = (a.element.minimized ? 1 : 0, rank(a.element), a.offset)
            let kb = (b.element.minimized ? 1 : 0, rank(b.element), b.offset)
            return ka < kb
        }
        .map { $0.element }
}

/// Byte layout reverse-engineered from CGSEvent.h (via yabai/Hammerspoon/AltTab). Makes `wid` the key
/// window of its app: a synthetic mouse-down delivered to the window BY ID, aimed far off-content so no
/// control can be hit, and with no matching mouse-up so it can never complete as a click.
private func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID) {
    var wid = wid
    var point = CGPoint(x: 300_000, y: 300_000)
    var bytes = [UInt8](repeating: 0, count: 0x100)
    bytes[0x04] = 0xf8                                                 // record length
    bytes[0x3a] = 0x10                                                 // undocumented flag
    bytes[0x08] = 0x01                                                 // kCGEventLeftMouseDown
    memcpy(&bytes[0x3c], &wid, MemoryLayout<CGWindowID>.size)
    memcpy(&bytes[0x20], &point, MemoryLayout<CGPoint>.size)
    SLPSPostEventRecordTo(&psn, &bytes)
}

/// An Accessibility handle for a window.
///
/// `kAXWindows` only lists windows on the CURRENT Space, so every fullscreen window is missing from it —
/// measured here: VS Code reported 5 of its 9 windows. For those, forge an element from a "remote token"
/// (pid + magic + element id) and walk element ids until one reports the window id we want. Undocumented,
/// but it is the only bridge from a window id we can see to a handle we can raise. Bounded by a time
/// budget because the id space is huge and sparse; in practice the match is found within a few dozen ids.
func axWindow(pid: pid_t, wid: CGWindowID, budgetMs: Double = 500) -> AXUIElement? {
    let axApp = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
       let windows = value as? [AXUIElement] {
        for w in windows {
            var got = CGWindowID(0)
            if _AXUIElementGetWindow(w, &got) == .success, got == wid { return w }
        }
    }
    var token = Data(count: 20)
    token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
    token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
    let start = Date()
    var id: UInt64 = 0
    while Date().timeIntervalSince(start) * 1000 < budgetMs {
        token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
        if let cand = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() {
            var got = CGWindowID(0)
            if _AXUIElementGetWindow(cand, &got) == .success, got == wid {
                // _AXUIElementGetWindow on ANY descendant reports its containing window, so a toolbar or
                // tab bar also matches the id — insist on the window element itself.
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(cand, kAXRoleAttribute as CFString, &role)
                if (role as? String) == kAXWindowRole as String { return cand }
            }
        }
        id += 1
    }
    return nil
}

/// Bring a window forward, switching Space if it lives on another one.
///
/// Measured on this machine: the WindowServer calls alone never switch Space, even from the active app —
/// `AXRaise` is what actually does it. The WindowServer calls still earn their place for moving key focus
/// between apps, which no public API does since macOS 14.
func focus(_ win: Win) {
    let pid = win.app.processIdentifier
    let wid = win.wid
    let app = win.app
    let wasMinimized = win.minimized
    let space = win.space
    DispatchQueue.global(qos: .userInitiated).async {
        // nothing below may run for a window that is gone — every step would otherwise fire anyway
        guard !app.isTerminated, windowStillOwned(wid, by: pid) else { return }
        let element = axWindow(pid: pid, wid: wid)
        if wasMinimized, let element {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if space != 0 { switchTo(space: space) }
        if let element { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
        app.activate()
        var psn = ProcessSerialNumber()
        guard GetProcessForPID_(pid, &psn) == noErr else { return }   // else psn is kNoProcess
        _SLPSSetFrontProcessWithOptions(&psn, wid, 0x200)
        makeKeyWindow(&psn, wid)
    }
}

/// Split a window title into (headline, detail). Editors append the project after an em/en dash
/// ("Some file — my-project"); the part AFTER the dash is what you navigate by, so it leads.
func split(_ w: Win) -> (headline: String, detail: String) {
    for sep in [" — ", " – "] {
        if let r = w.title.range(of: sep, options: .backwards) {
            let head = w.title[r.upperBound...].trimmingCharacters(in: .whitespaces)
            let tail = w.title[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return (head, tail) }
        }
    }
    return (w.title, w.app.localizedName ?? "")
}

// ── UI ──

/// Borderless panels refuse key focus unless we say otherwise.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Soft rounded selection instead of the full-width system bar; keeps label contrast intact.
final class RowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 9, yRadius: 9).fill()
    }
}
final class Table: NSTableView {
    var onPick: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 36, 76: onPick?(selectedRow)
        case 53: onCancel?()
        case 48:                                                                    // Tab cycles
            guard numberOfRows > 0 else { return }   // selecting row 0 of an empty table raises
            selectRow(selectedRow + 1 < numberOfRows ? selectedRow + 1 : 0)
        default:
            if let c = e.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) { onPick?(n - 1) }
            else { super.keyDown(with: e) }
        }
    }
    private func selectRow(_ i: Int) {
        selectRowIndexes([i], byExtendingSelection: false)
        scrollRowToVisible(i)
    }
}

/// Windows from these apps are listed first (matched against bundle id, case-sensitive substring).
/// Empty the array to keep plain most-recently-used order.
let priorityApps = ["VSCode", "Cursor"]

let rowHeight: CGFloat = 54
let panelWidth: CGFloat = 720

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var panel: NSPanel!
    var table: Table!
    var wins: [Win] = []
    /// True when Screen Recording is missing: every title reads back empty, so the list would silently be
    /// blank. Show a row that says so instead of leaving the user staring at nothing.
    var needsPermission = false
    /// When the panel last opened; used to ignore the focus wobble right after it appears.
    var shownAt = Date.distantPast
    var permissionPoll: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Window titles on OTHER Spaces are readable only with Screen Recording. Reading a title string is
        // the ONLY use of it — no capture API is called anywhere in this program. Asking is also what puts
        // the app into the Settings list in the first place.
        // Two permissions, each verified necessary by test:
        //   Screen Recording — the ONLY way to read titles of windows on other Spaces (no capture is done).
        //   Accessibility    — the ONLY way to RAISE such a window; WindowServer calls cannot switch Space.
        // Deliberately NOT requested here: prompting at launch means a dialog on every single start while
        // a permission is missing. The panel says what is missing and asks only when the user clicks it.
        trace("launch: screenRecording=\(CGPreflightScreenCaptureAccess()) accessibility=\(AXIsProcessTrusted())")

        table = Table()
        table.dataSource = self
        table.delegate = self
        table.rowHeight = rowHeight
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.target = self
        table.action = #selector(rowClicked)                            // single click picks
        table.onPick = { [weak self] in self?.pick($0) }
        table.onCancel = { [weak self] in self?.hide() }
        table.addTableColumn(NSTableColumn(identifier: .init("w")))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        blur.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: blur.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
        ])

        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 500),
                      styleMask: [.nonactivatingPanel, .borderless],
                      backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // LEVEL MATTERS MORE THAN IT LOOKS. A fullscreen app puts a window at level 26 (measured: VS
        // Code fullscreen, z-order index 0). At .modalPanel (8) this panel was correctly ON the Space
        // but stacked UNDERNEATH that window, so it was invisible on every fullscreen Space and only
        // showed up on the desktop. .popUpMenu (101) clears it — the level AltTab uses, high enough to
        // also sit above context menus.
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = .canJoinAllSpaces
        panel.contentView = blur
        panel.delegate = self

        registerHotkey()
    }

    func registerHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { (NSApp.delegate as! AppDelegate).toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_Tab), UInt32(optionKey),
                            EventHotKeyID(signature: OSType(0x42535731), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
        trace("RegisterEventHotKey status=\(status) ref=\(ref != nil)")
    }

    func toggle() {
        // visible but not key = something stole focus inside the resign-key grace period; the panel is
        // stranded on screen and Esc cannot reach it. Treat the hotkey as "show" so it re-takes key.
        guard panel.isVisible, panel.isKeyWindow else { return show() }
        advance()   // repeat presses walk the list, like Command-Tab; Esc or clicking away closes
    }

    func advance() {
        guard !wins.isEmpty else { return }
        let next = (table.selectedRow + 1) % wins.count
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    func show() {
        needsPermission = !CGPreflightScreenCaptureAccess() || !AXIsProcessTrusted()
        wins = needsPermission ? [] : listWindows()
        table.reloadData()
        if !wins.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let wanted = CGFloat(max(wins.count, 1)) * rowHeight + 20
            let height = min(max(wanted, 120), visible.height * 0.8)
            panel.setFrame(NSRect(x: visible.midX - panelWidth / 2,
                                  y: visible.midY - height / 2,
                                  width: panelWidth, height: height), display: true)
        }
        // Do NOT activate the app: activating an accessory app pulls the display to the app's own Space,
        // which is the "it jumps to the desktop" bug. A non-activating panel takes key focus on its own,
        // and raising the target works from an inactive process (verified with AXRaise).
        shownAt = Date()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(table)
    }

    func hide() { panel.orderOut(nil) }

    @objc func rowClicked() {
        guard table.clickedRow >= 0 else { return }   // click below the last row: do nothing, don't close
        pick(table.clickedRow)
    }

    func pick(_ row: Int) {
        if needsPermission {
            hide()
            let pane = !CGPreflightScreenCaptureAccess() ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            if !AXIsProcessTrusted() {
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
            relaunchWhenGranted()
            return
        }
        guard row >= 0, row < wins.count else { return }
        hide()
        focus(wins[row])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { needsPermission ? 1 : wins.count }

    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableView(_ tv: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        if needsPermission { return permissionCell() }
        let w = wins[row]
        let (headline, detail) = split(w)
        let dim = w.minimized
        let cell = NSTableCellView()

        let key = NSTextField(labelWithString: row < 9 ? "\(row + 1)" : "")
        key.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        key.textColor = .tertiaryLabelColor
        key.alignment = .center

        let icon = NSImageView(image: w.app.icon ?? NSImage())
        icon.alphaValue = dim ? 0.45 : 1

        let title = NSTextField(labelWithString: headline)
        title.font = .systemFont(ofSize: 18, weight: .medium)
        title.textColor = dim ? .secondaryLabelColor : .labelColor
        title.lineBreakMode = .byTruncatingTail

        let subtitleText = [w.app.localizedName, detail.isEmpty ? nil : detail]
            .compactMap { $0 }.joined(separator: "  ·  ")
        let subtitle = NSTextField(labelWithString: dim ? subtitleText + "  ·  minimized" : subtitleText)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1

        for v in [key, icon, stack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            key.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
            key.widthAnchor.constraint(equalToConstant: 16),
            key.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: key.trailingAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 13),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func permissionCell() -> NSView {
        let cell = NSTableCellView()
        let missing = [!CGPreflightScreenCaptureAccess() ? "Screen Recording" : nil,
                       !AXIsProcessTrusted() ? "Accessibility" : nil].compactMap { $0 }.joined(separator: " + ")
        let title = NSTextField(labelWithString: "\(missing) permission needed")
        title.font = .systemFont(ofSize: 17, weight: .medium)
        let sub = NSTextField(labelWithString: "Screen Recording reads window titles; Accessibility switches to them. Click to open Settings — once both are granted, BigSwitch relaunches itself.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [title, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Screen Recording only takes effect for a process started AFTER it was granted. Without this, a
    /// user who grants it in Settings comes back to the same "permission needed" row for as long as the
    /// app stays running — which, for a login item, is until the next reboot. Watch for both grants and
    /// relaunch. Gives up after ten minutes so an abandoned Settings pane does not leave a timer forever.
    func relaunchWhenGranted() {
        permissionPoll?.invalidate()
        let deadline = Date().addingTimeInterval(600)
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            if Date() > deadline { t.invalidate(); return }
            guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else { return }
            t.invalidate()
            self?.relaunch()
        }
    }

    func relaunch() {
        guard Bundle.main.bundleIdentifier != nil else { return }   // bare binary (tests): nothing to relaunch
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, error in
            if error == nil { DispatchQueue.main.async { exit(0) } }
        }
    }

    func windowDidResignKey(_ n: Notification) {
        // a resign within a few hundred ms of opening is the window server settling, not the user
        // clicking away — closing on it made the panel flash open and shut on the first press
        guard Date().timeIntervalSince(shownAt) > 0.5 else { return }
        hide()
    }
}

/// Drives the real UI end-to-end: opens the panel, picks a window, and reports whether the window
/// actually came forward. Run from a terminal that already holds the permissions.
func runSelfTest(_ d: AppDelegate) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        let spaceBeforeShow = currentSpace()
        d.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let spaceAfterShow = currentSpace()
            let stayed = spaceAfterShow == spaceBeforeShow
            print("SELFTEST: listed \(d.wins.count) windows")
            print("SELFTEST: [opening] Space \(spaceBeforeShow) → \(spaceAfterShow)  \(stayed ? "PASS — stayed put" : "FAIL — jumped Space")")
            print("SELFTEST: [focus]   panel.isKeyWindow=\(d.panel.isKeyWindow) firstResponder=\(d.panel.firstResponder is NSTableView) appActive=\(NSApp.isActive)")

            // repeat hotkey must move the selection, not close the panel
            let sel0 = d.table.selectedRow
            d.toggle()
            let sel1 = d.table.selectedRow
            let advanced = d.panel.isVisible && sel1 == sel0 + 1
            print("SELFTEST: [repeat]  row \(sel0) → \(sel1), still open=\(d.panel.isVisible)  \(advanced ? "PASS — advances" : "FAIL")")

            guard let idx = d.wins.firstIndex(where: { $0.app.localizedName == "Code" && !$0.minimized && spaceOf($0.wid) != spaceAfterShow })
            else { print("SELFTEST: no off-Space VS Code window to switch to"); exit(stayed && advanced ? 0 : 1) }
            let target = d.wins[idx]
            print("SELFTEST: [switch]  picking '\(target.title)' on Space \(spaceOf(target.wid))")
            d.pick(idx)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let after = currentSpace()
                let switched = after == spaceOf(target.wid)
                print("SELFTEST: [switch]  Space \(spaceAfterShow) → \(after)  \(switched ? "PASS — switched" : "FAIL")")
                let ok = stayed && advanced && switched
                print(ok ? "SELFTEST: ALL PASS" : "SELFTEST: FAILURES ABOVE")
                exit(ok ? 0 : 1)
            }
        }
    }
}

/// Regression test for "the panel opens on the desktop, not over my fullscreen window".
///
/// The panel was never on the wrong Space — Space membership passed even while the bug was live, which
/// is what made this hard to see. It was STACKING: a fullscreen app keeps a window at level 26, and the
/// panel sat at level 8, so it was present and buried. So assert on the front-to-back order of what is
/// actually on screen, never on Space membership.
///
/// Run this on an idle machine: it drives real Spaces and real keypresses, and anything you do
/// meanwhile (closing the panel, switching Space) will corrupt the result.
func runFullscreenTest(_ d: AppDelegate) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        let home = currentSpace()
        guard let fs = listWindows().first(where: { !$0.minimized && $0.space != home })?.space
        else { print("FSTEST: no other Space to test with"); exit(1) }
        switchTo(space: fs)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let landed = currentSpace()
            guard landed == fs else {
                print("FSTEST: INCONCLUSIVE — asked for \(fs), landed on \(landed)")
                switchTo(space: home); exit(2)
            }
            d.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                // kCGWindowListOptionOnScreenOnly returns windows front to back
                let onscreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
                let owners = onscreen.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }
                let me = ProcessInfo.processInfo.processIdentifier
                let panelIndex = owners.firstIndex(of: me)
                let otherIndex = owners.firstIndex(where: { $0 != me })
                print("FSTEST: Space \(landed), panel level \(d.panel.level.rawValue)")
                let ok = panelIndex != nil && (otherIndex == nil || panelIndex! < otherIndex!)
                print(ok ? "FSTEST: PASS — panel draws in front on a fullscreen Space"
                         : "FSTEST: FAIL — panel is behind (index \(String(describing: panelIndex)) vs \(String(describing: otherIndex)))")
                d.hide()
                switchTo(space: home)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exit(ok ? 0 : 1) }
            }
        }
    }
}

// One cap on every Accessibility message this process sends, forged elements included. Set on the
// system-wide element it becomes the process default; without it each probe against a beach-balling
// app waits the stock ~6 s, and the sweep's time budget — checked only between probes — means nothing.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)

if CommandLine.arguments.contains("dump") {
    for w in listWindows() {
        let p = split(w)
        print(String(format: "%-26@ | %@ %@", p.headline as NSString, p.detail, w.minimized ? "(min)" : ""))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
if CommandLine.arguments.contains("selftest") { runSelfTest(delegate) }
if CommandLine.arguments.contains("fstest") { runFullscreenTest(delegate) }
app.run()

