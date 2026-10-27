import { publicDocument, PublishingError, linkedPageKey } from "./contract.ts";
import type { JSONObject, JSONValue } from "./contract.ts";
import type { Publication } from "./handler.ts";

export function readerPayload(publication: Publication, key?: string, includeSnapshots = false) {
  const root = publication.document!;
  const settings = { ...publication.settings };
  if (settings.showAuthor !== true) delete settings.authorName;
  let icons: Map<string, Map<string, Set<string>>> | undefined;
  function propertyIcons() {
    const result = new Map<string, Map<string, Set<string>>>();
    function visit(value: JSONValue) {
      if (Array.isArray(value)) { value.forEach(visit); return; }
      if (!value || typeof value !== "object") return;
      if (value.type === "publishedCollection") {
        const projection = (value.attrs as JSONObject).projection as JSONObject;
        for (const view of [projection, ...((projection.views || []) as JSONObject[])]) {
          for (const entry of view.entries as JSONObject[]) {
            if (typeof entry.targetPage !== "string") continue;
            const fields = result.get(entry.targetPage) || new Map<string, Set<string>>();
            for (const field of view.fields as JSONObject[]) {
              const id = JSON.stringify([field.name, field.kind === "email" ? "text" : field.kind]);
              const names = fields.get(id) || new Set<string>();
              if (typeof field.icon === "string") names.add(field.icon);
              fields.set(id, names);
            }
            result.set(entry.targetPage, fields);
          }
        }
        return;
      }
      if (value.content) visit(value.content);
    }
    for (const document of [root, ...(root.linkedPages || []).map(page => page.document)]) visit(document.content);
    return result;
  }
  function selected(pageKey?: string) {
    const page = pageKey ? root.linkedPages?.find(page => page.key === pageKey) : undefined;
    if (pageKey && (settings.allowFollowLinkedContent !== true || !linkedPageKey.test(pageKey) || !page)) throw new PublishingError(404, "not_found");
    const document = publicDocument(page?.document || root, settings);
    delete document.linkedPages;
    if (page) {
      const fields = (icons ||= propertyIcons()).get(page.key);
      function restoreIcons(value: JSONValue) {
        if (Array.isArray(value)) { value.forEach(restoreIcons); return; }
        if (!value || typeof value !== "object") return;
        if (value.type === "inlineProperty") {
          const property = (value.attrs as JSONObject).property as JSONObject;
          const names = fields?.get(JSON.stringify([property.name, property.kind]));
          if (!property.icon && names?.size === 1) property.icon = [...names][0];
        }
        if (value.content) restoreIcons(value.content);
      }
      restoreIcons(document.content);
      if (settings.showAuthor === true && root.authorAvatar) {
        document.authorAvatar = root.authorAvatar;
        const asset = root.media.find(asset => asset.id === root.authorAvatar!.mediaID)!;
        if (!document.media.some(item => item.id === asset.id)) document.media = [...document.media, asset];
      }
    }
    const parent = page?.parentKey !== "root" ? root.linkedPages?.find(item => item.key === page?.parentKey) : undefined;
    return { version: Number(publication.version), updatedAt: publication.updated_at, document, settings,
      ...(page ? { navigation: { parentPage: parent?.key ?? null, parentTitle: settings.showTitle === false ? "Document" : (parent?.document || root).title } } : {}) };
  }
  const current = selected(key);
  const snapshots: Array<{ page: string | null; publication: ReturnType<typeof selected> }> = [];
  if (includeSnapshots && settings.allowFollowLinkedContent === true) {
    const targets = new Set<string>();
    if (key) { targets.add(current.navigation?.parentPage || "root"); targets.add("root"); }
    function links(value: JSONValue) {
      if (Array.isArray(value)) { value.forEach(links); return; }
      if (!value || typeof value !== "object") return;
      if (typeof value.targetPage === "string") targets.add(value.targetPage);
      Object.values(value).forEach(links);
    }
    links(current.document.content);
    let size = 0;
    for (const target of targets) {
      if (snapshots.length === 8) break;
      if (target === (key || "root")) continue;
      const snapshot = selected(target === "root" ? undefined : target);
      const bytes = new TextEncoder().encode(JSON.stringify(snapshot)).byteLength;
      if (size + bytes > 256 * 1024) continue;
      size += bytes; snapshots.push({ page: target === "root" ? null : target, publication: snapshot });
      links(snapshot.document.content);
    }
  }
  return { ...current, ...(snapshots.length ? { snapshots } : {}) };
}
