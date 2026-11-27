import { insertionBookmark, insertionRange } from "./existing-event-insertion.js";
import { linkedCalendarEventJSON, updateLinkedCalendarEventJSON } from "./linked-calendar-event-model.js";
import { insertionPanelDepth } from "./week-strip-insertion.js";
import { ensureCalendarInsertionSelection, selectionInsideCalendar, activeCalendarTarget, forgetActiveCalendar, appendParagraphToCalendarDate } from "./calendar-insertion-target.js";
import { LinkedCalendarEvent } from "./linked-calendar-event.js";
// Bundle entry for the Vellix TipTap editor.
//
// Same bridge shape as Lurelia:
//   Swift -> JS   window.tiptapCommand(name, args)
//   JS -> Swift   webkit.messageHandlers.tiptap.postMessage({ kind, payload })

import { Editor, Extension, Node, getRenderedAttributes, mergeAttributes } from "@tiptap/core";
import { AllSelection, NodeSelection, Plugin, PluginKey, TextSelection, Selection, SelectionRange } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import { DOMSerializer, Fragment, Slice } from "@tiptap/pm/model";
import { canSplit, ReplaceStep, Transform, Step, StepResult } from "@tiptap/pm/transform";
import { keydownHandler } from "@tiptap/pm/keymap";
import { closeHistory, isHistoryTransaction } from "@tiptap/pm/history";
import { createTextColor, textColorDependencies } from "./text-color.js";
import StarterKit from "@tiptap/starter-kit";
import { ListItem } from "@tiptap/extension-list";
import Blockquote from "@tiptap/extension-blockquote";
import Code from "@tiptap/extension-code";
import Placeholder from "@tiptap/extension-placeholder";
import { createTemplateComponents } from "./template-components.js";
import { createDocumentTags, taggedInlineContent } from "./document-tags.js";
import { createAttachments, containsAttachments, attachmentURL } from "./attachments.js";
import { freshClipboardBlockIDs } from "./block-clipboard-ids.js";
import { clipSource, clipPreview } from "./clip-source.js";
import TaskItem from "@tiptap/extension-task-item";
import TaskList from "@tiptap/extension-task-list";
import { PROPERTY_KINDS, normalizeProperty, propertyText } from "./inline-properties.js";
import { inlinePropertyNode } from "./inline-property-node.js";
import { createCaretTracking } from "./caret-tracking.js";
import { createCalloutListBackspace } from "./callout-list-backspace.js";
import { CaretSlots, activeColumnInsertion, beginCaretInsertion, blockGapAtPoint, clearUnusedCaretSlots,
  documentWithoutUnusedCaretSlots, endCaretInsertion, hasCaretInsertion, placeCaretInSlot, resetCaretInsertions, restoreCaretInsertion,
  trailingNumberedLine, separateTrailingNumberedLine, placeCaretOnTrailingNumberedLine, pageBreakGapAtPoint } from "./caret-slots.js";
import { calloutRow, CalloutRowCleanup, calloutWidthAttribute, LegacyToggleFollowers } from "./resizable-callouts.js";
import { calloutRowMetrics } from "./callout-layout.js";
import { unwrapRetiredColumns } from "./retired-column-content.js";
import { createChecklistItem, createTaskIntegration, taskCommand, taskMenuContext } from "./document-tasks.js";
import { pageReferenceNode, setPageReferences, normalizePageReferenceStarters } from "./page-reference-node.js";
import { collectionNode, setCollections, setNativeCollectionHeight, iconAssetCSSVariable } from "./collection-node.js";
import { createListGrid } from "./list-grid.js";
import { createCodeBlocks } from "./code-block.js";
import { createTabs } from "./tabs.js";
import { WeekStrip, WeekDayPanel, navigateWeekStripJSON, weekStripJSON } from "./week-strip.js";
import { updateWeekStripAppearanceJSON } from "./week-strip-settings.js";
import { bindNonEditingTap } from "./editor-control-activation.js";
import { createMinimalFields } from "./minimal-fields.js";
import { createInformationCard, informationCardJSON } from "./information-card.js";
import { GRID_CARD_DEFAULTS, gridCardSettings, gridCardDOMAttributes, newGridCard } from "./grid-card.js";
import { gridCardSettingDifferences, gridCardSettingTypes } from "./grid-card-diagnostics.js";
import { ICON_CALLOUT_DEFAULTS, iconCalloutNode, iconCalloutSettings, iconCalloutGlyph, iconCalloutImage, plainCalloutSettings, plainCalloutSurface } from "./icon-callout.js";
import { createLabelHeading, labelLevel, labelSettings, updateHeadingLabel } from "./heading-label.js";
import { createDocumentLinks, richLinkLayout, richLinkMetadata, webLinkURL } from "./document-links.js";
import { nativeCollectionRegions } from "./native-collection-regions.js";
import { prepareDocumentPresentation } from "./presentation-ready.js";
import { repaintScallopedLabels } from "./scalloped-label.js";
import { applyEditorAppearance } from "./appearance.js";
import { createBlockActions } from "./block-actions.js";
import { Caption } from "./caption.js";
import { blockFontAttribute, blockFontFamilies } from "./block-font.js";
import { changedRanges, createNodeIndex, updateNodeIndex, inlineTextEdit } from "./incremental-nodes.js";
import { dividerStyle as normalizedDividerStyle, dividerColor, dividerPhoto, dividerDOM, washiTapeSize } from "./divider.js";
import "./structured-placeholders.js";
import "./vendor/table-library.js";
import "./table-formulas.js";
import "./vellix-tables.js";

const DEFAULT_CALLOUT_ICON = "sparkle";
const DEFAULT_CALLOUT_COLOR = "#ffffff";
const DEFAULT_BLOCKQUOTE_COLOR = "#ffffff";
const DEFAULT_DIVIDER_STYLE = "thinLine";
const CHECKLIST_DOUBLE_TAP_MS = 300;
const DIVIDER_STYLES = {
  dottedCircles: {
    title: "Dotted Circles",
    detail: "Circle dot divider",
    icon: "listcircle",
  },
  thickLine: {
    title: "Thick Line",
    detail: "Bold rounded divider",
    icon: "minuswavy",
  },
  thinLine: {
    title: "Thin Line",
    detail: "Minimal divider",
    icon: "minuswavy",
  },
  fourCircles: {
    title: "Four Circles",
    detail: "Centered circle divider",
    icon: "listcircle",
  },
  washiTape: {
    title: "Washi Tape",
    detail: "Photo tape with notched ends",
    icon: "imagesign",
  },
};
const vellixIconAssets = new Map();
const selectionHighlightPluginKey = new PluginKey("vellixTextSelectionHighlight");
const UnderlineableCode = Code.extend({
  excludes: "",
});
const PennedListItem = ListItem.extend({
  content: "(paragraph | heading | caption) block*",
  addKeyboardShortcuts() {
    const shortcuts = this.parent?.() || {};
    return { ...shortcuts, Enter: () => {
      const { $from } = this.editor.state.selection;
      if ($from.parent.type.name !== "heading" || !$from.parent.content.size ||
          $from.depth < 2 || $from.node(-1).type.name !== this.name) return shortcuts.Enter?.() || false;
      const level = $from.parent.attrs.level;
      return this.editor.chain().splitListItem(this.name).command(({ tr }) => {
        const next = tr.selection.$from;
        if (!next.parent.isTextblock) return false;
        tr.setNodeMarkup(next.before(), this.editor.schema.nodes.heading,
          { ...next.parent.attrs, id: id(), level });
        return true;
      }).run();
    } };
  },
});
const SLASH_ITEMS = [
  { key: "templates", title: "Templates", detail: "Browse and insert a template", icon: "copy" },
  { key: "collection", title: "Collection", detail: "Document Table and Gallery views", icon: "linedpages" },
  { key: "table", title: "Table", detail: "Rows, columns and formulas", icon: "blackcal" },
  { key: "listGrid", title: "List Grid", detail: "Labeled rows in a grid", icon: "blackcal" },
  { key: "tabs", title: "Tabs", detail: "Tabbed sections of content", icon: "window" },
  { key: "moodBar", title: "Mood Bar", detail: "Interactive seven-mood slider", icon: "happy" },
  { key: "countdown", title: "Countdown", detail: "Count down to a date and time", icon: "clockwavy" },
  { key: "calculator", title: "Calculator", detail: "Interactive calculator", icon: "blackcal" },
  { key: "fields", title: "Fields", detail: "Minimal label and value records", icon: "linedpages" },
  { key: "informationCard", title: "Information Card", detail: "Title, description and details", icon: "linedpages" },
  { key: "heading1", title: "Title", detail: "H1, 24px", icon: "h1" },
  { key: "heading2", title: "Subtitle", detail: "H2, 21px", icon: "h2" },
  { key: "heading3", title: "Heading", detail: "H3, 18px", icon: "h3" },
  { key: "heading4", title: "Subheading", detail: "H4, 16px", icon: "h4" },
  { key: "paragraph", title: "Paragraph", detail: "Plain text", icon: "linedpages" },
  { key: "caption", title: "Caption", detail: "Smaller supporting text", icon: "linedpages" },
  { key: "nestedPage", title: "Page", detail: "A page inside this document", icon: "linedpages" },
  { key: "pageCard", title: "Card", detail: "A page with a custom card preview", icon: "linedpages" },
  { key: "toggleListItem", title: "Toggle", detail: "Collapsible block", icon: "chevright" },
  { key: "iconCallout", title: "Icon Callout", detail: "Icon and highlighted text", icon: "sparkle" },
  { key: "plainCallout", title: "Plain Callout", detail: "Highlighted text", icon: "linedpages" },
  { key: "gridCard", title: "Grid Cards", detail: "Independent icon and text cards", icon: "gridboard" },
  { key: "quote", title: "Blockquote", detail: "Quoted text", icon: "quote" },
  { key: "checkListItem", title: "Checklist", detail: "Hollow circle tasks", icon: "checkwavy" },
  { key: "bulletListItem", title: "Bullet List", detail: "Bulleted items", icon: "listcircle" },
  { key: "numberedListItem", title: "Numbered List", detail: "Ordered items", icon: "numcal" },
  { key: "underline", title: "Underline", detail: "Underlined text", icon: "linesbmark" },
  { key: "inlineCode", title: "Inline Code", detail: "Inline code text", icon: "codewindow" },
  { key: "codeBlock", title: "Code Block", detail: "Standalone syntax-highlighted code", icon: "codewindow" },
  { key: "pageBreak", title: "Page Break", detail: "Page boundary", icon: "pagefold" },
  ...PROPERTY_KINDS.map(({ kind, title, icon }) => ({
    key: `property:${kind}`, title: `${title} Property`, detail: "Named property row", icon,
  })),
  ...Object.entries(DIVIDER_STYLES).map(([style, item]) => ({
    key: `divider:${style}`,
    title: item.title,
    detail: item.detail,
    icon: item.icon,
  })),
];

function postToSwift(kind, payload = {}) {
  try {
    window.webkit?.messageHandlers?.tiptap?.postMessage({ kind, payload });
    if (kind === "snapshot" && pendingUpdateDoc && pendingUpdateDoc === snapshotDocument && payload === cachedSnapshot) {
      cancelScheduledUpdate();
    }
  } catch (_e) {
    console.log("[Vellix TipTap]", kind, payload);
  }
}

function traceDiag(label, details = {}) {
  if (window.PENNED_EDITOR_DIAGNOSTICS !== true) return;
  const message = JSON.stringify({ label, ...details });
  console.log(`[Vellix TipTap TRACE] ${message}`);
  postToSwift("diag", { message });
}

function id() {
  return crypto.randomUUID();
}

