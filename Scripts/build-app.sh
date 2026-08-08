#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
configuration=${1:-release}
app_dir="$project_dir/dist/Uziq.app"
contents_dir="$app_dir/Contents"
iconset_dir="$project_dir/dist/Uziq.iconset"
helpers_dir="$contents_dir/Helpers"
notices_dir="$contents_dir/Resources/ThirdPartyNotices"

cd "$project_dir"
swift build -c "$configuration"
binary_dir=$(swift build -c "$configuration" --show-bin-path)

rm -rf "$app_dir" "$iconset_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$helpers_dir" "$notices_dir" "$iconset_dir"

cp "$binary_dir/Uziq" "$contents_dir/MacOS/Uziq"
cp "$project_dir/Packaging/Info.plist" "$contents_dir/Info.plist"

librespot_source=${UZIQ_LIBRESPOT_PATH:-}
if [[ -z "$librespot_source" ]]; then
    librespot_source=$(command -v librespot || true)
fi
if [[ -z "$librespot_source" || ! -x "$librespot_source" ]]; then
    echo "A librespot executable is required to package Uziq." >&2
    echo "Install librespot 0.8.0 or set UZIQ_LIBRESPOT_PATH to its executable." >&2
    exit 1
fi

app_archs=$(lipo -archs "$binary_dir/Uziq")
helper_archs=$(lipo -archs "$librespot_source")
for app_arch in ${(z)app_archs}; do
    if [[ " $helper_archs " != *" $app_arch "* ]]; then
        echo "librespot does not contain the app architecture $app_arch (found: $helper_archs)." >&2
        exit 1
    fi
done

cp -X "$librespot_source" "$helpers_dir/librespot"
chmod 755 "$helpers_dir/librespot"
cp "$project_dir/ThirdPartyNotices/librespot-LICENSE.txt" "$notices_dir/librespot-LICENSE.txt"

icon_source="$project_dir/Images/logo.png"
cp "$icon_source" "$contents_dir/Resources/logo.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$icon_source" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$contents_dir/Resources/AppIcon.icns"
rm -rf "$iconset_dir"

codesign --force --sign - "$helpers_dir/librespot"
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "Bundled librespot from $librespot_source ($helper_archs)"
echo "$app_dir"
