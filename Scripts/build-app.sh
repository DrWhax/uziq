#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
configuration=${1:-release}
app_dir="$project_dir/dist/Uziq.app"
contents_dir="$app_dir/Contents"
iconset_dir="$project_dir/dist/Uziq.iconset"

cd "$project_dir"
swift build -c "$configuration"
binary_dir=$(swift build -c "$configuration" --show-bin-path)

rm -rf "$app_dir" "$iconset_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$iconset_dir"

cp "$binary_dir/Uziq" "$contents_dir/MacOS/Uziq"
cp "$project_dir/Packaging/Info.plist" "$contents_dir/Info.plist"

icon_source="$project_dir/Images/logo.png"
cp "$icon_source" "$contents_dir/Resources/logo.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$icon_source" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$contents_dir/Resources/AppIcon.icns"
rm -rf "$iconset_dir"

codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "$app_dir"
