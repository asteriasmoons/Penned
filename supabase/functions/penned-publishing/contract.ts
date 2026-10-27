import { sanitizeVisibleNode } from "./visible-content.ts";
export type JSONObject = { [key: string]: JSONValue };
export type JSONValue = null | boolean | number | string | JSONValue[] | JSONObject;

export class PublishingError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string) { super(code); this.status = status; this.code = code; }
}

export const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const tokenPattern = /^[a-f0-9]{64}$/;
export const maxMediaBytes = 16 * 1024 * 1024;
export const mediaTypes = new Set(["image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/avif", "image/svg+xml", "application/pdf", "audio/mpeg", "audio/mp4", "audio/wav", "audio/x-wav", "audio/ogg", "video/mp4", "video/quicktime", "video/webm", "video/ogg", "application/octet-stream", "text/plain", "application/zip"]);

export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new PublishingError(400, "invalid_object");
  return value as Record<string, unknown>;
}

export function string(value: unknown, limit = 512): string {
  if (typeof value !== "string" || value.length > limit || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(value)) throw new PublishingError(400, "invalid_string");
  return value;
}

export function uuid(value: unknown): string {
  const result = string(value, 36).toLowerCase();
  if (!uuidPattern.test(result)) throw new PublishingError(400, "invalid_id");
  return result;
}

export function version(value: unknown): number {
  if (!Number.isSafeInteger(value) || Number(value) < 0) throw new PublishingError(400, "invalid_version");
  return Number(value);
}

