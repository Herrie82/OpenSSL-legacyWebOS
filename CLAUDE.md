# CLAUDE.md — working in this repo

Modern TLS 1.2/1.3 (OpenSSL 1.1.1w + curl 7.88.1) for the 2011 HP TouchPad
(webOS 3.0.5, stock OpenSSL 0.9.8). Four ipks put a process-private stack in
`/usr/lib/ssl11` and wire the browser, the apps, and the CLI into it. Full story:
[`README.md`](README.md). Build/maintainer details: [`BUILDING.md`](BUILDING.md).

## Status — PDK-launch fix (luna-tls13 1.1.2, `1b956ac`)
- **DONE, proven on hardware (one device).** The `setcpushares-pdk` env-scrub wrapper fixes PDK apps (QupZilla / the whole nizovn Qt5-glibc stack) dying instantly at launch under **LunaCE + luna-tls13 ≥ 1.1.0** (details in Key facts). Committed to `main` @ **`1b956ac`** — not pushed; the maintainer opens the PR.
- **Validated:** launch via `com.palm.applicationManager` (the Launcher-UI code path) runs stable; `tls13-diag.sh` PASS; media wrapper unaffected; postinst **refresh** path exercised on-device (upgrade over a hand-installed wrapper). The **fresh-wrap** postinst path (stock script → `.real`) has NOT yet run via the package on hardware — validate on the next clean 1.1.1→1.1.2 device.
- **Known residual (OPEN):** LunaSysMgr's own App-Manager install path (`palm-install`/WOSQI) dies of the same env leak under LunaCE (`util_ipkgInstallDone ... 127`) and can't be wrapped from outside. Workaround: **Preware** (its ipkgservice doesn't run under LunaSysMgr's env) or over novacom: `ipkg -o /media/cryptofs/apps install <ipk>` + run the ipk's `pmPostInstall.script` with `IPKG_OFFLINE_ROOT=/media/cryptofs/apps`. A real fix means LunaCE sanitizing its child env (report upstream) or a shim-constructor unsetenv trick (unproven — changes dlopen-time binding semantics, treat as risky).

