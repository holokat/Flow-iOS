import { env as cloudflareEnv } from "cloudflare:workers";
import { reset } from "cloudflare:test";
import { finalizeEvent, getPublicKey } from "nostr-tools/pure";
import { afterEach, describe, expect, it } from "vitest";
import { authorizeBlossomRequest } from "../src/auth";
import {
  handleBlossomRequest,
  type BlossomBindings,
} from "../src/blossom";

const BASE_URL = "https://media.21media.to";
const OWNER_SECRET_KEY = secretKey(1);
const OTHER_SECRET_KEY = secretKey(2);
const OWNER_PUBKEY = getPublicKey(OWNER_SECRET_KEY);

afterEach(async () => {
  await reset();
});

describe("Blossom authorization", () => {
  it("rejects missing credentials and valid non-owner credentials", async () => {
    const body = new TextEncoder().encode("%PDF-1.4\n%%EOF\n");
    const sha256 = await sha256Hex(body);
    const headers = preflightHeaders(body, sha256);

    const missing = await handleBlossomRequest(
      new Request(`${BASE_URL}/upload`, { method: "HEAD", headers }),
      testBindings(),
    );
    expect(missing.status).toBe(401);

    headers.set(
      "Authorization",
      blossomAuthorization("upload", sha256, OTHER_SECRET_KEY),
    );
    const nonOwner = await handleBlossomRequest(
      new Request(`${BASE_URL}/upload`, { method: "HEAD", headers }),
      testBindings(),
    );
    expect(nonOwner.status).toBe(403);
  });

  it("rejects expired and incorrectly scoped events", async () => {
    const sha256 = "a".repeat(64);
    const now = 2_000_000_000;
    const expired = signedAuthorization("upload", sha256, OWNER_SECRET_KEY, {
      expiration: now - 1,
      now,
      server: "media.21media.to",
    });
    const wrongServer = signedAuthorization("upload", sha256, OWNER_SECRET_KEY, {
      expiration: now + 60,
      now,
      server: "other.example",
    });

    expect(
      authorizeBlossomRequest({
        action: "upload",
        authorizationHeader: expired,
        expectedOwnerPubkey: OWNER_PUBKEY,
        expectedServerHost: "media.21media.to",
        expectedSha256: sha256,
        now,
      }),
    ).toMatchObject({ ok: false, status: 401 });

    expect(
      authorizeBlossomRequest({
        action: "upload",
        authorizationHeader: wrongServer,
        expectedOwnerPubkey: OWNER_PUBKEY,
        expectedServerHost: "media.21media.to",
        expectedSha256: sha256,
        now,
      }),
    ).toMatchObject({ ok: false, status: 401 });
  });
});

describe("Crawler controls", () => {
  it("serves a subdomain-wide crawl denial", async () => {
    const response = await handleBlossomRequest(
      new Request(`${BASE_URL}/robots.txt`),
      testBindings(),
    );

    expect(response.status).toBe(200);
    await expect(response.text()).resolves.toBe(
      "User-agent: *\nDisallow: /\nContent-Signal: search=no, ai-input=no, ai-train=no\n",
    );
    expect(response.headers.get("Content-Type")).toBe("text/plain; charset=utf-8");
    expect(response.headers.get("X-Robots-Tag")).toBe(
      "noindex, nofollow, noarchive, nosnippet, noimageindex",
    );
  });

  it("adds no-index instructions to non-HTML responses", async () => {
    const response = await handleBlossomRequest(
      new Request(`${BASE_URL}/${"0".repeat(64)}.jpg`, { method: "HEAD" }),
      testBindings(),
    );

    expect(response.status).toBe(404);
    expect(response.headers.get("X-Robots-Tag")).toBe(
      "noindex, nofollow, noarchive, nosnippet, noimageindex",
    );
  });
});