function safeURL(value: unknown): string {
  const text = string(value, 4096);
  if (/^#[A-Za-z0-9_-]+$/.test(text)) return text;
  let url: URL;
  try { url = new URL(text); } catch { throw new PublishingError(400, "invalid_url"); }
  if (!["https:", "http:", "mailto:"].includes(url.protocol) || url.username || url.password) throw new PublishingError(400, "invalid_url");
  return text;
}

function color(value: unknown): string {
  const result = string(value, 9);
  if (!/^#(?:[a-f0-9]{3}|[a-f0-9]{6}|[a-f0-9]{8})$/i.test(result)) throw new PublishingError(400, "invalid_color");
  return result;
}

const nodes: Record<string, string[]> = {
  doc: [], text: [], paragraph: [], caption: [], heading: ["level"], hardBreak: [],
  bulletList: [], orderedList: ["start", "type"], listItem: [],
  codeBlock: ["language"], blockquote: ["color"], callout: ["icon", "color"], plainCallout: ["color"],
  divider: ["style"], pageBreak: [], toggleItem: ["open"], taskList: [], taskItem: ["checked", "crossed"],
  templateComponent: ["definition", "response"], inlineProperty: ["property"],
  table: ["name", "leftOffset", "stripeColor", "columnless", "rowless", "rowCount", "columnCount", "headerRow"],
  tableRow: [], tableCell: ["colspan", "rowspan", "colwidth", "fillColor", "textColor", "formula", "calculated", "font", "bold", "italic", "strike", "code", "align", "format", "decimals", "currency"],
  tableHeader: ["colspan", "rowspan", "colwidth", "fillColor", "textColor", "formula", "calculated", "font", "bold", "italic", "strike", "code", "align", "format", "decimals", "currency"],
  attachment: ["displayMode", "widthPercent", "file"], inlineTag: ["name"],
};
const nestedKeys = new Set(["kind", "name", "label", "value", "checked", "options", "id", "color", "selectedOptionIDs", "prefix", "suffix", "minimum", "maximum", "step", "urlLabel", "dateValue", "timeValue", "includeTime", "placeholder", "icon", "title", "choices", "style", "symbol", "maxRating", "minimumLabel", "maximumLabel", "response", "start", "end", "angle", "mediaID", "previewMediaID", "mimeType", "size", "typeLabel"]);

function boundedValue(value: unknown, depth = 0): JSONValue {
  if (depth > 8) throw new PublishingError(400, "content_too_deep");
  if (value === null || typeof value === "boolean") return value;
  if (typeof value === "string") return string(value, 16384);
  if (typeof value === "number" && Number.isFinite(value) && Math.abs(value) <= 1e12) return value;
  if (Array.isArray(value) && value.length <= 500) return value.map(item => boundedValue(item, depth + 1));
  const result: JSONObject = {};
  for (const [key, item] of Object.entries(object(value))) {
    if (nestedKeys.has(key)) result[key] = boundedValue(item, depth + 1);
  }
  return result;
}

export type MediaDescriptor = { id: string; name: string; mimeType: string; size: number; sha256: string };
export type PublishedDocument = { schemaVersion: 1; title: string; subtitle: string | null; icon: string | null; cover: JSONValue; appearance: JSONObject; content: JSONObject; media: MediaDescriptor[]; authorAvatar?: { mediaID: string }; linkedPages?: LinkedPage[] };
export type LinkedPage = { key: string; parentKey: string; document: PublishedDocument };
export const linkedPageKey = /^page-[a-f0-9]{32}$/;

export function sanitizeDocument(input: unknown, links: ReadonlyMap<string, string> = new Map(), inheritedPages?: ReadonlySet<string>): PublishedDocument {
  const source = object(input);
  if (source.schemaVersion !== 1) throw new PublishingError(400, "unsupported_schema");
  if (inheritedPages && source.linkedPages != null) throw new PublishingError(400, "invalid_linked_page");
  const rawPages = source.linkedPages == null ? [] : source.linkedPages;
  if (!Array.isArray(rawPages) || rawPages.length > 1000) throw new PublishingError(400, "too_many_linked_pages");
  const keys = rawPages.map(value => string(object(value).key, 37));
  if (keys.some(key => !linkedPageKey.test(key)) || new Set(keys).size !== keys.length) throw new PublishingError(400, "invalid_linked_page");
  const pages = inheritedPages || new Set(["root", ...keys]);
  const descriptors = source.media;
  if (!Array.isArray(descriptors) || descriptors.length > 200) throw new PublishingError(400, "invalid_media");
  const media: MediaDescriptor[] = descriptors.map(item => {
    const asset = object(item), size = version(asset.size), mimeType = string(asset.mimeType, 100), sha256 = string(asset.sha256, 64);
    if (size < 1 || size > maxMediaBytes || !mediaTypes.has(mimeType) || !tokenPattern.test(sha256)) throw new PublishingError(400, "invalid_media");
    return { id: uuid(asset.id), name: string(asset.name, 255), mimeType, size, sha256 };
  });
  const assetMap = new Map(media.map(asset => [asset.id, asset]));
  if (assetMap.size !== media.length) throw new PublishingError(400, "duplicate_media");
  if (media.reduce((total, asset) => total + asset.size, 0) > 64 * 1024 * 1024) throw new PublishingError(400, "media_total_too_large");
  const used = new Set<string>();
  function reference(value: unknown): JSONObject {
    const ref = object(value), id = uuid(ref.mediaID);
    if (!assetMap.has(id)) throw new PublishingError(400, "missing_media");
    used.add(id);
    return { mediaID: id };
  }
  function photo(value: unknown): JSONObject {
    const source = object(value), result: JSONObject = {};
    for (const key of ["thumbURL", "imageURL", "photographerURL", "sourceURL"]) {
      if (source[key] != null) {
        const url = new URL(safeURL(source[key]));
        if (url.protocol !== "https:" || !["images.unsplash.com", "unsplash.com"].includes(url.hostname)) throw new PublishingError(400, "invalid_photo");
        result[key] = url.href;
      }
    }
    for (const key of ["photographer", "id"]) if (source[key] != null) result[key] = string(source[key], 512);
    return result;
  }
  function background(value: unknown): JSONObject {
    const source = object(value), result: JSONObject = {};
    if (!["none", "solid", "gradient", "image"].includes(String(source.kind))) throw new PublishingError(400, "invalid_background");
    result.kind = String(source.kind);
    for (const key of ["colorHex", "secondaryColorHex"]) if (source[key] != null) result[key] = color(source[key]);
    if (source.mediaID != null) Object.assign(result, reference(source));
    if (source.remotePhoto != null) result.remotePhoto = photo(source.remotePhoto);
    for (const key of ["gradientDirection", "effect"]) if (source[key] != null) result[key] = string(source[key], 40);
    if (result.gradientDirection && !["topToBottom", "leftToRight", "diagonal", "bottomToTop"].includes(String(result.gradientDirection))) throw new PublishingError(400, "invalid_gradient_direction");
    if (result.effect && !["immersive", "faded"].includes(String(result.effect))) throw new PublishingError(400, "invalid_backdrop_effect");
    if (typeof source.blurImage === "boolean") result.blurImage = source.blurImage;
    return result;
  }
  const appearance: JSONObject = {}, appearanceSource = object(source.appearance);
  for (const key of ["editorBackground", "innerPageBackground"]) if (appearanceSource[key] != null) appearance[key] = background(appearanceSource[key]);
  for (const key of ["themeID", "fontStyle", "coverThemeID"]) if (appearanceSource[key] != null) appearance[key] = string(appearanceSource[key], 40);
  if (appearance.fontStyle && !["system", "serif", "mono", "rounded"].includes(String(appearance.fontStyle))) throw new PublishingError(400, "invalid_font");
  if (appearanceSource.textColorHex != null) appearance.textColorHex = color(appearanceSource.textColorHex);
  if (typeof appearanceSource.showsCover === "boolean") appearance.showsCover = appearanceSource.showsCover;
  if (appearanceSource.coverPhoto != null) appearance.coverPhoto = photo(appearanceSource.coverPhoto);
  let count = 0;
  function node(value: unknown, depth = 0): JSONObject {
    if (depth > 64 || ++count > 20000) throw new PublishingError(400, "content_too_large");
    const source = object(value), type = string(source.type, 64);
    if (["pageReference", "privateReference"].includes(type)) return { type: "privateReference" };
    if (["collection", "privateCollection"].includes(type)) return { type: "privateCollection" };
    if (["publishedPage", "publishedCollection"].includes(type)) return sanitizeVisibleNode(type, source.attrs, { reference, photo, links, pages });
    if (!Object.hasOwn(nodes, type)) throw new PublishingError(400, "unsupported_node_" + type);
    if (source.content != null && !Array.isArray(source.content)) throw new PublishingError(400, "invalid_node_content");
    if (source.marks != null && !Array.isArray(source.marks)) throw new PublishingError(400, "invalid_marks");
    const result: JSONObject = { type };
    if (type === "text") result.text = string(source.text, 200000);
    if (source.attrs != null && type !== "doc") {
      const attrs = object(source.attrs), approved: JSONObject = {};
      for (const key of ["id", "textAlign", "indent", ...nodes[type]]) {
        if (attrs[key] == null) continue;
        const value = attrs[key];
        if (["textAlign", "align"].includes(key) && !["left", "center", "right", "justify"].includes(String(value))) throw new PublishingError(400, "invalid_alignment");
        if (["fillColor", "textColor", "stripeColor"].includes(key)) color(value);
        if (key === "indent" && (!Number.isInteger(value) || Number(value) < 0 || Number(value) > 6)) throw new PublishingError(400, "invalid_indent");
        if (key === "level" && (!Number.isInteger(value) || Number(value) < 1 || Number(value) > 6)) throw new PublishingError(400, "invalid_heading_level");
        if (["colspan", "rowspan"].includes(key) && (!Number.isInteger(value) || Number(value) < 1 || Number(value) > 200)) throw new PublishingError(400, "invalid_table_span");
        if (key === "colwidth" && (!Array.isArray(value) || value.length > 200 || value.some(width => typeof width !== "number" || !Number.isFinite(width) || width < 56 || width > 3000))) throw new PublishingError(400, "invalid_column_width");
        if (key === "widthPercent" && (typeof value !== "number" || value < 10 || value > 100)) throw new PublishingError(400, "invalid_media_width");
        approved[key] = boundedValue(value);
      }
      if (type === "attachment") {
        const file = object(attrs.file), ref = reference(file), asset = assetMap.get(String(ref.mediaID))!;
        approved.file = { ...ref, name: asset.name, mimeType: asset.mimeType, size: asset.size, kind: string(file.kind, 32) };
        for (const key of ["width", "height"]) if (file[key] != null) {
          const dimension = Number(file[key]);
          if (!Number.isInteger(dimension) || dimension < 1 || dimension > 30000) throw new PublishingError(400, "invalid_media_dimensions");
          (approved.file as JSONObject)[key] = dimension;
        }
        if (file.previewMediaID != null) {
          reference({ mediaID: file.previewMediaID });
          (approved.file as JSONObject).previewMediaID = uuid(file.previewMediaID);
        }
      }
      if (Object.keys(approved).length) result.attrs = approved;
    }
    if (Array.isArray(source.content)) {
      const children = source.content.map(child => node(child, depth + 1));
      const inline = new Set(["text", "hardBreak", "inlineTag"]);
      const childTypes: Record<string, string[]> = { paragraph: [...inline], caption: [...inline], heading: [...inline], codeBlock: ["text"],
        bulletList: ["listItem"], orderedList: ["listItem"], taskList: ["taskItem"], table: ["tableRow"], tableRow: ["tableCell", "tableHeader"],
        text: [], hardBreak: [], inlineTag: [], attachment: [], templateComponent: [], inlineProperty: [], divider: [], pageBreak: [] };
      for (const child of children) {
        if (childTypes[type] ? !childTypes[type].includes(String(child.type)) : ["doc", ...inline, "tableRow", "tableCell", "tableHeader", "listItem", "taskItem"].includes(String(child.type))) throw new PublishingError(400, "invalid_child_node");
      }
      result.content = children;
    }
    if (Array.isArray(source.marks)) {
      result.marks = source.marks.flatMap(value => {
        const mark = object(value), type = string(mark.type, 64);
        if (["bold", "italic", "strike", "underline", "code"].includes(type)) return [{ type }];
        if (type === "link") {
          const attrs = object(mark.attrs);
          try { return [{ type, attrs: { href: safeURL(attrs.href) } }]; } catch { return []; }
        }
        if (type === "textStyle") {
          const attrs = object(mark.attrs), approved: JSONObject = {};
          if (attrs.color != null) approved.color = color(attrs.color);
          if (attrs.gradient != null) {
            const gradient = object(attrs.gradient), angle = Number(gradient.angle);
            if (!Number.isFinite(angle)) throw new PublishingError(400, "invalid_gradient");
            approved.gradient = { start: color(gradient.start), end: color(gradient.end), angle: ((angle % 360) + 360) % 360 };
          }
          return [{ type, attrs: approved }];
        }
        throw new PublishingError(400, "unsupported_mark");
      });
    }
    return result;
  }
  const content = node(source.content);
  if (content.type !== "doc") throw new PublishingError(400, "document_required");
  const cover = source.cover == null ? null : reference(source.cover);
  let authorAvatar: { mediaID: string } | undefined;
  if (source.authorAvatar != null) {
    const id = uuid(object(source.authorAvatar).mediaID), asset = assetMap.get(id);
    if (!asset || used.has(id) || asset.size > 1024 * 1024 || !["image/png", "image/jpeg", "image/webp", "image/avif", "image/gif"].includes(asset.mimeType)) throw new PublishingError(400, "invalid_author_avatar");
    authorAvatar = { mediaID: id }; used.add(id);
  }
  const linkedPages = rawPages.map(value => {
    const page = object(value), key = string(page.key, 37), parentKey = string(page.parentKey ?? "root", 37);
    if (!pages.has(parentKey) || parentKey === key) throw new PublishingError(400, "invalid_linked_page");
    const document = sanitizeDocument(page.document, links, pages);
    for (const asset of document.media) {
      const rootAsset = assetMap.get(asset.id);
      if (!rootAsset || ["name", "mimeType", "size", "sha256"].some(key => rootAsset[key as keyof MediaDescriptor] !== asset[key as keyof MediaDescriptor])) throw new PublishingError(400, "missing_media");
      used.add(asset.id);
    }
    return { key, parentKey, document };
  });
  if (linkedPages.length) {
    const byKey = new Map(linkedPages.map(page => [page.key, page]));
    for (const page of linkedPages) {
      const seen = new Set([page.key]); let parent = page.parentKey;
      while (parent !== "root") {
        if (seen.has(parent)) throw new PublishingError(400, "invalid_linked_page");
        seen.add(parent); parent = byKey.get(parent)!.parentKey;
      }
    }
    const reached = new Set<string>();
    const pending: JSONValue[] = [content];
    while (pending.length) {
      const value = pending.pop();
      if (Array.isArray(value)) { pending.push(...value); continue; }
      if (!value || typeof value !== "object") continue;
      if (typeof value.targetPage === "string" && value.targetPage !== "root" && !reached.has(value.targetPage)) {
        reached.add(value.targetPage); pending.push(byKey.get(value.targetPage)!.document.content);
      }
      pending.push(...Object.values(value));
    }
    if (reached.size !== linkedPages.length) throw new PublishingError(400, "unreferenced_linked_page");
  }
  if (used.size !== media.length) throw new PublishingError(400, "unreferenced_media");
  return { schemaVersion: 1, title: string(source.title, 1000), subtitle: source.subtitle == null ? null : string(source.subtitle, 4000), icon: source.icon == null ? null : string(source.icon, 100), cover, appearance, content, media, ...(authorAvatar ? { authorAvatar } : {}), ...(source.linkedPages != null ? { linkedPages } : {}) };
}

export function sanitizeSettings(value: unknown): JSONObject {
  const source = object(value), result: JSONObject = {};
  for (const key of Object.keys(source)) {
    if (["showTitle", "showAuthor", "showTableOfContents", "allowIndexing", "allowFollowLinkedContent", "showBranding", "hideHashtags"].includes(key) && typeof source[key] === "boolean") result[key] = source[key] as boolean;
    else if (key === "authorName") result[key] = string(source[key], 200);
    else if (key === "expiresAt") {
      if (source[key] !== null && (typeof source[key] !== "string" || !Number.isFinite(Date.parse(source[key] as string)))) throw new PublishingError(400, "invalid_expiration");
      result[key] = source[key] as string | null;
    } else throw new PublishingError(400, "unsupported_setting");
  }
  return result;
}

export function publicDocument(document: PublishedDocument, settings: JSONObject): PublishedDocument {
  function reading(value: JSONValue): JSONValue {
    if (Array.isArray(value)) return value.filter(item => !(settings.hideHashtags === true && item && typeof item === "object" && !Array.isArray(item) && item.type === "inlineTag")).map(reading)
      .filter(item=>!(item&&typeof item==="object"&&!Array.isArray(item)&&item.type==="text"&&item.text===""));
    if(settings.hideHashtags===true && value && typeof value==="object" && !Array.isArray(value) && value.type==="text" && typeof value.text==="string")return {...value,text:value.text.replace(/(^|\s)#[\p{L}\p{N}_-]+/gu,"$1")};
    if (value && typeof value === "object") return Object.fromEntries(Object.entries(value)
      .filter(([key]) => !["targetToken", "targetPage"].includes(key) || settings.allowFollowLinkedContent === true)
      .map(([key, child]) => [key, reading(child)]));
    return value;
  }
  const result = { ...document, title: settings.showTitle === false ? "" : document.title, content: reading(document.content) as JSONObject };
  if (settings.allowFollowLinkedContent !== true) delete result.linkedPages;
  if (settings.showAuthor !== true && document.authorAvatar) {
    delete result.authorAvatar;
    result.media = document.media.filter(asset => asset.id !== document.authorAvatar!.mediaID);
  }
  if (document.linkedPages?.length) {
    const used = new Set<string>();
    function references(value: unknown) {
      if (Array.isArray(value)) { value.forEach(references); return; }
      if (!value || typeof value !== "object") return;
      for (const [key, child] of Object.entries(value)) {
        if (["mediaID", "previewMediaID"].includes(key) && typeof child === "string") used.add(child);
        else references(child);
      }
    }
    const visible = [result, ...(settings.allowFollowLinkedContent === true ? document.linkedPages.map(page => page.document) : [])];
    for (const page of visible) [page.cover, page.appearance, page.content, settings.showAuthor === true ? page.authorAvatar : null].forEach(references);
    result.media = result.media.filter(asset => used.has(asset.id));
  }
  return result;
}

// Legacy publications have no source hash. Establish it only after proving that
// the saved projection matches, including media bytes, without overwriting content.
export function equivalentProjection(incoming: PublishedDocument, current: PublishedDocument): boolean {
  const ids=new Map<string,string>();
  for(const asset of incoming.media){
    const match=current.media.find(other=>other.sha256===asset.sha256&&other.name===asset.name&&other.mimeType===asset.mimeType&&other.size===asset.size);
    if(!match)return false;ids.set(asset.id,match.id);
  }
  if(incoming.media.length!==current.media.length)return false;
  function normalize(value: unknown,key="",replace=false): unknown {
    if(Array.isArray(value))return value.map(item=>normalize(item,"",replace));
    if(value&&typeof value==="object")return Object.fromEntries(Object.entries(value).filter(([key])=>key!=="targetToken").sort(([a],[b])=>a.localeCompare(b)).map(([key,child])=>[key,normalize(child,key,replace)]));
    if(replace&&typeof value==="string"&&["id","mediaID","previewMediaID"].includes(key))return ids.get(value)||value;
    return value;
  }
  return JSON.stringify(normalize(incoming,"",true))===JSON.stringify(normalize(current));
}
