import { object, string, PublishingError } from "./contract.ts";
import type { JSONObject } from "./contract.ts";

type Context = { reference(value: unknown): JSONObject; photo(value: unknown): JSONObject; links: ReadonlyMap<string, string>; pages: ReadonlySet<string> };
const color = (value: unknown) => {
  const result = string(value, 9);
  if (!/^#(?:[a-f\d]{3}|[a-f\d]{6}|[a-f\d]{8})$/i.test(result)) throw new PublishingError(400, "invalid_color");
  return result;
};
function array(value: unknown, limit: number): unknown[] {
  if (!Array.isArray(value) || value.length > limit) throw new PublishingError(400, "invalid_visible_content");
  return value;
}
function choice(value: unknown, options: string[]): string {
  if (typeof value !== "string" || !options.includes(value)) throw new PublishingError(400, "invalid_visible_content");
  return value;
}
function linked(source: Record<string, unknown>, target: JSONObject, context: Context) {
  if (source.targetPage != null) {
    const key = string(source.targetPage, 37);
    if (!context.pages.has(key)) throw new PublishingError(400, "invalid_linked_page");
    target.targetPage = key;
    return;
  }
  if (source.targetDocumentID != null) {
    const token = context.links.get(string(source.targetDocumentID, 200));
    if (token && /^[a-z0-9][a-z0-9-]{1,78}[a-z0-9]$/.test(token)) target.targetToken = token;
  }
}
function cover(source: Record<string, unknown>, target: JSONObject, context: Context) {
  if (source.cover != null) target.cover = context.reference(source.cover);
  if (source.coverPhoto != null) target.coverPhoto = context.photo(source.coverPhoto);
  if (source.coverThemeID != null) target.coverThemeID = choice(source.coverThemeID, ["custom", "lunarClouds", "neonCode"]);
}

export function sanitizeVisibleNode(type: string, input: unknown, context: Context): JSONObject {
  const attrs = object(input);
  if (type === "publishedPage") {
    const source = object(attrs.preview), result: JSONObject = { title: string(source.title, 1000), excerpt: string(source.excerpt ?? "", 400) };
    if (source.icon != null) result.icon = string(source.icon, 100);
    if (source.textColorHex != null) result.textColorHex = color(source.textColorHex);
    if (source.fontStyle != null) result.fontStyle = choice(source.fontStyle, ["rounded", "system", "mono", "serif"]);
    linked(source, result, context); cover(source, result, context);
    if (source.cardStyle != null) {
      const style = object(source.cardStyle), approved: JSONObject = {
        size: choice(style.size, ["compact", "landscape", "portrait", "wide", "large"]),
        backdrop: choice(style.backdrop, ["none", "solid", "gradient", "photo"]), showsPages: style.showsPages === true,
        startColor: color(style.startColor), endColor: color(style.endColor),
      };
      if (style.mediaID != null) Object.assign(approved, context.reference(style));
      if (style.remotePhoto != null) approved.remotePhoto = context.photo(style.remotePhoto);
      result.cardStyle = approved;
    }
    return { type, attrs: { preview: result } };
  }
  const source = object(attrs.projection), projection = sanitizeCollectionView(source, context);
  if (source.views != null) {
    const views = array(source.views, 100).map(value => {
      const raw = object(value), key = string(raw.key, 12);
      if (!/^view-\d{1,3}$/.test(key)) throw new PublishingError(400, "invalid_visible_view");
      return { ...sanitizeCollectionView(raw, context), key };
    });
    const active = string(source.activeViewKey, 12);
    if (!views.length || new Set(views.map(view => view.key)).size !== views.length || !views.some(view => view.key === active)) {
      throw new PublishingError(400, "invalid_visible_view");
    }
    projection.views = views; projection.activeViewKey = active;
  }
  return { type, attrs: { projection } };
}

function sanitizeCollectionView(source: Record<string, unknown>, context: Context): JSONObject {
  const fields = array(source.fields, 100).map(value => {
    const field = object(value), key = string(field.key, 12);
    if (!/^field-\d{1,3}$/.test(key)) throw new PublishingError(400, "invalid_visible_field");
    return { key, name: string(field.name, 200), kind: choice(field.kind, ["text", "number", "select", "multiSelect", "date", "checkbox", "url", "email"]), icon: string(field.icon ?? "linedpages", 100) };
  });
  if (new Set(fields.map(field => field.key)).size !== fields.length) throw new PublishingError(400, "invalid_visible_field");
  const groups = array(source.groups ?? [], 100).map(value => {
    const group = object(value), key = string(group.key, 12);
    if (!/^group-\d{1,3}$/.test(key)) throw new PublishingError(400, "invalid_visible_group");
    return { key, name: string(group.name, 200), color: color(group.color), collapsed: group.collapsed === true };
  });
  if (new Set(groups.map(group => group.key)).size !== groups.length) throw new PublishingError(400, "invalid_visible_group");
  const entries = array(source.entries, 1000).map(value => {
    const entry = object(value), values = object(entry.values), result: JSONObject = { title: string(entry.title, 1000) };
    linked(entry, result, context); cover(entry, result, context);
    if (entry.group != null) {
      const key = string(entry.group, 12);
      if (!groups.some(group => group.key === key)) throw new PublishingError(400, "invalid_visible_group");
      result.group = key;
    }
    result.values = Object.fromEntries(fields.map(field => {
      const raw = values[field.key] == null ? {} : object(values[field.key]);
      const approved: JSONObject = { text: string(raw.text ?? "", 4000), empty: raw.empty === true,
        chips: array(raw.chips ?? [], 100).map(value => { const chip = object(value); return { name: string(chip.name, 200), color: color(chip.color) }; }) };
      if (typeof raw.checked === "boolean") approved.checked = raw.checked;
      return [field.key, approved];
    }));
    return result;
  });
  const columns = Number(source.galleryColumns ?? 2);
  if (!Number.isInteger(columns) || columns < 1 || columns > 3) throw new PublishingError(400, "invalid_visible_columns");
  return { name: string(source.name, 200), viewName: string(source.viewName, 200),
    kind: choice(source.kind, ["table", "gallery", "kanban"]), galleryColumns: columns,
    showsCover: source.showsCover === true, compactCards: source.compactCards === true, fields, groups, entries };
}

export function linkedDocumentIDs(content: unknown): string[] {
  const result = new Set<string>();
  let count = 0;
  function visit(value: unknown, depth: number) {
    if (++count > 100000 || depth > 80) throw new PublishingError(400, "content_too_large");
    if (!value || typeof value !== "object") return;
    if (Array.isArray(value)) { for (const child of value) visit(child, depth + 1); return; }
    const source = value as Record<string, unknown>;
    if (source.type === "publishedPage") {
      const preview = object(object(source.attrs).preview);
      if (preview.targetDocumentID != null) result.add(string(preview.targetDocumentID, 200));
      return;
    }
    if (source.type === "publishedCollection") {
      const projection = object(object(source.attrs).projection);
      for (const view of [projection, ...array(projection.views ?? [], 100).map(object)]) {
      for (const value of array(view.entries, 1000)) {
        const entry = object(value);
        if (entry.targetDocumentID != null) result.add(string(entry.targetDocumentID, 200));
      }
      }
      return;
    }
    if (source.content != null) visit(source.content, depth + 1);
  }
  visit(content, 0);
  if (result.size > 1000) throw new PublishingError(400, "too_many_linked_pages");
  return [...result];
}
