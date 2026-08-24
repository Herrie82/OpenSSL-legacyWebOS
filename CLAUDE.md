# CLAUDE.md — working in this repo

Modern TLS 1.2/1.3 (OpenSSL 1.1.1w + curl 7.88.1) for the 2011 HP TouchPad
(webOS 3.0.5, stock OpenSSL 0.9.8). Four ipks put a process-private stack in
`/usr/lib/ssl11` and wire the browser, the apps, and the CLI into it. Full story:
[`README.md`](README.md). Build/maintainer details: [`BUILDING.md`](BUILDING.md).

## Status — PDK-launch fix (luna-tls13 1.1.2, `1b956ac`)
- **DONE, proven on hardware (one device).** The `setcpushares-pdk` env-scrub wrapper fixes PDK apps (QupZilla / the whole nizovn Qt5-glibc stack) dying instantly at launch under **LunaCE + luna-tls13 ≥ 1.1.0** (details in Key facts). Committed to `main` @ **`1b956ac`** — not pushed; the maintainer opens the PR.
- **Validated:** launch via `com.palm.applicationManager` (the Launcher-UI code path) runs stable; `tls13-diag.sh` PASS; media wrapper unaffected; postinst **refresh** path exercised on-device (upgrade over a hand-installed wrapper). The **fresh-wrap** postinst path (stock script → `.real`) has NOT yet run via the package on hardware — validate on the next clean 1.1.1→1.1.2 device.
## Status — App-Manager install fix (luna-tls13 1.1.3)
- **DONE, proven on hardware.** LunaSysMgr's App-Manager install/remove path (Preware `installSvc`/`replaceSvc`, WOSQI) died of the same env leak under LunaCE (`util_ipkgInstallDone … 127`), and because `com.palm.appinstaller` then drops its connection the caller's subscription never returns — so **Preware WEDGES** ("stuck IPKG lock"). Root cause pinned on hardware: LunaSysMgr runs the install as `setcpushares-task ApplicationInstallerUtility -c install …`; `setcpushares-task` is a `/bin/sh` script, the LunaCE install-child env is composed with `LD_PRELOAD=libpvrtc.so`, and our leaked `LD_BIND_NOW=1` forces eager binding of libpvrtc's undefined `NApp_*` → `/bin/sh` dies at exec (127). **Fix:** a static env-scrub wrapper AS `/usr/sbin/setcpushares-task` (stock script → `.real`) — the SAME shape as `setcpushares-pdk`, just a DIFFERENT cpu-shares helper (pdk = app launch, task = install). The earlier "can't be wrapped from outside" claim was WRONG — the wrappable choke point is `setcpushares-task`, not the transient `/bin/sh -c`. Validated on hardware: composed env `{LD_BIND_NOW=1, LD_PRELOAD=libpvrtc.so}` → wrapper → install runs to **SUCCESS**; upgrade path (1.1.2→1.1.3, launcher already patched), idempotent re-run, and prerm restore all pass. Wrapper block runs BEFORE the launcher "already patched" short-circuit so upgrades get it. Diagnose a wedge: the stuck proc is `luna-send … appinstaller/installNoVerify` blocked in `poll_schedule_timeout`; `grep util_ipkgInstallDone.*127 /var/log/messages`.
- **Restart caveat (cosmetic, one-time):** right after installing/upgrading to 1.1.3, the FIRST uninstall-from-launcher may leave a grayed-out `?` placeholder icon in the launcher until Luna is restarted. This is stale in-memory state in the still-running LunaSysMgr (its ApplicationManager/subscriptions were composed before the wrapper existed), NOT a bug in the remove path — a Luna restart clears it and subsequent uninstalls are clean. It's just the already-required "reboot after luna-tls13" step surfacing. Only investigate the remove-completion → launcher-refresh notification if a grayed `?` icon recurs on a fresh uninstall *after* a restart.

## Status — webOS 2.x phone PDK + install fix (luna-tls13 1.1.4)
- **DONE, proven on hardware (HP Pre 3, mantaray 2.2.4).** PDK ("Linux binary") apps would not start on a
  phone with the TLS stack installed, and App-Manager installs failed — **both the same launcher-env leak,
  through spawn paths that DIFFER from the tablet's.** Do not assume 3.0.5's helpers exist on 2.x.
- **PDK launch (the reported bug):** webOS 2.x has **no `setcpushares-pdk`**. LunaSysMgr launches PDK apps
  DIRECTLY as `/usr/bin/jailer -t pdk -i <appId> -p <appDir> <binary> <binary>`, and — this is the part that
  was assumed 3.x-only — **stock 2.2.4 sysmgr composes that child's env with `LD_PRELOAD=libpvrtc.so`**
  (overriding our preload and lib path, but passing `LD_BIND_NOW=1` through). Eager binding makes libpvrtc's
  undefined `NApp_*` fatal → **jailer** dies at exec (127) before the jail is built, so the app binary is never
  exec'd. `applicationManager/launch` still returns `{"returnValue":true,"processId":"n-…"}` and **nothing is
  logged** — the death is in the child. **Fix: a static `jailer` env-scrub wrapper** (`jailer-wrap.c`, stock →
  `/usr/bin/jailer.real`, backup `/var/luna/jailer.tls13-orig`), same shape as the 3.x wrappers.
