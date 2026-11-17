import Foundation
import UIKit
import WebKit

/// Drawing an artifact page the way pai's web client does (`frameDocument` in `pai/src/protocol/artifact.ts`): the
/// page with pai's CSP, the chat's colours as CSS variables, a storage stand-in and a height reporter put in front of
/// it, loaded as a string with no base URL in a web view that keeps nothing (no cookies, no storage) and reaches
/// nothing (the CSP shuts the network, a navigation away is refused). The only message the page can send the app is
/// its height, a finite number, from its own main frame.
public enum PaiArtifacts {
    /// Taller than this a frame is clamped, with Expand under it.
    public static let maxHeight: CGFloat = 560
    /// A frame's height before its page has reported one.
    public static let placeholderHeight: CGFloat = 120

    public static let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; form-action 'none'; base-uri 'none'"

    static let heightMessage = "paiArtifactHeight"

    public struct Theme: Equatable {
        public let dark: Bool
        public let ink: UIColor
        public let muted: UIColor
        public let surface: UIColor
        public let line: UIColor
        public let accent: UIColor

        public init(dark: Bool, ink: UIColor, muted: UIColor, surface: UIColor, line: UIColor, accent: UIColor) {
            self.dark = dark
            self.ink = ink
            self.muted = muted
            self.surface = surface
            self.line = line
            self.accent = accent
        }
    }

    /// Swaps each storage an opaque origin may not touch for an in-memory one, before any other script runs.
    private static let storageShim = #"for(const k of["localStorage","sessionStorage"]){try{window[k].length}catch{const m=new Map(),s={getItem:x=>m.has(String(x))?m.get(String(x)):null,setItem:(x,v)=>{m.set(String(x),String(v))},removeItem:x=>{m.delete(String(x))},clear:()=>m.clear(),key:i=>[...m.keys()][i]??null,get length(){return m.size}};try{Object.defineProperty(window,k,{value:s,configurable:true})}catch{}}}"#

    private static func css(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let c = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        return a >= 0.999 ? String(format: "#%02x%02x%02x", c(r), c(g), c(b)) : "rgba(\(c(r)),\(c(g)),\(c(b)),\(String(format: "%.3f", a)))"
    }

    /// The document the frame loads: the CSP, theme, storage shim and height reporter first, after a leading doctype.
    public static func document(html: String, theme: Theme) -> String {
        let scheme = theme.dark ? "dark" : "light"
        let vars = [
            "--pai-ink:\(css(theme.ink))",
            "--pai-muted:\(css(theme.muted))",
            "--pai-surface:\(css(theme.surface))",
            "--pai-line:\(css(theme.line))",
            "--pai-accent:\(css(theme.accent))",
            "--pai-font:-apple-system,system-ui,sans-serif",
        ].joined(separator: ";")
        let post = "parent.postMessage({type:\"pai-artifact-height\",height:h},\"*\");try{window.webkit.messageHandlers.\(heightMessage).postMessage(h)}catch{}"
        let head = "<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"
            + "<meta name=\"color-scheme\" content=\"\(scheme)\">"
            + "<style>:root{color-scheme:\(scheme);\(vars)}html,body{margin:0;background:transparent}body{color:var(--pai-ink,CanvasText);font:14px/1.45 var(--pai-font,system-ui,sans-serif);-webkit-text-size-adjust:100%}</style>"
            + "<script>\(storageShim);document.documentElement.dataset.theme=\"\(scheme)\";(()=>{let last=0;const post=()=>{const h=Math.ceil(Math.max(document.body?document.body.scrollHeight:0,document.documentElement.getBoundingClientRect().height));if(h!==last){last=h;\(post)}};addEventListener(\"load\",post);addEventListener(\"DOMContentLoaded\",()=>{post();new ResizeObserver(post).observe(document.body)})})()</script>"
        let ns = html as NSString
        if let doctype = try? NSRegularExpression(pattern: "^\\u{FEFF}?\\s*<!doctype[^>]*>", options: [.caseInsensitive]).firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) {
            return ns.substring(with: doctype.range) + head + ns.substring(from: doctype.range.upperBound)
        }
        return head + html
    }

    // MARK: Pages and heights

    private static let lock = NSLock()
    private static var pages: [String: String] = [:]
    private static var heights: [String: CGFloat] = [:]
    private static var expanded: Set<String> = []

    /// A page's own height as it last reported it.
    public static func height(_ file: String) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return heights[file]
    }

    /// Records a reported height; true when it differs from the one known, so the message is laid out again.
    static func setHeight(_ file: String, _ height: CGFloat) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let old = heights[file]
        heights[file] = height
        return old.map { abs($0 - height) >= 1 } ?? true
    }

    public static func isExpanded(_ file: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return expanded.contains(file)
    }

    public static func toggleExpanded(_ file: String) {
        lock.lock()
        if expanded.contains(file) { expanded.remove(file) } else { expanded.insert(file) }
        lock.unlock()
    }

    /// The height a frame is drawn at: the page's, clamped unless expanded.
    public static func frameHeight(_ file: String) -> (height: CGFloat, clamped: Bool) {
        let natural = max(24, height(file) ?? placeholderHeight)
        if natural > maxHeight && !isExpanded(file) { return (maxHeight, true) }
        return (natural, natural > maxHeight)
    }

    /// The page's HTML, read once from the box (`GET /attachments/<file>`).
    @available(iOS 16.0, *)
    static func page(_ file: String) async throws -> String {
        lock.lock()
        let cached = pages[file]
        lock.unlock()
        if let cached { return cached }
        let data = try await PaiClient().data("/attachments/\(file)")
        guard data.count <= PaiArtifact.maxBytes else { throw PaiClientError(message: "Artifact is over 2 MB") }
        let html = String(decoding: data, as: UTF8.self)
        lock.lock()
        pages[file] = html
        lock.unlock()
        return html
    }
}

