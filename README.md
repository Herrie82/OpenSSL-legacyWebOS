# Modern TLS for legacy webOS (TouchPad / TouchPad Go 3.0.5 & 2.2.4 phones)

Bring TLS 1.2 / 1.3 to legacy webOS devices so they can actually connect to today's
HTTPS sites — in the **stock browser**, in **apps** (Mojo/Enyo WebKit), in the
**download manager**, and on the **command line** — without replacing the OS or
changing the rest of the device's 2011 TLS behaviour.

Legacy webOS ships **OpenSSL 0.9.8** (TLS 1.0 only). Modern servers refuse TLS 1.0,
so the built-in browser, app `XMLHttpRequest`s, and `curl` can no longer reach
them. This project installs a private, modern **OpenSSL 1.1.1w + curl 7.88.1**
stack in `/usr/lib/ssl11` and points exactly the consumers you want at it, leaving
the rest of the 2011 OS untouched.

## Supported devices

| Device | codename | webOS | Status |
|---|---|---|---|
| HP TouchPad | `topaz` | 3.0.5 | ✅ Hardware-verified |
| HP TouchPad Go | `opal` | 3.0.5 (**doctor it first**) | ✅ Hardware-verified — takes the **`topaz`** packages; see below |
| HP Pre 3 | `mantaray` | 2.2.4 | ✅ Hardware-verified |
| HP Veer | `broadway` | 2.2.4 | ⚠️ Built & published, untested on hardware |
| Palm Pre 2 | `roadrunner` | 2.2.4 | ⚠️ Built & published, untested on hardware |

