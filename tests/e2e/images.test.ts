import { test } from "node:test";
import assert from "node:assert/strict";
import { ImageCatalog } from "../../extensions/pi/images.ts";

test("image catalog preserves identity across history and returns aligned bounded chunks", () => {
  const catalog = new ImageCatalog();
  const original = Buffer.alloc(100000, 17).toString("base64");
  const blocks = [
    { type: "text", text: "look" },
    { type: "image", mimeType: "image/png", data: original },
  ];
  const [ref] = catalog.collect(blocks);
  assert.equal(ref.size, 100000);
  assert.deepEqual(catalog.collect(blocks), [ref]);
  let assembled = "",
    offset = 0;
  while (offset < original.length) {
    const chunk = catalog.read(ref.id, offset)!;
    assert.equal(chunk.offset, offset);
    assert.equal(chunk.total, original.length);
    assert.ok(chunk.data.length <= 49152);
    assert.equal(chunk.mime_type, "image/png");
    assembled += chunk.data;
    offset += chunk.data.length;
  }
  assert.equal(assembled, original);
  assert.throws(() => catalog.read(ref.id, -1));
  assert.throws(() => catalog.read(ref.id, 1));
  assert.throws(() => catalog.read(ref.id, original.length));
  assert.equal(catalog.read("not-in-this-session", 0), undefined);
});
test("unsupported, malformed and oversized images cannot enter the catalog", () => {
  const catalog = new ImageCatalog();
  for (const block of [
    { type: "image", mimeType: "image/svg+xml", data: "AAAA" },
    { type: "image", mimeType: "image/png", data: "bad!" },
    { type: "image", mimeType: "image/png", data: "" },
    {
      type: "image",
      mimeType: "image/png",
      data: "A".repeat(28 * 1024 * 1024),
    },
  ])
    assert.deepEqual(catalog.collect([block]), []);
});
test("switching session clears cached image access", () => {
  const catalog = new ImageCatalog();
  const [ref] = catalog.collect([
    { type: "image", mimeType: "image/png", data: "AAAA" },
  ]);
  catalog.clear();
  assert.equal(catalog.read(ref.id, 0), undefined);
});
