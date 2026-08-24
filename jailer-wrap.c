/* jailer env-scrub wrapper  (org.webosinternals.luna-tls13, webOS 2.x)
 * ---------------------------------------------------------------------------
 * On webOS 2.2.4 phones (Pre 3 / Pre 2 / Veer) every PDK app -- any app whose
 * appinfo.json type is pdk/native, i.e. the "Linux binary" apps -- is launched
 * by LunaSysMgr as:
 *     /usr/bin/jailer -t pdk -i <appId> -p <appDir> <binary> <binary>
 * and LunaSysMgr COMPOSES that child's environment: it overrides LD_PRELOAD to
 * "libpvrtc.so" and LD_LIBRARY_PATH to the app's own directory, but passes the
 * rest of its own environment through.  Captured from hardware (Pre 3, stock
 * 2.2.4 sysmgr, via a static tracer swapped in as /usr/bin/jailer):
 *     LD_PRELOAD=libpvrtc.so
 *     LD_LIBRARY_PATH=/media/cryptofs/apps/usr/palm/applications/<app>
 *     LD_BIND_NOW=1            <-- leaked from the luna-tls13 launcher patch
 *
 * luna-tls13 exports LD_BIND_NOW=1 in the LunaSysMgr upstart launcher so app
 * WebKit resolves every symbol at exec instead of SIGSEGVing in the glibc-2.8
 * linker while lazy-binding across the 0.9.8->1.1 shim.  It leaks into this
 * spawn, and libpvrtc.so is a stock lib with lazily-unresolved NApp_* symbols,
 * so eager binding turns them into a load error:
 *     /usr/bin/jailer: symbol lookup error: /usr/lib/libpvrtc.so:
 *     undefined symbol: NApp_GetPortabilityValue     -> exit 127
 * jailer dies BEFORE main(), so the jail is never built and the app binary is
 * never exec'd: PDK apps simply do not start (applicationManager/launch still
 * returns a processId -- the death is in the child).  Proven on hardware by
 * A/B: that exact env kills jailer; the same env minus LD_BIND_NOW launches the
 * app normally.
 *
 * Same root cause and fix shape as setcpushares-pdk-wrap (webOS 3.0.5 / LunaCE)
 * and setcpushares-task-wrap (the App-Manager install path) -- a DIFFERENT
 * spawn helper.  webOS 2.x has no setcpushares-pdk at all; jailer IS the PDK
 * launch path there, so this is the wrapper that fixes it.
 *
 * Fix: this wrapper is installed AS /usr/bin/jailer; the stock binary is moved
 * aside to /usr/bin/jailer.real.  It removes ONLY what luna-tls13 added --
 * LD_BIND_NOW, the libssl_compat.so preload entry, and the /usr/lib/ssl11
 * library-path entry -- leaving the rest of the env LunaSysMgr composed (incl.
 * libpvrtc, now harmless because its symbols are lazy again), then execs the
 * real jailer, whose scrubbed env carries into the jailed app.  App WebKit
 * keeps full TLS (LunaSysMgr's own env is untouched); only this spawn is
 * scrubbed -- and PDK apps never used our OpenSSL anyway (they get the app
 * directory as LD_LIBRARY_PATH, not /usr/lib/ssl11).
 *
 * Static ELF: no shared-lib dependencies, immune to the very LD_* poisoning it
 * is here to remove (and so unaffected by the libpvrtc preload itself).
 */
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

/* Retained literal so the installer can positively identify an already-wrapped
 * jailer regardless of the wrapper's md5. */
__attribute__((used))
static const char wrap_marker[] = "webos-tls13-jailer-envscrub-wrapper";

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

    execv("/usr/bin/jailer.real", argv);
    _exit(127);   /* only reached if exec fails */
}