- **App-Manager installs (found while validating):** the 2.x install path *does* use `setcpushares-task`, and
  its child env is composed the same way (`libpvrtc.so` + leaked `LD_BIND_NOW=1`) → `/bin/sh` dies at exec, so
  `installNoVerify` answers **`FAILED_IPKG_INSTALL`** (terminal, not the 3.0.5 wedge — appinstaller doesn't drop
  the connection here). **Fix: the EXISTING `setcpushares-task` wrapper, un-gated to both families.** Preware's
  default `installCli` path (ipkgservice, clean env) was never affected, which is why this hid behind a Preware
  that appeared to work.
- **Validated on hardware (Pre 3):** regression reproduced with stock helpers; fresh-wrap postinst (stock →
  `.real`) AND refresh path; PDK app launches with `LD_BIND_NOW` gone from its env; `installNoVerify` →
  **SUCCESS**; `tls13-diag.sh` **PASS** (TLS untouched); `pmPreRemove.script` restores both helpers
  bit-exact (stock jailer md5 `4ade5928178768c7ab5e87858a6436f1`) with no leftovers.
- **3.0.5 is behaviourally unchanged** — its postinst/prerm/payload are byte-identical to 1.1.3 apart from the
  version string and family-neutral message wording; only the fam gate on `setcpushares-task` moved.
