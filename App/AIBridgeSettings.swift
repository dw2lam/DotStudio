//  AIBridgeSettings.swift — the app's end of dotstudio-mcp's get_settings / update_settings /
//  app_action (the catalog and validation: Shared/AI/AppSettings.swift).
//
//  Reads come from the live objects (AppModel, WallpaperController, AppPresence, WeatherService,
//  UpdateController, the login item and the setup checks). Changes go through the same calls the
//  Settings window's controls make, so it updates at once; each patch shows a notice with Undo.
//  Settings that change what plays honour “Let AI change what plays”, as set_screensaver does.

import AppKit
import ApplicationServices

extension AIBridgeHost {
    // MARK: Read

    func settingsState(_ model: AppModel) -> AppSettings.State {
        let wall = WallpaperController.shared.settings
        let wallJSON = (try? JSONEncoder().encode(wall)).flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
        var prefs: [String: Bool] = [AppPresence.menuBarModeKey: AppPresence.shared.menuBarMode,
                                     WeatherService.enabledKey: WeatherService.shared.enabled]
        if let u = UpdateController.current {
            prefs["SUEnableAutomaticChecks"] = u.automaticallyChecks
            prefs["SUAutomaticallyUpdate"] = u.automaticallyInstalls
        }
        return AppSettings.State(library: model.library, wallpaper: wallJSON, prefs: prefs,
                                 ai: AISettings.load(store: model.store.baseDir))
    }

    /// Every setting's value, plus what only the running app can read.
    func settingsNow(_ model: AppModel) -> [String: JSONValue] {
        var o = AppSettings.read(settingsState(model))
        // The Settings toggle shows the wallpaper as on only while it has something to play.
        o["wallpaper.on"] = .bool(WallpaperController.shared.isActive)
        o["wallpaper.sameAsScreensaver"] = .bool(WallpaperController.shared.isActive && WallpaperController.shared.followsScreensaver)
        let login = LoginItem.status()
        o["general.openAtLogin"] = .bool(login != .off)
        o["system.loginItemApproval"] = .string(login == .enabled ? "enabled" : login == .requiresApproval ? "requiresApproval" : "off")
        o["system.screensaverInstalled"] = .bool(Installer.isInstalled)
        switch Installer.screensaverChoice() {
        case .unknown: o["system.screensaverChosen"] = .string("unknown (macOS's wallpaper store couldn't be read)")
        case .chosen(let on, let of): o["system.screensaverChosen"] = .string(on == 0 ? "not chosen" : "on \(on) of \(of) display\(of == 1 ? "" : "s")")
        }
        let idle = SetupProbe.idleSeconds() ?? SetupSnapshot.defaultIdle
        o["system.startScreenSaverAfter"] = .number(Double(idle) / 60)
        if let t = SetupProbe.displaySleep() {
            var d: [String: JSONValue] = [:]
            if let b = t.battery { d["battery"] = .integer(Int64(b)) }
            if let a = t.ac { d["powerAdapter"] = .integer(Int64(a)) }
            o["system.displayOffMinutes"] = .object(d)
        }
        o["system.accessibilityForGuideMe"] = .bool(AXIsProcessTrusted())
        let w = WeatherService.shared
        if let r = w.reading {
            o["weather.now"] = .string(([r.place.map { "\($0) area" }, r.summary] as [String?]).compactMap { $0 }.joined(separator: " · "))
        } else {
            o["weather.now"] = .string(w.enabled ? "no reading yet" : "off")
        }
        if let u = UpdateController.current {
            o["updates.version"] = .string(u.currentVersion)
            o["updates.status"] = .string(Self.updateStatus(u.state))
        }
        return o
    }

    static func updateStatus(_ s: UpdateController.State) -> String {
        switch s {
        case .idle, .upToDate: return "up to date"
        case .checking: return "checking"
        case .available(let v): return "\(v) is available"
        case .downloading(let v): return "downloading \(v)"
        case .readyToInstall(let v): return "\(v) is ready to install (Restart to Update, or it installs on quit)"
        case .failed(let why): return "couldn't check: \(why)"
        }
    }

    // MARK: Change

