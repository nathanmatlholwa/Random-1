import SwiftUI
import WebKit

/// Text that may contain LaTeX ($...$ and $$...$$). Rendered with KaTeX in a web view that sizes itself to the content.
/// KaTeX loads from a CDN, so equations need an internet connection. Without it the raw LaTeX text still shows.
struct MathText: View {
    let text: String
    var fontSize: CGFloat = 17
    @State private var height: CGFloat = 28

    var body: some View {
        MathWebView(text: text, fontSize: fontSize, height: $height)
            .frame(height: height)
            .accessibilityLabel(text)
    }
}

private struct MathWebView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "height")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        context.coordinator.load(text: text, fontSize: fontSize, into: web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(text: text, fontSize: fontSize, into: web)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "height")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: MathWebView
        private var loadedKey: String?

        init(_ parent: MathWebView) { self.parent = parent }

        func load(text: String, fontSize: CGFloat, into web: WKWebView) {
            let key = "\(fontSize)|\(text)"
            guard key != loadedKey else { return }
            loadedKey = key
            web.loadHTMLString(MathWebView.html(for: text, fontSize: fontSize),
                               baseURL: URL(string: "https://cdnjs.cloudflare.com/"))
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let raw = (message.body as? NSNumber)?.doubleValue ?? 0
            guard raw > 0 else { return }
            let newHeight = CGFloat(raw)
            DispatchQueue.main.async {
                if abs(self.parent.height - newHeight) > 0.5 { self.parent.height = max(newHeight, 24) }
            }
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func html(for text: String, fontSize: CGFloat) -> String {
        let body = escape(text)
        return #"""
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/KaTeX/0.16.9/katex.min.css">
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; padding: 2px 0; font: \#(fontSize)px/1.55 -apple-system, system-ui, sans-serif; color: CanvasText; background: transparent; white-space: pre-wrap; overflow-wrap: anywhere; }
        .katex { font-size: 1.05em; }
        .katex-display { overflow-x: auto; overflow-y: hidden; }
        </style>
        <script src="https://cdnjs.cloudflare.com/ajax/libs/KaTeX/0.16.9/katex.min.js"></script>
        <script src="https://cdnjs.cloudflare.com/ajax/libs/KaTeX/0.16.9/contrib/auto-render.min.js"></script>
        </head><body><div id="c">\#(body)</div>
        <script>
        function post() {
          var h = document.getElementById('c').getBoundingClientRect().height + 4;
          window.webkit.messageHandlers.height.postMessage(h);
        }
        window.addEventListener('load', function () {
          try {
            renderMathInElement(document.getElementById('c'), {
              delimiters: [
                { left: '$$', right: '$$', display: true },
                { left: '\\[', right: '\\]', display: true },
                { left: '\\(', right: '\\)', display: false },
                { left: '$', right: '$', display: false }
              ],
              throwOnError: false
            });
          } catch (e) {}
          post(); setTimeout(post, 250); setTimeout(post, 900);
        });
        if (window.ResizeObserver) { new ResizeObserver(post).observe(document.getElementById('c')); }
        </script>
        </body></html>
        """#
    }
}
