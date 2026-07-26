import AppKit
import ApplicationServices
import Carbon

struct SavedPosition {
    let x: CGFloat
    let y: CGFloat
    let displayId: CGDirectDisplayID
    let savedAt: String
}

struct AppSettings {
    var autoMode = true
    var manualMode = true
    var intervalSeconds = 1.0
    var notifyOnSave = false
    var notifyOnRestore = false
    var saveKeyCode: UInt32 = UInt32(kVK_ANSI_K)
    var restoreKeyCode: UInt32 = UInt32(kVK_ANSI_J)
    var saveKeyLabel = "Command + Shift + K"
    var restoreKeyLabel = "Command + Shift + J"
}

@MainActor
final class MouseTracApp: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var settings = AppSettings()
    var savedPosition: SavedPosition?
    var lastPosition: CGPoint?
    var wasStill = false
    var timer: Timer?
    var permissionTimer: Timer?
    var saveHotKeyRef: EventHotKeyRef?
    var restoreHotKeyRef: EventHotKeyRef?
    var eventHandlerRef: EventHandlerRef?

    let permissionBadge = StatusBadge(text: "Checking")
    let positionLabel = NSTextField(labelWithString: "No position saved yet")
    let positionTimeLabel = NSTextField(labelWithString: "")
    let autoCheckbox = NSButton(checkboxWithTitle: "Auto-save when still", target: nil, action: nil)
    let manualCheckbox = NSButton(checkboxWithTitle: "Manual save hotkey", target: nil, action: nil)
    let intervalSlider = NSSlider(value: 1.0, minValue: 0.5, maxValue: 10.0, target: nil, action: nil)
    let intervalBox = NSTextField(string: "1.0")
    let saveHotkeyButton = NSButton(title: "Command + Shift + K", target: nil, action: nil)
    let restoreHotkeyButton = NSButton(title: "Command + Shift + J", target: nil, action: nil)
    let saveNotifyCheckbox = NSButton(checkboxWithTitle: "Notify when saved", target: nil, action: nil)
    let restoreNotifyCheckbox = NSButton(checkboxWithTitle: "Notify when restored", target: nil, action: nil)
    let hotkeyStatusLabel = NSTextField(labelWithString: "")

    var capturingHotkey: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        createWindow()
        installHotkeyHandler()
        registerHotkeys()
        startTimer()
        startPermissionRefreshTimer()
        refreshUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterHotkeys()
        timer?.invalidate()
        permissionTimer?.invalidate()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func createWindow() {
        window = HotkeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "MouseTrac"
        window.center()
        window.minSize = NSSize(width: 680, height: 520)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = content

        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let title = makeLabel("MouseTrac", size: 34, weight: .bold)
        let subtitle = makeLabel("Save your cursor spot and snap back after a recording mistake.", size: 14, color: .secondaryLabelColor)

        permissionBadge.setContentHuggingPriority(.required, for: .horizontal)
        permissionBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleStack = verticalStack([title, subtitle, permissionBadge], spacing: 6)
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        let header = NSStackView(views: [titleStack])
        header.orientation = .horizontal
        header.alignment = .leading
        header.distribution = .fill
        header.spacing = 20

        positionLabel.font = .systemFont(ofSize: 22, weight: .bold)
        positionTimeLabel.font = .systemFont(ofSize: 14)
        positionTimeLabel.textColor = .secondaryLabelColor

        let saveNowButton = NSButton(title: "Save Now", target: self, action: #selector(saveNowClicked))
        let restoreNowButton = NSButton(title: "Restore Now", target: self, action: #selector(restoreNowClicked))
        restoreNowButton.bezelColor = .controlAccentColor

        autoCheckbox.target = self
        autoCheckbox.action = #selector(settingChanged)
        manualCheckbox.target = self
        manualCheckbox.action = #selector(settingChanged)

        intervalSlider.target = self
        intervalSlider.action = #selector(intervalSliderChanged)
        intervalSlider.isContinuous = true
        intervalSlider.numberOfTickMarks = 20
        intervalSlider.allowsTickMarkValuesOnly = false
        intervalSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        intervalSlider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        intervalBox.alignment = .right
        intervalBox.target = self
        intervalBox.action = #selector(intervalBoxChanged)

        saveHotkeyButton.target = self
        saveHotkeyButton.action = #selector(captureSaveHotkey)
        restoreHotkeyButton.target = self
        restoreHotkeyButton.action = #selector(captureRestoreHotkey)

        saveNotifyCheckbox.target = self
        saveNotifyCheckbox.action = #selector(settingChanged)
        restoreNotifyCheckbox.target = self
        restoreNotifyCheckbox.action = #selector(settingChanged)

        let permissionButton = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilitySettings))

        let mainStack = verticalStack([
            header,
            panel("Current Saved Position", [
                verticalStack([positionLabel, positionTimeLabel], spacing: 4),
                horizontalStack([saveNowButton, restoreNowButton], spacing: 10)
            ]),
            panel("Modes", [
                autoCheckbox,
                makeLabel("Saves once after the mouse has not moved for the chosen time.", size: 13, color: .secondaryLabelColor),
                manualCheckbox,
                makeLabel("Press the save shortcut to overwrite the saved position.", size: 13, color: .secondaryLabelColor)
            ]),
            panel("Timing", [
                horizontalStack([
                    intervalSlider,
                    intervalBox,
                    makeLabel("seconds", size: 14, color: .secondaryLabelColor)
                ], spacing: 12)
            ]),
            panel("Hotkeys", [
                formRow("Save position", saveHotkeyButton),
                formRow("Restore position", restoreHotkeyButton),
                makeLabel("Click a hotkey button, then press the shortcut you want.", size: 13, color: .secondaryLabelColor),
                hotkeyStatusLabel
            ]),
            panel("Notifications", [
                saveNotifyCheckbox,
                restoreNotifyCheckbox
            ]),
            panel("Permission", [
                makeLabel("MouseTrac needs Accessibility permission so it can listen for shortcuts and move the cursor.", size: 14, color: .secondaryLabelColor),
                permissionButton
            ])
        ], spacing: 14)

        content.addSubview(mainStack)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            content.topAnchor.constraint(equalTo: mainStack.topAnchor, constant: -24),
            content.bottomAnchor.constraint(equalTo: mainStack.bottomAnchor, constant: 24),

            mainStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            mainStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            mainStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),

            permissionBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            permissionBadge.heightAnchor.constraint(equalToConstant: 28),
            intervalSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            intervalBox.widthAnchor.constraint(equalToConstant: 90)
        ])
    }

    func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    func horizontalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    func panel(_ title: String, _ views: [NSView]) -> NSView {
        let box = NSBox()
        box.title = title
        box.boxType = .primary
        box.cornerRadius = 8
        box.contentViewMargins = NSSize(width: 16, height: 16)

        let stack = verticalStack(views, spacing: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let contentView = box.contentView {
            contentView.addSubview(stack)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
                stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
            ])
        }

        return box
    }

    func formRow(_ labelText: String, _ control: NSView) -> NSView {
        let label = makeLabel(labelText, size: 14, weight: .semibold)
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        return horizontalStack([label, control], spacing: 12)
    }

    func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        let key = "AXTrustedCheckOptionPrompt"
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @objc func openAccessibilitySettings() {
        _ = hasAccessibilityPermission(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        refreshUI()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.refreshUI()
        }
    }

    @objc func saveNowClicked() {
        saveCurrentPosition(source: "manual")
    }

    @objc func restoreNowClicked() {
        restoreSavedPosition()
    }

    @objc func settingChanged() {
        settings.autoMode = autoCheckbox.state == .on
        settings.manualMode = manualCheckbox.state == .on
        settings.notifyOnSave = saveNotifyCheckbox.state == .on
        settings.notifyOnRestore = restoreNotifyCheckbox.state == .on
        registerHotkeys()
        refreshUI()
    }

    @objc func intervalSliderChanged() {
        let rounded = (intervalSlider.doubleValue * 10).rounded() / 10
        settings.intervalSeconds = rounded
        intervalSlider.doubleValue = rounded
        intervalBox.stringValue = String(format: "%.1f", rounded)
        startTimer()
    }

    @objc func intervalBoxChanged() {
        let rawValue = Double(intervalBox.stringValue) ?? 1.0
        let clamped = max(0.5, min(10.0, rawValue))
        let rounded = (clamped * 10).rounded() / 10
        settings.intervalSeconds = rounded
        intervalSlider.doubleValue = rounded
        intervalBox.stringValue = String(format: "%.1f", rounded)
        startTimer()
        refreshUI()
    }

    @objc func captureSaveHotkey() {
        capturingHotkey = "save"
        saveHotkeyButton.title = "Press shortcut..."
    }

    @objc func captureRestoreHotkey() {
        capturingHotkey = "restore"
        restoreHotkeyButton.title = "Press shortcut..."
    }

    func refreshUI() {
        let trusted = hasAccessibilityPermission()

        permissionBadge.setStatus(
            text: trusted ? "Permission ready" : "Permission needed",
            textColor: trusted ? .systemGreen : .systemOrange,
            backgroundColor: trusted ? NSColor.systemGreen.withAlphaComponent(0.18) : NSColor.systemYellow.withAlphaComponent(0.25)
        )

        if let savedPosition {
            positionLabel.stringValue = "x: \(Int(savedPosition.x)), y: \(Int(savedPosition.y)), display: \(savedPosition.displayId)"
            positionTimeLabel.stringValue = "Saved at \(savedPosition.savedAt)"
        } else {
            positionLabel.stringValue = "No position saved yet"
            positionTimeLabel.stringValue = ""
        }

        autoCheckbox.state = settings.autoMode ? .on : .off
        manualCheckbox.state = settings.manualMode ? .on : .off
        intervalSlider.doubleValue = settings.intervalSeconds
        intervalBox.stringValue = String(format: "%.1f", settings.intervalSeconds)
        saveHotkeyButton.title = settings.saveKeyLabel
        restoreHotkeyButton.title = settings.restoreKeyLabel
        saveNotifyCheckbox.state = settings.notifyOnSave ? .on : .off
        restoreNotifyCheckbox.state = settings.notifyOnRestore ? .on : .off
    }

    func startPermissionRefreshTimer() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(refreshPermissionStatus),
            userInfo: nil,
            repeats: true
        )
    }

    @objc func refreshPermissionStatus() {
        refreshUI()
    }

    func currentMousePosition() -> SavedPosition {
        let point = NSEvent.mouseLocation
        let display = displayId(for: point)

        let formatter = DateFormatter()
        formatter.timeStyle = .medium

        return SavedPosition(
            x: point.x,
            y: point.y,
            displayId: display,
            savedAt: formatter.string(from: Date())
        )
    }

    func saveCurrentPosition(source: String) {
        savedPosition = currentMousePosition()

        if settings.notifyOnSave {
            showNotification(title: "MouseTrac", body: source == "auto" ? "Auto-saved position." : "Saved position.")
        }

        refreshUI()
    }

    func restoreSavedPosition() {
        guard let savedPosition else {
            showNotification(title: "MouseTrac", body: "No mouse position has been saved yet.")
            return
        }

        let appKitPoint = CGPoint(x: savedPosition.x, y: savedPosition.y)

        guard pointIsOnConnectedDisplay(appKitPoint) else {
            showNotification(title: "MouseTrac", body: "Saved position is on a display that is not connected.")
            return
        }

        let warpPoint = quartzPoint(from: appKitPoint, displayId: savedPosition.displayId)
        CGWarpMouseCursorPosition(warpPoint)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

        if settings.notifyOnRestore {
            showNotification(title: "MouseTrac", body: "Restored position.")
        }

        refreshUI()
    }

    func startTimer() {
        timer?.invalidate()
        lastPosition = nil
        wasStill = false

        timer = Timer.scheduledTimer(
            timeInterval: settings.intervalSeconds,
            target: self,
            selector: #selector(checkAutoSave),
            userInfo: nil,
            repeats: true
        )
    }

    @objc func checkAutoSave() {
        guard settings.autoMode else { return }

        let point = NSEvent.mouseLocation

        if let lastPosition, Int(lastPosition.x) == Int(point.x), Int(lastPosition.y) == Int(point.y) {
            if !wasStill {
                saveCurrentPosition(source: "auto")
                wasStill = true
            }
        } else {
            wasStill = false
            lastPosition = point
        }
    }

    func pointIsOnConnectedDisplay(_ point: CGPoint) -> Bool {
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                return true
            }
        }

        return false
    }

    func displayId(for point: CGPoint) -> CGDirectDisplayID {
        for screen in NSScreen.screens {
            if screen.frame.contains(point),
               let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                return CGDirectDisplayID(number.uint32Value)
            }
        }

        return CGMainDisplayID()
    }

    func quartzPoint(from appKitPoint: CGPoint, displayId: CGDirectDisplayID) -> CGPoint {
        for screen in NSScreen.screens {
            guard screen.frame.contains(appKitPoint),
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDirectDisplayID(number.uint32Value) == displayId else {
                continue
            }

            let quartzBounds = CGDisplayBounds(displayId)
            let localX = appKitPoint.x - screen.frame.minX
            let localYFromBottom = appKitPoint.y - screen.frame.minY
            let localYFromTop = screen.frame.height - localYFromBottom

            return CGPoint(
                x: quartzBounds.minX + localX,
                y: quartzBounds.minY + localYFromTop
            )
        }

        let mainHeight = NSScreen.main?.frame.height ?? 0
        return CGPoint(x: appKitPoint.x, y: mainHeight - appKitPoint.y)
    }

    func showNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        NSUserNotificationCenter.default.deliver(notification)
    }

    func installHotkeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }

            let app = Unmanaged<MouseTracApp>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()

            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            DispatchQueue.main.async {
                if hotKeyID.id == 1 {
                    app.saveCurrentPosition(source: "manual")
                } else if hotKeyID.id == 2 {
                    app.restoreSavedPosition()
                }
            }

            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    func registerHotkeys() {
        unregisterHotkeys()

        let modifiers = UInt32(cmdKey | shiftKey)

        if settings.manualMode {
            var saveId = EventHotKeyID(signature: OSType(0x4D545243), id: 1)
            let saveResult = RegisterEventHotKey(
                settings.saveKeyCode,
                modifiers,
                saveId,
                GetApplicationEventTarget(),
                0,
                &saveHotKeyRef
            )

            hotkeyStatusLabel.stringValue = saveResult == noErr ? "Save hotkey active." : "Save hotkey failed."
        }

        var restoreId = EventHotKeyID(signature: OSType(0x4D545243), id: 2)
        let restoreResult = RegisterEventHotKey(
            settings.restoreKeyCode,
            modifiers,
            restoreId,
            GetApplicationEventTarget(),
            0,
            &restoreHotKeyRef
        )

        if restoreResult == noErr {
            hotkeyStatusLabel.stringValue += " Restore hotkey active."
        } else {
            hotkeyStatusLabel.stringValue += " Restore hotkey failed."
        }
    }

    func unregisterHotkeys() {
        if let saveHotKeyRef {
            UnregisterEventHotKey(saveHotKeyRef)
            self.saveHotKeyRef = nil
        }

        if let restoreHotKeyRef {
            UnregisterEventHotKey(restoreHotKeyRef)
            self.restoreHotKeyRef = nil
        }
    }
}

