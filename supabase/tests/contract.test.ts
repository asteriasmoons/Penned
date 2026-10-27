import assert from "node:assert/strict";
import test from "node:test";
import { sanitizeDocument, sanitizeSettings, publicDocument } from "../functions/penned-publishing/contract.ts";
import { validateMedia } from "../functions/penned-publishing/media.ts";

export const sample = () => ({ schemaVersion: 1, title: "Selected", subtitle: "Subtitle", icon: "doc.text", cover: null, appearance: {},
  content: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Approved writing" }] }] }, media: [] });

test("projection strips hierarchy, descendants, embedded collections, and private attributes", () => {
  const result = sanitizeDocument({ ...sample(), parentDocumentID: "private-parent", siblings: ["private-sibling"],
    content: { type: "doc", attrs: { taskHistoryProjection: "private-history" }, content: [
      { type: "pageReference", attrs: { documentID: "private-child", title: "PRIVATE TITLE", previewText: "PRIVATE BODY" }, content: [{ type: "text", text: "PRIVATE CHILD BODY" }] },
      { type: "collection", attrs: { collectionID: "private-collection", entries: [{ title: "PRIVATE ENTRY" }] } },
      { type: "paragraph", attrs: { parentDocumentID: "private-parent" }, content: [{ type: "text", text: "Approved" }] },
    ] } });
  const encoded = JSON.stringify(result);
  assert.doesNotMatch(encoded, /PRIVATE|private-parent|private-sibling|private-child|private-collection|private-history/);
  assert.deepEqual(result.content.content?.slice(0, 2), [{ type: "privateReference" }, { type: "privateCollection" }]);
  assert.equal(result.title, "Selected");
});

test("dangerous links disappear and unknown block types fail closed", () => {
  const input = sample();
  input.content.content = [{ type: "paragraph", content: [{ type: "text", text: "Visible", marks: [{ type: "link", attrs: { href: "javascript:alert(1)" } }] }] }] as never;
  assert.doesNotMatch(JSON.stringify(sanitizeDocument(input)), /javascript:/);
  assert.throws(() => sanitizeDocument({ ...sample(), content: { type: "doc", content: [{ type: "futurePrivateBlock" }] } }), /unsupported_node/);
  assert.throws(() => sanitizeDocument({ ...sample(), content: { type: "doc", content: "malformed saved body" } }), /invalid_node_content/);
  assert.throws(() => sanitizeDocument({ ...sample(), content: { type: "doc", content: [{ type: "text", text: "Invalid root text" }] } }), /invalid_child_node/);
});

test("only referenced approved media can be published", () => {
  const asset = { id: crypto.randomUUID(), name: "picture.png", mimeType: "image/png", size: 10, sha256: "a".repeat(64) };
  assert.throws(() => sanitizeDocument({ ...sample(), media: [asset] }), /unreferenced_media/);
  const result = sanitizeDocument({ ...sample(), media: [asset], cover: { mediaID: asset.id, relativePath: "private-file" } });
  assert.deepEqual(result.cover, { mediaID: asset.id });
  assert.throws(() => sanitizeDocument({ ...sample(), cover: { mediaID: crypto.randomUUID() } }), /missing_media/);
  assert.throws(() => sanitizeDocument({ ...sample(), media: [{ ...asset, mimeType: "text/html" }] }), /invalid_media/);
});

test("settings reject unsupported access controls and malformed expiration", () => {
  assert.deepEqual(sanitizeSettings({ showAuthor: false, expiresAt: null }), { showAuthor: false, expiresAt: null });
  assert.throws(() => sanitizeSettings({ password: "do not silently pretend this is protected" }), /unsupported_setting/);
  assert.throws(() => sanitizeSettings({ expiresAt: "tomorrow" }), /invalid_expiration/);
});
test("author avatars are bounded, manifest-scoped raster images and disappear with the author setting",()=>{
  const asset={id:crypto.randomUUID(),name:"author-avatar.png",mimeType:"image/png",size:20,sha256:"a".repeat(64)};
  const input={...sample(),authorAvatar:{mediaID:asset.id,privatePath:"PRIVATE"},media:[asset]};
  const approved=sanitizeDocument(input);
  assert.deepEqual(approved.authorAvatar,{mediaID:asset.id});assert.doesNotMatch(JSON.stringify(approved),/PRIVATE/);
  assert.equal(publicDocument(approved,{showAuthor:true}).media.length,1);
  for(const settings of [{},{showAuthor:false}]) {
    const hidden=publicDocument(approved,settings);assert.equal(hidden.authorAvatar,undefined);assert.equal(hidden.media.length,0);
  }
  assert.throws(()=>sanitizeDocument({...input,media:[]}),/invalid_author_avatar/);
  assert.throws(()=>sanitizeDocument({...input,cover:{mediaID:asset.id}}),/invalid_author_avatar/);
  for(const change of [{mimeType:"text/plain"},{mimeType:"image/svg+xml"},{size:1024*1024+1}])assert.throws(()=>sanitizeDocument({...input,media:[{...asset,...change}]}),/invalid_author_avatar/);
});

test("media validation rejects mismatched types and active SVG content", () => {
  assert.throws(() => validateMedia(new TextEncoder().encode("<html>"), "image/png"), /media_type_mismatch/);
  assert.throws(() => validateMedia(new TextEncoder().encode('<svg><script>alert(1)</script></svg>'), "image/svg+xml"), /media_type_mismatch/);
  validateMedia(new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), "image/png");
});