    func updateSettings(_ req: BridgeRequest, _ model: AppModel, who: String) -> BridgeResponse {
        let changes: [AppSettings.Change]
        switch AppSettings.validate(req.settings ?? [:], library: model.library) {
        case .success(let c): changes = c
        case .failure(let e): return .fail(e.message)
        }
        let ai = AISettings.load(store: model.store.baseDir)
        let gated = AppSettings.gatedKeys(changes)
        if !gated.isEmpty, !ai.allowPlaybackChanges {
            return .fail(Self.playbackOff + " (Refused: \(gated.joined(separator: ", ")) change what plays; the other settings can be sent on their own.)")
        }
        let undo = settingsSnapshot(model)
        var problems: [String] = []

        // Library settings: the shared edit on a copy, then the touched fields, saved once —
        // what the Settings bindings and the Inspector's Source do.
        let libraryChanges = changes.filter { $0.def.store == .library }
        if !libraryChanges.isEmpty {
            var state = settingsState(model)
            do {
                try AppSettings.apply(libraryChanges, to: &state) { try model.store.importMedia(from: $0) }
            } catch let e as SettingsError {
                return .fail(e.message)
            } catch {
                return .fail("Couldn't copy the file into DotStudio's library: \(error.localizedDescription). Nothing was changed.")
            }
            model.library.rotation = state.library.rotation
            model.library.renderScale = state.library.renderScale
            model.library.music = state.library.music
            model.library.source = state.library.source
            model.save()
            // The location through the app's own call: it also stops or restarts the IP lookup.
            if let loc = libraryChanges.first(where: { $0.def.key == "weather.location" }) {
                model.setLocation(AppSettings.place(loc.value))
            }
        }

        let w = WallpaperController.shared
        for c in changes where c.def.store != .library {
            let v = c.value
            switch c.def.key {
            case "general.menuBarMode": AppPresence.shared.menuBarMode = v.boolValue ?? true
            case "general.openAtLogin":
                if let err = LoginItem.set(v.boolValue ?? false) { problems.append(err) }
            case "weather.live": WeatherService.shared.enabled = v.boolValue ?? true
            case "wallpaper.on": w.setEnabled(v.boolValue ?? false)
            case "wallpaper.sameAsScreensaver": w.setFollowsScreensaver(v.boolValue ?? false)
            case "wallpaper.style":
                guard let id = v.stringValue.flatMap(UUID.init) else { continue }
                if w.isActive { w.use(id) } else { w.update { $0.presetID = id } }
            case "wallpaper.frameRate": w.update { $0.frameRate = v.stringValue == "smooth" ? .smooth : .balanced }
            case "wallpaper.quality": w.update { $0.quality = WallpaperSettings.Quality(rawValue: v.stringValue ?? "") ?? .balanced }
            case "wallpaper.onBattery": w.update { $0.batteryMode = WallpaperSettings.BatteryMode(rawValue: v.stringValue ?? "") ?? .efficient }
            case "wallpaper.lockScreenPicture": w.setLockScreen(v.boolValue ?? false)
            case "updates.checkAutomatically", "updates.installAutomatically":
                guard let u = UpdateController.current else { problems.append("the updater isn't ready yet"); continue }
                if c.def.key == "updates.checkAutomatically" { u.automaticallyChecks = v.boolValue ?? true }
                else { u.automaticallyInstalls = v.boolValue ?? true }
            default:
                problems.append("\(c.def.key) isn't handled by this DotStudio")
            }
        }

        let now = settingsNow(model)
        var changed: [String: JSONValue] = [:]
        for c in changes { changed[c.def.key] = now[c.def.key] ?? c.value }
        let what = changes.map { AppSettings.describe($0, library: model.library) }.joined(separator: "; ")
        if ai.showNotices {
            AINoticePanel.shared.show("\(who) changed \(what)", undo: undo)
        }
        var msg = "Changed \(what)."
        if !problems.isEmpty { msg += " But: " + problems.joined(separator: "; ") + "." }
        return BridgeResponse(ok: true, appVersion: appVersion, message: msg, settings: changed)
    }

