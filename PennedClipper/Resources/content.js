(() => {
    if (globalThis.PennedClipperExtract) return;
    const blockTags = new Set(["P", "DIV", "SECTION", "ARTICLE", "MAIN", "HEADER", "FOOTER", "H1", "H2", "H3", "H4", "H5", "H6", "UL", "OL", "LI", "BLOCKQUOTE", "PRE", "FIGURE", "FIGCAPTION", "TABLE", "HR", "DL", "DT", "DD", "DETAILS"]);
    const ignored = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "FORM", "BUTTON", "INPUT", "SELECT", "TEXTAREA", "NAV"]);
    function url(value, base, image = false) {
        if (!value) return null;
        if (image && /^data:image\/(png|jpeg|gif|webp);base64,/i.test(value)) return value;
        try {
            const result = new URL(value, base);
            if ((image ? ["https:", "http:"] : ["https:", "http:", "mailto:", "tel:"]).includes(result.protocol) && !result.username && !result.password) return result.href;
        } catch {}
        return null;
    }
    function convert(root, base) {
        let count = 0;
        const paragraph = (content = []) => ({ type: "paragraph", content });
        function blocks(parent, depth = 0) {
            if (depth > 40) throw new Error("This article has deeply nested content that cannot be clipped safely.");
            const result = []; let pending = [];
            const flush = () => {
                if (pending.some(node => node.type !== "text" || node.text.trim())) result.push(paragraph(pending));
                pending = [];
            };
            function inline(node, marks = []) {
                if (++count > 50_000) throw new Error("This article is too large to clip safely.");
                if (node.nodeType === Node.TEXT_NODE) {
                    const text = node.textContent.replace(/\s+/g, " ");
                    if (text) pending.push({ type: "text", text, ...(marks.length ? { marks } : {}) });
                    return;
                }
                if (node.nodeType !== Node.ELEMENT_NODE || ignored.has(node.tagName)) return;
                const tag = node.tagName;
                if (tag === "BR") { pending.push({ type: "hardBreak" }); return; }
                if (tag === "IMG") {
                    const src = url(node.getAttribute("data-penned-source") || node.getAttribute("src"), base, true);
                    if (src) { flush(); result.push({ type: "image", attrs: { src, alt: node.getAttribute("alt") || "" } }); }
                    return;
                }
                const mark = ({ B: "bold", STRONG: "bold", I: "italic", EM: "italic", U: "underline", S: "strike", DEL: "strike", STRIKE: "strike", CODE: "code" })[tag];
                let next = mark ? [...marks.filter(item => item.type !== mark), { type: mark }] : marks;
                if (tag === "A") {
                    const href = url(node.getAttribute("href"), base);
                    if (href) next = [...marks.filter(item => item.type !== "link"), { type: "link", attrs: { href } }];
                }
                for (const child of node.childNodes) inline(child, next);
            }
            function flow(element, type, attrs) {
                const start = result.length;
                for (const child of element.childNodes) inline(child);
                flush();
                for (let index = start; index < result.length; index++) {
                    if (result[index].type === "paragraph") { result[index].type = type; if (attrs) result[index].attrs = attrs; }
                }
            }
            for (const child of parent.childNodes) {
                if (child.nodeType !== Node.ELEMENT_NODE || !blockTags.has(child.tagName)) { inline(child); continue; }
                flush(); const tag = child.tagName;
                if (ignored.has(tag)) continue;
                if (/^H[1-6]$/.test(tag)) flow(child, "heading", { level: Number(tag[1]) });
                else if (tag === "DETAILS" && child.querySelector(":scope > summary") && child.querySelector(":scope > ol, :scope > ul")) {
                    const summary = child.querySelector(":scope > summary");
                    const list = child.querySelector(":scope > ol, :scope > ul");
                    const label = summary.textContent.trim();
                    if (label) result.push({type:"heading", attrs:{level:3}, content:[{type:"text", text:label}]});
                    result.push(...blocks({childNodes:[list]}, depth + 1));
                }
                else if (tag === "P" || tag === "DT" || tag === "DD") flow(child, "paragraph");
                else if (tag === "FIGCAPTION") flow(child, "caption");
                else if (tag === "HR") result.push({ type: "divider" });
                else if (tag === "PRE") {
                    const code = child.querySelector("code"), text = child.textContent.replace(/\n$/, "");
                    if (text) result.push({ type: "codeBlock", attrs: { language: (code?.className || "").match(/language-([\w+-]+)/)?.[1] || "" }, content: [{ type: "text", text }] });
                } else if (tag === "UL" || tag === "OL") {
                    const items = [...child.children].filter(element => element.tagName === "LI");
                    const tasks = items.some(item => item.querySelector(":scope > input[type=checkbox], :scope > label > input[type=checkbox]"));
                    const content = items.map(item => {
                        const content = blocks(item, depth + 1);
                        if (content[0]?.type !== "paragraph") content.unshift(paragraph());
                        return { type: tasks ? "taskItem" : "listItem", ...(tasks ? { attrs: { checked: !!item.querySelector("input[type=checkbox]")?.checked } } : {}), content };
                    });
                    if (content.length) result.push({ type: tasks ? "taskList" : tag === "OL" ? "orderedList" : "bulletList", ...(tag === "OL" && !tasks ? { attrs: { start: Math.max(1, Number(child.getAttribute("start")) || 1) } } : {}), content });
                } else if (tag === "BLOCKQUOTE") {
                    const content = blocks(child, depth + 1);
                    if (content.length) result.push({ type: "blockquote", content });
                } else if (tag === "TABLE") {
                    const rows = [...child.rows].filter(row => row.closest("table") === child).map(row => ({ type: "tableRow", content: [...row.cells].map(cell => {
                        const content = blocks(cell, depth + 1);
                        if (content[0]?.type !== "paragraph") content.unshift(paragraph());
                        return { type: cell.tagName === "TH" ? "tableHeader" : "tableCell", attrs: { colspan: Math.min(100, cell.colSpan || 1), rowspan: Math.min(100, cell.rowSpan || 1) }, content };
                    }) })).filter(row => row.content.length);
                    if (rows.length) result.push({ type: "table", content: rows });
                } else result.push(...blocks(child, depth + 1));
            }
            flush(); return result;
        }
        return blocks(root);
    }
    globalThis.PennedClipperExtract = () => {
        try {
            if (document.getElementsByTagName("*").length > 100_000) throw new Error("This webpage is too large. Open its article-only view and try again.");
            const clone = document.cloneNode(true), originals = document.querySelectorAll("img"), copies = clone.querySelectorAll("img");
            originals.forEach((image, index) => {
                const copy = copies[index];
                if ((image.naturalWidth && image.naturalWidth <= 2) || (image.naturalHeight && image.naturalHeight <= 2)) { copy.remove(); return; }
                const source = image.getAttribute("data-src") || image.getAttribute("data-original") || image.currentSrc || image.src;
                const absolute = url(source, document.baseURI, true);
                if (absolute) { copy.setAttribute("data-penned-source", absolute); copy.setAttribute("src", absolute); }
            });
            const article = new Readability(clone, { charThreshold: 80, maxElemsToParse: 100_000, keepClasses: false }).parse();
            if (!article?.content || !article.textContent?.trim()) throw new Error("No readable article was found on this page. Open the full article and retry.");
            // Readability HTML is never inserted into the live page or clipping interface.
            const parsed = new DOMParser().parseFromString(article.content, "text/html");
            const content = convert(parsed.body, document.baseURI);
            if (!content.length) throw new Error("This article has no supported editable content.");
            const sourceURL = new URL(location.href); sourceURL.hash = "";
            const metadataImage = document.querySelector('meta[property="og:image"], meta[name="twitter:image"]')?.content;
            const articleImage = parsed.querySelector("img[data-penned-source], img[src]");
            const thumbnailURL = url(metadataImage, document.baseURI, true)
                || url(articleImage?.getAttribute("data-penned-source") || articleImage?.getAttribute("src"), document.baseURI, true);
            return { title: article.title || document.title, author: article.byline || "", siteName: article.siteName || location.hostname,
                sourceURL: sourceURL.href, content, thumbnailURL, excerpt: article.excerpt || "" };
        } catch (error) { return { error: error.message || "The article could not be extracted." }; }
    };
})();
