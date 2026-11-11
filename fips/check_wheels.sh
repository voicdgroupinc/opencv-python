#!/bin/bash
# Check the fips wheels built by build_fips_wheels.sh, in ModelAgent's base image
# (registry.access.redhat.com/ubi9/python-312), the way ModelAgent installs them:
# all three packages in one environment, numpy 2.x.
#
#   - no libssl/libcrypto file, no ELF NEEDED on ssl/crypto/gnutls/tls, no
#     OpenSSL 1.1.1 / FIPS self-test strings in any bundled library
#   - pip check clean; import cv2 works (also with LD_BIND_NOW=1)
#   - FFmpeg is on: getBuildInformation says FFMPEG: YES
#   - a video written with cv2.VideoWriter (mp4v in .mp4, MJPG in .avi) reads back
#     through cv2.VideoCapture with the right frame count and size
#   - an https:// input is refused (no TLS in libavformat), not crashed on
#
# usage: bash check_wheels.sh WHEELS_DIR      (needs docker)
set -euo pipefail
WH=$(realpath "${1:?usage: check_wheels.sh WHEELS_DIR}")
NUMPY=${NUMPY:-numpy==2.5.1}
docker run --rm --user 0 -v "$WH":/wheels:ro,z -e NUMPY="$NUMPY" \
  registry.access.redhat.com/ubi9/python-312 bash -euo pipefail -c '
dnf install -y -q mesa-libGL binutils >/dev/null 2>&1   # GUI wheels need libGL.so.1, as in ModelAgent
echo "fips_enabled=$(cat /proc/sys/crypto/fips_enabled) $(python -V)"
fail() { echo "FAIL: $*"; exit 1; }

for w in /wheels/opencv*.whl; do
  d=/tmp/st/$(basename $w .whl); mkdir -p $d
  python -I -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; z.extractall(sys.argv[2])" $w $d
  [ -z "$(find $d -iname "libssl*" -o -iname "libcrypto*")" ] || fail "$w bundles libssl/libcrypto"
  for so in $(find $d -type f \( -name "*.so" -o -name "*.so.*" \)); do
    ! readelf -d $so | grep NEEDED | grep -Eiq "ssl|crypto|gnutls|tls" || fail "$so links TLS"
  done
  ! grep -rlaE "crypto/fips/fips.c|FATAL FIPS SELFTEST|OpenSSL 1\.1\.1" $d >/dev/null || fail "$w carries OpenSSL 1.1.1 code"
  echo "static OK: $(basename $w)"
done

python -m venv /tmp/env && . /tmp/env/bin/activate
pip install -q --disable-pip-version-check --root-user-action=ignore "$NUMPY" /wheels/opencv*.whl
pip check
python -c "import cv2" && LD_BIND_NOW=1 python -c "import cv2"
python - <<"PY"
import cv2, numpy as np, os
info = cv2.getBuildInformation()
assert any(l.strip().startswith("FFMPEG:") and "YES" in l for l in info.splitlines()), "FFMPEG is not YES"
print("cv2", cv2.__version__, "numpy", np.__version__, "FFMPEG: YES")
for path, fourcc in (("/tmp/t.mp4", "mp4v"), ("/tmp/t.avi", "MJPG")):
    w = cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*fourcc), 25.0, (160, 120))
    assert w.isOpened(), "VideoWriter failed for " + path
    for i in range(30):
        f = np.zeros((120, 160, 3), np.uint8); f[:, : (i * 5) % 160] = (0, 128, 255); w.write(f)
    w.release()
    c = cv2.VideoCapture(path)
    assert c.isOpened(), "VideoCapture could not open " + path
    n = 0
    while True:
        ok, f = c.read()
        if not ok: break
        assert f.shape == (120, 160, 3); n += 1
    assert n == 30, "%s: read %d frames, wrote 30" % (path, n)
    print("decode OK:", path, n, "frames, fps", c.get(cv2.CAP_PROP_FPS))
c = cv2.VideoCapture("https://example.invalid/x.mp4", cv2.CAP_FFMPEG)
assert not c.isOpened(), "https input unexpectedly opened"
print("https input refused: OK")
PY
echo "ALL CHECKS PASSED"
'
