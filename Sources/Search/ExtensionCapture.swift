import AppKit
import SwiftUI
import WebKit

// Screen recording for extensions (#218): Loom, Screencastify, Awesome
// Screenshot and the like.
//
// Chrome hands an extension a stream id from its own picker
// (desktopCapture.chooseDesktopMedia) and the stream for it from
// getUserMedia. WebKit has neither. What it has is getDisplayMedia, which
// shows the Mac's own picker, and which it refuses unless the call comes
// from a click being handled in a page that is on screen. So Search stands
// in between. An extension's page asks through a channel that knows who is
// asking; Search asks you, once per extension, whether it may record; brings
// the page on screen; and calls WebKit's getDisplayMedia in that page itself,
// which WebKit counts as a click. The Mac's picker follows, every time: it is
// the Mac, not Search, that asks what to share. The stream stays in the page
// and is handed over as the answer to the extension's getUserMedia.
//
// While an extension records, a small pill says so and stops it
// (RecordingIndicator.swift, which shows what this watches).
//
// Nothing here uses ScreenCaptureKit or looks at other windows: WebKit's
// picker is the only way in, and it needs no Screen Recording permission.
// A test run never brings anything on screen and never shows the pill.

@available(macOS 15.4, *)
@MainActor
final class ExtensionCapture: NSObject, WKScriptMessageHandlerWithReply, ObservableObject {
    static let shared = ExtensionCapture()
    /// The name the pages post to (window.webkit.messageHandlers).
    static let channel = "searchCapture"

    override private init() {
        super.init()
        RecordingIndicator.shared.onStop = { [weak self] id in self?.stop(id) }
    }

    // MARK: - asking, once per extension

    static func key(_ id: String) -> String { "extensions.capture.\(id)" }
    static func allowed(_ id: String) -> Bool { Store.settings.bool(forKey: key(id)) }