The device-specific packages embed a patched copy of that device's own stock binary,
so they are **built per device** and live in per-codename folders under
[`ipks/`](ipks/). The three phones are additionally published as a **single merged
set** in [`ipks/phone/`](ipks/phone/) (`*-phone` package names) that picks the right
board at install time — that is the build a feed should carry. The **TouchPad Go has no
packages of its own**: doctor it to 3.0.5 and it takes the `topaz` ones. See
[Which packages for which device](#packages).

**What must match is the webOS BUILD, not the board.** The device-specific packages
swap in a stock binary, and `BrowserServer` *defines* the `BrowserPage` vtable that
`libWebKitLuna.so` calls **by index**. webOS 3.0.5 inserts five `Palm::WebViewClient`
sensor virtuals into the *middle* of that vtable (125 slots on 3.0.4 vs 130 on 3.0.5),
so every slot from 36 up shifts by five: 3.0.4's slot 43 `setCanBlitOnScroll(bool)`,
called on every page layout, trades places with 3.0.5's `showPrintDialog()`. Install a
3.0.5 binary on a 3.0.4 tablet and **the print dialog opens every time you navigate** —
100% reproducible, even factory-fresh. The reverse (3.0.4 binary on a 3.0.5 tablet) is
worse: 3.0.5 would call the sensor slots and land on unrelated 3.0.4 methods with
mismatched signatures.

**The TouchPad Go (`opal`) shipped at BOTH 3.0.4 and 3.0.5**, depending on its cellular
modem chipset — so the board name alone does *not* tell you which build you have. **Doctor
a Go to 3.0.5 before installing anything**; a Doctor exists that brings every Go variant up
to 3.0.5, and once it is on 3.0.5 the ordinary `topaz` packages are the correct build for
it. This is hardware-proven, not inferred: a doctored Go runs the `topaz` `BrowserServer`,
`LunaDownloadMgr` and IMAP tagfix correctly.

Its *stock* binaries are not byte-identical to the TouchPad's — the Go's stock
`BrowserServer` is `aae93132…` against the TouchPad's `0786bdf6…`, the same 252,564 bytes
differing in 2.6 % of them (device-variant details, not layout; compare the Pre 2 vs Pre 3,
both webOS 2.2.4, which differ in ~115 KB of 239 KB). What matters is the webOS **build**,
and that is identical. So every device-specific package reads the device's own
`PRODUCT_VERSION_STRING` and **refuses to install, before touching anything**, unless the
webOS version matches the one it was built for — an un-doctored 3.0.4 Go is declined with a
message telling you to doctor it, rather than silently getting the print-dialog bug. An
unrecognised stock md5 on a *matching* webOS version is reported as a NOTE and installation
proceeds, which is exactly the doctored-Go case.

On the phones, **webOS 2.2.4 is a hard requirement**, not a recommendation: an
un-upgraded Veer (2.2.0) or Pre 2 (2.1.0) has different stock binaries than these
patches were built against. Get to 2.2.4 (Super Doctor) first.

> **Installing?** Jump to [Packages & install order](#packages). The TL;DR also
> lives in [`ipks/README.md`](ipks/README.md). **Building from source?** See
> [`BUILDING.md`](BUILDING.md).

---

## What it DOES

- ✅ **TLS 1.2 / 1.3 in the stock browser** (`BrowserServer`) — modern ciphers, SNI.
- ✅ **TLS 1.2 / 1.3 in apps** — Mojo/Enyo `XMLHttpRequest`, `enyo.WebService`, and
  any HTML rendered in a card, via the app WebKit host (`LunaSysMgr`/`WebAppMgr`).
- ✅ **A modern command-line `curl`** (7.88.1) — installed as both `curl11` and
  `curl` (the stock 0.9.8 binary is backed up and restored on removal).
- ✅ **Modern TLS for the stock Email app** (optional `mail-tls13` package) — the
  native mail transports reach TLS 1.2/1.3 servers. **EAS, IMAP, POP & SMTP are all
  working and hardware-proven** (Zoho EAS — Mail/Contacts/Calendar/Tasks sync directly,
  no proxy; Fastmail IMAP/SMTP; Gmail IMAP/POP/SMTP). Gmail needs a Google App Password.
- ✅ **Validates current certificates** against an up-to-date Mozilla CA bundle.
- ✅ **gzip/deflate** decoding (curl built with zlib) — required for most sites.
- ✅ **Modern TLS for the system Download Manager** (optional `downloadmgr-tls13`
  package) — `/usr/bin/LunaDownloadMgr` is RPATH'd onto the ssl11 curl, so background
  downloads *and* uploads reach modern HTTPS.
- ✅ **Process-private & reboot-proof.** The modern stack lives in `/usr/lib/ssl11`
  and is loaded only by the browser, the app WebKit host, and the curl wrapper.
  Wi‑Fi/VPN/EAP, `keymanager`, Node services, etc. keep using the original 0.9.8 and
  are **unaffected**. (E‑mail and the download manager can each be moved to modern
  TLS separately with the optional `mail-tls13` / `downloadmgr-tls13` packages — see
  Packages.)
- ✅ **Auto clock sync** (separate package): webOS's own time sync targets dead
  `palm.com` servers, so the clock drifts and breaks cert validity windows.
- ✅ **Cleanly removable** — every change is reversible via package removal.

## What it does NOT do

- ❌ **It does not upgrade the rendering engine.** Browser *and* apps still use
  2011-era WebKit. Modern TLS gets you *connected* and the page *downloaded*, but
  heavy modern sites (lots of JS, modern CSS, SPAs) will render **blank or
  partially**, and some interactive features won't work. Only a newer engine
  (e.g. the LuneOS / Qt‑WebEngine route) fixes that — no TLS change can.
- ❌ **It does not bypass bot/WAF blocks.** Sites behind Cloudflare "managed
  challenge" or strict bot rules will serve a *"you have been blocked"* page —
  the server refusing the old client, not a TLS failure.
- ❌ **It does not change the User-Agent.** The browser still identifies as webOS.
  (A UA override is a one-line edit to `/etc/palm/browser-app.conf`
  — `UserAgentOverride=...` — kept deliberately *out* of these packages.)
- ❌ **It does not upgrade TLS system-wide.** Only the browser, the app WebKit
  host, the `curl` command, and — if you install the optional packages — the mail
  transports and the download manager are moved to 1.1. Wi‑Fi/VPN/EAP,
  `keymanager`, `PmNetConfigManager`, OTA/app-catalog fetches, and other
  libcurl/OpenSSL consumers stay on 0.9.8 **on purpose** — a global swap bricks
  boot. See *Effect on curl / libcurl* below.
- ❌ **No brotli.** curl advertises gzip only. (gzip covers virtually everything.)
- ❌ **It does not ship a CA bundle.** It relies on a current
  `/etc/ssl/certs/ca-certificates.crt` — see [Requirements](#requirements).

### Effect on curl / libcurl

To be explicit, since this trips people up:

- ✅ **The `curl` command is modernized** — `curl-tls13` installs curl 7.88.1
  (OpenSSL 1.1.1w, with zlib) as `/usr/bin/curl11` **and** replaces `/usr/bin/curl`
  (stock saved to `/usr/bin/curl.0.9.8-orig`, restored on removal). Its wrapper
  defaults `CURL_CA_BUNDLE` to the system bundle so verification just works.
- ✅ **App WebKit uses modern libcurl** — `luna-tls13` makes `LunaSysMgr`/`WebAppMgr`
  load `/usr/lib/ssl11`, so app `XHR` goes over TLS 1.3.
- ✅ **The download manager can be modernized** — `downloadmgr-tls13` RPATHs
  `/usr/bin/LunaDownloadMgr` onto the ssl11 curl with a baked CA bundle. Optional
  and separate, for the same isolation reason.
- ❌ **The system `/usr/lib/libcurl.so.4` (7.21.7 / 0.9.8) is NOT replaced.** Other
  libcurl consumers — `PmNetConfigManager`, `keymanager`, app/JS services — keep
  using the old curl and are still limited to TLS 1.0. This is intentional isolation
  (a global swap breaks unrelated services).

---

## Requirements

- One of the **[supported devices](#supported-devices)** above: an HP TouchPad **or**
  TouchPad Go on **webOS 3.0.5** (Doctor 3.0.5 / "doctor305"; a Go on 3.0.4 must be
  doctored to 3.0.5 first — there is a Doctor for every Go variant), or a Pre 3 / Veer /
  Pre 2 on **webOS 2.2.4**. Both 3.0.5 tablets take the same
  [`ipks/tablet/`](ipks/tablet/) build; the phones have their own — see
  [Compatibility](#compatibility).
- A **current Mozilla CA bundle** at `/etc/ssl/certs/ca-certificates.crt` (install a
  `ca-certificates` ipk; the stock 2011 bundle won't validate modern sites). The
  browser package **warns** on a stale bundle but does not install one.
- Wi‑Fi with working DNS (for the clock-sync package).

## Packages

Standard webos-internals-style ipks — install via **Preware**, **WebOS Quick
Install**, **App Catalog**, or `ipkg install`.

**Grab the right files first.** The device-specific packages (`browser-tls13`,
`luna-tls13`, `downloadmgr-tls13`, `mojomail-imap-tagfix`) are built per device and
live in a per-target folder under [`ipks/`](ipks/); `curl-tls13`, `ntpdate-sync` and
`mail-tls13` are identical on every device and live at [`ipks/`](ipks/) top level.
Both webOS 3.0.5 tablets — TouchPad and doctored TouchPad Go — take
[`ipks/tablet/`](ipks/tablet/). On phones, prefer the merged
[`ipks/phone/`](ipks/phone/) set — same packages with `-phone` appended to each name,
one ipk covering all three boards, resolved at install time from
`/etc/prefs/properties/machineName`. An unrecognised board (including a TouchPad)
**exits non-zero before touching anything**. Full rationale in
[`ipks/README.md`](ipks/README.md).

**Install in this order** (append `-phone` to the device-specific names if you're
using the merged phone set):

| # | Package | Installs |
|---|---------|----------|
| 1 | `org.webosinternals.browser-tls13` | OpenSSL 1.1.1w + curl(zlib) + compat shim in `/usr/lib/ssl11`, and an RPATH-patched `/usr/bin/BrowserServer`. **Install first** — provides `/usr/lib/ssl11` that #2 and #3 build on. |
| 2 | `org.webosinternals.luna-tls13` | Patches the `LunaSysMgr` upstart launcher to load `/usr/lib/ssl11`, moving app WebKit onto modern TLS. **v1.1.1 also installs a `media-pipeline` env-scrub wrapper so streaming *and* local media (Pandora/Plex/drPodder and stock Music) play reliably** — the media worker inherited the ssl11 stack it never needed, which wedged playback after one track. **v1.1.2 adds a `setcpushares-pdk` env-scrub wrapper so PDK apps (QupZilla / the nizovn Qt5 stack) launch again** — the launcher's `LD_BIND_NOW=1` leaked into every PDK launch and is fatal under LunaCE (its `libpvrtc.so` preload has lazily-unresolved symbols; eager binding kills `/bin/sh` at exec, exit 127), and the leaked compat-shim preload crashes nizovn-glibc apps under stock Luna. **v1.1.3 adds a `setcpushares-task` env-scrub wrapper so App-Manager installs/removes (Preware `installSvc`/WOSQI) stop wedging** — the same leaked `LD_BIND_NOW=1` killed `/bin/sh` running the installer's cpu-shares helper under LunaCE, failing the install and hanging Preware. Installs cleanly on top of 1.0.0/1.1.0/1.1.1/1.1.2. **Requires #1; reboot after.** *(Those three wrappers are webOS 3.x / LunaCE-specific — the webOS 2.x phone build is the launcher patch alone, with no payload, and is byte-identical across all three phones.)* |
| 3 | `org.webosinternals.curl-tls13` | Modern command-line curl as `/usr/bin/curl11` and `/usr/bin/curl`. Standalone. |
| 4 | `org.webosinternals.ntpdate-sync` | Upstart job: public NTP at boot (retry-until-success) and every 6 h. Standalone. |
| 5 | `org.webosinternals.mail-tls13` | **Optional.** Routes the stock Email app's native transports through OpenSSL 1.1.1w via a purpose-built libcurl + its own compat shim in `/usr/lib/ssl11mail`. **EAS, IMAP, POP & SMTP all working & hardware-proven** (Zoho EAS; Fastmail IMAP/SMTP; Gmail IMAP/POP/SMTP — needs a Google App Password). **Requires #1 installed** (for `/usr/lib/ssl11`); no reboot needed. See [BUILDING.md](BUILDING.md). |
| 6 | `org.webosinternals.mojomail-imap-tagfix` | **Optional, standalone.** A one-byte patch to `mojomail-imap` so **strict IMAP servers (e.g. Fastmail) accept its command tags** (stock mojomail uses a `~`-prefixed tag some servers reject, hanging IMAP validation). Only needed for such servers; pairs with #5. Independent — take it or leave it. Reversible (restored on removal). See [mojomail-changes.md](mojomail-changes.md). |
| 7 | `org.webosinternals.downloadmgr-tls13` | **Optional.** RPATHs the system Download Manager (`/usr/bin/LunaDownloadMgr`, `com.palm.downloadmanager`) onto the ssl11 curl 7.61.1 + a baked CA bundle, so background downloads **and uploads** negotiate TLS 1.2/1.3. No OpenSSL patch needed — the daemon links no OpenSSL directly — but it DOES get one mandatory one-byte code patch that disables its runtime curl multi-handle restart, which otherwise SIGSEGVs in `curl_multi_remove_handle` on any modern libcurl (see [downloadmgr-tls13/README.md](downloadmgr-tls13/README.md)). **Requires #1**; remove it *before* #1. No reboot needed. |

After installing, **reboot once** (`browser-tls13` self-restarts the browser, but
`luna-tls13`'s launcher change applies on reboot). `luna-tls13`'s postinst refuses
to patch if `/usr/lib/ssl11` is absent, so a wrong install order can't brick the
device — it just no-ops with an error. Removing a package restores stock state.

Verify with `sh tls13-diag.sh` (expect `VERDICT: PASS`); load an HTTPS site in the
browser and in an app; `curl https://github.com`.

### Recovery (if the UI ever fails to boot)

`novacomd` runs independently of the UI. Over novacom as root:

```sh
mount -o remount,rw /
cp /var/luna/LunaSysMgr.tls13-orig /etc/event.d/LunaSysMgr   # restore stock launcher
reboot
```

> ⚠️ Never leave a launcher backup **inside** `/etc/event.d/` — upstart runs every
> file there as a job, so a stray copy becomes a duplicate, crash-looping
> `LunaSysMgr`. All backups live in `/var/luna/`.

---

## How it works (for the curious)

The browser's and apps' TLS lives in **`libcurl`** (the TLS engine) and
**`libWebKitLuna`** (a cert-verification callback), both compiled against the
0.9.8 ABI.

1. **Private modern stack.** OpenSSL 1.1.1w + curl 7.88 (with zlib) install in
   `/usr/lib/ssl11`, with symlinks named like the old `libssl.so.0.9.8` /
   `libcrypto.so.0.9.8` pointing at the 1.1 libraries.

2. **Two struct-offset fixes.** `libWebKitLuna`'s verify callback reads two OpenSSL
   fields at **hard-coded 0.9.8 offsets** (`ssl->ctx` @ `0xD8`,
   `X509_STORE_CTX->cert` @ `0x8`). The bundled 1.1.1w is built with those fields
   **relocated** to match, so the callback works instead of crashing. (Found via
   Ghidra/objdump of the device binaries.)

3. **Compat shim** (`libssl_compat.so`) provides the 0.9.8 symbols 1.1 dropped
   (`sk_*` → `OPENSSL_sk_*`, legacy init no-ops, etc.).

4. **Per-consumer wiring:**
   - **browser** (`browser-tls13`): `/usr/bin/BrowserServer` is `patchelf`'d with
     `DT_RPATH=/usr/lib/ssl11` + the shim as `NEEDED`, so the whole browser process
     resolves OpenSSL/curl from `/usr/lib/ssl11` with **no env vars**, regardless
     of launcher. No other process is affected.
   - **apps** (`luna-tls13`): the app WebKit host is `LunaSysMgr` and a `WebAppMgr`
     child it `fork()`s *without exec* (so the child shares the parent's libs — the
     whole process must move). Its **upstart launcher** gets
     `LD_LIBRARY_PATH=/usr/lib/ssl11` + the shim in `LD_PRELOAD`.
   - **curl** (`curl-tls13`): a self-contained curl under `/usr/lib/curl11`, exposed
     via a small `LD_LIBRARY_PATH` + `CURL_CA_BUNDLE` wrapper as `curl11`/`curl`.

5. **CA bundle + clock.** curl validates against the Mozilla bundle; the NTP job
   keeps the clock correct so freshly-issued certs aren't seen as "not yet valid".

> **Packaging note:** these install through the webOS App-Manager (Preware/WOSQI),
> which unpacks into `/media/cryptofs/apps` and runs a `pmPostInstall.script`, **not**
> the Debian `postinst`. The packages ship both, app-layout, offline-root aware.
> Details in [`BUILDING.md`](BUILDING.md).

---

## Troubleshooting

Run `sh tls13-diag.sh` — it prints a PASS/FAIL **VERDICT** plus per-component status
and an end-to-end curl. Common results:

| Symptom | Cause / fix |
|---|---|
| `browser-tls13 NOT-INSTALLED` / `ssl11 missing` | Install didn't apply; reinstall via Preware/WOSQI/`ipkg`. |
| `BrowserServer: FAIL still STOCK` | RPATH swap skipped — usually a non-3.0.5 `BrowserServer` (see Compatibility). |
| `on ssl11: 0 maps` | Browser on old 0.9.8 — stray duplicate upstart job, or swap didn't apply. |
| apps still on TLS 1.0 | `luna-tls13` not installed, or not rebooted; or `/usr/lib/ssl11` absent (install `browser-tls13` first). |
| `curl: (60) ... local issuer` | Stale/missing CA bundle — install a current Mozilla `ca-certificates` ipk. |
| `curl http=000` right after boot | Network/clock not ready; retry after ~90 s. |
| Page blank / "you have been blocked" | Engine limit / Cloudflare block — **not** TLS (see *What it does NOT do*). |
| Media (Pandora/Plex/drPodder **or** stock Music) plays ~1 song, then the play button does nothing until a reboot | Update `luna-tls13` to **≥ 1.1.1** and reboot — it installs a `media-pipeline` env-scrub wrapper that keeps the ssl11 stack (which the media worker never needed) out of the worker, so playback stops wedging. (1.1.0's `LD_BIND_NOW` only fixed an earlier crash-on-start; it left this deeper wedge.) |
| PDK apps (QupZilla / nizovn Qt5 stack) die instantly on launch — LunaSysMgr logs `childProcessDied … status 32512` (exit 127) | Update `luna-tls13` to **≥ 1.1.2** — it installs a `setcpushares-pdk` env-scrub wrapper that strips the leaked launcher env (`LD_BIND_NOW`, compat-shim preload, ssl11 lib path) from every PDK launch. Fatal combo is LunaCE + luna-tls13 ≥ 1.1.0: LunaCE's PDK child env preloads `libpvrtc.so`, whose lazily-unresolved `NApp_*` symbols become eager-bind errors, so `/bin/sh` dies before the app exists. |
| App-Manager installs/removes wedge or fail with `FAILED_IPKG_INSTALL` (child exit 127) under LunaCE + luna-tls13 — **Preware hangs mid-install** ("stuck IPKG lock") | Update `luna-tls13` to **≥ 1.1.3** — it installs a `setcpushares-task` env-scrub wrapper. LunaSysMgr runs the installer as `setcpushares-task ApplicationInstallerUtility -c install …`; `setcpushares-task` is a `/bin/sh` script, and the same leaked `LD_BIND_NOW=1` + LunaCE's `libpvrtc.so` preload kills `/bin/sh` at exec (127), so the install fails and `com.palm.appinstaller` drops the connection, hanging Preware's request. The wrapper strips the leaked env from that spawn. (Preware's default *installCli* path was already fine — only *installSvc*/WOSQI hit this.) |

## Compatibility

Each build is made from that **webOS build's** stock binaries — for the tablets, the
webOS 3.0.5 `BrowserServer` (md5 `0786bdf6…`) and `libWebKitLuna` (md5 `3d90fd6e…`)
taken off a TouchPad; each 2.2.4 phone has its own pair. A doctored TouchPad Go's own
stock binaries differ slightly (`aae93132…`) but its webOS build — and therefore its
vtable layout — is the same, and the TouchPad build is hardware-proven on one. The
browser package only applies the RPATH swap
if `/usr/bin/BrowserServer` is non-stock-safe (it backs up whatever it replaces).
If `tls13-diag.sh` reports a **different** `libWebKitLuna` md5, that device is a
different webOS build — send that file to verify the struct offsets for that variant.

**Wrong-device protection.** The merged `*-phone` packages resolve the board from
`/etc/prefs/properties/machineName` (falling back to matching a known board name in
`/etc/palm-build-info`) and `exit 1` **before touching anything** if it isn't one of
`mantaray` / `broadway` / `roadrunner` — a TouchPad included.

**Wrong-BUILD protection (the one that actually matters).** Board identity is not
enough, because `opal` (TouchPad Go) ships at two different webOS versions. So *every*
device-specific package verifies the device's **own `PRODUCT_VERSION_STRING`** before
doing anything, and `exit 1`s if it isn't the webOS version the package was built for.
That is what would have caught the original bug: a TouchPad Go **on 3.0.4** handed the
TouchPad build is exactly how the print-on-navigate failure happened, and that install
is now refused outright, with a message saying to doctor the Go to 3.0.5.

A stock binary whose md5 we don't recognise on a *matching* webOS version is a NOTE, not
a refusal — that is the doctored-Go case, and gating on the md5 instead would wrongly
decline it. (An md5 mismatch is only fatal when the webOS version can't be read at all.)

The per-target ipks in `ipks/<target>/` still **must not be published in one feed
together**, because all four builds share the same `Package`+`Version`+`Architecture`
and ipkg's dedupe key is exactly that triple. That is what the `phone` target exists to
solve. See [`ipks/README.md`](ipks/README.md).

---

## Building from source

See **[`BUILDING.md`](BUILDING.md)** — prerequisites (`patchelf`, GNU `ar`,
auto-fetch of the stock `BrowserServer` over novacom) and `./build-ipks.sh`, which
takes a device and/or a package:

```sh
./build-ipks.sh                 # every device whose stock binaries you have
./build-ipks.sh phone           # the merged all-three-phones set -> ipks/phone/
./build-ipks.sh topaz           # the 3.0.5 tablet set          -> ipks/tablet/
./build-ipks.sh topaz browser   # one device, one package
```

## Credits / notes

Reverse-engineering, struct-offset analysis, packaging and testing done against a
live TouchPad (and a TouchPad Go) over novacom. What the packages do to a device is
an in-place `patchelf` of the on-device `BrowserServer` / `LunaDownloadMgr` (RPATH +
NEEDED) and a one-byte `mojomail-imap` tag patch, all reverted on package removal.

No stock Palm binary is redistributed: `devices/<board>/` is populated locally from your
own device (auto-fetched over novacom), and `prebuilt_rpath()` re-uses the already-patched
binary from a previously built ipk when a checkout has none.

The packages are **unsigned** — sign with the webos-internals feed key before
publishing to the official feed.