/// One artifact's live page. Its owner sets its frame; the view reports the page's height through `onHeight`.
public final class PaiArtifactView: UIView, WKNavigationDelegate {
    /// The handler the user content controller holds, so the web view does not keep its view alive.
    private final class HeightHandler: NSObject, WKScriptMessageHandler {
        weak var owner: PaiArtifactView?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let number = message.body as? NSNumber else { return }
            let height = CGFloat(number.doubleValue)
            guard height.isFinite, height >= 0, height < 100_000 else { return }
            owner?.reported(height)
        }
    }

    private let webView: WKWebView
    private let handler = HeightHandler()
    private let status = UILabel()
    private var loaded: (file: String, theme: PaiArtifacts.Theme)?
    private var task: Task<Void, Never>?
    private var file: String?

    /// The page's height changed: (file, height).
    public var onHeight: ((String, CGFloat) -> Void)?

    public override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.dataDetectorTypes = []
        configuration.userContentController.add(handler, name: PaiArtifacts.heightMessage)
        if #available(iOS 14.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        self.webView = WKWebView(frame: CGRect(origin: .zero, size: frame.size), configuration: configuration)
        super.init(frame: frame)
        self.handler.owner = self
        self.clipsToBounds = true
        self.webView.isOpaque = false
        self.webView.backgroundColor = .clear
        self.webView.scrollView.backgroundColor = .clear
        self.webView.scrollView.isScrollEnabled = false
        self.webView.scrollView.bounces = false
        self.webView.scrollView.contentInsetAdjustmentBehavior = .never
        self.webView.navigationDelegate = self
        if #available(iOS 16.4, *) {
            self.webView.isInspectable = false
        }
        self.addSubview(self.webView)
        self.status.font = UIFont.systemFont(ofSize: 13)
        self.status.textAlignment = .center
        self.status.numberOfLines = 2
        self.addSubview(self.status)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.task?.cancel()
        self.webView.configuration.userContentController.removeScriptMessageHandler(forName: PaiArtifacts.heightMessage)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        self.webView.frame = self.bounds
        self.status.frame = self.bounds.insetBy(dx: 12, dy: 8)
    }

    /// Shows `file`'s page in `theme`; the same page in the same look is left as it is.
    public func load(file: String, theme: PaiArtifacts.Theme) {
        if let loaded, loaded.file == file, loaded.theme == theme { return }
        self.loaded = (file, theme)
        self.file = file
        self.status.textColor = theme.muted
        self.status.text = "Loading…"
        self.status.isHidden = false
        self.task?.cancel()
        guard #available(iOS 16.0, *) else {
            self.status.text = "Needs iOS 16"
            return
        }
        self.task = Task { @MainActor [weak self] in
            do {
                let html = try await PaiArtifacts.page(file)
                guard let self, !Task.isCancelled, self.file == file else { return }
                self.webView.loadHTMLString(PaiArtifacts.document(html: html, theme: theme), baseURL: nil)
            } catch {
                guard let self, !Task.isCancelled, self.file == file else { return }
                self.loaded = nil
                self.status.text = "Could not load the page"
            }
        }
    }

    private func reported(_ height: CGFloat) {
        guard let file = self.file else { return }
        self.status.isHidden = true
        if PaiArtifacts.setHeight(file, height) {
            self.onHeight?(file, height)
        }
    }

    // MARK: WKNavigationDelegate

    /// Only the page itself loads: a link, a form or a script sending the frame elsewhere is refused.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url?.absoluteString ?? ""
        let isPage = navigationAction.navigationType == .other && (url.isEmpty || url == "about:blank" || url.hasPrefix("about:"))
        let isSubframe = navigationAction.targetFrame.map { !$0.isMainFrame } ?? false
        decisionHandler(isPage || (isSubframe && (url.hasPrefix("about:") || url.hasPrefix("data:"))) ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.status.isHidden = true
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let previous = self.loaded
        self.loaded = nil
        if let previous {
            self.load(file: previous.file, theme: previous.theme)
        }
    }
}
