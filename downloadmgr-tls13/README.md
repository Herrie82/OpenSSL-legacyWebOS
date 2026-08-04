# downloadmgr-tls13 — modern TLS for the webOS Download Manager

Routes the system **Download Manager** (`com.palm.downloadmanager` /
`/usr/bin/LunaDownloadMgr`) through modern TLS 1.2/1.3 so background **downloads
and uploads** reach today's HTTPS servers. Despite the name, the Download Manager
also performs uploads (`palm://com.palm.downloadmanager/upload`), and both paths
are fixed by this package.

## How it works (no binary code patch)

`LunaDownloadMgr` does *all* its HTTP(S) transfers through **libcurl** and links
**no OpenSSL directly** — its only TLS-bearing `NEEDED` entry is `libcurl.so.4`.
So the entire service is moved to modern TLS by RPATH'ing the daemon onto a modern
libcurl; the 2011 binary's code is untouched (only its ELF `DT_RPATH`).

- Ships **libcurl 7.61.1** into `/usr/lib/ssl11dl/` — the same build `mail-tls13`
  uses: compiled against **OpenSSL 1.1.1w**, `--enable-ares` (matches the DM's
  c-ares resolver), and `--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt`.
- Sets `DT_RPATH = /usr/lib/ssl11dl:/usr/lib/ssl11` on `/usr/bin/LunaDownloadMgr`
  (our libcurl, then browser-tls13's OpenSSL). RPATH (not RUNPATH) so it also
  covers libcurl's transitive `libssl.so.1.1` / `libcrypto.so.1.1` load.

### Why the baked-in CA bundle matters

The daemon hard-codes `CURLOPT_CAPATH = /var/ssl/trustedcerts`. That directory is
hashed by the device's **OpenSSL 0.9.8**, whose subject-name hashes **OpenSSL 1.1
cannot find** (the algorithm changed in 1.0.0). With TLS otherwise working, modern
certs would still fail as *"unable to get local issuer certificate."* Because our
libcurl bakes a default `CAINFO` bundle, OpenSSL 1.1 loads that bundle in addition
to the (unreadable) CAPATH dir and validation succeeds. No cert-related patching of
the daemon is required. A current `/etc/ssl/certs/ca-certificates.crt` (e.g.
`com.palm.rootcertsupdate`) and a correct clock (`ntpdate-sync`) are still required.

## Sending extra request headers (JWT / X-Auth-Token / etc.)

The documented `download` API only exposes `cookieHeader` (sent as `Cookie:`) plus
the app-catalog-specific `authToken`/`deviceId` (sent as fixed `Auth-Token:` /
`Device-Id:` headers, and only when *both* are present). None of those let you send
an `Authorization: Bearer <JWT>` or `X-Auth-Token`.

**Uploads** already accept a proper `customHttpHeaders` array — pass any headers:

```javascript
this.$.uploader.call({
    fileName: "/media/internal/downloads/out.bin",
    url: "https://api.example.com/upload",
    contentType: "application/octet-stream",
    customHttpHeaders: [ "Authorization: Bearer " + jwt, "X-Auth-Token: " + tok ],
    subscribe: true
});
```

**Downloads** gain arbitrary headers via a **`cookieHeader` multi-line convention**:
the underlying libcurl sends the first line as the `Cookie:` header and **every
subsequent line as a raw request header**. Lines split on `\r\n` or `\n`.

- Headers only (no cookie) — **begin the value with a newline**:

  ```javascript
  cookieHeader: "\r\nAuthorization: Bearer " + jwt + "\r\nX-Auth-Token: " + tok
  ```

- A cookie *and* extra headers — cookie on the first line:

  ```javascript
  cookieHeader: "session=" + sid + "\r\nAuthorization: Bearer " + jwt
  ```

- A single line with no newline is still treated as a plain cookie (fully
  backward-compatible with existing callers).

### Convenience helper

```javascript
// Build a download() cookieHeader from an optional cookie + a headers map.
// dmHeaders({Authorization: "Bearer "+jwt, "X-Auth-Token": tok})
function dmHeaders(headers, cookie) {
    var lines = [];
    for (var k in headers) if (headers.hasOwnProperty(k)) lines.push(k + ": " + headers[k]);
    // leading "" => leading CRLF => no bogus cookie when `cookie` is absent
    return [cookie || ""].concat(lines).join("\r\n");
}

this.$.downloader.call({
    target: "https://api.example.com/protected/file.bin",
    targetDir: "/media/internal/downloads/",
    targetFilename: "file.bin",
    cookieHeader: dmHeaders({ "Authorization": "Bearer " + jwt }),
    subscribe: true
});
```

This capability is a stable property of the exact libcurl the package ships (it is
frozen — the `.so` is not rebuilt on-device), and it needs no change to the
`LunaDownloadMgr` binary.

## Install / removal

- **Requires `org.webosinternals.browser-tls13`** (provides `/usr/lib/ssl11`
  OpenSSL). The postinst refuses to patch if `/usr/lib/ssl11` is absent, so it
  can't break downloads by being installed in the wrong order.
- Backs the stock daemon up to `/var/luna/LunaDownloadMgr.tls13-orig`; `prerm`
  restores it and removes `/usr/lib/ssl11dl`.
- **Remove this package *before* `browser-tls13`** (same rule as `luna-tls13`).
- No reboot needed — the postinst restarts the `LunaDownloadMgr` upstart job.

## Hardware validation (topaz, webOS 3.0.5)

*(A **webOS 3.0.4** TouchPad Go build ships as `downloadmgr-tls13-go` in `ipks/opal/`,
RPATH'd from that Go's own stock `LunaDownloadMgr`; `opal` also shipped at 3.0.5, which this
build does not cover. Its install pass on hardware is still pending. Unlike `BrowserServer`,
this daemon has no cross-module vtable exposure — its five vtables are identical in name and
size between 3.0.4 and 3.0.5, and nothing links against an executable — so the version-skew
hazard that affects the browser does not apply here. The postinst still gates on the stock
`LunaDownloadMgr` md5 and refuses on a mismatch, for consistency with `browser-tls13`.)*

- Download of `https://www.howsmyssl.com/a/check` → `"tls_version":"TLS 1.3"`, HTTP 200.
- Download of a Let's Encrypt-served file (ISRG root) → HTTP 200, `completed:true`
  (modern cert validation via the baked bundle, despite the 0.9.8-hashed CAPATH).
- Multipart upload to `https://postman-echo.com/post` → HTTP 200, echoed file +
  `customHttpHeaders`.
- Download with `cookieHeader: "\r\nAuthorization: Bearer …\r\nX-Auth-Token: …"`
  → server received both as real request headers, no `Cookie` sent.
