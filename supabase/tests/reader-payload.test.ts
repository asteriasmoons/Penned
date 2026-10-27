import test from "node:test";
import assert from "node:assert/strict";
import { readerPayload } from "../functions/penned-publishing/reader-payload.ts";
import { sanitizeDocument } from "../functions/penned-publishing/contract.ts";
import type { Publication } from "../functions/penned-publishing/handler.ts";

const key = (i: number) => "page-" + i.toString(16).padStart(32, "0");
const link = (targetPage: string) => ({ type: "publishedPage", attrs: { preview: { title: "Child", targetPage } } });
const doc = (content: unknown[]) => ({schemaVersion: 1, title: "Saved", appearance: {}, content: {type: "doc", content}, media: []});
function fixture(count = 2) {
  return { version: 7, updated_at: "2026-10-26T00:00:00Z", settings: { allowFollowLinkedContent: true },
    document: sanitizeDocument({ ...doc([link(key(1))]), linkedPages: Array.from({length: count}, (_, i) => ({ key: key(i + 1), parentKey: i ? key(i) : "root", document: doc(i < count - 1 ? [link(key(i + 2))] : []) })) }) } as Publication;
}
test("authorized snapshots include actual children, grandchildren and return page without separate publications", () => {
  const pub = fixture(), before = JSON.stringify(pub);
  assert.equal(readerPayload(pub).snapshots, undefined);
  const payload = readerPayload(pub, undefined, true);
  assert.deepEqual(payload.snapshots?.map(page => page.page), [key(1), key(2)]);
  assert.ok(payload.snapshots?.every(page => page.publication.version === 7 && !page.publication.document.linkedPages));
  assert.equal(readerPayload(pub, key(2), true).snapshots?.[0].page, key(1));
  assert.equal(JSON.stringify(pub), before);
  pub.settings.allowFollowLinkedContent = false;
  assert.equal(readerPayload(pub, undefined, true).snapshots, undefined);
  assert.throws(() => readerPayload(pub, key(1), true), /not_found/);
});
test("read-ahead is bounded in both page count and bytes", () => {
  assert.equal(readerPayload(fixture(12), undefined, true).snapshots?.length, 8);
  const pub = fixture();
  pub.document!.linkedPages![0].document.content.content = [{ type: "paragraph", content: [{ type: "text", text: "x".repeat(270000) }] }];
  assert.equal(readerPayload(pub, undefined, true).snapshots, undefined);
});
test("existing collection children regain their precise field icons without guessing or mutating saved content", () => {
  const pub = fixture(1);
  pub.document!.content.content = [{type:"publishedCollection",attrs:{projection:{name:"Tasks",fields:[{key:"field-0",name:"Priority",kind:"select",icon:"sf:flag.fill"}],entries:[{title:"Task",targetPage:key(1)}]}}}];
  const property = { name: "Priority", kind: "select", value: "Medium" };
  pub.document!.linkedPages![0].document.content.content = [{type:"inlineProperty",attrs:{property}}];
  assert.equal((readerPayload(pub,key(1)).document.content.content as any)[0].attrs.property.icon,"sf:flag.fill");
  assert.equal((property as any).icon, undefined);
  (property as any).icon = "sf:star.fill";
  assert.equal((readerPayload(pub,key(1)).document.content.content as any)[0].attrs.property.icon,"sf:star.fill");
});
