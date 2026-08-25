# Halo personal Blossom server

This Worker serves `media.21media.to` from a private R2 bucket. Only the configured Nostr public key can upload or delete blobs. Reads are public so media embedded in public Nostr events remains available to other clients.

## Resources

- Worker: `halo-personal-blossom-1bc70a01-production`
- R2 bucket: `halo-media-1bc70a0148b3f316-production`
- Domain: `media.21media.to`
- Owner npub: `npub1r0rs5q2gk0e3dk3nlc7gnu378ec6cnlenqp8a3cjhyzu6f8k5sgs4sq9ac`
- Owner hex pubkey: `1bc70a0148b3f316da33fe3c89f23e3e71ac4ff998027ec712b905cd24f6a411`

The project does not contain Cloudflare credentials or a Nostr private key. Wrangler uses the existing local Cloudflare login, and clients sign Blossom authorization events locally.

## Validation and deployment

```sh
npm ci
npm run check
npm run deploy:dry-run
npm run deploy:production
```

Always deploy with the `production` environment. The root Worker configuration has no resource bindings or route.

## Blossom discovery

Publish a replaceable Nostr event with kind `10063` from the owner key:

```json
{
  "kind": 10063,
  "content": "",
  "tags": [["server", "https://media.21media.to"]]
}
```

Clients that support BUD-03 can discover the server from that event. Clients with an exclusive-server setting should also set `https://media.21media.to` to prevent their own fallback behavior.

## Crawler controls

The Worker serves `robots.txt` with a site-wide `Disallow: /` directive and sends `X-Robots-Tag: noindex, nofollow, noarchive, nosnippet, noimageindex` on every response. These controls apply only to `media.21media.to`. Public reads remain available to Nostr clients, so non-compliant scrapers can still request a known blob URL.
