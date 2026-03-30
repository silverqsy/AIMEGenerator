# AIME Generator

**Apple Immersive Media Experience (.aime) Lens Profile Builder**

By Siyang Qi

A macOS tool for creating `.aime` lens profile files and `.ilpd` (Immersive Lens Profile Data) for third-party immersive (VR180 stereo) video on Apple Vision Pro. Also supports injecting ILPD metadata directly into video files for DaVinci Resolve's immersive workflow.

## What it does

AIME Generator takes camera calibration data (from Gyroflow or manual input) and generates `.aime` and `.ilpd` files that tell Apple Vision Pro / DaVinci Resolve how to correctly project fisheye video onto the immersive display. It supports:

- **Kannala-Brandt fisheye lens model** (OpenCV fisheye k1-k4)
- **Per-eye principal point calibration** (cx/cy for left and right eyes)
- **Stereo rotation offset** for rotational misalignment correction
- **3-mode dynamic mask**: Off (Max FOV), Off (Compatible), Custom with per-point control
- **Live preview** with side-by-side, anaglyph, overlay, and rectilinear views
- **Drag-to-align** for centering each eye's principal point
- **Mask adjustment mode** with mirror H/V and size slider
- **ILPD export** with KB→Mei-Rives model conversion
- **ILPD video injection** — embed ILPD metadata directly into MOV files for DaVinci Resolve
- **Top/Bottom stereo** layout support

## Supported Video Formats

| Format | Description |
|--------|-------------|
| **MV-HEVC** | Apple's multiview HEVC (stereo in one track) |
| **SBS** | Side-by-side (left+right in one frame) |
| **Top/Bottom** | Top/bottom (left on top, right on bottom) |
| **OSV** | Dual-stream (two video tracks in one container) |

## ILPD Injection (DaVinci Resolve)

The app can inject ILPD calibration metadata directly into MOV video files. This makes DaVinci Resolve recognize the footage as Apple Immersive content with lens calibration data.

**Supported containers for injection:** MOV files with standard codecs (ProRes, HEVC, MV-HEVC, H.264). Proprietary raw formats (BRAW, CRM, R3D) are not supported — transcode to ProRes/MOV first.

### How it works
1. Load your video and calibration
2. Click **Inject ILPD to Video** — saves a new MOV with metadata next to the original
3. Import the injected MOV into DaVinci Resolve
4. Resolve will recognize it as immersive content (Immersive ID, Projection, Calibration Type columns populate)

The `inject_ilpd_v2.py` script and `ilpd_template.json` must be in the same directory as the app.

## Requirements

- macOS 15.0+ (Sequoia)
- Apple Silicon Mac
- Xcode Command Line Tools (for `xcrun usdcat`)
- Python 3 (for ILPD video injection)
- **ffmpeg/ffprobe** — required for video preview. Install via:
  ```bash
  brew install ffmpeg
  ```
  The app will show a warning if ffmpeg is not found. Without it, video preview is unavailable but .aime generation from saved projects still works.

## Installation

1. Download `AIMEGenerator.dmg` from the [latest release](https://github.com/silverqsy/AIMEGenerator/releases)
2. Open the DMG and drag `AIMEGenerator.app` to your Applications folder
3. Place `inject_ilpd_v2.py` and `ilpd_template.json` next to the app (same directory)
4. **Important**: On first launch, if macOS says the app is "damaged" or "can't be opened", run:
   ```bash
   xattr -cr /Applications/AIMEGenerator.app
   ```

## Quick Start

1. Open `AIMEGenerator.app`
2. Click **Import Gyroflow JSON** to load camera calibration
3. Click **Open Video** to load your stereo footage
4. Adjust principal points by dragging in the preview
5. Toggle **Mask Adjustment Mode** to reshape the mask boundary
6. Click **Generate .aime** to export for Apple Vision Pro
7. Click **Export .ilpd** to export for DaVinci Resolve
8. Click **Inject ILPD to Video** to embed calibration into the video file

## Building from Source

```bash
swiftc -parse-as-library -O \
  -o AIMEGenerator \
  -framework Cocoa -framework SwiftUI -framework UniformTypeIdentifiers \
  -framework AVFoundation -framework VideoToolbox -framework CoreMedia \
  AIMEGeneratorApp.swift

# Create .app bundle
mkdir -p AIMEGenerator.app/Contents/MacOS
cp AIMEGenerator AIMEGenerator.app/Contents/MacOS/
codesign --force --sign - AIMEGenerator.app
```

## How .aime Files Work

An `.aime` file contains:
- A **USDZ projection mesh** that maps fisheye video pixels to directions on a unit sphere (one mesh per eye)
- A **dynamic mask** defining the visible boundary with gradient edge falloff
- **Camera metadata** (baseline, frame rate, calibration name)

The mesh uses the Kannala-Brandt distortion model to compute UV texture coordinates for each vertex on the sphere, allowing Apple Vision Pro to correctly undistort and display the fisheye video in immersive mode.

## How ILPD Works

An `.ilpd` file is a JSON file containing the **Mei-Rives (Unified Camera Model)** lens parameters. The app converts from the Kannala-Brandt model to Mei-Rives using Levenberg-Marquardt optimization with:
- Analytical xi estimation from projection curve shape
- Xi lower-bound constraint for physically meaningful parameters
- Dense sampling at high angles where models diverge

DaVinci Resolve uses ILPD data for its Apple Immersive Video workflow, enabling lens correction and stereo alignment during editing and export.

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