    /// Everything update_settings can change, to put back on Undo.
    private func settingsSnapshot(_ model: AppModel) -> () -> Void {
        let lib = model.library
        let wall = WallpaperController.shared.settings
        let menuBar = AppPresence.shared.menuBarMode
        let weather = WeatherService.shared.enabled
        let login = LoginItem.status() != .off
        let checks = UpdateController.current?.automaticallyChecks
        let installs = UpdateController.current?.automaticallyInstalls
        return { [weak model] in
            guard let model else { return }
            model.library.rotation = lib.rotation
            model.library.renderScale = lib.renderScale
            model.library.music = lib.music
            model.library.source = lib.source
            model.save()
            if lib.usesManualLocation != model.library.usesManualLocation || lib.manualPlace != model.library.manualPlace {
                model.setLocation(lib.usesManualLocation ? lib.manualPlace : nil)
            }
            let w = WallpaperController.shared
            if !wall.enabled, w.settings.enabled { w.stop() }
            w.update { var s = wall; s.enabled = $0.enabled; s.savedDesktopPictures = $0.savedDesktopPictures; $0 = s }
            if wall.enabled, !w.settings.enabled { w.setEnabled(true) }
            if AppPresence.shared.menuBarMode != menuBar { AppPresence.shared.menuBarMode = menuBar }
            if WeatherService.shared.enabled != weather { WeatherService.shared.enabled = weather }
            if (LoginItem.status() != .off) != login { LoginItem.set(login) }
            if let u = UpdateController.current {
                if let checks, u.automaticallyChecks != checks { u.automaticallyChecks = checks }
                if let installs, u.automaticallyInstalls != installs { u.automaticallyInstalls = installs }
            }
        }
    }

    // MARK: Actions

    func appAction(_ action: String, _ model: AppModel) -> BridgeResponse {
        func done(_ msg: String) -> BridgeResponse { BridgeResponse(ok: true, appVersion: appVersion, message: msg) }
        switch action {
        case "install_screensaver":
            model.installScreensaver()
            guard Installer.isInstalled else { return .fail("DotStudio couldn't install its screensaver (the app shows why).") }
            return done(model.setupStatus == .ready ? "Installed DotStudio's screensaver; it's the chosen screensaver."
                        : "Installed DotStudio's screensaver. System Settings ▸ Wallpaper is open: the user clicks Screen Saver… and picks DotStudio.")
        case "open_screensaver_settings":
            Installer.openScreenSaverSettings()
            return done("Opened System Settings ▸ Wallpaper: the user clicks Screen Saver… and picks DotStudio.")
        case "show_setup_guide":
            MainActor.assumeIsolated { SetupGuidePanel.shared.show(model: model) }
            return done("Opened the setup guide. It checks each step live; Guide Me points at the next click.")
        case "guide_me":
            MainActor.assumeIsolated {
                SetupGuidePanel.shared.show(model: model)
                SetupCoach.shared.guideMe()
            }
            return done(AXIsProcessTrusted()
                        ? "Opened the setup guide and started Guide Me: it rings the next control to click in System Settings."
                        : "Opened the setup guide and started Guide Me: macOS asks the user to allow Accessibility first (once).")
        case "open_lock_screen_settings":
            SystemSettingsLink.openLockScreen()
            return done("Opened System Settings ▸ Lock Screen.")
        case "open_login_items_settings":
            LoginItem.openLoginItemsSettings()
            return done("Opened System Settings ▸ General ▸ Login Items.")
        case "check_for_updates":
            guard let u = UpdateController.current else { return .fail("The updater isn't ready yet.") }
            if case .readyToInstall(let v) = u.state {
                return done("DotStudio \(v) is already downloaded: it installs when DotStudio quits, or the user clicks Restart to Update in Settings ▸ Updates.")
            }
            guard u.canCheck else { return .fail("This copy of DotStudio can't check for updates right now (a development build, or a check is already running).") }
            u.primaryAction()
            return done("Checking for updates; Sparkle shows what it finds.")
        case "open_settings":
            AppPresence.shared.showSettings()
            return done("Opened DotStudio's Settings.")
        case "open_main_window":
            AppPresence.shared.showMainWindow()
            return done("Opened DotStudio's main window.")
        case "show_welcome":
            AppPresence.shared.showMainWindow()
            model.showOnboarding = true
            return done("Showing the welcome tour.")
        default:
            return .fail("unknown action \(action)")
        }
    }
}
