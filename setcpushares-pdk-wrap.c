/* setcpushares-pdk env-scrub wrapper  (org.webosinternals.luna-tls13)
 * ---------------------------------------------------------------------------
 * Every PDK app is launched by LunaSysMgr through /usr/sbin/setcpushares-pdk.
 * luna-tls13 >= 1.1.0 exports LD_BIND_NOW=1 (plus the ssl11 LD_PRELOAD /
 * LD_LIBRARY_PATH) in the LunaSysMgr upstart launcher so app WebKit gets
 * modern TLS.  Those variables leak into every PDK child.
 *
 * Under LunaCE this is fatal: LunaCE's LunaSysMgr launches PDK children with
 * LD_PRELOAD=libpvrtc.so, a stock lib with lazily-unresolved NApp_* symbols.
 * The leaked LD_BIND_NOW=1 forces eager binding, so /bin/sh (the interpreter
 * of this very script's original) dies at load with
 *   "symbol lookup error: /usr/lib/libpvrtc.so: undefined symbol:
 *    NApp_GetPortabilityValue"  -> exit 127, and the app never starts
 * (hit: QupZilla / the nizovn Qt5 stack).  Under stock Luna the leaked ssl11
 * LD_PRELOAD shim likewise crashes nizovn-glibc apps.
 *
 * Fix: this wrapper is installed AS /usr/sbin/setcpushares-pdk; the stock
 * script is moved aside to /usr/sbin/setcpushares-pdk.real.  It surgically
 * removes ONLY what luna-tls13 added -- LD_BIND_NOW, the libssl_compat.so
 * preload entry, and the /usr/lib/ssl11 library-path entry -- leaving
 * whatever launch environment the (stock or LunaCE) sysmgr intended,
 * then execs the real script.  PDK apps thus launch exactly as they did
 * before the TLS stack existed, while WebKit keeps full TLS.
 *
 * Static ELF: no shared-lib dependencies, immune to the very LD_* poisoning
 * it is here to remove.
 */
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

/* Retained literal so the installer can positively identify an already-wrapped
 * setcpushares-pdk regardless of the wrapper's md5. */
__attribute__((used))
static const char wrap_marker[] = "webos-tls13-setcpushares-pdk-envscrub-wrapper";

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

    execv("/usr/sbin/setcpushares-pdk.real", argv);
    _exit(127);   /* only reached if exec fails */
}
