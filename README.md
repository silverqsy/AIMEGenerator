# AIME Generator

**Apple Immersive Media Experience (.aime) Lens Profile Builder**

By Siyang Qi

A macOS tool for creating `.aime` lens profile files used by Apple Vision Pro to play back third-party immersive (VR180 stereo) video content.

## What it does

AIME Generator takes camera calibration data (from Gyroflow or manual input) and generates `.aime` files that tell Apple Vision Pro how to correctly project fisheye video onto the immersive display. It supports:

- **Kannala-Brandt fisheye lens model** (OpenCV fisheye k1-k4)
- **Per-eye principal point calibration** (cx/cy for left and right eyes)
- **Stereo rotation offset** for rotational misalignment correction
- **3-mode dynamic mask**: Off (Max FOV), Off (Compatible), Custom with per-point control
- **Live preview** with side-by-side, anaglyph, overlay, and rectilinear views
- **Drag-to-align** for centering each eye's principal point
- **Mask adjustment mode** with mirror H/V and size slider

## Supported Video Formats

| Format | Description |
|--------|-------------|
| **MV-HEVC** | Apple's multiview HEVC (stereo in one track) |
| **SBS** | Side-by-side (left+right in one frame) |
| **OSV** | Dual-stream (two video tracks in one container) |

## Requirements

- macOS 15.0+ (Sequoia)
- Apple Silicon Mac
- Xcode Command Line Tools (for `xcrun usdcat`)
- ffmpeg/ffprobe (bundled in the release, or install via `brew install ffmpeg`)

## Installation

1. Download `AIMEGenerator.dmg` from the [latest release](https://github.com/silverqsy/AIMEGenerator/releases)
2. Open the DMG and drag `AIMEGenerator.app` to your Applications folder
3. **Important**: On first launch, if macOS says the app is "damaged" or "can't be opened", run:
   ```bash
   xattr -cr /Applications/AIMEGenerator.app
   ```
   This removes the quarantine flag added to all internet downloads. The app is ad-hoc signed.

## Quick Start

1. Open `AIMEGenerator.app`
2. Click **Import Gyroflow JSON** to load camera calibration
3. Click **Open Video** to load your stereo footage
4. Adjust principal points by dragging in the preview
5. Toggle **Mask Adjustment Mode** to reshape the mask boundary
6. Click **Generate .aime** to export

## Building from Source

```bash
swiftc -parse-as-library -O \
  -o AIMEGenerator \
  -framework SwiftUI -framework UniformTypeIdentifiers -framework Metal \
  -framework AVFoundation -framework CoreImage -framework AppKit \
  -framework ImmersiveMediaSupport \
  AIMEGeneratorApp.swift

# Create .app bundle
mkdir -p AIMEGenerator.app/Contents/MacOS
cp AIMEGenerator AIMEGenerator.app/Contents/MacOS/
cat > AIMEGenerator.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AIMEGenerator</string>
    <key>CFBundleIdentifier</key><string>com.aime.generator</string>
    <key>CFBundleName</key><string>AIMEGenerator</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSUIElement</key><false/>
</dict>
</plist>
EOF
codesign --force --sign - AIMEGenerator.app
```

## How .aime Files Work

An `.aime` file contains:
- A **USDZ projection mesh** that maps fisheye video pixels to directions on a unit sphere (one mesh per eye)
- A **dynamic mask** defining the visible boundary with gradient edge falloff
- **Camera metadata** (baseline, frame rate, calibration name)

The mesh uses the Kannala-Brandt distortion model to compute UV texture coordinates for each vertex on the sphere, allowing Apple Vision Pro to correctly undistort and display the fisheye video in immersive mode.

## Mask Modes

| Mode | Description |
|------|-------------|
| **Off (Max FOV)** | Transparent image mask — maximum field of view, works on Vision Pro but not in Immersive Utility |
| **Off (Compatible)** | Wide dynamic mask that covers ~96° from forward — works everywhere |
| **Custom** | Adjustable per-point mask with drag control, mirror H/V, and size slider |

## Project Files

Save/load project settings as `.json` files to preserve your calibration between sessions.

## License

MIT

## Links

[![Hypercommit](https://img.shields.io/badge/Hypercommit-DB2475)](https://hypercommit.com/aimegenerator)