final class StatusBadge: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        label.stringValue = text
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStatus(text: String, textColor: NSColor, backgroundColor: NSColor) {
        label.stringValue = text
        label.textColor = textColor
        layer?.backgroundColor = backgroundColor.cgColor
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(width: labelSize.width + 24, height: 28)
    }
}

final class HotkeyWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        guard let appDelegate = NSApp.delegate as? MouseTracApp,
              let captureTarget = appDelegate.capturingHotkey else {
            super.keyDown(with: event)
            return
        }

        guard event.modifierFlags.contains(.command),
              event.modifierFlags.contains(.shift),
              let characters = event.charactersIgnoringModifiers?.uppercased(),
              characters.count == 1,
              let keyCode = keyCodeForLetter(characters) else {
            NSSound.beep()
            return
        }

        if captureTarget == "save" {
            appDelegate.settings.saveKeyCode = keyCode
            appDelegate.settings.saveKeyLabel = "Command + Shift + \(characters)"
        } else {
            appDelegate.settings.restoreKeyCode = keyCode
            appDelegate.settings.restoreKeyLabel = "Command + Shift + \(characters)"
        }

        appDelegate.capturingHotkey = nil
        appDelegate.registerHotkeys()
        appDelegate.refreshUI()
    }
}

func keyCodeForLetter(_ letter: String) -> UInt32? {
    let codes: [String: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
        "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
        "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
        "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
        "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
        "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
        "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z
    ]

    return codes[letter].map { UInt32($0) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = MouseTracApp()
    app.delegate = delegate
    app.run()
}
