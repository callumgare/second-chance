//
//  IconLabWebView.swift
//  SecondChance
//
//  The Icon Lab page in a web view: `iconlab://` answered by the scheme
//  handler, the engine's events pushed to the page, and the page's
//  messages (open a link, copy text) carried out. The contract is in
//  Packages/IconLab/README.md ("The page's host").

import AppKit
import IconLabAPI
import Logging
import SwiftUI
import WebKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab")

struct IconLabWebView: NSViewRepresentable {
    let host: IconLabHost

    func makeCoordinator() -> IconLabPage { IconLabPage(api: host.api) }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: IconLabPage) {
        coordinator.close()
    }
}

/// One web view showing the page, with everything it needs from the app.
final class IconLabPage: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    private let api: IconLabAPI
    private var events: Task<Void, Never>?
    /// Whether the page has loaded, so events reach it.
    private(set) var loaded = false

    init(api: IconLabAPI) {
        self.api = api
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(IconLabSchemeHandler(api: api), forURLScheme: IconLabSchemeHandler.scheme)
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        // through a weak proxy: the controller holds its handlers strongly
        controller.add(WeakMessageHandler(self), name: "iconLab")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif
        if let home = IconLabSchemeHandler.home { webView.load(URLRequest(url: home)) }
    }

    /// Stops sending events; the window is closing.
    func close() {
        events?.cancel()
        events = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "iconLab")
    }

    // MARK: Events

    /// Sends each of the engine's events to the page, from when it has loaded until the window closes.
    private func startEvents() {
        guard events == nil else { return }
        let api = api
        events = Task { [weak self] in
            for await event in await api.events() {
                guard let self else { return }
                await self.send(event)
            }
        }
    }

    private func send(_ event: Data) async {
        // passed as an argument, not written into the script, so nothing in it needs escaping
        do {
            _ = try await webView.callAsyncJavaScript("window.iconLabHost && window.iconLabHost.event(json)",
                                                      arguments: ["json": String(decoding: event, as: UTF8.self)], contentWorld: .page)
        } catch {
            logger.debug("An event didn't reach the page: \(error)")
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        loaded = true
        startEvents()
    }

    /// The page stays on `iconlab://`; a link anywhere else opens in the person's browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.scheme == IconLabSchemeHandler.scheme || url.scheme == "about" { return decisionHandler(.allow) }
        Self.openOutside(url)
        decisionHandler(.cancel)
    }

    /// A window the page asks for (`target="_blank"`, `window.open`) is the browser's.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { Self.openOutside(url) }
        return nil
    }

    static func openOutside(_ url: URL) {
        guard ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
            logger.warning("Icon Lab's page asked to open \(url.absoluteString), which isn't a web link")
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Messages

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "open":
            if let text = body["url"] as? String, let url = URL(string: text) { Self.openOutside(url) }
        case "copy":
            guard let text = body["text"] as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        default:
            logger.warning("Icon Lab's page sent a message the app doesn't know: \(type)")
        }
    }
}

/// Holds the page weakly, so the content controller doesn't keep it alive.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
