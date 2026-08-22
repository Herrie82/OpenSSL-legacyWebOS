#!/usr/bin/env python3
"""
Neutralise DownloadManager::cbIdleSourceGlibcurlCleanup() in LunaDownloadMgr.

WHY
---
LunaDownloadMgr destroys and recreates its entire curl *multi* handle at runtime,
from a glib idle source, every time the transfer list goes empty:

    cbIdleSourceGlibcurlCleanup():
        ...guard...
        bl g_log                  ; "Restarting glibcurl for cleanup"
        bl shutdownGlibCurl()     ; -> glibcurl_cleanup -> curl_multi_cleanup   (frees the multi)
        bl startupGlibCurl()      ; -> glibcurl_init                            (allocates a new one)

No other libcurl consumer on the device does this. Against the stock libcurl
7.21.7 it was survivable; once the daemon is RPATH'd onto a modern libcurl it
SIGSEGVs in curl_multi_remove_handle, dereferencing a stale multi->msglist.head:

    pc  curl_multi_remove_handle   lr  singlesocket   FaultAddress 0xc8
    <- glibcurl_remove <- DownloadManager::removeTask_dl(unsigned int)

Hardware-proven on webOS CE 3.1.0 (TouchPad), curl 7.61.1. Identical storm of
fast-failing downloads (transfer list empties -> idle restart fires -> immediate
re-add), one variable changed:

    list allowed to empty        58 glibcurl restarts    28 crashes / 60 iters
    one download held open        0 glibcurl restarts     0 crashes / 30 iters

THE PATCH
---------
Make the guard branch that already skips the restart path unconditional, so the
teardown/recreate becomes dead code and the multi handle simply lives for the
lifetime of the process (what every other consumer does):

    beq <tail>   ->   b <tail>        (one condition-code nibble, 0x0 -> 0xE)

Measured after the patch on-device: same 60-iteration storm -> 0 crashes, 0 new
rdxd reports. No regression -- transfers still run at full speed, RSS 7092 ->
6940 kB and open fds 27 -> 27 across 40 further transfer cycles, i.e. the
"cleanup" was reclaiming nothing (it was almost certainly a workaround for a
curl 7.21.7-era leak that no longer exists).

The site is located structurally via the symbol table -- LunaDownloadMgr is not
stripped -- so this works across the per-board binaries without hardcoded
offsets. It refuses to guess: if the expected shape isn't found, it exits
non-zero rather than shipping an unpatched binary.

NOT APPLICABLE ON webOS 2.x
---------------------------
Only webOS 3.x builds have the runtime restart. On 2.2.4 (Pre 3 / Pre 2 / Veer)
there is no cbIdleSourceGlibcurlCleanup at all: glibcurl_cleanup is reached only
from shutdownGlibCurl, which is called only from ~DownloadManager(), and
startupGlibCurl is guarded by an "already started" flag. The multi handle
therefore outlives every transfer and the bug cannot occur. Verified on the
mantaray/roadrunner/broadway binaries. Those builds exit 3 (not applicable), so a
phone-bundle build is not blocked by a patch it does not need.

Usage:  patch-glibcurl-restart.py <LunaDownloadMgr>   (patches in place)
        patch-glibcurl-restart.py --check <LunaDownloadMgr>
Exit:   0 = patched now, or already patched
        1 = --check: site found and needs patching
        2 = ERROR, site expected but not locatable (build must fail)
        3 = not applicable: this build has no runtime restart path (webOS 2.x)
"""
import struct
import sys

SYM_FN = "_ZN15DownloadManager27cbIdleSourceGlibcurlCleanupEPv"
SYM_DOWN = "_ZN15DownloadManager16shutdownGlibCurlEv"
SYM_UP = "_ZN15DownloadManager15startupGlibCurlEv"


def die(msg):
    sys.stderr.write("patch-glibcurl-restart: ERROR: %s\n" % msg)
    sys.exit(2)


def read_elf(path):
    f = bytearray(open(path, "rb").read())
    if f[:4] != b"\x7fELF" or f[4] != 1 or f[5] != 1:
        die("%s is not a 32-bit little-endian ELF" % path)
    e_shoff = struct.unpack_from("<I", f, 0x20)[0]
    e_shentsize = struct.unpack_from("<H", f, 0x2E)[0]
    e_shnum = struct.unpack_from("<H", f, 0x30)[0]
    e_phoff = struct.unpack_from("<I", f, 0x1C)[0]
    e_phentsize = struct.unpack_from("<H", f, 0x2A)[0]
    e_phnum = struct.unpack_from("<H", f, 0x2C)[0]

    # vaddr -> file offset, via PT_LOAD
    loads = []
    for i in range(e_phnum):
        b = e_phoff + i * e_phentsize
        p_type, p_offset, p_vaddr, _, p_filesz = struct.unpack_from("<IIIII", f, b)
        if p_type == 1:
            loads.append((p_vaddr, p_offset, p_filesz))

    def v2o(va):
        for p_vaddr, p_offset, p_filesz in loads:
            if p_vaddr <= va < p_vaddr + p_filesz:
                return p_offset + (va - p_vaddr)
        die("vaddr 0x%x is not in any PT_LOAD segment" % va)

    # symtab (SHT_SYMTAB == 2), with its linked strtab
    syms = {}
    for i in range(e_shnum):
        b = e_shoff + i * e_shentsize
        sh_type = struct.unpack_from("<I", f, b + 4)[0]
        if sh_type != 2:
            continue
        sh_offset, sh_size, sh_link, _, _, sh_entsize = struct.unpack_from("<IIIIII", f, b + 16)
        stb = e_shoff + sh_link * e_shentsize
        str_off, str_size = struct.unpack_from("<II", f, stb + 16)
        for s in range(sh_offset, sh_offset + sh_size, sh_entsize):
            st_name, st_value, st_size = struct.unpack_from("<III", f, s)
            if st_name == 0:
                continue
            end = f.index(b"\0", str_off + st_name)
            name = f[str_off + st_name:end].decode("ascii", "replace")
            if name in (SYM_FN, SYM_DOWN, SYM_UP):
                syms[name] = (st_value & ~1, st_size)
    if not syms:
        die("%s has no symbol table (stripped?) -- cannot locate the patch site" % path)
    return f, v2o, syms


