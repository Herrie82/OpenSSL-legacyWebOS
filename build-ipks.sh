#!/bin/bash
# Build the webOS ipks in the webos-internals App-Manager convention so they
# install via Preware / App Catalog / WebOS Quick Install (which extract under
# /media/cryptofs/apps and run pmPostInstall.script from there) -- as well as via
# plain `ipkg install`.
#
#   org.webosinternals.browser-tls13  -- modern TLS for the stock browser
#   org.webosinternals.ntpdate-sync   -- clock sync (dead palm.com NTP replacement)
#   org.webosinternals.curl-tls13     -- modern command-line curl (/usr/bin/curl11)
#
# Layout (self-contained app -- the correct webOS convention; cf. com.palm.rootcertsupdate):
#   ar order: debian-binary, data.tar.gz, control.tar.gz, pmPostInstall.script, pmPreRemove.script
#   data ships everything under ./usr/palm/applications/<id>/ (appinfo.json + files/<payload>);
#   the postinst / pmPostInstall.script relocates files/ into the live system.
#
# Install fixes layered on the app layout:
#   * robust ONE-TIME BrowserServer backup -- works on any pre-existing binary, and
#     never saves our own RPATH'd build as if it were stock (so it stays uninstallable);
#   * teardown that won't brick the browser when no stock backup exists.
set -euo pipefail

# Resolve BASE to this script's own directory (the repo checkout), so the build
# works wherever it's cloned -- inputs (openssl-1.1.1w/, curl-7.88.1/, libssl_compat.so,
# ntpdate-sync, BrowserServer.bin) and the ipks/ output are relative to it.
BASE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
OUT="$BASE/ipks"; ARCH="armv7"

# Optional package selection: ./build-ipks.sh [browser|ntp|curl|luna|mail|downloadmgr|all ...]
# No args -> "all" (back-compat). 'want <pkg>' gates each section, so e.g. the mail
# package can be (re)built on a box without a clean stock device / BrowserServer.bin
# while iterating its libcurl (see BUILDING.md). 'all' also gates the blanket
# ipk clean below so a selective rebuild won't wipe the other packages' ipks.
# --- device registry + arg parsing -------------------------------------------
# One repo builds per-device variants side by side. Device-SPECIFIC packages
# (browser-tls13, and later downloadmgr-tls13) ship a patched stock binary and go to
# ipks/<device>/; device-INDEPENDENT packages (curl-tls13, ntpdate-sync) build once
# into ipks/. Each device's stock binaries live under devices/<device>/ :
#   devices/<device>/BrowserServer.bin     (stock /usr/bin/BrowserServer to RPATH)
#   devices/<device>/LunaDownloadMgr.bin   (stock /usr/bin/LunaDownloadMgr, phase 3)
# (legacy top-level BrowserServer.bin is still honored as topaz's, for back-compat.)
# webOS device codenames (from palm-build-info BUILDNAME):
#   topaz=TouchPad(3.0.5)  mantaray=Pre 3(2.2.4)  roadrunner=Pre 2(2.2.4)  broadway=Veer(2.2.4)
ALL_DEVICES="topaz mantaray roadrunner broadway"
# --- the 'phone' MULTI-BOARD target -------------------------------------------
# A package manager cannot tell four ipks apart when they share Package + Version +
# Architecture: ipkg's dedupe key is exactly that triple (pkg_vec.c, pkg_vec_insert_merge)
# and for feed parsing it "just overwrite[s] the old one", across ALL configured feeds
# (one hash table). Preware then installs BY NAME and lets ipkg choose the file -- so
# per-board ipks that share a name can never coexist in any feed layout: a Pre 3 could
# be handed the topaz build. (Same reason a subdir in Filename fails -- ipkg_download.c
# builds the URL right and the local cache path wrong -- and a per-board Architecture
# would have to be declared in every device's ipkg.conf first.)
#
# So the phones ship as ONE package per name, holding every board's pieces and choosing
# at install time from /etc/prefs/properties/machineName -- the same file Preware's own
# ipkgservice reads for getMachineName (preware/source/src/luna_methods.c). This is cheap
# because the per-board part is tiny: the ssl11 OpenSSL/curl payload (3.9MB) and the mail
# libcurl are identical across boards, only the ~250KB patched BrowserServer /
# ~480KB LunaDownloadMgr and a few md5s/offsets differ; luna-tls13's webOS-2.x build has
# no payload at all and mojomail-imap-tagfix is postinst-only.
#
# It also gives these packages a HARD wrong-device guard they never had: an unrecognised
# machineName (e.g. a TouchPad) exits non-zero before touching anything, which no amount
# of feed metadata can do (Preware's DeviceCompatibility filter is bypassable by a pref).
#
# Build with:  ./build-ipks.sh phone            (or 'phone browser', etc.)
# Output:      ipks/phone/org.webosinternals.<pkg>-phone_<ver>_armv7.ipk
# The per-board topaz/mantaray/... builds are left exactly as they were, so the deployed
# TouchPad packages are untouched and byte-identical.
PHONE_BOARDS="mantaray broadway roadrunner"
PHONE_TARGET="phone"
# Package-name suffix + the boards a target bundles. Single-board targets keep the
# historical flat payload filenames so their ipks stay byte-identical to before.
tgt_suffix() { case "$1" in "$PHONE_TARGET") echo "-phone";; *) echo "";; esac; }
tgt_boards() { case "$1" in "$PHONE_TARGET") echo "$PHONE_BOARDS";; *) echo "$1";; esac; }
dev_product() { case "$1" in
  topaz)      echo "HP TouchPad (webOS 3.0.5)";;
  mantaray)   echo "HP Pre 3 (webOS 2.2.4)";;
  roadrunner) echo "Palm Pre 2 (webOS 2.2.4)";;
  broadway)   echo "HP Veer (webOS 2.2.4)";;
  phone)      echo "webOS 2.2.4 phones (HP Pre 3 / HP Veer / Palm Pre 2)";;
  *)          echo "webOS device ($1)";;
esac; }
# Expected STOCK BrowserServer md5 -- used ONLY to verify a novacom AUTO-FETCH grabbed
# a clean/unpatched binary. Empty => skip that guard (trust a supplied .bin).
dev_bs_md5() { case "$1" in
  topaz)      echo "0786bdf698220aa82a90838e30355c9f";;   # TouchPad
  mantaray)   echo "44d2b0ce0fa4f1e0c660039676df5e36";;   # Pre 3
  roadrunner) echo "d7dcd8a05995859c36cf8e9db3c13b25";;   # Pre 2
  broadway)   echo "6b3eddf2581ed869beedba253bb35227";;   # Veer
  *)          echo "";;
esac; }
dev_novacom() { case "$1" in   # novacom -l device-id token, for auto-fetch matching
  topaz)      echo "topaz";;
  mantaray)   echo "mantaray";;
  broadway)   echo "broadway";;
  roadrunner) echo "roadrunner";;
  *)          echo "$1";;
esac; }
# webOS major family. Gates luna-tls13's env-scrub wrappers: 3.0.5 (LunaCE) needs the
# media-pipeline / setcpushares-pdk / setcpushares-task wrappers; webOS 2.x does not
# (no LunaCE; setcpushares-pdk doesn't even exist) -> 2.x gets a clean launcher-only luna.
dev_webos() { case "$1" in
  topaz)      echo "3";;
  mantaray|broadway|roadrunner) echo "2";;
  phone)      echo "2";;   # every board in the phone bundle is webOS 2.x
  *)          echo "2";;
esac; }
# Emit the shell that resolves the running board into $BOARD, for the postinst of a
# multi-board package. Primary source is machineName (what Preware's ipkgservice reads,
# and proven to return e.g. "roadrunner" on a Pre 2); /etc/palm-build-info is a fallback,
# matched only against the known board names so it cannot land on the wrong one.
emit_board_detect() { cat <<'EOF'
BOARD=""
if [ -r /etc/prefs/properties/machineName ]; then
    BOARD=$(cat /etc/prefs/properties/machineName 2>/dev/null | tr -d ' \t\r\n')
fi
if [ -z "$BOARD" ] && [ -r /etc/palm-build-info ]; then
    for k in mantaray broadway roadrunner topaz; do
        if grep -qi "$k" /etc/palm-build-info 2>/dev/null; then BOARD="$k"; break; fi
    done
fi
EOF
}
# Expected stock LunaDownloadMgr md5 (downloadmgr-tls13) -- verify auto-fetch only; empty=>skip.
dev_dlmgr_md5() { case "$1" in
  topaz)      echo "587f1a9f51c3e6e1c905e44e55ea6193";;   # TouchPad
  mantaray)   echo "44035016e79c7787017c7e218aef00cc";;   # Pre 3
  roadrunner) echo "444b88f2b2a01278692de74848af5b92";;   # Pre 2
  broadway)   echo "549fa933af41e043257ef8f2fbc655b7";;   # Veer
  *)          echo "";;
esac; }
# mojomail-imap-tagfix: stock md5 / patched md5 / file offset of the "~A"->"AA" tag byte.
# All three are per-build (offset moves between webOS builds). Empty stock md5 => device
# skipped (unknown offset). Recompute for a new device: find the single "~A", flip 0x7e->0x41.
dev_imap_stock_md5()   { case "$1" in
  topaz)      echo "9f6489ae48fc131733c1a88a9aa1056a";;   # TouchPad
  mantaray)   echo "291dbc5f6cc52392e4d653d39e528226";;   # Pre 3
  roadrunner) echo "b38230f8a0bc26c932caf7050fb93297";;   # Pre 2
  broadway)   echo "b308c86c598d66d39403bca73edfb366";;   # Veer
  *)          echo "";;
esac; }
dev_imap_patched_md5() { case "$1" in
  topaz)      echo "78956f6daf374a9a940e914459f234c3";;   # TouchPad
  mantaray)   echo "9cf606e11683d35b8f8da2145a23afc6";;   # Pre 3
  roadrunner) echo "3d614527bcaada9820e753b5eb600a17";;   # Pre 2
  broadway)   echo "00a991bbe527ff9e8d45fb0bfefd90f4";;   # Veer
  *)          echo "";;
esac; }
dev_imap_offset()      { case "$1" in
  topaz)      echo "991784";;   # TouchPad
  mantaray)   echo "988724";;   # Pre 3
  roadrunner) echo "988740";;   # Pre 2
  broadway)   echo "988620";;   # Veer
  *)          echo "";;
esac; }
is_device() { case " $ALL_DEVICES $PHONE_TARGET " in *" $1 "*) return 0;; *) return 1;; esac; }

# downloadmgr_for <dev>: echo a verified stock LunaDownloadMgr path (stderr progress), or
# non-zero if none. Prefers devices/<dev>/LunaDownloadMgr.bin; falls back to novacom fetch.
downloadmgr_for() {
  local d="$1" bin exp got tok
  bin="$BASE/devices/$d/LunaDownloadMgr.bin"
  if [ ! -f "$bin" ] && [ "$d" = topaz ] && [ -f "$BASE/LunaDownloadMgr.bin" ]; then bin="$BASE/LunaDownloadMgr.bin"; fi
  exp="$(dev_dlmgr_md5 "$d")"
  if [ -f "$bin" ]; then
    got="$(md5sum "$bin" | cut -d' ' -f1)"
    if [ -n "$exp" ] && [ "$got" != "$exp" ]; then
      echo "  NOTE: $d LunaDownloadMgr.bin md5 $got != registry $exp (building with it anyway)" >&2
    fi
    printf '%s\n' "$bin"; return 0
  fi
  command -v novacom >/dev/null 2>&1 || return 1
  tok="$(dev_novacom "$d")"
  novacom -l 2>/dev/null | grep -qiE "$tok" || return 1
  echo "  fetching stock LunaDownloadMgr from a connected $d over novacom..." >&2
  bin="$BASE/devices/$d/LunaDownloadMgr.bin"; mkdir -p "$(dirname "$bin")"
  novacom get file:///usr/bin/LunaDownloadMgr > "$bin" 2>/dev/null || { rm -f "$bin"; return 1; }
  [ -s "$bin" ] || { rm -f "$bin"; return 1; }
  got="$(md5sum "$bin" | cut -d' ' -f1)"
  if [ -n "$exp" ] && [ "$got" != "$exp" ]; then
    echo "ERROR: fetched $d LunaDownloadMgr md5 $got != expected stock $exp (device patched/non-stock?)" >&2
    rm -f "$bin"; return 1
  fi
  echo "  fetched stock $d LunaDownloadMgr ($got)" >&2
  printf '%s\n' "$bin"; return 0
}

# prebuilt_rpath <board> <pkgbase> <version> <member>: echo a path to a temp copy of the
# ALREADY-RPATH'd binary taken out of a previously built per-board ipk in ipks/<board>/,
# or return non-zero if that ipk isn't there. This is what lets the multi-board 'phone'
# bundle be rebuilt on a checkout that lacks the (gitignored, proprietary) stock Palm
# binaries -- and it is not a shortcut: the committed per-board ipk already holds exactly
# the patched binary that was built and hardware-tested, so reusing it is bit-identical to
# re-patching a stock one. Only the stock md5 (used for the postinst's "backed up a
# non-stock binary" NOTE) then has to come from the registry instead of a live md5sum.
prebuilt_rpath() {
  local b="$1" base="$2" ver="$3" member="$4" ipk out
  ipk="$OUT/$b/org.webosinternals.${base}_${ver}_${ARCH}.ipk"
  [ -f "$ipk" ] || return 1
  out="$(mktemp "${TMPDIR:-/tmp}/rpathbin.XXXXXX")" || return 1
  if ! "$AR" p "$ipk" data.tar.gz 2>/dev/null \
       | tar xzOf - "./usr/palm/applications/org.webosinternals.$base/files/$member" > "$out" 2>/dev/null; then
    rm -f "$out"; return 1
  fi
  [ -s "$out" ] || { rm -f "$out"; return 1; }
  printf '%s\n' "$out"
}