    /// The extensions you let record, for Settings › Extensions.
    static var allowedIDs: [String] {
        Store.settings.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("extensions.capture.") }
            .map { String($0.dropFirst("extensions.capture.".count)) }
            .filter { allowed($0) }
            .sorted()
    }

    /// Taken back: asked again the next time it wants to record.
    static func forget(_ id: String) {
        Store.settings.removeObject(forKey: key(id))
        shared.refused.remove(id)
        shared.objectWillChange.send()
    }

    /// It may record: it says so in its manifest, or was given it since.
    static func declares(_ context: WKWebExtensionContext) -> Bool {
        let manifest = context.webExtension.manifest
        let required = manifest["permissions"] as? [String] ?? []
        let granted = Store.settings.stringArray(forKey: "extensions.granted.\(context.uniqueIdentifier)") ?? []
        return required.contains("desktopCapture") || granted.contains("desktopCapture")
    }

    /// Yes from you: now, or before and you have just done something in
    /// Search — a remembered yes is never used by an extension on its own.
    private var refused: Set<String> = []

    private func consent(_ context: WKWebExtensionContext) async -> Bool {
        let id = context.uniqueIdentifier
        if ExtensionCapture.allowed(id) { return Store.testing || Extensions.recentlyUsed(within: 15) }
        // Refused once, not asked again until Search starts afresh: an
        // extension can't wear you down with the question.
        guard !refused.contains(id) else { return false }
        guard await Extensions.shared.ask(capture: context) else {
            refused.insert(id)
            return false
        }
        Store.settings.set(true, forKey: ExtensionCapture.key(id))
        objectWillChange.send()
        return true
    }

    // MARK: - stream ids

    /// A stream id handed to an extension: good once, for a minute, for that
    /// extension only.
    private struct Grant {
        let extensionID: String
        let made: Date
    }
    private var grants: [String: Grant] = [:]

    private static func token() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// From the extension's worker, which has no page to record in: the id is
    /// given now, and the recording starts when one of its pages hands it to
    /// getUserMedia (see `consume`).
    func grant(for context: WKWebExtensionContext) async -> String {
        guard ExtensionCapture.declares(context), await consent(context) else { return "" }
        let token = ExtensionCapture.token()
        grants = grants.filter { Date().timeIntervalSince($0.value.made) < 60 }
        grants[token] = Grant(extensionID: context.uniqueIdentifier, made: Date())
        return token
    }

    // MARK: - the channel

    /// What the bench reads.
    private(set) var last: [String: String] = [:]

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            return replyHandler(nil, "Not a request")
        }
        // Only the top of one of an extension's own pages, in a view of that
        // extension's: not a site framed in it, not its page framed in a site,
        // not another extension.
        guard let (context, web) = ExtensionCapture.sender(of: message) else {
            last = ["op": op, "refused": "sender"]
            return replyHandler(["error": "NotAllowedError", "message": "Not allowed here"], nil)
        }
        if op == "watch" {
            watch(web, for: context)
            return replyHandler(["ok": true], nil)
        }
        Task { @MainActor in
            let answer = await self.answer(op, body, context: context, in: web)
            self.last = answer.mapValues { "\($0)" }.merging(["op": op]) { a, _ in a }
            replyHandler(answer, nil)
        }
    }

    static func sender(of message: WKScriptMessage) -> (WKWebExtensionContext, WKWebView)? {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, let web = message.webView, Browser.extensionScheme(origin.protocol),
              let url = web.url, url.scheme?.lowercased() == origin.protocol.lowercased(),
              url.host()?.lowercased() == origin.host.lowercased(),
              let context = Extensions.shared.contexts.values.first(where: { $0.uniqueIdentifier.lowercased() == origin.host.lowercased() }),
              web.configuration.websiteDataStore.isPersistent
        else { return nil }
        return (context, web)
    }

    private func answer(_ op: String, _ body: [String: Any], context: WKWebExtensionContext, in web: WKWebView) async -> [String: Any] {
        guard ExtensionCapture.declares(context) || op == "display" else {
            return ["error": "NotAllowedError", "message": "It didn't ask to record your screen"]
        }
        let video = body["video"] ?? true
        switch op {
        // chooseDesktopMedia, from a page: asked, and recorded right away in
        // that page, so a cancelled picker is an empty id, as in Chrome.
        case "choose", "display":
            guard await consent(context) else { return ["error": "NotAllowedError", "message": "Permission denied"] }
            let token = ExtensionCapture.token()
            return await record(in: web, token: token, video: video, context: context)
        // An id the worker was given, handed to getUserMedia in a page.
        case "consume":
            guard let token = body["token"] as? String, let grant = grants.removeValue(forKey: token),
                  grant.extensionID == context.uniqueIdentifier, Date().timeIntervalSince(grant.made) < 60
            else { return ["error": "NotAllowedError", "message": "Invalid state"] }
            return await record(in: web, token: token, video: video, context: context)
        default:
            return ["error": "NotSupportedError", "message": "Unknown request"]
        }
    }

    /// The page on screen, then WebKit's getDisplayMedia called in it.
    private func record(in web: WKWebView, token: String, video: Any, context: WKWebExtensionContext) async -> [String: Any] {
        await bringForward(web)
        do {
            // Called by the app, so WebKit counts it as a click: the page's
            // own getDisplayMedia, kept by the shim before any of the
            // extension's code ran, is called at once, before any await.
            let result = try await web.callAsyncJavaScript(
                "return await globalThis[Symbol.for('search.capture')](token, video);",
                arguments: ["token": token, "video": video], in: nil, contentWorld: .page)
            guard let reply = result as? [String: Any] else { return ["error": "AbortError", "message": "No answer"] }
            if reply["ok"] as? Bool == true {
                watch(web, for: context)
                return ["ok": true, "token": token]
            }
            return reply
        } catch {
            return ["error": "AbortError", "message": error.localizedDescription]
        }
    }

    /// WebKit won't start a recording in a page that isn't on screen. Brought
    /// forward only after you said yes or just did something in Search, and
    /// never in a test run.
    private func bringForward(_ web: WKWebView) async {
        guard !Store.testing else { return }
        for browser in Browsers.all {
            guard let tab = browser.tab(for: web) else { continue }
            browser.select(tab)
            Browsers.show(browser)
            break
        }
        for _ in 0..<20 {
            if web.window?.isVisible == true, web.window?.occlusionState.contains(.visible) == true,
               (try? await web.evaluateJavaScript("document.visibilityState")) as? String == "visible" { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - what is recording

    /// Pages of extensions that capture, watched until they stop.
    private var watched: [ObjectIdentifier: (web: WKWebView, id: String)] = [:]
    private static let keys = ["cameraCaptureState", "microphoneCaptureState", "_displayCaptureState"]

    func watch(_ web: WKWebView, for context: WKWebExtensionContext) {
        let key = ObjectIdentifier(web)
        guard watched[key] == nil else { return changed() }
        watched[key] = (web, context.uniqueIdentifier)
        for path in ExtensionCapture.keys where path != "_displayCaptureState" || web.responds(to: NSSelectorFromString(path)) {
            web.addObserver(self, forKeyPath: path, options: [], context: nil)
        }
        changed()
    }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { ExtensionCapture.shared.changed() } }
    }

    /// One extension's captures, in words.
    struct Recording: Equatable, Identifiable {
        let id: String
        let name: String
        let screen: Bool
        let camera: Bool
        let microphone: Bool

        var what: String {
            if screen { return "is recording your screen" }
            if camera && microphone { return "is using your camera and microphone" }
            return camera ? "is using your camera" : "is using your microphone"
        }
    }

    @Published private(set) var recordings: [Recording] = []

    static func screen(_ web: WKWebView) -> Bool {
        guard web.responds(to: NSSelectorFromString("_displayCaptureState")) else { return false }
        return (web.value(forKey: "_displayCaptureState") as? Int ?? 0) != 0
    }

    /// Whether this page is recording anything, for Sleep.
    static func capturing(_ web: WKWebView) -> Bool {
        screen(web) || web.cameraCaptureState != .none || web.microphoneCaptureState != .none
    }

    private func changed() {
        var by: [String: Recording] = [:]
        for (key, entry) in watched {
            let web = entry.web
            guard ExtensionCapture.capturing(web) else {
                for path in ExtensionCapture.keys where path != "_displayCaptureState" || web.responds(to: NSSelectorFromString(path)) {
                    web.removeObserver(self, forKeyPath: path)
                }
                watched[key] = nil
                continue
            }
            let before = by[entry.id]
            by[entry.id] = Recording(
                id: entry.id, name: Browser.extensionName(entry.id),
                screen: (before?.screen ?? false) || ExtensionCapture.screen(web),
                camera: (before?.camera ?? false) || web.cameraCaptureState != .none,
                microphone: (before?.microphone ?? false) || web.microphoneCaptureState != .none)
        }
        let now = by.values.sorted { $0.name < $1.name }
        guard now != recordings else { return }
        recordings = now
        // The pill, and the mark on each recording tab (RecordingIndicator).
        RecordingIndicator.shared.update(now.map { RecordingLine(id: $0.id, name: $0.name, what: $0.what) },
                                         pages: now.flatMap { webViews(of: $0.id) })
    }

    /// The pages of an extension that are capturing now: for the mark on
    /// their tabs.
    func webViews(of id: String) -> [WKWebView] {
        watched.values.filter { $0.id == id && ExtensionCapture.capturing($0.web) }.map(\.web)
    }

    private typealias SetDisplay = @convention(c) (AnyObject, Selector, Int, (@convention(block) () -> Void)?) -> Void

    /// Stop: everything the extension is capturing ends, and its pages see
    /// their tracks end.
    func stop(_ id: String) {
        for entry in watched.values where entry.id == id {
            let web = entry.web
            let selector = NSSelectorFromString("_setDisplayCaptureState:completionHandler:")
            if web.responds(to: selector), let method = class_getMethodImplementation(type(of: web), selector) {
                unsafeBitCast(method, to: SetDisplay.self)(web, selector, 0, nil)
            }
            web.setCameraCaptureState(.none, completionHandler: nil)
            web.setMicrophoneCaptureState(.none, completionHandler: nil)
        }
    }

    /// The extension went away: what it records stops, and its ids with it.
    func purge(_ id: String) {
        stop(id)
        grants = grants.filter { $0.value.extensionID != id }
    }

    /// What the bench sees.
    var state: [String: Any] {
        ["grants": grants.count, "last": last,
         "recordings": recordings.map { ["id": $0.id, "what": $0.what] },
         "allowed": ExtensionCapture.allowedIDs,
         "pill": RecordingIndicator.shared.lines.map { "\($0.name) \($0.what)" }]
    }

    // MARK: - test runs

    /// WebKit's pretend camera, microphone and screen, so a test run records
    /// with no hardware and no macOS question. Never outside a test run.
    nonisolated static func mockDevices(_ preferences: WKPreferences) {
        guard Store.testing else { return }
        // WebKit's own pretend prompt stays: turned off, it grants without
        // asking Search at all, and the question is what is being tested.
        for (name, on) in [("_setMockCaptureDevicesEnabled:", true), ("_setGetUserMediaRequiresFocus:", false)] {
            let selector = NSSelectorFromString(name)
            guard preferences.responds(to: selector), let method = class_getMethodImplementation(type(of: preferences), selector) else { continue }
            typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(method, to: Set.self)(preferences, selector, on)
        }
    }
}
