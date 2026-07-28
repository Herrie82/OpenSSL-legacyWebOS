/* setcpushares-task env-scrub wrapper  (org.webosinternals.luna-tls13)
 * ---------------------------------------------------------------------------
 * LunaSysMgr's App-Manager install/remove path (com.palm.appinstaller, which
 * Preware's `installSvc`/`replaceSvc` and WOSQI both drive) runs the installer
 * through the cpu-shares helper:
 *     /usr/sbin/setcpushares-task  /usr/bin/ApplicationInstallerUtility -c install -p <ipk> ...
 * setcpushares-task is a #!/bin/sh script, so the kernel execs /bin/sh to run it.
 *
 * luna-tls13 exports LD_BIND_NOW=1 (plus the ssl11 LD_PRELOAD / LD_LIBRARY_PATH)
 * in the LunaSysMgr upstart launcher so app WebKit gets modern TLS.  Those leak
 * into the children LunaSysMgr spawns.  On LunaCE the install child's env is
 * composed with LD_PRELOAD=libpvrtc.so -- a stock lib with lazily-unresolved
 * NApp_* symbols.  The leaked LD_BIND_NOW=1 forces eager binding, so /bin/sh
 * (running setcpushares-task) dies at load with
 *   "symbol lookup error: /usr/lib/libpvrtc.so: undefined symbol:
 *    NApp_GetPortabilityValue"  -> exit 127 (status 32512), BEFORE the real
 * installer ever runs.  LunaSysMgr logs "util_ipkgInstallDone(): unknown return
 * code 127" and the install FAILS.  com.palm.appinstaller then drops its
 * connection, so the caller's subscription never gets a clean terminal response:
 * Preware's `luna-send ... appinstaller/installNoVerify` blocks forever and
 * Preware wedges ("stuck IPKG lock").  Same root cause and fix shape as the
 * PDK-app death handled by setcpushares-pdk-wrap -- a DIFFERENT cpu-shares
 * helper (this one is the install/task path; that one is the PDK-launch path).
 * Confirmed on hardware: composed env = { LD_BIND_NOW=1, LD_PRELOAD=libpvrtc.so };
 * stripping LD_BIND_NOW makes libpvrtc's symbols lazy again and the install
 * runs to SUCCESS.
 *
 * Fix: this wrapper is installed AS /usr/sbin/setcpushares-task; the stock
 * script is moved aside to /usr/sbin/setcpushares-task.real.  It surgically
 * removes ONLY what luna-tls13 added -- LD_BIND_NOW, the libssl_compat.so
 * preload entry, and the /usr/lib/ssl11 library-path entry -- leaving the rest
 * of whatever env the (stock or LunaCE) sysmgr composed (incl. libpvrtc, now
 * harmless), then execs the real script, whose scrubbed env propagates to the
 * whole install subtree (ApplicationInstallerUtility -> ipkg -> postinst sh).
 * App WebKit keeps full TLS (its env is untouched); only this spawn is scrubbed.
 *
 * Static ELF: no shared-lib dependencies, immune to the very LD_* poisoning it
 * is here to remove (a shell scrub cannot outrun an env that kills /bin/sh).
 */
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

/* Retained literal so the installer can positively identify an already-wrapped
 * setcpushares-task regardless of the wrapper's md5. */
__attribute__((used))
static const char wrap_marker[] = "webos-tls13-setcpushares-task-envscrub-wrapper";

/* Remove every whitespace/colon-separated token containing `needle` from the
 * value of env var `name`, rejoining survivors with `sep`; unset the var if
 * nothing is left. */
static void strip_entry(const char *name, const char *needle, const char *sep)
{
    const char *val = getenv(name);
    char *out, *copy, *tok;
    size_t len;

    if (!val || !strstr(val, needle))
        return;

    len = strlen(val);
    out = malloc(len + 1);
    if (!out) {                 /* can't scrub -> drop the var entirely */
        unsetenv(name);
        return;
    }
    out[0] = '\0';

    copy = strdup(val);
    if (!copy) {
        free(out);
        unsetenv(name);
        return;
    }
    for (tok = strtok(copy, " :"); tok; tok = strtok(NULL, " :")) {
        if (strstr(tok, needle))
            continue;
        if (out[0])
            strcat(out, sep);
        strcat(out, tok);
    }
    if (out[0])
        setenv(name, out, 1);
    else
        unsetenv(name);
    free(copy);
    free(out);
}

int main(int argc, char **argv)
{
    (void)argc;

    /* the three things luna-tls13 adds to the LunaSysMgr environment */
    unsetenv("LD_BIND_NOW");
    strip_entry("LD_PRELOAD", "libssl_compat", " ");
    strip_entry("LD_LIBRARY_PATH", "/usr/lib/ssl11", ":");

    execv("/usr/sbin/setcpushares-task.real", argv);
    _exit(127);   /* only reached if exec fails */
}