function isRecord(value) {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function nodeId(node) {
  const value = node?.attrs?.id;
  return typeof value === "string" && value.trim() ? value.trim() : id();
}

function normalizedIconName(icon) {
  return String(icon || DEFAULT_CALLOUT_ICON).trim() || DEFAULT_CALLOUT_ICON;
}

function iconSource(icon, tint = DEFAULT_CALLOUT_COLOR, size = 22) {
  const cleanIcon = normalizedIconName(icon);
  const cleanTint = String(tint || DEFAULT_CALLOUT_COLOR).trim();
  const registeredSource = vellixIconAssets.get(cleanIcon);
  if (registeredSource && cleanTint.toLowerCase() === DEFAULT_CALLOUT_COLOR.toLowerCase()) {
    return registeredSource;
  }

  const params = new URLSearchParams({
    tint: cleanTint,
    size: String(size),
  });
  return `vellix-icon://asset/${encodeURIComponent(cleanIcon)}?${params.toString()}`;
}

function setRegisteredIconCSSVariable(icon, src) {
  const variableName = iconAssetCSSVariable(normalizedIconName(icon));
  document.documentElement.style.setProperty(variableName, cssBackgroundImageSource(src));
}

function cssBackgroundImageSource(src) {
  return `url("${String(src || "").replace(/["\\\n\r]/g, "")}")`;
}

let calloutIconProbeSerial = 0;
const calloutIconSerials = new WeakMap();

function serialForElement(element) {
  if (!element) return null;
  if (!calloutIconSerials.has(element)) {
    calloutIconProbeSerial += 1;
    calloutIconSerials.set(element, calloutIconProbeSerial);
  }
  return calloutIconSerials.get(element);
}

function rectSnapshot(element) {
  if (!element) return null;
  const rect = element.getBoundingClientRect();
  return {
    x: Number(rect.x.toFixed(2)),
    y: Number(rect.y.toFixed(2)),
    width: Number(rect.width.toFixed(2)),
    height: Number(rect.height.toFixed(2)),
    top: Number(rect.top.toFixed(2)),
    left: Number(rect.left.toFixed(2)),
    right: Number(rect.right.toFixed(2)),
    bottom: Number(rect.bottom.toFixed(2)),
    isConnected: element.isConnected,
    hidden: element.hidden === true,
    clientWidth: element.clientWidth ?? null,
    clientHeight: element.clientHeight ?? null,
    offsetWidth: element.offsetWidth ?? null,
    offsetHeight: element.offsetHeight ?? null,
    naturalWidth: element.naturalWidth ?? null,
    naturalHeight: element.naturalHeight ?? null,
  };
}

function styleSnapshot(element) {
  if (!element) return null;
  const style = window.getComputedStyle(element);
  return {
    display: style.display,
    visibility: style.visibility,
    opacity: style.opacity,
    width: style.width,
    height: style.height,
    minWidth: style.minWidth,
    minHeight: style.minHeight,
    maxWidth: style.maxWidth,
    maxHeight: style.maxHeight,
    objectFit: style.objectFit,
    objectPosition: style.objectPosition,
    filter: style.filter,
    transform: style.transform,
    mixBlendMode: style.mixBlendMode,
    clipPath: style.clipPath,
    maskImage: style.maskImage,
    webkitMaskImage: style.webkitMaskImage,
    overflow: style.overflow,
    position: style.position,
    pointerEvents: style.pointerEvents,
  };
}

function canvasPixelStats(img) {
  try {
    const renderedWidth = Math.round(img.getBoundingClientRect().width || img.clientWidth || img.width || 22);
    const renderedHeight = Math.round(img.getBoundingClientRect().height || img.clientHeight || img.height || 22);
    const width = Math.max(1, Math.min(96, renderedWidth));
    const height = Math.max(1, Math.min(96, renderedHeight));
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d", { willReadFrequently: true });
    if (!context) return { error: "no-2d-context", width, height };

    context.clearRect(0, 0, width, height);
    context.drawImage(img, 0, 0, width, height);
    const pixels = context.getImageData(0, 0, width, height).data;
    let nonZeroAlpha = 0;
    let strongAlpha = 0;
    let nonWhite = 0;
    let minAlpha = 255;
    let maxAlpha = 0;

    for (let index = 0; index < pixels.length; index += 4) {
      const red = pixels[index];
      const green = pixels[index + 1];
      const blue = pixels[index + 2];
      const alpha = pixels[index + 3];
      if (alpha > 0) nonZeroAlpha += 1;
      if (alpha > 8) strongAlpha += 1;
      if (alpha > 8 && (red < 245 || green < 245 || blue < 245)) nonWhite += 1;
      minAlpha = Math.min(minAlpha, alpha);
      maxAlpha = Math.max(maxAlpha, alpha);
    }

    return {
      width,
      height,
      nonZeroAlpha,
      strongAlpha,
      nonWhite,
      minAlpha,
      maxAlpha,
    };
  } catch (error) {
    return { error: String(error?.message || error) };
  }
}

function traceCalloutImageState(label, callout, img, extra = {}) {
  if (window.PENNED_EDITOR_DIAGNOSTICS !== true) return;
  const button = img?.closest?.(".vellix-callout-icon-button") ?? null;
  const isImageElement = img instanceof HTMLImageElement;
  traceDiag(label, {
    id: callout?.dataset?.vellixBlockId || null,
    icon: callout?.dataset?.calloutIcon || null,
    color: callout?.dataset?.calloutColor || null,
    imageSerial: serialForElement(img),
    buttonSerial: serialForElement(button),
    calloutSerial: serialForElement(callout),
    imageAlt: img?.alt || img?.getAttribute?.("aria-label") || null,
    imageSrcAttr: img?.getAttribute?.("src") || null,
    imageSrc: img?.src || null,
    imageCurrentSrc: img?.currentSrc || null,
    imageBackgroundImage: img?.style?.backgroundImage || null,
    imageComplete: isImageElement ? img.complete : null,
    imageHidden: img?.hidden ?? null,
    imageRect: rectSnapshot(img),
    imageStyle: styleSnapshot(img),
    buttonRect: rectSnapshot(button),
    buttonStyle: styleSnapshot(button),
    calloutRect: rectSnapshot(callout),
    calloutStyle: styleSnapshot(callout),
    canvas: isImageElement && img.complete ? canvasPixelStats(img) : { skipped: isImageElement ? "image-not-complete" : "background-element" },
    text: callout?.textContent?.trim() ?? "",
    ...extra,
  });
}

function scheduleCalloutImageStateProbes(callout, img, sourceLabel) {
  if (window.PENNED_EDITOR_DIAGNOSTICS !== true) return;
  traceCalloutImageState("callout-dom-icon-probe", callout, img, { phase: `${sourceLabel}:immediate` });
  requestAnimationFrame(() => {
    traceCalloutImageState("callout-dom-icon-probe", callout, img, { phase: `${sourceLabel}:raf1` });
    requestAnimationFrame(() => {
      traceCalloutImageState("callout-dom-icon-probe", callout, img, { phase: `${sourceLabel}:raf2` });
    });
  });
  window.setTimeout(() => {
    traceCalloutImageState("callout-dom-icon-probe", callout, img, { phase: `${sourceLabel}:100ms` });
  }, 100);
  window.setTimeout(() => {
    traceCalloutImageState("callout-dom-icon-probe", callout, img, { phase: `${sourceLabel}:500ms` });
  }, 500);
}

function text(value) {
  return { type: "text", text: String(value || "") };
}

function paragraph(content = [], attrs = {}) {
  return { type: "paragraph", attrs: { id: id(), ...attrs }, content };
}

function inlineContent(value) {
  if (typeof value === "string") {
    return value.trim() ? [text(value)] : [];
  }

  if (!Array.isArray(value)) {
    return [];
  }

  return value.flatMap((item) => {
    if (!isRecord(item)) return [];
    if (item.type === "text") return [text(item.text || "")];
    if (typeof item.text === "string") return [text(item.text)];
    if (typeof item.content === "string") return [text(item.content)];
    return [];
  });
}

function plainText(node) {
  if (typeof node === "string") return node;
  if (Array.isArray(node)) return node.map(plainText).filter(Boolean).join(" ");
  if (!isRecord(node)) return "";
  if (node.type === "inlineTag") return "#" + (node.attrs?.name ?? "");
  if (node.type === "inlineProperty") return propertyText(node.attrs?.property);
  if (node.type === "attachment") return typeof node.attrs?.file?.name === "string" ? node.attrs.file.name : "";
  if (["gridCard", "iconCallout"].includes(node.type)) return [node.attrs?.title, plainText(node.content)].filter(Boolean).join(" ");
  const own = typeof node.text === "string" ? node.text : "";
  const content = plainText(node.content);
  const children = plainText(node.children);
  return [own, content, children].filter(Boolean).join(" ");
}

function calloutTraceRecords(source) {
  const records = [];
  const visit = (nodes, path = []) => {
    nodes?.forEach((node, index) => {
      if (!isRecord(node)) return;
      const nextPath = [...path, index];
      if (node.type === "callout" || node.type === "gridCard") {
        records.push({
          path: nextPath.join("."),
          id: node.attrs?.id ?? null,
          icon: node.attrs?.icon ?? null,
          color: node.attrs?.color ?? null,
          text: plainText(node),
          attrs: node.attrs ?? {},
        });
      }
      visit(node.content, nextPath);
    });
  };

  const documentJSON = source?.type === "doc" ? source : normalizeTipTapDocument(source);
  visit(documentJSON.content ?? []);
  return records;
}

function traceCalloutAttrs(label, source, extra = {}) {
  if (window.PENNED_EDITOR_DIAGNOSTICS !== true) return;
  traceDiag(label, {
    callouts: calloutTraceRecords(source),
    ...extra,
  });
}

function normalizeTipTapNode(value) {
  if (!isRecord(value)) {
    return paragraph();
  }

  if (value.type === "doc") {
    return normalizeTipTapDocument(value);
  }

  const type = value.type === "callout" ? "gridCard" : typeof value.type === "string" ? value.type : "paragraph";
  if (type === "text") {
    const textNode = { type: "text", text: typeof value.text === "string" ? value.text : "" };
    if (Array.isArray(value.marks)) {
      const marks = value.marks
        .filter((mark) => isRecord(mark) && typeof mark.type === "string" && mark.type.trim())
        .map((mark) => {
          const normalizedMark = { type: mark.type.trim() };
          if (isRecord(mark.attrs)) normalizedMark.attrs = { ...mark.attrs };
          return normalizedMark;
        });
      if (marks.length) textNode.marks = marks;
    }
    return textNode;
  }

  const attrs = isRecord(value.attrs) ? { ...value.attrs } : {};
  attrs.id = typeof attrs.id === "string" && attrs.id.trim() ? attrs.id.trim() : id();
  if (type === "divider") {
    attrs.style = normalizedDividerStyle(attrs.style);
    if (attrs.style === "washiTape" || attrs.tapeSize != null) attrs.tapeSize = washiTapeSize(attrs.tapeSize);
    else delete attrs.tapeSize;
    attrs.color = dividerColor(attrs.color);
    attrs.remotePhoto = dividerPhoto(attrs.remotePhoto);
    attrs.imagePath = !attrs.remotePhoto && typeof attrs.imagePath === "string" && attachmentURL({ relativePath: attrs.imagePath })
      ? attrs.imagePath : null;
  }
  if (type === "heading") {
    if (isRecord(attrs.label)) attrs.label = labelSettings(attrs.label);
    else delete attrs.label;
  }
  if (type === "inlineProperty") attrs.property = normalizeProperty(attrs.property);

  if (type === "gridCard") {
    Object.assign(attrs, gridCardSettings(attrs));
    delete attrs.color;
  }
  if (type === "iconCallout") Object.assign(attrs, iconCalloutSettings(attrs));
  if (type === "richLink") {
    attrs.href = webLinkURL(attrs.href) || "";
    attrs.layout = richLinkLayout(attrs.layout);
    attrs.metadata = richLinkMetadata(attrs.metadata);
  }

  if (type === "taskItem") {
    attrs.checked = attrs.checked === true;
    attrs.crossed = attrs.crossed === true;
    if (attrs.crossed) attrs.checked = false;
  }

  if (type === "plainCallout") {
    delete attrs.icon;
    attrs.color = typeof attrs.color === "string" && attrs.color.trim() ? attrs.color.trim() : DEFAULT_CALLOUT_COLOR;
  }

  let content = Array.isArray(value.content)
    ? value.content.map(normalizeTipTapNode).filter((node) => node.type !== "doc")
    : undefined;

  if (["gridCard", "iconCallout", "plainCallout"].includes(type)) {
    const hasBlockContent = content?.some((node) => node.type !== "text" && node.type !== "hardBreak") ?? false;
    content = hasBlockContent ? content : [paragraph(content ?? [])];
  }

  const normalized = content ? { type, attrs, content } : { type, attrs };
  if (type === "inlineTag" && Array.isArray(value.marks)) normalized.marks = value.marks;
  return normalized;
}

function hoistPageBreaks(nodes) {
  return nodes.flatMap((node) => {
    if (node.type === "pageBreak" || !Array.isArray(node.content)) {
      return [node];
    }

    const content = hoistPageBreaks(node.content);
    if (!content.some((child) => child.type === "pageBreak")) {
      return [{ ...node, content }];
    }

    const result = [];
    let chunk = [];
    let chunkIndex = 0;
    const appendChunk = () => {
      if (!chunk.length) return;
      const attrs = {
        ...(node.attrs || {}),
        ...(chunkIndex > 0 ? { id: id() } : {}),
      };
      result.push({ ...node, attrs, content: chunk });
      chunk = [];
      chunkIndex += 1;
    };

    content.forEach((child) => {
      if (child.type === "pageBreak") {
        appendChunk();
        result.push(child);
      } else {
        chunk.push(child);
      }
    });
    appendChunk();
    return result;
  });
}

function normalizedDocumentContent(content) {
  const hoisted = hoistPageBreaks(unwrapRetiredColumns(content));
  const cleaned = hoisted.filter((node, index) => {
    if (node.type !== "blockquote" || plainText(node).trim() || node.attrs?.color) return true;
    return !(
      hoisted[index - 1]?.type === "pageBreak" ||
      hoisted[index + 1]?.type === "pageBreak"
    );
  });
  const result = [];

  cleaned.forEach((node, index) => {
    result.push(node);
    if (
      node.type === "pageBreak" &&
      (!cleaned[index + 1] || cleaned[index + 1].type === "pageBreak")
    ) {
      result.push(paragraph());
    }
  });

  return result.length ? result : [paragraph()];
}

function importLegacyBlock(value) {
  if (!isRecord(value)) {
    return paragraph();
  }

  const blockID = typeof value.id === "string" && value.id.trim() ? value.id.trim() : id();
  const props = isRecord(value.props) ? value.props : {};
  const children = Array.isArray(value.children) ? value.children.map(importLegacyBlock) : [];
  const content = inlineContent(value.content);

  switch (value.type) {
    case "heading":
      return {
        type: "heading",
        attrs: { id: blockID, level: typeof props.level === "number" ? props.level : 1 },
        content,
      };
    case "bulletListItem":
      return {
        type: "bulletList",
        attrs: { id: blockID },
        content: [{ type: "listItem", attrs: { id: id() }, content: [paragraph(content)] }],
      };
    case "numberedListItem":
      return {
        type: "orderedList",
        attrs: { id: blockID },
        content: [{ type: "listItem", attrs: { id: id() }, content: [paragraph(content)] }],
      };
    case "checkListItem":
      return {
        type: "taskList",
        attrs: { id: blockID },
        content: [
          {
            type: "taskItem",
            attrs: {
              id: id(),
              checked: props.checked === true && props.crossed !== true,
              crossed: props.crossed === true,
            },
            content: [paragraph(content)],
          },
        ],
      };
    case "quote":
      return { type: "blockquote", attrs: { id: blockID }, content: [paragraph(content)] };
    case "plainCallout":
      return {
        type: "plainCallout",
        attrs: { id: blockID, color: props.color || DEFAULT_CALLOUT_COLOR },
        content: [paragraph(content)],
      };
    case "callout":
      return normalizeTipTapNode({ type: "gridCard", attrs: { ...props, id: blockID },
        content: [paragraph(content), ...children] });
    case "divider":
      return {
        type: "divider",
        attrs: { id: blockID, style: normalizedDividerStyle(props.style) },
      };
    case "pageBreak":
      return { type: "pageBreak", attrs: { id: blockID } };
    case "toggleListItem":
      return {
        type: "toggleItem",
        attrs: { id: blockID, open: true },
        content: [paragraph(content), ...children],
      };
    default:
      return paragraph(content, { id: blockID });
  }
}

function normalizeTipTapDocument(value) {
  if (isRecord(value)) {
    if (value.document) {
      return normalizeTipTapDocument(value.document);
    }

    if (value.type === "doc") {
      const content = Array.isArray(value.content)
        ? value.content.map(normalizeTipTapNode).filter((node) => node.type !== "doc")
        : [];
      return { type: "doc", ...(value.attrs?.taskHistoryProjection ? { attrs: { taskHistoryProjection: value.attrs.taskHistoryProjection } } : {}), content: normalizedDocumentContent(content) };
    }

    if (Array.isArray(value.blocks)) {
      return { type: "doc", content: normalizedDocumentContent(value.blocks.map(importLegacyBlock)) };
    }

    if (Array.isArray(value.content)) {
      const content = value.content.map(normalizeTipTapNode).filter((node) => node.type !== "doc");
      return { type: "doc", content: normalizedDocumentContent(content) };
    }
  }

  if (Array.isArray(value)) {
    return { type: "doc", content: normalizedDocumentContent(value.map(importLegacyBlock)) };
  }

  return { type: "doc", content: [paragraph()] };
}

function normalizeLoadedTipTapDocument(value) {
  const documentJSON = normalizeTipTapDocument(value);
  let content = documentJSON.content.filter(
    (node) => node.type !== "blockquote" || plainText(node).trim() || node.attrs?.color,
  );
  content = normalizePageReferenceStarters(content);
  const lastNode = content[content.length - 1];
  const previousNode = content[content.length - 2];
  if (
    content.length > 1 &&
    lastNode?.type === "paragraph" &&
    !plainText(lastNode).trim() &&
    previousNode?.type !== "paragraph" &&
    previousNode?.type !== "templateComponent" &&
    previousNode?.type !== "attachment" &&
    previousNode?.type !== "pageBreak"
  ) {
    content = content.slice(0, -1);
  }
  return {
    ...documentJSON,
    content: normalizedDocumentContent(content),
  };
}

function documentBlocks(source) {
  const flattened = [];
  const visit = (nodes) => {
    nodes?.forEach((node) => {
      if (node.type !== "text") flattened.push(node);
      visit(node.content);
    });
  };
  visit(normalizeTipTapDocument(source).content);
  return flattened;
}

function topLevelDocumentBlocks(source) {
  return normalizeTipTapDocument(source).content.filter((node) => node.type !== "text");
}

function topLevelSelectableBlocks(source) {
  const blocks = topLevelDocumentBlocks(source);
  const isEmptyParagraph = (node) =>
    node?.type === "paragraph" && !plainText(node).trim();
  return (
    blocks.length && isEmptyParagraph(blocks[blocks.length - 1])
      ? blocks.slice(0, -1)
      : blocks
  );
}

function statistics(document) {
  const compact = plainText(document)
    .split(/\s+/)
    .filter(Boolean)
    .join(" ");
  return {
    wordCount: compact ? compact.split(/\s+/).length : 0,
    characterCount: compact.length,
  };
}

function renderIconElement(iconElement, icon, color = DEFAULT_CALLOUT_COLOR, size = 22) {
  const normalizedIcon = normalizedIconName(icon);
  const src = iconSource(normalizedIcon, color, size);
  // No-op DOM writes can invalidate the callout while its text is being composed.
  if (iconElement.getAttribute("role") !== "img") iconElement.setAttribute("role", "img");
  if (iconElement.getAttribute("aria-label") !== normalizedIcon) iconElement.setAttribute("aria-label", normalizedIcon);
  const backgroundImage = cssBackgroundImageSource(src);
  if (iconElement.style.backgroundImage !== backgroundImage) iconElement.style.backgroundImage = backgroundImage;
  if (iconElement.hidden) iconElement.hidden = false;
  return { icon: normalizedIcon, src };
}

const renderedCalloutIcons = new WeakMap();
function renderCalloutIcons(root = document) {
  const callouts = root.matches?.(".vellix-callout")
    ? [root, ...root.querySelectorAll(".vellix-callout")]
    : root.querySelectorAll?.(".vellix-callout") ?? [];
  callouts.forEach((callout) => {
    const icon = callout.dataset.calloutIcon || DEFAULT_CALLOUT_ICON;
    const color = callout.dataset.calloutColor || DEFAULT_CALLOUT_COLOR;
    const iconElement = callout.querySelector(".vellix-callout-icon-image");
    if (!iconElement) return;
    const src = iconSource(icon, color, 22);
    const signature = `${icon}:${color}:${src}`;
    if (renderedCalloutIcons.get(iconElement) === signature) return;
    renderedCalloutIcons.set(iconElement, signature);
    traceCalloutImageState("callout-dom-icon-before-src", callout, iconElement, {
      nextSrc: src,
      previousSrc: iconElement.getAttribute("src") || iconElement.style.backgroundImage || null,
    });
    renderIconElement(iconElement, icon, color, 22);
    traceDiag("callout-dom-icon-mounted", {
      id: callout.dataset.vellixBlockId || null,
      icon,
      color,
      imageAlt: iconElement.getAttribute("aria-label") || null,
      imageSrc: src,
      text: callout.textContent?.trim() ?? "",
    });
    traceCalloutImageState("callout-dom-icon-mounted-state", callout, iconElement, { src });
    scheduleCalloutImageStateProbes(callout, iconElement, "mounted");
  });
}


// Ordinary text edits must not scan every callout in a large document.
// Resolve only callouts intersecting the changed model ranges; full-document
// replacement and icon-asset registration retain their explicit full refreshes.
function renderChangedCalloutIcons(transaction) {
  if (!transaction?.docChanged) return;
  const ranges = changedRanges(transaction);
  if (!ranges.length) { renderCalloutIcons(); return; }
  const affected = new Set();
  const view = editor.view;
  const addCallout = (position) => {
    const element = view.nodeDOM(position);
    if (!(element instanceof HTMLElement)) return;
    if (element.matches('.vellix-callout')) affected.add(element);
    element.querySelectorAll?.('.vellix-callout').forEach(callout => affected.add(callout));
    const ancestor = element.closest('.vellix-callout');
    if (ancestor) affected.add(ancestor);
  };
  for (const range of ranges) {
    const from = Math.max(0, range.from - 1);
    const to = Math.min(transaction.doc.content.size, range.to + 1);
    transaction.doc.nodesBetween(from, to, (node, position) => {
      if (["gridCard", "iconCallout"].includes(node.type.name)) addCallout(position);
      return !node.isText;
    });
    const resolved = transaction.doc.resolve(Math.min(range.from, transaction.doc.content.size));
    for (let depth = resolved.depth; depth > 0; depth--) {
      if (["gridCard", "iconCallout"].includes(resolved.node(depth).type.name)) addCallout(resolved.before(depth));
    }
  }
  affected.forEach(callout => renderCalloutIcons(callout));
}

let editorAppearance = {};
function applyAppearance(payload = {}) {
  editorAppearance = { ...editorAppearance, ...payload };
  applyEditorAppearance(document.documentElement, payload);
}

// Shared persistent block-id attribute. Stored on attrs.id, serialized into the
// canonical TipTap JSON, and mirrored to the data-vellix-block-id HTML attribute
// for clipboard round-trips. Reused by every block and structural node that
// carries an id, so there is one id format and one generation path.
const persistentBlockId = {
  default: null,
  keepOnSplit: false,
  parseHTML: (element) => element.getAttribute("data-vellix-block-id"),
  renderHTML: (attrs) =>
    typeof attrs.id === "string" && attrs.id.trim()
      ? { "data-vellix-block-id": attrs.id }
      : {},
};

const BlockID = Extension.create({
  name: "vellixBlockID",
  addGlobalAttributes() {
    return [
      { types: ["paragraph", "caption", "heading", "richLink"], attributes: { blockFont: blockFontAttribute() } },
      {
        types: [
          "paragraph",
          "caption",
          "heading",
          "codeBlock",
          "blockquote",
          "bulletList",
          "orderedList",
          "listItem",
          "taskList",
          "taskItem",
          "gridCard",
          "iconCallout",
          "richLink",
          "plainCallout",
          "plainCalloutRow",
          "templateComponent",
          "moodBar",
          "countdown",
          "calculator",
          "attachment",
          "divider",
          "pageBreak",
          "toggleItem",
          "inlineProperty",
          "pageReference",
          "collection",
        ],
        attributes: {
          id: persistentBlockId,
          textAlign: {
            default: null,
            parseHTML: (element) => element.style.textAlign || null,
            renderHTML: (attrs) => {
              const value = typeof attrs.textAlign === "string" ? attrs.textAlign.trim() : "";
              return value ? { "data-vellix-align": value } : {};
            },
          },
          indent: {
            default: 0,
            parseHTML: (element) => Number(element.getAttribute("data-vellix-indent")) || 0,
            renderHTML: (attrs) => {
              const value = Math.max(0, Math.min(6, Number(attrs.indent) || 0));
              return value
                ? { "data-vellix-indent": String(value) }
                : {};
            },
          },
        },
      },
      {
        // Structural nodes inside List Grids and Information Cards. They need a
        // persistent id so the whole document tree is addressable (e.g. by a
        // future REST API), but not alignment/indent — those stay block-only.
        types: [
          "listGridRow",
          "listGridLabel",
          "listGridValue",
          "informationCardTitle",
          "informationCardDescription",
          "informationCardBody",
          "informationCardLabel",
        ],
        attributes: { id: persistentBlockId },
      },
    ];
  },
  addProseMirrorPlugins() {
    const assignKey = new PluginKey("vellixBlockIDAssign");
    // Ordinary blocks that should carry a persistent, auto-generated id. attachment,
    // taskItem, iconless callouts, collection and templateComponent already assign
    // and dedupe their own ids in their own extensions, so they are left out here to
    // avoid two assigners touching the same node.
    const autoIdTypes = new Set([
      "paragraph", "caption", "heading", "codeBlock", "blockquote",
      "bulletList", "orderedList", "listItem", "taskList",
      "divider", "pageBreak", "toggleItem", "inlineProperty", "pageReference", "listGrid", "tabs", "weekStrip", "moodBar", "countdown", "calculator", "minimalFields", "informationCard", "gridCard", "iconCallout", "richLink",
      // Structural nodes inside List Grids and Information Cards. createNodeIndex
      // descends into matched nodes, so these are assigned and de-duplicated even
      // though they are nested inside their container.
      "listGridRow", "listGridLabel", "listGridValue",
      "informationCardTitle", "informationCardDescription", "informationCardBody", "informationCardLabel",
    ]);
    const accepts = (node) => autoIdTypes.has(node.type.name);
    return [new Plugin({
      key: assignKey,
      // Give any accepted block that lacks an id (just typed, split off with Enter,
      // or loaded from a document saved before ids existed) a fresh one, and replace
      // any id duplicated by paste or node duplication so every id stays unique and
      // stable across edits. Only processes blocks that were actually added/replaced,
      // so once every id is present and unique it stops — no redraw loop.
      appendTransaction(transactions, oldState, newState) {
        const changes = transactions.filter(tr => tr.docChanged);
        if (!changes.length) return null;
        if (changes.every(tr => inlineTextEdit(tr) && tr.steps.every((step, index) => {
          const start = tr.docs[index].resolve(step.from);
          for (let depth = 1; depth <= start.depth; depth++) {
            const node = start.node(depth);
            if (accepts(node) && !node.attrs.id) return false;
          }
          return true;
        }))) return null;
        const before = new Set(createNodeIndex(oldState.doc, accepts).records.map(record => record.node));
        const records = createNodeIndex(newState.doc, accepts).records;
        const seen = new Set(records.filter((record) => before.has(record.node)).map((record) => record.node.attrs.id));
        const tr = newState.tr;
        for (const { node, pos } of records) {
          if (before.has(node)) continue;
          let blockID = node.attrs.id;
          if (!blockID || seen.has(blockID)) {
            blockID = id();
            tr.setNodeMarkup(pos, undefined, { ...node.attrs, id: blockID });
          }
          seen.add(blockID);
        }
        return tr.docChanged ? tr : null;
      },
    })];
  },
});

const VellixTaskItem = createChecklistItem(TaskItem, {
  post: postToSwift, selectionActive: () => selectionMode !== "off",
  reportHeight: () => requestAnimationFrame(reportContentHeight), nodeID: nodeId, iconSource,
});

const VellixBlockquote = Blockquote.extend({
  addAttributes() {
    return {
      ...this.parent?.(),
      color: {
        default: DEFAULT_BLOCKQUOTE_COLOR,
        parseHTML: (element) => element.getAttribute("data-blockquote-color") || DEFAULT_BLOCKQUOTE_COLOR,
        renderHTML: (attrs) => ({
          "data-blockquote-color": attrs.color || DEFAULT_BLOCKQUOTE_COLOR,
          style: `--vellix-blockquote-color:${attrs.color || DEFAULT_BLOCKQUOTE_COLOR};`,
        }),
      },
    };
  },
  addNodeView() {
    return ({ editor: nodeEditor, node }) => {
      const dom = document.createElement("blockquote");
      const button = document.createElement("button");
      const contentDOM = document.createElement("div");
      let currentNode = node;
      let renderedKeys = [];
      const render = () => {
        const attributes = mergeAttributes(
          this.options.HTMLAttributes,
          getRenderedAttributes(currentNode, nodeEditor.extensionManager.attributes),
        );
        for (const key of renderedKeys) {
          if (!(key in attributes)) dom.removeAttribute(key);
        }
        for (const [key, value] of Object.entries(attributes)) {
          if (value != null) dom.setAttribute(key, value);
        }
        renderedKeys = Object.keys(attributes);
        const color = currentNode.attrs.color || DEFAULT_BLOCKQUOTE_COLOR;
        dom.dataset.vellixBlockId = nodeId(currentNode);
        dom.dataset.blockquoteColor = color;
        dom.style.setProperty("--vellix-blockquote-color", color);
      };
      button.type = "button";
      button.className = "vellix-blockquote-color-button";
      button.contentEditable = "false";
      button.setAttribute("aria-label", "Change blockquote color");
      contentDOM.className = "vellix-blockquote-content";
      dom.append(button, contentDOM);

      const requestColor = (event) => {
        if (selectionMode !== "off" || !editor.isEditable) return;
        event.preventDefault();
        event.stopPropagation();
        postToSwift("blockquoteColorPickerRequest", {
          blockId: nodeId(currentNode),
          currentColor: currentNode.attrs.color || DEFAULT_BLOCKQUOTE_COLOR,
        });
      };
      bindNonEditingTap(button, requestColor, () => editor.isEditable && selectionMode === "off");
      render();
      return {
        dom,
        contentDOM,
        update(updatedNode) {
          if (updatedNode.type.name !== "blockquote") return false;
          currentNode = updatedNode;
          render();
          return true;
        },
        stopEvent(event) {
          return selectionMode === "off" && button.contains(event.target);
        },
        ignoreMutation(mutation) {
          return (mutation.type === "attributes" && mutation.target === dom) || button.contains(mutation.target);
        },
      };
    };
  },
});

const GridCard = Node.create({
  name: "gridCard",
  group: "block",
  content: "block+",
  defining: true,
  isolating: true,
  addAttributes() {
    return Object.fromEntries(Object.entries(GRID_CARD_DEFAULTS).map(([key, value]) =>
      [key, { default: value, rendered: false }]));
  },
  parseHTML() {
    return ["div[data-type='penned-grid-card']", "div.vellix-callout:not([data-type='penned-icon-callout'])", "div[data-type='vellix-callout']"].map(tag => ({
      tag,
      contentElement: element => element.querySelector(":scope > .vellix-callout-text") ?? element,
      getAttrs: element => gridCardSettings({
        icon: element.dataset.calloutIcon, color: element.dataset.calloutColor,
        backgroundColor: element.dataset.gridBackground,
        titleColor: element.dataset.gridTitleColor, textColor: element.dataset.gridTextColor,
        width: element.dataset.gridWidth,
        alignment: element.dataset.gridAlignment, height: element.dataset.gridHeight,
        title: element.querySelector(":scope > .penned-grid-card-header > .penned-grid-card-title")?.textContent,
      }),
    }));
  },
  renderHTML({ HTMLAttributes, node }) {
    const { icon, iconColor, title } = gridCardSettings(node.attrs);
    return [
      "div",
      mergeAttributes(HTMLAttributes, gridCardDOMAttributes(node.attrs), {
        class: "vellix-callout penned-grid-card",
        "data-callout-icon": icon,
        "data-callout-color": iconColor,
      }),
      ["div", { class: "penned-grid-card-header", contenteditable: "false" },
      [
        "button",
        {
          type: "button",
          class: "vellix-callout-icon-button",
          contenteditable: "false",
          "data-vellix-callout-icon-button": "true",
          "aria-label": "Grid Card Settings",
        },
        [
          "span",
          {
            class: "vellix-callout-icon-image",
            role: "img",
            "aria-label": icon,
            style: `background-image:${cssBackgroundImageSource(iconSource(icon, iconColor, 22))};`,
          },
        ],
      ],
      ["div", { class: "penned-grid-card-title" }, title]],
      ["div", { class: "vellix-callout-text" }, 0],
    ];
  },
});

const renderCalloutLibraryIcon = (icon, color, rasterized = false) => rasterized
  ? iconCalloutImage(iconSource(icon, color, 24), null)
  : ["span", {
    class: "vellix-callout-icon-image", role: "img", "aria-label": icon,
    style: `background-image:${cssBackgroundImageSource(iconSource(icon, color, 22))};`,
  }];
const IconCallout = iconCalloutNode({
  selectionActive: () => selectionMode !== "off",
  reportHeight: () => requestAnimationFrame(reportContentHeight),
  renderLibraryIcon: renderCalloutLibraryIcon,
});

const PlainCallout = Node.create({
  name: "plainCallout",
  group: "block",
  content: "block+",
  defining: true,
  isolating: true,
  addAttributes() {
    return {
      id: { default: null },
      widthPercent: calloutWidthAttribute,
      textColor: { default: null, parseHTML: element => plainCalloutSettings({ textColor: element.dataset.calloutTextColor }).textColor, rendered: false },
      minimumHeight: { default: null, parseHTML: element => plainCalloutSettings({ minimumHeight: element.dataset.calloutMinimumHeight }).minimumHeight, rendered: false },
      clipSource: {
        default: null,
        parseHTML: element => {
          try { return clipSource(JSON.parse(element.getAttribute("data-penned-clip-source"))); }
          catch { return null; }
        },
        renderHTML: attrs => clipSource(attrs.clipSource) ? { "data-penned-clip-source": JSON.stringify(clipSource(attrs.clipSource)) } : {},
      },
      color: {
        default: DEFAULT_CALLOUT_COLOR,
        parseHTML: (element) => element.getAttribute("data-callout-color") || DEFAULT_CALLOUT_COLOR,
        renderHTML: (attrs) => ({ "data-callout-color": attrs.color || DEFAULT_CALLOUT_COLOR }),
      },
    };
  },
  parseHTML() {
    return [{ tag: "div[data-penned-clip-source]", contentElement: ".penned-clip-source-content" },
      { tag: "div[data-type='vellix-plain-callout']" }, { tag: "div.vellix-plain-callout" }];
  },
  renderHTML({ HTMLAttributes, node }) {
    const color = node.attrs.color || DEFAULT_CALLOUT_COLOR;
    const source = clipSource(node.attrs.clipSource);
    if (source) {
      return ["div", mergeAttributes(HTMLAttributes, { "data-type": "vellix-plain-callout",
        class: "vellix-plain-callout penned-clip-source", "data-callout-color": color }),
        clipPreview(source, attachmentURL(source.file, /heic|heif/.test(source.file?.mimeType || "") ? "image" : "")),
        ["div", { class: "vellix-plain-callout-text penned-clip-source-content" }, 0]];
    }
    const settings = plainCalloutSettings(node.attrs);
    return ["div", mergeAttributes(HTMLAttributes, {
      "data-type": "vellix-plain-callout", class: "vellix-plain-callout penned-plain-callout",
      "data-callout-color": settings.color, "data-callout-text-color": settings.textColor,
      "data-callout-minimum-height": settings.minimumHeight, style: plainCalloutSurface(settings),
    }), ["div", { class: "vellix-callout-text vellix-plain-callout-text" }, 0]];
  },
  addKeyboardShortcuts() {
    return {
      Enter: ({ editor }) => {
        const selection = editor.state.selection;
        const { $from, $to } = selection;
        // Nested lists and containers own their own Return, even when an outer
        // clipped-source callout has a special direct-paragraph shortcut.
        if ($from.depth < 2 || $from.node(-1).type.name !== "plainCallout") return false;
        const callout = $from.node(-1);
        if (!clipSource(callout.attrs.clipSource)) return false;
        if (!editor.isEditable || selectionMode !== "off") return true;
        if ($from.parent.type.spec.code || !$from.sameParent($to)) return false;
        return editor.commands.setHardBreak();
      },
    };
  },
});

const Divider = Node.create({
  name: "divider",
  group: "block",
  atom: true,
  addAttributes() {
    return {
      id: { default: null },
      style: {
        default: DEFAULT_DIVIDER_STYLE,
        parseHTML: (element) =>
          normalizedDividerStyle(
            element.getAttribute("data-divider-style") ||
              element.getAttribute("data-vellix-divider-style")
          ),
        rendered: false,
      },
      color: { default: null, rendered: false, parseHTML: element => dividerColor(element.getAttribute("data-divider-color")) },
      tapeSize: { default: null, rendered: false, parseHTML: element => {
        const size = element.getAttribute("data-tape-size");
        return size === null ? null : washiTapeSize(size);
      } },
      imagePath: { default: null, rendered: false, parseHTML: element => {
        const src = element.querySelector(".vellix-divider-tape img")?.getAttribute("src");
        try {
          const url = new URL(src);
          const path = url.searchParams.get("path");
          return url.protocol === "penned-file:" && url.host === "file" && attachmentURL({ relativePath: path }) ? path : null;
        } catch { return null; }
      } },
      remotePhoto: { default: null, rendered: false, parseHTML: element => {
        try { return dividerPhoto(JSON.parse(element.getAttribute("data-divider-photo"))); }
        catch { return null; }
      } },
    };
  },
  parseHTML() {
    return [{ tag: "div[data-vellix-divider]" }, { tag: "hr[data-vellix-divider]" }];
  },
  renderHTML({ node, HTMLAttributes }) {
    const photo = node.attrs.style === "washiTape" ? dividerPhoto(node.attrs.remotePhoto) : null;
    const path = node.attrs.imagePath;
    const src = node.attrs.style === "washiTape"
      ? photo?.imageURL || (typeof path === "string" ? attachmentURL({ relativePath: path }) : "") : "";
    return dividerDOM(node.attrs, src, { ...HTMLAttributes, "data-divider-photo": photo ? JSON.stringify(photo) : null });
  },
});

const VellixDocument = Node.create({
  name: "doc",
  topNode: true,
  content: "(block | pageBoundary)+",
});

const PageBreak = Node.create({
  name: "pageBreak",
  group: "pageBoundary",
  atom: true,
  selectable: true,
  isolating: true,
  addAttributes() {
    return { id: { default: null } };
  },
  parseHTML() {
    return [
      { tag: "div[data-vellix-page-break]" },
      { tag: "div[data-type='pageBreak']" },
      { tag: "div[data-page-break]" },
    ];
  },
  renderHTML({ HTMLAttributes }) {
    return [
      "div",
      mergeAttributes(HTMLAttributes, {
        "data-vellix-page-break": "true",
        "aria-hidden": "true",
      }),
    ];
  },
  addKeyboardShortcuts() {
    const deleteSelectedPageBreak = ({ editor: nodeEditor }) => {
      const { selection: currentSelection } = nodeEditor.state;
      if (
        !(currentSelection instanceof NodeSelection) ||
        currentSelection.node.type.name !== this.name
      ) {
        return false;
      }
      return nodeEditor.commands.deleteSelection();
    };

    return {
      Backspace: deleteSelectedPageBreak,
      Delete: deleteSelectedPageBreak,
    };
  },
});

const ToggleItem = Node.create({
  name: "toggleItem",
  group: "block",
  content: "block+",
  defining: true,
  addAttributes() {
    return {
      id: { default: null },
      open: { default: true },
    };
  },
  addKeyboardShortcuts() {
    return {
      // Enter at the end of the toggle's summary line drops the cursor into a
      // NEW paragraph INSIDE the toggle body (Notion behavior). Also force-
      // opens the toggle if it was collapsed so the new line is visible.
      // Only direct summary/body textblocks belong to this shortcut. Nested
      // lists, callouts, tables, and other containers retain their own handlers.
      Enter: ({ editor }) => {
        const { $from, empty } = editor.state.selection;
        if (!empty) return false;
        for (let depth = $from.depth; depth > 0; depth -= 1) {
          if ($from.node(depth).type.name !== "toggleItem") continue;
          const childDepth = depth + 1;
          if ($from.depth !== childDepth) return false;
          const isFirstChild = $from.index(depth) === 0;
          const isAtEnd = $from.parentOffset === $from.parent.content.size;
          if (!isFirstChild) {
            // The editor's default Enter split is a silent no-op inside a toggle
            // body, so perform the split here. A real split carries any trailing
            // text into the new block; when the schema disallows a split at this
            // position, insert an empty paragraph right after the current block
            // instead. Mirrors the summary-line behavior above and keeps the new
            // line inside the toggle.
            const splitPos = $from.pos;
            const afterBlock = $from.after($from.depth);
            return editor.chain().focus().command(({ tr, state, dispatch }) => {
              if (canSplit(state.doc, splitPos)) {
                if (dispatch) dispatch(tr.split(splitPos).scrollIntoView());
                return true;
              }
              const paragraph = state.schema.nodes.paragraph;
              if (!paragraph) return false;
              if (dispatch) {
                tr.insert(afterBlock, paragraph.create());
                tr.setSelection(TextSelection.near(tr.doc.resolve(afterBlock + 1)));
                dispatch(tr.scrollIntoView());
              }
              return true;
            }).run();
          }
          if (!isAtEnd) return false;

          const toggleNode = $from.node(depth);
          const togglePos = $from.before(depth);
          const insertAt = $from.after($from.depth); // right after the summary paragraph
          const chain = editor.chain().focus();
          if (toggleNode.attrs.open === false) {
            chain.command(({ tr }) => {
              tr.setNodeMarkup(togglePos, undefined, { ...toggleNode.attrs, open: true });
              return true;
            });
          }
          return chain
            .insertContentAt(insertAt, { type: "paragraph" }, { updateSelection: false })
            .setTextSelection(insertAt + 1)
            .run();
        }
        return false;
      },
      // Backspace at the start of an EMPTY toggle unwraps it back to a plain
      // paragraph. If the toggle has any content, do nothing so users don't
      // lose text unexpectedly.
      Backspace: ({ editor }) => {
        const { $from, empty } = editor.state.selection;
        if (!empty || $from.parentOffset !== 0) return false;
        for (let depth = $from.depth; depth > 0; depth -= 1) {
          if ($from.node(depth).type.name !== "toggleItem") continue;
          const toggleNode = $from.node(depth);
          if (toggleNode.childCount !== 1) return false;
          const only = toggleNode.firstChild;
          if (!only || only.textContent.length > 0 || only.childCount > 0) return false;
          const from = $from.before(depth);
          const to = $from.after(depth);
          return editor
            .chain()
            .focus()
            .insertContentAt({ from, to }, { type: "paragraph" }, { updateSelection: true })
            .run();
        }
        return false;
      },
    };
  },
  parseHTML() {
    return [
      {
        tag: "div[data-vellix-toggle]",
        getAttrs: (element) => ({ open: element.getAttribute("data-open") !== "false" }),
      },
      {
        tag: "details[data-vellix-toggle]",
        getAttrs: (element) => ({ open: element.hasAttribute("open") }),
      },
    ];
  },
  renderHTML({ HTMLAttributes, node }) {
    const isOpen = node.attrs.open !== false;
    return [
      "div",
      mergeAttributes(HTMLAttributes, {
        "data-vellix-toggle": "true",
        "data-open": isOpen ? "true" : "false",
      }),
      [
        "button",
        {
          type: "button",
          class: "vellix-toggle-button",
          contenteditable: "false",
          "data-vellix-toggle-button": "true",
          "aria-label": isOpen ? "Collapse toggle" : "Expand toggle",
        },
        "",
      ],
      ["div", { class: "vellix-toggle-content", "data-vellix-toggle-content": "true" }, 0],
    ];
  },
  addNodeView() {
    return ({ editor: nodeEditor, node, getPos }) => {
      let currentNode = node;
      let temporarilyOpenForTag = false;
      const dom = document.createElement("div");
      const button = document.createElement("button");
      const contentDOM = document.createElement("div");

      dom.dataset.vellixToggle = "true";
      dom.className = "vellix-toggle";

      button.type = "button";
      button.className = "vellix-toggle-button";
      button.contentEditable = "false";
      button.dataset.vellixToggleButton = "true";

      contentDOM.className = "vellix-toggle-content";
      contentDOM.dataset.vellixToggleContent = "true";

      dom.append(button, contentDOM);

      const render = () => {
        const isOpen = temporarilyOpenForTag || currentNode.attrs.open !== false;
        const blockId = nodeId(currentNode);
        dom.dataset.open = isOpen ? "true" : "false";
        dom.dataset.vellixBlockId = blockId;
        button.setAttribute("aria-label", isOpen ? "Collapse toggle" : "Expand toggle");
        button.setAttribute("aria-expanded", isOpen ? "true" : "false");
      };

      const toggleOpen = (event) => {
        if (selectionMode !== "off") {
          event.preventDefault();
          return;
        }
        event.preventDefault();
        event.stopPropagation();
        const position = typeof getPos === "function" ? getPos() : null;
        if (position == null || Number.isNaN(position)) return;
        const nextOpen = !(temporarilyOpenForTag || currentNode.attrs.open !== false);
        temporarilyOpenForTag = false;
        nodeEditor.view.dispatch(
          nodeEditor.state.tr.setNodeMarkup(position, undefined, {
            ...currentNode.attrs,
            open: nextOpen,
          }),
        );
        render();
        requestAnimationFrame(reportContentHeight);
      };

      const preventToggleFocus = (event) => {
        if (selectionMode !== "off") return;
        event.preventDefault();
        event.stopPropagation();
      };
      const toggleFromTouch = (event) => {
        if (selectionMode === "off") toggleOpen(event);
      };

      // Cancel native touch focus before WebKit enters the editing host. Since
      // this also suppresses the synthesized click, handle touch activation here.
      button.addEventListener("pointerdown", preventToggleFocus);
      button.addEventListener("mousedown", preventToggleFocus);
      button.addEventListener("touchstart", preventToggleFocus, { passive: false });
      button.addEventListener("touchend", toggleFromTouch, { passive: false });
      button.addEventListener("click", toggleOpen);
      dom.addEventListener("pennedTagReveal", () => { temporarilyOpenForTag = true; render(); requestAnimationFrame(reportContentHeight); });
      dom.addEventListener("pennedTagReset", () => { temporarilyOpenForTag = false; render(); });
      render();

      return {
        dom,
        contentDOM,
        update(updatedNode) {
          if (updatedNode.type.name !== "toggleItem") return false;
          currentNode = updatedNode;
          render();
          return true;
        },
        stopEvent(event) {
          if (selectionMode !== "off") return false;
          return event.target === button || button.contains(event.target);
        },
        ignoreMutation(mutation) {
          return (mutation.type === "attributes" && mutation.target === dom) || mutation.target === button || button.contains(mutation.target);
        },
        destroy() {
          button.removeEventListener("pointerdown", preventToggleFocus);
          button.removeEventListener("mousedown", preventToggleFocus);
          button.removeEventListener("touchstart", preventToggleFocus);
          button.removeEventListener("touchend", toggleFromTouch);
          button.removeEventListener("click", toggleOpen);
        },
      };
    };
  },
});

const SelectionTextHighlight = Extension.create({
  name: "vellixTextSelectionHighlight",
  addProseMirrorPlugins() {
    return [
      new Plugin({
        key: selectionHighlightPluginKey,
        state: {
          init: () => 0,
          apply: (transaction, value) =>
            transaction.getMeta(selectionHighlightPluginKey) || transaction.docChanged
              ? value + 1
              : value,
        },
        props: {
          decorations(state) {
            if (window.PennedBlockSelection) return DecorationSet.empty;
            selectionHighlightPluginKey.getState(state);
            if (selectionMode === "off" || !selection.size) return DecorationSet.empty;
            return selectedTextDecorationSet(state.doc);
          },
        },
      }),
    ];
  },
});

const selection = window.PennedBlockSelection?.selectionFacade() ?? new Set();
let selectionMode = "off";
let selectionDecorationRefreshQueued = false;
let lastSelectionHandleEvent = { key: "", time: 0 };
let lastHeight = -1;
let contentHeightFrame = null, lastContentHeightFrame = -1;
let lastVisualContentBottom = -1;
const isMeasuredFeature = node => node.type.name === "pageBreak" || node.type.name === "collection";
let measuredFeatureIndex = null;
let lastSelectionCount = -1;
let lastPageBreakSignature = "";
let lastNativeCollectionSignature = "";
let saveTimer, maxSaveTimer, pendingUpdateDoc = null, pendingTextOnly = true;
let supportsTextCheckpoints = false;

const templateComponents = createTemplateComponents({ Node, post: postToSwift,
  snapshot: () => snapshotPayload(), selectionActive: () => selectionMode !== "off" });
const attachments = createAttachments({ Node, Extension, post: postToSwift,
  iconCSS: name => `var(${iconAssetCSSVariable(name)}, ${cssBackgroundImageSource(iconSource(name))})`,
  snapshot: () => snapshotPayload(), selectionActive: () => selectionMode !== "off", reportHeight: () => requestAnimationFrame(reportContentHeight) });
const documentTags = createDocumentTags({ post: postToSwift, snapshot: () => snapshotPayload(),
  selectionActive: () => selectionMode !== "off", reportHeight: () => requestAnimationFrame(reportContentHeight) });

const textColor = createTextColor({ ...textColorDependencies, post: postToSwift,
  snapshot: () => snapshotPayload(), selectionActive: () => selectionMode !== "off" });
const listGridModule = createListGrid({ post: postToSwift,
  snapshot: () => snapshotPayload(), selectionActive: () => selectionMode !== "off" });
const codeBlocks = createCodeBlocks({ post: postToSwift, selectionActive: () => selectionMode !== "off", closeHistory });
const ListGridGuard = Extension.create({ name: "vellixListGridGuard", addProseMirrorPlugins: () => listGridModule.plugins });
const tabsModule = createTabs({ post: postToSwift,
  snapshot: () => snapshotPayload(), selectionActive: () => selectionMode !== "off",
  reportHeight: () => requestAnimationFrame(reportContentHeight) });
const TabsGuard = Extension.create({ name: "vellixTabsGuard", addProseMirrorPlugins: () => tabsModule.plugins });
const minimalFieldsModule = createMinimalFields({ post: postToSwift,
  snapshot: () => snapshotPayload(), selectionActive: () => selectionMode !== "off" });
const MinimalFieldsGuard = Extension.create({ name: "vellixMinimalFieldsGuard", addProseMirrorPlugins: () => minimalFieldsModule.plugins });
const informationCardModule = createInformationCard({ post: postToSwift, snapshot: () => snapshotPayload(), selectionActive: () => selectionMode !== "off" });
let linkEditingEnabled = true;
const documentLinks = createDocumentLinks({ post: postToSwift, canEdit: () => linkEditingEnabled, id,
  selectionActive: () => selectionMode !== "off",
  selectedBlock: () => selection.size === 1 ? (window.PennedBlockSelection?.selectedRecords()?.[0]
    ?? selectedBlockIndexMap().values().next().value) : null,
  reselect: blockID => {
    const record = topLevelModelBlocks().find(block => block.node.attrs.id === blockID);
    if (!record) return;
    if (selection.size && !selection.has(record.key)) selection.clear();
    if (selectionMode === "off") setSelectionMode("multi");
    if (!selection.has(record.key)) selection.add(record.key);
    setSelectionClasses(); reportFormattingState();
  },
});
// Block containers that hold multiple blocks and whose Enter behavior is a plain
// "new block" split, but which define no Enter handler of their own and so relied
// on the editor's default split. That default is a silent no-op inside a container
// (same regression the toggle hit), so this extension performs the split for them.
// Containers with intentional Enter behavior are deliberately excluded: clipped
// callouts, listItem/taskItem, codeBlock, caption, table, and toggleItem (which
// handles its own Enter). Nested blocks are matched by their DIRECT parent, so a
// paragraph inside a toggle inside a card is still handled by the toggle.
const BLOCK_SPLIT_CONTAINERS = new Set([
  "blockquote", "iconCallout", "plainCallout", "informationCardBody", "minimalFieldValue", "tabPanel", "weekDayPanel",
]);
const BlockContainerEnterFix = Extension.create({
  name: "blockContainerEnterFix",
  priority: 1000,
  addKeyboardShortcuts() {
    return {
      Enter: ({ editor }) => {
        const { $from, empty } = editor.state.selection;
        if (!empty || $from.depth < 2) return false;
        const parent = $from.node($from.depth - 1);
        if (!BLOCK_SPLIT_CONTAINERS.has(parent.type.name) ||
            (parent.type.name === "plainCallout" && clipSource(parent.attrs.clipSource))) return false;
        const splitPos = $from.pos;
        const afterBlock = $from.after($from.depth);
        return editor.chain().focus().command(({ tr, state, dispatch }) => {
          if (canSplit(state.doc, splitPos)) {
            if (dispatch) dispatch(tr.split(splitPos).scrollIntoView());
            return true;
          }
          const paragraph = state.schema.nodes.paragraph;
          if (!paragraph) return false;
          if (dispatch) {
            tr.insert(afterBlock, paragraph.create());
            tr.setSelection(TextSelection.near(tr.doc.resolve(afterBlock + 1)));
            dispatch(tr.scrollIntoView());
          }
          return true;
        }).run();
      },
    };
  },
});
// One-shot guard so the native-clipboard paste interceptor lets a Swift-driven
// WebKit fallback paste through instead of re-intercepting it (prevents a loop).
let pennedPasteBypass = false;
const editor = new Editor({
  element: document.getElementById("editor"),
  extensions: [
    BlockContainerEnterFix,
    textColor.mark, textColor.integration,
    CaretSlots,
    createCalloutListBackspace({ selectionActive: () => selectionMode !== "off" }),
    CalloutRowCleanup,
    LegacyToggleFollowers,
    calloutRow({ selectionActive: () => selectionMode !== "off" }),
    ...(window.PennedBlockSelection?.extensions({ Extension, Plugin, PluginKey, Decoration, DecorationSet,
      Fragment, Selection, Step, StepResult, closeHistory, post: postToSwift, modeChanged: mode => { selectionMode = mode; } }) ?? []),
    ...window.VellixTables.createExtensions({ Node, Extension, Plugin, PluginKey, Decoration, DecorationSet, TextSelection,
      post: postToSwift, selectionActive: () => selectionMode !== "off",
      modules: { "prosemirror-state": { Plugin, PluginKey, TextSelection, NodeSelection, Selection, SelectionRange },
        "prosemirror-model": { Fragment, Slice, DOMSerializer }, "prosemirror-view": { Decoration, DecorationSet },
        "prosemirror-transform": { Transform }, "prosemirror-keymap": { keydownHandler } } }),
    window.VellixStructuredPlaceholders.createExtension({ Extension, Plugin, PluginKey, Decoration, DecorationSet,
      TextSelection, NodeSelection, DOMSerializer, ReplaceStep, isHistoryTransaction }),
    VellixDocument,
    Caption,
    window.PennedMoodBar.createExtension({ Node, mergeAttributes, post: postToSwift }),
    window.PennedCountdown.createExtension({ Node, mergeAttributes, post: postToSwift,
      renderIcon: settings => iconCalloutGlyph(settings, renderCalloutLibraryIcon, true) }),
    window.PennedCalculator.createExtension({ Node, mergeAttributes, post: postToSwift, closeHistory, fonts: blockFontFamilies }),
    templateComponents.node,
    attachments.node,
    attachments.integration,
    documentTags.node,
    documentTags.integration,
    ...listGridModule.nodes,
    ListGridGuard,
    ...tabsModule.nodes,
    TabsGuard,
    WeekStrip.configure({ post: postToSwift, reportHeight: () => requestAnimationFrame(reportContentHeight) }),
    LinkedCalendarEvent,
    WeekDayPanel,
    ...minimalFieldsModule.nodes,
    ...informationCardModule.nodes,
    documentLinks.node,
    documentLinks.integration,
    MinimalFieldsGuard,
    StarterKit.configure({
      heading: false,
      link: { openOnClick: false },
      listItem: false,
      blockquote: false,
      code: false,
      codeBlock: false,
      document: false,
      horizontalRule: false,
      trailingNode: false,
    }),
    createLabelHeading({
      interactive: true,
      iconMask: name => `var(${iconAssetCSSVariable(name)}, ${cssBackgroundImageSource(iconSource(name))})`,
    }),
    PennedListItem,
    UnderlineableCode,
    codeBlocks.node,
    TaskList,
    VellixTaskItem,
    createTaskIntegration({ Extension, Plugin, PluginKey, post: postToSwift,
      selectionActive: () => selectionMode !== "off", canonicalize: normalizeTipTapDocument }),
    Placeholder.configure({ placeholder: "" }),
    BlockID,
    SelectionTextHighlight,
    GridCard,
    IconCallout,
    PlainCallout,
    VellixBlockquote,
    Divider,
    PageBreak,
    ToggleItem,
    inlinePropertyNode({
      post: postToSwift,
      selectionActive: () => selectionMode !== "off",
      reportHeight: reportContentHeight,
    }),
    pageReferenceNode({ post: postToSwift, selectionActive: () => selectionMode !== "off", indent: direction => movePageReferences(direction) }),
    collectionNode({ post: postToSwift, selectionActive: () => selectionMode !== "off", reportHeight: reportContentHeight }),
  ],
  content: normalizeTipTapDocument(null),
  autofocus: false,
  editorProps: {
    attributes: {
      class: "tiptap-editor",
      spellcheck: "false",
    },
    handleDOMEvents: {
      // WebKit sanitizes the HTML clipboard, stripping the data-* attributes that
      // carry a block's identity and settings, so an ordinary iOS paste collapses
      // rich blocks to plain text. For a selection that contains a structured block
      // we instead stash a lossless ProseMirror slice on the native pasteboard
      // (the sanitizer never touches a private UTI) alongside the normal HTML/text.
      // Plain inline/paragraph copies are left entirely to the browser.
      copy(view, event) {
        try {
          if (selectionMode !== "off") return false;
          const slice = view.state.selection.content();
          if (!slice.size) return false;
          let rich = false;
          slice.content.forEach(node => {
            if (node.isBlock && node.type.name !== "paragraph") rich = true;
            node.descendants(child => { if (child.isBlock && child.type.name !== "paragraph") rich = true; });
          });
          if (!rich) return false;
          const serializer = DOMSerializer.fromSchema(view.state.schema);
          const wrapper = document.createElement("div");
          wrapper.appendChild(serializer.serializeFragment(slice.content));
          const html = wrapper.innerHTML;
          const text = slice.content.textBetween(0, slice.content.size, "\n\n", "\n");
          const nativeJSON = JSON.stringify({ format: "penned-slice", version: 1, slice: slice.toJSON() });
          postToSwift("attachmentClipboard", { token: crypto.randomUUID(), html, text, nativeJSON });
          event.preventDefault();
          return true;
        } catch (_error) { return false; }
      },
      // Route every editor paste through the native layer, which reconstructs the
      // lossless slice when the private pasteboard type is present and otherwise
      // re-issues an ordinary WebKit paste (which this handler lets through).
      paste(view, event) {
        try {
          if (pennedPasteBypass) { pennedPasteBypass = false; return false; }
          if (selectionMode !== "off" || !view.editable) return false;
          pennedPasteBypass = true;
          setTimeout(() => { pennedPasteBypass = false; }, 1000);
          event.preventDefault();
          postToSwift("editorSmartPaste", {});
          return true;
        } catch (_error) { pennedPasteBypass = false; return false; }
      },
    },
    transformPastedText(text) {
      // Repair recognizable UTF-8 punctuation decoded as Windows-1252.
      // Leave correctly encoded text and unrelated characters untouched.
      return text
        .replace(/â€™/g, "’")
        .replace(/â€˜/g, "‘")
        .replace(/â€œ/g, "“")
        .replace(/â€\x9d/g, "”")
        .replace(/â€“/g, "–")
        .replace(/â€”/g, "—")
        .replace(/â€¦/g, "…");
    },
    transformPastedHTML(html) {
      // Some apps put HTML on the clipboard even when only text is selected.
      return html
        .replace(/â€™/g, "’")
        .replace(/â€˜/g, "‘")
        .replace(/â€œ/g, "“")
        .replace(/â€\x9d/g, "”")
        .replace(/â€“/g, "–")
        .replace(/â€”/g, "—")
        .replace(/â€¦/g, "…");
    },
  },
  onUpdate: ({ editor, transaction, appendedTransactions = [] }) => {
    const changes = [transaction, ...appendedTransactions].filter(tr => tr.docChanged);
    const textOnly = changes.length > 0 && changes.every(inlineTextEdit);
    if (!textOnly) {
      if (changes.length === 1 && changes[0].doc === editor.state.doc) renderChangedCalloutIcons(changes[0]);
      else renderCalloutIcons();
      // A structural edit can move a native overlay without changing total height.
      reportContentHeight();
    }
    if (window.PENNED_EDITOR_DIAGNOSTICS === true) traceCalloutAttrs("onUpdate-after-transaction", editor.getJSON());
    // Snapshot normalization can drop a text-empty blockquote next to a page
    // break. Let native reconcile relationships for those edits as well.
    const stableSnapshotStructure = textOnly && changes.every(tr =>
      tr.steps.every((step, index) => tr.docs[index].resolve(step.from).node(1).type.name !== "blockquote"));
    scheduleUpdate(editor.state.doc, stableSnapshotStructure);
  },
  onTransaction: ({ editor, transaction, appendedTransactions = [] }) => {
    for (const tr of [transaction, ...appendedTransactions]) {
      if (measuredFeatureIndex) updateMeasuredFeatures(tr);
    }
    if (window.PENNED_EDITOR_DIAGNOSTICS !== true) return;
    traceCalloutAttrs("onTransaction", editor.getJSON(), {
      docChanged: transaction.docChanged,
      selectionSet: transaction.selectionSet,
      stepCount: transaction.steps.length,
    });
  },
  onFocus: () => postToSwift("focus", { focused: true }),
  onBlur: () => { clearUnusedCaretSlots(editor); flushScheduledUpdate(); postToSwift("focus", { focused: false }); },
});

const caretTracking = createCaretTracking({ editor, post: postToSwift, verticalOnly: !!window.PennedBlockSelection,
  selectionActive: () => selectionMode !== "off" });

// Drive the height measurement from the content box resizing rather than from
// every keystroke. A ResizeObserver fires only when the editor DOM actually
// changes size — a line added or removed, text wrapping, a font finishing load,
// an image settling — which is the only time the reported height can change. This
// removes the per-keystroke forced layout that dominated long-document editing;
// same-line typing now triggers no height read at all.
if (typeof ResizeObserver === "function" && editor?.view?.dom) {
  const contentObserver = new ResizeObserver(reportContentHeight);
  contentObserver.observe(editor.view.dom);
  let activeBlock, activePosition;
  const observeActiveBlock = (force = false) => {
    const { $head } = editor.state.selection;
    const position = $head.depth && $head.parent.isTextblock ? $head.before() : null;
    if (!force && position === activePosition) return;
    activePosition = position;
    const next = position === null ? null : editor.view.nodeDOM(position);
    if (next === activeBlock) return;
    if (activeBlock instanceof Element) contentObserver.unobserve(activeBlock);
    activeBlock = next;
    // Text inside a column can wrap while the whole editor keeps the same height.
    if (activeBlock instanceof Element) contentObserver.observe(activeBlock);
  };
  editor.on("selectionUpdate", () => observeActiveBlock());
  editor.on("focus", () => observeActiveBlock(true));
  editor.on("transaction", ({ transaction, appendedTransactions = [] }) => {
    if ([transaction, ...appendedTransactions].some(tr => tr.docChanged && !inlineTextEdit(tr))) observeActiveBlock(true);
  });
  editor.on("destroy", () => contentObserver.disconnect());
}

function isCalloutProbeElement(element) {
  return !!element?.matches?.(
    ".vellix-callout, .vellix-callout-icon-button, .vellix-callout-icon-image",
  ) || !!element?.closest?.(".vellix-callout");
}

function mutationElementSummary(node) {
  if (!node || node.nodeType !== globalThis.Node.ELEMENT_NODE) {
    return null;
  }

  const element = node;
  const callout = element.matches?.(".vellix-callout")
    ? element
    : element.closest?.(".vellix-callout");
  return {
    tag: element.tagName?.toLowerCase?.() || null,
    className: element.className || null,
    serial: serialForElement(element),
    calloutSerial: serialForElement(callout),
    id: callout?.dataset?.vellixBlockId || null,
    icon: callout?.dataset?.calloutIcon || null,
    color: callout?.dataset?.calloutColor || null,
    src: element.getAttribute?.("src") || null,
    isConnected: element.isConnected,
  };
}

const editorElement = document.getElementById("editor");
const calloutMutationObserver = new MutationObserver((mutations) => {
  if (window.PENNED_EDITOR_DIAGNOSTICS !== true) return;
  mutations.forEach((mutation) => {
    const target = mutation.target;
    const added = Array.from(mutation.addedNodes || []).filter(isCalloutProbeElement);
    const removed = Array.from(mutation.removedNodes || []).filter(isCalloutProbeElement);
    const relevantAttribute =
      mutation.type === "attributes" &&
      target?.nodeType === globalThis.Node.ELEMENT_NODE &&
      isCalloutProbeElement(target);
    const relevantChildList = mutation.type === "childList" && (added.length || removed.length);

    if (!relevantAttribute && !relevantChildList) return;

    traceDiag("callout-dom-mutation", {
      type: mutation.type,
      attributeName: mutation.attributeName || null,
      oldValue: mutation.oldValue || null,
      target: mutationElementSummary(target),
      added: added.map(mutationElementSummary),
      removed: removed.map(mutationElementSummary),
    });

    if (target?.nodeType === globalThis.Node.ELEMENT_NODE) {
      const callout = target.matches?.(".vellix-callout")
        ? target
        : target.closest?.(".vellix-callout");
      const img = callout?.querySelector?.(".vellix-callout-icon-image");
      if (callout && img) {
        traceCalloutImageState("callout-dom-mutation-state", callout, img, {
          mutationType: mutation.type,
          attributeName: mutation.attributeName || null,
        });
      }
    }
  });
});

if (editorElement && window.PENNED_EDITOR_DIAGNOSTICS === true) {
  calloutMutationObserver.observe(editorElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeOldValue: true,
    attributeFilter: [
      "src",
      "style",
      "class",
      "hidden",
      "data-callout-icon",
      "data-callout-color",
      "data-vellix-block-id",
    ],
  });
}

