#!/bin/bash
# Build FIPS-safe OpenCV 4.12 wheels WITH FFmpeg video decoding for ModelAgent
# (voicdgroupinc/opencv-python release fips-v4.12.0-4).
#
# Why: PyPI opencv-python{,-headless,-contrib} 4.12.0.88 bundle FFmpeg 5.1.6, whose
# libavformat links a bundled OpenSSL 1.1.1w (libssl-*.so.1.1 / libcrypto-*.so.1.1)
# only for the https/tls/rtmps/crypto protocols. That is an unvalidated, end-of-life
# OpenSSL shipped and loaded into ModelAgent, which a FIPS review does not accept
# (ModelAgent's FIPS notes record a crypto/fips/fips.c self-test abort from a 1.1.1k
# build; the PyPI 1.1.1w carries no fips.c, so the abort itself did not reproduce on
# a FIPS host in Nov 2026). fips-v4.12.0-3 avoided it by building with
# -DWITH_FFMPEG=OFF, which also removed cv2.VideoCapture file decoding.
#
# What this does (same approach as VRH-DeepfakeVideo v0.1.3 build_nossl_wheel.sh):
#   1. rebuilds ONLY libavformat from ffmpeg-5.1.6 (the version upstream 4.12.0.88
#      uses) with no OpenSSL (--disable-autodetect --enable-zlib), against glibc 2.17
#      inside quay.io/pypa/manylinux2014_x86_64;
#   2. for each PyPI 4.12.0.88 manylinux2014 x86_64 wheel (sha256-pinned): swaps that
#      libavformat in (soname kept, NEEDED rewired to the wheel's own hashed
#      libavcodec/libavutil), deletes libssl/libcrypto, fails if any other bundled
#      ELF still NEEDs ssl/crypto/gnutls;
#   3. sets Version to 4.12.0.88+fips4 and relaxes the numpy pin to `numpy>=2`
#      (what the fips-v4.12.0-3 wheels declare; PyPI says numpy<2.3.0,>=2, which
#      ModelAgent's numpy 2.5.1 would violate), then repacks with `wheel pack`
#      (regenerates RECORD).
# libavcodec, libswscale, libavutil, cv2 itself etc. remain the PyPI binaries, so
# decoding output is unchanged.
#
# usage (host): bash build_fips_wheels.sh OUT_DIR
#   Runs itself in docker (scratch in the named volume opencv-fips-scratch, removed
#   at the end). Wheels land in OUT_DIR together with SHA256SUMS and build logs.
set -euo pipefail

LOCAL_TAG=fips4
FFMPEG_TARBALL_SHA=f4fa066278f7a47feab316fef905f4db0d5e9b589451949740f83972b30901bd
WHEEL_TOOL=wheel==0.45.1
# name|url|sha256 of the PyPI 4.12.0.88 cp37-abi3 manylinux2014 x86_64 wheels
WHEELS=(
"opencv_python|https://files.pythonhosted.org/packages/68/1f/795e7f4aa2eacc59afa4fb61a2e35e510d06414dd5a802b51a012d691b37/opencv_python-4.12.0.88-cp37-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64.whl|092c16da4c5a163a818f120c22c5e4a2f96e0db4f24e659c701f1fe629a690f9"
"opencv_python_headless|https://files.pythonhosted.org/packages/89/53/e19c21e0c4eb1275c3e2c97b081103b6dfb3938172264d283a519bf728b9/opencv_python_headless-4.12.0.88-cp37-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64.whl|236c8df54a90f4d02076e6f9c1cc763d794542e886c576a6fee46ec8ff75a7a9"
"opencv_contrib_python|https://files.pythonhosted.org/packages/6a/67/905c2c9364dcd450a0997a489fd3976a10a83cd1ebcbd3d039bb2525b54c/opencv_contrib_python-4.12.0.88-cp37-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64.whl|ac2627dcdf5bd625706949ada7994524320b656a991315ff6ae70043fc983689"
)
UPSTREAM_VER=4.12.0.88
NEW_VER=$UPSTREAM_VER+$LOCAL_TAG

if [ "${1:-}" != "--inside" ]; then
  OUT=$(realpath "${1:?usage: build_fips_wheels.sh OUT_DIR}"); mkdir -p "$OUT"
  HERE=$(cd "$(dirname "$0")" && pwd)
  ENGINE=${ENGINE:-docker}
  $ENGINE volume create opencv-fips-scratch >/dev/null
  [ -n "${KEEP_SCRATCH:-}" ] || trap '$ENGINE volume rm -f opencv-fips-scratch >/dev/null' EXIT
  $ENGINE run --rm -v opencv-fips-scratch:/scratch -v "$HERE":/scripts:ro,z -v "$OUT":/out:z \
    -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
    quay.io/pypa/manylinux2014_x86_64 bash /scripts/$(basename "$0") --inside
  exit