- **Not committed/pushed — maintainer opens the PR.** Device left with 1.1.4 installed (reboot pending).
- **Media (1.1.1's bug) does NOT look reachable on 2.x — different spawn parent.** `/usr/bin/media-pipeline`
  exists on the Pre 3, but on webOS 2.2.4 it is spawned by **`/usr/bin/mediaserver`**, which is its OWN upstart
  job (`/etc/event.d/mediaserver`: `exec ionice -c1 /usr/bin/mediaserver --gst-debug=1`) — LunaSysMgr contains
  **zero** `media-pipeline`/`mediad` strings there, so the worker never inherits the launcher env that causes
  the tablet wedge. (On 3.0.5 it's WebAppMgr, a LunaSysMgr child, that fork+execs the worker — that's the
  exposure.) **Closed on hardware:** `mediaserver` runs with **`PPid=1`** (upstart, not LunaSysMgr) and **zero
  `LD_*` variables in its environ** — a child cannot inherit what its parent does not have, so the worker it
  spawns is structurally out of reach of our launcher exports. So 2.x correctly ships no media wrapper, and
  music plays fine on the Pre 3 with the full stack installed.

## Status — media fix (luna-tls13 1.1.1, `edbe184`)
- **DONE & fleet-validated.** The `media-pipeline` env-scrub wrapper (Key-facts bullet below; `media-player-gap-findings` memory) fixes media (Pandora/Plex/drPodder + stock Music) wedging after ~1 song under the TLS stack. Committed to `main` @ **`edbe184`** — **not pushed; the maintainer opens the PR** to Herrie82 (Claude does not push).
- **Validated A–E on hardware:** upgrades from 1.0.0 and 1.1.0, nizovn and no-nizovn, fresh full install, and a faithful Preware uninstall-to-stock (1.1.1 prerm reversibility). All webOS 3.0.5.
- **Hard prereq surfaced by the fresh-install test — `ntpdate-sync` (#4):** a freshly-doctored device boots with its clock in the *past*, so every modern cert reads "not yet valid" and the whole TLS stack *looks* broken (HTTPS dead everywhere, "cert not trusted") when it's actually fine. webOS's built-in NTP hits dead palm.com and fails, so the clock never self-corrects — ntpdate-sync is REQUIRED, not optional. (Same family as the CA-bundle gotcha below.)
- **Known limit:** the media worker streams HTTPS via `souphttpsrc`→`libsoup`→**gnutls** (never our OpenSSL), capped by the ~2011 stock gnutls (no TLS 1.3). A strictly-TLS-1.3-only media CDN would fail to *stream* — pre-existing, not the wrapper's doing; control-plane HTTPS (playlists/tokens in the app WebKit) already uses our modern TLS. Fix if ever needed: modernize gnutls/glib-networking for the worker.

## Status — Download Manager fix (`downloadmgr-tls13` 1.0.0, NEW package)
- **DONE, proven on hardware (one device).** The system **Download Manager** (`com.palm.downloadmanager` / `/usr/bin/LunaDownloadMgr`) now does modern TLS for BOTH downloads and uploads. `LunaDownloadMgr` does all HTTP(S) via **libcurl and links NO OpenSSL directly** (its only TLS-bearing `DT_NEEDED` is `libcurl.so.4`), so the TLS half of the fix is a pure **RPATH** (`/usr/lib/ssl11dl:/usr/lib/ssl11`, DT_RPATH so it covers libcurl's transitive libssl) onto a modern libcurl — **no code patch to the 2011 binary.** Reuses the **mail** libcurl 7.61.1 (OpenSSL 1.1.1w + c-ares, matching the DM's stock c-ares resolver) shipped into a package-private `/usr/lib/ssl11dl`. Depends on `browser-tls13` for `/usr/lib/ssl11` OpenSSL (postinst refuses if absent → can't brick downloads on wrong order; remove BEFORE browser-tls13). Backup `/var/luna/LunaDownloadMgr.tls13-orig`; postinst restarts the `LunaDownloadMgr` upstart job (no reboot).
- **CA gotcha (why the baked bundle is load-bearing):** the daemon hard-codes `CURLOPT_CAPATH=/var/ssl/trustedcerts`, a dir hashed by the device's **OpenSSL 0.9.8** whose subject hashes **OpenSSL 1.1 cannot find** (hash algo changed in 1.0.0) — so with TLS otherwise fine, modern certs read as *"unable to get local issuer certificate."* The mail libcurl is built `--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt`; OpenSSL 1.1 loads that bundle **in addition to** the unreadable CAPATH → validation succeeds with zero cert-related patching. (Same CA-bundle + clock prereqs as the rest of the suite: needs a current ca-certificates.crt + ntpdate-sync.)
- **Headers (the "cookieHeader can't send a JWT" ask):** downloads only expose `cookieHeader`→`CURLOPT_COOKIE` + hardcoded `Auth-Token:`/`Device-Id:` (gated on BOTH `authToken`+`deviceId`; parsed in `cbDownload`, applied in `download()`); `customHttpHeaders` is **upload-only** (`cbUpload`/`UploadTask::setHTTPHeaders`). Arbitrary request headers on **downloads** (Authorization/Bearer JWT, X-Auth-Token) are delivered via a documented **`cookieHeader` multi-line convention** — curl 7.61.1 sends the first line as `Cookie:` and every subsequent `\r\n`/`\n`-split line as a raw request header (lead with a newline for headers-only). Frozen behavior of the pinned `.so`; no binary patch. Helper + docs in [`downloadmgr-tls13/README.md`](downloadmgr-tls13/README.md).
- **Validated on hardware (topaz 3.0.5):** stock baseline fails modern HTTPS (`completionStatusCode -1`); after install, download of howsmyssl → `tls_version: TLS 1.3`, Let's Encrypt file → HTTP 200 validated, `cookieHeader` header-injection echoed back by postman-echo, multipart upload with `customHttpHeaders` → HTTP 200; full ipkg install(postinst)→remove(prerm restores stock, HTTP still works)→reinstall cycle clean. Build: `./build-ipks.sh downloadmgr` (needs `patchelf`, a stock `LunaDownloadMgr.bin` auto-fetched over novacom like `BrowserServer.bin`, and `curl-mail/`'s libcurl). Analysis binary in `analysis/device/LunaDownloadMgr` (gitignored, not stripped). **Not committed/pushed — maintainer opens the PR.**

## The packages (install order)
1. `browser-tls13` — RPATH'd `/usr/bin/BrowserServer` → stock browser on TLS 1.3. **Ships `/usr/lib/ssl11`; install first.**
2. `luna-tls13` — patches the `LunaSysMgr` upstart launcher → app WebKit (Mojo/Enyo XHR) on TLS 1.3, **+ the env-scrub wrappers that family's spawn paths need: webOS 3.0.5 gets `media-pipeline` (v1.1.1, media), `setcpushares-pdk` (v1.1.2, PDK launch) and `setcpushares-task` (v1.1.3, App-Manager installs); webOS 2.x gets `jailer` (v1.1.4, PDK launch — 2.x has no setcpushares-pdk) and `setcpushares-task` (v1.1.4, same install break)** (see Key facts). **Needs #1; reboot after.**
3. `curl-tls13` — modern `/usr/bin/curl11` + `/usr/bin/curl` (stock backed up).
4. `ntpdate-sync` — NTP clock sync.
- `downloadmgr-tls13` — RPATH'd `/usr/bin/LunaDownloadMgr` → Download Manager (downloads + uploads) on TLS 1.3; ships libcurl into `/usr/lib/ssl11dl`. **Needs `browser-tls13`; remove before it. No reboot.** (See Status section above.)

## Mail TLS — `mail-tls13` (5th package; **EAS + IMAP + SMTP all working & hardware-proven**, v1.3.2)
Goal: the stock Email app's native transports `mojomail-{eas,imap,pop,smtp}` reach modern
TLS so accounts like Zoho (`msync.zoho.com`, EAS), Fastmail (IMAP/SMTP), and Gmail sync again. Full
story in [`BUILDING.md`](BUILDING.md); deep notes in the `mail-eas-WORKING`,
`mail-imap-smtp-WORKING`, and `mail-gmail-ecdsa-leaf-bug` auto-memories.
**Proven on hardware (v1.3.2):** EAS (Zoho: Mail/Contacts/Calendar/Tasks, TLS 1.3, no proxy),
IMAP+SMTP (Fastmail, TLS 1.3), and Gmail IMAP/POP/SMTP (TLS 1.2, see the ECDSA bullet) all validate + sync.
- **Architecture:** `com.palm.app.email` is just UI → delegates to `palm://com.palm.eas/`
  etc. TLS happens in the native transports: **EAS via libcurl** (`libemail-common`'s
  `glibcurl`, multi interface; its `CurlSSLVerifier` adds a verify callback but sets NO CA
  path — it trusts **libcurl's built-in default bundle**), **IMAP/POP/SMTP via `libpalmsocket`**
  (direct OpenSSL, `SSLv23_method`; loads `/var/ssl/certs` + `set_default_verify_paths`).
  Launchers are the four D-Bus `*.service` files in `/usr/share/dbus-1/system-services/`;
  reload edits with **`ls-control scan-services`** (no UI bounce). Backups go in `/var/luna`.
- **Two dead ends proven on hardware** (don't repeat): (a) ssl11's libcurl 7.88.1 → SIGSEGV
  in `curl_multi_remove_handle`; (b) STOCK libcurl
  7.21.7 on ssl11 OpenSSL → TLS 1.3 ok then SIGSEGV inspecting the X509 cert.
- **CORRECTION (2026-08-21) to dead end (a):** the old explanation ("glibcurl was built for
  curl 7.21.7+c-ares, so pick a curl old enough") is **wrong**, and the 7.61.1 pin it
  produced does **not** avoid the crash — `downloadmgr-tls13` on 7.61.1 SIGSEGVs in the same
  function. Root cause is not curl-version skew at all: `LunaDownloadMgr` destroys and
  recreates its curl *multi* handle at runtime (`cbIdleSourceGlibcurlCleanup` →
  `shutdownGlibCurl`/`startupGlibCurl`) every time the transfer list empties, then touches
  the freed multi (`curl_multi_remove_handle` on a stale `multi->msglist.head`, FaultAddress
  `0xc8`). Controlled A/B on hardware: list allowed to empty = 58 restarts / **28 crashes per
  60** download cycles; one download held open (restart suppressed) = 0 restarts / **0
  crashes**. Fixed by a one-byte patch (`downloadmgr-tls13/patch-glibcurl-restart.py`) that
  makes the existing guard branch unconditional → 0 crashes, unchanged throughput/RSS/fds.
  **Audited the other consumers: `libemail-common` (mojomail) and `libWebKitLuna`
  (BrowserServer + app WebKit, on 7.88.1) are clean** — both read everything out of the
  `CURLMsg` *before* teardown and neither restarts its multi handle, so mail/browser need no
  equivalent fix. `libmasflib`, `mms-service`, `PmNetConfigManager` and `yahoo-service` also
  use glibcurl but are never moved off stock libcurl, so they are not exposed.
- **The working fix (EAS, v1.2.0):** ship into `/usr/lib/ssl11mail` (and point the four
  launchers there): (1) a purpose-built **libcurl 7.61.1** `--enable-ares`, compiled vs
  OpenSSL 1.1 headers, **and `--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt`** (libcurl
  ignores the `CURL_CA_BUNDLE` *env* — only the curl CLI reads it — so the bundle MUST be
  baked in or EAS certs read as untrusted); (2) mail's **OWN `libssl_compat.so`** (a real
  file, NOT a symlink to ssl11's) — a superset adding **`CONF_modules_free`** (libpalmsocket)
  and **`SSL_CTX_get_ex_new_index`** (libemail-common), both 1.1 macros that the 0.9.8-built
  mail libs import as functions; unresolved → `exit(127)` after `SSL_CTX_new`, before any
  ClientHello. So mail-tls13 is **self-contained for the shim and never requires re-issuing
  browser-tls13** (it still *depends* on browser-tls13 being installed for ssl11's OpenSSL).
- **IMAP/SMTP fixes, both NON-TLS — the TLS layer was already fine** (libpalmsocket's CA store
  = `/var/ssl/certs` + `set_default_verify_paths` honoring the launcher's `SSL_CERT_FILE`
  verifies modern certs fine):
  - **(a) `LD_BIND_NOW=1`** on all four launchers (in `mail-tls13` v1.3.x) — with lazy binding
    the transports intermittently SIGSEGV in the glibc-2.8 dynamic linker
    (`do_lookup_x`/`check_match`) while first-resolving a PLT symbol across the shim + 0.9.8→1.1
    aliased OpenSSL (hit on SMTP); eager binding fixes it. (A launch-env change, not a mojomail
    binary change.)
  - **(b) mojomail-imap 1-byte patch** `~A`→`AA` (0x7e→0x41 at file offset **991784**): mojomail
    hard-codes a `~`-leading IMAP tag (`ImapRequestManager: ss << "~A" << id`), which strict
    servers (Fastmail) reject with an UNTAGGED `* BAD` that mojomail can't match → 30s hang
    (err 3099). **Shipped as a SEPARATE, optional package `org.webosinternals.mojomail-imap-tagfix`**
    (split out of mail-tls13 so it's take-or-leave and won't collide with other mojomail
    patches — it modifies a stock binary). Its postinst md5-guards the stock binary
    (`9f6489…`→`78956f…`), patches a same-fs temp copy + `mv` (in-place `dd` fails ETXTBSY on
    the running binary), backs up to `/var/luna/mojomail-imap.tagfix-orig`; prerm restores. The
    one and only mojomail-binary change — see `mojomail-changes.md`.
- **Gmail / ECDSA-leaf fix (v1.3.2)** — `libpalmsocket` (0.9.8-built, on 1.1 via our shim)
  **mis-verifies ECDSA (P-256) LEAF certs**: it declares the leaf "self signed" (`X509_V_ERR=18`)
  at depth 0 and never links it → validation fails with **err 4010 "self signed certificate"**.
  **RSA leaves verify fine.** Google's `imap.`/`pop.gmail.com` serve ECDSA leaves by default, so
  Gmail IMAP/POP broke while Fastmail (RSA) worked — NOT the chain/root/store/clock (`curl11` on
  the same OpenSSL+bundle verifies Gmail every way). **Fix (config-only, KEEPS full validation):**
  ship `/usr/lib/ssl11mail/mailssl.cnf` and add `OPENSSL_CONF=…mailssl.cnf` to the **imap/pop/smtp**
  launchers (NOT `eas` — it verifies via libcurl/`CurlSSLVerifier`, no bug). The cnf's
  `[system_default]` sets `MaxProtocol=TLSv1.2` + `SignatureAlgorithms=RSA+SHA256:RSA+SHA384:RSA+SHA512`,
  forcing the server to pick an RSA cert. **Both settings needed:** under TLS 1.3 Google still
  serves ECDSA, and libpalmsocket overrides any `CipherString` (but honors `MaxProtocol` +
  `SignatureAlgorithms`). **Upgrade-safe:** the postinst injects `OPENSSL_CONF` in a step
  *independent* of the `grep -q ssl11mail … continue` idempotency check, so ≤1.3.1 launchers
  (already env-prefixed) still get it. Reproduce/diagnose pre-auth (no creds needed — cert check
  is at handshake) via `luna-send -i -n 2 palm://com.palm.imap/validateAccount '{"username":"u@gmail.com","password":"d","config":{"server":"imap.gmail.com","port":993,"encryption":"ssl"}}'`
  (`4010`=cert fail, `1000`/`3099`/`535`=cert passed→auth/protocol); per-depth trace with
  `PmLogCtl set libpalmsocket debug`. (**Gmail also needs a Google App Password** — separate.)
- **Build needs** `curl-mail/lib/.libs/libcurl.so.4.*` AND `libssl_compat.so` (build the shim
  from `openssl_compat_shim.c`); else mail is SKIPped/errors. Validate with `mail-tls13-diag.sh`.
- **Build host:** needs the PalmPDK ARM cross-gcc (`/opt/PalmPDK/arm-gcc`, gcc-4.3.3, i386 →
  **Linux box only**, not Apple Silicon). Device binaries for offline RE in `analysis/device/`
  (gitignored) — they're **not stripped**, so `objdump`/`nm` give named functions.

## Commands
- Build: `./build-ipks.sh` → `ipks/` (needs `patchelf`, **GNU ar**, and `BrowserServer.bin` — auto-fetched over novacom from a connected stock device).
- Build the **feed-safe phone set**: `./build-ipks.sh phone` → `ipks/phone/` (see the `phone` target below). Add package selectors as usual, e.g. `./build-ipks.sh phone browser downloadmgr`.
- Diagnose on device: push `tls13-diag.sh`, `sh tls13-diag.sh` → look at the `VERDICT` line.
- Rebuild ipks on the Mac without the build tree: the Python re-wrap pattern used in history (extract members, repack GNU ar) — but prefer `build-ipks.sh`.

## Device access (novacom)
- novacom is at `/usr/local/bin` (PalmSDK). Device id: `topaz-linux`. It's a **dev tablet — anything goes**.
- **GOTCHA:** `novacom -- run file:///bin/sh -c '...'` **splits args on whitespace** (mangles multi-word commands). Instead: `novacom put file:///tmp/x.sh < local.sh` then `novacom -- run file:///bin/sh /tmp/x.sh`. Single commands with args are fine: `novacom -- run file:///usr/bin/md5sum /usr/bin/BrowserServer`.
- novacomd survives a dead UI → **always recoverable** even if a patch wedges boot.

## The `phone` target — one package per name for all three phones (feed-safe)
- **Why it exists:** the per-device folders cannot be published in a feed together. All four builds
  share the same `Package` + `Version` + `Architecture`, which is exactly ipkg's dedupe key
  (`pkg_vec.c`, `pkg_vec_insert_merge`); feed parsing takes the `/* just overwrite the old one */`
  branch, across every configured feed at once (one hash table). Preware installs **by name** and lets
  ipkg pick the file — so a Pre 3 could be handed the topaz build, and `luna-tls13` has no md5 guard.
  Also ruled out: a subdir in `Filename` (`ipkg_download.c:118` builds the URL right, `:124` builds the
  local cache path wrong — ipkg's own source comments the bug), a per-board `Architecture:` (rejected
  unless every device's `ipkg.conf` declares it first), and `Provides:` (ipkg supports it; Preware's JS
  has zero references, so Preware reports an unmet dep).
- **What it emits:** `ipks/phone/org.webosinternals.<pkg>-phone_<ver>_armv7.ipk` for browser / luna /
  downloadmgr / mojomail-imap-tagfix. Each bundles every board's pieces (`BrowserServer.rpath.<board>`
  etc.) and the postinst resolves the board from `/etc/prefs/properties/machineName`, falling back to
  matching a known board name in `/etc/palm-build-info`, then `case`s to that board's binary + md5s +
  IMAP offset — reusing the existing `dev_*` registry tables, just at runtime instead of build time.
- **It is also the wrong-device guard these packages never had:** an unrecognised board, including a
  TouchPad, exits non-zero *before touching anything*. No feed metadata can do that (Preware's
  `DeviceCompatibility` filter is bypassable by a user pref).
- **Cheap:** the ssl11 OpenSSL/curl payload and mail libcurl are identical across boards; only the
  ~250KB/~480KB patched binaries and a few md5s differ. `luna-tls13`'s webOS-2.x build is
  byte-identical across all three phones; `mojomail-imap-tagfix` is postinst-only. Family total ~2.7MB.
- **Single-board targets are untouched.** `tgt_suffix`/`tgt_boards` return `""`/`"$dev"` for a real
  board, so `ipks/tablet/` keeps the historical flat payload filenames. A rebuild-and-compare of all
  four tablet ipks showed only the intended `BS_FILE=`/`DL_FILE=` indirection line.
- **`prebuilt_rpath()`** lets `phone` be rebuilt on a checkout with no stock Palm binaries
  (`devices/<board>/*.bin` is gitignored) by extracting the already-RPATH'd binary from the committed
  per-board ipk — verified bit-identical to all six shipped binaries. The stock md5 for the postinst's
  "non-stock backup" NOTE then comes from the registry instead of a live `md5sum`.
- **`mail-tls13` and `curl-tls13` now declare NO `Depends`.** `/usr/lib/ssl11` comes from a
  differently *named* package per family (`browser-tls13` vs `browser-tls13-phone`), and one `Depends`
  line cannot name both — declaring either makes the package uninstallable on the other family. Both
  postinsts already refuse (`exit 1`) without ssl11, and the feed's `tls-updates*` metas supply the
  install ORDER. (Same reasoning already applied to `ntpdate-sync`.)
- **Status:** hardware-verified on an **HP Pre 3**. Veer (broadway) and Pre 2 (roadrunner) are built
  and published but untested on hardware.

## The TouchPad Go (opal) — covered by the 3.0.5 tablet build, no packages of its own
- **A Doctor exists that brings every Go variant to webOS 3.0.5, so the Go takes the `topaz`
  packages.** The old `go` target and its `-3.0.4` packages, `ipks/opal/` and `devices/opal/` are
  GONE (unwound 2026-08-04). `ipks/topaz/` is now **`ipks/tablet/`** — same board-keyed build inputs
  (`./build-ipks.sh topaz`, `devices/topaz/`), a folder named for what it serves (both 3.0.5 tablets).
- **Hardware-proven on a doctored Go** (`opal`, `Nova-HP-Opal` build 1026, `PRODUCT_VERSION_STRING=HP
  webOS 3.0.5`): it runs topaz's RPATH'd `BrowserServer` `a56bf4fe…` and `LunaDownloadMgr`
  `de784d7f…`, and takes the IMAP tagfix. Its **stock** binaries are NOT the TouchPad's:
  BrowserServer `aae93132…` (vs `0786bdf6…` — same 252,564 bytes, 2.6 % different), LunaDownloadMgr
  `d9c59339…` (vs `587f1a9f…`), mojomail-imap `df8d18e4…` (vs `9f6489ae…`, `~A` at **991664** not
  991784, patched `d127895e…`).
- **So the install guard keys on `PRODUCT_VERSION_STRING`, NOT the stock md5** (md5 is a per-DEVICE
  fact; per-BUILD is what governs the vtable). Wrong version → `exit 1` before touching anything (a
  3.0.4 Go is told to doctor itself); unknown stock md5 on a matching version → NOTE, proceed;
  version unreadable → fall back to the md5 rule. `mojomail-imap-tagfix` matches the LIVE binary
  against `dev_imap_variants()` (a `stock:patched:offset` list per board), so one package covers both
  tablets — before this it silently no-op'd on a Go.
- **Don't "fix" a Go by re-adding a board-specific package** — that is exactly what was removed. The
  earlier print-dialog bug was 3.0.4-vs-3.0.5 vtable skew (`opal-touchpad-go-vtable-print-bug` memory),
  and doctoring to 3.0.5 is the fix.

## Committed-artifact drift — both resolved 2026-08-04 (keep the toolchain rule)
Both drifts found by the `phone` work are gone: all four `ipks/tablet/` ipks were rebuilt during the
opal unwind and now match what `build-ipks.sh` emits (only their postinsts/controls changed; every
payload byte-identical, verified by unpack-and-diff).
- **The toolchain rule still stands.** `luna-tls13` ships **457,924B** env-scrub wrappers, but the
  committed prebuilt `setcpushares-pdk-wrap.bin` is **382,496B**: a build on a host without
  `/opt/PalmPDK` silently substitutes the smaller prebuilt. **Don't rebuild luna without the
  toolchain** unless you mean to change that payload. This Linux box HAS `/opt/PalmPDK/arm-gcc`, and a
  rebuild here reproduced all three wrappers byte-for-byte (verified).

## Critical gotchas (these bit us repeatedly — heed them)
- **App-Manager installs (Preware / WebOS Quick Install) ≠ `ipkg install`.** They unpack into the offline-root `/media/cryptofs/apps` and run a top-level **`pmPostInstall.script`** ar member, NOT the Debian `postinst`. So every package ships BOTH (the Debian postinst/prerm AND pmPostInstall.script/pmPreRemove.script as ar members) and the scripts **self-default `IPKG_OFFLINE_ROOT=/media/cryptofs/apps`**.
- **NEVER put a file backup in `/etc/event.d/`.** Upstart runs *every* file there as a job → a stray launcher backup becomes a duplicate, crash-looping `LunaSysMgr` that wedges boot. Backups go in `/var/luna/`. (This caused two "brick" scares that were NOT the TLS stack.)
- **GNU ar is required to build.** The pm-script ar members have long names; BSD ar (stock macOS `/usr/bin/ar`) writes an incompatible format the device may not read. `brew install binutils` on macOS. `build-ipks.sh` aborts if GNU ar is missing.
- **`/usr/bin/curl` default CA path** doesn't exist on-device → the curl wrapper sets `CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt`. A **current CA bundle** (e.g. `com.palm.rootcertsupdate`) is required for cert validation everywhere.
- **`luna-tls13` requires `browser-tls13`'s `/usr/lib/ssl11`** (its postinst refuses to patch otherwise → can't brick on wrong order). On removal, take `luna-tls13` out **before** `browser-tls13`.
- **The LunaSysMgr launcher env leaks into EVERY child it spawns — budget a scrub for each spawn path when touching those exports.** `LD_PRELOAD`/`LD_LIBRARY_PATH`/`LD_BIND_NOW` in `/etc/event.d/LunaSysMgr` are inherited by media workers, PDK app launches, App-Manager `ipkg` children, and anything else LunaSysMgr fork+execs. Victims so far, ALL fixed with static env-scrub wrappers: media-pipeline (1.1.1), PDK apps on 3.0.5 via `setcpushares-pdk` (1.1.2), App-Manager installs/removes via `setcpushares-task` (1.1.3 on 3.0.5, 1.1.4 on 2.x), PDK apps on 2.x via `jailer` (1.1.4). Before adding/changing a launcher export, enumerate the children and decide per-path: needs it, tolerates it, or needs a scrub. **And enumerate them PER FAMILY** — the helper that owns a path on 3.0.5 may not exist on 2.x (no `setcpushares-pdk` there; `jailer` is the PDK path), so "3.x-only" is a claim to verify with a tracer, not to assume.
- **`LD_PRELOAD=libpvrtc.so` in a sysmgr-composed child env is NOT LunaCE-specific** — stock webOS 2.2.4 sysmgr does it too (traced on a Pre 3, for BOTH the `jailer` PDK launch and the `setcpushares-task` install spawn). Any leaked `LD_BIND_NOW=1` is therefore fatal on the phones as well. **Test the launcher-env matrix on LunaCE, not just stock Luna.** LunaCE's LunaSysMgr builds its *own* PDK child env (`LD_PRELOAD=libpvrtc.so`, app-dir `LD_LIBRARY_PATH`, Qt vars) while passing other vars through — `libpvrtc.so` has lazily-unresolved `NApp_*` symbols, so a passed-through `LD_BIND_NOW=1` kills `/bin/sh` at exec (exit 127) before any script runs. "Works on stock" says nothing about LunaCE. Also: the child env ≠ LunaSysMgr's `/proc/<pid>/environ` — LunaCE composes it at spawn time; to see the real child env, swap in a static tracer binary as the spawn target and dump argv/env.
- **Env-scrub wrappers MUST be static ELF binaries** (`media-pipeline-wrap.c`, `setcpushares-pdk-wrap.c`). A shell-script scrub cannot outrun an environment that kills `/bin/sh` itself, and ld.so consumes `LD_*` before any script line runs.
- **`childProcessDied ... status 32512` = exit 127 = death at exec/ld.so, before `main()`.** First suspects: inherited `LD_*` env (preload with unresolvable symbols + `LD_BIND_NOW`, missing preload dep), then bad interpreter/path. Reproduce with `env -i <suspect vars> /bin/sh -c 'echo ok'` on-device before theorizing.
- **A freshly rebuilt ipk is byte-different but content-identical** (tar member mtimes; back-to-back builds can even be byte-identical). Don't commit a rebuild artifact as if it were a change — unpack and diff contents (`ar x`, `tar xzf`, `diff -r`) when git flags an ipk you didn't mean to touch.
- **On-device debug quirks:** this TouchPad's `luna-send` needs `-i` (with `-n 1` it exits 0 printing *nothing* — looks like a dead bus when the bus is fine); jailed PDK processes don't show up in busybox `ps | grep` from a novacom shell — use `pidof` or `/proc/*/comm`.

## Key facts / values
- Stock `BrowserServer` md5 `0786bdf698220aa82a90838e30355c9f`; RPATH'd build `a56bf4febbb961ce5249ed78caa0bf33`.
- `libWebKitLuna` hardcodes `ssl->ctx`@`0xD8`, `X509_STORE_CTX->cert`@`0x8`; the bundled OpenSSL relocates those + `libssl_compat.so` bridges the rest.
- Recovery from a wedged UI: `mount -o remount,rw / ; cp /var/luna/LunaSysMgr.tls13-orig /etc/event.d/LunaSysMgr ; reboot` (over novacom).
- webos-mcp server has webOS platform knowledge (resources under `webos://knowledge/...`) — consult `tls-and-networking`, `system-internals`, `gotchas`.
- **HTML5 + local media (Pandora/Plex/drPodder + stock Music) needs the `media-pipeline` env-scrub wrapper** (`luna-tls13` ≥ v1.1.1). The `media-pipeline` worker that `WebAppMgr` **fork+execs** inherits the ssl11 env but **never needed OpenSSL** (local files don't touch it; http(s) streaming is `souphttpsrc`→`libsoup`→**gnutls**, not our OpenSSL). That inherited-but-unused stack **corrupts the worker's teardown → media WEDGES after ~1 song** (the next worker dies at init, play goes no-op until a Luna restart — hits Pandora/Plex/drPodder AND stock Music). **It is our stack, device-independent — NOT nizovn** (the identical wedge reproduces on a no-nizovn box). **The fix:** install a static ARM wrapper AS `/usr/bin/media-pipeline` that resets the env to stock (`LD_PRELOAD=libptmalloc3+libmemcpy` only — drops `libssl_compat`; unsets `LD_LIBRARY_PATH`/`LD_BIND_NOW`) and `execv`s the real binary, **moved to `/usr/bin/media-pipeline.real` with its own LS2 role** (`com.palm.mediad.pipeline.real.json`, `exeName=…/media-pipeline.real`) so it still registers `MediaPlayer_<pid>`. Two-layer history: **v1.1.0's `LD_BIND_NOW=1`** (still set on the launcher, for LunaSysMgr/WebAppMgr) fixed only a *first-layer* lazy-binding SIGSEGV in the glibc-2.8 linker (worker died before `gst_init`) — **necessary but NOT sufficient; it merely unmasked the teardown wedge.** The earlier "**no wrapper/env-scrub fix is possible**" claim was **WRONG** — it failed only because it never added the `.real` LS2 role. `luna-service2 transport.c:1895 Broken pipe` on teardown is a **red herring** (fires with a stock-env worker too). Proven NOT to be: gstreamer/TLS (gnutls, not OpenSSL), libcurl (worker links none), symbol collision, OpenSSL fork-safety (worker is fork+EXEC), or nizovn. postinst installs the wrapper independent of the launcher patch (so 1.0.0/1.1.0 boxes get it on upgrade), keyed on the `.real` file (grep-on-binary isn't portable); prerm restores. **Proven on D (controlled nizovn: clean 1.1.0→1.1.1 upgrade, worker `ssl11=0`) and C (real-world nizovn daily driver: 4 workers incl. cross-app, no wedge).** Debug the real worker's gst via `GST_DEBUG`/`GST_DEBUG_FILE` in the launcher env (not a wrapper), reboot, read the trace.

- **PDK apps (QupZilla / nizovn Qt5 stack) need the `setcpushares-pdk` env-scrub wrapper** (`luna-tls13` ≥ v1.1.2). Every PDK app is spawned by LunaSysMgr through `/usr/sbin/setcpushares-pdk` (a `/bin/sh` script) and inherits the ssl11 launcher env. Under **LunaCE** the leaked `LD_BIND_NOW=1` is fatal — LunaCE's PDK child env preloads `libpvrtc.so`, whose lazily-unresolved `NApp_*` symbols become eager-bind errors, so `/bin/sh` dies at exec (`childProcessDied ... 32512` = exit 127, ~20 ms) and the app never exists. Under **stock Luna** the leaked `libssl_compat.so` preload crashes nizovn-glibc apps instead (reproduced). Any *two* of {nizovn stack, LunaCE, luna-tls13 ≥ 1.1.0} coexist; all three = every PDK launch dead. **The fix:** a static ARM wrapper installed AS `setcpushares-pdk` (stock script → `.real`, backup `/var/luna/setcpushares-pdk.tls13-orig`) that strips ONLY the tls13 additions — `LD_BIND_NOW`, the `libssl_compat` `LD_PRELOAD` entry, the `/usr/lib/ssl11` lib-path entry — preserving the rest of whatever child env the (stock or LunaCE) sysmgr composed, then execs `.real`. Source `setcpushares-pdk-wrap.c` + committed prebuilt `.bin` (build uses PalmPDK gcc when present, else the prebuilt). No LS2 role needed (unlike media-pipeline — setcpushares-pdk never registers on the bus). postinst installs it independent of the launcher patch (keyed on the `.real` file, refuses a shebang-less target with no `.real`); prerm restores.

- **App-Manager installs/removes (Preware `installSvc`/`replaceSvc`, WOSQI) need the `setcpushares-task` env-scrub wrapper** (`luna-tls13` ≥ v1.1.3). LunaSysMgr's `com.palm.appinstaller` runs the installer as `/usr/sbin/setcpushares-task /usr/bin/ApplicationInstallerUtility -c install -p <ipk> …` — `setcpushares-task` is a **DIFFERENT** `/bin/sh` cpu-shares helper than `setcpushares-pdk` (pdk = PDK app launch, task = install/task spawns). Under **LunaCE** the install-child env is composed with `LD_PRELOAD=libpvrtc.so` and inherits our leaked `LD_BIND_NOW=1` → `/bin/sh` dies at exec (`util_ipkgInstallDone … 127` / status 32512) BEFORE the installer runs → install FAILS, `com.palm.appinstaller` drops the connection, and the caller's subscription never returns → **Preware wedges** (its `luna-send … appinstaller/installNoVerify` blocks in `poll_schedule_timeout`; NOT a stale lock *file* — none is left). Note Preware's default `installCli` path (ipkgservice runs `ipkg` in its own **hub-launched, clean** env) is unaffected — only the `installSvc`/App-Manager path leaks. **The fix:** static ARM wrapper AS `setcpushares-task` (stock script → `.real`, backup `/var/luna/setcpushares-task.tls13-orig`) that strips the tls13 additions (`LD_BIND_NOW` is the killer; also the `libssl_compat` preload + `/usr/lib/ssl11` lib-path entries) and execs `.real` — the scrubbed env propagates to the whole install subtree (AIU → ipkg → postinst `sh`). Source `setcpushares-task-wrap.c` + committed prebuilt `.bin`; postinst installs it before the launcher-patch short-circuit (so upgrades get it), prerm restores. Reproduce/diagnose via a direct `luna-send -n 8 luna://com.palm.appinstaller/installNoVerify '{"target":"/media/internal/.developer/<x>.ipk","subscribe":true}'` (appinstaller `inbound:*`, so callable from novacom) and watch `util_ipkgInstallDone` — 32512=broken, status 0=fixed.

## Git
- `origin` = `webOSArchive/OpenSSL-legacyWebOS` (the ONLY remote configured — there is no `upstream` remote; add one
  if you need to fetch from Herrie82 directly). Team works on `main` (no feature branches).
- **The maintainer opens the PR, and Claude does not push unless explicitly asked.** Upstream is Herrie82:
  `gh pr create --repo Herrie82/OpenSSL-legacyWebOS --base main --head webOSArchive:main` — note `gh` is NOT
  installed on this Linux box, so that runs from wherever the maintainer has it.
- `BrowserServer.bin` and `ipks-backup/` are gitignored (build artifact / local backup).
