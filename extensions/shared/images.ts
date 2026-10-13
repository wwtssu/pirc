import { createHash } from "node:crypto";
import type { ImageRef } from "../../packages/protocol/generated/ImageRef.ts";

const MAX_IMAGE_BYTES = 20 * 1024 * 1024;
const CHUNK = 48 * 1024;
const SUPPORTED = new Set([
  "image/png",
  "image/jpeg",
  "image/webp",
  "image/gif",
]);

/** Keeps recent image content by reference; history remains the source of truth. */
export class ImageCatalog {
  private readonly images = new Map<string, { data: string; mime: string }>();
  private bytes = 0;
  private refs = new WeakMap<
    object,
    { data: string; mime: string; ref: ImageRef }
  >();
  clear() {
    this.images.clear();
    this.bytes = 0;
    this.refs = new WeakMap();
  }
  collect(content: unknown): ImageRef[] {
    if (!Array.isArray(content)) return [];
    const refs: ImageRef[] = [];
    for (const block of content) {
      if (
        block?.type !== "image" ||
        typeof block.data !== "string" ||
        !SUPPORTED.has(block.mimeType)
      )
        continue;
      const data: string = block.data;
      const cached = this.refs.get(block);
      let ref =
        cached?.data === data && cached.mime === block.mimeType
          ? cached.ref
          : undefined;
      if (!ref) {
        if (
          !data.length ||
          data.length > Math.ceil(MAX_IMAGE_BYTES / 3) * 4 ||
          data.length % 4 ||
          !/^[A-Za-z0-9+/]*={0,2}$/.test(data)
        )
          continue;
        const id = createHash("sha256")
          .update(block.mimeType)
          .update("\0")
          .update(data)
          .digest("hex");
        ref = {
          id,
          mime_type: block.mimeType,
          size: Buffer.byteLength(data, "base64"),
        };
        this.refs.set(block, { data, mime: block.mimeType, ref });
      }
      if (!this.images.has(ref.id)) {
        this.images.set(ref.id, { data, mime: block.mimeType });
        this.bytes += data.length;
      }
      refs.push(ref);
      while (this.bytes > 64 * 1024 * 1024 || this.images.size > 128) {
        const [key, value] = this.images.entries().next().value!;
        this.bytes -= value.data.length;
        this.images.delete(key);
      }
    }
    return refs;
  }
  read(id: string, offset: number) {
    const image = this.images.get(id);
    if (!image) return undefined;
    if (
      !Number.isSafeInteger(offset) ||
      offset < 0 ||
      offset % 4 ||
      offset >= image.data.length
    )
      throw new Error("Invalid image offset");
    return {
      kind: "image_chunk" as const,
      data: image.data.slice(offset, offset + CHUNK),
      mime_type: image.mime,
      offset,
      total: image.data.length,
    };
  }
}
