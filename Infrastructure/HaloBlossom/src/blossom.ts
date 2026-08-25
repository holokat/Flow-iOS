import { authorizeBlossomRequest, type BlossomAction } from "./auth";

type BlobDescriptor = {
  url: string;
  sha256: string;
  size: number;
  type: string;
  uploaded: number;
};

type UploadMetadata = {
  contentLength: number;
  contentType: string;
  extension: string;
  sha256: string;
};

type ByteRange = {
  offset: number;
  length: number;
};

export type BlossomBindings = {
  MEDIA: R2Bucket;
  MAX_UPLOAD_BYTES: string;
  OWNER_NPUB: string;
  OWNER_PUBKEY_HEX: string;
  PUBLIC_BASE_URL: string;
};

const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const BLOB_PATH_PATTERN = /^\/([0-9a-f]{64})(?:\.([a-z0-9]{1,12}))?$/;
const CACHE_CONTROL = "public, max-age=31536000, immutable";

const EXTENSION_BY_MIME_TYPE = new Map<string, string>([
  ["application/octet-stream", "bin"],
  ["application/pdf", "pdf"],
  ["audio/aac", "aac"],
  ["audio/flac", "flac"],
  ["audio/mp4", "m4a"],
  ["audio/mpeg", "mp3"],
  ["audio/ogg", "ogg"],
  ["audio/wav", "wav"],
  ["audio/webm", "webm"],
  ["audio/x-m4a", "m4a"],
  ["image/avif", "avif"],
  ["image/bmp", "bmp"],
  ["image/gif", "gif"],
  ["image/heic", "heic"],
  ["image/heif", "heif"],
  ["image/jpeg", "jpg"],
  ["image/png", "png"],
  ["image/tiff", "tiff"],
  ["image/webp", "webp"],
  ["video/mp4", "mp4"],
  ["video/quicktime", "mov"],
  ["video/webm", "webm"],
  ["video/x-m4v", "m4v"],
]);

export async function handleBlossomRequest(
  request: Request,
  env: BlossomBindings,
): Promise<Response> {
  const url = new URL(request.url);

  if (request.method === "OPTIONS") {
    return withStandardHeaders(
      new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Headers": "Authorization, Content-Type, Content-Length, Range, X-SHA-256, X-Content-Length, X-Content-Type",
          "Access-Control-Allow-Methods": "GET, HEAD, PUT, DELETE, OPTIONS",
          "Access-Control-Max-Age": "86400",
        },
      }),
    );
  }

  if (url.pathname === "/") {
    return handleServerInformation(request, env);
  }

  if (url.pathname === "/upload") {
    if (request.method === "HEAD") {
      return handleUploadPreflight(request, env);
    }
    if (request.method === "PUT") {
      return handleUpload(request, env);
    }
    return methodNotAllowed("HEAD, PUT, OPTIONS");
  }

  const blobMatch = BLOB_PATH_PATTERN.exec(url.pathname);
  if (blobMatch === null || blobMatch[1] === undefined) {
    return errorResponse(404, "Not Found", "No Blossom endpoint exists at this path.");
  }

  const sha256 = blobMatch[1];
  switch (request.method) {
    case "GET":
      return handleGetBlob(request, env, sha256);
    case "HEAD":
      return handleHeadBlob(request, env, sha256);
    case "DELETE":
      return handleDeleteBlob(request, env, sha256);
    default:
      return methodNotAllowed("GET, HEAD, DELETE, OPTIONS");
  }
}

async function handleServerInformation(
  request: Request,
  env: BlossomBindings,
): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return methodNotAllowed("GET, HEAD, OPTIONS");
  }

  const body = JSON.stringify({
    name: "Halo personal Blossom server",
    description: "Single-user Blossom storage for the configured Nostr public key.",
    pubkey: env.OWNER_PUBKEY_HEX,
    npub: env.OWNER_NPUB,
    supported_buds: [1, 2, 6, 11, 12],
    max_upload_bytes: maximumUploadBytes(env),
  });

  return withStandardHeaders(
    new Response(request.method === "HEAD" ? null : body, {
      headers: {
        "Cache-Control": "public, max-age=300",
        "Content-Length": String(new TextEncoder().encode(body).byteLength),
        "Content-Type": "application/json; charset=utf-8",
      },
    }),
  );
}

