# Modern TLS (OpenSSL 1.1.1w / TLS 1.2+1.3) for the webOS TouchPad

The 2011 HP TouchPad (webOS 3.0.5) ships OpenSSL 0.9.8, which can no longer
complete a TLS handshake with essentially any modern HTTPS server. This suite
brings a process-private **OpenSSL 1.1.1w + curl 7.88.1** stack to the device and
wires the browser, the app WebKit layer, and the command line into it.

## Packages — install in this order

| # | Package | Ver | What it does | Notes |
|---|---------|-----|--------------|-------|
| 1 | `org.webosinternals.browser-tls13` | 1.1.1 | Installs the OpenSSL 1.1.1w + curl stack under `/usr/lib/ssl11` and swaps the stock **Browser** (`BrowserServer`, RPATH'd) to use it. | **Install first** — it provides `/usr/lib/ssl11` that #2 and #3 build on. Self-restarts the browser. |
| 2 | `org.webosinternals.luna-tls13` | 1.0.0 | Routes the **app WebKit host** (`LunaSysMgr` / `WebAppMgr` — where Mojo/Enyo `XMLHttpRequest` and `enyo.WebService` run) through `/usr/lib/ssl11`, so in-app HTTPS negotiates TLS 1.2/1.3. | **Requires #1.** Edits the `LunaSysMgr` upstart launcher. **Reboot required.** |
| 3 | `org.webosinternals.curl-tls13` | 1.0.1 | Modern command-line curl (7.88.1 / OpenSSL 1.1.1w) as **`/usr/bin/curl11`** *and* as **`/usr/bin/curl`** (stock 0.9.8 backed up to `/usr/bin/curl.0.9.8-orig`, restored on uninstall). Wrapper defaults the CA bundle to `/etc/ssl/certs/ca-certificates.crt`. | Standalone, self-contained, reversible. |
| 4 | `org.webosinternals.ntpdate-sync` | 2.0.1 | Upstart job that syncs the clock from public NTP at boot (retry-until-Wi-Fi) and every 6 h, replacing webOS's dead palm.com time sync. | Standalone. Keeps TLS cert validity windows correct. |

`#3` and `#4` can be installed in any order once `#1` is in.

## Requirements

- **A current CA bundle** in `/etc/ssl/certs/ca-certificates.crt` (e.g. install a
  Mozilla `ca-certificates` / `com.palm.rootcertsupdate` package). Without it,
  modern certificates won't validate even though the handshake succeeds.
- `luna-tls13` **requires** `browser-tls13` to be installed first. Its postinst
  refuses to patch (exit 1) if `/usr/lib/ssl11` is absent, so installing out of
  order cannot brick the device — it just no-ops with an error.

## Installing

These are packaged in the webOS-internals App-Manager convention (payload under
`/usr/palm/applications/<id>/`, with `pmPostInstall.script`/`pmPreRemove.script`),
so they install via **Preware**, **WebOS Quick Install**, **App Catalog**, *or*
plain `ipkg install`.

1. Install `browser-tls13`, then `luna-tls13`, then `curl-tls13` / `ntpdate-sync`.
2. **Reboot once** after installing the suite. (`browser-tls13` self-restarts the
   browser, but `luna-tls13`'s launcher change only takes effect on reboot.)

## Verifying

- Push `../tls13-diag.sh` to the device and run `sh tls13-diag.sh` — expect
  `VERDICT: PASS` and `curl: http=200`.
- **Browser:** load any modern HTTPS site.
- **Apps:** open an Enyo/Mojo app that fetches an `https://` API/feed that used to fail.
- **CLI:** `curl https://github.com` or `curl11 https://github.com` (both should return 200; cert verification uses the system CA bundle automatically).

## Uninstalling

Remove in any order; each package restores stock state (`luna-tls13` restores the
launcher, `browser-tls13` restores `BrowserServer`). **Reboot** after removing
`luna-tls13`.

## Recovery (if the UI ever fails to boot)

`novacomd` runs independently of the UI and stays reachable even if `LunaSysMgr`
won't start. Over novacom as root:

```sh
mount -o remount,rw /
cp /var/luna/LunaSysMgr.tls13-orig /etc/event.d/LunaSysMgr   # restore stock launcher
reboot
```

> ⚠️ Never leave a launcher backup **inside** `/etc/event.d/` — upstart runs every
> file in that directory as a job, so a stray copy becomes a duplicate, crash-looping
> `LunaSysMgr`. All backups here live in `/var/luna/`.

---

*Building these ipks from source? See the [project README](../README.md) (developer docs).*
