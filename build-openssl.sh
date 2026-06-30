#!/bin/bash
# build-openssl.sh -- (re)build the process-private OpenSSL 1.1.1w for ssl11 with ARM NEON crypto.
#
# Toolchain: Palm PDK arm-none-linux-gnueabi- (gcc 4.3.3). Target: TouchPad Cortex-A8 (ARMv7 + NEON).
#
# Why the extra flags: the original ssl11 OpenSSL was Configured as bare `linux-armv4` with no arch
# flags, so __ARM_MAX_ARCH__ stayed low and only the *integer* asm got compiled (ecp_nistz256 P-256,
# bn_mul_mont RSA) -- handshakes were fast but the NEON *bulk* crypto (AES/SHA/Poly1305) ran in C.
# Adding `-march=armv7-a -mfpu=neon` raises __ARM_MAX_ARCH__ so OpenSSL also compiles in
# bsaes (NEON AES), sha1/sha256-neon, poly1305-neon and ChaCha20 -- the symmetric throughput path.
#
# Deliberately NO -mfloat-abi: the ELF float-ABI flags stay 0x5000002 (identical to the device's
# other libs). CPU features are detected at runtime via OpenSSL's SIGILL probe (sigaction), NOT
# getauxval() -- getauxval is glibc>=2.16 and webOS 3.0.5 is glibc 2.8, so the lib stays loadable.
#
# Output: openssl-1.1.1w/libcrypto.so.1.1 + libssl.so.1.1  (consumed by build-ipks.sh -> ssl11/).

set -eu
BASE="$(cd "$(dirname "$0")" && pwd)"
export PDK="${PDK:-/opt/PalmPDK}"
export PATH="$PDK/arm-gcc/bin:$PATH"
command -v arm-none-linux-gnueabi-gcc >/dev/null 2>&1 || {
  echo "ERROR: PDK toolchain 'arm-none-linux-gnueabi-gcc' not in PATH (set PDK=/path/to/PalmPDK)." >&2
  exit 1
}

cd "$BASE/openssl-1.1.1w"
make distclean >/dev/null 2>&1 || true

# Exactly the original config + NEON arch flags (see header).
CFLAGS="-Wall -O3" ./Configure linux-armv4 --prefix=/usr --openssldir=/usr/lib/ssl \
  --cross-compile-prefix=arm-none-linux-gnueabi- shared no-async no-hw no-tests \
  -march=armv7-a -mtune=cortex-a8 -mfpu=neon

make -j"$(nproc)" build_libs

echo "== verify =="
nm libcrypto.so.1.1 | grep -qw bsaes_ctr32_encrypt_blocks \
  && echo "  NEON bulk crypto (bsaes/aes_v8/sha-neon/poly1305-neon): present" \
  || { echo "  ERROR: NEON bulk crypto MISSING"; exit 1; }
nm libcrypto.so.1.1 | grep -qw ecp_nistz256_mul_mont && echo "  handshake asm (ecp_nistz256/bn_mul_mont): present"
echo "  float ABI: $(readelf -h libcrypto.so.1.1 | awk '/Flags/{print $2}') (must be 0x5000002)"
echo "  getauxval undefined refs (must be 0 for glibc-2.8): $(nm -D -u libcrypto.so.1.1 | grep -c getauxval)"
ls -la libcrypto.so.1.1 libssl.so.1.1