async function handleUploadPreflight(request: Request, env: BlossomBindings): Promise<Response> {
  const metadataResult = parseUploadMetadata(request, env, true);
  if (metadataResult instanceof Response) {
    return metadataResult;
  }

  const authorization = authorize(request, env, "upload", metadataResult.sha256);
  if (authorization instanceof Response) {
    return authorization;
  }

  return withStandardHeaders(new Response(null, { status: 200 }));
}

async function handleUpload(request: Request, env: BlossomBindings): Promise<Response> {
  const metadataResult = parseUploadMetadata(request, env, false);
  if (metadataResult instanceof Response) {
    return metadataResult;
  }

  const authorization = authorize(request, env, "upload", metadataResult.sha256);
  if (authorization instanceof Response) {
    return authorization;
  }

  if (request.body === null) {
    return errorResponse(400, "Bad Request", "The upload body is missing.");
  }

  const existing = await env.MEDIA.head(metadataResult.sha256);
  let stored: R2Object;
  try {
    stored = await env.MEDIA.put(metadataResult.sha256, request.body, {
      sha256: hexToArrayBuffer(metadataResult.sha256),
      httpMetadata: {
        cacheControl: CACHE_CONTROL,
        contentType: metadataResult.contentType,
      },
      customMetadata: {
        extension: metadataResult.extension,
        ownerPubkey: env.OWNER_PUBKEY_HEX,
      },
    });
  } catch (error) {
    const code = r2ErrorCode(error);
    if (code === 10037) {
      return errorResponse(409, "Conflict", "The uploaded bytes do not match X-SHA-256.");
    }
    if (code === 10014) {
      return errorResponse(400, "Bad Request", "The upload checksum is malformed.");
    }
    throw error;
  }

  if (stored.size !== metadataResult.contentLength) {
    if (existing === null) {
      await env.MEDIA.delete(metadataResult.sha256);
    }
    return errorResponse(400, "Bad Request", "Content-Length does not match the uploaded byte count.");
  }

  if (stored.size > maximumUploadBytes(env)) {
    if (existing === null) {
      await env.MEDIA.delete(metadataResult.sha256);
    }
    return errorResponse(413, "Content Too Large", "The uploaded blob exceeds this server's size limit.");
  }

  const descriptor = descriptorFor(stored, metadataResult.sha256, env);
  return jsonResponse(descriptor, existing === null ? 201 : 200);
}

async function handleGetBlob(
  request: Request,
  env: BlossomBindings,
  sha256: string,
): Promise<Response> {
  const metadata = await env.MEDIA.head(sha256);
  if (metadata === null) {
    return errorResponse(404, "Not Found", "The requested blob was not found.");
  }

  if (request.headers.get("If-None-Match") === metadata.httpEtag) {
    return withBlobHeaders(new Response(null, { status: 304 }), metadata);
  }

  const rangeResult = parseByteRange(request.headers.get("Range"), metadata.size);
  if (rangeResult === "invalid") {
    return withStandardHeaders(
      new Response(null, {
        status: 416,
        headers: {
          "Content-Range": `bytes */${metadata.size}`,
          "X-Reason": "The requested byte range is invalid or outside the blob.",
        },
      }),
    );
  }

  const object = await env.MEDIA.get(
    sha256,
    rangeResult === null ? undefined : { range: rangeResult },
  );
  if (object === null) {
    return errorResponse(404, "Not Found", "The requested blob was not found.");
  }

  const headers = blobHeaders(object);
  let status = 200;
  if (rangeResult !== null) {
    const lastByte = rangeResult.offset + rangeResult.length - 1;
    headers.set("Content-Length", String(rangeResult.length));
    headers.set("Content-Range", `bytes ${rangeResult.offset}-${lastByte}/${metadata.size}`);
    status = 206;
  }

  return withStandardHeaders(new Response(object.body, { status, headers }));
}

