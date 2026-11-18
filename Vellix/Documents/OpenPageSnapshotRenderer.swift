import WebKit
import ImageIO

@MainActor
enum OpenPageSnapshotRenderer {
    static let contentHeight: CGFloat = 460

    static func capture(in webView: WKWebView, header: CGImage, headerHeight: CGFloat) async throws -> OpenPageSnapshots {
        let originalFrame = webView.frame
        defer { webView.frame = originalFrame }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { throw CaptureError.unavailable }
        CGImageDestinationAddImage(destination, header, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.unavailable }
        do {
            // A separate DOM copy owns the preview layout; ProseMirror's DOM observer never
            // receives these pagination mutations and no editor selection/content is changed.
            _ = try await webView.callAsyncJavaScript(#"""
                const root = document.querySelector('#editor-root .tiptap-editor, #editor-root .ProseMirror');
                if (!root) throw new Error('Preview editor is unavailable.');
                const clone = root.cloneNode(true);
                clone.id = 'penned-open-page-flow';
                clone.setAttribute('contenteditable', 'false');
                clone.classList.remove('ProseMirror-focused', 'ProseMirror-hideselection');
                clone.querySelectorAll('.ProseMirror-selectednode').forEach(node => node.classList.remove('ProseMirror-selectednode'));
                const canvases = root.querySelectorAll('canvas');
                clone.querySelectorAll('canvas').forEach((canvas, index) => {
                    if (canvases[index]) canvas.getContext('2d')?.drawImage(canvases[index], 0, 0);
                });
                if (headerHeight > 0) {
                    const asset = new Image(); asset.src = headerSource; await asset.decode();
                    const header = document.createElement('div');
                    header.style.cssText = `width:320px;height:${headerHeight}px;margin:0 0 18px;padding:0;break-inside:auto;box-decoration-break:slice;-webkit-box-decoration-break:slice;background-repeat:no-repeat;background-size:320px ${headerHeight}px;`;
                    header.style.backgroundImage = `url("${headerSource}")`;
                    clone.prepend(header);
                }
                const host = document.createElement('div');
                host.id = 'penned-open-page-capture';
                host.style.cssText = `position:absolute;left:0;top:0;width:680px;height:${height}px;overflow:hidden;pointer-events:none;`;
                const style = document.createElement('style');
                style.id = 'penned-open-page-capture-style';
                style.textContent = `
                    #editor-root { visibility:hidden !important; }
                    #penned-open-page-flow {
                        display:block !important; position:relative !important; margin:0 !important;
                        width:320px !important; min-width:320px !important; max-width:320px !important;
                        height:${height}px !important; min-height:0 !important; max-height:${height}px !important;
                        padding:0 !important; overflow:visible !important;
                        columns:320px auto !important; column-gap:40px !important; column-fill:auto !important;
                        column-rule:none !important; direction:ltr !important;
                    }
                    #penned-open-page-flow > :is([data-vellix-page-break], [data-type="pageBreak"], [data-page-break]) {
                        break-before:column !important; height:0.1px !important;
                        min-height:0 !important; margin:0 !important; padding:0 !important;
                    }
                    #penned-open-page-flow :is(img, tr, .vellix-page-card-inline, .vellix-plain-callout-row) {
                        break-inside:avoid-column;
                    }
                    #penned-open-page-flow .vellix-table-wrapper { overflow:visible !important; }
                    #penned-open-page-flow .penned-list-grid {
                        display:block; overflow:visible;
                        -webkit-box-decoration-break:clone; box-decoration-break:clone;
                    }
                    #penned-open-page-flow .penned-list-grid-row { break-inside:avoid-column; }
                    #penned-open-page-flow .penned-list-grid-row + .penned-list-grid-row {
                        margin-top:var(--lg-gap, 6px);
                    }
                `;
                document.head.appendChild(style);
                host.appendChild(clone); document.body.appendChild(host);
                await document.fonts.ready;
                await Promise.all(Array.from(clone.querySelectorAll('img')).map(image => image.decode().catch(() => {})));
                clone.getBoundingClientRect();
                return true;
                """#, arguments: ["headerSource": "data:image/png;base64," + (png as Data).base64EncodedString(),
                                    "headerHeight": Double(headerHeight), "height": Double(contentHeight)],
                in: nil, contentWorld: .page)
            // Keep both columns inside WebKit's painting viewport, not just the PDF crop.
            webView.frame = CGRect(x: originalFrame.minX, y: originalFrame.minY, width: 680, height: originalFrame.height)
            _ = try await webView.callAsyncJavaScript("document.getElementById('penned-open-page-flow').getBoundingClientRect(); return true;",
                arguments: [:], in: nil, contentWorld: .page)
            let captureRect = CGRect(x: 0, y: 0, width: 680, height: contentHeight)
            let configuration = WKPDFConfiguration()
            configuration.rect = captureRect
            configuration.allowTransparentBackground = true
            let data = try await webView.pdf(configuration: configuration)
            guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1),
                  let context = CGContext(data: nil, width: 1360, height: Int(contentHeight * 2), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.unavailable }
            context.clear(CGRect(x: 0, y: 0, width: 1360, height: contentHeight * 2))
            context.scaleBy(x: 2, y: 2)
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: captureRect, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let image = context.makeImage(),
                  let left = image.cropping(to: CGRect(x: 0, y: 0, width: 640, height: contentHeight * 2)),
                  let right = image.cropping(to: CGRect(x: 720, y: 0, width: 640, height: contentHeight * 2)) else { throw CaptureError.unavailable }
            await cleanUp(webView)
            return OpenPageSnapshots(left: left, right: right)
        } catch {
            await cleanUp(webView)
            throw error
        }
    }

    private static func cleanUp(_ webView: WKWebView) async {
        _ = try? await webView.evaluateJavaScript("document.getElementById('penned-open-page-capture')?.remove(); document.getElementById('penned-open-page-capture-style')?.remove();")
    }

    private enum CaptureError: Error { case unavailable }
}