// ProseMirror documents are immutable: selection/formatting transactions can
// reuse a snapshot without serializing and normalizing every block again.
let snapshotDocument = null;
let cachedSnapshot = null;
const snapshotNodes = new WeakMap();
function snapshotPayload() {
  const currentDocument = editor.state.doc;
  if (snapshotDocument === currentDocument && cachedSnapshot) return cachedSnapshot;
  const doc = documentWithoutUnusedCaretSlots(editor.state);
  const blocks = [];
  doc.forEach(node => {
    if (!snapshotNodes.has(node)) snapshotNodes.set(node, normalizeTipTapNode(node.toJSON()));
    blocks.push(snapshotNodes.get(node));
  });
  const projection = doc.attrs.taskHistoryProjection;
  const documentJSON = { type: "doc", ...(projection ? { attrs: { taskHistoryProjection: projection } } : {}), content: normalizedDocumentContent(blocks) };
  // Word/character counts are recomputed natively during save (TipTapContentAnalyzer)
  // and are ignored on "update"/"snapshot" messages.
  snapshotDocument = currentDocument;
  cachedSnapshot = { document: documentJSON };
  return cachedSnapshot;
}

function cancelScheduledUpdate() {
  window.clearTimeout(saveTimer);
  window.clearTimeout(maxSaveTimer);
  saveTimer = maxSaveTimer = undefined;
  pendingUpdateDoc = null;
  pendingTextOnly = true;
}

function flushScheduledUpdate() {
  if (!pendingUpdateDoc || editor.isDestroyed) return;
  const textOnly = pendingTextOnly && pendingUpdateDoc === editor.state.doc;
  cancelScheduledUpdate();
  const snapshot = snapshotPayload();
  if (textOnly && supportsTextCheckpoints) postToSwift("update", { textDocumentJSON: JSON.stringify(snapshot.document) });
  else postToSwift("update", snapshot);
}

function scheduleUpdate(doc, textOnly) {
  pendingUpdateDoc = doc;
  pendingTextOnly &&= textOnly;
  window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(flushScheduledUpdate, 500);
  maxSaveTimer ??= window.setTimeout(flushScheduledUpdate, 4000);
}

document.addEventListener("visibilitychange", () => { if (document.hidden) flushScheduledUpdate(); });
editor.on("destroy", cancelScheduledUpdate);

function roundedRectNumber(value) {
  return Number.isFinite(value) ? Math.round(value * 10) / 10 : null;
}

function shortText(value, limit = 120) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim();
  return text.length > limit ? `${text.slice(0, limit)}...` : text;
}

function domElementTrace(element) {
  if (!element) return null;
  const rect = element.getBoundingClientRect?.();
  return {
    tag: element.tagName?.toLowerCase?.() || null,
    dataType: element.getAttribute?.("data-type") || null,
    blockId: element.dataset?.vellixBlockId || null,
    className:
      typeof element.className === "string"
        ? shortText(element.className, 90)
        : shortText(element.getAttribute?.("class"), 90),
    top: rect ? roundedRectNumber(rect.top) : null,
    left: rect ? roundedRectNumber(rect.left) : null,
    width: rect ? roundedRectNumber(rect.width) : null,
    height: rect ? roundedRectNumber(rect.height) : null,
  };
}

function domParentTrace(element) {
  const parent = element?.parentElement;
  return parent ? domElementTrace(parent) : null;
}

function domPathTrace(element) {
  const parts = [];
  let current = element;
  while (current && current.nodeType === globalThis.Node.ELEMENT_NODE && parts.length < 6) {
    const tag = current.tagName?.toLowerCase?.() || "element";
    const dataType = current.getAttribute?.("data-type");
    const blockId = current.dataset?.vellixBlockId;
    const classes = typeof current.className === "string"
      ? current.className.split(/\s+/).filter(Boolean).slice(0, 2)
      : [];
    parts.push(
      `${tag}${dataType ? `[data-type=${dataType}]` : ""}${blockId ? `[block=${blockId}]` : ""}${classes.length ? `.${classes.join(".")}` : ""}`,
    );
    if (current.classList?.contains("tiptap-editor")) break;
    current = current.parentElement;
  }
  return parts.join(" <- ");
}

function topLevelBlockTraceRecords(source) {
  return topLevelDocumentBlocks(source).map((node, index) => ({
    index,
    id: nodeId(node),
    type: node.type,
    text: shortText(plainText(node)),
    childBlockIds: Array.isArray(node.content)
      ? node.content
          .filter((child) => child?.type && child.type !== "text")
          .map((child) => ({ type: child.type, id: nodeId(child), text: shortText(plainText(child), 60) }))
      : [],
  }));
}

function duplicateValues(values) {
  const counts = new Map();
  values.forEach((value) => {
    if (!value) return;
    counts.set(value, (counts.get(value) || 0) + 1);
  });
  return Array.from(counts.entries())
    .filter(([, count]) => count > 1)
    .map(([value, count]) => ({ value, count }));
}

function isVisibleElement(element) {
  if (!element) return false;
  const style = window.getComputedStyle(element);
  return style.display !== "none" && style.visibility !== "hidden" && element.getClientRects().length > 0;
}

function pathKey(path) {
  return Array.isArray(path) ? path.join(".") : "";
}

function selectionKeyForModelPath(path, pos) {
  const pathValue = pathKey(path);
  return pathValue ? `path:${pathValue}` : `pos:${pos}`;
}

function listContainerType(type) {
  return type === "bulletList" || type === "orderedList" || type === "taskList";
}

function listRowType(type) {
  return type === "listItem" || type === "taskItem";
}

function shouldSelectModelNode(type, parentType) {
  if (type === "plainCalloutRow") return false;
  if (["plainCalloutRow", "plainCallout"].includes(parentType) && !listContainerType(type)) return true;
  if (listRowType(type) && listContainerType(parentType)) return true;
  if (parentType === "doc" && !listContainerType(type)) return true;
  return false;
}

