# Modern TLS ipks — install order

## How this directory is laid out

Two different kinds of folder sit side by side here, which is worth getting straight before
you pick files:

```
ipks/
  *.ipk           device-INDEPENDENT — the same file for every device
                  (curl-tls13, ntpdate-sync, mail-tls13)

  tablet/         ─┐  device-SPECIFIC builds: each holds browser-tls13, luna-tls13,
  mantaray/        │  downloadmgr-tls13 and mojomail-imap-tagfix carrying that build's
  broadway/        │  patched stock binaries. One folder = one thing you install by hand.
  roadrunner/     ─┘  Package names here are UNSUFFIXED, so no two can share a feed.

  phone/              a MERGED build: one ipk per package holding all three phones'
                      pieces, named *-phone, picking its board at install time.
                      This is what a feed carries for the phones.
```

The per-build folders are the raw output — they all contain a package literally named
`org.webosinternals.browser-tls13`, so publishing two of them in one feed is impossible
(see [`phone/`](phone/) below for why). `phone/` exists to solve that for the phones.

| Device | codename | folder to install | + shared (this dir) |
|--------|----------|-------------------|---------------------|
| HP TouchPad (webOS 3.0.5) | topaz | [`tablet/`](tablet/) | `curl-tls13`, `ntpdate-sync`, `mail-tls13` |
| HP TouchPad Go — **doctored to webOS 3.0.5** | opal | [`tablet/`](tablet/) — same files | `curl-tls13`, `ntpdate-sync`, `mail-tls13` |
| HP Pre 3 (webOS 2.2.4) | mantaray | [`mantaray/`](mantaray/) | `curl-tls13`, `ntpdate-sync`, `mail-tls13` |
| Palm Pre 2 (webOS 2.2.4) | roadrunner | [`roadrunner/`](roadrunner/) | `curl-tls13`, `ntpdate-sync`, `mail-tls13` |
| HP Veer (webOS 2.2.4) | broadway | [`broadway/`](broadway/) | `curl-tls13`, `ntpdate-sync`, `mail-tls13` |
| **all three phones in one set** | — | [`phone/`](phone/) | `curl-tls13`, `ntpdate-sync`, `mail-tls13` |

[`tablet/`](tablet/) is named for what it serves rather than the board it was built from:
**both** webOS 3.0.5 tablets take the same files. Everything on the build side is still
board-keyed (`devices/<board>/`, `./build-ipks.sh topaz`). (A new device builds the same
way — drop its stock binaries in `devices/<codename>/` and run `./build-ipks.sh <codename>`.)

> **Match the webOS BUILD, not the board.** 3.0.5 inserts five `Palm::WebViewClient` sensor
> virtuals into the *middle* of the `BrowserPage` vtable (125 slots on 3.0.4 vs 130 on 3.0.5),
> and `libWebKitLuna.so` calls that vtable **by index**, so every slot from 36 up shifts by
> five — 3.0.4's slot 43 `setCanBlitOnScroll(bool)` (called on every page layout) trades places
> with 3.0.5's `showPrintDialog()`, and **the print dialog opens every time you navigate**.
>
> The TouchPad Go (`opal`) shipped at **both 3.0.4 and 3.0.5** depending on its cellular modem,
> so the board name doesn't tell you which you have. **Doctor a Go to 3.0.5 first** — a Doctor
> exists for every Go variant — and then it takes [`tablet/`](tablet/), hardware-proven. Every
> device-specific package reads your device's own `PRODUCT_VERSION_STRING` and **refuses before
> touching anything** if it's the wrong webOS version, so a Go still on 3.0.4 is declined (with
> a message telling you to doctor it) rather than silently broken. A doctored Go's stock
> binaries aren't byte-identical to a TouchPad's — different device, same build — so an
> unrecognised stock md5 on a *matching* webOS version is reported as a note and the install
> proceeds.

## `phone/` — one set of packages for all three phones (use this for a FEED)

