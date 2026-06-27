# OpenSSL 1.1.1w / TLS 1.3 for the webOS TouchPad

The 2011 HP TouchPad (webOS 3.0.5) ships **OpenSSL 0.9.8**, which can't complete a
TLS handshake with essentially any modern HTTPS server. This project builds a
process-private **OpenSSL 1.1.1w + curl 7.88.1** stack and wires the stock browser,
the app WebKit layer, and the command line into it — leaving the rest of the 0.9.8
system untouched.

> **Installing on a device?** This page is the developer/build doc. End-user install,
> verify, uninstall, and recovery instructions live in **[`ipks/README.md`](ipks/README.md)**.

## How it works

Everything modern lives under **`/usr/lib/ssl11`** (OpenSSL 1.1.1w + libcurl 4.8 +
`libssl_compat.so`), shipped by `browser-tls13`. The custom OpenSSL libs relocate
`ssl->ctx` (0xD8) and `X509_STORE_CTX->cert` (0x8) to the offsets `libWebKitLuna`
hardcodes, and `libssl_compat.so` bridges the rest — so the 2011 WebKit's cert
callback works against 1.1.

Each consumer is pointed at that stack independently:

| Package | Target | Mechanism |
|---------|--------|-----------|
| `browser-tls13` | stock Browser (`BrowserServer`) | Ships `/usr/lib/ssl11`; swaps in a **`patchelf`'d BrowserServer** (`DT_RPATH=/usr/lib/ssl11` + `libssl_compat.so` as `NEEDED`) so it loads 1.1 with no env, regardless of launcher. |
| `luna-tls13` | app WebKit host (`LunaSysMgr`/`WebAppMgr` — Mojo/Enyo XHR, `enyo.WebService`) | Edits the `LunaSysMgr` **upstart launcher** to add `LD_LIBRARY_PATH=/usr/lib/ssl11` + the compat shim to `LD_PRELOAD`. (`WebAppMgr` is a `fork()`-without-exec child, so it shares the parent's libs — the whole process must move.) |
| `curl-tls13` | command line | Self-contained curl 7.88.1 under `/usr/lib/curl11`, installed as `/usr/bin/curl11` **and** `/usr/bin/curl` (stock backed up), via an `LD_LIBRARY_PATH` + `CURL_CA_BUNDLE` wrapper. |
| `ntpdate-sync` | system clock | Upstart job; public NTP at boot + every 6 h (dead palm.com replacement) so cert validity windows stay correct. |

## Packaging notes (important for maintainers)

These install through the webOS **App-Manager** path (Preware / WebOS Quick Install /
App Catalog), which is *not* a plain `ipkg install`:

- It unpacks into the app offline-root **`/media/cryptofs/apps`** (via `ipkg -o`) and
  runs a top-level **`pmPostInstall.script`** ar member — **not** the Debian `postinst`.
- So every package ships the install logic as *both* a Debian `postinst`/`prerm`
  **and** `pmPostInstall.script`/`pmPreRemove.script` (the `pack()` function in
  `build-ipks.sh` copies them and adds them as ar members), and the scripts
  **self-default `IPKG_OFFLINE_ROOT=/media/cryptofs/apps`** so they work on every path.
- Data is laid out as a headless app under `./usr/palm/applications/<id>/files/…`;
  the postinst relocates `files/` into the live system. ar member order:
  `debian-binary, data.tar.gz, control.tar.gz, pmPostInstall.script, pmPreRemove.script`.
- **Never leave a launcher backup inside `/etc/event.d/`** — upstart runs *every* file
  there as a job, so a stray backup becomes a duplicate, crash-looping `LunaSysMgr`
  that wedges boot. `luna-tls13` keeps its backup in `/var/luna/`.
- Recovery always works via novacom (it survives a dead UI) — see `ipks/README.md`.

## Building

```sh
./build-ipks.sh        # outputs the four ipks into ipks/
```

Paths resolve relative to the script (the repo checkout), so it runs from wherever
you clone it. It **fails fast with a descriptive error** if a prerequisite is missing:

- **`patchelf`** — required to RPATH `BrowserServer` (`apt-get install patchelf` / `brew install patchelf`).
- **GNU `ar`** (binutils) — the pm-script ar members use long names; BSD `ar` (stock
  macOS) writes an incompatible format. On macOS: `brew install binutils`. On Linux the
  system `ar` is already GNU. (The script aborts with a hint if it can't find GNU ar.)
- **`BrowserServer.bin`** — the stock 3.0.5 binary (md5 `0786bdf698220aa82a90838e30355c9f`)
  at the repo root. If absent, the script **auto-fetches it over `novacom` from a
  connected, factory/stock TouchPad** and verifies the md5. So either connect a
  freshly-reset TouchPad (novacom mode) or drop a known-stock `BrowserServer.bin`
  in the repo root. The build aborts if no device is connected and the file is missing.
- Other inputs (`openssl-1.1.1w/`, `curl-7.88.1/`, `libssl_compat.so`, `ntpdate-sync`)
  are committed in the repo.

The build cleans only its own artifacts in `ipks/` (`*.ipk` + `_b_*` dirs); it leaves
`ipks/README.md` alone.

## Repo layout

```
build-ipks.sh        build all four ipks (see above)
tls13-diag.sh        on-device diagnostic (push + `sh tls13-diag.sh`; prints a PASS/FAIL VERDICT)
ipks/                built packages + END-USER README (install/verify/uninstall/recovery)
openssl-1.1.1w/      OpenSSL 1.1.1w build tree (libssl.so.1.1, libcrypto.so.1.1)
curl-7.88.1/         curl 7.88.1 build tree (libcurl.so.4.8.0, src/.libs/curl)
libssl_compat.so     struct-offset shim for libWebKitLuna
openssl_compat_shim.c  shim source
ntpdate-sync         the upstart NTP job
BrowserServer.bin    stock 3.0.5 BrowserServer (not committed; auto-fetched at build time)
```