# Split args into DEVICES (codenames) and WANT (package selectors); either may be
# given, in any order. DEVICE=... env also seeds DEVICES. Unknown tokens error out.
#   ./build-ipks.sh                     -> all packages, all devices with a binary present
#   ./build-ipks.sh mantaray browser    -> just browser-tls13 for the Pre 3
#   ./build-ipks.sh curl ntp            -> device-independent packages only
DEVICES=""; WANT=""
for a in ${DEVICE:-} "$@"; do
  [ -z "$a" ] && continue
  if is_device "$a"; then DEVICES="$DEVICES $a"
  elif [ "$a" = alldevices ]; then DEVICES="$DEVICES $ALL_DEVICES"
  else case "$a" in
    all) WANT="$WANT all";;
    browser|ntp|curl|luna|mail|imaptagfix|downloadmgr) WANT="$WANT $a";;
    *) echo "ERROR: unknown argument '$a'" >&2
       echo "       devices:  $ALL_DEVICES (or 'alldevices', or '$PHONE_TARGET' = all webOS 2.x phones in one ipk)" >&2
       echo "       packages: browser ntp curl luna mail imaptagfix downloadmgr all" >&2
       exit 1;;
  esac; fi
done
[ -n "$WANT" ] || WANT="all"
want() { case " $WANT " in *" all "*) return 0;; *" $1 "*) return 0;; *) return 1;; esac; }
# Default device set = those with a stock BrowserServer present, so a plain build
# "just works" for whatever device binaries the maintainer has dropped in.
if [ -z "$(printf %s "$DEVICES" | tr -d ' ')" ]; then
  for d in $ALL_DEVICES; do
    if [ -f "$BASE/devices/$d/BrowserServer.bin" ] || { [ "$d" = topaz ] && [ -f "$BASE/BrowserServer.bin" ]; }; then
      DEVICES="$DEVICES $d"
    fi
  done
fi
# de-dupe DEVICES, preserving order
DEVICES="$(printf '%s\n' $DEVICES | awk '!seen[$0]++' | tr '\n' ' ')"

# browserserver_for <dev>: echo a verified stock BrowserServer path for the device to
# stdout (progress/errors to stderr), or exit non-zero if none is available. Prefers a
# supplied devices/<dev>/BrowserServer.bin; falls back to a novacom auto-fetch.
browserserver_for() {
  local d="$1" bin exp got tok
  bin="$BASE/devices/$d/BrowserServer.bin"
  if [ ! -f "$bin" ] && [ "$d" = topaz ] && [ -f "$BASE/BrowserServer.bin" ]; then bin="$BASE/BrowserServer.bin"; fi
  exp="$(dev_bs_md5 "$d")"
  if [ -f "$bin" ]; then
    got="$(md5sum "$bin" | cut -d' ' -f1)"
    if [ -n "$exp" ] && [ "$got" != "$exp" ]; then
      echo "  NOTE: $d BrowserServer.bin md5 $got != registry $exp (building with it anyway)" >&2
    fi
    printf '%s\n' "$bin"; return 0
  fi
  # not on disk -> try to auto-fetch from a connected device of this type
  command -v novacom >/dev/null 2>&1 || return 1
  tok="$(dev_novacom "$d")"
  novacom -l 2>/dev/null | grep -qiE "$tok" || return 1
  echo "  fetching stock BrowserServer from a connected $d over novacom..." >&2
  bin="$BASE/devices/$d/BrowserServer.bin"; mkdir -p "$(dirname "$bin")"
  novacom get file:///usr/bin/BrowserServer > "$bin" 2>/dev/null || { rm -f "$bin"; return 1; }
  [ -s "$bin" ] || { rm -f "$bin"; return 1; }
  got="$(md5sum "$bin" | cut -d' ' -f1)"
  if [ -n "$exp" ] && [ "$got" != "$exp" ]; then
    echo "ERROR: fetched $d BrowserServer md5 $got != expected stock $exp (device patched/non-stock?)" >&2
    rm -f "$bin"; return 1
  fi
  echo "  fetched stock $d BrowserServer ($got)" >&2
  printf '%s\n' "$bin"; return 0
}
MAINT="WebOS Internals <support@webos-internals.org>"
TLSVER="1.1.2"   # browser-tls13: 1.1.2 ssl11 OpenSSL rebuilt with ARM NEON bulk crypto (bsaes AES / sha-neon / poly1305-neon / ChaCha20) on top of the existing ecp_nistz256+bn_mul_mont handshake asm -- see build-openssl.sh; still 1.1.1w, ABI 0x5000002 unchanged. 1.1.1: app-layout + robust backup / safe teardown
NTPVER="2.0.1"   # ntpdate-sync: app-layout
CURLVER="1.0.1"  # curl-tls13: modern curl as /usr/bin/curl11 AND /usr/bin/curl (stock backed up); CA bundle defaulted
LUNAVER="1.1.3"  # luna-tls13: 1.1.3: ship a setcpushares-task env-scrub wrapper so App-Manager installs/removes (Preware installSvc/replaceSvc, WOSQI) work again. LunaSysMgr drives them via `setcpushares-task ApplicationInstallerUtility -c install ...`; setcpushares-task is a /bin/sh script, and on LunaCE the install child's env is composed with LD_PRELOAD=libpvrtc.so while our leaked LD_BIND_NOW=1 forces eager binding of libpvrtc's undefined NApp_* -> /bin/sh dies at exec (exit 127/status 32512), the install FAILS, com.palm.appinstaller drops the connection, and Preware's luna-send blocks forever ("stuck IPKG lock"/wedge). Same fix shape as setcpushares-pdk (a DIFFERENT cpu-shares helper -- pdk=app launch, task=install): static wrapper installed AS setcpushares-task (stock script -> .real) strips the tls13 additions (LD_BIND_NOW + ssl11 preload/libpath) and execs the real script; scrubbed env propagates to the whole install subtree. Hardware-proven: composed env {LD_BIND_NOW=1, LD_PRELOAD=libpvrtc.so}, wrapper -> install runs to SUCCESS. 1.1.2: ship a setcpushares-pdk env-scrub wrapper so PDK apps (QupZilla / the nizovn Qt5-glibc stack) launch again. Every PDK app is spawned by LunaSysMgr through /usr/sbin/setcpushares-pdk and inherits the launcher ssl11 env; under LunaCE the leaked LD_BIND_NOW=1 is FATAL (LunaCE PDK child env preloads libpvrtc.so, whose lazily-unresolved NApp_* symbols become eager-bind errors -> /bin/sh dies at exec, exit 127, app never starts), and under stock Luna the leaked libssl_compat.so LD_PRELOAD crashes nizovn-glibc apps. The wrapper (installed AS setcpushares-pdk, stock script moved to .real) strips ONLY the tls13 additions and execs the real script; static ELF because a shell scrub cannot outrun an env that kills /bin/sh itself. luna-tls13: app WebKit (LunaSysMgr/WebAppMgr) -> ssl11; needs browser-tls13. 1.1.1: ship a media-pipeline env-scrub wrapper so HTML5 media (Pandora/Plex/drPodder AND stock Music) plays RELIABLY. The forked media worker inherits WebAppMgr's ssl11 env but never needed OpenSSL (local files; http via libsoup->gnutls), and that inherited stack corrupts its teardown -> media wedged after ~1 song (next worker dies at init, play goes no-op until a Luna restart). The wrapper (installed AS /usr/bin/media-pipeline) restores the stock env and execs the real binary, moved to .real and given its own LS2 role. SUPERSEDES 1.1.0's LD_BIND_NOW-only fix, which only unmasked this deeper wedge. Wrapper install is independent of the launcher patch, so it also fixes 1.1.0 installs on upgrade. 1.1.0: + LD_BIND_NOW=1 (first-worker lazy-binding crash across the 0.9.8->1.1 shim).
MAILVER="1.3.2"  # mail-tls13: mojomail (EAS/IMAP/POP/SMTP) -> purpose-built libcurl (vs OpenSSL 1.1, CA bundle baked in) + OWN superset shim + ssl11 + LD_BIND_NOW launchers; needs browser-tls13 installed + curl-mail/ (see BUILDING.md). 1.3.2: Gmail (and any ECDSA-leaf server) IMAP/POP fix -- libpalmsocket (0.9.8-built, on 1.1 via our shim) mis-verifies ECDSA leaf certs as "self signed" (X509_V_ERR=18 -> err 4010); ship /usr/lib/ssl11mail/mailssl.cnf + inject OPENSSL_CONF into the imap/pop/smtp launchers to force TLS 1.2 + RSA cert (keeps full validation; eas untouched -- it verifies via libcurl). Upgrade-safe: injects OPENSSL_CONF even on launchers a prior mail-tls13 already patched. 1.3.1: split the mojomail-imap tag patch out into its own org.webosinternals.mojomail-imap-tagfix package (take-or-leave). 1.3.0: full EAS+IMAP+SMTP proven (LD_BIND_NOW eager binding fixes intermittent ld.so SIGSEGV). 1.2.0: EAS (shim CONF_modules_free + SSL_CTX_get_ex_new_index; libcurl --with-ca-bundle)
IMAPTAGVER="1.0.0"  # mojomail-imap-tagfix: standalone 1-byte patch of /usr/bin/mojomail-imap IMAP tag prefix ~A->AA so strict servers (Fastmail) accept it (see mojomail-changes.md). Independent of the TLS stack; take-or-leave.
DOWNVER="1.0.0"  # downloadmgr-tls13: route the system Download Manager (/usr/bin/LunaDownloadMgr) through modern TLS. LunaDownloadMgr does ALL its HTTP(S) via libcurl and links NO OpenSSL directly, so an RPATH (/usr/lib/ssl11dl:/usr/lib/ssl11) onto a modern libcurl (the mail 7.61.1 build: OpenSSL 1.1.1w + c-ares + baked CA bundle) modernizes both downloads AND uploads with no binary code patch. The baked ca-bundle makes cert validation succeed despite the daemon's hard-coded CURLOPT_CAPATH=/var/ssl/trustedcerts (which is 0.9.8-hashed and invisible to OpenSSL 1.1). Hardware-proven: download negotiates TLS 1.3, Let's Encrypt/modern certs validate, multipart upload 200. Arbitrary request headers on downloads (Authorization/Bearer JWT, X-Auth-Token) work via the cookieHeader multi-line convention (see downloadmgr-tls13/README.md); uploads already take a native customHttpHeaders array. Needs browser-tls13 (provides /usr/lib/ssl11 OpenSSL).
# browser-tls13 / downloadmgr-tls13 stock binaries + md5s are now per-device (see the
# registry above: dev_bs_md5 / dev_dlmgr_md5, resolved by browserserver_for / downloadmgr_for
# from devices/<dev>/{BrowserServer,LunaDownloadMgr}.bin).

LIBSSL="$BASE/openssl-1.1.1w/libssl.so.1.1"
LIBCRYPTO="$BASE/openssl-1.1.1w/libcrypto.so.1.1"
LIBCOMPAT="$BASE/libssl_compat.so"
LIBCURL="$BASE/curl-7.88.1/lib/.libs/libcurl.so.4.8.0"
CURLBIN="$BASE/curl-7.88.1/src/.libs/curl"
NTPSRC="$BASE/ntpdate-sync"
MAIL_LIBCURL="$BASE/curl-mail/lib/.libs/libcurl.so.4.5.0"  # libcurl 7.61.1 (OpenSSL 1.1.1w + c-ares + baked CA bundle); shared with mail-tls13

# --- build prerequisites (fail fast, before doing any work) -------------------
if want browser; then
command -v patchelf >/dev/null 2>&1 || {
  echo "ERROR: 'patchelf' not found in PATH -- required to RPATH BrowserServer." >&2
  echo "       Install it (e.g. 'apt-get install patchelf', or 'brew install patchelf')." >&2
  exit 1
}
fi

# GNU ar is REQUIRED. The pmPostInstall.script/pmPreRemove.script members have long
# names; BSD ar (macOS /usr/bin/ar) encodes those in a format the device's ipkg/
# appinstaller can't read, so the packages would install but never activate.
AR=""
for c in gar ar /usr/local/opt/binutils/bin/ar /opt/homebrew/opt/binutils/bin/ar; do
  { command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; } || continue
  "$c" --version 2>/dev/null | grep -qi 'GNU ar' && { AR="$c"; break; }
done
[ -n "$AR" ] || {
  echo "ERROR: GNU ar not found (your 'ar' is BSD, e.g. stock macOS)." >&2
  echo "       BSD ar can't write the GNU long-name members the device needs." >&2
  echo "       Install GNU binutils: 'brew install binutils' (provides GNU ar), or build on Linux." >&2
  exit 1
}

# The stock BrowserServer to RPATH is resolved per-device inside the browser-tls13
# section (browserserver_for <dev>): it uses devices/<dev>/BrowserServer.bin, or
# auto-fetches from a connected device of that type over novacom.
if want browser; then
  echo "browser-tls13 target device(s):$DEVICES"
fi
# -----------------------------------------------------------------------------

# downloadmgr-tls13 prereqs. The stock LunaDownloadMgr to RPATH is resolved per-device
# inside the section (downloadmgr_for <dev>): devices/<dev>/LunaDownloadMgr.bin or a
# novacom auto-fetch. Here we just fail fast on the shared tool/lib prereqs.
if want downloadmgr; then
command -v patchelf >/dev/null 2>&1 || {
  echo "ERROR: 'patchelf' not found in PATH -- required to RPATH LunaDownloadMgr." >&2
  echo "       Install it (e.g. 'apt-get install patchelf', or 'brew install patchelf')." >&2
  exit 1
}
[ -f "$MAIL_LIBCURL" ] || {
  echo "ERROR: $MAIL_LIBCURL not found -- build the mail libcurl first (see BUILDING.md)." >&2
  echo "       downloadmgr-tls13 reuses that 7.61.1 (OpenSSL 1.1 + c-ares + baked CA bundle) build." >&2
  exit 1
}
echo "downloadmgr-tls13 target device(s):$DEVICES"
fi  # want downloadmgr
# -----------------------------------------------------------------------------

