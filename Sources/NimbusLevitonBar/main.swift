// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import NimbusUpdater

// Nimbus Leviton Bar — a menu bar controller for Leviton Decora Smart Wi-Fi devices via the
// My Leviton cloud. See README.md.
//
// Flags (all optional; build.sh uses most of them):
//   --enable-login-item     register this bundle as a Login Item, then keep running
//   --disable-login-item    unregister the Login Item and exit
//   --login-item-status     print the Login Item state and exit
//   --render-icon PATH [--size PX]   write the app icon as a PNG and exit
//   --render-iconset DIR    write an .iconset (for iconutil) and exit
//   --render-dmg-background DIR [--signed]   write the disk image's background PNGs and exit
//   --dump-bar PATH         render just the status item to PATH, quit (layout check)
//   --dump-menu PATH        render the menu's rows with sample data to PATH, quit (layout check)
//
// Command-line use of the same client (no UI; the login/session come from the Keychain):
//   --login EMAIL           ask for the password (or take $MYLEVITON_PASSWORD), sign in, save both; exit
//   --logout                forget the session and the password; exit
//   --print                 list residences and devices as text; exit
//   --set DEVICE on|off|N   turn a device (name or id) on/off or set its level; exit
//   --watch                 print realtime updates as they arrive (Ctrl-C to stop)
//   --get PATH              raw GET of an API path (e.g. Residences/1/residentialRooms), pretty-printed

func usage() -> Never {
    print("""
    usage: NimbusLevitonBar [--enable-login-item | --disable-login-item | --login-item-status]
                            [--render-icon PATH [--size PX]] [--render-iconset DIR]
                            [--login EMAIL | --logout | --print | --set DEVICE on|off|N | --watch]
                            [--room ROOM on|off | --get PATH | --put PATH JSON | --dump-menu PATH]
                            [--check-update | --preflight APP.app]
    """)
    exit(2)
}

var enableLoginItem = false
var dumpBarPath: String?
var renderIconPath: String?
var renderIconSize = 1024
var renderIconsetDir: String?
var renderDMGBackgroundDir: String?
var dmgSigned = false
var cli: CLI.Command?

var args = Array(CommandLine.arguments.dropFirst())
func takeValue(_ flag: String) -> String {
    guard !args.isEmpty else { fputs("\(flag) needs a value\n", stderr); usage() }
    return args.removeFirst()
}
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--enable-login-item": enableLoginItem = true
    case "--disable-login-item":
        do { try LoginItem.setEnabled(false); print("login item: \(LoginItem.statusDescription)") }
        catch { fputs("could not unregister login item: \(error)\n", stderr); exit(1) }
        exit(0)
    case "--login-item-status":
        print(LoginItem.statusDescription)
        exit(0)
    case "--render-icon": renderIconPath = takeValue(a)
    case "--size": renderIconSize = Int(takeValue(a)) ?? 1024
    case "--render-iconset": renderIconsetDir = takeValue(a)
    case "--render-dmg-background": renderDMGBackgroundDir = takeValue(a)
    case "--signed": dmgSigned = true
    case "--dump-bar": dumpBarPath = takeValue(a)
    case "--dump-menu":
        let path = takeValue(a)
        MainActor.assumeIsolated {
            let ok = MenuRowPreview.write(to: path)
            print(ok ? "wrote \(path)" : "menu dump failed")
            exit(ok ? 0 : 1)
        }
    case "--login": cli = .login(email: takeValue(a))
    case "--logout": cli = .logout
    case "--print": cli = .print
    case "--watch": cli = .watch
    case "--get": cli = .get(path: takeValue(a))
    case "--check-update": cli = .checkUpdate
    case "--preflight": cli = .preflight(app: takeValue(a))
    case "--put":
        let path = takeValue(a), json = takeValue(a)
        cli = .put(path: path, json: json)
    case "--set":
        let device = takeValue(a), value = takeValue(a)
        cli = .set(device: device, value: value)
    case "--room":
        let room = takeValue(a), value = takeValue(a)
        cli = .room(room: room, value: value)
    case "-h", "--help": usage()
    default:
        // Finder/LaunchServices can pass -psn_… style args; ignore anything unknown.
        if !a.hasPrefix("-psn") { fputs("ignoring unknown argument \(a)\n", stderr) }
    }
}

if let dir = renderIconsetDir {
    do { try AppIcon.writeIconset(to: dir); print("wrote \(dir)") }
    catch { fputs("iconset: \(error)\n", stderr); exit(1) }
    exit(0)
}
if let dir = renderDMGBackgroundDir {
    do { try DMGBackground.write(to: dir, signed: dmgSigned); print("wrote \(dir)") }
    catch { fputs("dmg background: \(error)\n", stderr); exit(1) }
    exit(0)
}
if let path = renderIconPath {
    guard let data = AppIcon.pngData(px: renderIconSize) else { fputs("icon render failed\n", stderr); exit(1) }
    do { try data.write(to: URL(fileURLWithPath: path)); print("wrote \(path) (\(renderIconSize)×\(renderIconSize))") }
    catch { fputs("icon: \(error)\n", stderr); exit(1) }
    exit(0)
}
if let cli { exit(CLI.run(cli)) }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: DeviceStore!
    var statusBar: StatusBarController!

    /// A menu-bar-only app has no main menu, so ⌘V / ⌘C / ⌘A have nowhere to go and the
    /// sign-in fields refuse a pasted password. An Edit menu (never shown) routes them.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        let editItem = NSMenuItem(); editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no app menu. (The bundle's LSUIElement says the same;
        // this also covers running the bare binary.)
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()

        store = DeviceStore()

        // The updater, unless this launch is a screenshot run. It checks GitHub for a newer
        // release (daily, and when the menu opens if the last check is stale), stages one that
        // is signed by the same Developer ID as this copy, and waits for a click.
        var updater: Updater?
        if dumpBarPath == nil, let version = Updates.runningVersion {
            let u = Updater(config: Updates.config(currentVersion: version))
            u.onWillRelaunch = { [weak store] in store?.stop() }
            updater = u
        }
        statusBar = StatusBarController(store: store, updater: updater)
        updater?.onChange = { [weak self] in self?.statusBar.updaterChanged() }
        updater?.start()

        // Login Item. `build.sh install` passes --enable-login-item; a drag-install from the
        // disk image has nobody to pass it, so the first launch from /Applications registers
        // too. Once only — the flag is then set, so turning it off later (menu, System
        // Settings) sticks across relaunches and updates.
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
        let registered = UserDefaults.standard.bool(forKey: LoginItem.registeredDefaultsKey)
        if enableLoginItem || (installed && !registered) {
            do { try LoginItem.setEnabled(true); NSLog("login item: \(LoginItem.statusDescription)") }
            catch { NSLog("could not register login item: \(error)") }
            UserDefaults.standard.set(true, forKey: LoginItem.registeredDefaultsKey)
        }

        // Nothing saved in the Keychain: ask now, once. Cancel leaves the menu's Sign In… row.
        if !store.start(), dumpBarPath == nil, let login = SignInDialog.run() {
            store.signIn(login)
        }

        if let path = dumpBarPath {
            let t = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    let ok = self?.statusBar.dumpBar(to: path) ?? false
                    NSLog(ok ? "bar → \(path)" : "bar dump failed")
                    exit(ok ? 0 : 1)
                }
            }
            RunLoop.main.add(t, forMode: .common)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
