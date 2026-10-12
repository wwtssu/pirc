import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { decode } from "../../extensions/pi/protocol.ts";
test("graceful exit is a typed command with a required observed revision", () => {
  const valid = {
    version: 1,
    request_id: "exit",
    message: {
      type: "close_session",
      generation_id: "g",
      session_id: "s",
      instance_id: "i",
      expected_revision: 7,
    },
  };
  assert.deepEqual(decode(JSON.stringify(valid)), valid);
  assert.equal(
    decode(
      JSON.stringify({
        version: 1,
        request_id: "close",
        message: {
          type: "close_session",
          generation_id: "g",
          session_id: "s",
          instance_id: "i",
        },
      }),
    ),
    null,
  );
});
for (const name of ["list", "prompt", "register"])
  test(`Rust fixture ${name} passes TypeScript runtime validation`, () => {
    const json = readFileSync(
      new URL(`../../packages/protocol/fixtures/${name}.json`, import.meta.url),
      "utf8",
    );
    assert.deepEqual(decode(json), JSON.parse(json));
  });
test("invalid revision, version and extra fields are rejected", () => {
  const e = JSON.parse(
    readFileSync(
      new URL("../../packages/protocol/fixtures/prompt.json", import.meta.url),
      "utf8",
    ),
  );
  assert.equal(decode(JSON.stringify({ ...e, version: 2 })), null);
  assert.equal(
    decode(
      JSON.stringify({
        ...e,
        message: { ...e.message, expected_revision: -1 },
      }),
    ),
    null,
  );
  assert.equal(
    decode(JSON.stringify({ ...e, message: { ...e.message, extra: true } })),
    null,
  );
  assert.equal(
    decode(
      JSON.stringify({
        ...e,
        message: {
          ...e.message,
          expected_revision: Number.MAX_SAFE_INTEGER + 1,
        },
      }),
    ),
    null,
  );
});

test("authentication has no shared credential payload", () => {
  const envelope = { version: 1, request_id: "auth", message: { type: "auth" } };
  assert.deepEqual(decode(JSON.stringify(envelope)), envelope);
  assert.equal(decode(JSON.stringify({ ...envelope, message: { ...envelope.message, token: "obsolete" } })), null);
});