# Clean only our build artifacts in $OUT (the repo ipks/ dir) -- keep README.md etc.
mkdir -p "$OUT"
# Blanket-clean only for a full build; a selective rebuild keeps unselected ipks
# (pack() removes each package's own ipk before repacking, so this is safe).
if want all; then rm -f "$OUT"/*.ipk "$OUT"/*/*.ipk 2>/dev/null || true; fi
rm -rf "$OUT"/_b_* 2>/dev/null || true
T="--owner=0 --group=0 --numeric-owner --format=ustar"
# 1x1 transparent png (icon)
PNG_B64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='

pack() { # $1 builddir  $2 ipkname  [$3 outdir=$OUT]
  local b="$1" name="$2" outdir="${3:-$OUT}"
  mkdir -p "$outdir"
  rm -f "$outdir/$name"   # ar rc appends to an existing archive -> always start clean
  printf '2.0\n' > "$b/debian-binary"
  ( cd "$b/control" && tar $T -czf ../control.tar.gz . )
  ( cd "$b/data"    && tar $T -czf ../data.tar.gz    . )
  # webOS App-Manager hooks: the luna appinstaller (WOSQI / App Catalog / Preware
  # app installs) runs these TOP-LEVEL scripts, not the Debian control postinst.
  # Make them identical to postinst/prerm so every install path applies the bits.
  cp "$b/control/postinst" "$b/pmPostInstall.script"
  cp "$b/control/prerm"    "$b/pmPreRemove.script"
  chmod 0755 "$b/pmPostInstall.script" "$b/pmPreRemove.script"
  # webos-internals ar member order: debian-binary, data.tar.gz, control.tar.gz, pm scripts
  ( cd "$b" && "$AR" rc "$outdir/$name" debian-binary data.tar.gz control.tar.gz \
        pmPostInstall.script pmPreRemove.script )
  echo "  built ${outdir#"$OUT"/}/$name"
}

############################# browser-tls13 (per device) #############################
if want browser; then
for dev in $DEVICES; do
sfx="$(tgt_suffix "$dev")"; boards="$(tgt_boards "$dev")"
ID="org.webosinternals.browser-tls13$sfx"
PRODUCT="$(dev_product "$dev")"
B="$OUT/_b_tls_$dev"; rm -rf "$B"; APPDIR="$B/data/usr/palm/applications/$ID"; F="$APPDIR/files"
mkdir -p "$B/control" "$F/ssl11"
# Stage each bundled board's RPATH'd BrowserServer and remember its md5 pair. A
# single-board target keeps the historical flat "BrowserServer.rpath" name so its ipk
# stays byte-identical to previous builds; the phone bundle suffixes per board.
BS_CASES=""; staged=""
for b in $boards; do
  bs="$(browserserver_for "$b")" || bs=""
  pre=""
  [ -z "$bs" ] && { pre="$(prebuilt_rpath "$b" browser-tls13 "$TLSVER" BrowserServer.rpath)" || pre=""; }
  if [ -z "$bs" ] && [ -z "$pre" ]; then
    echo "  browser-tls13$sfx: SKIP board $b -- no stock BrowserServer (devices/$b/BrowserServer.bin) and no prebuilt ipks/$b/ ipk to reuse"
    continue
  fi
  if [ -n "$sfx" ]; then bsf="BrowserServer.rpath.$b"; else bsf="BrowserServer.rpath"; fi
  if [ -n "$bs" ]; then
    s_md5="$(md5sum "$bs" | cut -d' ' -f1)"
    cp "$bs" "$F/$bsf"; chmod 0644 "$F/$bsf"
    patchelf --force-rpath --set-rpath /usr/lib/ssl11 "$F/$bsf"
    patchelf --add-needed libssl_compat.so "$F/$bsf"
  else
    s_md5="$(dev_bs_md5 "$b")"          # no stock binary here; take its md5 from the registry
    cp "$pre" "$F/$bsf"; chmod 0644 "$F/$bsf"; rm -f "$pre"
    echo "  [$dev/$b] reusing the already-RPATH'd BrowserServer from ipks/$b (no stock binary in this checkout)"
  fi
  r_md5=$(md5sum "$F/$bsf" | cut -d' ' -f1)   # so postinst never backs up our own binary as "stock"
  echo "  [$dev/$b] $(dev_product "$b"): stock $s_md5 -> RPATH'd $r_md5"
  BS_CASES="$BS_CASES  $b) BS_FILE=$bsf; STOCK_BS_MD5=$s_md5; RPATH_BS_MD5=$r_md5;;
"
  BS_FILE1="$bsf"; STOCK1="$s_md5"; RPATH1="$r_md5"   # single-board target uses these directly
  staged="$staged $b"
done
if [ -z "$(printf %s "$staged" | tr -d ' ')" ]; then
  echo "  browser-tls13$sfx: SKIP $dev -- no board had a stock BrowserServer"
  rm -rf "$B"; continue
fi
install -m0644 "$LIBSSL"    "$F/ssl11/libssl.so.1.1"
install -m0644 "$LIBCRYPTO" "$F/ssl11/libcrypto.so.1.1"
install -m0644 "$LIBCOMPAT" "$F/ssl11/libssl_compat.so"
install -m0644 "$LIBCURL"   "$F/ssl11/libcurl.so.4.8.0"
# app metadata (headless / hidden)
cat > "$APPDIR/appinfo.json" <<EOF
{ "title":"Browser TLS 1.3", "id":"$ID", "version":"$TLSVER", "vendor":"WebOS Internals",
  "type":"web", "main":"index.html", "icon":"icon.png", "removable":true,
  "noWindow":true, "visible":false }
EOF
echo '<html><head><title>Browser TLS 1.3</title></head><body></body></html>' > "$APPDIR/index.html"
echo "$PNG_B64" | base64 -d > "$APPDIR/icon.png"

cat > "$B/control/control" <<EOF
Package: $ID
Version: $TLSVER
Architecture: $ARCH
Maintainer: $MAINT
Description: Modern TLS 1.2/1.3 for the stock browser on $PRODUCT
Section: System
Priority: optional
Depends:
Source: { "Type":"Application", "Feed":"WebOS Internals", "Category":"System", "Title":"Browser TLS 1.3 ($dev)", "FullDescription":"Adds a process-private OpenSSL 1.1.1w + curl(zlib) under /usr/lib/ssl11 and points the stock $PRODUCT BrowserServer at it via RPATH, so the 2011 browser can reach modern TLS 1.2/1.3 sites. Requires a current /etc/ssl/certs/ca-certificates.crt (Mozilla ca-certificates).", "License":"OpenSSL/curl" }
EOF

printf '#!/bin/sh\n' > "$B/control/postinst"
if [ -n "$sfx" ]; then
  # multi-board bundle: resolve the running board, then pick its binary + md5 pair.
  # An unrecognised board (e.g. a TouchPad) exits before touching anything.
  emit_board_detect >> "$B/control/postinst"
  cat >> "$B/control/postinst" <<EOF
case "\$BOARD" in
$BS_CASES  *) echo "browser-tls13: ERROR -- this package is for $PRODUCT; board '\$BOARD' is not one of ($staged ). Not patching."; exit 1;;
esac
PID="$ID"
EOF
else
  cat >> "$B/control/postinst" <<EOF
BS_FILE="$BS_FILE1"
STOCK_BS_MD5="$STOCK1"
RPATH_BS_MD5="$RPATH1"
PID="$ID"
EOF
fi
cat >> "$B/control/postinst" <<'EOF'
# App-Manager installs offline under /media/cryptofs/apps and leaves the root ro;
# raw `ipkg install` puts files at / . Find wherever our payload actually landed.
[ -z "$IPKG_OFFLINE_ROOT" ] && IPKG_OFFLINE_ROOT=/media/cryptofs/apps
mount -o remount,rw / 2>/dev/null || true
SRC=""
for R in "$IPKG_OFFLINE_ROOT" /media/cryptofs/apps /var ""; do
    d="$R/usr/palm/applications/$PID/files"
    [ -d "$d/ssl11" ] && { SRC="$d"; break; }
done
[ -n "$SRC" ] || { echo "ERROR: browser-tls13 payload not found - install failed"; exit 1; }

