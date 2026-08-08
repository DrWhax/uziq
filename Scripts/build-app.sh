#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
configuration=${1:-release}
dist_dir="$project_dir/dist"
app_dir="$dist_dir/Uziq.app"
contents_dir="$app_dir/Contents"
iconset_dir="$dist_dir/Uziq.iconset"
helpers_dir="$contents_dir/Helpers"
notices_dir="$contents_dir/Resources/ThirdPartyNotices"

cd "$project_dir"
swift build -c "$configuration"
binary_dir=$(swift build -c "$configuration" --show-bin-path)

rm -rf "$app_dir" "$iconset_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$helpers_dir" "$notices_dir" "$iconset_dir"

cp "$binary_dir/Uziq" "$contents_dir/MacOS/Uziq"
cp "$project_dir/Packaging/Info.plist" "$contents_dir/Info.plist"

spotify_client_id=${UZIQ_SPOTIFY_CLIENT_ID:-}
if [[ -n "$spotify_client_id" ]]; then
    if [[ ! "$spotify_client_id" =~ ^[A-Za-z0-9]+$ ]]; then
        echo "UZIQ_SPOTIFY_CLIENT_ID must contain only letters and numbers." >&2
        exit 1
    fi
    /usr/libexec/PlistBuddy -c "Add :UziqSpotifyClientID string $spotify_client_id" "$contents_dir/Info.plist"
fi

librespot_source=${UZIQ_LIBRESPOT_PATH:-}
helper_name=uziq-librespot
if [[ -z "$librespot_source" ]]; then
    helper_manifest="$project_dir/Helpers/uziq-librespot/Cargo.toml"
    if ! command -v cargo >/dev/null; then
        echo "Rust/Cargo is required to build Uziq's bundled Spotify helper." >&2
        exit 1
    fi
    cargo build --release --locked --manifest-path "$helper_manifest"
    librespot_source="$project_dir/Helpers/uziq-librespot/target/release/uziq-librespot"
elif [[ "${librespot_source:t}" != "uziq-librespot" ]]; then
    # Preserve support for a stock librespot override. Uziq detects this name
    # and falls back to Spotify Web API transport controls.
    helper_name=librespot
fi
if [[ ! -x "$librespot_source" ]]; then
    echo "Spotify playback helper is not executable: $librespot_source" >&2
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

helper_destination="$helpers_dir/$helper_name"
cp -X "$librespot_source" "$helper_destination"
chmod 755 "$helper_destination"
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

plutil -lint "$contents_dir/Info.plist" >/dev/null
codesign --force --options runtime --timestamp=none --sign - --identifier com.crambledeggs.uziq.librespot "$helper_destination"
codesign --force --options runtime --timestamp=none --sign - "$app_dir"
codesign --verify --strict --verbose=2 "$helper_destination"
codesign --verify --deep --strict --verbose=2 "$app_dir"
echo "Bundled $helper_name from $librespot_source ($helper_archs)"
echo "Bundled signed application resources and third-party notices"
echo "$app_dir"