function cssIdentifier(value) {
  const raw = String(value || "");
  return globalThis.CSS?.escape ? globalThis.CSS.escape(raw) : raw.replace(/["\\]/g, "\\$&");
}

function elementForModelBlock(block) {
  const nodeDOM = editor.view.nodeDOM(block.pos);
  if (nodeDOM instanceof HTMLElement) return nodeDOM;

  const attrID = block.node?.attrs?.id;
  if (typeof attrID === "string" && attrID.trim()) {
    const escapedID = cssIdentifier(attrID.trim());
    const byID = editor.view.dom.querySelector(`[data-vellix-block-id="${escapedID}"]`);
    if (byID instanceof HTMLElement) return byID;
  }

  try {
    const domAtPos = editor.view.domAtPos(block.pos, 1);
    const element = domAtPos.node instanceof HTMLElement ? domAtPos.node : domAtPos.node?.parentElement;
    return element?.closest?.(
      [
        "[data-vellix-block-id]",
        "[data-type='taskItem']",
        "[data-vellix-toggle]",
        ".vellix-callout",
        ".vellix-plain-callout",
        "[data-vellix-divider]",
        "[data-vellix-page-break]",
        "li",
        "p",
        "blockquote",
      ].join(", "),
    ) || null;
  } catch (_e) {
    return null;
  }
}

function topLevelModelBlocks(rootDoc = editor.state.doc) {
  if (window.PennedBlockSelection) return window.PennedBlockSelection.records(rootDoc, normalizeTipTapNode);
  const blocks = [];

  const visitChildren = (parentNode, parentPos, parentPath) => {
    const parentType = parentNode.type.name;
    parentNode.forEach((node, offset, index) => {
      const type = node.type.name;
      const pos = parentType === "doc" ? offset : parentPos + 1 + offset;
      const path = [...parentPath, index];
      const json = normalizeTipTapNode(node.toJSON());
      const selectable = shouldSelectModelNode(type, parentType);

      if (selectable) {
        blocks.push({
          index: blocks.length,
          node,
          pos,
          key: selectionKeyForModelPath(path, pos),
          json,
          path,
          parentType,
          type,
        });
      }

      if (listContainerType(type) || ["plainCalloutRow", "plainCallout"].includes(type)) {
        visitChildren(node, pos, path);
      }
    });
  };

  visitChildren(rootDoc, 0, []);

  const last = blocks[blocks.length - 1];
  if (last?.parentType === "doc" && last?.type === "paragraph" && !plainText(last.json).trim()) {
    blocks.pop();
  }

  return blocks;
}

function addTextDecorationsForNode(node, nodePos, decorations) {
  node.descendants((child, childPos) => {
    if (!child.isText || !String(child.text || "").trim()) return true;
    const from = nodePos + 1 + childPos;
    const to = from + child.nodeSize;
    if (to > from) {
      decorations.push(
        Decoration.inline(from, to, {
          class: "vellix-selected-text-decoration",
        }),
      );
    }
    return true;
  });
}

function selectedTextDecorationSet(rootDoc) {
  const decorations = [];
  topLevelModelBlocks(rootDoc).forEach((block) => {
    if (!selection.has(block.key)) return;
    addTextDecorationsForNode(block.node, block.pos, decorations);
  });
  return decorations.length ? DecorationSet.create(rootDoc, decorations) : DecorationSet.empty;
}

function scheduleSelectionDecorationRefresh() {
  if (selectionDecorationRefreshQueued) return;
  selectionDecorationRefreshQueued = true;
  queueMicrotask(() => {
    selectionDecorationRefreshQueued = false;
    if (!editor?.view) return;
    editor.view.dispatch(
      editor.state.tr.setMeta(selectionHighlightPluginKey, { refresh: true }),
    );
  });
}

function selectableBlockRecords() {
  return topLevelModelBlocks().flatMap((block) => {
    const element = elementForModelBlock(block);
    if (!(element instanceof HTMLElement)) return [];
    if (!editor.view.dom.contains(element) || !isVisibleElement(element)) return [];
    return [{ ...block, element }];
  });
}

function clearSelectionDOMState() {
  document
    .querySelectorAll(
      [
        ".tiptap-editor .vellix-selectable-block",
        ".tiptap-editor .vellix-selected-block",
        ".tiptap-editor [data-vellix-selection-block]",
        ".tiptap-editor [data-vellix-selected]",
      ].join(", "),
    )
    .forEach((outer) => {
      outer.classList.remove("vellix-selectable-block", "vellix-selected-block");
      outer.removeAttribute("data-vellix-selected");
      outer.removeAttribute("data-vellix-selection-block");
      outer.removeAttribute("data-vellix-selection-key");
      outer.removeAttribute("data-vellix-selection-node-type");
      outer.removeAttribute("data-vellix-selection-index");
      outer.removeAttribute("data-vellix-selection-path");
      outer.style.removeProperty("--vellix-selection-y");
      outer.style.removeProperty("--vellix-selection-highlight-left");
      outer.style.removeProperty("--vellix-selection-highlight-top");
      outer.style.removeProperty("--vellix-selection-highlight-width");
      outer.style.removeProperty("--vellix-selection-highlight-height");
    });
}

function blockOuters() {
  return selectableBlockRecords().map((record) => record.element);
}

function selectionIndicatorOffset(outer) {
  const outerRect = outer.getBoundingClientRect();
  if (!outerRect.height) return 12;
  const isTaskItem =
    outer.matches?.("[data-type='taskItem']") ||
    (outer.tagName === "LI" && outer.hasAttribute("data-checked"));
  const markerTarget = isTaskItem
    ? outer.querySelector(":scope > label")
    : outer.matches?.("[data-type='taskList']")
      ? outer.querySelector("[data-type='taskItem'] > label, li[data-checked] > label")
      : null;
  const targetRect = markerTarget?.getBoundingClientRect?.();
  if (targetRect?.height) {
    return Math.max(12, Math.min(outerRect.height - 12, targetRect.top - outerRect.top + targetRect.height / 2));
  }
  return outerRect.height / 2;
}

function selectionHandleContainsEvent(outer, event) {
  const rect = outer.getBoundingClientRect();
  const visibleHandleSize = 18;
  const visibleHandleRightInset = 8;
  const centerX = rect.right - visibleHandleRightInset - visibleHandleSize / 2;
  const centerY = rect.top + selectionIndicatorOffset(outer);
  const hitRadius = 22;
  return Math.abs(event.clientX - centerX) <= hitRadius && Math.abs(event.clientY - centerY) <= hitRadius;
}

function textContentRect(element) {
  if (!element) return null;
  const rects = [];
  const walker = document.createTreeWalker(
    element,
    NodeFilter.SHOW_TEXT,
    {
      acceptNode(node) {
        return String(node.nodeValue || "").trim()
          ? NodeFilter.FILTER_ACCEPT
          : NodeFilter.FILTER_REJECT;
      },
    },
  );

  let node = walker.nextNode();
  while (node) {
    const range = document.createRange();
    range.selectNodeContents(node);
    rects.push(...Array.from(range.getClientRects()).filter((rect) => rect.width > 0 && rect.height > 0));
    range.detach?.();
    node = walker.nextNode();
  }

  if (!rects.length) return null;

  return rects.reduce(
    (union, rect) => ({
      left: Math.min(union.left, rect.left),
      top: Math.min(union.top, rect.top),
      right: Math.max(union.right, rect.right),
      bottom: Math.max(union.bottom, rect.bottom),
    }),
    {
      left: rects[0].left,
      top: rects[0].top,
      right: rects[0].right,
      bottom: rects[0].bottom,
    },
  );
}

function unionRects(rects) {
  const visibleRects = rects.filter((rect) => rect && rect.width > 0 && rect.height > 0);
  if (!visibleRects.length) return null;
  return visibleRects.reduce(
    (union, rect) => ({
      left: Math.min(union.left, rect.left),
      top: Math.min(union.top, rect.top),
      right: Math.max(union.right, rect.right),
      bottom: Math.max(union.bottom, rect.bottom),
    }),
    {
      left: visibleRects[0].left,
      top: visibleRects[0].top,
      right: visibleRects[0].right,
      bottom: visibleRects[0].bottom,
    },
  );
}

function selectionHighlightRect(outer) {
  const outerRect = outer.getBoundingClientRect();
  const nodeType = outer.dataset?.vellixSelectionNodeType || "";
  const horizontalPadding = 10;
  const verticalPadding = 6;
  const handleGutter = 44;
  let contentRect = null;

  if (nodeType === "taskItem" || outer.matches?.("[data-type='taskItem']")) {
    contentRect = unionRects([
      outer.querySelector(":scope > label")?.getBoundingClientRect?.(),
      textContentRect(outer.querySelector(":scope > div")),
    ]);
  } else if (nodeType === "blockquote" || outer.matches?.("blockquote")) {
    const textRect = textContentRect(outer);
    if (textRect) {
      contentRect = {
        left: outerRect.left,
        top: Math.min(outerRect.top, textRect.top),
        right: textRect.right,
        bottom: Math.max(outerRect.bottom, textRect.bottom),
      };
    } else {
      contentRect = outerRect;
    }
  } else if (nodeType === "divider" || outer.matches?.("[data-vellix-divider]")) {
    contentRect = outerRect;
  } else if (
    nodeType === "gridCard" ||
    nodeType === "iconCallout" ||
    nodeType === "plainCallout" ||
    nodeType === "pageBreak" ||
    nodeType === "toggleItem" ||
    outer.matches?.(".vellix-callout, .vellix-plain-callout, [data-vellix-page-break], [data-vellix-toggle], pre")
  ) {
    contentRect = outerRect;
  } else {
    contentRect = textContentRect(outer) || outerRect;
  }

  const maxRight = outerRect.right - handleGutter;
  const left = Math.max(outerRect.left, contentRect.left - horizontalPadding);
  const top = Math.max(outerRect.top, contentRect.top - verticalPadding);
  const right = Math.min(maxRight, Math.max(left + 12, contentRect.right + horizontalPadding));
  const bottom = Math.min(outerRect.bottom + verticalPadding, Math.max(top + 12, contentRect.bottom + verticalPadding));

  return {
    left: left - outerRect.left,
    top: top - outerRect.top,
    width: Math.max(12, right - left),
    height: Math.max(12, bottom - top),
  };
}

function setSelectionHighlightProperties(outer) {
  const rect = selectionHighlightRect(outer);
  outer.style.setProperty("--vellix-selection-highlight-left", `${rect.left}px`);
  outer.style.setProperty("--vellix-selection-highlight-top", `${rect.top}px`);
  outer.style.setProperty("--vellix-selection-highlight-width", `${rect.width}px`);
  outer.style.setProperty("--vellix-selection-highlight-height", `${rect.height}px`);
}

function selectionRecordForEvent(event) {
  if (selectionMode === "off" || !editor.view.dom.contains(event.target)) return null;

  const records = selectableBlockRecords();
  // Tabs are a single top-level block. In block-selection mode, their title
  // and exposed card border select the parent, while panel text retains its
  // own text-selection behavior outside block-selection mode.
  const tabs = event.target.closest?.(".penned-tabs[data-tabs]");
  if (tabs && (event.target === tabs || event.target.closest?.(".penned-tabs-header"))) {
    const tabsRecord = records.find(record => record.node.type.name === "tabs" && record.element === tabs);
    if (tabsRecord) return tabsRecord;
  }
  const weekStrip = event.target.closest?.(".penned-week-strip[data-week-strip]");
  if (weekStrip && (event.target === weekStrip || event.target.closest?.(".penned-week-strip-chrome"))) {
    const weekStripRecord = records.find(record => record.node.type.name === "weekStrip" && record.element === weekStrip);
    if (weekStripRecord) return weekStripRecord;
  }
  const closestBlock = event.target.closest?.("[data-vellix-selection-block='true']");
  if (
    closestBlock instanceof HTMLElement &&
    editor.view.dom.contains(closestBlock) &&
    selectionHandleContainsEvent(closestBlock, event)
  ) {
    const selectionKey = closestBlock.dataset.vellixSelectionKey;
    return records.find((record) => record.element === closestBlock || record.key === selectionKey) || {
      element: closestBlock,
      key: selectionKey,
    };
  }

  return records.find((record) => selectionHandleContainsEvent(record.element, event)) || null;
}

function handleSelectionHandleEvent(event) {
  if (window.PennedBlockSelection) return false;
  const record = selectionRecordForEvent(event);
  if (!record) return false;

  event.preventDefault();
  event.stopPropagation();
  const selectionKey = record.key || record.element?.dataset?.vellixSelectionKey;
  const now = performance.now();
  if (
    event.type === "click" &&
    selectionKey &&
    lastSelectionHandleEvent.key === selectionKey &&
    now - lastSelectionHandleEvent.time < 500
  ) {
    return true;
  }

  toggleBlockSelection(selectionKey);
  lastSelectionHandleEvent = { key: selectionKey || "", time: now };
  return true;
}

function pruneSelectionToSelectable(records) {
  const keys = new Set(records.map((record) => record.key));
  Array.from(selection).forEach((key) => {
    if (!keys.has(key)) selection.delete(key);
  });
}

function traceSelectionRegistry(label, selectableRecords) {
  const documentJSON = editor.getJSON();
  const topLevelBlocks = topLevelBlockTraceRecords(documentJSON);
  const topLevelById = new Map(topLevelBlocks.map((block) => [block.id, block]));
  const allCandidates = Array.from(document.querySelectorAll(".tiptap-editor [data-vellix-block-id]"));
  const visibleCandidates = allCandidates.filter(isVisibleElement);
  const candidateRecords = visibleCandidates.map((element, index) => {
    const blockId = element.dataset.vellixBlockId || "";
    const topLevelBlock = topLevelById.get(blockId);
    const elementTrace = domElementTrace(element);
    return {
      index,
      blockId,
      nodeType: topLevelBlock?.type || null,
      isTopLevelDocumentBlock: topLevelById.has(blockId),
      isDirectEditorChild: element.parentElement === editor.view.dom,
      domElement: elementTrace,
      parentNode: domParentTrace(element),
      path: domPathTrace(element),
      topPosition: elementTrace?.top ?? null,
    };
  });
  const registryRecords = selectableRecords.map((record) => {
    const elementTrace = domElementTrace(record.element);
    return {
      index: record.index,
      blockId: record.node.attrs?.id || null,
      selectionKey: record.key,
      nodeType: record.node.type.name,
      parentType: record.parentType,
      modelPath: record.path,
      prosemirrorPos: record.pos,
      domElement: elementTrace,
      parentNode: domParentTrace(record.element),
      path: domPathTrace(record.element),
      topPosition: elementTrace?.top ?? null,
    };
  });
  const candidateCountsByBlockId = Array.from(
    visibleCandidates.reduce((counts, element) => {
      const blockId = element.dataset.vellixBlockId || "";
      if (!blockId) return counts;
      counts.set(blockId, (counts.get(blockId) || 0) + 1);
      return counts;
    }, new Map()),
    ([blockId, count]) => ({ blockId, count }),
  );
  const duplicateTopPositions = duplicateValues(
    registryRecords.map((record) =>
      typeof record.topPosition === "number" ? String(Math.round(record.topPosition)) : null,
    ),
  );

  traceDiag("selection-registry", {
    label,
    mode: selectionMode,
    topLevelBlocks,
    duplicateTopLevelIds: duplicateValues(topLevelBlocks.map((block) => block.id)),
    modelBlocks: topLevelModelBlocks().map((block) => ({
      index: block.index,
      blockId: block.node.attrs?.id || null,
      selectionKey: block.key,
      nodeType: block.node.type.name,
      parentType: block.parentType,
      modelPath: block.path,
      prosemirrorPos: block.pos,
      text: shortText(plainText(block.json)),
    })),
    domCandidateCount: candidateRecords.length,
    candidateCountsByBlockId,
    domCandidates: candidateRecords,
    selectableCount: registryRecords.length,
    selectableBlocks: registryRecords,
    duplicateSelectableIds: duplicateValues(registryRecords.map((block) => block.selectionKey)),
    duplicateSelectableTopPositions: duplicateTopPositions,
  });
}

function setSelectionClasses() {
  if (window.PennedBlockSelection) { window.PennedBlockSelection.refresh(); return; }
  const inSelectionMode = selectionMode !== "off";
  document.documentElement.classList.toggle("vellix-selection-mode", inSelectionMode);
  document.documentElement.dataset.vellixSelectionMode = selectionMode;
  document.body?.classList.toggle("vellix-selection-mode", inSelectionMode);
  if (document.body) document.body.dataset.vellixSelectionMode = selectionMode;
  editor.setEditable(!inSelectionMode, false);

  clearSelectionDOMState();

  const selectableBlocks = selectableBlockRecords();
  pruneSelectionToSelectable(selectableBlocks);
  if (inSelectionMode) {
    traceSelectionRegistry("setSelectionClasses-before-apply", selectableBlocks);
  }

  selectableBlocks.forEach((record) => {
    const outer = record.element;
    const selected = selection.has(record.key);
    outer.classList.add("vellix-selectable-block");
    outer.classList.toggle("vellix-selected-block", selected);
    outer.setAttribute("data-vellix-selection-block", "true");
    outer.setAttribute("data-vellix-selection-key", record.key);
    outer.setAttribute("data-vellix-selection-node-type", record.node.type.name);
    outer.setAttribute("data-vellix-selection-index", String(record.index));
    outer.setAttribute("data-vellix-selection-path", pathKey(record.path));
    outer.setAttribute("data-vellix-selected", selected ? "true" : "false");
    outer.style.setProperty("--vellix-selection-y", `${selectionIndicatorOffset(outer)}px`);
    setSelectionHighlightProperties(outer);
  });

  if (lastSelectionCount !== selection.size) {
    lastSelectionCount = selection.size;
    postToSwift("selection", { count: selection.size });
  }
  scheduleSelectionDecorationRefresh();
}

function setSelectionMode(mode) {
  if (window.PennedBlockSelection) { window.PennedBlockSelection.setMode(mode); return; }
  const nextMode = mode === "single" || mode === "multi" ? mode : "off";
  const previousMode = selectionMode;
  const isExitingSelectionMode = previousMode !== "off" && nextMode === "off";
  selectionMode = nextMode;
  templateComponents.refresh();
  if (selectionMode === "off") selection.clear();
  if (selectionMode !== "off") {
    hideSlashMenu();
    attachments.command(editor, "attachmentPauseAll", {});
    editor.commands.blur();
  }
  setSelectionClasses();
  if (isExitingSelectionMode) {
    clearProseMirrorNodeSelectionForSelectionExit();
  }
  if (previousMode !== selectionMode) {
    postToSwift("selectionMode", { mode: selectionMode });
  }
  reportFormattingState();
}

function toggleBlockSelection(selectionKey) {
  if (!selectionKey || selectionMode === "off") return;
  if (selectionMode === "single") {
    selection.clear();
    selection.add(selectionKey);
  } else if (selection.has(selectionKey)) {
    selection.delete(selectionKey);
  } else {
    selection.add(selectionKey);
  }
  setSelectionClasses();
  postToSwift("haptic", { style: "light" });
}

function clearProseMirrorNodeSelectionForSelectionExit() {
  const currentSelection = editor.state.selection;
  if (!(currentSelection instanceof NodeSelection) && !(currentSelection instanceof AllSelection)) {
    editor.commands.blur();
    return;
  }

  try {
    const pos = Math.max(0, Math.min(currentSelection.from, editor.state.doc.content.size));
    const nextSelection = TextSelection.near(editor.state.doc.resolve(pos), 1);
    editor.view.dispatch(editor.state.tr.setSelection(nextSelection));
  } catch (_error) {
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.atStart(editor.state.doc)));
  }

  editor.commands.blur();
  window.getSelection?.()?.removeAllRanges?.();
}

function reportedVisualContentBottom(root, content) {
  let visualElement = null, offset = editor.state.doc.content.size;
  for (let index = editor.state.doc.childCount - 1; index >= 0; index--) {
    const node = editor.state.doc.child(index);
    offset -= node.nodeSize;
    const element = editor.view.nodeDOM(offset);
    if (element instanceof HTMLElement && isVisibleElement(element)) {
      visualElement = element;
      break;
    }
  }
  if (!(visualElement instanceof HTMLElement)) {
    return Math.max(0, Math.ceil(content.getBoundingClientRect().bottom - root.getBoundingClientRect().top));
  }

  const rootTop = root.getBoundingClientRect().top;
  const visualRect = visualElement.getBoundingClientRect();
  const contentStyle = window.getComputedStyle(content);
  const contentPaddingBottom = Number.parseFloat(contentStyle.paddingBottom) || 0;

  // The native page sheet owns its bottom inset. A final block's CSS margin is
  // inter-block spacing and must not become a second page-edge inset.
  return Math.max(
    0,
    Math.ceil(visualRect.bottom - rootTop + contentPaddingBottom),
  );
}

function reportContentHeight(timestamp) {
  if (typeof timestamp !== "number") {
    if (contentHeightFrame === null) contentHeightFrame = requestAnimationFrame(reportContentHeight);
    return;
  }
  if (contentHeightFrame !== null) cancelAnimationFrame(contentHeightFrame);
  contentHeightFrame = null;
  if (lastContentHeightFrame === timestamp) return;
  lastContentHeightFrame = timestamp;
  measureContentHeight();
}

function measuredFeatureRecords() {
  const doc = editor.state.doc;
  if (!measuredFeatureIndex || measuredFeatureIndex.doc !== doc) {
    measuredFeatureIndex = createNodeIndex(doc, isMeasuredFeature);
  }
  return measuredFeatureIndex.records;
}
function updateMeasuredFeatures(transaction) {
  if (!transaction.docChanged) return;
  if (measuredFeatureIndex.doc === transaction.before && !measuredFeatureIndex.records.length && inlineTextEdit(transaction)) {
    measuredFeatureIndex = { doc: transaction.doc, records: [], changed: [] };
    return;
  }
  measuredFeatureIndex = updateNodeIndex(measuredFeatureIndex, transaction, isMeasuredFeature);
}

function measureContentHeight() {
  const root = document.querySelector(".vellix-editor-page");
  const content = editor?.view?.dom;

  let height = 60;
  let visualContentBottom = 60;
  if (root && content instanceof HTMLElement && isVisibleElement(content)) {
    const top = root.getBoundingClientRect().top;
    const bottom = content.getBoundingClientRect().bottom;
    height = Math.max(60, Math.ceil(bottom - top + 2));
    visualContentBottom = Math.min(height, reportedVisualContentBottom(root, content));
  }

  if (Math.abs(height - lastHeight) > 1 || Math.abs(visualContentBottom - lastVisualContentBottom) > 1) {
    lastHeight = height;
    lastVisualContentBottom = visualContentBottom;
    postToSwift("height", { height, visualContentBottom });
  }

  const pageBreaks = [], collections = [];
  for (const { node, pos } of measuredFeatureRecords()) {
    const element = editor.view.nodeDOM(pos);
    if (!(element instanceof HTMLElement)) continue;
    if (node.type.name === "pageBreak") pageBreaks.push(element);
    else if (element.hasAttribute("data-native-collection")) collections.push(element);
  }
  reportPageBreakRegions(root, pageBreaks);
  const regions = collections.length ? nativeCollectionRegions(root, collections) : [];
  const signature = JSON.stringify(regions);
  if (signature !== lastNativeCollectionSignature) {
    lastNativeCollectionSignature = signature;
    postToSwift("nativeCollections", { regions });
  }
}

function reportPageBreakRegions(root, candidates) {
  if (!root) return;
  const rootRect = candidates.length ? root.getBoundingClientRect() : null;
  const regions = candidates
    .filter((element) => {
      const style = window.getComputedStyle(element);
      return style.display !== "none" && style.visibility !== "hidden" && element.getClientRects().length > 0;
    })
    .map((element) => {
      const rect = element.getBoundingClientRect();
      return {
        y: Math.max(0, Math.round((rect.top - rootRect.top) * 10) / 10),
        height: Math.max(0, Math.round(rect.height * 10) / 10),
      };
    });
  const signature = JSON.stringify(regions);
  if (signature === lastPageBreakSignature) return;
  lastPageBreakSignature = signature;
  postToSwift("pageBreaks", { regions });
}

function selectedBlocks() {
  const blocks = topLevelModelBlocks()
    .filter((block) => selection.has(block.key))
    .map((block) => block.json);
  if (!blocks.length) {
    postToSwift("error", { message: "Select at least one block first." });
    return null;
  }
  return blocks;
}

function selectedBlockIndexMap() {
  return topLevelModelBlocks().reduce((map, block) => {
    if (selection.has(block.key)) map.set(pathKey(block.path), block);
    return map;
  }, new Map());
}

function transformSelectedTopLevelBlocks(transform, includeTopLevel = false) {
  const mobileResult = window.PennedBlockSelection?.transformSelectedNested(transform, includeTopLevel);
  if (mobileResult !== undefined) {
    if (mobileResult) postToSwift("snapshot", snapshotPayload());
    return mobileResult;
  }
  const selectedByPath = selectedBlockIndexMap();
  if (!selectedByPath.size) {
    postToSwift("error", { message: "Select at least one block first." });
    return false;
  }
  const nextDocument = normalizeTipTapDocument(editor.getJSON());
  const transformNodes = (nodes, parentPath = []) => nodes.flatMap((node, index) => {
    const path = [...parentPath, index];
    const selectedBlock = selectedByPath.get(pathKey(path));
    const nodeWithChildren =
      node.content && !selectedBlock
        ? { ...node, content: transformNodes(node.content, path) }
        : node;
    const transformed = selectedBlock ? transform(nodeWithChildren, selectedBlock) : nodeWithChildren;
    return transformed ? [transformed] : [];
  });
  nextDocument.content = transformNodes(nextDocument.content);
  commitDocument(nextDocument);
  return true;
}

function walkTransform(nodes, transform) {
  return nodes.flatMap((node) => {
    const withChildren = node.content ? { ...node, content: walkTransform(node.content, transform) } : node;
    const transformed = transform(withChildren);
    return transformed ? [transformed] : [];
  });
}

function commitDocument(nextDocument, deletionRanges = null) {
  const normalizedDocument = normalizeTipTapDocument(nextDocument);
  traceCalloutAttrs("commitDocument-before-setContent", normalizedDocument);
  if (deletionRanges) {
    editor.chain().command(({ tr }) => { tr.setMeta("pennedPlaceholderDeletion", deletionRanges); return true; })
      .setContent(normalizedDocument, { emitUpdate: false }).run();
  } else editor.commands.setContent(normalizedDocument, { emitUpdate: false });
  traceCalloutAttrs("commitDocument-after-setContent", editor.getJSON());
  renderCalloutIcons();
  setSelectionClasses();
  reportContentHeight();
  postToSwift("update", snapshotPayload());
}

function cardConversionJSON(node, type) {
  if (node.type === type) return node;
  const blockID = nodeId(node);
  if (type === "gridCard") {
    const body = node.type === "codeBlock" ? { ...node, attrs: { ...node.attrs, id: id() } } : paragraph(node.content);
    return newGridCard(blockID, body);
  }
  const card = informationCardJSON();
  const [title, description, body] = card.content;
  card.attrs.id = blockID;
  title.content = node.type === "heading" ? node.content ?? [] : [];
  description.content = ["paragraph", "caption"].includes(node.type) ? node.content ?? [] : [];
  body.content = node.type === "codeBlock" ? [{ ...node, attrs: { ...node.attrs, id: id() } }] : [paragraph()];
  return card;
}

editor.storage.pennedCardConversion = (node, type) => editor.schema.nodeFromJSON(cardConversionJSON(node.toJSON(), type));

function transformNodeToBlock(node, type, payload = {}) {
  const heading = /^(text|label)Heading([1-4])$/.exec(type);
  if (heading) return transformNodeToBlock(node, "heading", { ...payload, level: Number(heading[2]), presentation: heading[1] });
  const blockID = nodeId(node);
  const isTextStyle = value => ["paragraph", "heading", "caption"].includes(value);
  const preservesInline = isTextStyle(node.type);
  const content = preservesInline ? node.content : taggedInlineContent(node) ?? inlineContent(plainText(node));
  const textStyleAttrs = preservesInline
    ? { id: blockID, textAlign: node.attrs?.textAlign, indent: node.attrs?.indent, blockFont: node.attrs?.blockFont }
    : { id: blockID };
  if (node.type === "listItem" && type === "heading") {
    const [first, ...rest] = node.content || [];
    return { ...node, content: [transformNodeToBlock(first || paragraph(), type, payload), ...rest] };
  }
  switch (type) {
    case "caption":
      return { type: "caption", attrs: textStyleAttrs, content };
    case "heading":
      return {
        type: "heading",
        attrs: {
          ...textStyleAttrs,
          level: Math.max(1, Math.min(6, Number(payload.level) || 3)),
          ...(payload.presentation === "label" || (node.type === "heading" && node.attrs.label)
            ? { label: { ...labelSettings(node.type === "heading" ? node.attrs.label : null),
              ...(payload.presentation ? { presentation: payload.presentation } : {}) } } : {}),
        },
        content,
      };
    case "quote":
      return { type: "blockquote", attrs: { id: id() }, content: [paragraph(content, textStyleAttrs)] };
    case "plainCallout":
      return {
        type: "plainCallout",
        attrs: { id: blockID, color: payload.color || DEFAULT_CALLOUT_COLOR },
        content: [paragraph(content, { ...textStyleAttrs, id: id() })],
      };
    case "checkListItem":
      return {
        type: "taskList",
        attrs: { id: id() },
        content: [{
          type: "taskItem",
          attrs: { id: id(), checked: false, crossed: false },
          content: [paragraph(content, textStyleAttrs)],
        }],
      };
    case "bulletListItem":
      return {
        type: "bulletList",
        attrs: { id: id() },
        content: [{ type: "listItem", attrs: { id: id() }, content: [paragraph(content, textStyleAttrs)] }],
      };
    case "numberedListItem":
      return {
        type: "orderedList",
        attrs: { id: id() },
        content: [{ type: "listItem", attrs: { id: id() }, content: [
          node.type === "heading" ? node : paragraph(content, textStyleAttrs),
        ] }],
      };
    case "toggleListItem":
      return { type: "toggleItem", attrs: { id: id(), open: true }, content: [
        payload.level ? { type: "heading", attrs: { ...textStyleAttrs, level: Math.max(1, Math.min(6, Number(payload.level) || 1)) }, content } : paragraph(content, textStyleAttrs),
      ] };
    case "codeBlock":
      return { type: "codeBlock", attrs: { id: blockID }, content: inlineContent(plainText(node)) };
    case "gridCard":
    case "informationCard":
      return cardConversionJSON(node, type);
    default:
      return paragraph(content, textStyleAttrs);
  }
}

