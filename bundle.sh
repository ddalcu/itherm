#!/bin/sh
# Builds build/iTherm.app from itherm.swift (install: cp -R build/iTherm.app /Applications).
# VERSION=26.10.1 sets the version; SIGN_IDENTITY="Developer ID Application: ..." signs for release (default: ad-hoc).
set -e
cd "$(dirname "$0")"
app=build/iTherm.app
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$tmp/AppIcon.iconset"
swiftc -O itherm.swift -o "$app/Contents/MacOS/itherm"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>iTherm</string>
    <key>CFBundleDisplayName</key><string>iTherm</string>
    <key>CFBundleIdentifier</key><string>com.dalcu.itherm</string>
    <key>CFBundleExecutable</key><string>itherm</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION:-0.0.0}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Icon: a ">_" prompt drawn once at 1024px, then scaled into every size an .icns needs.
swift - "$tmp/icon.png" <<'EOF'
import AppKit
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
(">_" as NSString).draw(at: NSPoint(x: 200, y: 330), withAttributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 340, weight: .bold),
    .foregroundColor: NSColor(red: 0.31, green: 0.89, blue: 0.52, alpha: 1),
])
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
EOF
for n in 16 32 128 256 512; do
    sips -z $n $n "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${n}x${n}.png" >/dev/null
    sips -z $((n * 2)) $((n * 2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$tmp/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$app"
echo "built $app"