def bl_target(word, addr):
    """Decode an ARM BL/B; return target vaddr or None."""
    cond = (word >> 28) & 0xF
    op = (word >> 24) & 0xF
    if cond == 0xF or op not in (0xA, 0xB):
        return None
    imm = word & 0x00FFFFFF
    if imm & 0x00800000:
        imm -= 0x01000000
    return addr + 8 + (imm << 2)


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    check_only = "--check" in sys.argv[1:]
    if len(args) != 1:
        sys.stderr.write(__doc__)
        sys.exit(2)
    path = args[0]

    f, v2o, syms = read_elf(path)
    if SYM_FN not in syms:
        # webOS 2.x: no idle restart callback exists, so there is nothing to
        # disable. Distinguish this from a real failure so a mixed-board build
        # is not blocked by a patch that does not apply. Sanity-check that this
        # is a LunaDownloadMgr at all before waving it through.
        if SYM_DOWN not in syms and SYM_UP not in syms:
            die("%s has no glibcurl symbols at all -- is this LunaDownloadMgr?" % path)
        print("%s: NOT APPLICABLE -- no cbIdleSourceGlibcurlCleanup in this build "
              "(webOS 2.x); the curl multi handle is never torn down at runtime"
              % path)
        return 3
    for s in (SYM_DOWN, SYM_UP):
        if s not in syms:
            die("symbol %s not found in %s" % (s, path))
    fn_addr, fn_size = syms[SYM_FN]
    if fn_size == 0:
        fn_size = 0x100
    down_addr = syms[SYM_DOWN][0]
    up_addr = syms[SYM_UP][0]

    # Find the two calls inside cbIdleSourceGlibcurlCleanup.
    call_down = call_up = None
    for va in range(fn_addr, fn_addr + fn_size, 4):
        w = struct.unpack_from("<I", f, v2o(va))[0]
        if (w >> 24) & 0xF != 0xB:
            continue
        t = bl_target(w, va)
        if t == down_addr:
            if call_down is not None:
                die("more than one 'bl shutdownGlibCurl' in the function")
            call_down = va
        elif t == up_addr:
            if call_up is not None:
                die("more than one 'bl startupGlibCurl' in the function")
            call_up = va
    if call_down is None or call_up is None:
        die("could not find the shutdownGlibCurl/startupGlibCurl calls -- "
            "unexpected build of LunaDownloadMgr")
    if not call_down < call_up:
        die("unexpected call order (shutdown at 0x%x, startup at 0x%x)" % (call_down, call_up))

    tail = call_up + 4   # the instruction the guard already branches to

    # The guard: a branch to `tail` somewhere before the teardown calls.
    cond_site = uncond_site = None
    for va in range(fn_addr, call_down, 4):
        w = struct.unpack_from("<I", f, v2o(va))[0]
        if (w >> 24) & 0xF != 0xA:
            continue
        if bl_target(w, va) != tail:
            continue
        if (w >> 28) & 0xF == 0xE:
            uncond_site = va
        else:
            if cond_site is not None:
                die("more than one conditional branch to the tail -- refusing to guess")
            cond_site = va

    if cond_site is None:
        if uncond_site is not None:
            print("%s: already patched (unconditional b 0x%x at 0x%x)"
                  % (path, tail, uncond_site))
            return 0
        die("could not find the guard branch to 0x%x -- refusing to guess" % tail)

    off = v2o(cond_site)
    old = struct.unpack_from("<I", f, off)[0]
    new = (old & 0x0FFFFFFF) | 0xE0000000        # force cond = AL
    if check_only:
        print("%s: NOT patched -- guard at 0x%x (file 0x%x): 0x%08x -> 0x%08x"
              % (path, cond_site, off, old, new))
        return 1
    struct.pack_into("<I", f, off, new)
    open(path, "wb").write(f)
    print("%s: patched guard at vaddr 0x%x (file offset 0x%x): 0x%08x -> 0x%08x "
          "[glibcurl restart disabled]" % (path, cond_site, off, old, new))
    return 0


if __name__ == "__main__":
    sys.exit(main())