## Status — media fix (luna-tls13 1.1.1, `edbe184`)
- **DONE & fleet-validated.** The `media-pipeline` env-scrub wrapper (Key-facts bullet below; `media-player-gap-findings` memory) fixes media (Pandora/Plex/drPodder + stock Music) wedging after ~1 song under the TLS stack. Committed to `main` @ **`edbe184`** — **not pushed; the maintainer opens the PR** to Herrie82 (Claude does not push).
- **Validated A–E on hardware:** upgrades from 1.0.0 and 1.1.0, nizovn and no-nizovn, fresh full install, and a faithful Preware uninstall-to-stock (1.1.1 prerm reversibility). All webOS 3.0.5.
- **Hard prereq surfaced by the fresh-install test — `ntpdate-sync` (#4):** a freshly-doctored device boots with its clock in the *past*, so every modern cert reads "not yet valid" and the whole TLS stack *looks* broken (HTTPS dead everywhere, "cert not trusted") when it's actually fine. webOS's built-in NTP hits dead palm.com and fails, so the clock never self-corrects — ntpdate-sync is REQUIRED, not optional. (Same family as the CA-bundle gotcha below.)
- **Known limit:** the media worker streams HTTPS via `souphttpsrc`→`libsoup`→**gnutls** (never our OpenSSL), capped by the ~2011 stock gnutls (no TLS 1.3). A strictly-TLS-1.3-only media CDN would fail to *stream* — pre-existing, not the wrapper's doing; control-plane HTTPS (playlists/tokens in the app WebKit) already uses our modern TLS. Fix if ever needed: modernize gnutls/glib-networking for the worker.

## The four packages (install order)
1. `browser-tls13` — RPATH'd `/usr/bin/BrowserServer` → stock browser on TLS 1.3. **Ships `/usr/lib/ssl11`; install first.**
2. `luna-tls13` — patches the `LunaSysMgr` upstart launcher → app WebKit (Mojo/Enyo XHR) on TLS 1.3, **+ a `media-pipeline` env-scrub wrapper (v1.1.1) so HTML5 *and* local media play reliably, + a `setcpushares-pdk` env-scrub wrapper (v1.1.2) so PDK apps launch** (see Key facts). **Needs #1; reboot after.**
3. `curl-tls13` — modern `/usr/bin/curl11` + `/usr/bin/curl` (stock backed up).
4. `ntpdate-sync` — NTP clock sync.

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
  in `curl_multi_remove_handle` (glibcurl was built for curl 7.21.7+c-ares); (b) STOCK libcurl
  7.21.7 on ssl11 OpenSSL → TLS 1.3 ok then SIGSEGV inspecting the X509 cert.
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
- Diagnose on device: push `tls13-diag.sh`, `sh tls13-diag.sh` → look at the `VERDICT` line.
- Rebuild ipks on the Mac without the build tree: the Python re-wrap pattern used in history (extract members, repack GNU ar) — but prefer `build-ipks.sh`.

## Device access (novacom)
- novacom is at `/usr/local/bin` (PalmSDK). Device id: `topaz-linux`. It's a **dev tablet — anything goes**.
- **GOTCHA:** `novacom -- run file:///bin/sh -c '...'` **splits args on whitespace** (mangles multi-word commands). Instead: `novacom put file:///tmp/x.sh < local.sh` then `novacom -- run file:///bin/sh /tmp/x.sh`. Single commands with args are fine: `novacom -- run file:///usr/bin/md5sum /usr/bin/BrowserServer`.
- novacomd survives a dead UI → **always recoverable** even if a patch wedges boot.

## Critical gotchas (these bit us repeatedly — heed them)
- **App-Manager installs (Preware / WebOS Quick Install) ≠ `ipkg install`.** They unpack into the offline-root `/media/cryptofs/apps` and run a top-level **`pmPostInstall.script`** ar member, NOT the Debian `postinst`. So every package ships BOTH (the Debian postinst/prerm AND pmPostInstall.script/pmPreRemove.script as ar members) and the scripts **self-default `IPKG_OFFLINE_ROOT=/media/cryptofs/apps`**.
- **NEVER put a file backup in `/etc/event.d/`.** Upstart runs *every* file there as a job → a stray launcher backup becomes a duplicate, crash-looping `LunaSysMgr` that wedges boot. Backups go in `/var/luna/`. (This caused two "brick" scares that were NOT the TLS stack.)
- **GNU ar is required to build.** The pm-script ar members have long names; BSD ar (stock macOS `/usr/bin/ar`) writes an incompatible format the device may not read. `brew install binutils` on macOS. `build-ipks.sh` aborts if GNU ar is missing.
- **`/usr/bin/curl` default CA path** doesn't exist on-device → the curl wrapper sets `CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt`. A **current CA bundle** (e.g. `com.palm.rootcertsupdate`) is required for cert validation everywhere.
- **`luna-tls13` requires `browser-tls13`'s `/usr/lib/ssl11`** (its postinst refuses to patch otherwise → can't brick on wrong order). On removal, take `luna-tls13` out **before** `browser-tls13`.
- **The LunaSysMgr launcher env leaks into EVERY child it spawns — budget a scrub for each spawn path when touching those exports.** `LD_PRELOAD`/`LD_LIBRARY_PATH`/`LD_BIND_NOW` in `/etc/event.d/LunaSysMgr` are inherited by media workers, PDK app launches, App-Manager `ipkg` children, and anything else LunaSysMgr fork+execs. Three victims so far: media-pipeline (fixed 1.1.1), PDK apps via setcpushares-pdk (fixed 1.1.2), App-Manager installs (OPEN — see Status). Before adding/changing a launcher export, enumerate the children and decide per-path: needs it, tolerates it, or needs a scrub.
- **Test the launcher-env matrix on LunaCE, not just stock Luna.** LunaCE's LunaSysMgr builds its *own* PDK child env (`LD_PRELOAD=libpvrtc.so`, app-dir `LD_LIBRARY_PATH`, Qt vars) while passing other vars through — `libpvrtc.so` has lazily-unresolved `NApp_*` symbols, so a passed-through `LD_BIND_NOW=1` kills `/bin/sh` at exec (exit 127) before any script runs. "Works on stock" says nothing about LunaCE. Also: the child env ≠ LunaSysMgr's `/proc/<pid>/environ` — LunaCE composes it at spawn time; to see the real child env, swap in a static tracer binary as the spawn target and dump argv/env.
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

## Git
- `origin` = the fork (codepoet80), `upstream` = Herrie82. Team works on `main` (no feature branches). PR: `gh pr create --repo Herrie82/OpenSSL-legacyWebOS --base main --head codepoet80:main`.
- `BrowserServer.bin` and `ipks-backup/` are gitignored (build artifact / local backup).
