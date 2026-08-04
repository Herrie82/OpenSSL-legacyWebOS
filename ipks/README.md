# Modern TLS ipks — install order

## Which files to grab (per device)

Device-**specific** packages ship a patched stock binary and live in a per-device folder;
device-**independent** packages are shared and live here at the top level. Install the
matching device folder **plus** the three shared packages:

| Device | codename | device-specific folder | + shared (this dir) |
|--------|----------|------------------------|---------------------|
| HP TouchPad (webOS 3.0.5) | topaz | [`topaz/`](topaz/) | `curl-tls13`, `ntpdate-sync`, `mail-tls13` |
| HP TouchPad Go (webOS 3.0.4 **only**) | opal | [`opal/`](opal/) — `*-go` names | `curl-tls13`, `ntpdate-sync`, `mail-tls13` |
| HP Pre 3 (webOS 2.2.4) | mantaray | [`mantaray/`](mantaray/) | `curl-tls13`, `ntpdate-sync`, `mail-tls13` |
| Palm Pre 2 (webOS 2.2.4) | roadrunner | [`roadrunner/`](roadrunner/) | `curl-tls13`, `ntpdate-sync`, `mail-tls13` |
| HP Veer (webOS 2.2.4) | broadway | [`broadway/`](broadway/) | `curl-tls13`, `ntpdate-sync`, `mail-tls13` |
| **all three phones in one set** | — | [`phone/`](phone/) | `curl-tls13`, `ntpdate-sync`, `mail-tls13` |

Each device folder holds `browser-tls13`, `luna-tls13`, `downloadmgr-tls13`, and
`mojomail-imap-tagfix` built for that exact device. The shared `curl`/`ntp`/`mail`
packages are identical across devices. (A new device builds the same way — drop its stock
binaries in `devices/<codename>/` and run `./build-ipks.sh <codename>`.)

> **TouchPad owners — match the webOS BUILD, not the board.** 3.0.5 inserts five
> `Palm::WebViewClient` sensor virtuals into the *middle* of the `BrowserPage` vtable (125
> slots on 3.0.4 vs 130 on 3.0.5), and `libWebKitLuna.so` calls that vtable **by index**, so
> every slot from 36 up shifts by five — 3.0.4's slot 43 `setCanBlitOnScroll(bool)` (called
> on every page layout) trades places with 3.0.5's `showPrintDialog()`, and **the print
> dialog opens every time you navigate**.
>
> The TouchPad Go (`opal`) shipped at **both 3.0.4 and 3.0.5** depending on its cellular
> modem, so the board name doesn't tell you which you have. [`opal/`](opal/)'s `-go`
> packages are **3.0.4 only**. Every device-specific package verifies your device's own
> stock binary by md5 and **refuses before touching anything** if it's the wrong build — so
> a wrong pick is declined, not silently broken. A **3.0.5 Go** needs its own build — don't
> substitute [`topaz/`](topaz/). The vtable *layout* follows the webOS build, but the binary
> is still per-board (the Pre 2 and Pre 3 are both 2.2.4 with the same 101-slot vtable, yet
> their stock `BrowserServer`s differ in ~115 KB of 239 KB). `topaz/` will refuse on a 3.0.5
> Go, and its message reports the md5 we'd need to add a second `opal` entry.

## `phone/` — one set of packages for all three phones (use this for a FEED)

The per-device folders above are for hand-installing on a known device. They **cannot** be published
in a Preware/ipkg feed together, because all four builds share the same `Package` **and** `Version`
**and** `Architecture`: ipkg's dedupe key is exactly that triple (`pkg_vec.c`,
`pkg_vec_insert_merge`) and for feed parsing it "just overwrite[s] the old one", across every
configured feed at once (one hash table). Preware then installs **by name** and lets ipkg pick the
file — so a Pre 3 could be handed the topaz build, and `luna-tls13` (which edits
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

Because the names differ from the topaz ones, both families can live in a single feed — which is how
`webOSArchive/preware-modernize-feed` ships them, one URL for every device.

## `opal/` — the TouchPad Go (`*-go` names)

Same reasoning, one board — but note it covers **webOS 3.0.4 Gos only**; `opal` also shipped at
3.0.5. `./build-ipks.sh go` emits `org.webosinternals.browser-tls13-go`,
`…luna-tls13-go`, `…downloadmgr-tls13-go` and `…mojomail-imap-tagfix-go` into [`opal/`](opal/).
The distinct name is the point: `opal` and `topaz` packages would otherwise collide on that same
`Package`+`Version`+`Architecture` key, and a Go could be handed the topaz build — which is
exactly how the print-on-navigate bug above happened. Reusing the `phone` target's suffix
machinery also gives these packages the same `machineName` guard, so a `-go` package
**exits non-zero on any board but `opal`**, and a TouchPad cannot install it.

Note the deliberate split: the *folder* is the board codename (`opal`, matching `devices/opal/`),
while the *package suffix* is the friendlier `-go`. `opal` is a registered board but is **not** in
`ALL_DEVICES`, so a bare `./build-ipks.sh` can never emit an unsuffixed `opal` ipk that would
re-create the collision.

Unlike the other devices, the Go's stock binaries **are** committed in `devices/opal/`. They have
to be: the `novacom` auto-fetch returns the *patched* binary on any Go that already has these
packages installed (the md5 guard then rejects it), and `prebuilt_rpath()` only looks in the
unsuffixed `ipks/<board>/` dir that the `go` target never creates. So `./build-ipks.sh go` works
on a fresh checkout with no device attached.

**Building `phone/` without the stock Palm binaries:** the phones' and topaz's
`devices/<board>/*.bin` are gitignored, so a fresh checkout has none of them (the Go's are the
one exception — see [`opal/`](#opal--the-touchpad-go--go-names) for why). `prebuilt_rpath()` falls back to extracting the already-RPATH'd binary from
the committed per-board ipk in `ipks/<board>/`, which is bit-identical to what was built and tested
there (only the stock md5 for the postinst's "non-stock backup" NOTE then comes from the registry
instead of a live `md5sum`). So `./build-ipks.sh phone` works anywhere; you still need GNU `ar`.

## Install order

Install via **Preware** / **WebOS Quick Install** / `ipkg install`, in this order:

(On the phone set, append `-phone` to each device-specific package name below —
`org.webosinternals.browser-tls13-phone` and so on. On a TouchPad Go, append `-go`.
`curl`/`ntp`/`mail` are unchanged.)

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