function transformSelectedBlocks(type, payload = {}) {
  if (type === "gridCard" || type === "informationCard" || /^(text|label)Heading[1-4]$/.test(type)) {
    const blocks = window.PennedBlockSelection?.selectedRecords?.() ?? topLevelModelBlocks().filter(block => selection.has(block.key));
    const accepted = new Set(["paragraph", "heading", "caption", "codeBlock", type]);
    if (!blocks.length) return false;
    if (blocks.some(({ node }) => !accepted.has(node.type.name))) {
      postToSwift("error", { message: "Select text blocks for this conversion." });
      return false;
    }
    for (const { node, pos } of blocks) {
      const replacement = editor.schema.nodeFromJSON(transformNodeToBlock(node.toJSON(), type, payload));
      const $pos = editor.state.doc.resolve(pos);
      if (!$pos.parent.canReplace($pos.index(), $pos.index() + 1, Fragment.from(replacement))) {
        postToSwift("error", { message: "This block type is not supported inside this container." });
        return false;
      }
    }
  }
  if (type === "numberedListItem") {
    const blocks = topLevelModelBlocks().filter(block => selection.has(block.key));
    if (blocks.length && blocks.every(block => block.node.isTextblock || block.node.type.name === "listItem")) {
      const tr = closeHistory(editor.state.tr);
      for (const block of blocks.slice().reverse()) {
        const from = tr.mapping.map(block.pos + (block.node.isTextblock ? 1 : 2), 1);
        const to = tr.mapping.map(block.pos + block.node.nodeSize - (block.node.isTextblock ? 1 : 2), -1);
        const resolved = tr.doc.resolve(from);
        let numbered = false;
        for (let depth = resolved.depth; depth > 0; depth--) if (resolved.node(depth).type.name === "orderedList") numbered = true;
        if (numbered) continue;
        if (!editor.commandManager.createChain(tr).setTextSelection({ from, to }).toggleOrderedList().run()) return false;
      }
      if (tr.docChanged) editor.view.dispatch(tr);
      return true;
    }
  }
  return transformSelectedTopLevelBlocks((node) => transformNodeToBlock(node, type, payload), true);
}

function dividerConversionSelection(doc, blocks) {
  const protectedDepth = position => {
    for (let depth = 1; depth <= position.depth; depth++) {
      if (editor.storage?.vellixStructuredPlaceholders?.isProtected?.(position.node(depth))) return depth;
    }
    return 0;
  };
  const current = editor.state.selection;
  if (current instanceof TextSelection && current.empty && !protectedDepth(current.$from)) return current;
  const findText = (position, direction) => {
    let candidate = Selection.findFrom(doc.resolve(position), direction, true);
    while (candidate) {
      const depth = protectedDepth(candidate.$from);
      if (!depth) return candidate;
      const next = direction > 0 ? candidate.$from.after(depth) : candidate.$from.before(depth);
      candidate = Selection.findFrom(doc.resolve(next), direction, true);
    }
    return null;
  };
  const first = blocks.reduce((position, block) => Math.min(position, block.pos), doc.content.size);
  const last = blocks.reduce((a, b) => a.pos > b.pos ? a : b);
  return findText(last.pos + last.node.nodeSize, 1) || findText(first, -1) || NodeSelection.create(doc, last.pos);
}

function clearEditorNativeRange() {
  const native = window.getSelection();
  if (native && (editor.view.dom.contains(native.anchorNode) || editor.view.dom.contains(native.focusNode))) native.removeAllRanges();
}

function convertSelectedDividers(style) {
  if (selectionMode === "off" || editor.view.composing || !Object.prototype.hasOwnProperty.call(DIVIDER_STYLES, style)) return false;
  // Blur may flush an unused caret slot, so read positions only afterward.
  editor.view.dom.blur();
  const blocks = window.PennedBlockSelection?.selectedRecords?.() ||
    topLevelModelBlocks().filter(block => selection.has(block.key));
  const dividers = blocks.filter(block => ["divider", "horizontalRule"].includes(block.node.type.name));
  if (!dividers.length) return false;
  const tr = closeHistory(editor.state.tr);
  for (const block of dividers) {
    if (block.node.type.name === "divider" && block.node.attrs.style === style) continue;
    const parent = tr.doc.resolve(block.pos);
    if (!parent.parent.canReplaceWith(parent.index(), parent.index() + 1, editor.schema.nodes.divider, block.node.marks)) return false;
    tr.setNodeMarkup(block.pos, editor.schema.nodes.divider, { ...block.node.attrs, id: block.node.attrs.id || id(), style });
  }
  const changed = tr.docChanged;
  const caret = dividerConversionSelection(editor.state.doc, dividers);
  // Block conversion must not retain a text/node selection from a neighboring
  // callout. Establish the history bookmark before the attribute edit as well.
  if (!editor.state.selection.eq(caret)) {
    editor.view.dispatch(editor.state.tr.setSelection(caret).setMeta("addToHistory", false));
  }
  tr.setSelection(caret instanceof NodeSelection
    ? NodeSelection.create(tr.doc, tr.mapping.map(caret.from, -1))
    : caret.map(tr.doc, tr.mapping));
  tr.setMeta("pennedDividerStyleConversion", true);
  editor.view.dispatch(tr);
  clearEditorNativeRange();
  if (changed) {
    editor.view.dispatch(closeHistory(editor.state.tr));
    setSelectionClasses();
    postToSwift("snapshot", snapshotPayload());
  }
  return true;
}

function updateSelectedCalloutColor(color) {
  transformSelectedTopLevelBlocks((node) => {
    if (node.type === "gridCard") return node;
    if (node.type === "iconCallout") {
      return { ...node, attrs: { ...node.attrs, backgroundColor: iconCalloutSettings({ backgroundColor: color }).backgroundColor } };
    }
    if (node.type === "plainCallout") {
      return { ...node, attrs: { ...node.attrs, color } };
    }
    return transformNodeToBlock(node, "plainCallout", { color });
  });
}

function findGridCard(blockID, type = "gridCard") {
  if (!blockID) return null;
  let found = null;
  editor.state.doc.descendants((node, pos) => {
    if (found) return false;
    if (node.type.name === type && node.attrs.id === blockID) found = { node, pos };
    return !found;
  });
  return found;
}

function gridCardDiagnostic(stage, blockID, details = {}) {
  postToSwift("gridCardDiagnostic", {
    stage, blockID: typeof blockID === "string" ? blockID : "",
    ...details,
  });
}

function requestGridCard(blockID, type = "gridCard") {
  if (!editor.isEditable || selectionMode !== "off") {
    if (type === "gridCard") gridCardDiagnostic("open-rejected", blockID, {
      reason: !editor.isEditable ? "editor-read-only" : "block-selection-mode",
    });
    return false;
  }
  const target = findGridCard(blockID, type);
  if (!target || (type === "plainCallout" && clipSource(target.node.attrs.clipSource))) {
    if (type === "gridCard") gridCardDiagnostic("open-rejected", blockID, { reason: "block-not-found" });
    return false;
  }
  if (type === "gridCard") gridCardDiagnostic("open", blockID, {
    position: target.pos, contentBlocks: target.node.childCount,
    settingTypes: gridCardSettingTypes(gridCardSettings(target.node.attrs)),
  });
  editor.commands.blur();
  postToSwift(type === "gridCard" ? "gridCardSettings" : "iconCalloutSettings",
    { blockID, node: target.node.toJSON(), appearance: editorAppearance });
  return true;
}

function commitGridCard({ blockID, original, settings, text, originalText }, type = "gridCard") {
  const diagnostic = type === "gridCard";
  if (diagnostic) gridCardDiagnostic("save-requested", blockID, {
    editable: editor.isEditable, selectionMode,
    originalTypes: gridCardSettingTypes(original),
    requestedTypes: gridCardSettingTypes(settings),
    requestedChanges: gridCardSettingDifferences(original, settings),
  });
  if (!editor.isEditable || selectionMode !== "off" || !isRecord(settings) || !isRecord(original)) {
    if (diagnostic) gridCardDiagnostic("save-rejected", blockID, {
      reason: !editor.isEditable ? "editor-read-only" : selectionMode !== "off" ? "block-selection-mode" : "invalid-settings-payload",
    });
    return false;
  }
  const target = findGridCard(blockID, type);
  if (!target) {
    if (diagnostic) gridCardDiagnostic("save-rejected", blockID, { reason: "block-not-found" });
    return false;
  }
  if (type === "plainCallout" && clipSource(target.node.attrs.clipSource)) return false;
  const normalize = type === "plainCallout" ? plainCalloutSettings : type === "iconCallout" ? iconCalloutSettings : gridCardSettings;
  const current = normalize(target.node.attrs);
  const initial = normalize(original);
  const before = JSON.stringify(current);
  const after = normalize(settings);
  const attrsChanged = before !== JSON.stringify(after);
  const textChanged = type !== "gridCard" && typeof text === "string" && text !== originalText;
  if (diagnostic) gridCardDiagnostic("save-validation", blockID, {
    position: target.pos, contentBlocks: target.node.childCount,
    originalMatchesCurrent: before === JSON.stringify(initial),
    changedSinceOpen: gridCardSettingDifferences(initial, current),
    requestedChanges: gridCardSettingDifferences(current, after),
    initialTypes: gridCardSettingTypes(initial), currentTypes: gridCardSettingTypes(current),
    attrsChanged,
  });
  if (attrsChanged || textChanged) {
    if (before !== JSON.stringify(initial)) {
      if (diagnostic) gridCardDiagnostic("save-rejected", blockID, {
        reason: "original-settings-mismatch",
        changedSinceOpen: gridCardSettingDifferences(initial, current),
      });
      return false;
    }
    const tr = closeHistory(editor.state.tr);
    if (attrsChanged) tr.setNodeMarkup(target.pos, undefined, { ...target.node.attrs, ...after });
    if (textChanged) {
      const paragraphs = target.node.content.content;
      if (!paragraphs.every(p => p.type.name === "paragraph" && p.content.content.every(n => n.isText && !n.marks.length)) ||
          paragraphs.map(p => p.textContent).join("\n") !== originalText) return false;
      const content = text.replace(/\r\n?/g, "\n").split("\n").map((line, index) =>
        editor.schema.nodeFromJSON(paragraph(line.length ? [{ type: "text", text: line }] : [], paragraphs[index]?.attrs)));
      tr.replaceWith(target.pos + 1, target.pos + target.node.nodeSize - 1, Fragment.fromArray(content));
    }
    editor.view.dispatch(tr);
  }
  if (diagnostic) gridCardDiagnostic("save-accepted", blockID, {
    applied: attrsChanged, position: findGridCard(blockID, type)?.pos ?? null,
  });
  return snapshotPayload();
}

function updateCalloutColor(blockId, color) {
  if (!blockId) {
    postToSwift("error", { message: "Choose a callout before changing its color." });
    return;
  }
  const tr = editor.state.tr;
  editor.state.doc.descendants((node, pos) => {
    if (node.attrs.id === blockId && node.type.name === "plainCallout") {
      tr.setNodeMarkup(pos, undefined, { ...node.attrs, color: color || DEFAULT_CALLOUT_COLOR });
    }
  });
  if (tr.docChanged) editor.view.dispatch(tr);
}

function updateBlockquoteColor(blockId, color) {
  const nextColor = typeof color === "string" ? color.trim() : "";
  if (!blockId || !/^#[0-9a-f]{6}$/i.test(nextColor)) return false;
  let position = null;
  let target = null;
  editor.state.doc.descendants((node, pos) => {
    if (node.type.name === "blockquote" && nodeId(node) === blockId) {
      position = pos;
      target = node;
      return false;
    }
  });
  if (!target) return false;
  editor.view.dispatch(editor.state.tr.setNodeMarkup(position, undefined, {
    ...target.attrs,
    color: nextColor,
  }));
  return true;
}

const blockMarks = ["bold", "italic", "underline", "strike", "code"];

function formatSelectedBlocks(action, value = null) {
  if (selectionMode === "off" || !selection.size || !linkEditingEnabled) return false;
  if (["indent", "outdent"].includes(action)) {
    const direction = action === "indent" ? 1 : -1;
    if (moveSelectedStructuralBlocks(direction)) return true;
  }
  const blocks = window.PennedBlockSelection?.selectedRecords() ?? [...selectedBlockIndexMap().values()];
  const tr = closeHistory(editor.state.tr);
  const mark = blockMarks.includes(action) || action === "codeUnderline"
    ? editor.schema.marks[action === "codeUnderline" ? "code" : action] : null;
  const text = [];
  const set = (node, pos, attr, next) => {
    if (Object.hasOwn(node.attrs, attr) && node.attrs[attr] !== next) tr.setNodeAttribute(pos, attr, next);
  };
  for (const { node, pos } of blocks) {
    if (mark) {
      if (node.isAtom) continue;
      node.descendants((child, offset, parent) => {
        if (child.isText && parent.type.allowsMarkType(mark)) text.push({ child, from: pos + 1 + offset });
        return !child.isAtom;
      });
    } else if (action === "dividerColor" && node.type.name === "divider" && dividerColor(value)) {
      set(node, pos, "color", dividerColor(value));
    } else if (action === "headingPresentation" && ["text", "label"].includes(value)) {
      if (node.type.name === "heading" && labelLevel(node.attrs.level)) {
        const config = labelSettings(node.attrs.label);
        if (config.presentation !== value) set(node, pos, "label", { ...config, presentation: value });
      }
    } else if (action === "font" && Object.hasOwn(blockFontFamilies, value)) {
      if (node.isTextblock && !node.isAtom) set(node, pos, "blockFont", value);
      else if (!node.isAtom) node.descendants((child, offset) => {
        if (child.isTextblock && !child.isAtom) set(child, pos + 1 + offset, "blockFont", value);
        return !child.isAtom;
      });
    } else if (action === "align" && ["left", "center", "right", "justify"].includes(value)) {
      set(node, pos, "textAlign", value);
    } else if (action === "indent" || action === "outdent") {
      const indent = (Number(node.attrs.indent) || 0) + (action === "indent" ? 1 : -1);
      set(node, pos, "indent", Math.max(0, Math.min(6, indent)));
    }
  }
  if (mark) {
    const remove = text.every(({ child }) => mark.isInSet(child.marks));
    for (const { child, from } of text) {
      if (remove) tr.removeMark(from, from + child.nodeSize, mark);
      else tr.addMark(from, from + child.nodeSize, mark.create());
    }
  }
  if (!tr.docChanged) return false;
  editor.view.dispatch(tr.setMeta("preventAutolink", true));
  editor.view.dispatch(closeHistory(editor.state.tr));
  postToSwift("snapshot", snapshotPayload());
  return true;
}

function currentSelectionTextblocks() {
  const { state } = editor;
  const positions = new Map();
  const includeNode = (node, position) => {
    if (node?.isTextblock) positions.set(position, node);
  };

  const includeSelectionAncestors = ($position) => {
    for (let depth = $position.depth; depth > 0; depth -= 1) {
      const node = $position.node(depth);
      if (node.isTextblock) {
        includeNode(node, $position.before(depth));
        break;
      }
    }
  };

  includeSelectionAncestors(state.selection.$from);
  if (!state.selection.empty) {
    includeSelectionAncestors(state.selection.$to);
    state.doc.nodesBetween(state.selection.from, state.selection.to, (node, position) => {
      includeNode(node, position);
    });
  }

  return positions;
}

function selectedBlocksStyle() {
  if (selectionMode === "off" || !selection.size) return null;
  const blocks = window.PennedBlockSelection?.selectedRecords() ?? [...selectedBlockIndexMap().values()];
  if (!blocks.length) return null;

  const types = new Set();
  const alignments = new Set();
  const lists = new Set();
  const fonts = new Set();
  const dividerColors = new Set();
  const seenMarks = new Set(), missingMarks = new Set();
  const includeFont = node => {
    if (node.isTextblock && !node.isAtom && Object.hasOwn(node.attrs, "blockFont")) fonts.add(node.attrs.blockFont || "inherit");
  };
  for (const { node, type, pos, parentType } of blocks) {
    if (type === "divider") dividerColors.add(dividerColor(node.attrs.color));
    types.add(type === "heading" ? `heading${node.attrs.level}`
      : type === "listItem" || type === "taskItem" ? parentType : type);
    const resolved = editor.state.doc.resolve(pos);
    const parent = ["listItem", "taskItem"].includes(parentType) && resolved.depth > 0 ? resolved.node(-1).type.name : parentType;
    lists.add(listContainerType(parent) ? parent : null);
    if (Object.hasOwn(node.attrs, "textAlign")) alignments.add(node.attrs.textAlign || "left");
    includeFont(node);
    if (node.isAtom) continue;
    node.descendants((child, _offset, parent) => {
      includeFont(child);
      if (!child.isText) return !child.isAtom;
      for (const name of blockMarks) {
        const mark = editor.schema.marks[name];
        if (!mark || missingMarks.has(name) || !parent.type.allowsMarkType(mark)) continue;
        if (mark.isInSet(child.marks)) seenMarks.add(name);
        else missingMarks.add(name);
      }
      return false;
    });
  }
  return {
    type: types.size === 1 ? [...types][0] : null,
    canLabel: blocks.every(({ node }) => node.type.name === "heading" && labelLevel(node.attrs.level)),
    canColorDivider: dividerColors.size > 0,
    dividerColor: dividerColors.size === 1 ? [...dividerColors][0] : null,
    alignment: alignments.size === 1 ? [...alignments][0] : null,
    list: lists.size === 1 ? [...lists][0] : null,
    font: fonts.size === 1 ? [...fonts][0] : null,
    marks: blockMarks.filter(mark => seenMarks.has(mark) && !missingMarks.has(mark)),
    target: window.PennedBlockSelection?.formattingTarget?.() ?? null,
  };
}

let lastFormattingStateSignature = "";
function settingsKind(node, fromSelectionBar = false) {
  if (!node.attrs.id) return null;
  const type = node.type.name;
  if (["listGrid", "minimalFields", "informationCard", "tabs"].includes(type)) return type;
  if (fromSelectionBar && ["moodBar", "countdown", "calculator"].includes(type)) return type;
  if (type === "heading" && labelLevel(node.attrs.level) && node.attrs.label?.presentation === "label") return "headingLabel";
  if (type === "plainCallout" && !clipSource(node.attrs.clipSource)) return type;
  if (!fromSelectionBar) return null;
  if (["gridCard", "iconCallout", "codeBlock", "blockquote", "taskItem"].includes(type)) return type;
  if (type === "divider" && node.attrs.style === "washiTape") return "washiTape";
  if (type === "table" && node.firstChild?.firstChild) return type;
  if (type === "attachment" && node.attrs.file?.relativePath) return type;
  if (type === "inlineProperty" && node.attrs.property) return type;
  if (type === "templateComponent" && templateComponents.canConfigure(node)) return type;
  if (type === "collection" && node.attrs.collectionID) return type;
  if (type === "pageReference" && node.attrs.documentID) return "pageCard";
  return null;
}

function blockSettingsTarget() {
  const { $from, $to } = editor.state.selection;
  if (!editor.isEditable || selectionMode !== "off" || editor.state.selection instanceof NodeSelection) return null;
  for (let depth = $from.depth; depth > 0; depth--) {
    const node = $from.node(depth);
    if ($to.depth < depth || $to.start(depth) !== $from.start(depth) || !node.attrs.id) continue;
    const kind = settingsKind(node);
    if (kind) return { kind, node };
  }
  return null;
}

function selectedBlockSettingsTarget(link) {
  const selectionController = window.PennedBlockSelection;
  if (!selectionController || selectionMode === "off" || editor.options.editable === false || editor.view.composing) return null;
  const blocks = selectionController.selectedRecords();
  if (!blocks.length || blocks.some(block => block.type !== blocks[0].type)) return null;
  const owner = block => {
    const direct = settingsKind(block.node, true);
    if (direct) return { kind: direct, node: block.node, pos: block.pos };
    if (blocks.length === 1 && link && link.blockID === block.node.attrs.id) {
      return { kind: "documentLink", node: block.node, pos: block.pos };
    }
    const position = editor.state.doc.resolve(block.pos);
    for (let depth = position.depth; depth > 0; depth--) {
      const node = position.node(depth);
      const kind = settingsKind(node, true);
      if (kind) return { kind, node, pos: position.before(depth) };
    }
    return null;
  };
  const first = owner(blocks[0]);
  // A multi-selection may point to one settings owner (such as two paragraphs
  // inside one card), but never choose between different block instances.
  if (!first || blocks.slice(1).some(block => owner(block)?.pos !== first.pos)) return null;
  return first;
}

function requestSelectedBlockSettings(args) {
  const target = selectedBlockSettingsTarget();
  if (!target || editor.state.doc.nodeAt(target.pos) !== target.node ||
      target.kind !== args.kind || target.node.attrs.id !== args.blockID ||
      !args.selectionTarget || args.selectionTarget !== window.PennedBlockSelection?.formattingTarget()) return false;
  // Existing settings sheets edit by block identity and require text mode.
  // Leaving block selection changes no content and does not focus the editor.
  setSelectionMode("off");
  if (selectionMode !== "off" || editor.state.doc.nodeAt(target.pos) !== target.node) return false;
  return requestBlockSettings(target);
}

function requestBlockSettings(target = blockSettingsTarget()) {
  if (!target) return false;
  const { kind, node } = target;
  const blockId = node.attrs.id;
  switch (kind) {
    case "calculator":
      editor.view.dom.blur();
      postToSwift("calculatorSettings", { blockId, settings: window.PennedCalculator.settings(node.attrs), state: window.PennedCalculator.state(node.attrs.state) });
      return true;
    case "moodBar":
    case "countdown":
      editor.view.dom.blur();
      postToSwift(kind === "moodBar" ? "moodBarSettings" : "countdownSettings", {
        blockId, settings: kind === "moodBar" ? window.PennedMoodBar.settings(node.attrs) : window.PennedCountdown.settings(node.attrs),
      });
      return true;
    case "listGrid":
      return listGridModule.command(editor, "listGridRequestSettings", { blockId });
    case "minimalFields":
      return minimalFieldsModule.command(editor, "minimalFieldsRequestSettings", { blockId });
    case "tabs":
      return tabsModule.command(editor, "tabsRequestSettings", { blockId });
    case "informationCard":
      return informationCardModule.requestSettings(node);
    case "headingLabel":
      postToSwift("headingLabelSettings", { blockID: blockId, level: node.attrs.level,
        text: node.textBetween(0, node.content.size, "", "\n"), settings: labelSettings(node.attrs.label) });
      return true;
    case "blockquote":
      postToSwift("blockquoteColorPickerRequest", { blockId, currentColor: node.attrs.color || DEFAULT_BLOCKQUOTE_COLOR });
      return true;
    case "gridCard":
    case "iconCallout":
    case "plainCallout":
      return requestGridCard(blockId, kind);
    case "codeBlock":
      return codeBlocks.request(editor, blockId);
    case "washiTape":
      return requestWashiTape(blockId);
    case "table":
      return window.VellixTables.command("requestSettings", { tableID: blockId });
    case "attachment":
      return attachments.requestSettings(node);
    case "taskItem":
      postToSwift("taskMenuRequest", taskMenuContext(node));
      return true;
    case "inlineProperty":
      postToSwift("propertyEditorRequest", { blockId, property: node.attrs.property, resumeEditing: false });
      return true;
    case "templateComponent":
      return templateComponents.requestSettings(node);
    case "collection":
      postToSwift("collectionRequest", { action: "openCollection", blockID: blockId, collectionID: node.attrs.collectionID });
      return true;
    case "pageCard":
      postToSwift("pageCardSettingsRequest", { documentId: node.attrs.documentID });
      return true;
    default:
      return false;
  }
}

function reportFormattingState(force = false) {
  const selection = editor.state.selection;
  const available = selectionMode === "off" && editor.isEditable && !(selection instanceof NodeSelection);
  const alignments = available
    ? new Set([...currentSelectionTextblocks().values()].map(node => node.attrs.textAlign || "left"))
    : new Set();
  const parents = new Set();
  if (available && selection.empty) {
    for (let depth = 1; depth <= selection.$from.depth; depth++) parents.add(selection.$from.node(depth).type.name);
  }
  const inList = name => available && (selection.empty ? parents.has(name) : editor.isActive(name));
  const isTrailingListLine = available && selection.empty && trailingNumberedLine(editor.state);
  const linkFormatting = documentLinks.formatting(editor);
  const selectedSettings = selectedBlockSettingsTarget(linkFormatting.selectedLink);
  const state = {
    ...textColor.formattingState(editor),
    ...linkFormatting,
    selectedBlocksStyle: selectedBlocksStyle(),
    canOpenListGridSettings: available && !!listGridModule.selectedGridID(editor),
    blockSettingsKind: blockSettingsTarget()?.kind ?? null,
    selectedBlockSettings: selectedSettings ? {
      kind: selectedSettings.kind, blockID: selectedSettings.node.attrs.id,
      selectionTarget: window.PennedBlockSelection.formattingTarget(),
    } : null,
    bold: available && editor.isActive("bold"),
    italic: available && editor.isActive("italic"),
    underline: available && editor.isActive("underline"),
    strike: available && editor.isActive("strike"),
    code: available && editor.isActive("code"),
    alignment: alignments.size === 1 ? [...alignments][0] : null,
    checklist: inList("taskList") && !isTrailingListLine,
    bulletList: inList("bulletList") && !isTrailingListLine,
    numberList: inList("orderedList") && !emptyNumberedContinuation(editor.state) && !isTrailingListLine,
  };
  const signature = JSON.stringify(state);
  if (!force && signature === lastFormattingStateSignature) return;
  lastFormattingStateSignature = signature;
  postToSwift("formattingState", state);
}

function setCurrentTextblockAttribute(attribute, value) {
  const { state, view } = editor;
  const positions = currentSelectionTextblocks();

  if (!positions.size) return false;

  let transaction = state.tr;
  positions.forEach((node, position) => {
    if (!Object.prototype.hasOwnProperty.call(node.attrs || {}, attribute)) return;
    const nextValue = typeof value === "function" ? value(node) : value;
    transaction = transaction.setNodeMarkup(position, undefined, {
      ...node.attrs,
      [attribute]: nextValue,
    });
  });
  view.dispatch(transaction.scrollIntoView());
  view.focus();
  return true;
}

function indentCurrentPlainCallout(direction) {
  const { state, view } = editor;
  const { $from, from, to } = state.selection;
  for (let depth = $from.depth; depth > 0; depth--) {
    const node = $from.node(depth);
    if (node.type.name === "gridCard" || node.type.name === "iconCallout") return false;
    if (node.type.name !== "plainCallout") continue;
    const position = $from.before(depth);
    if (from < position || to > position + node.nodeSize) return false;
    const indent = Math.max(0, Math.min(6, (Number(node.attrs.indent) || 0) + direction));
    view.dispatch(state.tr.setNodeMarkup(position, undefined, { ...node.attrs, indent }).scrollIntoView());
    view.focus();
    return true;
  }
  return false;
}

function currentTextblockRange() {
  const { $from } = editor.state.selection;
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    const block = $from.node(depth);
    if (!block.isTextblock) continue;
    const start = $from.start(depth);
    let from = start, to = $from.end(depth);
    // Existing plain callouts can contain hard breaks. Keep those logical
    // lines independent for formatting without rewriting saved content.
    if ($from.node(depth - 1).type.name === "plainCallout") {
      block.forEach((child, offset) => {
        if (child.type.name !== "hardBreak") return;
        const boundary = start + offset;
        if (boundary + child.nodeSize <= $from.pos) from = boundary + child.nodeSize;
        else if (boundary >= $from.pos) to = Math.min(to, boundary);
      });
    }
    return { from, to };
  }
  return null;
}

function rangeFullyHasMark(documentNode, from, to, markType) {
  let hasText = false;
  let everyTextNodeHasMark = true;
  documentNode.nodesBetween(from, to, (node, position) => {
    if (!node.isText) return;
    const overlapStart = Math.max(from, position);
    const overlapEnd = Math.min(to, position + node.nodeSize);
    if (overlapStart >= overlapEnd) return;
    hasText = true;
    if (!markType.isInSet(node.marks)) everyTextNodeHasMark = false;
  });
  return hasText && everyTextNodeHasMark;
}

function toggleMarkForCurrentSelection(markName) {
  const { state, view } = editor;
  if (!state.selection.empty) {
    return editor.chain().toggleMark(markName).focus().run();
  }

  const range = currentTextblockRange();
  const markType = state.schema.marks[markName];
  if (!range || !markType || range.from === range.to) {
    return editor.chain().focus().toggleMark(markName).run();
  }

  const transaction = rangeFullyHasMark(state.doc, range.from, range.to, markType)
    ? state.tr.removeMark(range.from, range.to, markType)
    : state.tr.addMark(range.from, range.to, markType.create());
  view.dispatch(transaction.scrollIntoView());
  view.focus();
  return true;
}