async function handleHeadBlob(
  _request: Request,
  env: BlossomBindings,
  sha256: string,
): Promise<Response> {
  const object = await env.MEDIA.head(sha256);
  if (object === null) {
    return errorResponse(404, "Not Found", "The requested blob was not found.");
  }
  return withBlobHeaders(new Response(null), object);
}

async function handleDeleteBlob(
  request: Request,
  env: BlossomBindings,
  sha256: string,
): Promise<Response> {
  const authorization = authorize(request, env, "delete", sha256);
  if (authorization instanceof Response) {
    return authorization;
  }

  const existing = await env.MEDIA.head(sha256);
  if (existing === null) {
    return errorResponse(404, "Not Found", "The requested blob was not found.");
  }

  await env.MEDIA.delete(sha256);
  return jsonResponse({ message: "Blob deleted." }, 200);
}

function authorize(
  request: Request,
  env: BlossomBindings,
  action: BlossomAction,
  expectedSha256: string,
): true | Response {
  const result = authorizeBlossomRequest({
    action,
    authorizationHeader: request.headers.get("Authorization"),
    expectedOwnerPubkey: env.OWNER_PUBKEY_HEX,
    expectedServerHost: new URL(env.PUBLIC_BASE_URL).hostname,
    expectedSha256,
  });

  if (!result.ok) {
    return errorResponse(
      result.status,
      result.status === 401 ? "Unauthorized" : "Forbidden",
      result.reason,
    );
  }
  return true;
}

function parseUploadMetadata(
  request: Request,
  env: BlossomBindings,
  usesBlossomPreflightHeaders: boolean,
): UploadMetadata | Response {
  const sha256 = request.headers
    .get("X-SHA-256")
    ?.trim()
    .toLowerCase();
  if (sha256 === undefined || !SHA256_PATTERN.test(sha256)) {
    return errorResponse(400, "Bad Request", "X-SHA-256 must be a lowercase SHA-256 hex string.");
  }

  const contentLengthHeader = request.headers.get(
    usesBlossomPreflightHeaders ? "X-Content-Length" : "Content-Length",
  );
  const contentLength = parsePositiveInteger(contentLengthHeader);
  if (contentLength === null) {
    return errorResponse(411, "Length Required", "A valid content length is required.");
  }
  if (contentLength > maximumUploadBytes(env)) {
    return errorResponse(413, "Content Too Large", "The blob exceeds this server's size limit.");
  }

  const rawContentType = request.headers.get(
    usesBlossomPreflightHeaders ? "X-Content-Type" : "Content-Type",
  );
  const contentType = rawContentType?.split(";", 1)[0]?.trim().toLowerCase();
  const extension = contentType === undefined ? undefined : EXTENSION_BY_MIME_TYPE.get(contentType);
  if (contentType === undefined || extension === undefined) {
    return errorResponse(415, "Unsupported Media Type", "This server does not accept that media type.");
  }

  return { contentLength, contentType, extension, sha256 };
}

function parsePositiveInteger(value: string | null): number | null {
  if (value === null || !/^\d{1,12}$/.test(value)) {
    return null;
  }
  const result = Number(value);
  return Number.isSafeInteger(result) && result > 0 ? result : null;
}

function maximumUploadBytes(env: BlossomBindings): number {
  const value = Number(env.MAX_UPLOAD_BYTES);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error("MAX_UPLOAD_BYTES must be a positive integer.");
  }
  return value;
}

