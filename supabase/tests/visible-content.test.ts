import assert from "node:assert/strict";
import test from "node:test";
import { publicDocument, sanitizeDocument, sanitizeSettings, equivalentProjection } from "../functions/penned-publishing/contract.ts";
import { linkedDocumentIDs } from "../functions/penned-publishing/visible-content.ts";

const page = (content: unknown[], media: unknown[] = []) => ({ schemaVersion: 1, title: "Selected", appearance: {}, content: { type: "doc", content }, media });
const linked = { type: "publishedPage", attrs: { preview: { title: "Actual visible page", excerpt: "Saved visible preview", targetDocumentID: "private-destination-id", icon: "linedpages",
  parentID: "PRIVATE PARENT", body: "PRIVATE BODY", path: "PRIVATE PATH", targetToken: "f".repeat(64),
  cardStyle: { size: "large", backdrop: "gradient", startColor: "#000000", endColor: "#123456", showsPages: true, hidden: "PRIVATE STYLE" } } } };
const collection = () => ({ type: "publishedCollection", attrs: { projection: { name: "Actual collection", viewName: "Saved view", kind: "kanban", galleryColumns: 2,
  collectionID: "PRIVATE COLLECTION ID", showsCover: true, fields: [{ key: "field-0", name: "Visible field", kind: "select", icon: "listcircle", id: "PRIVATE FIELD ID" }],
  groups: [{ key: "group-0", name: "Current", color: "#AABBCC", collapsed: false, id: "PRIVATE GROUP ID" }],
  entries: [{ title: "Visible entry", group: "group-0", targetDocumentID: "private-entry-id", body: "PRIVATE ENTRY BODY", id: "PRIVATE ENTRY ID",
    values: { "field-0": { text: "Visible value", empty: false, chips: [{ name: "Actual chip", color: "#FFAA00", id: "PRIVATE OPTION ID" }] }, hidden: { text: "PRIVATE HIDDEN FIELD" } } }] } } });

test("real page/card previews persist without destination bodies, identifiers or arbitrary links", () => {
  const document = sanitizeDocument(page([linked]), new Map([["private-destination-id", "a".repeat(64)]]));
  const raw = JSON.stringify(document);
  assert.match(raw, /Actual visible page/); assert.match(raw, /Saved visible preview/); assert.match(raw, /large/);
  assert.doesNotMatch(raw, /PRIVATE|private-destination-id|ffffffffff/);
  assert.equal((document.content.content as any)[0].attrs.preview.targetToken, "a".repeat(64));
  assert.doesNotMatch(JSON.stringify(publicDocument(document, {})), /targetToken/);
  assert.match(JSON.stringify(publicDocument(document, { allowFollowLinkedContent: true })), /targetToken/);
});
test("collection snapshots retain visible values, ordering and board structure, not hidden data", () => {
  const document = sanitizeDocument(page([collection()]));
  const raw = JSON.stringify(document);
  assert.match(raw, /Actual collection/); assert.match(raw, /Visible field/); assert.match(raw, /Actual chip/); assert.match(raw, /group-0/);
  assert.doesNotMatch(raw, /PRIVATE|private-entry-id/);
});
test("saved collection views are independently approved, linked and bounded without exposing configuration or IDs", () => {
  const node = collection() as any, first = structuredClone(node.attrs.projection), second = structuredClone(first);
  first.key = "view-0"; second.key = "view-1"; second.kind = "gallery"; second.viewName = "Gallery";
  second.entries[0].targetDocumentID = "other-visible-entry"; second.privateConfiguration = "PRIVATE CONFIGURATION";
  node.attrs.projection.views = [first, second]; node.attrs.projection.activeViewKey = "view-1";
  assert.deepEqual(linkedDocumentIDs({ type: "doc", content: [node] }), ["private-entry-id", "other-visible-entry"]);
  const document = sanitizeDocument(page([node]), new Map([["other-visible-entry", "b".repeat(64)]]));
  const raw = JSON.stringify(document); assert.doesNotMatch(raw, /PRIVATE|other-visible-entry|private-entry-id/);
  assert.match(raw, /view-1/); assert.match(raw, /bbbbbbbb/);
  const views = (document.content.content as any)[0].attrs.projection.views;
  assert.equal(views[0].kind, "kanban"); assert.equal(views[1].kind, "gallery");
  for (const active of ["private-view", "view-99"]) {
    node.attrs.projection.activeViewKey = active; assert.throws(() => sanitizeDocument(page([node])), /invalid_visible_view/);
  }
  node.attrs.projection.activeViewKey = "view-0"; second.key = "view-0";
  assert.throws(() => sanitizeDocument(page([node])), /invalid_visible_view/);
});
test("link candidates are private owner-side inputs, not trusted public tokens", () => {
  assert.deepEqual(linkedDocumentIDs({ type: "doc", content: [linked, collection()] }), ["private-destination-id", "private-entry-id"]);
  const document = sanitizeDocument(page([linked]));
  assert.doesNotMatch(JSON.stringify(document), /targetToken|private-destination-id/);
  assert.deepEqual(sanitizeSettings({ allowFollowLinkedContent: true }), { allowFollowLinkedContent: true });
});
test("separately published nested pages retain verified short paths without accepting caller-supplied destinations",()=>{
  const document=sanitizeDocument(page([linked]),new Map([["private-destination-id","a1b2c3d4"]]));
  assert.equal((document.content.content as any)[0].attrs.preview.targetToken,"a1b2c3d4");
  assert.doesNotMatch(JSON.stringify(document),/private-destination-id|ffffffffff/);
});