The per-build folders above are for hand-installing on a known device. They **cannot** be published
in a Preware/ipkg feed together, because all four builds share the same `Package` **and** `Version`
**and** `Architecture`: ipkg's dedupe key is exactly that triple (`pkg_vec.c`,
`pkg_vec_insert_merge`) and for feed parsing it "just overwrite[s] the old one", across every
configured feed at once (one hash table). Preware then installs **by name** and lets ipkg pick the
file — so a Pre 3 could be handed the tablet build, and `luna-tls13` (which edits
`/etc/event.d/LunaSysMgr`) has no md5 guard to catch that.

`./build-ipks.sh phone` therefore emits **one ipk per package covering all three phones**, named
`*-phone`, into [`phone/`](phone/):

- `org.webosinternals.browser-tls13-phone`, `…luna-tls13-phone`,
  `…downloadmgr-tls13-phone`, `…mojomail-imap-tagfix-phone`
- Each bundles every board's pieces and picks at install time from
  `/etc/prefs/properties/machineName` (falling back to matching a known board name in
  `/etc/palm-build-info`). An unrecognised board — including a TouchPad — **exits non-zero before
  touching anything**, which is a hard wrong-device guard these packages never had.
- Cheap, because the per-board part is small: the ssl11 OpenSSL/curl payload and the mail libcurl are
  identical across boards; only the ~250KB `BrowserServer.rpath` / ~480KB `LunaDownloadMgr.rpath` and
  a few md5s/offsets differ. `luna-tls13`'s webOS-2.x build is byte-identical across all three phones
  and `mojomail-imap-tagfix` is postinst-only. Whole phone family: ~2.7MB.
- **Hardware-verified on an HP Pre 3.** Veer (broadway) and Pre 2 (roadrunner) are built and
  published but untested on hardware.

Because the names differ from the unsuffixed ones, both families can live in a single feed — which
is how `webOSArchive/preware-modernize-feed` ships them, one URL for every device.

The tablets need no equivalent: there is only **one** tablet build, and both the TouchPad and a
doctored TouchPad Go install it, so nothing collides.

**Building `phone/` without the stock Palm binaries:** a fresh checkout has no
`devices/<board>/*.bin` (they're your device's, not ours to redistribute). `prebuilt_rpath()` falls
back to extracting the already-RPATH'd binary from the committed per-board ipk, which is
bit-identical to what was built and tested there (only the stock md5 for the postinst's "non-stock
backup" NOTE then comes from the registry instead of a live `md5sum`). So `./build-ipks.sh phone`
works anywhere; you still need GNU `ar`.

## Install order

Install via **Preware** / **WebOS Quick Install** / `ipkg install`, in this order:

(On the phone set, append `-phone` to each device-specific package name below —
`org.webosinternals.browser-tls13-phone` and so on. `curl`/`ntp`/`mail` are unchanged.)

1. `org.webosinternals.browser-tls13` — browser TLS 1.3 (provides `/usr/lib/ssl11`; **install first**)
2. `org.webosinternals.luna-tls13` — apps (Mojo/Enyo WebKit) TLS 1.3 (**requires #1**)
3. `org.webosinternals.curl-tls13` — modern `curl` / `curl11`
4. `org.webosinternals.ntpdate-sync` — clock sync

Then **reboot once**.

Optional packages — modern TLS for the stock Email app:

5. `org.webosinternals.mail-tls13` — mail transports on TLS 1.2/1.3 (**requires #1**; no
   reboot). **EAS, IMAP & SMTP all working & hardware-proven**; POP in
   testing. Details: [BUILDING.md](../BUILDING.md).
6. `org.webosinternals.mojomail-imap-tagfix` — **optional, standalone**: a one-byte
   `mojomail-imap` patch so strict IMAP servers (e.g. Fastmail) accept its command tags. Only
   needed for such servers; pairs with #5; reversible. Details:
   [mojomail-changes.md](../mojomail-changes.md).

Full details — requirements, what it does/doesn't do, verification, recovery, and how
it works — are in the [project README](../README.md). Building: [BUILDING.md](../BUILDING.md).