# 0. clean stray upstart job-backups from old (<=1.0.3) installs (duplicate launchers)
rm -f /etc/event.d/*.tls13-orig /etc/event.d/*.orig /etc/event.d/*.preua /etc/event.d/*.pre-rpath 2>/dev/null

# 1. install the ssl11 stack to /usr/lib/ssl11 (symlinks made here -- the offline-root
#    filesystem rejects symlink creation during ipkg unpack)
rm -rf /usr/lib/ssl11; mkdir -p /usr/lib/ssl11
cp -f "$SRC/ssl11/libssl.so.1.1" "$SRC/ssl11/libcrypto.so.1.1" \
      "$SRC/ssl11/libssl_compat.so" "$SRC/ssl11/libcurl.so.4.8.0" /usr/lib/ssl11/
chmod 755 /usr/lib/ssl11/*.so*
ln -sf libcurl.so.4.8.0 /usr/lib/ssl11/libcurl.so.4
ln -sf libssl.so.1.1    /usr/lib/ssl11/libssl.so.0.9.8
ln -sf libcrypto.so.1.1 /usr/lib/ssl11/libcrypto.so.0.9.8

# 2. swap in the RPATH'd BrowserServer. Back up whatever browser is currently
#    installed ONCE -- only when no backup exists yet AND it isn't already our
#    RPATH'd build -- so the package stays cleanly uninstallable even on a
#    non-stock BrowserServer, and we never save our own binary as if it were stock.
cur=$(md5sum /usr/bin/BrowserServer 2>/dev/null | cut -d' ' -f1)
if [ ! -f /usr/bin/BrowserServer.tls13-orig ] && [ "$cur" != "$RPATH_BS_MD5" ] && [ -f /usr/bin/BrowserServer ]; then
    cp -p /usr/bin/BrowserServer /usr/bin/BrowserServer.tls13-orig
    [ "$cur" = "$STOCK_BS_MD5" ] || echo "NOTE: backed up a non-stock BrowserServer ($cur) as the uninstall restore point."
fi
cp -f "$SRC/$BS_FILE" /usr/bin/BrowserServer
chmod 755 /usr/bin/BrowserServer

# 3. CA bundle check (no '|| echo 0' -- that yields two values and breaks the test)
n=$(grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt 2>/dev/null); [ -z "$n" ] && n=0
[ "$n" -lt 50 ] && echo "WARNING: stale CA bundle ($n certs) -- install a current Mozilla ca-certificates ipk."

# 4. restart browser
stop browserserver 2>/dev/null || true
i=0; while [ $i -lt 8 ]; do ps=$(pidof BrowserServer 2>/dev/null); [ -z "$ps" ] && break; for p in $ps; do kill -9 $p 2>/dev/null; done; i=$((i+1)); sleep 1; done
start browserserver 2>/dev/null || true
exit 0
EOF

cat > "$B/control/prerm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
stop browserserver 2>/dev/null || true
i=0; while [ $i -lt 8 ]; do ps=$(pidof BrowserServer 2>/dev/null); [ -z "$ps" ] && break; for p in $ps; do kill -9 $p 2>/dev/null; done; i=$((i+1)); sleep 1; done
# Restore stock ONLY if we have the backup; otherwise the live BrowserServer is our
# RPATH'd one and removing /usr/lib/ssl11 would leave it unable to load its libs
# (dead browser) -- so keep the stack in place.
if [ -f /usr/bin/BrowserServer.tls13-orig ]; then
    mv -f /usr/bin/BrowserServer.tls13-orig /usr/bin/BrowserServer
    rm -rf /usr/lib/ssl11
else
    echo "WARNING: no BrowserServer.tls13-orig backup; keeping /usr/lib/ssl11 so the browser keeps working."
fi
start browserserver 2>/dev/null || true
exit 0
EOF
chmod 0755 "$B/control/postinst" "$B/control/prerm"
pack "$B" "${ID}_${TLSVER}_${ARCH}.ipk" "$OUT/$dev"
done  # for dev in $DEVICES
fi  # want browser

############################# ntpdate-sync #############################
if want ntp; then
ID2=org.webosinternals.ntpdate-sync
B2="$OUT/_b_ntp"; APPDIR2="$B2/data/usr/palm/applications/$ID2"; F2="$APPDIR2/files"
mkdir -p "$B2/control" "$F2"
install -m0644 "$NTPSRC" "$F2/ntpdate-sync"
cat > "$APPDIR2/appinfo.json" <<EOF
{ "title":"NTP Clock Sync", "id":"$ID2", "version":"$NTPVER", "vendor":"WebOS Internals",
  "type":"web", "main":"index.html", "icon":"icon.png", "removable":true,
  "noWindow":true, "visible":false }
EOF
echo '<html><head><title>NTP Clock Sync</title></head><body></body></html>' > "$APPDIR2/index.html"
echo "$PNG_B64" | base64 -d > "$APPDIR2/icon.png"

cat > "$B2/control/control" <<EOF
Package: $ID2
Version: $NTPVER
Architecture: $ARCH
Maintainer: $MAINT
Description: NTP clock sync for legacy webOS (2.2.4 / 3.0.5)
Section: System
Priority: optional
Depends:
Source: { "Type":"Application", "Feed":"WebOS Internals", "Category":"System", "Title":"NTP Clock Sync", "FullDescription":"webOS time sync targets dead palm.com servers; this installs an upstart job that syncs from public NTP (retry-until-success + IP fallbacks) at boot and every 6h, fixing TLS cert validity windows.", "License":"MIT" }
EOF

cat > "$B2/control/postinst" <<EOF
#!/bin/sh
PID="$ID2"
EOF
cat >> "$B2/control/postinst" <<'EOF'
[ -z "$IPKG_OFFLINE_ROOT" ] && IPKG_OFFLINE_ROOT=/media/cryptofs/apps
mount -o remount,rw / 2>/dev/null || true
SRC=""
for R in "$IPKG_OFFLINE_ROOT" /media/cryptofs/apps /var ""; do
    [ -f "$R/usr/palm/applications/$PID/files/ntpdate-sync" ] && { SRC="$R/usr/palm/applications/$PID/files"; break; }
done
[ -n "$SRC" ] || { echo "ERROR: ntpdate-sync payload not found"; exit 1; }
cp -f "$SRC/ntpdate-sync" /etc/event.d/ntpdate-sync
chmod 755 /etc/event.d/ntpdate-sync
stop ntpdate-sync 2>/dev/null || true
start ntpdate-sync 2>/dev/null || true
exit 0
EOF

cat > "$B2/control/prerm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
stop ntpdate-sync 2>/dev/null || true
rm -f /etc/event.d/ntpdate-sync
exit 0
EOF
chmod 0755 "$B2/control/postinst" "$B2/control/prerm"
pack "$B2" "${ID2}_${NTPVER}_${ARCH}.ipk"
fi  # want ntp

############################# curl-tls13 #############################
if want curl; then
ID3=org.webosinternals.curl-tls13
B3="$OUT/_b_curl"; APPDIR3="$B3/data/usr/palm/applications/$ID3"; F3="$APPDIR3/files"
mkdir -p "$B3/control" "$F3/curl11"
install -m0644 "$LIBSSL"    "$F3/curl11/libssl.so.1.1"
install -m0644 "$LIBCRYPTO" "$F3/curl11/libcrypto.so.1.1"
install -m0644 "$LIBCURL"   "$F3/curl11/libcurl.so.4.8.0"
install -m0644 "$CURLBIN"   "$F3/curl11/curl"
cat > "$APPDIR3/appinfo.json" <<EOF
{ "title":"curl (TLS 1.3)", "id":"$ID3", "version":"$CURLVER", "vendor":"WebOS Internals",
  "type":"web", "main":"index.html", "icon":"icon.png", "removable":true,
  "noWindow":true, "visible":false }
EOF
echo '<html><head><title>curl TLS 1.3</title></head><body></body></html>' > "$APPDIR3/index.html"
echo "$PNG_B64" | base64 -d > "$APPDIR3/icon.png"

cat > "$B3/control/control" <<EOF
Package: $ID3
Version: $CURLVER
Architecture: $ARCH
Maintainer: $MAINT
Description: Modern command-line curl (7.88.1, TLS 1.2/1.3) for legacy webOS (2.2.4 / 3.0.5)
Section: System
Priority: optional
Depends:
Source: { "Type":"Application", "Feed":"WebOS Internals", "Category":"System", "Title":"curl TLS 1.3", "FullDescription":"curl 7.88.1 (OpenSSL 1.1.1w + zlib) under /usr/lib/curl11, installed as /usr/bin/curl11 AND /usr/bin/curl (stock 0.9.8 backed up to /usr/bin/curl.0.9.8-orig, restored on uninstall). Wrapper defaults the CA bundle to /etc/ssl/certs/ca-certificates.crt.", "License":"OpenSSL/curl" }
EOF

cat > "$B3/control/postinst" <<EOF
#!/bin/sh
PID="$ID3"
EOF
cat >> "$B3/control/postinst" <<'EOF'
[ -z "$IPKG_OFFLINE_ROOT" ] && IPKG_OFFLINE_ROOT=/media/cryptofs/apps
mount -o remount,rw / 2>/dev/null || true
SRC=""
for R in "$IPKG_OFFLINE_ROOT" /media/cryptofs/apps /var ""; do
    d="$R/usr/palm/applications/$PID/files"
    [ -d "$d/curl11" ] && { SRC="$d"; break; }
done
[ -n "$SRC" ] || { echo "ERROR: curl-tls13 payload not found"; exit 1; }
rm -rf /usr/lib/curl11; mkdir -p /usr/lib/curl11
cp -f "$SRC/curl11/curl" "$SRC/curl11/libcurl.so.4.8.0" \
      "$SRC/curl11/libssl.so.1.1" "$SRC/curl11/libcrypto.so.1.1" /usr/lib/curl11/
chmod 755 /usr/lib/curl11/*
ln -sf libcurl.so.4.8.0 /usr/lib/curl11/libcurl.so.4
# Wrapper defaults the CA bundle to webOS's (the build's compiled-in CA path doesn't
# exist on-device); respects an existing CURL_CA_BUNDLE, and explicit --cacert wins.
cat > /usr/bin/curl11 <<'WRAP'
#!/bin/sh
[ -n "$CURL_CA_BUNDLE" ] || CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export CURL_CA_BUNDLE LD_LIBRARY_PATH=/usr/lib/curl11
exec /usr/lib/curl11/curl "$@"
WRAP
chmod 755 /usr/bin/curl11
# Also take over /usr/bin/curl (back up the stock 0.9.8 binary once).
if [ -f /usr/bin/curl ] && [ ! -f /usr/bin/curl.0.9.8-orig ]; then
    cp -p /usr/bin/curl /usr/bin/curl.0.9.8-orig
fi
cp -f /usr/bin/curl11 /usr/bin/curl
chmod 755 /usr/bin/curl
exit 0
EOF

cat > "$B3/control/prerm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
# Restore stock curl if backed up; else drop our wrapper so /usr/bin/curl isn't left dangling.
if [ -f /usr/bin/curl.0.9.8-orig ]; then
    mv -f /usr/bin/curl.0.9.8-orig /usr/bin/curl
else
    grep -q 'LD_LIBRARY_PATH=/usr/lib/curl11' /usr/bin/curl 2>/dev/null && rm -f /usr/bin/curl
fi
rm -f /usr/bin/curl11
rm -rf /usr/lib/curl11
exit 0
EOF
chmod 0755 "$B3/control/postinst" "$B3/control/prerm"
pack "$B3" "${ID3}_${CURLVER}_${ARCH}.ipk"
fi  # want curl

############################# luna-tls13 (per device) #############################
if want luna; then
# Routes the app WebKit host (LunaSysMgr / WebAppMgr -- where Mojo/Enyo XHR runs) at
# /usr/lib/ssl11. On webOS 2.x it's PAYLOAD-FREE: the postinst just edits the LunaSysMgr
# upstart launcher. On webOS 3.0.5 (LunaCE) it ALSO ships env-scrub wrappers
# (media-pipeline / setcpushares-pdk / setcpushares-task). REQUIRES browser-tls13; REBOOT after.
CROSSGCC=/opt/PalmPDK/arm-gcc/bin/arm-none-linux-gnueabi-gcc
for dev in $DEVICES; do
fam="$(dev_webos "$dev")"; PRODUCT="$(dev_product "$dev")"
# luna-tls13 needs NO per-board content: the webOS 2.x build is a launcher patch with no
# payload (verified byte-identical across mantaray/broadway/roadrunner), and only webOS 3.x
# ships the LunaCE env-scrub wrappers. So the phone bundle is just the fam=2 build.
sfx="$(tgt_suffix "$dev")"
ID4="org.webosinternals.luna-tls13$sfx"
B4="$OUT/_b_luna_$dev"; rm -rf "$B4"; APPDIR4="$B4/data/usr/palm/applications/$ID4"; F4="$APPDIR4/files"
mkdir -p "$B4/control" "$APPDIR4" "$F4"
echo "  [$dev] $PRODUCT: luna-tls13 (webOS $fam -- $([ "$fam" = 3 ] && echo 'launcher patch + LunaCE env-scrub wrappers' || echo 'launcher patch only'))"
# webOS 3.x (LunaCE) needs env-scrub wrappers; webOS 2.x does not (no LunaCE; setcpushares-pdk
# doesn't exist). 2.x therefore ships NO wrapper payloads -- launcher patch only.
if [ "$fam" = 3 ]; then
# media-pipeline env-scrub wrapper payload: compile from source with the PalmPDK
# cross-gcc when present (reproducible); else fall back to the committed prebuilt so
# luna still builds on a host without the toolchain (e.g. the Mac re-wrap path).
MPWRAP_SRC="$BASE/media-pipeline-wrap.c"
MPWRAP_BIN="$BASE/media-pipeline-wrap.bin"
if [ -x "$CROSSGCC" ] && [ -f "$MPWRAP_SRC" ]; then
    "$CROSSGCC" -static -Os -o "$F4/media-pipeline.wrap" "$MPWRAP_SRC"
    "${CROSSGCC%gcc}strip" "$F4/media-pipeline.wrap" 2>/dev/null || true
    echo "  luna: compiled media-pipeline wrapper from source"
elif [ -f "$MPWRAP_BIN" ]; then
    cp -f "$MPWRAP_BIN" "$F4/media-pipeline.wrap"
    echo "  luna: using prebuilt media-pipeline wrapper"
else
    echo "ERROR: no media-pipeline wrapper -- need $MPWRAP_SRC + PalmPDK gcc, or prebuilt $MPWRAP_BIN" >&2
    exit 1
fi
chmod 0644 "$F4/media-pipeline.wrap"
# setcpushares-pdk env-scrub wrapper payload: same compile-or-prebuilt strategy as
# the media wrapper above (PDK-app launch fix -- see the postinst block).
SPWRAP_SRC="$BASE/setcpushares-pdk-wrap.c"
SPWRAP_BIN="$BASE/setcpushares-pdk-wrap.bin"
if [ -x "$CROSSGCC" ] && [ -f "$SPWRAP_SRC" ]; then
    "$CROSSGCC" -static -Os -o "$F4/setcpushares-pdk.wrap" "$SPWRAP_SRC"
    "${CROSSGCC%gcc}strip" "$F4/setcpushares-pdk.wrap" 2>/dev/null || true
    echo "  luna: compiled setcpushares-pdk wrapper from source"
elif [ -f "$SPWRAP_BIN" ]; then
    cp -f "$SPWRAP_BIN" "$F4/setcpushares-pdk.wrap"
    echo "  luna: using prebuilt setcpushares-pdk wrapper"
else
    echo "ERROR: no setcpushares-pdk wrapper -- need $SPWRAP_SRC + PalmPDK gcc, or prebuilt $SPWRAP_BIN" >&2
    exit 1
fi
chmod 0644 "$F4/setcpushares-pdk.wrap"
# setcpushares-task env-scrub wrapper payload: same compile-or-prebuilt strategy
# (App-Manager install/remove fix -- see the postinst block).
STWRAP_SRC="$BASE/setcpushares-task-wrap.c"
STWRAP_BIN="$BASE/setcpushares-task-wrap.bin"
if [ -x "$CROSSGCC" ] && [ -f "$STWRAP_SRC" ]; then
    "$CROSSGCC" -static -Os -o "$F4/setcpushares-task.wrap" "$STWRAP_SRC"
    "${CROSSGCC%gcc}strip" "$F4/setcpushares-task.wrap" 2>/dev/null || true
    echo "  luna: compiled setcpushares-task wrapper from source"
elif [ -f "$STWRAP_BIN" ]; then
    cp -f "$STWRAP_BIN" "$F4/setcpushares-task.wrap"
    echo "  luna: using prebuilt setcpushares-task wrapper"
else
    echo "ERROR: no setcpushares-task wrapper -- need $STWRAP_SRC + PalmPDK gcc, or prebuilt $STWRAP_BIN" >&2
    exit 1
fi
chmod 0644 "$F4/setcpushares-task.wrap"
fi  # fam=3 : LunaCE env-scrub wrapper payloads
# luna-tls13 control text differs by family (3.x mentions the wrappers).
if [ "$fam" = 3 ]; then
  LUNA_DESC="Modern TLS 1.2/1.3 for webOS apps (Mojo/Enyo WebKit) on $PRODUCT"
  LUNA_FULL="Routes the app WebKit host (LunaSysMgr/WebAppMgr) through the OpenSSL 1.1.1w stack under /usr/lib/ssl11 so in-app HTTPS (Mojo/Enyo XHR, enyo.WebService) negotiates TLS 1.2/1.3. On webOS 3.0.5 (LunaCE) it also installs env-scrub wrappers (media-pipeline at /usr/bin, setcpushares-pdk and setcpushares-task at /usr/sbin) so HTML5 media, PDK apps and App-Manager installs keep working under the ssl11 launcher env. REQUIRES org.webosinternals.browser-tls13 (provides /usr/lib/ssl11). Edits the LunaSysMgr upstart launcher; REBOOT after install. Recovery: novacomd survives a UI failure -- restore /var/luna/LunaSysMgr.tls13-orig to /etc/event.d/LunaSysMgr and reboot."
else
  LUNA_DESC="Modern TLS 1.2/1.3 for webOS apps (Mojo/Enyo WebKit) on $PRODUCT"
  LUNA_FULL="Routes the app WebKit host (LunaSysMgr) through the OpenSSL 1.1.1w stack under /usr/lib/ssl11 so in-app HTTPS (Mojo/Enyo XHR, enyo.WebService) negotiates TLS 1.2/1.3. REQUIRES org.webosinternals.browser-tls13 (provides /usr/lib/ssl11). Edits the LunaSysMgr upstart launcher; REBOOT after install. Recovery: novacomd survives a UI failure -- restore /var/luna/LunaSysMgr.tls13-orig to /etc/event.d/LunaSysMgr and reboot."
fi
cat > "$APPDIR4/appinfo.json" <<EOF
{ "title":"Luna TLS 1.3", "id":"$ID4", "version":"$LUNAVER", "vendor":"WebOS Internals",
  "type":"web", "main":"index.html", "icon":"icon.png", "removable":true,
  "noWindow":true, "visible":false }
EOF
echo '<html><head><title>Luna TLS 1.3</title></head><body></body></html>' > "$APPDIR4/index.html"
echo "$PNG_B64" | base64 -d > "$APPDIR4/icon.png"

cat > "$B4/control/control" <<EOF
Package: $ID4
Version: $LUNAVER
Architecture: $ARCH
Maintainer: $MAINT
Description: $LUNA_DESC
Section: System
Priority: optional
Depends: org.webosinternals.browser-tls13$sfx
Source: { "Type":"Application", "Feed":"WebOS Internals", "Category":"System", "Title":"Luna TLS 1.3 ($dev)", "FullDescription":"$LUNA_FULL", "License":"OpenSSL/curl" }
EOF

# postinst: patch the LunaSysMgr launcher to load ssl11 (+ compat shim). Backup goes
# OUTSIDE /etc/event.d (upstart runs every file there as a job). Requires the ssl11
# stack; never restarts LunaSysMgr (that would kill the UI/Preware) -- reboot applies it.
cat > "$B4/control/postinst" <<EOF
#!/bin/sh
PID="$ID4"
EOF
cat >> "$B4/control/postinst" <<'EOF'
[ -z "$IPKG_OFFLINE_ROOT" ] && IPKG_OFFLINE_ROOT=/media/cryptofs/apps
mount -o remount,rw / 2>/dev/null || true
L=/etc/event.d/LunaSysMgr
COMPAT=/usr/lib/ssl11/libssl_compat.so
if [ ! -f "$COMPAT" ]; then
    echo "luna-tls13 ERROR: /usr/lib/ssl11 stack not found -- install org.webosinternals.browser-tls13 first. Not patching."
    exit 1
fi
EOF
# webOS 3.0.5 (LunaCE) only: the three env-scrub wrapper blocks. webOS 2.x skips them.
if [ "$fam" = 3 ]; then
cat >> "$B4/control/postinst" <<'EOF'

# ---- media-pipeline env-scrub wrapper (INDEPENDENT of the launcher patch) ----
# The HTML5 media worker (/usr/bin/media-pipeline, fork+exec'd by WebAppMgr) inherits
# WebAppMgr's ssl11 env but never needed OpenSSL (local files; http via libsoup->gnutls).
# That inherited stack corrupts the worker's teardown, so media WEDGES after ~1 song
# (Pandora/Plex/drPodder AND stock Music: one track plays, then the next worker dies at
# init and the play button goes no-op until a Luna restart). Fix: install a wrapper AS
# media-pipeline that restores the stock env and execs the real binary, moved to .real
# and given its own LS2 role (roles are keyed to the exe path). This block runs BEFORE
# the launcher "already patched" short-circuit below, so 1.0.0/1.1.0 installs get it on
# upgrade. Detection keys on the .real FILE (reliable; grep-on-binary is not portable).
MP=/usr/bin/media-pipeline
MPW=""
for R in "$IPKG_OFFLINE_ROOT" /media/cryptofs/apps /var ""; do
    f="$R/usr/palm/applications/$PID/files/media-pipeline.wrap"
    [ -f "$f" ] && { MPW="$f"; break; }
done
mp_role() {   # $1 = prv|pub ; derive the .real role from the stock one
    rf="/usr/share/ls2/roles/$1/com.palm.mediad.pipeline.json"
    [ -f "$rf" ] && sed 's#/usr/bin/media-pipeline#/usr/bin/media-pipeline.real#' "$rf" \
        > "/usr/share/ls2/roles/$1/com.palm.mediad.pipeline.real.json"
}
if [ -z "$MPW" ]; then
    echo "luna-tls13 WARNING: media-pipeline wrapper payload not found -- media fix NOT applied."
elif [ ! -f "$MP" ]; then
    echo "luna-tls13 NOTE: $MP not present -- skipping media fix."
elif [ -f "$MP.real" ]; then
    cp -f "$MPW" "$MP"; chmod 755 "$MP"          # already wrapped: refresh, keep .real intact
    mp_role prv; mp_role pub
    echo "luna-tls13: media-pipeline wrapper already installed (refreshed)."
else
    sz=$(wc -c < "$MP" 2>/dev/null || echo 0)
    if [ "${sz:-0}" -lt 900000 ]; then
        echo "luna-tls13 WARNING: $MP is only $sz bytes -- looks like a stray wrapper, not the real media worker. NOT wrapping (restore a stock media-pipeline to repair)."
    else
        mkdir -p /var/luna 2>/dev/null
        [ -f /var/luna/media-pipeline.stock-orig ] || cp -p "$MP" /var/luna/media-pipeline.stock-orig
        mv -f "$MP" "$MP.real"
        cp -f "$MPW" "$MP"; chmod 755 "$MP"
        if [ -s "$MP" ] && [ -f "$MP.real" ]; then
            mp_role prv; mp_role pub
            echo "luna-tls13: installed media-pipeline env-scrub wrapper + LS2 role (HTML5 media plays reliably)."
        else
            echo "luna-tls13 ERROR: wrapper install failed -- restoring real media-pipeline."
            mv -f "$MP.real" "$MP" 2>/dev/null
        fi
    fi
fi
/usr/bin/ls-control scan-services 2>/dev/null || true
# ---- end media-pipeline fix --------------------------------------------------

# ---- setcpushares-pdk env-scrub wrapper (INDEPENDENT of the launcher patch) ----
# Every PDK app is spawned by LunaSysMgr through /usr/sbin/setcpushares-pdk and
# inherits the ssl11 launcher env. Under LunaCE the leaked LD_BIND_NOW=1 is fatal:
# LunaCE's PDK child env preloads libpvrtc.so (lazily-unresolved NApp_* symbols),
# eager binding turns those into load errors, /bin/sh dies at exec (exit 127) and
# the app NEVER STARTS (hit: QupZilla / the whole nizovn Qt5-glibc stack). Under
# stock Luna the leaked libssl_compat.so LD_PRELOAD crashes nizovn-glibc apps.
# Fix: install a STATIC wrapper AS setcpushares-pdk (stock script moved to .real)
# that strips ONLY the tls13 additions -- LD_BIND_NOW, the libssl_compat.so
# preload entry, the /usr/lib/ssl11 library path -- and execs the real script,
# preserving whatever child env the (stock or LunaCE) sysmgr intended. Static
# because a shell scrub can't run when the env kills /bin/sh itself. This block
# runs BEFORE the launcher "already patched" short-circuit below so existing
# 1.1.0/1.1.1 installs get it on upgrade. Detection keys on the .real FILE.
SP=/usr/sbin/setcpushares-pdk
SPW=""
for R in "$IPKG_OFFLINE_ROOT" /media/cryptofs/apps /var ""; do
    f="$R/usr/palm/applications/$PID/files/setcpushares-pdk.wrap"
    [ -f "$f" ] && { SPW="$f"; break; }
done
if [ -z "$SPW" ]; then
    echo "luna-tls13 WARNING: setcpushares-pdk wrapper payload not found -- PDK launch fix NOT applied."
elif [ ! -f "$SP" ]; then
    echo "luna-tls13 NOTE: $SP not present -- skipping PDK launch fix."
elif [ -f "$SP.real" ]; then
    cp -f "$SPW" "$SP"; chmod 755 "$SP"          # already wrapped: refresh, keep .real intact
    echo "luna-tls13: setcpushares-pdk wrapper already installed (refreshed)."
elif head -n 1 "$SP" 2>/dev/null | grep -q '^#!'; then
    mkdir -p /var/luna 2>/dev/null
    [ -f /var/luna/setcpushares-pdk.tls13-orig ] || cp -p "$SP" /var/luna/setcpushares-pdk.tls13-orig
    mv -f "$SP" "$SP.real"
    cp -f "$SPW" "$SP"; chmod 755 "$SP"
    if [ -s "$SP" ] && [ -f "$SP.real" ]; then
        echo "luna-tls13: installed setcpushares-pdk env-scrub wrapper (PDK apps launch clean)."
    else
        echo "luna-tls13 ERROR: setcpushares-pdk wrapper install failed -- restoring stock script."
        mv -f "$SP.real" "$SP" 2>/dev/null
    fi
else
    echo "luna-tls13 WARNING: $SP has no shebang and no .real exists -- looks like a stray wrapper, not the stock script. NOT wrapping."
fi
# ---- end setcpushares-pdk fix --------------------------------------------------

# ---- setcpushares-task env-scrub wrapper (INDEPENDENT of the launcher patch) ----
# LunaSysMgr's App-Manager install/remove path runs the installer as
#   /usr/sbin/setcpushares-task  /usr/bin/ApplicationInstallerUtility -c install -p <ipk> ...
# setcpushares-task is a #!/bin/sh script; on LunaCE the install child's env is
# composed with LD_PRELOAD=libpvrtc.so, and our leaked LD_BIND_NOW=1 forces eager
# binding of libpvrtc's undefined NApp_* symbols -> /bin/sh dies at exec (exit 127
# / status 32512) BEFORE the installer runs. The install fails, com.palm.appinstaller
# drops its connection, and the caller's subscription never completes -> Preware
# (installSvc/replaceSvc) and WOSQI WEDGE ("stuck IPKG lock"). Same fix as the PDK
# path but a DIFFERENT cpu-shares helper: a STATIC wrapper AS setcpushares-task
# (stock script -> .real) strips ONLY the tls13 additions and execs the real script,
# whose scrubbed env propagates to the whole install subtree. Static because a shell
# scrub can't run when the env kills /bin/sh. Runs BEFORE the launcher "already
# patched" short-circuit so existing 1.1.x installs get it on upgrade. Keys on .real.
ST=/usr/sbin/setcpushares-task
STW=""
for R in "$IPKG_OFFLINE_ROOT" /media/cryptofs/apps /var ""; do
    f="$R/usr/palm/applications/$PID/files/setcpushares-task.wrap"
    [ -f "$f" ] && { STW="$f"; break; }
done
if [ -z "$STW" ]; then
    echo "luna-tls13 WARNING: setcpushares-task wrapper payload not found -- App-Manager install fix NOT applied."
elif [ ! -f "$ST" ]; then
    echo "luna-tls13 NOTE: $ST not present -- skipping App-Manager install fix."
elif [ -f "$ST.real" ]; then
    cp -f "$STW" "$ST"; chmod 755 "$ST"          # already wrapped: refresh, keep .real intact
    echo "luna-tls13: setcpushares-task wrapper already installed (refreshed)."
elif head -n 1 "$ST" 2>/dev/null | grep -q '^#!'; then
    mkdir -p /var/luna 2>/dev/null
    [ -f /var/luna/setcpushares-task.tls13-orig ] || cp -p "$ST" /var/luna/setcpushares-task.tls13-orig
    mv -f "$ST" "$ST.real"
    cp -f "$STW" "$ST"; chmod 755 "$ST"
    if [ -s "$ST" ] && [ -f "$ST.real" ]; then
        echo "luna-tls13: installed setcpushares-task env-scrub wrapper (App-Manager installs/removes work under LunaCE)."
    else
        echo "luna-tls13 ERROR: setcpushares-task wrapper install failed -- restoring stock script."
        mv -f "$ST.real" "$ST" 2>/dev/null
    fi
else
    echo "luna-tls13 WARNING: $ST has no shebang and no .real exists -- looks like a stray wrapper, not the stock script. NOT wrapping."
fi
# ---- end setcpushares-task fix -------------------------------------------------
EOF
fi  # fam=3 : LunaCE env-scrub wrapper postinst blocks
cat >> "$B4/control/postinst" <<'EOF'

# ---- LunaSysMgr launcher: route app WebKit through ssl11 --
if grep -q 'ssl11/libssl_compat.so' "$L" 2>/dev/null && grep -q 'LD_BIND_NOW=1' "$L" 2>/dev/null; then
    echo "luna-tls13: LunaSysMgr launcher already patched (ssl11 + LD_BIND_NOW). REBOOT to activate the media fix if you have not rebooted since this install."
    exit 0
fi
mkdir -p /var/luna 2>/dev/null
[ -f /var/luna/LunaSysMgr.tls13-orig ] || cp -p "$L" /var/luna/LunaSysMgr.tls13-orig
if grep -q 'ssl11/libssl_compat.so' "$L" 2>/dev/null; then
    # older luna-tls13 (1.0.0) already added the ssl11 exports; just add LD_BIND_NOW.
    # LD_BIND_NOW=1: eager PLT binding, so LunaSysMgr/WebAppMgr resolve every symbol at
    # exec instead of SIGSEGVing in the glibc-2.8 linker while LAZY-binding across the
    # 0.9.8->1.1 shim. (The media worker no longer relies on this -- it's scrubbed above.)
    awk '/export LD_LIBRARY_PATH=\/usr\/lib\/ssl11/ && !bn { print; print "\texport LD_BIND_NOW=1"; bn=1; next } { print }' \
        "$L" > /tmp/lsm.bn.$$ && cat /tmp/lsm.bn.$$ > "$L"
    rm -f /tmp/lsm.bn.$$
else
    awk '
/export LD_PRELOAD="/ {
    sub(/"[ \t]*$/, " /usr/lib/ssl11/libssl_compat.so\"")
    print
    print "\texport LD_LIBRARY_PATH=/usr/lib/ssl11"
    print "\texport LD_BIND_NOW=1"
    next
}
{ print }
' "$L" > /tmp/lsm.tls13.$$ && cat /tmp/lsm.tls13.$$ > "$L"
    rm -f /tmp/lsm.tls13.$$
fi
if grep -q 'ssl11/libssl_compat.so' "$L" && grep -q 'LD_LIBRARY_PATH=/usr/lib/ssl11' "$L" && grep -q 'LD_BIND_NOW=1' "$L"; then
    echo "luna-tls13: patched LunaSysMgr launcher (ssl11 + LD_BIND_NOW). REBOOT to route app WebKit through OpenSSL 1.1 / TLS 1.3 (and to activate the media fix)."
else
    echo "luna-tls13 WARNING: LD_PRELOAD anchor not found; restoring stock launcher (no change)."
    cp -f /var/luna/LunaSysMgr.tls13-orig "$L"
    exit 1
fi
exit 0
EOF

cat > "$B4/control/prerm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
L=/etc/event.d/LunaSysMgr
EOF
# webOS 3.0.5 (LunaCE) only: restore the three env-scrub wrappers. webOS 2.x skips them.
if [ "$fam" = 3 ]; then
cat >> "$B4/control/prerm" <<'EOF'

# restore media-pipeline: move the real binary back over the wrapper, drop the .real
# roles. (.real is the untouched real binary; the /var/luna copy is a secondary backup.)
MP=/usr/bin/media-pipeline
if [ -f "$MP.real" ]; then
    mv -f "$MP.real" "$MP"
elif [ -f /var/luna/media-pipeline.stock-orig ]; then
    cp -f /var/luna/media-pipeline.stock-orig "$MP"; chmod 755 "$MP"
fi
rm -f /var/luna/media-pipeline.stock-orig
rm -f /usr/share/ls2/roles/prv/com.palm.mediad.pipeline.real.json \
      /usr/share/ls2/roles/pub/com.palm.mediad.pipeline.real.json
/usr/bin/ls-control scan-services 2>/dev/null || true

# restore setcpushares-pdk: move the stock script back over the wrapper.
SP=/usr/sbin/setcpushares-pdk
if [ -f "$SP.real" ]; then
    mv -f "$SP.real" "$SP"
elif [ -f /var/luna/setcpushares-pdk.tls13-orig ]; then
    cp -f /var/luna/setcpushares-pdk.tls13-orig "$SP"; chmod 755 "$SP"
fi
rm -f /var/luna/setcpushares-pdk.tls13-orig

# restore setcpushares-task: move the stock script back over the wrapper.
ST=/usr/sbin/setcpushares-task
if [ -f "$ST.real" ]; then
    mv -f "$ST.real" "$ST"
elif [ -f /var/luna/setcpushares-task.tls13-orig ]; then
    cp -f /var/luna/setcpushares-task.tls13-orig "$ST"; chmod 755 "$ST"
fi
rm -f /var/luna/setcpushares-task.tls13-orig
EOF
fi  # fam=3 : LunaCE env-scrub wrapper prerm restores
cat >> "$B4/control/prerm" <<'EOF'
if [ -f /var/luna/LunaSysMgr.tls13-orig ]; then
    cp -f /var/luna/LunaSysMgr.tls13-orig "$L"
    rm -f /var/luna/LunaSysMgr.tls13-orig
    echo "luna-tls13: restored stock LunaSysMgr launcher + media-pipeline. REBOOT to return app TLS to stock."
else
    awk '
    /export LD_PRELOAD="/ { gsub(/ \/usr\/lib\/ssl11\/libssl_compat.so/, ""); print; next }
    /export LD_LIBRARY_PATH=\/usr\/lib\/ssl11/ { next }
    /export LD_BIND_NOW=1/ { next }
    { print }
    ' "$L" > /tmp/lsm.unp.$$ && cat /tmp/lsm.unp.$$ > "$L"
    rm -f /tmp/lsm.unp.$$
    echo "luna-tls13: removed patch lines (no backup found). REBOOT to revert."
fi
exit 0
EOF
chmod 0755 "$B4/control/postinst" "$B4/control/prerm"
pack "$B4" "${ID4}_${LUNAVER}_${ARCH}.ipk" "$OUT/$dev"
done  # for dev in $DEVICES
fi  # want luna

############################# mail-tls13 #############################
if want mail; then
# Routes the native mail transports (mojomail-eas/imap/pop/smtp -- where the Email
# app's EAS/IMAP/POP/SMTP sync actually runs) through the OpenSSL 1.1.1w stack, so
# the 2011 mail client can reach modern TLS 1.2/1.3 servers (Zoho, Gmail, etc.).
#
# KEY DESIGN (the long story is in BUILDING.md): mojomail does HTTPS via libcurl
# (EAS) / libpalmsocket (line protocols). Two proven dead ends: (a) ssl11's libcurl
# 7.88.1 SIGSEGVs in curl_multi_remove_handle (mojomail's glibcurl glue was built for
# curl 7.21.7+c-ares, incompatible with the 11-years-newer multi/resolver internals);
# (b) keeping STOCK libcurl 7.21.7 on ssl11 OpenSSL does the TLS1.3 handshake fine but
# SIGSEGVs inspecting the X509 cert (ssl11 OpenSSL only carries libWebKitLuna's offset
# relocation, not libcurl's). FIX: ship a purpose-built libcurl (~7.51-7.61, --enable-
# ares, compiled against OpenSSL 1.1 *headers* so no offset assumptions) into a redirect
# dir /usr/lib/ssl11mail, and point the four launchers there. REQUIRES browser-tls13
# (for /usr/lib/ssl11). No reboot. The libcurl must be cross-built first -- see
# BUILDING.md; if curl-mail/ is absent this package is SKIPPED (not shipped broken).
MAILCURL=""
for f in "$BASE"/curl-mail/lib/.libs/libcurl.so.4.* "$BASE"/curl-mail/libcurl.so.4.*; do
  [ -f "$f" ] && { MAILCURL="$f"; break; }
done
if [ -z "$MAILCURL" ]; then
  echo "  SKIP mail-tls13: no cross-built libcurl at curl-mail/lib/.libs/libcurl.so.4.* (see BUILDING.md)"
else
  MAILCURL_BN="$(basename "$MAILCURL")"
  ID5=org.webosinternals.mail-tls13
  B5="$OUT/_b_mail"; APPDIR5="$B5/data/usr/palm/applications/$ID5"; F5="$APPDIR5/files"
  rm -rf "$B5"; mkdir -p "$B5/control" "$F5/ssl11mail"
  install -m0644 "$MAILCURL" "$F5/ssl11mail/$MAILCURL_BN"
  # mail ships its OWN libssl_compat.so (a superset of the browser's: adds CONF_modules_free
  # + SSL_CTX_get_ex_new_index, which only the mail transports' libpalmsocket/libemail-common
  # need). So mail-tls13 is self-contained for the shim and does NOT require browser-tls13 to
  # be rebuilt/reinstalled -- it only needs ssl11's OpenSSL libs (still a Depends).
  [ -f "$LIBCOMPAT" ] || { echo "ERROR: $LIBCOMPAT missing -- build the shim from openssl_compat_shim.c first" >&2; exit 1; }
  install -m0644 "$LIBCOMPAT" "$F5/ssl11mail/libssl_compat.so"
  cat > "$APPDIR5/appinfo.json" <<EOF
{ "title":"Mail TLS 1.3", "id":"$ID5", "version":"$MAILVER", "vendor":"WebOS Internals",
  "type":"web", "main":"index.html", "icon":"icon.png", "removable":true,
  "noWindow":true, "visible":false }
EOF
  echo '<html><head><title>Mail TLS 1.3</title></head><body></body></html>' > "$APPDIR5/index.html"
  echo "$PNG_B64" | base64 -d > "$APPDIR5/icon.png"

  # No Depends: mail-tls13 is device-INDEPENDENT (one build for every board), but the package
  # that provides /usr/lib/ssl11 is device-specific and therefore differently NAMED per family
  # (browser-tls13 on the TouchPad, browser-tls13-phone on the webOS 2.x phones) -- one Depends
  # line cannot name both, and declaring either would make this package uninstallable on the
  # other family. The requirement is enforced at install time instead: the postinst already
  # refuses (exit 1) unless /usr/lib/ssl11/{libssl_compat.so,libssl.so.1.1} are present, and the
  # tls-updates meta packages supply the install ORDER. Upstream applied the same reasoning to
  # curl-tls13 and ntpdate-sync.
  cat > "$B5/control/control" <<EOF
Package: $ID5
Version: $MAILVER
Architecture: $ARCH
Maintainer: $MAINT
Description: Modern TLS 1.2/1.3 for the webOS mail client (EAS/IMAP/POP/SMTP)
Section: System
Priority: optional
Depends:
Source: { "Type":"Application", "Feed":"WebOS Internals", "Category":"System", "Title":"Mail TLS 1.3", "FullDescription":"Routes the native mail transports (mojomail-eas/imap/pop/smtp) through a purpose-built libcurl (compiled against OpenSSL 1.1.1w) under /usr/lib/ssl11mail, so the stock Email app can sync Exchange ActiveSync/IMAP/POP/SMTP accounts on modern TLS 1.2/1.3 servers (Zoho, Gmail, etc.). Patches the four D-Bus service launchers (backups in /var/luna). v1.3.2 also fixes Gmail (and any ECDSA-certificate) IMAP/POP sign-in that previously failed with a false 'certificate is not trusted' (error 4010): the stock libpalmsocket mis-verifies ECDSA leaf certs, so the imap/pop/smtp launchers now pin TLS 1.2 + an RSA server certificate (full certificate validation is preserved). Note Gmail requires a Google App Password for IMAP. REQUIRES org.webosinternals.browser-tls13 (provides /usr/lib/ssl11) and a current /etc/ssl/certs/ca-certificates.crt. No reboot needed.", "License":"OpenSSL/curl" }
EOF

  # postinst: build the OpenSSL-1.1 redirect dir with OUR libcurl + patch the four
  # launchers. Refuses if the ssl11 stack is absent (so it can't half-apply). Backups
  # go OUTSIDE /etc/event.d. Never touches /usr/lib/ssl11 (browser/curl11 unaffected).
  cat > "$B5/control/postinst" <<EOF
#!/bin/sh
MAILCURL_BN="$MAILCURL_BN"
PID="$ID5"
EOF
  cat >> "$B5/control/postinst" <<'EOF'
[ -z "$IPKG_OFFLINE_ROOT" ] && IPKG_OFFLINE_ROOT=/media/cryptofs/apps
mount -o remount,rw / 2>/dev/null || true
SSL11=/usr/lib/ssl11
MAILDIR=/usr/lib/ssl11mail
if [ ! -f "$SSL11/libssl_compat.so" ] || [ ! -f "$SSL11/libssl.so.1.1" ]; then
    echo "mail-tls13 ERROR: /usr/lib/ssl11 stack not found -- install org.webosinternals.browser-tls13 first. Not patching."
    exit 1
fi
SRC=""
for R in "$IPKG_OFFLINE_ROOT" /media/cryptofs/apps /var ""; do
    d="$R/usr/palm/applications/$PID/files"
    [ -f "$d/ssl11mail/$MAILCURL_BN" ] && { SRC="$d"; break; }
done
[ -n "$SRC" ] || { echo "mail-tls13 ERROR: payload (libcurl) not found -- install failed"; exit 1; }

# 1. redirect dir: OUR libcurl (built vs OpenSSL 1.1 headers) + ssl11 OpenSSL. The 1.1
#    sonames satisfy our libcurl's NEEDED; the 0.9.8 aliases satisfy the OTHER mojomail
#    consumers (libpalmsocket etc.) that still reference the 0.9.8 sonames. libcares.so.2
#    resolves from /usr/lib (the device's). No 7.88 libcurl here.
rm -rf "$MAILDIR"; mkdir -p "$MAILDIR"
cp -f "$SRC/ssl11mail/$MAILCURL_BN" "$MAILDIR/$MAILCURL_BN"; chmod 755 "$MAILDIR/$MAILCURL_BN"
ln -sf "$MAILCURL_BN"            "$MAILDIR/libcurl.so.4"
ln -sf "$SSL11/libssl.so.1.1"    "$MAILDIR/libssl.so.1.1"
ln -sf "$SSL11/libcrypto.so.1.1" "$MAILDIR/libcrypto.so.1.1"
ln -sf "$SSL11/libssl.so.1.1"    "$MAILDIR/libssl.so.0.9.8"
ln -sf "$SSL11/libcrypto.so.1.1" "$MAILDIR/libcrypto.so.0.9.8"
# OUR shim (superset with CONF_modules_free + SSL_CTX_get_ex_new_index that the mail
# transports need) -- a real copy, NOT a symlink to ssl11's, so mail is self-contained
# and unaffected if the installed browser-tls13 ships an older shim.
cp -f "$SRC/ssl11mail/libssl_compat.so" "$MAILDIR/libssl_compat.so"; chmod 755 "$MAILDIR/libssl_compat.so"

# 2. patch the four mojomail D-Bus launchers (idempotent; backup each once to /var/luna)
mkdir -p /var/luna 2>/dev/null
# LD_BIND_NOW=1: force EAGER symbol binding. With lazy binding the mojomail transports
# intermittently SIGSEGV inside the glibc-2.8 dynamic linker (do_lookup_x/check_match)
# while first-resolving a PLT symbol across our shim + the 0.9.8->1.1 aliased OpenSSL
# (proven on SMTP). Resolving everything up-front at exec avoids it.
PFX='/usr/bin/env LD_BIND_NOW=1 LD_LIBRARY_PATH=/usr/lib/ssl11mail LD_PRELOAD=/usr/lib/ssl11mail/libssl_compat.so CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt'
patched=0
for s in eas imap pop smtp; do
    F="/usr/share/dbus-1/system-services/com.palm.$s.service"
    [ -f "$F" ] || continue
    grep -q 'ssl11mail' "$F" 2>/dev/null && { patched=$((patched+1)); continue; }
    cp -p "$F" "/var/luna/com.palm.$s.service.tls13-orig"
    awk -v p="$PFX" '
      /^Exec=\/usr\/bin\/mojomail-/ && $0 !~ /ssl11mail/ { sub(/^Exec=/, "Exec=" p " "); print; next }
      { print }
    ' "$F" > "/tmp/mail.$s.$$" && cat "/tmp/mail.$s.$$" > "$F"
    rm -f "/tmp/mail.$s.$$"
    if grep -q 'ssl11mail' "$F" 2>/dev/null; then
        patched=$((patched+1))
    else
        cp -f "/var/luna/com.palm.$s.service.tls13-orig" "$F"   # restore on failure
        echo "mail-tls13 WARNING: could not patch $F (left stock)."
    fi
done
echo "mail-tls13: patched $patched / 4 mojomail launcher(s)."

# 2b. Gmail / ECDSA-leaf fix (1.3.2). libpalmsocket (stock 0.9.8-built, run on 1.1.1w via our
#     shim) mis-verifies ECDSA (P-256) LEAF certs -- OpenSSL declares the leaf "self signed"
#     (X509_V_ERR=18) at depth 0 and never links it, so IMAP/POP/SMTP validation fails with
#     err 4010. RSA leaves verify fine (full chain). Google's imap./pop.gmail.com serve ECDSA
#     leaves by default, hence Gmail IMAP/POP break while Fastmail (RSA) works. Fix: an OpenSSL
#     system_default config that forces these transports to TLS 1.2 + an RSA cert -- this KEEPS
#     full certificate validation. Applied to imap/pop/smtp only (NOT eas: EAS verifies via
#     libcurl/CurlSSLVerifier, which has no bug -- leave it on TLS 1.3). Both settings are
#     required: under TLS 1.3 Google still serves ECDSA, and libpalmsocket overrides any
#     CipherString (but honors MaxProtocol + SignatureAlgorithms). This step is INDEPENDENT of
#     the ssl11mail-prefix check above (which 'continue's over already-patched launchers on
#     upgrade), so an upgrade from <=1.3.1 still gets OPENSSL_CONF injected.
cat > "$MAILDIR/mailssl.cnf" <<'CNF'
openssl_conf = openssl_init
[openssl_init]
ssl_conf = ssl_sect
[ssl_sect]
system_default = system_default_sect
[system_default_sect]
MaxProtocol = TLSv1.2
SignatureAlgorithms = RSA+SHA256:RSA+SHA384:RSA+SHA512
CNF
chmod 0644 "$MAILDIR/mailssl.cnf"
ecdsa=0
for s in imap pop smtp; do
    F="/usr/share/dbus-1/system-services/com.palm.$s.service"
    [ -f "$F" ] || continue
    grep -q 'OPENSSL_CONF=' "$F" 2>/dev/null && { ecdsa=$((ecdsa+1)); continue; }   # idempotent
    grep -q 'LD_BIND_NOW=1' "$F" 2>/dev/null || continue   # only touch our env-prefixed launchers
    awk '/^Exec=\/usr\/bin\/env / && $0 !~ /OPENSSL_CONF=/ { sub(/LD_BIND_NOW=1 /, "LD_BIND_NOW=1 OPENSSL_CONF=/usr/lib/ssl11mail/mailssl.cnf "); print; next } { print }' "$F" > "/tmp/mailc.$s.$$" && cat "/tmp/mailc.$s.$$" > "$F"
    rm -f "/tmp/mailc.$s.$$"
    if grep -q 'OPENSSL_CONF=' "$F" 2>/dev/null; then ecdsa=$((ecdsa+1)); else echo "mail-tls13 WARNING: could not add OPENSSL_CONF to $F"; fi
done
echo "mail-tls13: ECDSA/Gmail TLS-1.2+RSA config on $ecdsa / 3 (imap/pop/smtp) launcher(s)."

# NOTE: the one-byte mojomail-imap "~A"->"AA" IMAP-tag patch (needed only for strict servers
# like Fastmail that reject '~'-leading tags) is a SEPARATE, optional package --
# org.webosinternals.mojomail-imap-tagfix -- so it can be taken or left independently of this
# TLS stack and won't collide with other mojomail patches. See mojomail-changes.md.

# 3. CA bundle sanity (mail does REAL cert validation -- unlike a plain version bump)
n=$(grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt 2>/dev/null); [ -z "$n" ] && n=0
[ "$n" -lt 50 ] && echo "mail-tls13 WARNING: stale CA bundle ($n certs) -- mail cert checks may fail; install a current ca-certificates."

# 4. reload the service registry + stop running transports so they respawn patched
/usr/bin/ls-control scan-services 2>/dev/null || true
for b in mojomail-eas mojomail-imap mojomail-pop mojomail-smtp; do killall "$b" 2>/dev/null; done
echo "mail-tls13: done. Open Email and refresh an account (or wait for scheduled sync) to test."
exit 0
EOF

  cat > "$B5/control/prerm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
for s in eas imap pop smtp; do
    F="/usr/share/dbus-1/system-services/com.palm.$s.service"
    B="/var/luna/com.palm.$s.service.tls13-orig"
    [ -f "$F" ] || continue
    if [ -f "$B" ]; then
        cp -f "$B" "$F"; rm -f "$B"
    else
        # no backup -- strip our whole env prefix in place: 'env ' + every leading VAR=value
        # token (count varies: eas has 5, imap/pop/smtp have 6 incl. OPENSSL_CONF from 1.3.2)
        awk '/^Exec=\/usr\/bin\/env .*mojomail-/ { sub(/^Exec=\/usr\/bin\/env ([A-Za-z_]+=[^ ]* )+/, "Exec="); print; next } { print }' "$F" > "/tmp/mailu.$s.$$" && cat "/tmp/mailu.$s.$$" > "$F"
        rm -f "/tmp/mailu.$s.$$"
    fi
done
rm -rf /usr/lib/ssl11mail
/usr/bin/ls-control scan-services 2>/dev/null || true
for b in mojomail-eas mojomail-imap mojomail-pop mojomail-smtp; do killall "$b" 2>/dev/null; done
echo "mail-tls13: reverted mojomail launchers to stock."
exit 0
EOF
  chmod 0755 "$B5/control/postinst" "$B5/control/prerm"
  pack "$B5" "${ID5}_${MAILVER}_${ARCH}.ipk"
fi
fi  # want mail

##################### mojomail-imap-tagfix (standalone) #####################
# A take-or-leave, one-byte patch of /usr/bin/mojomail-imap: its hard-coded IMAP command
# tag prefix "~A" -> "AA" (0x7e->0x41 at file offset 991784). mojomail tags commands "~A1",
# "~A2", ...; strict modern servers (e.g. Fastmail) reject a '~' in the tag with an UNTAGGED
# "* BAD invalid command", which mojomail can never match to its pending "~A1" request -> IMAP
# validation hangs 30s (error 3099). "AA1".. is valid everywhere. This is the ONLY change the
# suite makes to a stock mojomail binary, packaged separately from mail-tls13 so it can be
# applied or skipped independently and won't collide with other mojomail patches. Full detail:
# mojomail-changes.md. No payload, no deps -- the postinst patches in place (backup in
# /var/luna); prerm restores. Ships nothing if you don't want to touch the binary: just leave
# this package out.
if want imaptagfix; then
for dev in $DEVICES; do
  sfx="$(tgt_suffix "$dev")"; boards="$(tgt_boards "$dev")"
  ID6="org.webosinternals.mojomail-imap-tagfix$sfx"
  PRODUCT="$(dev_product "$dev")"
  # No payload at all -- the only per-board facts are the byte offset and the two md5s.
  IMAP_CASES=""; staged6=""
  for b in $boards; do
    i_stock="$(dev_imap_stock_md5 "$b")"; i_patched="$(dev_imap_patched_md5 "$b")"; i_off="$(dev_imap_offset "$b")"
    if [ -z "$i_stock" ] || [ -z "$i_patched" ] || [ -z "$i_off" ]; then
      echo "  mojomail-imap-tagfix$sfx: SKIP board $b -- no known mojomail-imap tag offset/md5 (add it to dev_imap_* in the registry)"
      continue
    fi
    echo "  [$dev/$b] $(dev_product "$b"): mojomail-imap-tagfix (offset $i_off, stock $i_stock -> patched $i_patched)"
    IMAP_CASES="$IMAP_CASES  $b) STOCK_IMAP_MD5=$i_stock; PATCHED_IMAP_MD5=$i_patched; IMAP_OFF=$i_off;;
"
    ISTOCK1="$i_stock"; IPATCHED1="$i_patched"; IOFF1="$i_off"
    staged6="$staged6 $b"
  done
  if [ -z "$(printf %s "$staged6" | tr -d ' ')" ]; then
    echo "  mojomail-imap-tagfix$sfx: SKIP $dev -- no board had a known tag offset"
    continue
  fi
  B6="$OUT/_b_imaptag_$dev"; APPDIR6="$B6/data/usr/palm/applications/$ID6"
  rm -rf "$B6"; mkdir -p "$B6/control" "$APPDIR6"
  cat > "$APPDIR6/appinfo.json" <<EOF
{ "title":"Mojomail IMAP Tag Fix", "id":"$ID6", "version":"$IMAPTAGVER", "vendor":"WebOS Internals",
  "type":"web", "main":"index.html", "icon":"icon.png", "removable":true,
  "noWindow":true, "visible":false }
EOF
  echo '<html><head><title>Mojomail IMAP Tag Fix</title></head><body></body></html>' > "$APPDIR6/index.html"
  echo "$PNG_B64" | base64 -d > "$APPDIR6/icon.png"

  cat > "$B6/control/control" <<EOF
Package: $ID6
Version: $IMAPTAGVER
Architecture: $ARCH
Maintainer: $MAINT
Description: Patch mojomail-imap's IMAP command tag (~A -> AA) for strict modern servers
Section: System
Priority: optional
Source: { "Type":"Application", "Feed":"WebOS Internals", "Category":"System", "Title":"Mojomail IMAP Tag Fix ($dev)", "FullDescription":"Optional, standalone one-byte patch of /usr/bin/mojomail-imap on $PRODUCT: changes its hard-coded IMAP command tag prefix from ~A to AA. mojomail tags IMAP commands ~A1, ~A2, ...; some strict modern servers (e.g. Fastmail) reject a tilde in the tag with an untagged BAD response, which the stock client can never match to its request, so IMAP account validation hangs and fails (error 3099). AA1.. is accepted by every server. Independent of the TLS packages -- take it or leave it. md5-guarded to the stock binary, backed up to /var/luna, restored on removal. Useful together with org.webosinternals.mail-tls13 (which provides modern TLS for the mail transports).", "License":"Public Domain" }
EOF

  printf '#!/bin/sh\nIMAPBIN=/usr/bin/mojomail-imap\n' > "$B6/control/postinst"
  if [ -n "$sfx" ]; then
    emit_board_detect >> "$B6/control/postinst"
    cat >> "$B6/control/postinst" <<EOF
case "\$BOARD" in
$IMAP_CASES  *) echo "mojomail-imap-tagfix: ERROR -- this package is for $PRODUCT; board '\$BOARD' is not one of ($staged6 ). Not patching."; exit 1;;
esac
EOF
  else
    cat >> "$B6/control/postinst" <<EOF
STOCK_IMAP_MD5=$ISTOCK1
PATCHED_IMAP_MD5=$IPATCHED1
IMAP_OFF=$IOFF1
EOF
  fi
  cat >> "$B6/control/postinst" <<'EOF'
[ -z "$IPKG_OFFLINE_ROOT" ] && IPKG_OFFLINE_ROOT=/media/cryptofs/apps
mount -o remount,rw / 2>/dev/null || true
mkdir -p /var/luna 2>/dev/null
if [ ! -f "$IMAPBIN" ]; then echo "mojomail-imap-tagfix: $IMAPBIN not found -- nothing to patch."; exit 0; fi
im=$(md5sum "$IMAPBIN" | cut -d' ' -f1)
if [ "$im" = "$STOCK_IMAP_MD5" ]; then
    cp -f "$IMAPBIN" /var/luna/mojomail-imap.tagfix-orig
    # Patch a SAME-FILESYSTEM temp copy then atomically mv over the original. An in-place dd
    # fails ETXTBSY while mojomail-imap is running (dbus-activated); rename(2) replaces the
    # dir entry safely (the live process keeps the old inode until it respawns -- killall below).
    cp -f "$IMAPBIN" "$IMAPBIN.tagfixnew"
    printf 'A' | dd of="$IMAPBIN.tagfixnew" bs=1 seek=$IMAP_OFF count=1 conv=notrunc 2>/dev/null
    nm=$(md5sum "$IMAPBIN.tagfixnew" | cut -d' ' -f1)
    if [ "$nm" = "$PATCHED_IMAP_MD5" ]; then
        chmod 755 "$IMAPBIN.tagfixnew"; mv -f "$IMAPBIN.tagfixnew" "$IMAPBIN"
        echo "mojomail-imap-tagfix: patched IMAP tag (~A->AA)."
    else
        rm -f "$IMAPBIN.tagfixnew" /var/luna/mojomail-imap.tagfix-orig
        echo "mojomail-imap-tagfix ERROR: patch produced unexpected md5 ($nm) -- left stock."
    fi
elif [ "$im" = "$PATCHED_IMAP_MD5" ]; then
    echo "mojomail-imap-tagfix: already patched."
else
    echo "mojomail-imap-tagfix NOTE: mojomail-imap md5 $im unrecognized -- NOT patching (a different build, or another mojomail patch is present). Left untouched."
fi
/usr/bin/ls-control scan-services 2>/dev/null || true
killall mojomail-imap 2>/dev/null
exit 0
EOF

  cat > "$B6/control/prerm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
if [ -f /var/luna/mojomail-imap.tagfix-orig ]; then
    cp -f /var/luna/mojomail-imap.tagfix-orig /usr/bin/mojomail-imap
    rm -f /var/luna/mojomail-imap.tagfix-orig
    echo "mojomail-imap-tagfix: restored stock mojomail-imap."
fi
killall mojomail-imap 2>/dev/null
exit 0
EOF
  chmod 0755 "$B6/control/postinst" "$B6/control/prerm"
  pack "$B6" "${ID6}_${IMAPTAGVER}_${ARCH}.ipk" "$OUT/$dev"
done  # for dev in $DEVICES
fi  # want imaptagfix

############################# downloadmgr-tls13 #############################
# The system Download Manager (/usr/bin/LunaDownloadMgr, com.palm.downloadmanager)
# does ALL its HTTP(S) transfers -- downloads AND uploads -- through libcurl and
# links NO OpenSSL directly (its only TLS-bearing NEEDED is libcurl.so.4). So an
# RPATH onto a modern libcurl is all it takes to move the whole service to TLS
# 1.2/1.3; no code patch to the 2011 binary. We reuse the mail package's libcurl
# 7.61.1 (built vs OpenSSL 1.1.1w, --enable-ares to match the DM's c-ares resolver,
# and --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt). That baked-in CA bundle
# is load-bearing: the daemon hard-codes CURLOPT_CAPATH=/var/ssl/trustedcerts, a
# directory hashed by the device's OpenSSL 0.9.8 whose subject hashes OpenSSL 1.1
# cannot find -- so without a baked default CAINFO, modern certs would read as
# "unable to get local issuer certificate" even though TLS negotiated fine.
# Header note: uploads already accept a native customHttpHeaders array; downloads
# gain arbitrary request headers (Authorization/Bearer JWT, X-Auth-Token, ...) via
# the cookieHeader multi-line convention documented in downloadmgr-tls13/README.md
# (curl 7.61.1 emits any line after the first as a real request header) -- also no
# binary patch. RPATH = /usr/lib/ssl11dl (our libcurl) : /usr/lib/ssl11 (browser-
# tls13's OpenSSL); DT_RPATH so it also covers libcurl's transitive libssl load.
if want downloadmgr; then
for dev in $DEVICES; do
sfx="$(tgt_suffix "$dev")"; boards="$(tgt_boards "$dev")"
ID7="org.webosinternals.downloadmgr-tls13$sfx"
PRODUCT="$(dev_product "$dev")"
B7="$OUT/_b_dlmgr_$dev"; rm -rf "$B7"; APPDIR7="$B7/data/usr/palm/applications/$ID7"; F7="$APPDIR7/files"
mkdir -p "$B7/control" "$F7/ssl11dl"
# One RPATH'd LunaDownloadMgr per bundled board (flat name for a single-board target,
# so those ipks stay byte-identical to previous builds).
DL_CASES=""; staged7=""
for b in $boards; do
  dl="$(downloadmgr_for "$b")" || dl=""
  pre=""
  [ -z "$dl" ] && { pre="$(prebuilt_rpath "$b" downloadmgr-tls13 "$DOWNVER" LunaDownloadMgr.rpath)" || pre=""; }
  if [ -z "$dl" ] && [ -z "$pre" ]; then
    echo "  downloadmgr-tls13$sfx: SKIP board $b -- no stock LunaDownloadMgr (devices/$b/LunaDownloadMgr.bin) and no prebuilt ipks/$b/ ipk to reuse"
    continue
  fi
  if [ -n "$sfx" ]; then dlf="LunaDownloadMgr.rpath.$b"; else dlf="LunaDownloadMgr.rpath"; fi
  if [ -n "$dl" ]; then
    s_md5="$(md5sum "$dl" | cut -d' ' -f1)"
    cp "$dl" "$F7/$dlf"; chmod 0644 "$F7/$dlf"
    patchelf --force-rpath --set-rpath '/usr/lib/ssl11dl:/usr/lib/ssl11' "$F7/$dlf"
  else
    s_md5="$(dev_dlmgr_md5 "$b")"       # no stock binary here; take its md5 from the registry
    cp "$pre" "$F7/$dlf"; chmod 0644 "$F7/$dlf"; rm -f "$pre"
    echo "  [$dev/$b] reusing the already-RPATH'd LunaDownloadMgr from ipks/$b (no stock binary in this checkout)"
  fi
  r_md5=$(md5sum "$F7/$dlf" | cut -d' ' -f1)   # so postinst never backs up our own binary as "stock"
  echo "  [$dev/$b] $(dev_product "$b"): stock $s_md5 -> RPATH'd $r_md5"
  DL_CASES="$DL_CASES  $b) DL_FILE=$dlf; STOCK_DLMGR_MD5=$s_md5; RPATH_DLMGR_MD5=$r_md5;;
"
  DL_FILE1="$dlf"; DSTOCK1="$s_md5"; DRPATH1="$r_md5"
  staged7="$staged7 $b"
done
if [ -z "$(printf %s "$staged7" | tr -d ' ')" ]; then
  echo "  downloadmgr-tls13$sfx: SKIP $dev -- no board had a stock LunaDownloadMgr"
  rm -rf "$B7"; continue
fi
install -m0644 "$MAIL_LIBCURL" "$F7/ssl11dl/libcurl.so.4.5.0"

cat > "$APPDIR7/appinfo.json" <<EOF
{ "title":"Download Manager TLS 1.3", "id":"$ID7", "version":"$DOWNVER", "vendor":"WebOS Internals",
  "type":"web", "main":"index.html", "icon":"icon.png", "removable":true,
  "noWindow":true, "visible":false }
EOF
echo '<html><head><title>Download Manager TLS 1.3</title></head><body></body></html>' > "$APPDIR7/index.html"
echo "$PNG_B64" | base64 -d > "$APPDIR7/icon.png"

cat > "$B7/control/control" <<EOF
Package: $ID7
Version: $DOWNVER
Architecture: $ARCH
Maintainer: $MAINT
Description: Modern TLS 1.2/1.3 for the webOS Download Manager on $PRODUCT (downloads and uploads)
Section: System
Priority: optional
Depends: org.webosinternals.browser-tls13$sfx
Source: { "Type":"Application", "Feed":"WebOS Internals", "Category":"System", "Title":"Download Manager TLS 1.3 ($dev)", "FullDescription":"Routes the system Download Manager (com.palm.downloadmanager / /usr/bin/LunaDownloadMgr) on $PRODUCT through modern TLS so background downloads AND uploads reach today's HTTPS servers. LunaDownloadMgr does all its transfers via libcurl and links no OpenSSL directly, so it is simply RPATH'd (/usr/lib/ssl11dl:/usr/lib/ssl11) onto a modern libcurl 7.61.1 (OpenSSL 1.1.1w + c-ares + a baked-in CA bundle) -- no patch to the binary's code. The baked CA bundle is required because the daemon hard-codes an OpenSSL-0.9.8-hashed CAPATH that OpenSSL 1.1 cannot read. On the TouchPad this is hardware-proven (downloads negotiate TLS 1.3, modern/Let's Encrypt certificates validate, multipart uploads return 200). Bonus: downloads can now send arbitrary request headers (Authorization: Bearer <JWT>, X-Auth-Token, ...) via the cookieHeader multi-line convention (uploads already accept a customHttpHeaders array). REQUIRES org.webosinternals.browser-tls13 (provides /usr/lib/ssl11 OpenSSL); a current /etc/ssl/certs/ca-certificates.crt (e.g. com.palm.rootcertsupdate) and a correct clock (org.webosinternals.ntpdate-sync) are needed for cert validation. Remove this BEFORE browser-tls13. No reboot needed.", "License":"OpenSSL/curl" }
EOF

printf '#!/bin/sh\n' > "$B7/control/postinst"
if [ -n "$sfx" ]; then
  emit_board_detect >> "$B7/control/postinst"
  cat >> "$B7/control/postinst" <<EOF
case "\$BOARD" in
$DL_CASES  *) echo "downloadmgr-tls13: ERROR -- this package is for $PRODUCT; board '\$BOARD' is not one of ($staged7 ). Not patching."; exit 1;;
esac
PID="$ID7"
EOF
else
  cat >> "$B7/control/postinst" <<EOF
DL_FILE="$DL_FILE1"
STOCK_DLMGR_MD5="$DSTOCK1"
RPATH_DLMGR_MD5="$DRPATH1"
PID="$ID7"
EOF
fi
cat >> "$B7/control/postinst" <<'EOF'
[ -z "$IPKG_OFFLINE_ROOT" ] && IPKG_OFFLINE_ROOT=/media/cryptofs/apps
mount -o remount,rw / 2>/dev/null || true
SRC=""
for R in "$IPKG_OFFLINE_ROOT" /media/cryptofs/apps /var ""; do
    d="$R/usr/palm/applications/$PID/files"
    [ -d "$d/ssl11dl" ] && { SRC="$d"; break; }
done
[ -n "$SRC" ] || { echo "ERROR: downloadmgr-tls13 payload not found - install failed"; exit 1; }

# HARD PREREQ: browser-tls13's OpenSSL under /usr/lib/ssl11. Our libcurl NEEDs
# libssl.so.1.1/libcrypto.so.1.1 from there; without it LunaDownloadMgr can't
# start and ALL downloads break. Refuse to patch (can't brick on wrong order).
if [ ! -f /usr/lib/ssl11/libssl.so.1.1 ]; then
    echo "ERROR: /usr/lib/ssl11 not found -- install org.webosinternals.browser-tls13 first."
    exit 1
fi

# 1. install our modern libcurl into a package-private dir (symlink made here --
#    the offline-root fs rejects symlink creation during ipkg unpack)
rm -rf /usr/lib/ssl11dl; mkdir -p /usr/lib/ssl11dl
cp -f "$SRC/ssl11dl/libcurl.so.4.5.0" /usr/lib/ssl11dl/
chmod 755 /usr/lib/ssl11dl/libcurl.so.4.5.0
ln -sf libcurl.so.4.5.0 /usr/lib/ssl11dl/libcurl.so.4

# 2. back up the stock LunaDownloadMgr ONCE (only if no backup yet AND it isn't
#    already our RPATH'd build), then swap ours in. Mirrors browser-tls13 so the
#    package stays cleanly uninstallable even over a non-stock daemon.
cur=$(md5sum /usr/bin/LunaDownloadMgr 2>/dev/null | cut -d' ' -f1)
if [ ! -f /var/luna/LunaDownloadMgr.tls13-orig ] && [ "$cur" != "$RPATH_DLMGR_MD5" ] && [ -f /usr/bin/LunaDownloadMgr ]; then
    mkdir -p /var/luna 2>/dev/null
    cp -p /usr/bin/LunaDownloadMgr /var/luna/LunaDownloadMgr.tls13-orig
    [ "$cur" = "$STOCK_DLMGR_MD5" ] || echo "NOTE: backed up a non-stock LunaDownloadMgr ($cur) as the uninstall restore point."
fi
cp -f "$SRC/$DL_FILE" /usr/bin/LunaDownloadMgr
chmod 0750 /usr/bin/LunaDownloadMgr

# 3. CA bundle sanity (validation relies on the baked default bundle)
n=$(grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt 2>/dev/null); [ -z "$n" ] && n=0
[ "$n" -lt 50 ] && echo "WARNING: stale CA bundle ($n certs) -- install a current Mozilla ca-certificates ipk (downloads won't validate modern certs otherwise)."

# 4. restart the Download Manager upstart job so the change takes effect (no reboot)
stop LunaDownloadMgr 2>/dev/null || true
i=0; while [ $i -lt 8 ]; do ps=$(pidof LunaDownloadMgr 2>/dev/null); [ -z "$ps" ] && break; for p in $ps; do kill -9 $p 2>/dev/null; done; i=$((i+1)); sleep 1; done
start LunaDownloadMgr 2>/dev/null || true
exit 0
EOF

cat > "$B7/control/prerm" <<'EOF'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
stop LunaDownloadMgr 2>/dev/null || true
i=0; while [ $i -lt 8 ]; do ps=$(pidof LunaDownloadMgr 2>/dev/null); [ -z "$ps" ] && break; for p in $ps; do kill -9 $p 2>/dev/null; done; i=$((i+1)); sleep 1; done
# Restore stock ONLY if we have the backup; otherwise the live LunaDownloadMgr is
# our RPATH'd one and removing /usr/lib/ssl11dl would leave it unable to load its
# libcurl (dead download service) -- so keep the lib in place.
if [ -f /var/luna/LunaDownloadMgr.tls13-orig ]; then
    mv -f /var/luna/LunaDownloadMgr.tls13-orig /usr/bin/LunaDownloadMgr
    chmod 0750 /usr/bin/LunaDownloadMgr
    rm -rf /usr/lib/ssl11dl
else
    echo "WARNING: no LunaDownloadMgr.tls13-orig backup; keeping /usr/lib/ssl11dl so downloads keep working."
fi
start LunaDownloadMgr 2>/dev/null || true
exit 0
EOF
chmod 0755 "$B7/control/postinst" "$B7/control/prerm"
pack "$B7" "${ID7}_${DOWNVER}_${ARCH}.ipk" "$OUT/$dev"
done  # for dev in $DEVICES
fi  # want downloadmgr

echo "=== output ==="
ls -1 "$OUT"/*.ipk 2>/dev/null | sed 's#^#  #'
for d in $ALL_DEVICES; do [ -d "$OUT/$d" ] && ls -1 "$OUT/$d"/*.ipk 2>/dev/null | sed "s#^#  #"; done
true