function parseByteRange(header: string | null, size: number): ByteRange | null | "invalid" {
  if (header === null) {
    return null;
  }
  if (!header.startsWith("bytes=") || header.includes(",")) {
    return "invalid";
  }

  const specification = header.slice("bytes=".length).trim();
  const match = /^(\d*)-(\d*)$/.exec(specification);
  if (match === null || (match[1] === "" && match[2] === "")) {
    return "invalid";
  }

  if (match[1] === "") {
    const suffixLength = Number(match[2]);
    if (!Number.isSafeInteger(suffixLength) || suffixLength <= 0) {
      return "invalid";
    }
    const length = Math.min(suffixLength, size);
    return { offset: size - length, length };
  }

  const start = Number(match[1]);
  if (!Number.isSafeInteger(start) || start < 0 || start >= size) {
    return "invalid";
  }

  const requestedEnd = match[2] === "" ? size - 1 : Number(match[2]);
  if (!Number.isSafeInteger(requestedEnd) || requestedEnd < start) {
    return "invalid";
  }
  const end = Math.min(requestedEnd, size - 1);
  return { offset: start, length: end - start + 1 };
}

function descriptorFor(
  object: R2Object,
  sha256: string,
  env: BlossomBindings,
): BlobDescriptor {
  const contentType = object.httpMetadata?.contentType ?? "application/octet-stream";
  const extension = object.customMetadata?.extension ?? EXTENSION_BY_MIME_TYPE.get(contentType) ?? "bin";
  return {
    url: `${env.PUBLIC_BASE_URL.replace(/\/$/, "")}/${sha256}.${extension}`,
    sha256,
    size: object.size,
    type: contentType,
    uploaded: Math.floor(object.uploaded.getTime() / 1000),
  };
}

function blobHeaders(object: R2Object): Headers {
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("Accept-Ranges", "bytes");
  headers.set("Cache-Control", CACHE_CONTROL);
  headers.set("Content-Length", String(object.size));
  headers.set("ETag", object.httpEtag);
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Content-Security-Policy", "default-src 'none'; sandbox");
  return headers;
}

function withBlobHeaders(response: Response, object: R2Object): Response {
  const headers = new Headers(response.headers);
  for (const [name, value] of blobHeaders(object)) {
    headers.set(name, value);
  }
  return withStandardHeaders(new Response(response.body, { status: response.status, headers }));
}

function jsonResponse(value: object, status: number): Response {
  return withStandardHeaders(
    Response.json(value, {
      status,
      headers: { "Cache-Control": "no-store" },
    }),
  );
}

function errorResponse(status: number, statusText: string, reason: string): Response {
  return withStandardHeaders(
    Response.json(
      { error: reason },
      {
        status,
        statusText,
        headers: {
          "Cache-Control": "no-store",
          "X-Reason": reason,
        },
      },
    ),
  );
}

function methodNotAllowed(allow: string): Response {
  return withStandardHeaders(
    Response.json(
      { error: "Method Not Allowed" },
      {
        status: 405,
        headers: { Allow: allow, "Cache-Control": "no-store" },
      },
    ),
  );
}

function withStandardHeaders(response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set("Access-Control-Allow-Origin", "*");
  headers.set("Access-Control-Expose-Headers", "Content-Length, Content-Range, ETag, X-Reason");
  headers.set("Cross-Origin-Resource-Policy", "cross-origin");
  headers.set("Referrer-Policy", "no-referrer");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function hexToArrayBuffer(hex: string): ArrayBuffer {
  const bytes = new Uint8Array(hex.length / 2);
  for (let index = 0; index < hex.length; index += 2) {
    bytes[index / 2] = Number.parseInt(hex.slice(index, index + 2), 16);
  }
  return bytes.buffer;
}

function r2ErrorCode(error: unknown): number | null {
  if (!(error instanceof Error)) {
    return null;
  }
  const match = /\((\d+)\)\s*$/.exec(error.message);
  return match?.[1] === undefined ? null : Number(match[1]);
}