describe("Blossom blob lifecycle", () => {
  it("uploads, reads, serves ranges, and deletes an owner blob", async () => {
    const body = new TextEncoder().encode("%PDF-1.4\n%%EOF\n");
    const sha256 = await sha256Hex(body);
    const uploadHeaders = new Headers({
      Authorization: blossomAuthorization("upload", sha256, OWNER_SECRET_KEY),
      "Content-Length": String(body.byteLength),
      "Content-Type": "application/pdf",
      "X-SHA-256": sha256,
    });

    const upload = await handleBlossomRequest(
      new Request(`${BASE_URL}/upload`, {
        body,
        headers: uploadHeaders,
        method: "PUT",
      }),
      testBindings(),
    );
    expect(upload.status).toBe(201);
    await expect(upload.json()).resolves.toMatchObject({
      sha256,
      size: body.byteLength,
      type: "application/pdf",
      url: `${BASE_URL}/${sha256}.pdf`,
    });

    const download = await handleBlossomRequest(
      new Request(`${BASE_URL}/${sha256}.pdf`),
      testBindings(),
    );
    expect(download.status).toBe(200);
    expect(new Uint8Array(await download.arrayBuffer())).toEqual(body);
    expect(download.headers.get("Cache-Control")).toBe(
      "public, max-age=31536000, immutable",
    );
    expect(download.headers.get("X-Robots-Tag")).toBe(
      "noindex, nofollow, noarchive, nosnippet, noimageindex",
    );

    const range = await handleBlossomRequest(
      new Request(`${BASE_URL}/${sha256}.pdf`, {
        headers: { Range: "bytes=0-3" },
      }),
      testBindings(),
    );
    expect(range.status).toBe(206);
    expect(new TextDecoder().decode(await range.arrayBuffer())).toBe("%PDF");
    expect(range.headers.get("Content-Range")).toBe(`bytes 0-3/${body.byteLength}`);

    const deletion = await handleBlossomRequest(
      new Request(`${BASE_URL}/${sha256}.pdf`, {
        headers: {
          Authorization: blossomAuthorization("delete", sha256, OWNER_SECRET_KEY),
        },
        method: "DELETE",
      }),
      testBindings(),
    );
    expect(deletion.status).toBe(200);

    const missing = await handleBlossomRequest(
      new Request(`${BASE_URL}/${sha256}.pdf`),
      testBindings(),
    );
    expect(missing.status).toBe(404);
  });

  it("rejects bytes that do not match the declared SHA-256", async () => {
    const body = new TextEncoder().encode("%PDF-1.4\n%%EOF\n");
    const wrongSha256 = await sha256Hex(new TextEncoder().encode("different"));
    const response = await handleBlossomRequest(
      new Request(`${BASE_URL}/upload`, {
        body,
        headers: {
          Authorization: blossomAuthorization("upload", wrongSha256, OWNER_SECRET_KEY),
          "Content-Length": String(body.byteLength),
          "Content-Type": "application/pdf",
          "X-SHA-256": wrongSha256,
        },
        method: "PUT",
      }),
      testBindings(),
    );

    expect(response.status).toBe(409);
    expect(await cloudflareEnv.MEDIA.head(wrongSha256)).toBeNull();
  });
});

function testBindings(): BlossomBindings {
  return {
    MEDIA: cloudflareEnv.MEDIA,
    MAX_UPLOAD_BYTES: "99614720",
    OWNER_NPUB: "npub1test-only",
    OWNER_PUBKEY_HEX: OWNER_PUBKEY,
    PUBLIC_BASE_URL: BASE_URL,
  };
}

function preflightHeaders(body: Uint8Array, sha256: string): Headers {
  return new Headers({
    "X-Content-Length": String(body.byteLength),
    "X-Content-Type": "application/pdf",
    "X-SHA-256": sha256,
  });
}

function blossomAuthorization(
  action: "upload" | "delete",
  sha256: string,
  privateKey: Uint8Array,
): string {
  const now = Math.floor(Date.now() / 1000);
  return signedAuthorization(action, sha256, privateKey, {
    expiration: now + 300,
    now,
    server: "media.21media.to",
  });
}

function signedAuthorization(
  action: "upload" | "delete",
  sha256: string,
  privateKey: Uint8Array,
  timing: { expiration: number; now: number; server: string },
): string {
  const event = finalizeEvent(
    {
      content: `Authorize ${action}`,
      created_at: timing.now,
      kind: 24_242,
      tags: [
        ["t", action],
        ["x", sha256],
        ["server", timing.server],
        ["expiration", String(timing.expiration)],
      ],
    },
    privateKey,
  );
  return `Nostr ${base64URL(JSON.stringify(event))}`;
}

function base64URL(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const input = new Uint8Array(bytes.byteLength);
  input.set(bytes);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", input.buffer));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function secretKey(lastByte: number): Uint8Array {
  const value = new Uint8Array(32);
  value[31] = lastByte;
  return value;
}
