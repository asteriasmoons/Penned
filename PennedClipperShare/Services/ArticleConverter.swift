import Foundation
import WebKit

/// Converts fetched HTML into Penned's editable document nodes.
@MainActor
final class ArticleConverter: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    func convert(_ article: ExtractedArticle) async throws -> [ClipperNode] {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        webView.navigationDelegate = self
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
            self.webView = nil
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.loadHTMLString(article.html, baseURL: article.url)
        }

        let result = try await webView.evaluateJavaScript(Self.conversionScript)
        guard let data = result as? String, let json = data.data(using: .utf8) else {
            throw ShareClipError.articleExtractionFailed("The webpage content could not be converted.")
        }
        let nodes = try JSONDecoder().decode([ClipperNode].self, from: json)
        guard !nodes.isEmpty else {
            throw ShareClipError.articleExtractionFailed("No readable article content was found.")
        }
        return nodes
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    private static let conversionScript = #"""
    (() => {
      const ignored = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','FORM','BUTTON','INPUT','SELECT','TEXTAREA','NAV','ASIDE','IFRAME','SVG']);
      const blocks = new Set(['P','DIV','SECTION','ARTICLE','MAIN','H1','H2','H3','H4','H5','H6','UL','OL','LI','BLOCKQUOTE','PRE','FIGURE','FIGCAPTION','TABLE','HR','DETAILS']);
      let count = 0;
      const paragraph = (content = []) => ({type:'paragraph', content});
      const safeURL = (value, image = false) => {
        if (!value) return null;
        try {
          const url = new URL(value, document.baseURI);
          if ((image ? ['http:','https:'] : ['http:','https:','mailto:','tel:']).includes(url.protocol) && !url.username && !url.password) return url.href;
        } catch (_) {}
        return null;
      };
      function convert(root, depth = 0) {
        if (depth > 40) return [];
        const result = []; let pending = [];
        const flush = () => {
          if (pending.some(n => n.type !== 'text' || n.text.trim())) result.push(paragraph(pending));
          pending = [];
        };
        function inline(node, marks = []) {
          if (++count > 50000) throw Error('Article is too large.');
          if (node.nodeType === 3) {
            const text = node.textContent.replace(/\s+/g, ' ');
            if (text) pending.push({type:'text', text, ...(marks.length ? {marks} : {})});
            return;
          }
          if (node.nodeType !== 1 || ignored.has(node.tagName)) return;
          const tag = node.tagName;
          if (tag === 'BR') { pending.push({type:'hardBreak'}); return; }
          if (tag === 'IMG') {
            const src = safeURL(node.getAttribute('data-src') || node.getAttribute('src'), true);
            if (src) { flush(); result.push({type:'image', attrs:{src, alt:node.getAttribute('alt') || ''}}); }
            return;
          }
          const type = {B:'bold',STRONG:'bold',I:'italic',EM:'italic',U:'underline',S:'strike',DEL:'strike',CODE:'code'}[tag];
          let next = type ? [...marks.filter(m => m.type !== type), {type}] : marks;
          if (tag === 'A') {
            const href = safeURL(node.getAttribute('href'));
            if (href) next = [...next.filter(m => m.type !== 'link'), {type:'link', attrs:{href}}];
          }
          for (const child of node.childNodes) inline(child, next);
        }
        function flow(node, type, attrs) {
          const start = result.length;
          for (const child of node.childNodes) inline(child);
          flush();
          for (let i = start; i < result.length; i++) {
            if (result[i].type === 'paragraph') { result[i].type = type; if (attrs) result[i].attrs = attrs; }
          }
        }
        for (const child of root.childNodes) {
          if (child.nodeType !== 1 || !blocks.has(child.tagName)) { inline(child); continue; }
          flush(); const tag = child.tagName;
          if (ignored.has(tag)) continue;
          if (/^H[1-6]$/.test(tag)) flow(child, 'heading', {level:Number(tag[1])});
          else if (tag === 'DETAILS' && child.querySelector(':scope > summary') && child.querySelector(':scope > ol, :scope > ul')) {
            const summary = child.querySelector(':scope > summary');
            const list = child.querySelector(':scope > ol, :scope > ul');
            const label = summary.textContent.trim();
            if (label) result.push({type:'heading', attrs:{level:3}, content:[{type:'text', text:label}]});
            result.push(...convert({childNodes:[list]}, depth + 1));
          }
          else if (tag === 'P') flow(child, 'paragraph');
          else if (tag === 'FIGCAPTION') flow(child, 'caption');
          else if (tag === 'HR') result.push({type:'divider'});
          else if (tag === 'PRE') {
            const text = child.textContent.replace(/\n$/, '');
            if (text) result.push({type:'codeBlock', content:[{type:'text', text}]});
          } else if (tag === 'UL' || tag === 'OL') {
            const items = [...child.children].filter(el => el.tagName === 'LI').map(el => {
              const content = convert(el, depth + 1);
              const hasContent = nodes => nodes.some(n =>
                (n.type === 'text' && !!n.text?.trim()) ||
                ['image','hardBreak','divider'].includes(n.type) ||
                (n.content && hasContent(n.content))
              );
              if (!hasContent(content)) return null;
              if (content[0]?.type !== 'paragraph') content.unshift(paragraph());
              return {type:'listItem', content};
            }).filter(Boolean);
            if (items.length) result.push({type:tag === 'UL' ? 'bulletList' : 'orderedList', ...(tag === 'OL' ? {attrs:{start:Math.max(1,Number(child.getAttribute('start')) || 1)}} : {}), content:items});
          } else if (tag === 'BLOCKQUOTE') {
            const content = convert(child, depth + 1);
            if (content.length) result.push({type:'blockquote', content});
          } else if (tag === 'TABLE') {
            const rows = [...child.querySelectorAll('tr')].filter(row => row.closest('table') === child).map(row => ({type:'tableRow', content:[...row.children].filter(cell => ['TD','TH'].includes(cell.tagName)).map(cell => {
              const content = convert(cell, depth + 1);
              if (content[0]?.type !== 'paragraph') content.unshift(paragraph());
              return {type:cell.tagName === 'TH' ? 'tableHeader' : 'tableCell', attrs:{colspan:Math.min(100,cell.colSpan || 1),rowspan:Math.min(100,cell.rowSpan || 1)}, content};
            })})).filter(row => row.content.length);
            if (rows.length) result.push({type:'table', content:rows});
          } else result.push(...convert(child, depth + 1));
        }
        flush(); return result;
      }
      const root = document.querySelector('article') || document.querySelector('main') || document.body;
      return JSON.stringify(convert(root));
    })();
    """#
}