function movePageReferences(direction, documentID = null) {
  return moveStructuralBlocks(direction, "pageReference", documentID);
}

function moveSelectedStructuralBlocks(direction) {
  return ["pageReference", "divider", "plainCallout", "callout", "iconCallout"].some(type => moveStructuralBlocks(direction, type));
}

function moveBlockExactly(tr, position, node, insertAt) {
  // Preflight both exact steps. The generic insert fitter may produce no step
  // at a schema boundary; moving a block must never commit the delete alone.
  const remove = new ReplaceStep(position, position + node.nodeSize, Slice.empty);
  const without = remove.apply(tr.doc).doc;
  if (!without) return null;
  const destination = remove.getMap().map(insertAt, -1);
  const insert = new ReplaceStep(destination, destination, new Slice(Fragment.from(node), 0, 0));
  if (!insert.apply(without).doc) return null;
  tr.step(remove).step(insert);
  return destination;
}

function moveStructuralBlocks(direction, type, documentID = null) {
  if (editor.options.editable === false) return false;
  const state = editor.state;
  let targets = [];
  if (selectionMode !== "off" && !documentID) {
    const selected = window.PennedBlockSelection?.selectedRecords() ?? topLevelModelBlocks().filter(block => selection.has(block.key));
    if (!selected.length || selected.some(block => block.type !== type)) return false;
    targets = selected;
  } else if (state.selection.node?.type.name === type &&
      (!documentID || state.selection.node.attrs.documentID === documentID)) {
    targets = [{ node: state.selection.node, pos: state.selection.from }];
  } else if (documentID) {
    state.doc.descendants((node, pos) => {
      if (!targets.length && node.type.name === type && node.attrs.documentID === documentID) targets.push({ node, pos });
    });
  }
  if (!targets.length) return false;
  const tr = closeHistory(state.tr);
  let selectedPosition = null;
  for (const target of targets.slice().sort((a, b) => direction > 0 ? a.pos - b.pos : b.pos - a.pos)) {
    const pos = tr.mapping.map(target.pos, 1), node = tr.doc.nodeAt(pos);
    if (node?.type.name !== type || node.attrs.id !== target.node.attrs.id) continue;
    const resolved = tr.doc.resolve(pos), parent = resolved.parent, index = resolved.index();
    const previous = index > 0 ? parent.child(index - 1) : null;
    if (direction > 0 && previous?.type.name === "toggleItem" &&
        previous.canReplace(previous.childCount, previous.childCount, Fragment.from(node))) {
      const previousPosition = pos - previous.nodeSize;
      const destination = pos - 1;
      const moved = moveBlockExactly(tr, pos, node, destination);
      if (moved === null) continue;
      if (previous.attrs.open === false) tr.setNodeAttribute(previousPosition, "open", true);
      selectedPosition = moved;
    } else if (direction < 0 && parent.type.name === "toggleItem" && index > 0 && resolved.depth > 0) {
      const outer = resolved.node(resolved.depth - 1), outerIndex = resolved.index(resolved.depth - 1) + 1;
      if (!outer.canReplace(outerIndex, outerIndex, Fragment.from(node))) continue;
      const moved = moveBlockExactly(tr, pos, node, resolved.after());
      if (moved === null) continue;
      selectedPosition = moved;
    } else {
      const indent = Math.max(0, Math.min(6, Number(node.attrs.indent) || 0));
      const next = Math.max(0, Math.min(6, indent + direction));
      if (next !== indent) tr.setNodeMarkup(pos, undefined, { ...node.attrs, indent: next });
      selectedPosition = pos;
    }
  }
  if (!tr.docChanged) return false;
  if (selectionMode === "off" && selectedPosition !== null) tr.setSelection(NodeSelection.create(tr.doc, selectedPosition));
  editor.view.dispatch(tr.scrollIntoView());
  editor.view.dispatch(closeHistory(editor.state.tr));
  return true;
}

function currentStructuralBlockContext() {
  const { $from } = editor.state.selection;
  const selected = editor.state.selection.node;
  if (selected?.type.name === "pageReference") {
    return { $from, parentDepth: $from.depth, parent: $from.parent, node: selected,
      index: $from.index(), position: $from.pos };
  }

  for (let depth = $from.depth; depth > 0; depth -= 1) {
    const parentDepth = depth - 1;
    const parent = $from.node(parentDepth);
    const node = $from.node(depth);
    if (
      node.isBlock &&
      (parent.type.name === "doc" || parent.type.name === "toggleItem")
    ) {
      return {
        $from,
        depth,
        parentDepth,
        parent,
        node,
        index: $from.index(parentDepth),
        position: $from.before(depth),
      };
    }
  }

  return null;
}

function restoreSelectionAfterBlockMove(transaction, oldPosition, newPosition) {
  if (editor.state.selection instanceof NodeSelection) {
    transaction.setSelection(NodeSelection.create(transaction.doc, newPosition));
    return;
  }
  const { anchor, head } = editor.state.selection;
  const documentEnd = transaction.doc.content.size;
  const mappedAnchor = Math.max(
    0,
    Math.min(documentEnd, newPosition + (anchor - oldPosition)),
  );
  const mappedHead = Math.max(
    0,
    Math.min(documentEnd, newPosition + (head - oldPosition)),
  );
  transaction.setSelection(TextSelection.between(
    transaction.doc.resolve(mappedAnchor),
    transaction.doc.resolve(mappedHead),
    1,
  ));
}

function indentCurrentBlockIntoPreviousToggle() {
  const context = currentStructuralBlockContext();
  if (!context || context.index === 0) return false;

  const { selection } = editor.state;
  if (
    selection.from < context.position ||
    selection.to > context.position + context.node.nodeSize
  ) {
    return false;
  }

  const previousNode = context.parent.child(context.index - 1);
  if (previousNode.type.name !== "toggleItem") return false;

  const { state, view } = editor;
  const previousPosition = context.position - previousNode.nodeSize;
  const insertAt = previousPosition + previousNode.nodeSize - 1;
  const transaction = state.tr;
  const destination = moveBlockExactly(transaction, context.position, context.node, insertAt);
  if (destination === null) return false;
  if (previousNode.attrs.open === false) transaction.setNodeAttribute(previousPosition, "open", true);
  restoreSelectionAfterBlockMove(transaction, context.position, destination);
  view.dispatch(transaction.scrollIntoView());
  view.focus();
  return true;
}

function outdentCurrentBlockFromToggle() {
  const context = currentStructuralBlockContext();
  if (
    !context ||
    context.parent.type.name !== "toggleItem" ||
    context.index === 0
  ) {
    return false;
  }

  const { selection } = editor.state;
  if (
    selection.from < context.position ||
    selection.to > context.position + context.node.nodeSize
  ) {
    return false;
  }

  const { state, view } = editor;
  const togglePosition = context.$from.before(context.parentDepth);
  const toggleEnd = togglePosition + context.parent.nodeSize;
  const transaction = state.tr;
  const insertAt = moveBlockExactly(transaction, context.position, context.node, toggleEnd);
  if (insertAt === null) return false;
  restoreSelectionAfterBlockMove(transaction, context.position, insertAt);
  view.dispatch(transaction.scrollIntoView());
  view.focus();
  return true;
}

function emptyNumberedContinuation(state) {
  const { empty, $from } = state.selection;
  if (!empty || $from.depth < 3 || $from.parent.type.name !== "paragraph" || $from.parent.content.size ||
      $from.node(-1).type.name !== "listItem" || $from.node(-2).type.name !== "orderedList" ||
      $from.index(-1) === 0) return null;
  return { position: $from.before(), item: $from.node(-1) };
}

function numberEmptyContinuation() {
  const { state, view } = editor;
  const target = emptyNumberedContinuation(state);
  if (!target) return false;
  const typesAfter = [{ type: target.item.type, attrs: { ...target.item.attrs, id: id() } }];
  if (!canSplit(state.doc, target.position, 1, typesAfter)) return false;
  // Repair an existing unnumbered continuation without toggling the whole item
  // out of its list. The paragraph and its caret become the next numbered item.
  const tr = state.tr.split(target.position, 1, typesAfter);
  tr.setSelection(TextSelection.create(tr.doc, tr.mapping.map(state.selection.from, 1)));
  view.dispatch(tr.scrollIntoView());
  view.focus();
  return true;
}

function formatCurrentSelection(action, value = null) {
  if (selectionMode !== "off" || !editor.isEditable) return false;
  const selectedType = editor.state.selection.node?.type.name;
  if (["indent", "outdent"].includes(action) && ["pageReference", "divider"].includes(selectedType)) {
    return moveStructuralBlocks(action === "indent" ? 1 : -1, selectedType);
  }

  switch (action) {
    case "bold":
    case "italic":
    case "underline":
    case "strike":
    case "code":
      return toggleMarkForCurrentSelection(action);
    case "align":
      return setCurrentTextblockAttribute("textAlign", value || "left");
    case "indent": {
      if (editor.chain().focus().sinkListItem("listItem").run()) return true;
      if (editor.chain().focus().sinkListItem("taskItem").run()) return true;
      if (indentCurrentBlockIntoPreviousToggle()) return true;
      if (indentCurrentPlainCallout(1)) return true;
      return setCurrentTextblockAttribute("indent", (node) =>
        Math.min(6, (Number(node.attrs?.indent) || 0) + 1));
    }
    case "outdent": {
      if (editor.chain().focus().liftListItem("listItem").run()) return true;
      if (editor.chain().focus().liftListItem("taskItem").run()) return true;
      if (outdentCurrentBlockFromToggle()) return true;
      if (indentCurrentPlainCallout(-1)) return true;
      return setCurrentTextblockAttribute("indent", (node) =>
        Math.max(0, (Number(node.attrs?.indent) || 0) - 1));
    }
    case "checkList":
      if (editor.state.selection.empty && trailingNumberedLine(editor.state) &&
          !editor.storage?.vellixStructuredPlaceholders?.isProtected?.(editor.state.selection.$from.parent)) {
        return editor.chain().command(({ tr }) => separateTrailingNumberedLine(tr)).toggleTaskList().focus().run();
      }
      return editor.chain().focus().toggleTaskList().run();
    case "bulletList":
      if (editor.state.selection.empty && trailingNumberedLine(editor.state) &&
          !editor.storage?.vellixStructuredPlaceholders?.isProtected?.(editor.state.selection.$from.parent)) {
        return editor.chain().command(({ tr }) => separateTrailingNumberedLine(tr)).toggleBulletList().focus().run();
      }
      return editor.chain().focus().toggleBulletList().run();
    case "numberList":
      if (editor.state.selection.empty && trailingNumberedLine(editor.state) &&
          !editor.storage?.vellixStructuredPlaceholders?.isProtected?.(editor.state.selection.$from.parent)) {
        return editor.chain().command(({ tr }) => separateTrailingNumberedLine(tr)).toggleOrderedList().focus().run();
      }
      if (numberEmptyContinuation()) return true;
      return editor.chain().focus().toggleOrderedList().run();
    default:
      return false;
  }
}

function deleteSelected(immediateSnapshot = false, removeListRows = false) {
  const before = editor.state.doc;
  if (window.PennedBlockSelection?.deleteSelected(removeListRows)) {
    postToSwift("snapshot", snapshotPayload());
    return editor.state.doc !== before;
  }
  const selectedByPath = selectedBlockIndexMap();
  if (!selectedByPath.size) {
    postToSwift("error", { message: "Select at least one block first." });
    return false;
  }
  const nextDocument = normalizeTipTapDocument(editor.getJSON());
  const deleteNodes = (nodes, parentPath = []) => nodes.flatMap((node, index) => {
    const path = [...parentPath, index];
    if (selectedByPath.has(pathKey(path))) return [];
    if (!node.content) return [node];
    const content = deleteNodes(node.content, path);
    if (listContainerType(node.type) && !content.length) return [];
    return [{ ...node, content }];
  });
  nextDocument.content = deleteNodes(nextDocument.content);
  const fileOperation = containsAttachments([...selectedByPath.values()].map(block => block.json));
  const deletionRanges = [...selectedByPath.values()].map(block => ({ from: block.pos, to: block.pos + block.node.nodeSize }));
  if (fileOperation) editor.view.dispatch(closeHistory(editor.state.tr));
  selection.clear();
  commitDocument(nextDocument.content.length ? nextDocument : normalizeTipTapDocument(null), deletionRanges);
  if (fileOperation) editor.view.dispatch(closeHistory(editor.state.tr));
  if (fileOperation || immediateSnapshot) postToSwift("snapshot", snapshotPayload());
  return editor.state.doc !== before;
}

// A page card only references a page by documentID; two cards pointing at the
// same id share one page. When a card is duplicated or pasted we clear its
// documentID (the card briefly shows as pending) and queue it, keyed by its
// already-freshened block id, so native can clone the page into an independent
// copy and repoint this card at it. Nested cards inside are queued too.
function detachPageReferences(nodes, pending) {
  const walk = node => {
    if (node && node.type === "pageReference" && node.attrs &&
        typeof node.attrs.documentID === "string" && node.attrs.documentID &&
        typeof node.attrs.id === "string" && node.attrs.id) {
      pending.push({ blockId: node.attrs.id, sourceDocumentID: node.attrs.documentID });
      node.attrs = { ...node.attrs, documentID: "" };
    }
    if (node && Array.isArray(node.content)) node.content.forEach(walk);
  };
  (nodes || []).forEach(walk);
}

function duplicateSelected() {
  const selectedByPath = selectedBlockIndexMap();
  if (!selectedByPath.size) {
    postToSwift("error", { message: "Select at least one block first." });
    return;
  }
  const nextDocument = normalizeTipTapDocument(editor.getJSON());
  const fileOperation = containsAttachments([...selectedByPath.values()].map(block => block.json));
  // Give the duplicate its own identity: deep-clone, then regenerate every nested
  // block/card id (and remap internal references such as a tabs block's active
  // tab) with the same helper the clipboard paste uses. Without fresh ids the copy
  // keeps the original's ids, so editing one block's settings retargets the other.
  // Page cards are also detached below so native clones their page into an
  // independent copy rather than sharing the original's page.
  const pageClones = [];
  const duplicateNodes = (nodes, parentPath = []) => nodes.flatMap((node, index) => {
    const path = [...parentPath, index];
    const nodeWithChildren = node.content ? { ...node, content: duplicateNodes(node.content, path) } : node;
    if (!selectedByPath.has(pathKey(path))) return [nodeWithChildren];
    const copy = normalizeTipTapNode(freshClipboardBlockIDs([JSON.parse(JSON.stringify(nodeWithChildren))])[0]);
    detachPageReferences([copy], pageClones);
    return [nodeWithChildren, copy];
  });
  nextDocument.content = duplicateNodes(nextDocument.content);
  if (fileOperation) editor.view.dispatch(closeHistory(editor.state.tr));
  selection.clear();
  commitDocument(nextDocument);
  if (fileOperation) { editor.view.dispatch(closeHistory(editor.state.tr)); postToSwift("snapshot", snapshotPayload()); }
  if (pageClones.length) postToSwift("clonePageReferences", { pairs: pageClones });
}

async function copySelected() {
  // Preserve the exact selected node trees for the native Penned clipboard.
  // The normalizer used elsewhere can change attrs and is not a copy format.
  const blocks = topLevelModelBlocks()
    .filter(block => selection.has(block.key))
    .map(block => block.node.toJSON());
  if (!blocks.length) {
    postToSwift("error", { message: "Select at least one block first." });
    return false;
  }
  const copiedFiles = await attachments.copyBlocks(editor, blocks, plainText(blocks));
  if (copiedFiles !== undefined) return copiedFiles;
  try {
    await navigator.clipboard?.writeText(plainText(blocks) || JSON.stringify(blocks));
    return true;
  } catch (_e) { return false; }
}

async function cutSelected() {
  const document = editor.state.doc, keys = [...selection].sort().join("|");
  if (!await copySelected() || editor.state.doc !== document || [...selection].sort().join("|") !== keys) return false;
  deleteSelected();
  return true;
}

let pendingSubpage = null;

function requestSubpage() {
  const blocks = selectedBlocks();
  if (!blocks) return false;
  const token = id();
  pendingSubpage = { token, doc: editor.state.doc, keys: [...selection].sort() };
  postToSwift("selectedBlocksForSubpage", {
    token,
    document: normalizeTipTapDocument({ type: "doc", content: blocks }),
  });
  return true;
}

function placeGroupedPage(token, documentID) {
  if (pendingSubpage?.token !== token) return false;
  const request = pendingSubpage;
  pendingSubpage = null;
  if (!editor.options.editable || selectionMode === "off" || editor.state.doc !== request.doc ||
      selection.size !== request.keys.length || !request.keys.every(key => selection.has(key)) ||
      typeof documentID !== "string" || !documentID) return false;

  const { state } = editor;
  const reference = state.schema.nodes.pageReference.create({ id: id(), documentID });
  let position = state.doc.content.size;
  // Leave unselected trailing editing lines after the page, as on legacy recovery.
  // Do not cross a selected block: the desktop selection still uses model paths.
  for (let index = state.doc.childCount - 1; index >= 0; index--) {
    const node = state.doc.child(index);
    const start = position - node.nodeSize;
    if (node.type.name !== "paragraph" || node.content.size || node.attrs.placeholderEnabled ||
        node.attrs.indent || node.attrs.textAlign || selection.has(selectionKeyForModelPath([index], start))) break;
    position = start;
  }
  // Creation and reparenting are persisted natively. Like the previous
  // unplaced page, the new reference survives undo of the source deletion.
  const insert = state.tr.insert(position, reference)
    .setMeta("addToHistory", false).setMeta("preventUpdate", true);
  editor.view.dispatch(insert);
  if (editor.state.doc === state.doc) return false;
  editor.view.dispatch(closeHistory(editor.state.tr).setMeta("addToHistory", false));
  if (!deleteSelected(true)) {
    postToSwift("snapshot", snapshotPayload());
    postToSwift("error", { message: "The nested page was created, but the source blocks could not be removed." });
  }
  return true;
}

function insertNode(node) {
  // Direct native insertions (e.g. Divider) share the same Calendar target as
  // the Add Block menu instead of always appending at the document root.
  const tr = editor.state.tr;
  const activeCalendar = ensureCalendarInsertionSelection(tr);
  if (activeCalendar && (tr.docChanged || tr.selectionSet)) editor.view.dispatch(tr.setMeta("addToHistory", false));
  if (selectionInsideCalendar(editor.state.selection)) {
    return editor.commands.insertContent(normalizeTipTapNode(node));
  }
  return editor.commands.insertContentAt(editor.state.doc.content.size, normalizeTipTapNode(node));
}

function blockNodeForKey(key) {
  const label = /^labelHeading([1-4])$/.exec(key);
  if (label) return { type: "heading", attrs: { id: id(), level: Number(label[1]), label: { ...labelSettings(), presentation: "label" } } };
  if (key.startsWith("property:")) {
    return { type: "inlineProperty", attrs: { id: id(), property: normalizeProperty({ kind: key.slice(9) }) } };
  }
  switch (key) {
    case "calculator":
      return { type: "calculator", attrs: { id: id(), state: window.PennedCalculator.initialState() } };
    case "countdown":
      return { type: "countdown", attrs: window.PennedCountdown.newAttrs() };
    case "moodBar":
      return { type: "moodBar", attrs: { id: id() } };
    case "caption":
      return { type: "caption", attrs: { id: id() } };
    case "heading1":
      return { type: "heading", attrs: { id: id(), level: 1 } };
    case "heading2":
      return { type: "heading", attrs: { id: id(), level: 2 } };
    case "heading3":
      return { type: "heading", attrs: { id: id(), level: 3 } };
    case "heading4":
      return { type: "heading", attrs: { id: id(), level: 4 } };
    case "heading5":
      return { type: "heading", attrs: { id: id(), level: 5 } };
    case "toggleListItem":
      return { type: "toggleItem", attrs: { id: id(), open: true }, content: [paragraph()] };
    case "toggleHeading1":
      return {
        type: "toggleItem",
        attrs: { id: id(), open: true },
        content: [{ type: "heading", attrs: { id: id(), level: 1 } }],
      };
    case "toggleHeading2":
      return {
        type: "toggleItem",
        attrs: { id: id(), open: true },
        content: [{ type: "heading", attrs: { id: id(), level: 2 } }],
      };
    case "toggleHeading3":
      return {
        type: "toggleItem",
        attrs: { id: id(), open: true },
        content: [{ type: "heading", attrs: { id: id(), level: 3 } }],
      };
    case "toggleHeading4":
      return {
        type: "toggleItem",
        attrs: { id: id(), open: true },
        content: [{ type: "heading", attrs: { id: id(), level: 4 } }],
      };
    case "toggleHeading5":
      return {
        type: "toggleItem",
        attrs: { id: id(), open: true },
        content: [{ type: "heading", attrs: { id: id(), level: 5 } }],
      };
    case "gridCard":
      return newGridCard(id(), paragraph());
    case "iconCallout":
      return { type: "iconCallout", attrs: { id: id(), ...ICON_CALLOUT_DEFAULTS }, content: [paragraph()] };
    case "plainCallout":
      return { type: "plainCallout", attrs: { id: id(), color: ICON_CALLOUT_DEFAULTS.backgroundColor }, content: [paragraph()] };
    case "quote":
      return { type: "blockquote", attrs: { id: id() }, content: [paragraph()] };
    case "checkListItem":
      return {
        type: "taskList",
        attrs: { id: id() },
        content: [{
          type: "taskItem",
          attrs: { id: id(), checked: false, crossed: false },
          content: [paragraph()],
        }],
      };
    case "bulletListItem":
      return {
        type: "bulletList",
        attrs: { id: id() },
        content: [{ type: "listItem", attrs: { id: id() }, content: [paragraph()] }],
      };
    case "numberedListItem":
      return {
        type: "orderedList",
        attrs: { id: id() },
        content: [{ type: "listItem", attrs: { id: id() }, content: [paragraph()] }],
      };
    case "codeBlock":
      return { type: "codeBlock", attrs: { id: id() } };
    case "divider":
      return { type: "divider", attrs: { id: id(), style: DEFAULT_DIVIDER_STYLE } };
    case "divider:dottedCircles":
    case "divider:tinyDots":
      return { type: "divider", attrs: { id: id(), style: "dottedCircles" } };
    case "divider:thickLine":
      return { type: "divider", attrs: { id: id(), style: "thickLine" } };
    case "divider:thinLine":
      return { type: "divider", attrs: { id: id(), style: "thinLine" } };
    case "divider:fourCircles":
    case "divider:fourDots":
      return { type: "divider", attrs: { id: id(), style: "fourCircles" } };
    case "pageBreak":
      return { type: "pageBreak", attrs: { id: id() } };
    case "paragraph":
    default:
      return paragraph();
  }
}

function tabsCheckpoint(stage, details = {}) {
  // Independent WebKit message, delivered before the insertion command returns.
  // Keep payload small and avoid serializing the document.
  postToSwift("tabsDiagnostic", { stage, ...details });
}

function insertContainerAtBlockBoundary(tr, node, range, depth) {
  const $cursor = tr.selection.$from;
  if (range && $cursor.depth === depth && $cursor.parent.isTextblock &&
      range.from === $cursor.start() && range.to === $cursor.end()) {
    const from = $cursor.before();
    const $boundary = tr.doc.resolve(from);
    if ($boundary.parent.canReplaceWith($boundary.index(), $boundary.index() + 1, node.type)) {
      tr.replaceWith(from, $cursor.after(), node);
      return from;
    }
  }
  const boundary = $cursor.depth >= depth ? $cursor.after(depth) : $cursor.pos;
  if (range) tr.delete(range.from, range.to);
  const position = tr.mapping.map(boundary);
  const $position = tr.doc.resolve(position);
  if (!$position.parent.canReplaceWith($position.index(), $position.index(), node.type)) return null;
  tr.insert(position, node);
  return position;
}

function panelChildDepth($cursor) {
  return insertionPanelDepth($cursor);
}

