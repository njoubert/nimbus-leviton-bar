// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// "Sign in to My Leviton": an alert with an email and a password field. Used on first
/// launch (no saved login), from the menu's Sign In… row, and again after the server
/// rejects the saved password. Runs modally; the caller gets the login or nil.
@MainActor
enum SignInDialog {
    static func run(email: String? = nil, message: String? = nil) -> Keychain.Login? {
        let alert = NSAlert()
        alert.messageText = "Sign in to My Leviton"
        alert.informativeText = message
            ?? "The same email and password as the My Leviton app. They are kept in your Keychain and sent only to my.leviton.com."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let emailField = NSTextField(frame: NSRect(x: 0, y: 34, width: 300, height: 24))
        emailField.placeholderString = "Email"
        emailField.stringValue = email ?? ""
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        passwordField.placeholderString = "Password"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        box.addSubview(emailField)
        box.addSubview(passwordField)
        alert.accessoryView = box
        emailField.nextKeyView = passwordField
        passwordField.nextKeyView = emailField
        alert.window.initialFirstResponder = email == nil || email!.isEmpty ? emailField : passwordField

        // A menu bar app has no key window to anchor the alert; bring it forward explicitly.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let e = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = passwordField.stringValue
        guard !e.isEmpty, !p.isEmpty else { return nil }
        return Keychain.Login(email: e, password: p)
    }

    /// The account uses two-factor authentication: ask for the code My Leviton just sent.
    static func askCode(email: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Two-factor code"
        alert.informativeText = "My Leviton sent a code to the contact on file for \(email). Enter it to finish signing in."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "123456"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let code = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    /// A plain "something went wrong" alert with one button.
    static func showError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
