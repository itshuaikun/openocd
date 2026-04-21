#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${IMAGE:-docker.io/library/ubuntu:20.04}
OUT_DIR=${OUT_DIR:-"$ROOT_DIR/out/portable"}
BUILD_DIR="$OUT_DIR/build-u20"
STAGE_DIR="$OUT_DIR/stage-u20"
PKG_DIR="$OUT_DIR/openocd-linux-portable"
TARBALL="$OUT_DIR/openocd-linux-portable.tar.gz"
LEGACY_PKG_DIR="$OUT_DIR/openocd-ubuntu20-portable"
LEGACY_TARBALL_GZ="$OUT_DIR/openocd-ubuntu20-portable.tar.gz"
LEGACY_TARBALL_XZ="$OUT_DIR/openocd-ubuntu20-portable.tar.xz"

mkdir -p "$OUT_DIR"

echo "[portable] Using image: $IMAGE"
echo "[portable] Output dir: $OUT_DIR"

podman run --rm \
	-e BUILD_IMAGE="$IMAGE" \
	-v "$ROOT_DIR":/work \
	-w /work \
	"$IMAGE" \
	bash -lc '
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
	build-essential autoconf automake libtool pkg-config texinfo \
	patchelf perl file ca-certificates xz-utils \
	libusb-1.0-0-dev libftdi1-dev libhidapi-dev libcapstone-dev \
	libjaylink-dev libjim-dev libssl-dev zlib1g-dev

ROOT_DIR=/work
OUT_DIR=/work/out/portable
BUILD_DIR=$OUT_DIR/build-u20
STAGE_DIR=$OUT_DIR/stage-u20
PKG_DIR=$OUT_DIR/openocd-linux-portable
TARBALL=$OUT_DIR/openocd-linux-portable.tar.gz
LEGACY_PKG_DIR=$OUT_DIR/openocd-ubuntu20-portable
LEGACY_TARBALL_GZ=$OUT_DIR/openocd-ubuntu20-portable.tar.gz
LEGACY_TARBALL_XZ=$OUT_DIR/openocd-ubuntu20-portable.tar.xz

rm -rf \
	"$BUILD_DIR" \
	"$STAGE_DIR" \
	"$PKG_DIR" \
	"$TARBALL" \
	"$LEGACY_PKG_DIR" \
	"$LEGACY_TARBALL_GZ" \
	"$LEGACY_TARBALL_XZ"
mkdir -p "$BUILD_DIR" "$STAGE_DIR" "$PKG_DIR" "$PKG_DIR/lib" "$PKG_DIR/meta"

cd "$BUILD_DIR"
"$ROOT_DIR/configure" --disable-werror --enable-internal-libjaylink --prefix=/usr
make -j"$(nproc)"
make install DESTDIR="$STAGE_DIR"

cp -a "$STAGE_DIR/usr/." "$PKG_DIR"/

# Keep runtime assets, drop install-time docs to shrink the portable bundle.
rm -rf "$PKG_DIR/share/info" "$PKG_DIR/share/man"

BIN="$PKG_DIR/bin/openocd"
LDD_LIST="$PKG_DIR/meta/ldd-libs.txt"
BUNDLED_LIST="$PKG_DIR/meta/bundled-libs.txt"

ldd "$BIN" | awk "
/=> \// { print \$3 }
/^\// { print \$1 }
" | sort -u > "$LDD_LIST"

: > "$BUNDLED_LIST"
while IFS= read -r so; do
	case "$so" in
		""|linux-vdso.so.1)
			continue
			;;
		*/ld-linux-*|*/libc.so.*|*/libm.so.*|*/libpthread.so.*|*/libdl.so.*|*/librt.so.*|*/libresolv.so.*|*/libnsl.so.*|*/libanl.so.*|*/libnss_*)
			continue
			;;
	esac
	cp -Lv "$so" "$PKG_DIR/lib/"
	basename "$so" >> "$BUNDLED_LIST"
done < "$LDD_LIST"

sort -u -o "$BUNDLED_LIST" "$BUNDLED_LIST"

mv "$BIN" "$PKG_DIR/bin/openocd.real"
cat > "$PKG_DIR/bin/openocd" <<'\''EOF'\''
#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ -n "${OPENOCD_SCRIPTS:-}" ]; then
	export OPENOCD_SCRIPTS="$HERE/share/openocd/scripts:$OPENOCD_SCRIPTS"
else
	export OPENOCD_SCRIPTS="$HERE/share/openocd/scripts"
fi

if [ -n "${LD_LIBRARY_PATH:-}" ]; then
	export LD_LIBRARY_PATH="$HERE/lib:$LD_LIBRARY_PATH"
else
	export LD_LIBRARY_PATH="$HERE/lib"
fi

exec "$HERE/bin/openocd.real" "$@"
EOF
chmod +x "$PKG_DIR/bin/openocd"

patchelf --set-rpath "\$ORIGIN/../lib" "$PKG_DIR/bin/openocd.real"

strip --strip-unneeded "$PKG_DIR/bin/openocd.real"
find "$PKG_DIR/lib" -type f -name "*.so*" -exec strip --strip-unneeded {} +

cat > "$PKG_DIR/meta/build-info.txt" <<EOF
image=$BUILD_IMAGE
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
kernel=$(uname -srmo)
glibc=$(ldd --version | head -n1)
configure=$ROOT_DIR/configure --disable-werror --enable-internal-libjaylink --prefix=/usr
EOF

cat > "$PKG_DIR/README.portable.txt" <<EOF
Portable OpenOCD package built on Ubuntu 20.04.

Usage:
  ./bin/openocd --version
  ./bin/openocd -f interface/dummy.cfg -f target/faux.cfg -c "init; shutdown"

Notes:
  - This package bundles non-glibc shared libraries under ./lib.
  - It expects a reasonably modern x86_64 glibc-based Linux system.
  - USB device permissions and udev rules are still managed by the host system.
EOF

tar -C "$OUT_DIR" -czf "$TARBALL" "$(basename "$PKG_DIR")"
rm -rf "$BUILD_DIR" "$STAGE_DIR"

echo "[portable] Package ready: $TARBALL"
'

echo "[portable] Test on fresh ubuntu:20.04"
podman run --rm \
	-v "$OUT_DIR":/work/out \
	-w /work/out/openocd-linux-portable \
	docker.io/library/ubuntu:20.04 \
	bash -lc './bin/openocd --version && ./bin/openocd -f interface/dummy.cfg -f target/faux.cfg -c "init; shutdown"'

echo "[portable] Test on fresh ubuntu:24.04"
podman run --rm \
	-v "$OUT_DIR":/work/out \
	-w /work/out/openocd-linux-portable \
	docker.io/library/ubuntu:24.04 \
	bash -lc './bin/openocd --version && ./bin/openocd -f interface/dummy.cfg -f target/faux.cfg -c "init; shutdown"'

echo "[portable] Test on host"
"$PKG_DIR/bin/openocd" --version
"$PKG_DIR/bin/openocd" -f interface/dummy.cfg -f target/faux.cfg -c "init; shutdown"

echo "[portable] Done"