let pendingExistingEventConversion = null;
function insertBlockByKey(key, range = null, color = null, insertionToken = null) {
  if (!editor.isEditable || selectionMode !== "off") return false;
  if (insertionToken && !restoreCaretInsertion(editor, insertionToken)) return false;
  // Native Add Block > Paragraph must create/focus the paragraph *inside* the
  // last selected date. Calling a generic chain.focus() here can resurrect
  // WebKit's old caret in the Infocard above the Calendar on iOS.
  const rememberedCalendar = activeCalendarTarget(editor);
  if (key === "paragraph" && !range && !insertionToken && rememberedCalendar) {
    const tr = editor.state.tr;
    const result = appendParagraphToCalendarDate(tr, rememberedCalendar);
    if (result) {
      editor.view.dispatch(tr.scrollIntoView());
      editor.view.focus();
      postToSwift("calendarDiagnostic", { stage: "insert-paragraph-caret", blockID: result.stripID,
        date: result.date, position: editor.state.selection.from, inserted: result.inserted });
      requestAnimationFrame(reportContentHeight);
      return true;
    }
  }
  // One shared insertion target for every Add Block/toolbar/slash-menu type.
  // The selected Calendar date wins over an old caret in a hidden date panel.
  const calendarTr = editor.state.tr;
  const calendarTarget = ensureCalendarInsertionSelection(calendarTr,
    rememberedCalendar && !selectionInsideCalendar(editor.state.selection)
      ? { stripPos: rememberedCalendar.stripPos, date: rememberedCalendar.date, force: true } : {});
  if (calendarTarget) {
    if (calendarTr.docChanged || calendarTr.selectionSet) editor.view.dispatch(calendarTr.setMeta("addToHistory", false));
    // A stale explicit range must not replace content in the hidden panel.
    range = null;
    postToSwift("calendarDiagnostic", { stage: "insert-target", blockID: calendarTarget.stripID,
      date: calendarTarget.date, blockType: key });
  }
  if (key === "templates") {
    if (range) editor.commands.deleteRange(range);
    const token = beginCaretInsertion(editor);
    editor.commands.blur();
    postToSwift("templateRequest", { token });
    return true;
  }
  if (key === "divider:washiTape") return insertWashiTape(range);
  const column = key === "plainCallout" ? activeColumnInsertion(editor.state) : null;
  const location = editor.state.selection.$from;
  if (!column && location.parent.type.name === "paragraph" && location.depth > 1 &&
      location.node(-1).type.name === "plainCalloutRow") {
    if (!placeCaretInSlot(editor, location.after(location.depth - 1))) return false;
    range = null;
  }
  if (key === "collection") {
    if (!editor.isEditable || selectionMode !== "off") return false;
    const blockID = id();
    const node = { type: "collection", attrs: { id: blockID, collectionID: "", documentID: "" } };
    const chain = editor.chain();
    const selectedCollection = editor.state.selection instanceof NodeSelection && editor.state.selection.node.type.name === "collection";
    const inserted = range ? chain.deleteRange(range).insertContent(node).run()
      : selectedCollection ? chain.insertContentAt(editor.state.selection.to, node).run() : chain.insertContent(node).run();
    if (!inserted) return false;
    editor.commands.blur();
    postToSwift("collectionRequest", { action: "create", blockID });
    return true;
  }
  if (key === "table") {
    if (range) editor.chain().deleteRange(range).run();
    return window.VellixTables.command("requestInsert");
  }
  if (key === "codeBlock") {
    const block = blockNodeForKey(key);
    const chain = editor.chain();
    if (!(range ? chain.deleteRange(range) : chain).insertContent(block).run()) return false;
    return codeBlocks.request(editor, block.attrs.id);
  }
  if (key === "gridCard" || key === "iconCallout" || (key === "plainCallout" && !column && !color && !insertionToken)) {
    const block = blockNodeForKey(key);
    let chain = editor.chain();
    if (range) chain = chain.deleteRange(range);
    const insideCard = Array.from({ length: location.depth }, (_, i) => i + 1)
      .find(depth => ["gridCard", "iconCallout"].includes(location.node(depth).type.name) ||
        (key === "plainCallout" && location.node(depth).type.name === "plainCallout"));
    if (insideCard !== undefined) {
      chain = chain.command(({ tr, commands }) => commands.insertContentAt(tr.mapping.map(location.after(insideCard)), block));
    } else if (editor.state.selection instanceof NodeSelection) {
      chain = chain.insertContentAt(editor.state.selection.to, block);
    } else {
      chain = chain.insertContent(block);
    }
    return chain.run() && requestGridCard(block.attrs.id, key);
  }
  if (key === "listGridSettings") {
    return listGridModule.command(editor, "listGridRequestSelectedSettings");
  }
  if (key === "listGrid") {
    const json = listGridModule.listGridJSON();
    const opensSettings = !!window.PennedBlockSelection;
    const chain = editor.chain();
    // iOS presents settings without first focusing a cell. Mac has no List
    // Grid sheet, so keep its existing caret placement for immediate editing.
    if (!opensSettings) chain.focus();
    if (!(range ? chain.deleteRange(range) : chain).insertContent(json).run()) return false;
    if (!opensSettings) {
      editor.state.doc.descendants((node, pos) => {
        if (node.type.name !== "listGrid" || node.attrs.id !== json.attrs.id) return;
        // The first row is label + value, and the label contains one paragraph.
        if (node.firstChild?.firstChild?.firstChild?.type.name === "paragraph") {
          editor.commands.setTextSelection(pos + 4);
        }
        return false;
      });
    }
    renderCalloutIcons();
    requestAnimationFrame(reportContentHeight);
    return !opensSettings || listGridModule.command(editor, "listGridRequestSettings", { blockId: json.attrs.id });
  }
  if (key === "weekStrip") {
    try {
      const block = editor.schema.nodeFromJSON(weekStripJSON());
      block.check();
      const tr = editor.state.tr;
      const position = insertContainerAtBlockBoundary(tr, block, range, panelChildDepth(tr.selection.$from));
      if (position === null) {
        postToSwift("error", { message: "Week Strip insertion was rejected at the document position." });
        return false;
      }
      editor.view.dispatch(tr);
      const exists = editor.state.doc.nodeAt(position)?.type.name === "weekStrip";
      if (!exists) {
        postToSwift("error", { message: "Week Strip insertion did not appear in the document." });
        return false;
      }
      renderCalloutIcons();
      requestAnimationFrame(reportContentHeight);
      return true;
    } catch (error) {
      postToSwift("error", { message: `Week Strip insertion failed: ${error?.message || String(error)}` });
      return false;
    }
  }
  if (key === "existingEvent") {
    // Preserve the insertion location before the native picker takes focus.
    // Use the caller's explicit range when Add Block supplies one.
    const bookmark = range || editor.state.selection;
    pendingExistingEventConversion = { ...insertionBookmark(bookmark), kind: "insert" };
    postToSwift("existingEventPickerRequest", { action: "insert" });
    return true;
  }
  if (key === "tabs") {
    // Build the complete parent + panels as a schema-validated ProseMirror node.
    // Insert at a top-level boundary; inserting inside a paragraph or nested
    // content can be rejected or split unexpectedly.
    tabsCheckpoint("entered", { editable: editor.isEditable, selectionMode });
    try {
      const json = tabsModule.tabsJSON();
      const tabsNode = editor.state.schema.nodeFromJSON(json);
      tabsNode.check();
      tabsCheckpoint("node-validated", { nodeSize: tabsNode.nodeSize });
      const tr = editor.state.tr;
      const position = insertContainerAtBlockBoundary(tr, tabsNode, range, panelChildDepth(tr.selection.$from));
      if (position === null) {
        postToSwift("error", { message: "Tabs insertion was rejected at the document position." });
        return false;
      }
      tabsCheckpoint("after-tr-insert", { docSize: tr.doc.content.size });
      tabsCheckpoint("before-dispatch");
      editor.view.dispatch(tr);
      tabsCheckpoint("after-dispatch");
      // Confirm the block actually exists before reporting success.
      const exists = editor.state.doc.nodeAt(position)?.type.name === "tabs";
      if (!exists) {
        postToSwift("error", { message: "Tabs insertion did not appear in the document." });
        return false;
      }
      tabsCheckpoint("before-render-icons");
      renderCalloutIcons();
      tabsCheckpoint("after-render-icons");
      requestAnimationFrame(reportContentHeight);
      tabsCheckpoint("success");
      return true;
    } catch (error) {
      tabsCheckpoint("exception", { error: String(error?.stack || error) });
      postToSwift("error", { message: `Tabs insertion failed: ${error?.message || String(error)}` });
      return false;
    }
  }
  if (key === "informationCard") {
    // Insert inside the active Tabs panel when the selection is within a panel.
    // Otherwise retain normal document-level insertion.
    try {
      const json = informationCardJSON();
      const node = editor.state.schema.nodeFromJSON(json);
      node.check();
      const tr = editor.state.tr;
      const position = insertContainerAtBlockBoundary(tr, node, range, panelChildDepth(tr.selection.$from));
      if (position === null) {
        postToSwift("error", { message: "Information Card insertion was rejected at the document position." });
        return false;
      }
      editor.view.dispatch(tr);
      const inserted = editor.state.doc.nodeAt(position);
      if (inserted?.type.name !== "informationCard") {
        postToSwift("error", { message: "Information Card insertion did not appear in the document." });
        return false;
      }
      // Inserting an Information Card block must not focus its title or open the keyboard.
      editor.commands.blur();
      renderCalloutIcons();
      requestAnimationFrame(reportContentHeight);
      return true;
    } catch (error) {
      postToSwift("error", { message: `Information Card insertion failed: ${error?.message || String(error)}` });
      return false;
    }
  }
  if (key === "fields") {
    // Insert inside the active Tabs panel when the selection is within a panel.
    // Otherwise retain normal document-level insertion.
    try {
      const json = minimalFieldsModule.minimalFieldsJSON();
      const node = editor.state.schema.nodeFromJSON(json);
      node.check();
      const tr = editor.state.tr;
      const position = insertContainerAtBlockBoundary(tr, node, range, panelChildDepth(tr.selection.$from));
      if (position === null) {
        postToSwift("error", { message: "Fields insertion was rejected at the document position." });
        return false;
      }
      editor.view.dispatch(tr);
      const inserted = editor.state.doc.nodeAt(position);
      if (inserted?.type.name !== "minimalFields") {
        postToSwift("error", { message: "Fields insertion did not appear in the document." });
        return false;
      }
      // Inserting a Fields block must not focus its title or open the keyboard.
      editor.commands.blur();
      renderCalloutIcons();
      requestAnimationFrame(reportContentHeight);
      return true;
    } catch (error) {
      postToSwift("error", { message: `Fields insertion failed: ${error?.message || String(error)}` });
      return false;
    }
  }
  if (key === "nestedPage" || key === "pageCard") {
    if (!editor.isEditable || selectionMode !== "off") return false;
    const blockId = id();
    const node = { type: "pageReference", attrs: { id: blockId, documentID: "" } };
    const insertion = editor.chain();
    const inserted = range ? insertion.deleteRange(range).insertContent(node).run() : insertion.insertContent(node).run();
    if (!inserted) return false;
    editor.commands.blur();
    postToSwift(key === "pageCard" ? "pageCardRequest" : "nestedPageRequest", { blockId });
    return true;
  }
  if (key === "pageBreak") {
    return insertPageBreak(range);
  }
  if (key === "moodBar" || key === "countdown" || key === "calculator") {
    const insertion = editor.chain();
    if (range) insertion.deleteRange(range);
    const inserted = insertion.insertContent(blockNodeForKey(key)).run();
    if (inserted) { editor.view.dom.blur(); requestAnimationFrame(reportContentHeight); }
    return inserted;
  }

  const node = normalizeTipTapNode(blockNodeForKey(key));
  if (column) {
    const siblings = column.row.content.content.filter(child => child !== column.node);
    const remaining = calloutRowMetrics(siblings).remaining;
    if (!siblings.length || remaining <= 1) return false;
    node.attrs.widthPercent = remaining;
  }
  if (key === "plainCallout" && typeof color === "string" && /^#[0-9a-f]{6}$/i.test(color)) {
    node.attrs.color = color;
  }
  const selectedProperty = editor.state.selection instanceof NodeSelection &&
    editor.state.selection.node.type.name === "inlineProperty";
  if (column && !column.node.content.size) {
    // The caret paragraph is UI state, not part of the undoable insertion.
    // Undo must restore the spare column, not resurrect an untracked row cell.
    editor.view.dispatch(closeHistory(editor.state.tr.delete(column.position, column.position + column.node.nodeSize))
      .setMeta("addToHistory", false));
  }
  const insertion = editor.chain();
  if (node.type === "heading" && node.attrs.label?.presentation === "label") {
    const inserted = insertion
      .focus()
      .command(({ tr, commands }) => {
        // An empty heading is inserted at a block boundary, never as inline content.
        const { $from } = tr.selection;
        const replace = $from.depth > 0 && $from.parent.type.name === "paragraph" && !$from.parent.content.size;
        const from = replace ? $from.before() : $from.depth > 0 ? $from.after() : $from.pos;
        const to = replace ? $from.after() : from;
        if (!commands.insertContentAt({ from, to }, node, { updateSelection: false })) return false;
        if (tr.doc.nodeAt(from)?.attrs.id !== node.attrs.id) return false;
        tr.setSelection(TextSelection.create(tr.doc, from + 1));
        return true;
      }).run();
    if (inserted) requestAnimationFrame(reportContentHeight);
    return inserted;
  }
  if (node.type !== "inlineProperty") insertion.focus();
  const command = column && !column.node.content.size
    ? insertion.insertContentAt(column.position, node)
    : range
    ? insertion.deleteRange(range).insertContent(node)
    : selectedProperty ? insertion.insertContentAt(editor.state.selection.to, node)
    : insertion.insertContent(node);
  const inserted = command.run();
  if (inserted && node.type === "plainCallout" && !color && !insertionToken) requestGridCard(node.attrs.id, "plainCallout");
  if (inserted && node.type === "inlineProperty") {
    editor.commands.blur();
    postToSwift("propertyEditorRequest", { blockId: node.attrs.id, property: node.attrs.property });
  }
  renderCalloutIcons();
  requestAnimationFrame(reportContentHeight);
  return inserted;
}

function insertPageBreak(range = null) {
  const chain = editor.chain().focus();
  if (range) chain.deleteRange(range);

  const inserted = chain
    .command(({ tr, state }) => {
      const breakNode = state.schema.nodes.pageBreak.create({ id: id() });
      const nextParagraph = state.schema.nodes.paragraph.create({ id: id() });
      const { $from } = tr.selection;

      let insertionPosition = tr.selection.to;
      let replaceFrom = null;
      let replaceTo = null;

      if ($from.depth > 0) {
        const topLevelStart = $from.before(1);
        const topLevelNode = tr.doc.nodeAt(topLevelStart);
        if (topLevelNode) {
          const topLevelEnd = topLevelStart + topLevelNode.nodeSize;
          const replaceEmptyBlock =
            topLevelNode.type.name !== "pageBreak" &&
            topLevelNode.type.name !== "inlineProperty" && !plainText(topLevelNode.toJSON()).trim();
          if (replaceEmptyBlock) {
            replaceFrom = topLevelStart;
            replaceTo = topLevelEnd;
            insertionPosition = topLevelStart;
          } else {
            insertionPosition = topLevelEnd;
          }
        }
      }

      if (replaceFrom !== null && replaceTo !== null) {
        tr.replaceWith(replaceFrom, replaceTo, [breakNode, nextParagraph]);
      } else {
        tr.insert(insertionPosition, [breakNode, nextParagraph]);
      }

      const paragraphStart = insertionPosition + breakNode.nodeSize;
      tr.setSelection(TextSelection.near(tr.doc.resolve(paragraphStart + 1), 1));
      return true;
    })
    .run();

  renderCalloutIcons();
  requestAnimationFrame(reportContentHeight);
  return inserted;
}

function findWashiTape(blockID) {
  let result = null;
  if (!blockID) return result;
  editor.state.doc.descendants((node, pos) => {
    if (!result && node.type.name === "divider" && node.attrs.style === "washiTape" && node.attrs.id === blockID) {
      result = { node, pos };
      return false;
    }
  });
  return result;
}

function requestWashiTape(blockID) {
  if (!editor.isEditable || selectionMode !== "off" || editor.view.composing) return false;
  const target = findWashiTape(blockID);
  if (!target) return false;
  const { node } = target;
  editor.commands.blur();
  postToSwift("washiTapeSettings", { blockID, imagePath: node.attrs.imagePath, remotePhoto: dividerPhoto(node.attrs.remotePhoto),
    color: dividerColor(node.attrs.color), tapeSize: washiTapeSize(node.attrs.tapeSize) });
  return true;
}

function insertWashiTape(range = null) {
  if (!editor.isEditable || selectionMode !== "off" || editor.view.composing) return false;
  const blockID = id();
  if (typeof editor.storage.pennedMobileInsertDivider === "function") {
    if (!editor.storage.pennedMobileInsertDivider("washiTape", range, blockID)) return false;
  } else {
    const chain = editor.chain();
    if (range) chain.deleteRange(range);
    if (!chain.insertContent({ type: "divider", attrs: { id: blockID, style: "washiTape" } }).run()) return false;
  }
  return requestWashiTape(blockID);
}

function updateWashiTape(args) {
  if (!editor.isEditable || selectionMode !== "off") return false;
  const target = findWashiTape(args.blockID);
  if (!target || (target.node.attrs.imagePath || null) !== (args.originalPath || null) ||
      (target.node.attrs.remotePhoto?.id || null) !== (args.originalPhotoID || null)) return false;
  const currentSize = washiTapeSize(target.node.attrs.tapeSize);
  const tapeSize = washiTapeSize(args.tapeSize ?? currentSize);
  if (args.originalTapeSize != null && currentSize !== washiTapeSize(args.originalTapeSize) && currentSize !== tapeSize) return false;
  const remotePhoto = dividerPhoto(args.remotePhoto);
  const imagePath = !remotePhoto && typeof args.imagePath === "string" && attachmentURL({ relativePath: args.imagePath })
    ? args.imagePath : null;
  if ((args.remotePhoto && !remotePhoto) || (args.imagePath && !imagePath)) return false;
  const tr = closeHistory(editor.state.tr);
  tr.setNodeMarkup(target.pos, undefined, { ...target.node.attrs, imagePath, remotePhoto, tapeSize });
  if (!tr.doc.eq(editor.state.doc)) {
    editor.view.dispatch(tr);
    editor.view.dispatch(closeHistory(editor.state.tr));
  }
  return snapshotPayload();
}

let slashState = null;
let slashMenuVisible = false;
let dismissedSlash = null;
const maxSlashQueryLength = Math.max(...SLASH_ITEMS.map(item => `${item.title} ${item.detail} ${item.key}`.length));

function slashRangeAtSelection() {
  const { $from, empty } = editor.state.selection;
  if (!empty || !$from.parent.isTextblock || $from.parent.type.spec.code) return null;
  const start = Math.max(0, $from.parentOffset - maxSlashQueryLength - 2);
  const before = $from.parent.textBetween(start, $from.parentOffset, "\n", "\0");
  const match = before.match(/(?:^|\s)\/([a-zA-Z0-9]*)$/);
  if (!match) return null;
  const query = match[1] || "";
  if (query.length > maxSlashQueryLength) return null;
  return {
    from: $from.pos - query.length - 1,
    to: $from.pos,
    query,
  };
}

function filteredSlashItems(query) {
  const value = String(query || "").toLowerCase();
  if (!value) return SLASH_ITEMS;
  return SLASH_ITEMS.filter((item) =>
    `${item.title} ${item.detail} ${item.key}`.toLowerCase().includes(value),
  );
}

function hideSlashMenu() {
  const wasVisible = slashMenuVisible || slashState !== null;
  slashState = null;
  slashMenuVisible = false;
  if (wasVisible) postToSwift("slashMenu", { visible: false });
}

function dismissSlashMenu() {
  if (slashMenuVisible && slashState) dismissedSlash = slashState.range.from;
  hideSlashMenu();
  return true;
}

function renderSlashMenu() {
  if (!slashState) return;
  const items = filteredSlashItems(slashState.query);
  if (!items.length) {
    hideSlashMenu();
    return;
  }

  slashState.index = Math.max(0, Math.min(slashState.index, items.length - 1));
  slashMenuVisible = true;

  const visualViewport = window.visualViewport;
  const viewportLeft = visualViewport?.offsetLeft ?? 0;
  const viewportTop = visualViewport?.offsetTop ?? 0;
  const viewportWidth = visualViewport?.width ?? window.innerWidth;
  const coords = editor.view.coordsAtPos(slashState.range.to);
  const rowHeight = 62;
  const visibleRows = Math.min(items.length, 5);
  const naturalMaxHeight = 14 + visibleRows * rowHeight;
  const menuMaxHeight = Math.min(324, naturalMaxHeight);
  const menuWidth = Math.min(342, Math.max(280, viewportWidth - 28));
  const gutter = 14;
  const topGutter = 10;
  const viewportRight = viewportLeft + viewportWidth;
  const left = Math.min(
    viewportRight - menuWidth - gutter,
    Math.max(viewportLeft + gutter, coords.left),
  );
  const top = Math.max(viewportTop + topGutter, coords.bottom + topGutter);

  postToSwift("slashMenu", {
    visible: true,
    query: slashState.query,
    selectedIndex: slashState.index,
    anchorX: left,
    anchorY: top,
    anchorAboveY: coords.top - topGutter,
    width: menuWidth,
    maxHeight: menuMaxHeight,
    items: items.map((item) => ({
      key: item.key,
      title: item.title,
      detail: item.detail,
      icon: item.icon,
    })),
  });
}

function updateSlashMenu() {
  if (selectionMode !== "off" || !editor.isEditable || editor.view.composing) {
    hideSlashMenu();
    return;
  }
  const range = slashRangeAtSelection();
  if (!range || range.from === dismissedSlash) {
    hideSlashMenu();
    return;
  }
  slashState = { range, query: range.query, index: slashState?.index || 0 };
  renderSlashMenu();
}

function topLevelInsertionPositionAtY(clientY) {
  let insertionPosition = editor.state.doc.content.size;
  let foundPosition = false;

  editor.state.doc.forEach((_node, offset) => {
    if (foundPosition) return;
    const element = editor.view.nodeDOM(offset);
    if (!(element instanceof HTMLElement)) return;

    const rect = element.getBoundingClientRect();
    if (clientY < rect.top + rect.height / 2) {
      insertionPosition = offset;
      foundPosition = true;
    }
  });

  return insertionPosition;
}

function placeCaretInParagraphAt(position) {
  return placeCaretInSlot(editor, position);
}

function placeCaretAtPageBoundary(position) {
  // On iOS the native document scroll view already reveals real text carets.
  // A second reveal from ProseMirror can scroll against the changing page layout.
  return placeCaretInSlot(editor, position, { scroll: !window.PennedBlockSelection });
}

function focusEditorAtDocumentEnd() {
  if (selectionMode !== "off" || !editor.isEditable) return false;
  return placeCaretInParagraphAt(editor.state.doc.content.size);
}

function focusAfterInlineProperty(blockId) {
  if (selectionMode !== "off" || !editor.isEditable) return false;
  let afterProperty = null;
  editor.state.doc.descendants((node, pos) => {
    if (node.type.name === "inlineProperty" && node.attrs.id === blockId) afterProperty = pos + node.nodeSize;
  });
  const state = editor.state;
  if (afterProperty !== null) {
    // Returning from a sheet may focus existing text, but must never create content.
    if (!state.doc.resolve(afterProperty).nodeAfter?.isTextblock) return false;
    editor.view.dispatch(state.tr.setSelection(TextSelection.create(state.doc, afterProperty + 1)).scrollIntoView());
  } else if (!state.selection.$from.parent.isTextblock) {
    return false;
  }
  editor.view.focus();
  return true;
}

function insertParagraphFromEmptySurface(event) {
  if (selectionMode !== "off" || !editor.isEditable || event.defaultPrevented) return false;
  if (editor.view.composing || event.button !== 0 || window.PennedBlockSelection?.consumesClick(event)) return false;

  const target = event.target;
  if (!(target instanceof HTMLElement)) return false;

  const content = editor.view.dom;
  // Tabs chrome handles navigation and settings, not caret placement.
  if (target.matches(".penned-tabs[data-tabs]") ||
      target.closest(".penned-tabs-header, .penned-tabs-bar") ||
      target.matches(".penned-week-strip[data-week-strip]") ||
      target.closest(".penned-week-strip-chrome")) return false;
  if (target.closest("button, a, input, textarea, select, audio, video, iframe, [role='button']")) return false;
  const pageBoundary = pageBreakGapAtPoint(editor, target, event.clientX, event.clientY);
  if (pageBoundary !== null) {
    event.preventDefault();
    placeCaretAtPageBoundary(pageBoundary);
    return true;
  }
  if (placeCaretOnTrailingNumberedLine(editor, target, event.clientX, event.clientY)) {
    event.preventDefault();
    return true;
  }
  const gapPosition = blockGapAtPoint(editor, target, event.clientX, event.clientY);
  // WebKit can resolve a tap in the blank space after a decorated heading
  // back into its editable label. Only recover taps physically BELOW the
  // heading, never taps on its tile or text, and use the existing caret slot.
  if (editor.view.dom.contains(target)) {
    let labelEnd = null;
    editor.state.doc.descendants((node, offset, parent) => {
      if (node.type.name !== "heading" || node.attrs.label?.presentation !== "label" ||
          !["informationCardBody", "doc"].includes(parent?.type.name)) return;
      const element = editor.view.nodeDOM(offset);
      if (!(element instanceof HTMLElement)) return;
      const bounds = element.getBoundingClientRect();
      const next = element.nextElementSibling?.getBoundingClientRect();
      const body = element.closest("[data-information-card-body]");
      const horizontal = (body || editor.view.dom).getBoundingClientRect();
      if (event.clientY <= bounds.bottom || (next && event.clientY >= next.top) ||
          event.clientY > (body || editor.view.dom).getBoundingClientRect().bottom ||
          event.clientX < horizontal.left || event.clientX > horizontal.right ||
          (body && !body.contains(target) && target !== body)) return;
      const position = offset + node.nodeSize;
      const boundary = editor.state.doc.resolve(position);
      if (!boundary.parent.canReplaceWith(boundary.index(), boundary.index(), editor.schema.nodes.paragraph)) return;
      if (labelEnd === null || event.clientY - bounds.bottom < labelEnd.distance)
        labelEnd = { position, distance: event.clientY - bounds.bottom };
    });
    if (labelEnd && placeCaretInParagraphAt(labelEnd.position)) {
      event.preventDefault();
      return true;
    }
  }
  const isEmptyEditorSurface =
    target === content ||
    target.id === "editor" ||
    target.classList.contains("vellix-editor-page") ||
    target.classList.contains("vellix-editor-shell") ||
    target === document.body ||
    target === document.documentElement;
  if (!isEmptyEditorSurface && gapPosition === null) return false;

  const handled = placeCaretInParagraphAt(gapPosition ?? topLevelInsertionPositionAtY(event.clientY));
  if (handled) event.preventDefault();
  return handled;
}

function chooseSlashItem(key) {
  if (!slashState || !slashMenuVisible || !editor.isEditable || selectionMode !== "off" || editor.view.composing) return false;
  const range = slashRangeAtSelection();
  if (!range || range.from !== slashState.range.from || range.query !== slashState.query ||
      !filteredSlashItems(range.query).some(item => item.key === key)) return false;
  hideSlashMenu();
  if (key === "divider:washiTape") return insertWashiTape(range);
  if (key.startsWith("divider:") && typeof editor.storage.pennedMobileInsertDivider === "function") {
    return editor.storage.pennedMobileInsertDivider(key.slice("divider:".length), range);
  }
  if (key === "inlineCode") {
    return editor.chain().focus().deleteRange(range).toggleMark("code").run();
  }
  if (key === "underline") {
    return editor.chain().focus().deleteRange(range).toggleMark("underline").run();
  }
  return insertBlockByKey(key, range);
}

editor.on("transaction", ({ transaction, appendedTransactions = [] }) => {
  let changed = false;
  for (const tr of [transaction, ...appendedTransactions]) {
    changed ||= tr.docChanged || tr.selectionSet;
    if (dismissedSlash === null || !tr.docChanged) continue;
    // Follow the original character, not its position or the current caret.
    const from = tr.mapping.mapResult(dismissedSlash, 1);
    const to = tr.mapping.mapResult(dismissedSlash + 1, -1);
    if (from.deleted || to.deleted || to.pos !== from.pos + 1 || tr.doc.textBetween(from.pos, to.pos) !== "/") {
      dismissedSlash = null;
      continue;
    }
    dismissedSlash = from.pos;
  }
  if (changed) updateSlashMenu();
});
editor.view.dom.addEventListener("compositionend", () => requestAnimationFrame(updateSlashMenu));
// Transactions also cover stored marks, undo/redo, and programmatic selection changes.
let formattingFrame = null;
function queueFormattingState() {
  if (formattingFrame !== null) return;
  formattingFrame = requestAnimationFrame(() => {
    formattingFrame = null;
    if (!editor.isDestroyed) reportFormattingState();
  });
}
editor.on("transaction", queueFormattingState);
editor.on("focus", queueFormattingState);
editor.on("blur", queueFormattingState);

const blockActions = createBlockActions({ editor, blocks: topLevelModelBlocks, elementForBlock: elementForModelBlock,
  selectionActive: () => selectionMode !== "off", post: postToSwift, snapshot: snapshotPayload });

// ProseMirror re-renders nodeViews (especially inside taskLists) on every doc
// change, which wipes DOM attributes we set for selection UI. Re-apply the
// selection classes whenever the document changes while selection mode is on.
editor.on("update", () => {
  if (selectionMode !== "off") setSelectionClasses();
});

window.visualViewport?.addEventListener("resize", () => {
  if (slashState && slashMenuVisible) renderSlashMenu();
});
window.visualViewport?.addEventListener("scroll", () => {
  if (slashState && slashMenuVisible) renderSlashMenu();
});

document.addEventListener("keydown", (event) => {
  if (!slashState || !slashMenuVisible || event.isComposing) return;
  if (!["ArrowDown", "ArrowUp", "Enter", "Tab", "Escape"].includes(event.key)) return;
  const items = filteredSlashItems(slashState.query);
  if (!items.length) return;
  event.preventDefault();
  event.stopPropagation();

  if (event.key === "ArrowDown") {
    slashState.index = (slashState.index + 1) % items.length;
    renderSlashMenu();
  } else if (event.key === "ArrowUp") {
    slashState.index = (slashState.index - 1 + items.length) % items.length;
    renderSlashMenu();
  } else if (event.key === "Enter" || event.key === "Tab") {
    chooseSlashItem(items[slashState.index]?.key);
  } else if (event.key === "Escape") {
    dismissSlashMenu();
  }
}, true);

// Paint callout text ranges independently of WebKit's transient selection paint.
// Custom Highlights do not wrap text or move the native selection handles.
if (typeof Highlight === "function" && window.CSS?.highlights && CSS.supports("selector(::highlight(penned-callout-selection))")) {
  window.PennedCalloutRangeHighlight = true;
  const name = "penned-callout-selection";
  let frame = null;
  const selectionDocument = editor.view.dom.ownerDocument;
  const update = () => {
    frame = null;
    const { view } = editor;
    if (!editor.isEditable || selectionMode !== "off") {
      CSS.highlights.delete(name);
      return;
    }
    const native = selectionDocument.getSelection();
    let range = null;
    if (native?.rangeCount && !native.isCollapsed) {
      const selected = native.getRangeAt(0);
      if (view.dom.contains(selected.startContainer) && view.dom.contains(selected.endContainer)) range = selected.cloneRange();
    } else if (view.hasFocus()) {
      const selection = view.state.selection;
      if (selection instanceof TextSelection && !selection.empty) {
        const start = view.domAtPos(selection.from, 1), end = view.domAtPos(selection.to, -1);
        range = selectionDocument.createRange();
        range.setStart(start.node, start.offset);
        range.setEnd(end.node, end.offset);
      }
    }
    if (range && !range.collapsed) CSS.highlights.set(name, new Highlight(range));
    else CSS.highlights.delete(name);
  };
  const schedule = () => {
    if (frame === null && (CSS.highlights.has(name) || !editor.state.selection.empty ||
        selectionDocument.getSelection()?.isCollapsed === false)) frame = requestAnimationFrame(update);
  };
  selectionDocument.addEventListener("selectionchange", schedule);
  editor.on("selectionUpdate", schedule);
  editor.on("blur", schedule);
  editor.on("destroy", () => {
    selectionDocument.removeEventListener("selectionchange", schedule);
    if (frame !== null) cancelAnimationFrame(frame);
    CSS.highlights.delete(name);
    delete window.PennedCalloutRangeHighlight;
  });
}

document.addEventListener("pointerdown", event => documentLinks.pointerDown(editor, event), { capture: true });
// Real user taps into another document block end Calendar insertion targeting.
// Native toolbar taps do not reach the editor DOM and therefore retain it.
editor.view.dom.addEventListener("pointerdown", event => {
  if (!event.target.closest?.(".penned-week-strip")) forgetActiveCalendar(editor);
}, { capture: true });
document.addEventListener("mousedown", (event) => {
  if (selectionMode === "off" && event.target.closest?.(".vellix-callout-icon-button")) {
    event.preventDefault();
  }
});