test("legacy source baselines require exact approved content and equivalent media bytes",()=>{
  const original=sanitizeDocument(page([{type:"paragraph",content:[{type:"text",text:"Saved"}]}]));
  assert.equal(equivalentProjection(structuredClone(original),original),true);
  const stale=structuredClone(original);stale.title="Old title";
  assert.equal(equivalentProjection(stale,original),false);
});

test("visual settings remove hashtag text/tags without mutating the saved publication or leaving invalid empty text nodes",()=>{
  const document=sanitizeDocument(page([{type:"paragraph",content:[{type:"text",text:"#privateTag"},{type:"inlineTag",attrs:{name:"other"}},{type:"text",text:" Visible writing"}]}]));
  const rendered=publicDocument(document,{hideHashtags:true});
  assert.doesNotMatch(JSON.stringify(rendered),/privateTag|inlineTag|"text":""/);
  assert.match(JSON.stringify(document),/privateTag/);
  assert.deepEqual(sanitizeSettings({showBranding:false,hideHashtags:true}),{showBranding:false,hideHashtags:true});
});
test("collection and page images must belong to the publication manifest", () => {
  const input = structuredClone(linked) as any; input.attrs.preview.cover = { mediaID: crypto.randomUUID() };
  assert.throws(() => sanitizeDocument(page([input])), /missing_media/);
  const id = crypto.randomUUID(), descriptor = { id, name: "cover.png", mimeType: "image/png", size: 8, sha256: "a".repeat(64) };
  input.attrs.preview.cover.mediaID = id;
  assert.equal(sanitizeDocument(page([input], [descriptor])).media.length, 1);
});
test("nested cover photos retain approved saved metadata and reject arbitrary origins", () => {
  const input = structuredClone(linked) as any;
  input.attrs.preview.coverPhoto = { id: "photo", imageURL: "https://images.unsplash.com/photo-real", thumbURL: "https://images.unsplash.com/photo-real?w=200", photographer: "Saved author", photographerURL: "https://unsplash.com/@author", sourceURL: "https://unsplash.com/photos/real" };
  assert.match(JSON.stringify(sanitizeDocument(page([input]))), /Saved author/);
  input.attrs.preview.coverPhoto.imageURL = "https://private.example/image";
  assert.throws(() => sanitizeDocument(page([input])));
});
test("malformed visible fields, arbitrary CSS, excessive data and unsupported board links fail closed", () => {
  for (const mutate of [(value: any) => { value.attrs.projection.fields[0].key = "__proto__"; },
    (value: any) => { value.attrs.projection.groups[0].color = "url(https://evil.example)"; },
    (value: any) => { value.attrs.projection.entries[0].group = "private-id"; },
    (value: any) => { value.attrs.projection.entries = Array.from({length:1001}, () => value.attrs.projection.entries[0]); }]) {
    const input = collection(); mutate(input); assert.throws(() => sanitizeDocument(page([input])));
  }
});
