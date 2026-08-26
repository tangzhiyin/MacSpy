//
//  AppDelegate.swift
//  MacSpy
//
//  Created by Crisp on 2026/6/13.
//


import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let accessibilityOnboardingKey = "hasShownAccessibilityOnboardingV1"
    private var windowController: MainWindowController!
    private var didPresentAccessibilityPrompt = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureApplicationIcon()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureApplicationIcon()

        windowController = MainWindowController()
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            self?.configureApplicationIcon()
            self?.presentAccessibilityOnboardingIfNeeded()
        }
    }

    private func configureApplicationIcon() {
        guard let iconURL = Bundle.main.url(
            forResource: "MacSpyIcon",
            withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        icon.isTemplate = false
        NSApp.applicationIconImage = icon
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        windowController?.accessibilityPermissionDidChange()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func showAccessibilityPermissionGuide() {
        presentAccessibilityGuide(force: true)
    }

    private func presentAccessibilityOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(
            forKey: Self.accessibilityOnboardingKey) else { return }
        presentAccessibilityGuide(force: false)
    }

    private func presentAccessibilityGuide(force: Bool) {
        guard force || !didPresentAccessibilityPrompt else { return }
        didPresentAccessibilityPrompt = true
        UserDefaults.standard.set(
            true,
            forKey: Self.accessibilityOnboardingKey)

        let alert = NSAlert()
        alert.alertStyle = .informational
        if AXIsProcessTrusted() {
            alert.messageText = "辅助功能权限已启用"
            alert.informativeText = """
            MacSpy 已获得检查 Outlook for Mac 窗口和界面元素所需的辅助功能权限。

            macOS 会按 Bundle ID 保留此权限，因此重新 Build 通常不会再次要求授权。
            """
            alert.addButton(withTitle: "完成")
            alert.addButton(withTitle: "打开设置")
            if alert.runModal() == .alertSecondButtonReturn {
                openAccessibilitySettings(requestSystemPrompt: false)
            }
        } else {
            alert.messageText = "MacSpy 需要辅助功能权限"
            alert.informativeText = """
            为了检查 Outlook for Mac 等应用的窗口和界面元素，请在“系统设置 → 隐私与安全性 → 辅助功能”中启用 MacSpy。

            出于 macOS 安全限制，MacSpy 无法代替你开启此开关，但可以直接打开对应的设置页面。
            """
            alert.addButton(withTitle: "打开辅助功能设置")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                openAccessibilitySettings(requestSystemPrompt: true)
            }
        }
    }

    private func openAccessibilitySettings(requestSystemPrompt: Bool) {
        if requestSystemPrompt {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
            ]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSWorkspace.shared.open(url)
        }
    }
}