// Don't let the browser park an editable-looking caret on the atomic page
// break. Handle only stationary taps in this specific boundary area.
const pageGapInteractionAllowed = () => selectionMode === "off" && editor.isEditable && !editor.view.composing;
let pageGapTouch = null;
for (const type of ["pointerdown", "mousedown"]) {
  document.addEventListener(type, event => {
    if (event.button === 0 && pageGapInteractionAllowed() &&
        pageBreakGapAtPoint(editor, event.target, event.clientX, event.clientY) !== null) event.preventDefault();
  }, true);
}
editor.view.dom.addEventListener("touchstart", event => {
  const point = event.touches[0];
  pageGapTouch = event.touches.length === 1 && pageGapInteractionAllowed() &&
    pageBreakGapAtPoint(editor, event.target, point.clientX, point.clientY) !== null
    ? { id: point.identifier, x: point.clientX, y: point.clientY } : null;
}, { passive: true });
editor.view.dom.addEventListener("touchmove", event => {
  const point = event.touches[0];
  if (pageGapTouch && (event.touches.length !== 1 || Math.hypot(point.clientX - pageGapTouch.x, point.clientY - pageGapTouch.y) > 8)) pageGapTouch = null;
}, { passive: true });
editor.view.dom.addEventListener("touchcancel", () => { pageGapTouch = null; }, { passive: true });
editor.view.dom.addEventListener("touchend", event => {
  const start = pageGapTouch;
  pageGapTouch = null;
  if (!start || !event.cancelable || !pageGapInteractionAllowed()) return;
  const point = [...event.changedTouches].find(touch => touch.identifier === start.id);
  if (!point || Math.hypot(point.clientX - start.x, point.clientY - start.y) > 8) return;
  const position = pageBreakGapAtPoint(editor, event.target, point.clientX, point.clientY);
  if (position !== null) {
    event.preventDefault();
    event.stopImmediatePropagation();
    placeCaretAtPageBoundary(position);
  }
}, { passive: false });

// Card node views own their normal clicks. Handle only their surrounding gaps
// before those views stop propagation, leaving taps on the cards themselves alone.
document.addEventListener("click", event => {
  const tape = event.target.closest?.('[data-divider-style="washiTape"]');
  if (tape && editor.view.dom.contains(tape) && !event.defaultPrevented && event.button === 0 &&
      !window.PennedBlockSelection?.consumesClick(event) && selectionMode === "off") {
    const credit = event.target.closest?.(".vellix-divider-credit a");
    if (credit) {
      event.preventDefault();
      event.stopImmediatePropagation();
      postToSwift("propertyURLRequest", { url: credit.href });
      return;
    }
    const node = editor.state.doc.nodeAt(editor.view.posAtDOM(tape, 0));
    if (requestWashiTape(node?.attrs.id)) {
      event.preventDefault();
      event.stopImmediatePropagation();
      return;
    }
  }
  if (insertParagraphFromEmptySurface(event)) event.stopImmediatePropagation();
}, true);

if (!window.PennedBlockSelection) document.addEventListener(
  "pointerdown",
  (event) => {
    handleSelectionHandleEvent(event);
  },
  { capture: true },
);

document.addEventListener("click", (event) => {
  if (selectionMode !== "off" && handleSelectionHandleEvent(event)) return;

  const sourceLink = event.target.closest?.("[data-penned-clip-link]");
  if (sourceLink && editor.view.dom.contains(sourceLink)) {
    event.preventDefault();
    event.stopPropagation();
    if (selectionMode === "off") postToSwift("propertyURLRequest", { url: sourceLink.href });
    return;
  }
  if (documentLinks.handleClick(editor, event)) return;

  const iconButton = event.target.closest?.(".vellix-callout-icon-button");
  if (iconButton) {
    const callout = iconButton.closest(".vellix-callout");
    const blockId = callout?.dataset.vellixBlockId || "";
    event.preventDefault();
    event.stopPropagation();
    requestGridCard(blockId, callout?.dataset.type === "penned-icon-callout" ? "iconCallout" : "gridCard");
    return;
  }

  if (selectionMode === "off" && insertParagraphFromEmptySurface(event)) return;

  if (selectionMode === "off") return;

  if (editor.view.dom.contains(event.target)) return;
});

const resizeObserver = new ResizeObserver(() => {
  requestAnimationFrame(reportContentHeight);
  caretTracking.schedule();
});
resizeObserver.observe(document.documentElement);

// The settings sheet loads this same local editor page in a read-only web view.
window.pennedGridCardPreview = async ({ node, settings, appearance, assets, width }) => {
  document.documentElement.dataset.gridCardPreview = "";
  editor.view.dom.style.width = `${width}px`;
  const draft = gridCardSettings(settings);
  if (node) {
    applyAppearance(appearance);
    editor.setEditable(false, false);
    editor.commands.setContent({ type: "doc", content: [{ ...node, attrs: { ...node.attrs, ...draft } }] }, { emitUpdate: false });
  } else {
    const current = editor.state.doc.firstChild;
    if (current?.type.name === "gridCard" && JSON.stringify(gridCardSettings(current.attrs)) !== JSON.stringify(draft)) {
      editor.view.dispatch(editor.state.tr.setNodeMarkup(0, undefined, { ...current.attrs, ...draft })
        .setMeta("addToHistory", false).setMeta("preventUpdate", true));
    }
  }
  if (Object.keys(assets).length) await window.tiptapCommand("registerIconAssets", { assets });
  await document.fonts?.ready;
  return Math.ceil(editor.view.dom.firstElementChild?.getBoundingClientRect().height ?? 100);
};

window.pennedRepaintScallopedLabels = repaintScallopedLabels;

window.tiptapCommand = async function tiptapCommand(name, args = {}) {
  if (name === "pastePennedBlocks") {
    if (!editor.isEditable || selectionMode !== "off" || typeof args.nativeJSON !== "string") return false;
    let payload;
    try { payload = JSON.parse(args.nativeJSON); } catch (_error) { return false; }
    // A penned-slice carries an exact ProseMirror slice (with open depths) from a
    // text-range copy; reconstruct it losslessly and drop it at the caret.
    pennedPasteBypass = false;
    if (payload?.format === "penned-slice" && payload.version === 1 &&
        payload.slice && Array.isArray(payload.slice.content) && payload.slice.content.length) {
      try {
        const pageClones = [];
        const freshenedContent = freshClipboardBlockIDs(payload.slice.content);
        detachPageReferences(freshenedContent, pageClones);
        const freshened = { ...payload.slice, content: freshenedContent };
        const slice = Slice.fromJSON(editor.schema, freshened);
        if (!slice.content.size) return false;
        const tr = editor.state.tr.replaceSelection(slice);
        if (!tr.docChanged) return false;
        editor.view.dispatch(tr.scrollIntoView());
        editor.view.focus();
        postToSwift("snapshot", snapshotPayload());
        if (pageClones.length) postToSwift("clonePageReferences", { pairs: pageClones });
        return true;
      } catch (_error) { return false; }
    }
    if (payload?.format !== "penned-blocks" || payload.version !== 1 ||
        payload.document?.type !== "doc" || !Array.isArray(payload.document.content) ||
        !payload.document.content.length) return false;
    try {
      // Validate the original nodes against the editor schema without converting
      // them through HTML or applying document-loading normalization.
      const copiedBlocks = freshClipboardBlockIDs(payload.document.content);
      const pageClones = [];
      detachPageReferences(copiedBlocks, pageClones);
      const nodes = copiedBlocks.map(node => editor.schema.nodeFromJSON(node));
      if (nodes.some(node => !node.isBlock || !node.type.validContent(node.content))) return false;
      const fragment = Fragment.fromArray(nodes);
      if (!fragment.size) return false;
      // Insert actual ProseMirror nodes. TipTap insertContent parses JSON again
      // and can transform custom block attributes or nested child structures.
      const tr = editor.state.tr.replaceSelection(new Slice(fragment, 0, 0));
      if (!tr.docChanged) return false;
      editor.view.dispatch(tr.scrollIntoView());
      editor.view.focus();
      postToSwift("snapshot", snapshotPayload());
      if (pageClones.length) postToSwift("clonePageReferences", { pairs: pageClones });
      return true;
    } catch (_error) { return false; }
  }
  if (name === "requestBlockSettings") return requestBlockSettings();
  if (name === "requestSelectedBlockSettings") return requestSelectedBlockSettings(args);
  if (name === "washiTapeUpdate") return updateWashiTape(args);
  if (name === "headingLabelUpdate") {
    if (!editor.isEditable || selectionMode !== "off") return false;
    if (!updateHeadingLabel(editor, args, closeHistory)) return false;
    if (args.assets) await window.tiptapCommand("registerIconAssets", { assets: args.assets });
    return snapshotPayload();
  }
  if (name === "setEditable") linkEditingEnabled = args.editable === true;
  const linkResult = documentLinks.command(editor, name, args);
  if (linkResult !== undefined) {
    if (linkResult === true && (name === "linksApply" || name === "linksSelected")) {
      postToSwift("snapshot", snapshotPayload());
      reportFormattingState();
    }
    return linkResult;
  }
  if (["gridCardUpdate", "iconCalloutUpdate", "plainCalloutUpdate"].includes(name)) {
    const result = commitGridCard(args, name.slice(0, -"Update".length));
    if (result && args.assets) await window.tiptapCommand("registerIconAssets", { assets: args.assets });
    return result;
  }
  if (name === "templateInsertionAvailable") return editor.isEditable && selectionMode === "off" && hasCaretInsertion(editor, args.token);
  if (name === "templateEndInsertion") return endCaretInsertion(editor, args.token);
  if (name === "insertTemplate") {
    if (!editor.isEditable || selectionMode !== "off" || !hasCaretInsertion(editor, args.token)) return false;
    const content = editor.schema.nodeFromJSON(normalizeTipTapDocument(args.document)).content;
    if (!content.size || !restoreCaretInsertion(editor, args.token)) return false;
    const before = editor.state.doc;
    const inserted = editor.chain().command(({ tr }) => { closeHistory(tr); return true; })
      .insertContent(content.toJSON()).run();
    if (!inserted || editor.state.doc === before) return false;
    editor.view.dispatch(closeHistory(editor.state.tr).setMeta("addToHistory", false));
    renderCalloutIcons();
    reportContentHeight();
    postToSwift("snapshot", snapshotPayload());
    editor.view.focus();
    return true;
  }
  const colorResult = textColor.command(editor, name, args);
  if (colorResult !== undefined) return colorResult;
  const listGridResult = listGridModule.command(editor, name, args);
  if (listGridResult !== undefined) return listGridResult;
  const codeBlockResult = codeBlocks.command(editor, name, args);
  if (codeBlockResult !== undefined) return codeBlockResult;
  if (name === "cancelExistingEventPicker") {
    pendingExistingEventConversion = null;
    return true;
  }
  if (name === "beginExistingEventConversion") {
    if (!editor.isEditable) return false;
    if (!args.blockSelection) {
      const calendarTr = editor.state.tr;
      const target = ensureCalendarInsertionSelection(calendarTr);
      if (target && (calendarTr.docChanged || calendarTr.selectionSet)) {
        editor.view.dispatch(calendarTr.setMeta("addToHistory", false));
        postToSwift("calendarDiagnostic", { stage: "convert-event-target", date: target.date, blockID: target.stripID });
      }
    }
    const blocks = args.blockSelection
      ? (window.PennedBlockSelection?.selectedRecords?.() ?? [])
      : [];
    if (args.blockSelection && !blocks.length) return false;
    pendingExistingEventConversion = args.blockSelection
      ? { ids: blocks.map(({ node }) => node.attrs.id).filter(Boolean) }
      : { ...insertionBookmark(editor.state.selection), kind: "convert" };
    postToSwift("existingEventPickerRequest", { action: "convert" });
    return true;
  }
  if (name === "refreshLinkedCalendarEvent") {
    if (!args.eventID) return false;
    const tr = editor.state.tr;
    let changed = false;
    tr.doc.descendants((node, pos) => {
      if (node.type.name !== "linkedCalendarEvent" || node.attrs.eventID !== args.eventID) return;
      const updated = updateLinkedCalendarEventJSON(node.toJSON(), args);
      if (!updated || (updated.attrs.title === node.attrs.title && updated.attrs.calendarTitle === node.attrs.calendarTitle && updated.attrs.start === node.attrs.start && updated.attrs.end === node.attrs.end && updated.attrs.isAllDay === node.attrs.isAllDay && updated.attrs.timeZoneID === node.attrs.timeZoneID && updated.attrs.available === node.attrs.available)) return;
      tr.setNodeMarkup(pos, undefined, updated.attrs);
      changed = true;
    });
    if (changed) editor.view.dispatch(tr.setMeta("addToHistory", false));
    return true;
  }
  if (name === "insertLinkedCalendarEvent") {
    if (!editor.isEditable || !args.eventID || !args.eventIdentity) return false;
    let node;
    try { node = editor.schema.nodeFromJSON(linkedCalendarEventJSON({
      id: id(), eventID: args.eventID, identity: args.eventIdentity,
      title: args.title, calendarTitle: args.calendarTitle, start: args.start, end: args.end,
      isAllDay: args.isAllDay, timeZoneID: args.timeZoneID, available: true,
    })); } catch { return false; }
    const tr = editor.state.tr;
    const conversion = pendingExistingEventConversion;
    pendingExistingEventConversion = null;
    if (conversion?.ids?.length) {
      const records = [];
      tr.doc.descendants((candidate, pos) => {
        if (conversion.ids.includes(candidate.attrs.id)) records.push({ candidate, pos });
      });
      if (records.length !== conversion.ids.length) return false;
      for (const record of records.reverse()) tr.replaceWith(record.pos, record.pos + record.candidate.nodeSize, [node.type.create({ ...node.attrs, id: id() }), record.candidate]);
      editor.view.dispatch(tr);
      return true;
    }
    const bookmark = insertionRange(conversion);
    if (bookmark) {
      if (bookmark.from < 0 || bookmark.to > tr.doc.content.size) return false;
      tr.setSelection(Selection.near(tr.doc.resolve(bookmark.from)));
    }
    const range = conversion?.kind === "convert" && bookmark?.to > bookmark?.from ? bookmark : null;
    const position = insertContainerAtBlockBoundary(tr, node, range, panelChildDepth(tr.selection.$from));
    if (position === null) return false;
    editor.view.dispatch(tr);
    return editor.state.doc.nodeAt(position)?.type.name === "linkedCalendarEvent";
  }
  if (name === "weekStripSetAttr") {
    if (!editor.isEditable) return false;
    let found = null;
    editor.state.doc.descendants((node, pos) => {
      if (node.type.name === "weekStrip" && node.attrs.id === args.blockId) { found = { node, pos }; return false; }
    });
    if (!found) return false;
    const panelSummary = node => node.content.content.map(panel => ({
      date: panel.attrs.date, id: panel.attrs.id, count: panel.childCount,
      types: panel.content.content.map(child => child.type.name),
    }));
    postToSwift("calendarDiagnostic", { stage: "setting-before", blockID: args.blockId,
      setting: args.key, selectedDate: found.node.attrs.selectedDate, panels: panelSummary(found.node) });
    const changed = updateWeekStripAppearanceJSON(found.node.toJSON(), args.key, args.value);
    if (!changed) return false;
    if (changed.attrs[args.key] === found.node.attrs[args.key]) return true;
    const value = changed.attrs[args.key];
    const tr = editor.state.tr;
    if (args.key === "firstDayOfWeek") {
      const selected = found.node.attrs.selectedDate;
      const updated = navigateWeekStripJSON({ ...found.node.toJSON(), attrs: { ...found.node.attrs, firstDayOfWeek: value } }, selected);
      const missing = updated.content.slice(found.node.childCount);
      if (missing.length) tr.insert(found.pos + found.node.nodeSize - 1, missing.map(panel => editor.schema.nodeFromJSON(panel)));
    }
    tr.setNodeMarkup(found.pos, undefined, { ...found.node.attrs, [args.key]: value });
    editor.view.dispatch(tr);
    const after = editor.state.doc.nodeAt(found.pos);
    postToSwift("calendarDiagnostic", { stage: "setting-after", blockID: args.blockId,
      setting: args.key, selectedDate: after?.attrs.selectedDate,
      panels: after?.type.name === "weekStrip" ? panelSummary(after) : [],
      sameContent: after?.type.name === "weekStrip" && after.childCount === found.node.childCount &&
        found.node.content.content.every((panel, index) => panel.eq(after.child(index))) });
    return true;
  }
  const tabsResult = tabsModule.command(editor, name, args);
  if (tabsResult !== undefined) return tabsResult;
  const informationCardResult = informationCardModule.command(editor, name, args);
  if (informationCardResult !== undefined) return informationCardResult;
  const minimalFieldsResult = minimalFieldsModule.command(editor, name, args);
  if (minimalFieldsResult !== undefined) return minimalFieldsResult;
  const pennedSelectionResult = window.PennedBlockSelection?.command(name, args);
  if (pennedSelectionResult !== undefined) return pennedSelectionResult;
  const tagResult = await documentTags.command(editor, name, args);
  if (tagResult !== undefined) return tagResult;
  try {
    const attachmentResult = attachments.command(editor, name, args);
    if (attachmentResult !== undefined) return attachmentResult;
    const result = templateComponents.command(editor, name, args);
    if (result !== undefined) return result;
  } catch (error) { postToSwift("error", { message: error.message }); return false; }
  if (name === "deleteBlock") return blockActions.remove(args.token);
  if (name === "dismissBlockActions") return blockActions.dismiss(args.token);
  if (name === "setContent" || name === "setEditable" || name === "setSelectionMode") blockActions.reset();
  const taskResult = taskCommand(editor, name, args, postToSwift, normalizeTipTapDocument);
  if (taskResult !== null) return taskResult;
  if (name === "formatCurrentSelection" && editor.state.selection instanceof NodeSelection &&
      editor.state.selection.node.type.name === "inlineProperty") return false;
  if (name === "updateInlineProperty" || name === "deleteInlineProperty") {
    if (!editor.isEditable || selectionMode !== "off") return false;
    let position = null;
    let target = null;
    editor.state.doc.descendants((node, pos) => {
      if (node.type.name === "inlineProperty" && node.attrs.id === args.blockId) {
        position = pos;
        target = node;
      }
    });
    if (!target) return false;
    const transaction = editor.state.tr;
    if (name === "deleteInlineProperty") transaction.delete(position, position + target.nodeSize);
    else transaction.setNodeMarkup(position, undefined, { ...target.attrs, property: normalizeProperty(args.property) });
    editor.view.dispatch(transaction);
    return true;
  }
  if (name === "updateBlockquoteColor") {
    return updateBlockquoteColor(args.blockId, args.color);
  }
  const focusedChain = () => editor.chain().focus();
  switch (name) {
    case "preparePresentation": {
      if (args.appearance) applyAppearance(args.appearance);
      setPageReferences(args.pages || []);
      setCollections(args.collections || []);
      attachments.command(editor, "setAttachments", { files: args.files || [] });
      const generation = args.openingDiagnosticGeneration;
      const started = Number.isSafeInteger(generation) ? performance.now() : null;
      const diagnostic = started === null ? undefined : (phase, data) => {
        postToSwift("openingDiagnostic", { generation, phase, browserMS: Math.round(performance.now() - started), ...data });
      };
      const result = await prepareDocumentPresentation(editor.view.dom, document, diagnostic);
      if (diagnostic) result.openingDiagnostic = true;
      reportContentHeight();
      return result;
    }
    case "setNativeCollectionHeight": {
      const resized = setNativeCollectionHeight(args);
      if (resized) requestAnimationFrame(reportContentHeight);
      return resized;
    }
    case "setCollections":
      setCollections(args.collections);
      requestAnimationFrame(reportContentHeight);
      return true;
    case "resolveCollection": {
      let target = null;
      editor.state.doc.descendants((node, pos) => {
        if (node.type.name === "collection" && node.attrs.id === args.blockID) target = { node, pos };
      });
      if (!target) return false;
      const transaction = editor.state.tr;
      if (!args.collectionID) {
        if (target.node.attrs.collectionID) return false;
        transaction.delete(target.pos, target.pos + target.node.nodeSize);
      } else transaction.setNodeMarkup(target.pos, undefined, { ...target.node.attrs, collectionID: args.collectionID, documentID: args.documentID });
      editor.view.dispatch(transaction);
      postToSwift("snapshot", snapshotPayload());
      return true;
    }
    case "setPageReferences":
      setPageReferences(args.pages);
      requestAnimationFrame(reportContentHeight);
      return true;
    case "resolvePageReference": {
      let target = null;
      editor.state.doc.descendants((node, pos) => {
        if (node.type.name === "pageReference" && node.attrs.id === args.blockId) target = { node, pos };
      });
      if (!target) return false;
      const tr = editor.state.tr;
      if (!args.documentId) tr.delete(target.pos, target.pos + target.node.nodeSize);
      else tr.setNodeMarkup(target.pos, undefined, { ...target.node.attrs, documentID: args.documentId });
      editor.view.dispatch(tr);
      postToSwift("snapshot", snapshotPayload());
      if (args.documentId) postToSwift("pageOpenRequest", { documentId: args.documentId });
      return true;
    }
    case "applyClonedPageReference": {
      // Repoint a duplicated/pasted page card at its freshly cloned independent
      // page (or delete the card if the clone failed). Never auto-opens the page.
      let target = null;
      editor.state.doc.descendants((node, pos) => {
        if (node.type.name === "pageReference" && node.attrs.id === args.blockId) target = { node, pos };
      });
      if (!target) return false;
      const tr = editor.state.tr;
      if (!args.documentId) tr.delete(target.pos, target.pos + target.node.nodeSize);
      else tr.setNodeMarkup(target.pos, undefined, { ...target.node.attrs, documentID: args.documentId });
      editor.view.dispatch(tr);
      postToSwift("snapshot", snapshotPayload());
      return true;
    }
    case "setContent":
      tabsModule.command(editor, "tabsResetNavigation");
      cancelScheduledUpdate();
      supportsTextCheckpoints = args.textCheckpoints === true;
      dismissedSlash = null;
      hideSlashMenu();
      pendingSubpage = null;
      resetCaretInsertions(editor);
      lastHeight = lastVisualContentBottom = -1;
      lastPageBreakSignature = "";
      lastNativeCollectionSignature = "";
      {
        const normalizedDocument = normalizeLoadedTipTapDocument(args.document ?? args);
        traceCalloutAttrs("command-setContent-before-setContent", normalizedDocument);
        editor.chain().command(({ tr }) => { tr.setMeta("pennedPlaceholderDocumentLoad", true); return true; })
          .setContent(normalizedDocument, { emitUpdate: false }).command(({ tr }) => {
          tr.setDocAttribute("taskHistoryProjection", normalizedDocument.attrs?.taskHistoryProjection ?? null);
          return true;
        }).run();
        traceCalloutAttrs("command-setContent-after-setContent", editor.getJSON());
	      }
		      setSelectionMode("off");
		      renderCalloutIcons();
		      reportFormattingState(true);
	      requestAnimationFrame(reportContentHeight);
      if (Number.isSafeInteger(args.openingLoadDiagnosticGeneration)) {
        postToSwift("openingDiagnostic", {
          generation: args.openingLoadDiagnosticGeneration,
          phase: "tiptap-set-content-returned",
        });
      }
	      return true;
    case "moodBarSetAttr":
      return editor.isEditable && selectionMode === "off" && editor.commands.moodBarSetAttr(args);
    case "countdownUpdate":
      return editor.isEditable && selectionMode === "off" && editor.commands.countdownUpdate(args) ? snapshotPayload() : false;
    case "calculatorUpdate":
      return editor.isEditable && selectionMode === "off" && editor.commands.calculatorUpdate(args) ? snapshotPayload() : false;
    case "setEditable":
      editor.setEditable(args.editable === true, false);
      if (!editor.isEditable) hideSlashMenu();
      templateComponents.refresh();
      reportFormattingState();
      return true;
    case "focus":
      editor.commands.focus("end");
      return true;
    case "focusDocumentEnd":
      return focusEditorAtDocumentEnd();
    case "reportCaret":
      caretTracking.schedule();
      return true;
    case "focusAfterInlineProperty":
      return focusAfterInlineProperty(args.blockId);
    case "blur":
      editor.commands.blur();
      return true;
    case "undo":
      return focusedChain().undo().run();
    case "redo":
      return focusedChain().redo().run();
    case "setAppearance":
      applyAppearance(args);
      requestAnimationFrame(reportContentHeight);
      return true;
    case "registerIconAsset":
      {
        const icon = normalizedIconName(args.icon);
        const src = typeof args.src === "string" ? args.src.trim() : "";
        if (src) {
          vellixIconAssets.set(icon, src);
          setRegisteredIconCSSVariable(icon, src);
          traceDiag("icon-asset-registered", { icon, bytes: src.length });
          renderCalloutIcons();
          if (slashState && slashMenuVisible) renderSlashMenu();
        }
      }
      return true;
    case "registerIconAssets":
      {
        const assets = args.assets && typeof args.assets === "object" ? args.assets : {};
        let registered = 0;
        for (const [rawIcon, rawSrc] of Object.entries(assets)) {
          const icon = normalizedIconName(rawIcon);
          const src = typeof rawSrc === "string" ? rawSrc.trim() : "";
          if (!src) continue;
          vellixIconAssets.set(icon, src);
          setRegisteredIconCSSVariable(icon, src);
          registered += 1;
        }
        traceDiag("icon-assets-registered-bulk", { count: registered });
        renderCalloutIcons();
        if (slashState && slashMenuVisible) renderSlashMenu();
      }
      return true;
    case "chooseSlashItem":
      return chooseSlashItem(args.key || "");
    case "dismissSlashMenu":
      return dismissSlashMenu();
    case "insertDivider":
      if (args.style === "washiTape") return insertWashiTape();
      insertNode({ type: "divider", attrs: { id: id(), style: normalizedDividerStyle(args.style) } });
      return true;
    case "insertPageBreak":
      return insertBlockByKey("pageBreak");
      case "plainCalloutCaptureInsertion":
        return editor.isEditable && selectionMode === "off" ? beginCaretInsertion(editor) : false;
      case "plainCalloutEndInsertion":
        return endCaretInsertion(editor, args.token);
	    case "insertBlock":
	      return insertBlockByKey(args.blockType || "paragraph", null, args.color, args.insertionToken);
	    case "setSelectedBlockType":
	      if (typeof args.blockType === "string" && args.blockType.startsWith("divider:")) {
	        return convertSelectedDividers(args.blockType.slice("divider:".length));
	      }
	      return transformSelectedBlocks(args.blockType, args);
	    case "setSelectedCalloutColor":
	      updateSelectedCalloutColor(args.color || DEFAULT_CALLOUT_COLOR);
	      return true;
	    case "formatSelectedBlocks":
	      return formatSelectedBlocks(args.action, args.value);
      case "formatCurrentSelection":
        return formatCurrentSelection(args.action, args.value);
      case "toggleTextMark":
        return editor.chain().focus().toggleMark(args.mark === "codeUnderline" ? "code" : (args.mark || "code")).run();
	    case "updateCalloutColor":
	      updateCalloutColor(args.blockId, args.color);
	      return true;
    case "indentSelectedBlocks":
      if (moveSelectedStructuralBlocks(1)) return true;
      if (selectionMode !== "off" && selection.size) return false;
      return focusedChain().sinkListItem("listItem").run() || focusedChain().sinkListItem("taskItem").run();
    case "outdentSelectedBlocks":
      if (moveSelectedStructuralBlocks(-1)) return true;
      if (selectionMode !== "off" && selection.size) return false;
      return focusedChain().liftListItem("listItem").run() || focusedChain().liftListItem("taskItem").run();
    case "indentPageReference":
      return movePageReferences(args.outdent ? -1 : 1, args.documentID);
	    case "selectAllBlocks":
	      setSelectionMode("multi");
	      selection.clear();
	      topLevelModelBlocks().forEach((block) => selection.add(block.key));
	      setSelectionClasses();
	      return true;
	    case "setSelectionMode":
	      setSelectionMode(args.mode);
	      return true;
	    case "clearBlockSelection":
	      setSelectionMode("off");
	      return true;
        case "clearBlockSelectionIfEmpty":
          if (!selection.size && selectionMode !== "off") setSelectionMode("off");
          return true;
    case "deleteSelectedBlocks":
      deleteSelected(false, true);
      return true;
    case "copySelectedBlocks":
      return await copySelected();
    case "cutSelectedBlocks":
      return await cutSelected();
    case "duplicateSelectedBlocks":
      duplicateSelected();
      return true;
    case "requestSelectedBlocksForSubpage":
      return requestSubpage();
    case "placeGroupedPage":
      return placeGroupedPage(args.token, args.documentId);
    case "requestSnapshot":
      postToSwift("snapshot", snapshotPayload());
      return true;
    default:
      return false;
  }
};

window.VellixStructuredPlaceholders.initialize(editor);
window.VellixTables.initialize(editor);
renderCalloutIcons();
setSelectionClasses();
requestAnimationFrame(reportContentHeight);
postToSwift("ready", { blockCount: documentBlocks(editor.getJSON()).length });
reportFormattingState(true);