fi

# ---------------------------------------------------------------- in container
S=/scratch; PY=/opt/python/cp312-cp312/bin/python
cd $S; rm -rf build wheel dist; mkdir -p src build wheel dist
$PY -m pip install -q --root-user-action=ignore "$WHEEL_TOOL"
gcc --version | sed -n 1p; ldd --version | sed -n 1p

# 1. libavformat without OpenSSL
[ -f src/ffmpeg-5.1.6.tar.xz ] || curl -fsSL -o src/ffmpeg-5.1.6.tar.xz https://ffmpeg.org/releases/ffmpeg-5.1.6.tar.xz
echo "$FFMPEG_TARBALL_SHA  src/ffmpeg-5.1.6.tar.xz" | sha256sum -c -
tar -xf src/ffmpeg-5.1.6.tar.xz -C build
( cd build/ffmpeg-5.1.6
  ./configure --prefix=$S/build/out --disable-autodetect --enable-zlib --enable-shared --disable-static \
      --enable-pic --disable-x86asm --disable-programs --disable-doc > ../configure.log
  make -j"$(nproc)" > ../make.log 2>&1; make install >> ../make.log 2>&1 )
cp build/configure.log /out/ffmpeg-configure.log
NEWAVF=build/out/lib/libavformat.so.59.27.100
grep -E '^(Enabled protocols|External libraries)' -A12 build/configure.log | sed -n '1,40p' > /out/ffmpeg-enabled.txt || true
if readelf -d $NEWAVF | grep NEEDED | grep -Ei 'ssl|crypto|gnutls|tls'; then echo "FAIL: new libavformat links TLS"; exit 1; fi
echo "new libavformat NEEDED:"; readelf -d $NEWAVF | grep NEEDED
strings $NEWAVF | grep -E '^--prefix' | sed -n 1p

# 2./3. patch each wheel
for spec in "${WHEELS[@]}"; do
  IFS='|' read -r NAME URL SHA <<<"$spec"
  F=src/$(basename "$URL")
  [ -f "$F" ] || curl -fsSL -o "$F" "$URL"
  echo "$SHA  $F" | sha256sum -c -
  rm -rf wheel/*; $PY -m wheel unpack -d wheel "$F" >/dev/null
  W=wheel/$NAME-$UPSTREAM_VER; L=$W/$NAME.libs
  AVF=$(cd $L && ls libavformat-*.so.59.*); AVC=$(cd $L && ls libavcodec-*.so.59.*); AVU=$(cd $L && ls libavutil-*.so.57.*)
  echo "== $NAME: $AVF -> NEEDED $AVC $AVU"
  cp $NEWAVF $L/$AVF; strip --strip-unneeded $L/$AVF
  patchelf --set-soname "$AVF" --replace-needed libavcodec.so.59 "$AVC" \
           --replace-needed libavutil.so.57 "$AVU" --remove-rpath $L/$AVF
  echo "removing: $(cd $L && ls libssl* libcrypto* 2>/dev/null | tr '\n' ' ')"
  rm -f $L/libssl* $L/libcrypto*
  # nothing left may reference ssl/crypto/gnutls
  BAD=0
  while IFS= read -r so; do
    if readelf -d "$so" 2>/dev/null | grep NEEDED | grep -Eiq 'libssl|libcrypto|gnutls'; then
      echo "FAIL: $so still NEEDs:"; readelf -d "$so" | grep NEEDED | grep -Ei 'ssl|crypto|gnutls'; BAD=1; fi
  done < <(find $W -type f \( -name '*.so' -o -name '*.so.*' \))
  [ $BAD = 0 ] || exit 1
  # metadata: version + numpy pin like fips-v4.12.0-3
  mv $W/$NAME-$UPSTREAM_VER.dist-info $W/$NAME-$NEW_VER.dist-info
  M=$W/$NAME-$NEW_VER.dist-info/METADATA
  sed -i -e "s/^Version: $UPSTREAM_VER\$/Version: $NEW_VER/" \
         -e 's/^Requires-Dist: numpy<2.3.0,>=2; python_version >= "3.9"$/Requires-Dist: numpy>=2; python_version >= "3.9"/' $M
  grep -q "^Version: $NEW_VER\$" $M; grep -q '^Requires-Dist: numpy>=2; python_version >= "3.9"$' $M
  grep -E '^(Version|Requires-Dist)' $M
  mv $W wheel/$NAME-$NEW_VER
  $PY -m wheel pack -d dist wheel/$NAME-$NEW_VER
done
rm -rf wheel/* build
cp dist/*.whl /out/
cd /out && sha256sum *.whl | tee SHA256SUMS
chown "$HOST_UID:$HOST_GID" /out/* 2>/dev/null || true
