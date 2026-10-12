import { readFileSync } from "node:fs";
import { Ajv2020 } from "ajv/dist/2020.js";
import type { Envelope } from "../../packages/protocol/generated/Envelope.ts";

const schema = JSON.parse(
  readFileSync(
    new URL(
      "../../packages/protocol/generated/envelope.schema.json",
      import.meta.url,
    ),
    "utf8",
  ),
);
const validate = new Ajv2020({
  strict: false,
  formats: {
    uint64: {
      type: "number",
      validate: (n: number) => Number.isSafeInteger(n) && n >= 0,
    },
    uint32: {
      type: "number",
      validate: (n: number) => Number.isInteger(n) && n >= 0 && n <= 0xffffffff,
    },
  },
}).compile<Envelope>(schema);
export function decode(text: string): Envelope | null {
  if (Buffer.byteLength(text) > 1024 * 1024) return null;
  try {
    const value: unknown = JSON.parse(text);
    return validate(value) &&
      value.version === 1 &&
      Buffer.byteLength(value.request_id) > 0 &&
      Buffer.byteLength(value.request_id) <= 128
      ? value
      : null;
  } catch {
    return null;
  }
}
