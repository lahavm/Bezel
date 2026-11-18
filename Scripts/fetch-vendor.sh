#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p Vendor

if [ ! -f Vendor/scrcpy-server-v5.0.1 ]; then
    echo "Downloading scrcpy-server 5.0.1…"
    curl -fL -o Vendor/scrcpy-server-v5.0.1 \
        https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-server-v5.0.1
fi

if [ ! -x Vendor/platform-tools/adb ]; then
    echo "Downloading Android platform-tools…"
    curl -fL -o Vendor/platform-tools.zip \
        https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
    unzip -o -q Vendor/platform-tools.zip -d Vendor
    rm -f Vendor/platform-tools.zip
fi

mkdir -p Vendor/licenses
[ -f Vendor/licenses/scrcpy-LICENSE.txt ] || curl -fsL -o Vendor/licenses/scrcpy-LICENSE.txt \
    https://raw.githubusercontent.com/Genymobile/scrcpy/v5.0.1/LICENSE
[ -f Vendor/licenses/platform-tools-NOTICE.txt ] && true || cp Vendor/platform-tools/NOTICE.txt \
    Vendor/licenses/platform-tools-NOTICE.txt

echo "Vendor ready."
