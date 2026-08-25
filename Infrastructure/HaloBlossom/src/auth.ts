import { validateEvent, verifyEvent, type Event, type UnsignedEvent } from "nostr-tools/pure";

export type BlossomAction = "upload" | "delete" | "list" | "get" | "media";

export type AuthorizationResult =
  | { ok: true; event: Event }
  | { ok: false; status: 401 | 403; reason: string };

type AuthorizationRequirements = {
  action: BlossomAction;
  authorizationHeader: string | null;
  expectedOwnerPubkey: string;
  expectedServerHost: string;
  expectedSha256?: string;
  now?: number;
};

const AUTHORIZATION_PREFIX = "Nostr ";
const MAX_AUTHORIZATION_HEADER_BYTES = 128 * 1024;
const EVENT_KIND = 24_242;
const HEX_64 = /^[0-9a-f]{64}$/;
const HEX_128 = /^[0-9a-f]{128}$/;

export function authorizeBlossomRequest(
  requirements: AuthorizationRequirements,
): AuthorizationResult {
  const decoded = decodeAuthorizationEvent(requirements.authorizationHeader);
  if (!decoded.ok) {
    return decoded;
  }

  const event = decoded.event;
  if (!verifyEvent(event)) {
    return unauthorized("The Nostr authorization signature is invalid.");
  }

  if (event.kind !== EVENT_KIND) {
    return unauthorized("The Nostr authorization event kind is invalid.");
  }

  if (event.pubkey.toLowerCase() !== requirements.expectedOwnerPubkey.toLowerCase()) {
    return {
      ok: false,
      status: 403,
      reason: "This Blossom server accepts uploads only from its configured owner.",
    };
  }

  if (event.content.trim().length === 0) {
    return unauthorized("The Nostr authorization event must explain its intended use.");
  }

  const now = requirements.now ?? Math.floor(Date.now() / 1000);
  if (event.created_at > now) {
    return unauthorized("The Nostr authorization event was created in the future.");
  }

  const expirationValues = tagValues(event, "expiration");
  if (expirationValues.length !== 1) {
    return unauthorized("The Nostr authorization event must contain one expiration tag.");
  }

  const expiration = parseUnixTimestamp(expirationValues[0]);
  if (expiration === null || expiration <= now) {
    return unauthorized("The Nostr authorization event has expired.");
  }

  const actions = tagValues(event, "t");
  if (actions.length !== 1 || actions[0] !== requirements.action) {
    return unauthorized("The Nostr authorization action does not match this endpoint.");
  }

  const serverHosts = tagValues(event, "server");
  if (
    serverHosts.length > 0 &&
    !serverHosts.some((host) => host === requirements.expectedServerHost.toLowerCase())
  ) {
    return unauthorized("The Nostr authorization event is scoped to another server.");
  }

  if (requirements.expectedSha256 !== undefined) {
    const expectedSha256 = requirements.expectedSha256.toLowerCase();
    const authorizedHashes = tagValues(event, "x");
    if (!authorizedHashes.some((hash) => hash === expectedSha256)) {
      return unauthorized("The Nostr authorization event does not authorize this blob hash.");
    }
  }

  return { ok: true, event };
}

function decodeAuthorizationEvent(
  authorizationHeader: string | null,
): AuthorizationResult {
  if (authorizationHeader === null || !authorizationHeader.startsWith(AUTHORIZATION_PREFIX)) {
    return unauthorized("A Nostr authorization event is required.");
  }

  if (new TextEncoder().encode(authorizationHeader).byteLength > MAX_AUTHORIZATION_HEADER_BYTES) {
    return unauthorized("The Nostr authorization header is too large.");
  }

  const encoded = authorizationHeader.slice(AUTHORIZATION_PREFIX.length).trim();
  if (encoded.length === 0) {
    return unauthorized("The Nostr authorization event is missing.");
  }

  try {
    const json = decodeBase64URLOrStandard(encoded);
    const candidate: unknown = JSON.parse(json);
    if (!validateEvent(candidate) || !hasSignedEventFields(candidate)) {
      return unauthorized("The Nostr authorization event is malformed.");
    }
    return { ok: true, event: candidate };
  } catch {
    return unauthorized("The Nostr authorization event could not be decoded.");
  }
}

function hasSignedEventFields(event: UnsignedEvent): event is Event {
  const candidate = event as UnsignedEvent & { id?: unknown; sig?: unknown };
  return (
    typeof candidate.id === "string" &&
    HEX_64.test(candidate.id) &&
    typeof candidate.sig === "string" &&
    HEX_128.test(candidate.sig)
  );
}

function decodeBase64URLOrStandard(value: string): string {
  if (!/^[A-Za-z0-9+/_=-]+$/.test(value)) {
    throw new Error("Invalid Base64 characters.");
  }

  const standard = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = standard.padEnd(Math.ceil(standard.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

function tagValues(event: Event, name: string): string[] {
  return event.tags
    .filter((tag) => tag.length >= 2 && tag[0] === name)
    .map((tag) => tag[1])
    .filter((value): value is string => typeof value === "string");
}

function parseUnixTimestamp(value: string | undefined): number | null {
  if (value === undefined || !/^\d{1,12}$/.test(value)) {
    return null;
  }
  const timestamp = Number(value);
  return Number.isSafeInteger(timestamp) ? timestamp : null;
}

function unauthorized(reason: string): AuthorizationResult {
  return { ok: false, status: 401, reason };
}
