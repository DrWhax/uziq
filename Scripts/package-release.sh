#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
configuration=${1:-release}
dist_dir="$project_dir/dist"
app_dir="$dist_dir/Uziq.app"
staging_dir="$dist_dir/.Uziq-dmg-root"

"$script_dir/build-app.sh" "$configuration"

info_plist="$app_dir/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info_plist")
app_archs=$(lipo -archs "$app_dir/Contents/MacOS/Uziq")
arch_label=${app_archs// /-}
artifact_name="Uziq-$version-macOS-$arch_label"
dmg_path="$dist_dir/$artifact_name.dmg"
zip_path="$dist_dir/$artifact_name.zip"
checksums_path="$dist_dir/$artifact_name-SHA256.txt"

rm -rf "$staging_dir"
rm -f "$dmg_path" "$zip_path" "$checksums_path"
mkdir -p "$staging_dir"
trap 'rm -rf "$staging_dir"' EXIT

ditto --noqtn "$app_dir" "$staging_dir/Uziq.app"
ln -s /Applications "$staging_dir/Applications"
cp "$project_dir/Packaging/First Launch.txt" "$staging_dir/First Launch.txt"

hdiutil create \
    -volname "Uziq $version" \
    -srcfolder "$staging_dir" \
    -format UDZO \
    -ov \
    "$dmg_path" >/dev/null
hdiutil verify "$dmg_path" >/dev/null

ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$zip_path"
unzip -tq "$zip_path" >/dev/null

shasum -a 256 "$dmg_path" "$zip_path" > "$checksums_path"

echo
echo "Ad-hoc signature verification:"
codesign --verify --deep --strict --verbose=2 "$app_dir"
if spctl --assess --type execute --verbose=2 "$app_dir" 2>/dev/null; then
    echo "Gatekeeper accepted the app."
else
    echo "Gatekeeper reports an unidentified developer, as expected for an ad-hoc signature."
    echo "On first launch, Control-click Uziq and choose Open."
fi

echo
echo "Distribution artifacts:"
ls -lh "$dmg_path" "$zip_path" "$checksums_path"
echo
cat "$checksums_path"
