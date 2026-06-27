#!/bin/sh
# tls13-diag.sh -- diagnose the modern-TLS browser stack on a webOS TouchPad.
# Push to a device and run:  sh /tmp/tls13-diag.sh
# Flags PASS / WARN / FAIL for each thing that varies across devices.

P() { printf '%-22s %s\n' "$1" "$2"; }
STOCK_BS=0786bdf698220aa82a90838e30355c9f      # stock 3.0.5 BrowserServer
RPATH_BS=a56bf4febbb961ce5249ed78caa0bf33      # our RPATH'd BrowserServer
WK_KNOWN=3d90fd6e33e1f382814c653c0e63a6eb      # libWebKitLuna whose offsets we fixed (0xD8 / 0x8)
md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

echo "===== webOS / device ====="
P "build:" "$(cat /etc/palm-build-info 2>/dev/null | head -1)$(grep -h . /etc/os-release 2>/dev/null | head -1)"
P "uptime:" "$(cut -d. -f1 /proc/uptime)s"
P "date:"   "$(date)"

echo "===== package + ssl11 ====="
P "browser-tls13 pkg:" "$(ipkg list_installed 2>/dev/null | grep -o 'browser-tls13 - [0-9.]*' || echo NOT-INSTALLED)"
if [ -d /usr/lib/ssl11 ]; then P "ssl11 dir:" "present"; else P "ssl11 dir:" "FAIL missing"; fi
for f in libssl.so.1.1 libcrypto.so.1.1 libcurl.so.4.8.0 libssl_compat.so; do
  P "  $f:" "$(md5 /usr/lib/ssl11/$f)"
done

echo "===== BrowserServer binary ====="
bm=$(md5 /usr/bin/BrowserServer)
case "$bm" in
  "$RPATH_BS") P "BrowserServer:" "PASS RPATH'd ($bm)";;
  "$STOCK_BS") P "BrowserServer:" "FAIL still STOCK ($bm) -- RPATH swap did NOT apply (postinst skipped or not installed)";;
  *)           P "BrowserServer:" "WARN unknown build ($bm) -- not the 3.0.5 stock our ipk patches; modern TLS will be SKIPPED on this device";;
esac
P "  .tls13-orig backup:" "$(md5 /usr/bin/BrowserServer.tls13-orig)"

echo "===== libWebKitLuna (struct-offset compatibility) ====="
wm=$(md5 /usr/lib/libWebKitLuna.so)
if [ "$wm" = "$WK_KNOWN" ]; then
  P "libWebKitLuna:" "PASS known build ($wm) -- offsets 0xD8/0x8 match"
else
  P "libWebKitLuna:" "WARN DIFFERENT build ($wm) -- its hardcoded SSL struct offsets may NOT be 0xD8/0x8; the custom OpenSSL could crash. PULL THIS FILE for analysis."
fi

echo "===== running browser process ====="
PID=$(pidof BrowserServer | awk '{print $1}')
if [ -n "$PID" ]; then
  P "PID:" "$PID"
  P "on ssl11 (1.1):" "$(grep -c ssl11 /proc/$PID/maps 2>/dev/null) maps  $( [ "$(grep -c ssl11 /proc/$PID/maps)" -ge 4 ] && echo PASS || echo 'FAIL -- running on OLD 0.9.8!')"
  P "real 0.9.8 mapped:" "$(grep -cE '/usr/lib/lib(ssl|crypto)\.so\.0\.9\.8 ' /proc/$PID/maps 2>/dev/null) (want 0)"
else
  P "PID:" "FAIL not running"
fi

echo "===== duplicate-job / churn check ====="
strays=$(ls /etc/event.d/ 2>/dev/null | grep -E '\.(tls13-orig|orig|preua|pre-rpath|bak)$')
if [ -n "$strays" ]; then P "stray event.d jobs:" "FAIL upstart runs these as DUPLICATE launchers -> churn: $strays"; else P "stray event.d jobs:" "PASS none"; fi
P "recent 'already exists':" "$(tail -40 /var/log/messages 2>/dev/null | grep -c 'already exists') (high = churn)"

echo "===== CA bundle ====="
n=$(grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt 2>/dev/null || echo 0)
isrg=$(grep -c 'ISRG Root X1' /etc/ssl/certs/ca-certificates.crt 2>/dev/null || echo 0)
P "cert count:" "$n  $( [ "$n" -ge 50 ] && echo PASS || echo 'FAIL -- stale/stock bundle, modern certs will not validate')"
P "has ISRG Root X1:" "$isrg $( [ "$isrg" -ge 1 ] && echo PASS || echo 'WARN -- no Let'\''s Encrypt root')"

echo "===== clock / ntp ====="
P "ntpdate-sync job:" "$(initctl status ntpdate-sync 2>/dev/null | grep -o 'start/running.*' || echo 'FAIL not running')"
P "last ntpdate:" "$(grep ntpdate /var/log/messages 2>/dev/null | tail -1 | sed 's/.*ntpdate/ntpdate/')"
P "wifi:" "$(pidof wpa_supplicant >/dev/null && echo up || echo down)"

echo "===== crashes ====="
P "BrowserServer SIGSEGV:" "$(dmesg 2>/dev/null | grep -c 'BrowserServer.*received 11') (>0 = crashing -> check newest /var/log/reports/librdx)"

echo "===== end-to-end TLS through the stack ====="
LD_LIBRARY_PATH=/usr/lib/ssl11 curl -s --compressed --max-time 20 --cacert /etc/ssl/certs/ca-certificates.crt \
  -o /dev/null -w 'curl: http=%{http_code} verify=%{ssl_verify_result} (want 200 / 0)\n' https://tweakers.net/ 2>&1 | tail -1

echo "===== summary ====="
echo "FAIL on BrowserServer=STOCK/unknown -> RPATH swap skipped (check BrowserServer md5 vs your build)"
echo "FAIL on ssl11 maps -> browser on 0.9.8 (swap didn't take, or stray job won the race)"
echo "FAIL on CA bundle  -> install the Mozilla ca-certificates ipk"
echo "WARN on libWebKitLuna different -> send me that file; offsets may need a per-build OpenSSL"
