import SwiftUI
import UniformTypeIdentifiers
import Foundation
import ImmersiveMediaSupport
import Metal
import Spatial
import simd
import AVFoundation
import CoreImage
import AppKit

// MARK: - App Entry Point

// Track spawned ffmpeg processes so we can kill them on app exit
final class ProcessTracker {
    static let shared = ProcessTracker()
    private var pids: [pid_t] = []
    private let lock = NSLock()

    func track(_ pid: pid_t) {
        lock.lock(); pids.append(pid); lock.unlock()
    }
    func remove(_ pid: pid_t) {
        lock.lock(); pids.removeAll { $0 == pid }; lock.unlock()
    }
    func killAll() {
        lock.lock()
        for pid in pids {
            kill(pid, SIGKILL)
            kill(-pid, SIGKILL) // kill process group too
        }
        pids.removeAll()
        lock.unlock()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No startup cleanup — ProcessTracker.killAll() handles termination
    }
    func applicationWillTerminate(_ notification: Notification) {
        ProcessTracker.shared.killAll()
    }
}

@main
struct AIMEGeneratorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 900)
        }
        .windowResizability(.contentMinSize)
    }
}

// MARK: - Gyroflow JSON Parser

struct GyroflowProfile: Codable {
    let name: String?
    let camera_brand: String?
    let camera_model: String?
    let lens_model: String?
    let calib_dimension: Dimension?
    let orig_dimension: Dimension?
    let fps: Double?
    let distortion_model: String?
    let fisheye_params: FisheyeParams?

    struct Dimension: Codable {
        let w: Int
        let h: Int
    }

    struct FisheyeParams: Codable {
        let RMS_error: Double?
        let camera_matrix: [[Double]]
        let distortion_coeffs: [Double]
        let radial_distortion_limit: Double?
    }
}

// MARK: - View Model

@MainActor
class AIMEViewModel: ObservableObject {
    // Camera ID
    @Published var cameraID: String = "MY-CAMERA-001"
    @Published var calibrationName: String = "custom-calibration"

    // Image dimensions
    @Published var imageWidth: String = "2048"
    @Published var imageHeight: String = "2048"

    // Distortion model
    @Published var distortionModel: DistortionModel = .opencvFisheye

    // Shared intrinsics (focal length same for both eyes)
    @Published var fx: String = "825.0"
    @Published var fy: String = "825.0"

    // Shared distortion coefficients (same lens model both eyes)
    @Published var k1: String = "0.0"
    @Published var k2: String = "0.0"
    @Published var k3: String = "0.0"
    @Published var k4: String = "0.0"

    // Per-eye principal points (this is what differs between eyes)
    @Published var leftCx: String = "1024.0"
    @Published var leftCy: String = "1024.0"
    @Published var rightCx: String = "1024.0"
    @Published var rightCy: String = "1024.0"

    // Stereo rotation offset (degrees) — applied symmetrically:
    // Left eye gets -half, Right eye gets +half
    @Published var stereoRotX: String = "0.0"  // pitch
    @Published var stereoRotY: String = "0.0"  // yaw (toe-in/out)
    @Published var stereoRotZ: String = "0.0"  // roll

    // FOV & mesh
    @Published var hfov: String = "190.0"
    @Published var thetaSteps: String = "128"
    @Published var phiSteps: String = "64"

    // Stereo
    @Published var baseline: String = "0.065"

    // Presentation
    @Published var frameRate: String = "90"

    // Mask — stored as pixel radii from image center (in image space)
    enum MaskMode: String, CaseIterable {
        case offMaxFOV = "Off (Max FOV)"
        case offCompatible = "Off (Compatible)"
        case custom = "Custom"
    }
    @Published var maskMode: MaskMode = .custom
    @Published var maskEdgeWidth: String = "2.5"
    @Published var maskNumPoints: String = "64"
    @Published var maskPlaneAngle: String = "10.0"
    @Published var maskEdgeTreatment: String = "linear"  // "linear" or "easeInOut"
    // Per-point pixel radius from image center. nil = use default circle (inscribed circle radius)
    @Published var maskPixelRadii: [Float]? = nil

    /// Get the default mask radius in pixels (inscribed circle = half the smaller dimension)
    var defaultMaskPixelRadius: Float {
        let w = Float(imageWidth) ?? 2048
        let h = Float(imageHeight) ?? 2048
        return min(w, h) / 2.0 * 0.95  // 95% of inscribed circle
    }

    /// Get mask pixel radii, using defaults if not set
    func getMaskPixelRadii() -> [Float] {
        let count = Int(maskNumPoints) ?? 64
        if let radii = maskPixelRadii, radii.count == count { return radii }
        return Array(repeating: defaultMaskPixelRadius, count: count)
    }

    /// Reset mask to default circle
    func resetMaskRadii() {
        maskPixelRadii = nil
    }

    @Published var maskSizePercent: Float = 95  // percentage of inscribed circle
    @Published var maskAdjustMode: Bool = false
    @Published var maskMirrorH: Bool = true   // mirror across vertical axis (left↔right)
    @Published var maskMirrorV: Bool = false   // mirror across horizontal axis (top↔bottom)

    /// Get mirror indices for a given mask point index
    func maskMirrorIndices(for index: Int) -> [Int] {
        let count = Int(maskNumPoints) ?? 64
        var indices: Set<Int> = []
        if maskMirrorH {
            indices.insert((count / 2 - index + count) % count)  // horizontal mirror
        }
        if maskMirrorV {
            indices.insert((count - index) % count)  // vertical mirror
        }
        if maskMirrorH && maskMirrorV {
            indices.insert((count / 2 + index) % count)  // diagonal mirror (both axes)
        }
        indices.remove(index)  // don't include self
        return Array(indices)
    }

    /// Set mask size as percentage of inscribed circle, scaling all points uniformly
    func setMaskSizePercent(_ pct: Float) {
        let clamped = max(10, min(150, pct))
        let oldPct = maskSizePercent
        guard abs(clamped - oldPct) > 0.01 else { return }
        let factor = clamped / oldPct
        let imgW = Float(imageWidth) ?? 2048
        let imgH = Float(imageHeight) ?? 2048
        let maxR = min(imgW, imgH) / 2.0 - 1  // max pixel radius: half the smaller dimension minus margin
        var radii = getMaskPixelRadii()
        for i in 0..<radii.count {
            radii[i] = max(10, min(maxR, radii[i] * factor))
        }
        maskPixelRadii = radii
        maskSizePercent = clamped
    }

    /// Adjust mask size by delta percentage points
    func maskAdjustModeSize(delta: Float) {
        setMaskSizePercent(maskSizePercent + delta)
    }

    /// Scale all mask point radii by a factor
    func scaleMaskRadii(factor: Float) {
        var radii = getMaskPixelRadii()
        for i in 0..<radii.count {
            radii[i] = max(10, radii[i] * factor)
        }
        maskPixelRadii = radii
        // Update percentage to reflect new size
        let w = Float(imageWidth) ?? 2048
        let h = Float(imageHeight) ?? 2048
        let inscribed = min(w, h) / 2.0
        if inscribed > 0, let first = maskPixelRadii?.first {
            maskSizePercent = first / inscribed * 100
        }
    }

    /// Convert pixel radii to Apple's 3D control points on a plane
    /// Inverse KB: pixel radius → incidence angle (theta) from optical axis
    private func inverseKB(pixelR: Float, fx: Float, fy: Float, k1: Float, k2: Float, k3: Float, k4: Float) -> Float {
        let rd = pixelR / ((fx + fy) / 2.0)  // average focal length for radial
        var theta = rd
        for _ in 0..<10 {
            let t2 = theta * theta
            let t3 = t2 * theta
            let f = theta + k1 * t3 + k2 * t2 * t3 + k3 * t2 * t2 * t3 + k4 * t2 * t2 * t2 * t3 - rd
            let df = 1.0 + 3.0 * k1 * t2 + 5.0 * k2 * t2 * t2 + 7.0 * k3 * t2 * t2 * t2 + 9.0 * k4 * t2 * t2 * t2 * t2
            if abs(df) > 1e-10 { theta -= f / df }
        }
        return max(0, theta)
    }

    func maskPixelRadiiToControlPoints() -> [Point3DFloat] {
        let count = Int(maskNumPoints) ?? 64
        let radii = getMaskPixelRadii()
        let fxV = Float(fx) ?? 1000
        let fyV = Float(fy) ?? 1000
        let k1V = Float(k1) ?? 0, k2V = Float(k2) ?? 0, k3V = Float(k3) ?? 0, k4V = Float(k4) ?? 0
        let imgW = Float(imageWidth) ?? 2048
        let imgH = Float(imageHeight) ?? 2048
        let centerX = imgW / 2
        let centerY = imgH / 2

        // Fixed plane: Apple standard planeAngle = 10°, z = -sin(10°) = -0.17364822
        let zPlane: Float = -0.17364822
        let maxTheta: Float = 89.0 * .pi / 180.0  // clamp to 89° max (just under hemisphere)

        return (0..<count).map { i in
            let sweepAngle = Float.pi - Float(i) / Float(count) * 2.0 * .pi
            let pixelR = radii[i]

            var px = centerX + pixelR * cos(sweepAngle)
            var py = centerY - pixelR * sin(sweepAngle)  // negate Y: image Y increases downward

            // Clamp pixel position to stay within image bounds (1px margin)
            px = max(1, min(imgW - 1, px))
            py = max(1, min(imgH - 1, py))

            let xd = (px - centerX) / fxV
            let yd = (py - centerY) / fyV
            let rd = sqrt(xd * xd + yd * yd)

            // Newton's method to invert KB: find theta such that theta_d(theta) = rd
            var theta = rd
            for _ in 0..<10 {
                let t2 = theta * theta
                let t3 = t2 * theta
                let f = theta + k1V * t3 + k2V * t2 * t3 + k3V * t2 * t2 * t3 + k4V * t2 * t2 * t2 * t3 - rd
                let df = 1.0 + 3.0 * k1V * t2 + 5.0 * k2V * t2 * t2 + 7.0 * k3V * t2 * t2 * t2 + 9.0 * k4V * t2 * t2 * t2 * t2
                if abs(df) > 1e-10 { theta -= f / df }
            }

            // Clamp to max 85° from forward
            theta = min(theta, maxTheta)

            let dx: Float, dy: Float, dz: Float
            if rd > 1e-6 {
                dx = sin(theta) * (xd / rd)
                dy = sin(theta) * (yd / rd)
                dz = -cos(theta)
            } else {
                dx = 0; dy = 0; dz = -1
            }

            // Project direction onto the z-plane: find t such that t*dz = zPlane
            let t = zPlane / dz
            return Point3DFloat(x: t * dx, y: t * dy, z: zPlane)
        }
    }

    // Status
    @Published var statusMessage: String = ""
    @Published var isGenerating: Bool = false
    @Published var gyroflowInfo: String = ""

    // --- Video Preview ---
    @Published var videoURL: URL?
    @Published var videoInfo: String = ""
    @Published var currentTime: Double = 0
    @Published var scrubTime: Double = 0
    var scrubDebounceTask: Task<Void, Never>?
    var extractionTask: Task<Void, Never>?
    @Published var duration: Double = 1
    @Published var leftFrame: CGImage?
    @Published var rightFrame: CGImage?
    @Published var previewMode: PreviewMode = .anaglyph
    @Published var isLoadingFrame = false
    @Published var swapEyes: Bool = true
    @Published var flipILPDCalibration: Bool = false
    @Published var showInjectAlert: Bool = false
    @Published var injectAlertMessage: String = ""
    @Published var showCrosshair: Bool = true
    @Published var showMask: Bool = true
    // maskAdjustMode is declared in the mask section above
    @Published var selectedMaskPoint: Int = -1  // currently selected mask point index (-1 = none)
    var isDraggingAlignment: Bool = false  // suppress composite rebuild during alignment drag
    @Published var rectFOV: Double = 90
    @Published var rectYaw: Double = 0
    @Published var rectPitch: Double = 0
    // Preview zoom/pan
    @Published var previewZoom: CGFloat = 1.0
    @Published var previewPanX: CGFloat = 0
    @Published var previewPanY: CGFloat = 0

    var videoWidth: Int = 0
    var videoHeight: Int = 0
    var eyeWidth: Int = 0
    var eyeHeight: Int = 0
    var videoFormat: VideoFormat = .sbs

    enum VideoFormat: String { case sbs = "SBS", tab = "Top/Bottom", dualStream = "Dual Stream (OSV)", mvhevc = "MV-HEVC" }

    let gpuRenderer = GPURenderer()
    @Published var cachedComposite: NSImage?
    private var compositeDebounceTask: Task<Void, Never>?

    private var asset: AVAsset?
    private var imgGenerator: AVAssetImageGenerator?
    private var imgGenerator2: AVAssetImageGenerator?  // second stream for OSV

    enum DistortionModel: String, CaseIterable {
        case opencvFisheye = "OpenCV Fisheye (k1-k4)"
    }

    enum Eye { case left, right }

    // MARK: - Project Save/Load

    struct ProjectData: Codable {
        var cameraID: String
        var calibrationName: String
        var imageWidth: String
        var imageHeight: String
        var fx: String; var fy: String
        var k1: String; var k2: String; var k3: String; var k4: String
        var leftCx: String; var leftCy: String
        var rightCx: String; var rightCy: String
        var stereoRotX: String; var stereoRotY: String; var stereoRotZ: String
        var hfov: String
        var thetaSteps: String; var phiSteps: String
        var baseline: String
        var frameRate: String
        var maskRadius: String?; var maskEdgeWidth: String; var maskControlPoints: String?
        var maskCenterY: String?; var maskPlaneAngle: String?; var maskAngle: String?; var maskEdgeTreatment: String?
        var maskRadii: [Float]?  // legacy per-point multipliers
        var maskNumPoints: String?
        var maskPixelRadii: [Float]?
        var maskMode: String?
        var videoPath: String?
        var swapEyes: Bool?
    }

    func saveProject() -> ProjectData {
        ProjectData(
            cameraID: cameraID, calibrationName: calibrationName,
            imageWidth: imageWidth, imageHeight: imageHeight,
            fx: fx, fy: fy, k1: k1, k2: k2, k3: k3, k4: k4,
            leftCx: leftCx, leftCy: leftCy, rightCx: rightCx, rightCy: rightCy,
            stereoRotX: stereoRotX, stereoRotY: stereoRotY, stereoRotZ: stereoRotZ,
            hfov: hfov, thetaSteps: thetaSteps, phiSteps: phiSteps,
            baseline: baseline, frameRate: frameRate,
            maskEdgeWidth: maskEdgeWidth,
            maskPlaneAngle: maskPlaneAngle, maskEdgeTreatment: maskEdgeTreatment,
            maskNumPoints: maskNumPoints, maskPixelRadii: maskPixelRadii,
            maskMode: maskMode.rawValue,
            videoPath: videoURL?.path, swapEyes: swapEyes
        )
    }

    func loadProject(_ p: ProjectData) {
        cameraID = p.cameraID; calibrationName = p.calibrationName
        imageWidth = p.imageWidth; imageHeight = p.imageHeight
        fx = p.fx; fy = p.fy
        k1 = p.k1; k2 = p.k2; k3 = p.k3; k4 = p.k4
        leftCx = p.leftCx; leftCy = p.leftCy
        rightCx = p.rightCx; rightCy = p.rightCy
        stereoRotX = p.stereoRotX; stereoRotY = p.stereoRotY; stereoRotZ = p.stereoRotZ
        hfov = p.hfov; thetaSteps = p.thetaSteps; phiSteps = p.phiSteps
        baseline = p.baseline; frameRate = p.frameRate
        maskEdgeWidth = p.maskEdgeWidth
        if let pa = p.maskPlaneAngle { maskPlaneAngle = pa }
        if let et = p.maskEdgeTreatment { maskEdgeTreatment = et }
        if let np = p.maskNumPoints { maskNumPoints = np }
        if let pr = p.maskPixelRadii { maskPixelRadii = pr }
        if let mm = p.maskMode, let mode = MaskMode(rawValue: mm) { maskMode = mode }
        if let se = p.swapEyes { swapEyes = se }
        statusMessage = "Project loaded"
    }

    func importGyroflow(url: URL, eye: Eye = .left) {
        do {
            let data = try Data(contentsOf: url)
            let profile = try JSONDecoder().decode(GyroflowProfile.self, from: data)

            // Determine calibration resolution and target resolution
            let calibDim = profile.calib_dimension ?? profile.orig_dimension
            let calibW = Float(calibDim?.w ?? 2048)
            let calibH = Float(calibDim?.h ?? 2048)

            // If video is loaded, keep its resolution and scale params; otherwise use calib res
            let targetW: Float
            let targetH: Float
            if videoURL != nil, let vw = Float(imageWidth), let vh = Float(imageHeight), vw > 0, vh > 0 {
                targetW = vw
                targetH = vh
            } else {
                imageWidth = "\(Int(calibW))"
                imageHeight = "\(Int(calibH))"
                targetW = calibW
                targetH = calibH
            }
            let scaleX = Double(targetW / calibW)
            let scaleY = Double(targetH / calibH)

            if let fp = profile.fisheye_params {
                let cm = fp.camera_matrix
                let dc = fp.distortion_coeffs
                distortionModel = .opencvFisheye

                // Focal length scaled from calib to target resolution
                if cm.count >= 3 && cm[0].count >= 3 {
                    fx = String(format: "%.4f", cm[0][0] * scaleX)
                    fy = String(format: "%.4f", cm[1][1] * scaleY)
                }

                // Kannala-Brandt k1-k4 (unitless, no scaling)
                k1 = dc.count > 0 ? String(format: "%.8f", dc[0]) : "0.0"
                k2 = dc.count > 1 ? String(format: "%.8f", dc[1]) : "0.0"
                k3 = dc.count > 2 ? String(format: "%.8f", dc[2]) : "0.0"
                k4 = dc.count > 3 ? String(format: "%.8f", dc[3]) : "0.0"

                // Principal point scaled from calib to target resolution
                if cm.count >= 3 && cm[0].count >= 3 {
                    let cxVal = String(format: "%.4f", cm[0][2] * scaleX)
                    let cyVal = String(format: "%.4f", cm[1][2] * scaleY)
                    switch eye {
                    case .left:
                        leftCx = cxVal
                        leftCy = cyVal
                        // If first import, also set right to same
                        if rightCx == "1024.0" && rightCy == "1024.0" {
                            rightCx = cxVal
                            rightCy = cyVal
                        }
                    case .right:
                        rightCx = cxVal
                        rightCy = cyVal
                    }
                }

                // Compute FOV using compute_deo_params method:
                // 1. Find edge of fisheye circle: R = min(W,H)/2 (inscribed circle)
                // 2. Sample points around rim, convert to normalized KB radius
                // 3. Invert KB model with Newton's method to find theta_max
                // 4. Clamp to monotonicity limit
                if let w = Float(imageWidth), let h = Float(imageHeight),
                   let fxVal = Float(fx), let fyVal = Float(fy),
                   let cxVal = Float(leftCx), let cyVal = Float(leftCy),
                   let k1V = Float(k1), let k2V = Float(k2),
                   let k3V = Float(k3), let k4V = Float(k4) {

                    // Step 1: Inscribed circle radius in pixels
                    let Rpx = min(w, h) / 2.0

                    // Step 2: Sample points around the rim and compute normalized KB radius
                    // tex_cx/cy = center of image (w/2, h/2), not the principal point
                    let tex_cx = w / 2.0
                    let tex_cy = h / 2.0
                    let numSamples = 64
                    var rSamples: [Float] = []
                    for i in 0..<numSamples {
                        let angle = Float(i) / Float(numSamples) * 2.0 * .pi
                        let xs = (tex_cx + Rpx * cos(angle) - cxVal) / fxVal
                        let ys = (tex_cy + Rpx * sin(angle) - cyVal) / fyVal
                        rSamples.append(sqrt(xs * xs + ys * ys))
                    }
                    rSamples.sort()
                    let rEdge = rSamples[rSamples.count / 2]  // median

                    // Step 3: Find monotonicity limit of KB polynomial
                    // d(theta_d)/d(theta) = 1 + 3*k1*t^2 + 5*k2*t^4 + 7*k3*t^6 + 9*k4*t^8
                    // Find where this derivative = 0 (polynomial starts turning around)
                    // Search by stepping through theta values
                    var monoLimit: Float = .pi  // default: full 180°
                    var rAtMonoLimit: Float = .greatestFiniteMagnitude
                    for step in 1...1000 {
                        let t = Float(step) * 0.001 * .pi  // 0 to π
                        let t2 = t * t
                        let deriv = 1 + 3 * k1V * t2 + 5 * k2V * t2 * t2 + 7 * k3V * t2 * t2 * t2 + 9 * k4V * t2 * t2 * t2 * t2
                        if deriv <= 0 {
                            monoLimit = t
                            let t3 = t2 * t
                            rAtMonoLimit = t + k1V * t3 + k2V * t2 * t3 + k3V * t2 * t2 * t3 + k4V * t2 * t2 * t2 * t3
                            break
                        }
                    }

                    // Step 4: Invert KB model to find theta_max from r_edge
                    var thetaMax: Float
                    if rEdge >= rAtMonoLimit {
                        // Clamp to just below mono limit
                        thetaMax = monoLimit * 0.99
                    } else {
                        // Newton's method: solve r(θ) = θ + k1·θ³ + k2·θ⁵ + k3·θ⁷ + k4·θ⁹ = r_edge
                        thetaMax = rEdge  // initial guess
                        for _ in 0..<50 {
                            let t2 = thetaMax * thetaMax
                            let t3 = t2 * thetaMax
                            let f = thetaMax + k1V * t3 + k2V * t2 * t3 + k3V * t2 * t2 * t3 + k4V * t2 * t2 * t2 * t3 - rEdge
                            let df = 1 + 3 * k1V * t2 + 5 * k2V * t2 * t2 + 7 * k3V * t2 * t2 * t2 + 9 * k4V * t2 * t2 * t2 * t2
                            if abs(df) < 1e-12 { break }
                            let step = f / df
                            thetaMax -= step
                            if abs(step) < 1e-8 { break }
                        }
                    }

                    // Full FOV = 2 × theta_max in degrees
                    let fovDeg = 2.0 * thetaMax * 180.0 / .pi
                    hfov = String(format: "%.1f", min(max(fovDeg, 10.0), 360.0))
                }
            }

            if let fps = profile.fps {
                let roundedFPS = [24, 25, 30, 50, 60, 90, 100, 120].min(by: { abs(Double($0) - fps) < abs(Double($1) - fps) }) ?? 90
                frameRate = "\(roundedFPS)"
            }

            // Build info string
            var info = "Imported (\(eye == .left ? "Left" : "Right")): "
            if let brand = profile.camera_brand { info += brand + " " }
            if let model = profile.camera_model { info += model }
            if let lens = profile.lens_model, !lens.isEmpty { info += " (\(lens))" }
            if let rms = profile.fisheye_params?.RMS_error {
                info += String(format: " | RMS: %.3f", rms)
            }
            gyroflowInfo = info

            if let name = profile.name {
                calibrationName = name.replacingOccurrences(of: " ", with: "-").lowercased()
            }
            if let model = profile.camera_model {
                cameraID = model.uppercased().replacingOccurrences(of: " ", with: "-")
            }

            statusMessage = "Gyroflow profile loaded successfully!"
        } catch {
            statusMessage = "Error loading Gyroflow JSON: \(error.localizedDescription)"
        }
    }

    func importAIME(url: URL) async {
        do {
            let device = MTLCreateSystemDefaultDevice()!
            let venue = try await VenueDescriptor(aimeURL: url, device: device)
            let cams = await venue.cameras

            guard let cam = cams.first else {
                statusMessage = "Error: .aime contains no cameras"
                return
            }

            cameraID = cam.id
            calibrationName = cam.calibration.name
            frameRate = "\(cam.presentationFrameRate)"

            // Extract origin (baseline)
            let origin = cam.calibration.origin
            let originMirror = Mirror(reflecting: origin)
            for child in originMirror.children {
                if child.label == "right" {
                    let ptMirror = Mirror(reflecting: child.value)
                    for ptChild in ptMirror.children {
                        if ptChild.label == "x", let xVal = ptChild.value as? Float {
                            baseline = String(format: "%.4f", xVal)
                        }
                    }
                }
            }

            // Extract mask parameters
            if case .dynamic(let mask) = cam.calibration.mask {
                maskEdgeWidth = String(format: "%.1f", mask.edgeWidthInDegrees)
                maskNumPoints = "\(mask.leftControlPoints.count)"
            }

            // Extract mesh USDZ → convert to USDA → parse pole vertex UV to recover cx/cy
            if case .usdzMesh(let meshCal) = cam.calibration.type {
                let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                let usdzPath = tmpDir.appendingPathComponent("mesh.usdz")
                let usdaPath = tmpDir.appendingPathComponent("mesh.usda")
                try meshCal.usdzData.write(to: usdzPath)

                // Convert USDZ → USDA for text parsing
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                proc.arguments = ["usdcat", usdzPath.path, "-o", usdaPath.path]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try proc.run()
                proc.waitUntilExit()

                if let usdaData = try? String(contentsOf: usdaPath, encoding: .utf8) {
                    // Find pole vertex (0,0,-1) UV for each eye to recover cx/cy normalized
                    func findPoleUV(eye: String) -> (Float, Float)? {
                        guard let meshStart = usdaData.range(of: "def Mesh \"\(eye)\"") else { return nil }
                        let searchEnd = usdaData.range(of: "def Mesh", range: meshStart.upperBound..<usdaData.endIndex)?.lowerBound ?? usdaData.endIndex
                        let section = String(usdaData[meshStart.lowerBound..<searchEnd])

                        // Extract points and UVs
                        guard let ptsRange = section.range(of: "point3f[] points = ["),
                              let ptsEnd = section.range(of: "]", range: ptsRange.upperBound..<section.endIndex),
                              let uvRange = section.range(of: "float2[] primvars:st = ["),
                              let uvEnd = section.range(of: "]", range: uvRange.upperBound..<section.endIndex)
                        else { return nil }

                        let ptsStr = String(section[ptsRange.upperBound..<ptsEnd.lowerBound])
                        let uvStr = String(section[uvRange.upperBound..<uvEnd.lowerBound])

                        // Parse tuples — extract (x, y, z) groups
                        func parseTuples(_ s: String) -> [String] {
                            var result: [String] = []
                            var i = s.startIndex
                            while i < s.endIndex {
                                if s[i] == "(" {
                                    if let close = s.range(of: ")", range: i..<s.endIndex) {
                                        let inner = String(s[s.index(after: i)..<close.lowerBound])
                                        result.append(inner)
                                        i = close.upperBound
                                    } else { break }
                                } else { i = s.index(after: i) }
                            }
                            return result
                        }

                        let pts = parseTuples(ptsStr)
                        let uvs = parseTuples(uvStr)

                        guard pts.count == uvs.count else { return nil }

                        // Find vertex closest to (0,0,-1)
                        var minDist: Float = 999
                        var poleU: Float = 0.5, poleV: Float = 0.5
                        for i in 0..<pts.count {
                            let xyzParts = pts[i].split(separator: ",")
                            guard xyzParts.count >= 3 else { continue }
                            let x = Float(xyzParts[0].trimmingCharacters(in: CharacterSet.whitespaces)) ?? 0
                            let y = Float(xyzParts[1].trimmingCharacters(in: CharacterSet.whitespaces)) ?? 0
                            let z = Float(xyzParts[2].trimmingCharacters(in: CharacterSet.whitespaces)) ?? 0
                            let dist = sqrt(x*x + y*y + (z+1)*(z+1))
                            if dist < minDist {
                                minDist = dist
                                let uvParts = uvs[i].split(separator: ",")
                                if uvParts.count >= 2 {
                                    poleU = Float(uvParts[0].trimmingCharacters(in: CharacterSet.whitespaces)) ?? 0.5
                                    poleV = Float(uvParts[1].trimmingCharacters(in: CharacterSet.whitespaces)) ?? 0.5
                                }
                            }
                        }
                        return (poleU, poleV)
                    }

                    // If we have imageWidth/imageHeight, compute absolute cx/cy
                    let imgW = Float(imageWidth) ?? 2048
                    let imgH = Float(imageHeight) ?? 2048

                    if let (lu, lv) = findPoleUV(eye: "_0_Left") {
                        leftCx = String(format: "%.1f", lu * imgW)
                        leftCy = String(format: "%.1f", lv * imgH)
                    }
                    if let (ru, rv) = findPoleUV(eye: "_0_Right") {
                        rightCx = String(format: "%.1f", ru * imgW)
                        rightCy = String(format: "%.1f", rv * imgH)
                    }
                }

                statusMessage = "Loaded \(cam.id): \(cam.calibration.name) (\(meshCal.usdzData.count) bytes mesh)"
                gyroflowInfo = "Imported .aime: \(url.lastPathComponent) | \(cams.count) camera(s) | mesh: \(meshCal.name)"

                try? FileManager.default.removeItem(at: tmpDir)
            } else {
                statusMessage = "Loaded \(cam.id): \(cam.calibration.name) (non-mesh calibration type)"
                gyroflowInfo = "Imported .aime: \(url.lastPathComponent) | \(cams.count) camera(s)"
            }

        } catch {
            statusMessage = "Error loading .aime: \(error.localizedDescription)"
        }
    }

    func exportILPD(to url: URL) {
        let imgW = Int(imageWidth) ?? 2048
        let imgH = Int(imageHeight) ?? 2048
        let fxV = Double(fx) ?? 1000, fyV = Double(fy) ?? 1000
        let k1V = Double(k1) ?? 0, k2V = Double(k2) ?? 0, k3V = Double(k3) ?? 0, k4V = Double(k4) ?? 0
        let lCx = Double(leftCx) ?? Double(imgW)/2, lCy = Double(leftCy) ?? Double(imgH)/2
        let rCx = Double(rightCx) ?? Double(imgW)/2, rCy = Double(rightCy) ?? Double(imgH)/2
        let rotX = Double(stereoRotX) ?? 0, rotY = Double(stereoRotY) ?? 0, rotZ = Double(stereoRotZ) ?? 0
        let baselineV = Double(baseline) ?? 0.065
        let hfovV = Double(hfov) ?? 190
        let edgeV = Double(maskEdgeWidth) ?? 2.5

        // Get mask control points from current mask state
        var maskPts: [[Double]]? = nil
        if maskMode == .custom {
            let pts = maskPixelRadiiToControlPoints()
            if !pts.isEmpty {
                maskPts = pts.map { [Double($0.x), Double($0.y), Double($0.z)] }
            }
        }

        statusMessage = "Fitting KB→Mei-Rives model..."

        // Generate deterministic camera UUID from cameraID string, and a fresh calibration UUID
        let cameraUUID = UUID(uuidFromName: cameraID).uuidString.lowercased()
        let calibrationUUID = UUID().uuidString.lowercased()

        let ilpdJSON = MeiRivesFitter.generateILPD(
            cameraID: cameraUUID, calibrationName: calibrationName,
            calibrationUUID: calibrationUUID,
            imageWidth: imgW, imageHeight: imgH,
            fxL: fxV, fyL: fyV, cxL: lCx, cyL: lCy,
            fxR: fxV, fyR: fyV, cxR: rCx, cyR: rCy,
            k1: k1V, k2: k2V, k3: k3V, k4: k4V,
            stereoRotX: rotX, stereoRotY: rotY, stereoRotZ: rotZ,
            baseline: baselineV, maskControlPoints: maskPts,
            maskEdgeWidth: edgeV, hfov: hfovV, vfov: hfovV,
            flipLR: flipILPDCalibration
        )

        // Use {cameraUUID}.{calibrationUUID}.ilpd naming convention
        let ilpdFilename = "\(cameraUUID).\(calibrationUUID).ilpd"
        let ilpdURL = url.deletingLastPathComponent().appendingPathComponent(ilpdFilename)

        do {
            try ilpdJSON.write(to: ilpdURL, atomically: true, encoding: .utf8)
            let size = (try? FileManager.default.attributesOfItem(atPath: ilpdURL.path)[.size] as? Int) ?? 0
            statusMessage = "Exported \(ilpdFilename) (\(size / 1024) KB) — KB→Mei-Rives fit"
        } catch {
            statusMessage = "Error exporting ILPD: \(error.localizedDescription)"
        }
    }

    /// Generate ILPD JSON string using current parameters (shared by exportILPD and injectILPD)
    private func generateILPDJSON() -> String? {
        let imgW = Int(imageWidth) ?? 2048
        let imgH = Int(imageHeight) ?? 2048
        let fxV = Double(fx) ?? 1000, fyV = Double(fy) ?? 1000
        let k1V = Double(k1) ?? 0, k2V = Double(k2) ?? 0, k3V = Double(k3) ?? 0, k4V = Double(k4) ?? 0
        let lCx = Double(leftCx) ?? Double(imgW)/2, lCy = Double(leftCy) ?? Double(imgH)/2
        let rCx = Double(rightCx) ?? Double(imgW)/2, rCy = Double(rightCy) ?? Double(imgH)/2
        let rotX = Double(stereoRotX) ?? 0, rotY = Double(stereoRotY) ?? 0, rotZ = Double(stereoRotZ) ?? 0
        let baselineV = Double(baseline) ?? 0.065
        let hfovV = Double(hfov) ?? 190
        let edgeV = Double(maskEdgeWidth) ?? 2.5

        var maskPts: [[Double]]? = nil
        if maskMode == .custom {
            let pts = maskPixelRadiiToControlPoints()
            if !pts.isEmpty {
                maskPts = pts.map { [Double($0.x), Double($0.y), Double($0.z)] }
            }
        }

        let cameraUUID = UUID(uuidFromName: cameraID).uuidString.lowercased()
        let calibrationUUID = UUID().uuidString.lowercased()

        return MeiRivesFitter.generateILPD(
            cameraID: cameraUUID, calibrationName: calibrationName,
            calibrationUUID: calibrationUUID,
            imageWidth: imgW, imageHeight: imgH,
            fxL: fxV, fyL: fyV, cxL: lCx, cyL: lCy,
            fxR: fxV, fyR: fyV, cxR: rCx, cyR: rCy,
            k1: k1V, k2: k2V, k3: k3V, k4: k4V,
            stereoRotX: rotX, stereoRotY: rotY, stereoRotZ: rotZ,
            baseline: baselineV, maskControlPoints: maskPts,
            maskEdgeWidth: edgeV, hfov: hfovV, vfov: hfovV,
            flipLR: flipILPDCalibration
        )
    }

    func injectILPDToVideo(outputURL: URL) {
        guard let videoURL = videoURL else {
            statusMessage = "No video loaded"
            return
        }
        guard let ilpdJSON = generateILPDJSON() else {
            statusMessage = "Error generating ILPD"
            return
        }

        statusMessage = "Injecting ILPD metadata into video..."

        // Write ILPD to temp file
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpILPD = tmpDir.appendingPathComponent("inject_temp.ilpd")
        do {
            try ilpdJSON.write(to: tmpILPD, atomically: true, encoding: .utf8)
        } catch {
            statusMessage = "Error writing temp ILPD: \(error.localizedDescription)"
            return
        }

        // Find inject_ilpd_v2.py: check bundle Resources first, then next to app
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let scriptCandidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/inject_ilpd_v2.py"),
            appDir.appendingPathComponent("inject_ilpd_v2.py"),
            URL(fileURLWithPath: "/Users/siyangqi/Downloads/Aime investigate/inject_ilpd_v2.py")
        ]
        guard let scriptURL = scriptCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            statusMessage = "Error: inject_ilpd_v2.py not found"
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [scriptURL.path, videoURL.path, tmpILPD.path, outputURL.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            proc.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            if proc.terminationStatus == 0 {
                let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
                injectAlertMessage = "Saved to \(outputURL.lastPathComponent) (\(size / 1024 / 1024) MB)"
                showInjectAlert = true
                statusMessage = "Injected ILPD → \(outputURL.lastPathComponent)"
            } else {
                injectAlertMessage = "Injection failed: \(output.suffix(200))"
                showInjectAlert = true
                statusMessage = "Injection failed"
            }
        } catch {
            injectAlertMessage = "Error: \(error.localizedDescription)"
            showInjectAlert = true
            statusMessage = "Error running injector"
        }

        try? FileManager.default.removeItem(at: tmpILPD)
    }

    func generateAIME(to url: URL) async {
        isGenerating = true
        statusMessage = "Generating projection mesh..."

        do {
            guard let imgW = Float(imageWidth), let imgH = Float(imageHeight),
                  let fxV = Float(fx), let fyV = Float(fy),
                  let lCx = Float(leftCx), let lCy = Float(leftCy),
                  let rCx = Float(rightCx), let rCy = Float(rightCy),
                  let k1V = Float(k1), let k2V = Float(k2),
                  let k3V = Float(k3), let k4V = Float(k4),
                  let sRotX = Float(stereoRotX), let sRotY = Float(stereoRotY), let sRotZ = Float(stereoRotZ),
                  let hfovV = Float(hfov),
                  let thetaV = Int(thetaSteps), let phiV = Int(phiSteps),
                  let baselineV = Float(baseline),
                  let fpsV = Float(frameRate),
                  let maskEdgeV = Float(maskEdgeWidth),
                  let maskPtsV = Int(maskNumPoints)
            else {
                statusMessage = "Error: Invalid number in one of the fields"
                isGenerating = false
                return
            }

            let hasRotation = (abs(sRotX) > 0.001 || abs(sRotY) > 0.001 || abs(sRotZ) > 0.001)
            let samePrincipalPoint = (lCx == rCx && lCy == rCy)

            // Build stereo rotation quaternion (half-angle applied opposite to each eye)
            func makeRotQuat(_ x: Float, _ y: Float, _ z: Float) -> simd_quatf {
                // Reverse order (Rx * Ry * Rz) to match preview's inverse-rotation convention
                let qx = simd_quatf(angle: x * .pi / 180.0, axis: SIMD3<Float>(1, 0, 0))
                let qy = simd_quatf(angle: y * .pi / 180.0, axis: SIMD3<Float>(0, 1, 0))
                let qz = simd_quatf(angle: z * .pi / 180.0, axis: SIMD3<Float>(0, 0, 1))
                return qx * qy * qz
            }

            // Left eye: rotate by -half the stereo offset
            var (leftVerts, leftUVs, leftIndices) = MeshGen.generateHemisphereMesh(
                imageWidth: imgW, imageHeight: imgH,
                fx: fxV, fy: fyV, cx: lCx, cy: lCy,
                k1: k1V, k2: k2V, k3: k3V, k4: k4V,
                hfov: hfovV, thetaSteps: thetaV, phiSteps: phiV
            )
            if hasRotation {
                let qLeft = makeRotQuat(sRotX / 2, sRotY / 2, sRotZ / 2)
                leftVerts = leftVerts.map { qLeft.act($0) }
            }

            // Right eye: rotate by +half the stereo offset
            var rightVerts: [SIMD3<Float>]
            let rightUVs: [SIMD2<Float>]
            let rightIndices: [UInt32]

            if samePrincipalPoint && !hasRotation {
                rightVerts = leftVerts
                rightUVs = leftUVs
                rightIndices = leftIndices
            } else {
                (rightVerts, rightUVs, rightIndices) = MeshGen.generateHemisphereMesh(
                    imageWidth: imgW, imageHeight: imgH,
                    fx: fxV, fy: fyV, cx: rCx, cy: rCy,
                    k1: k1V, k2: k2V, k3: k3V, k4: k4V,
                    hfov: hfovV, thetaSteps: thetaV, phiSteps: phiV
                )
                if hasRotation {
                    let qRight = makeRotQuat(-sRotX / 2, -sRotY / 2, -sRotZ / 2)
                    rightVerts = rightVerts.map { qRight.act($0) }
                }
            }

            let totalVerts = leftVerts.count + rightVerts.count
            let totalTris = (leftIndices.count + rightIndices.count) / 3
            let info = [
                samePrincipalPoint ? nil : "per-eye cx/cy",
                hasRotation ? String(format: "stereo rot \u{00B1}%.2f/%.2f/%.2f\u{00B0}", sRotX/2, sRotY/2, sRotZ/2) : nil
            ].compactMap { $0 }.joined(separator: ", ")
            statusMessage = "Mesh: \(totalVerts) verts, \(totalTris) tris\(info.isEmpty ? "" : " (\(info))"). Building USDA..."

            // Build USDA
            let usda = MeshGen.buildFullUSDA(
                leftVerts: leftVerts, leftUVs: leftUVs, leftIndices: leftIndices,
                rightVerts: rightVerts, rightUVs: rightUVs, rightIndices: rightIndices
            )

            // Write temp USDA
            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let usdaURL = tmpDir.appendingPathComponent("mesh.usda")
            let usdcURL = tmpDir.appendingPathComponent("mesh.usdc")
            let usdzURL = tmpDir.appendingPathComponent("mesh.usdz")
            try usda.write(to: usdaURL, atomically: true, encoding: .utf8)

            statusMessage = "Converting USDA -> USDC -> USDZ..."

            // USDA -> USDC
            let usdcProc = Process()
            usdcProc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            usdcProc.arguments = ["usdcat", "--out", usdcURL.path, usdaURL.path]
            try usdcProc.run()
            usdcProc.waitUntilExit()

            // USDC -> USDZ
            let usdzProc = Process()
            usdzProc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            usdzProc.arguments = ["usdzip", usdzURL.path, usdcURL.path]
            try usdzProc.run()
            usdzProc.waitUntilExit()

            let usdzData: Data
            if FileManager.default.fileExists(atPath: usdzURL.path) {
                usdzData = try Data(contentsOf: usdzURL)
            } else {
                usdzData = try MeshGen.createUSDZ(from: usdcURL)
            }

            statusMessage = "Building .aime (USDZ: \(usdzData.count) bytes)..."

            // Build .aime
            let meshCal = ImmersiveCameraMeshCalibration(name: calibrationName + "-mesh", usdzData: usdzData)

            // Generate mask based on mode
            let maskOption: ImmersiveCameraMask?
            switch maskMode {
            case .offMaxFOV:
                // Transparent PNG image mask — maximum FOV, no masking at all
                // Works on Vision Pro but may not work in Immersive Utility
                let width = 8640, height = 4320
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
                let ptr = rep.bitmapData!
                for px in 0..<(width * height) {
                    ptr[px * 4] = 255; ptr[px * 4 + 1] = 255; ptr[px * 4 + 2] = 255; ptr[px * 4 + 3] = 0
                }
                let pngData = rep.representation(using: .png, properties: [:])!
                let imgMask = ImmersiveImageMask(name: "no_mask", maskData: pngData)
                maskOption = .image(imgMask)

            case .offCompatible:
                // Wide-FOV dynamic mask that covers everything — works in Immersive Utility too
                let fullPts = (0..<64).map { i -> Point3DFloat in
                    let angle = Float.pi - Float(i) / 64.0 * 2.0 * .pi
                    return Point3DFloat(x: 1.0 * cos(angle), y: 1.0 * sin(angle), z: 0.135716)
                }
                let fullMask = ImmersiveDynamicMask(
                    name: calibrationName + "-mask",
                    stereoRelation: .separate,
                    edgeTreatment: .linear,
                    controlPointInterpolation: .cubicHermite,
                    leftControlPoints: fullPts,
                    rightControlPoints: fullPts,
                    edgeWidthInDegrees: 2.5
                )
                maskOption = .dynamic(fullMask)

            case .custom:
                // User-adjustable per-point mask
                let controlPoints = maskPixelRadiiToControlPoints()
                let dynamicMask = ImmersiveDynamicMask(
                    name: calibrationName + "-mask",
                    stereoRelation: .separate,
                    edgeTreatment: maskEdgeTreatment == "easeInOut" ? .easeInOut : .linear,
                    controlPointInterpolation: .cubicHermite,
                    leftControlPoints: controlPoints,
                    rightControlPoints: controlPoints,
                    edgeWidthInDegrees: maskEdgeV
                )
                maskOption = .dynamic(dynamicMask)
            }

            let calibration = ImmersiveCameraCalibration(
                name: calibrationName,
                type: .usdzMesh(meshCal),
                mask: maskOption,
                positionable: false,
                origin: ImmersiveCameraCalibration.CameraOrigin(
                    left: Point3DFloat(x: -baselineV, y: 0, z: 0),
                    right: Point3DFloat(x: baselineV, y: 0, z: 0)
                ),
                textureMapping: .identity
            )

            let camera = ImmersiveCamera(
                id: cameraID,
                calibration: calibration,
                type: .stereoCamera,
                presentationFrameRate: Int(fpsV)
            )

            let device = MTLCreateSystemDefaultDevice()!
            let venue = VenueDescriptor(device: device)
            try await venue.addCamera(camera)
            try await venue.save(to: url)

            // Verify
            let verify = try await VenueDescriptor(aimeURL: url, device: device)
            let cams = await verify.cameras
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

            statusMessage = "Success! Saved \(url.lastPathComponent) (\(fileSize / 1024) KB) with \(cams.count) camera(s)"

            // Cleanup
            try? FileManager.default.removeItem(at: tmpDir)

        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }

        isGenerating = false
    }

    // MARK: - Video Preview

    nonisolated static let ffmpegPath: String? = {
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ffmpeg").path
        let candidates = [bundled, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }()
    nonisolated static let ffprobePath: String? = {
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ffprobe").path
        let candidates = [bundled, "/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }()
    nonisolated static var hasFFmpeg: Bool { ffmpegPath != nil && ffprobePath != nil }

    func loadVideo(url: URL) {
        guard AIMEViewModel.hasFFmpeg else {
            statusMessage = "⚠️ ffmpeg/ffprobe not found. Install with: brew install ffmpeg"
            return
        }
        print("[loadVideo] url=\(url.path)")
        videoURL = url
        isLoadingFrame = true
        imgGenerator = nil
        imgGenerator2 = nil

        Task {
            do {
                // Use ffprobe to detect format — works for all containers including OSV
                let info = try await probeVideo(url: url)
                self.duration = info.duration
                self.videoWidth = info.width
                self.videoHeight = info.height

                switch info.format {
                case .dualStream:
                    self.videoFormat = .dualStream
                    self.eyeWidth = info.width
                    self.eyeHeight = info.height
                    self.videoInfo = "Dual Stream (OSV) | \(info.width)x\(info.height) per eye | \(String(format: "%.1fs", duration))"

                case .sbs:
                    self.videoFormat = .sbs
                    self.eyeWidth = info.width / 2
                    self.eyeHeight = info.height
                    self.videoInfo = "SBS | \(info.width)x\(info.height) → \(eyeWidth)x\(eyeHeight) per eye | \(String(format: "%.1fs", duration))"

                case .tab:
                    self.videoFormat = .tab
                    self.eyeWidth = info.width
                    self.eyeHeight = info.height / 2
                    self.videoInfo = "Top/Bottom | \(info.width)x\(info.height) → \(eyeWidth)x\(eyeHeight) per eye | \(String(format: "%.1fs", duration))"

                case .mvhevc:
                    self.videoFormat = .mvhevc
                    self.eyeWidth = info.width
                    self.eyeHeight = info.height
                    self.videoInfo = "MV-HEVC Stereo | \(info.width)x\(info.height) | \(String(format: "%.1fs", duration))"

                case .mono:
                    self.videoFormat = .mvhevc  // treat as single-eye
                    self.eyeWidth = info.width
                    self.eyeHeight = info.height
                    self.videoInfo = "Mono | \(info.width)x\(info.height) | \(String(format: "%.1fs", duration))"
                }

                // Set imageWidth/imageHeight to the probed per-eye source resolution
                self.imageWidth = "\(self.eyeWidth)"
                self.imageHeight = "\(self.eyeHeight)"

                // Auto-center cx/cy if still at defaults
                let cx = String(format: "%.1f", Float(self.eyeWidth) / 2)
                let cy = String(format: "%.1f", Float(self.eyeHeight) / 2)
                if self.leftCx == "1024.0" { self.leftCx = cx }
                if self.leftCy == "1024.0" { self.leftCy = cy }
                if self.rightCx == "1024.0" { self.rightCx = cx }
                if self.rightCy == "1024.0" { self.rightCy = cy }

                // Also try AVFoundation for SBS/TAB (faster scrubbing)
                if info.format == .sbs || info.format == .tab {
                    let a = AVURLAsset(url: url)
                    self.asset = a
                    let gen = AVAssetImageGenerator(asset: a)
                    gen.appliesPreferredTrackTransform = true
                    gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
                    gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
                    gen.maximumSize = CGSize(width: info.width, height: info.height)
                    self.imgGenerator = gen
                }

                await extractFrame(at: 0)
            } catch {
                videoInfo = "Error: \(error.localizedDescription)"
                isLoadingFrame = false
            }
        }
    }

    enum DetectedFormat { case sbs, tab, dualStream, mvhevc, mono }
    struct VideoInfo { var width: Int; var height: Int; var duration: Double; var format: DetectedFormat; var videoStreamCount: Int }

    /// Use ffprobe to detect video format — runs off main thread
    private nonisolated func probeVideo(url: URL) async throws -> VideoInfo {
        try await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: AIMEViewModel.ffprobePath!)
            proc.arguments = ["-v", "quiet", "-print_format", "json",
                              "-show_format", "-show_streams", url.path]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            proc.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "AIME", code: 1, userInfo: [NSLocalizedDescriptionKey: "ffprobe returned invalid JSON"])
            }

            let streams = json["streams"] as? [[String: Any]] ?? []
            let format = json["format"] as? [String: Any] ?? [:]
            let dur = Double(format["duration"] as? String ?? "0") ?? 0

            let videoStreams = streams.filter { s in
                guard (s["codec_type"] as? String) == "video" else { return false }
                let codec = s["codec_name"] as? String ?? ""
                return codec != "mjpeg" && codec != "jpeg"
            }

            guard let first = videoStreams.first,
                  let w = first["width"] as? Int,
                  let h = first["height"] as? Int else {
                throw NSError(domain: "AIME", code: 2, userInfo: [NSLocalizedDescriptionKey: "No video stream found"])
            }

            let detected: DetectedFormat
            if videoStreams.count >= 2 {
                detected = .dualStream
            } else if w > 0 && h > 0 && abs(Double(w) / Double(h) - 2.0) < 0.1 {
                detected = .sbs
            } else if w > 0 && h > 0 && abs(Double(h) / Double(w) - 2.0) < 0.1 {
                detected = .tab
            } else {
                let sideDataList = first["side_data_list"] as? [[String: Any]] ?? []
                let hasStereo = sideDataList.contains { ($0["side_data_type"] as? String)?.contains("Stereo") == true }
                detected = hasStereo ? .mvhevc : .mono
            }

            return VideoInfo(width: w, height: h, duration: dur, format: detected, videoStreamCount: videoStreams.count)
        }.value
    }

    func extractFrame(at time: Double) async {
        guard let videoURL = videoURL else { return }
        isLoadingFrame = true

        do {
            switch videoFormat {
            case .dualStream:
                // OSV: 2 video streams — extract each with ffmpeg -map
                async let leftCG = ffmpegExtractFrame(url: videoURL, time: time, extraArgs: ["-map", "0:v:0"])
                async let rightCG = ffmpegExtractFrame(url: videoURL, time: time, extraArgs: ["-map", "0:v:1"])
                let (l, r) = try await (leftCG, rightCG)
                if swapEyes { self.leftFrame = r; self.rightFrame = l }
                else { self.leftFrame = l; self.rightFrame = r }

            case .sbs:
                // SBS: single frame, split in half. Try AVFoundation first (faster), fall back to ffmpeg
                if let gen = imgGenerator {
                    let cmTime = CMTime(seconds: time, preferredTimescale: 600)
                    let (cgImage, _) = try await gen.image(at: cmTime)
                    let w = cgImage.width; let h = cgImage.height; let halfW = w / 2
                    let leftRect = CGRect(x: 0, y: 0, width: halfW, height: h)
                    let rightRect = CGRect(x: halfW, y: 0, width: halfW, height: h)
                    if swapEyes {
                        self.leftFrame = cgImage.cropping(to: leftRect)
                        self.rightFrame = cgImage.cropping(to: rightRect)
                    } else {
                        // Default SBS: left half = right eye, right half = left eye
                        self.leftFrame = cgImage.cropping(to: rightRect)
                        self.rightFrame = cgImage.cropping(to: leftRect)
                    }
                } else {
                    // Fallback: ffmpeg for SBS
                    let cg = try await ffmpegExtractFrame(url: videoURL, time: time, extraArgs: [])
                    if let cg = cg {
                        let w = cg.width; let halfW = w / 2; let h = cg.height
                        let l = cg.cropping(to: CGRect(x: 0, y: 0, width: halfW, height: h))
                        let r = cg.cropping(to: CGRect(x: halfW, y: 0, width: halfW, height: h))
                        if swapEyes { self.leftFrame = l; self.rightFrame = r }
                        else { self.leftFrame = r; self.rightFrame = l }
                    }
                }

            case .tab:
                // Top/Bottom: single frame, split top/bottom
                if let gen = imgGenerator {
                    let cmTime = CMTime(seconds: time, preferredTimescale: 600)
                    let (cgImage, _) = try await gen.image(at: cmTime)
                    let w = cgImage.width; let h = cgImage.height; let halfH = h / 2
                    let topRect = CGRect(x: 0, y: 0, width: w, height: halfH)
                    let bottomRect = CGRect(x: 0, y: halfH, width: w, height: halfH)
                    if swapEyes {
                        self.leftFrame = cgImage.cropping(to: bottomRect)
                        self.rightFrame = cgImage.cropping(to: topRect)
                    } else {
                        // Default TAB: top = left eye, bottom = right eye
                        self.leftFrame = cgImage.cropping(to: topRect)
                        self.rightFrame = cgImage.cropping(to: bottomRect)
                    }
                } else {
                    let cg = try await ffmpegExtractFrame(url: videoURL, time: time, extraArgs: [])
                    if let cg = cg {
                        let w = cg.width; let h = cg.height; let halfH = h / 2
                        let top = cg.cropping(to: CGRect(x: 0, y: 0, width: w, height: halfH))
                        let bot = cg.cropping(to: CGRect(x: 0, y: halfH, width: w, height: halfH))
                        if swapEyes { self.leftFrame = bot; self.rightFrame = top }
                        else { self.leftFrame = top; self.rightFrame = bot }
                    }
                }

            case .mvhevc:
                // MV-HEVC: extract both eyes via ffmpeg -view_ids
                let (l, r) = await extractMVHEVCFrames(url: videoURL, time: time)
                videoInfo = "MV-HEVC | L:\(l.map{"\($0.width)x\($0.height)"} ?? "nil") R:\(r.map{"\($0.width)x\($0.height)"} ?? "nil")"
                if swapEyes { self.leftFrame = r ?? l; self.rightFrame = l }
                else { self.leftFrame = l; self.rightFrame = r ?? l }
            }
            self.currentTime = time
            buildComposite()
        } catch {
            videoInfo = "Frame error: \(error.localizedDescription)"
        }
        isLoadingFrame = false
    }

    /// Universal frame extraction via ffmpeg — works for any format
    /// Runs off the main thread to avoid blocking the UI
    /// Tries hwaccel first, falls back to software decode if result is black
    private nonisolated func ffmpegExtractFrame(url: URL, time: Double, extraArgs: [String]) async throws -> CGImage? {
        try await Task.detached {
            func runFFmpeg(hwaccel: Bool) -> CGImage? {
                let bmpPath = FileManager.default.temporaryDirectory
                    .appendingPathComponent("frame_\(UUID().uuidString).bmp").path
                defer { try? FileManager.default.removeItem(atPath: bmpPath) }

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: AIMEViewModel.ffmpegPath!)
                // Split extraArgs: pre-input flags (-view_ids, -map) go before -i
                var preInput: [String] = []
                var postInput: [String] = []
                var i = 0
                while i < extraArgs.count {
                    if extraArgs[i] == "-view_ids" || extraArgs[i] == "-map" {
                        preInput.append(extraArgs[i])
                        if i + 1 < extraArgs.count { preInput.append(extraArgs[i+1]); i += 1 }
                    } else {
                        postInput.append(extraArgs[i])
                    }
                    i += 1
                }

                var args = ["-y"]
                if hwaccel { args += ["-hwaccel", "videotoolbox"] }
                args += preInput
                args += ["-ss", String(format: "%.3f", time), "-i", url.path]
                args += postInput
                args += ["-frames:v", "1", "-update", "1", "-pix_fmt", "rgb24", bmpPath]
                proc.arguments = args
                let stderrPipe = Pipe()
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = stderrPipe

                print("[ffmpeg] args: \(args.joined(separator: " "))")
                do { try proc.run() } catch { print("[ffmpeg] launch error: \(error)"); return nil }
                proc.waitUntilExit()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus != 0 {
                    print("[ffmpeg] exit=\(proc.terminationStatus) stderr=\(String(data: stderrData, encoding: .utf8)?.suffix(200) ?? "?")")
                }

                guard proc.terminationStatus == 0,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: bmpPath)),
                      let nsImage = NSImage(data: data),
                      let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    return nil
                }
                return cg
            }

            // Try with hwaccel first
            if let cg = runFFmpeg(hwaccel: true) {
                // Verify the frame isn't all black (hwaccel can silently fail for MV-HEVC right eye)
                if let dp = cg.dataProvider, let data = dp.data {
                    let ptr = CFDataGetBytePtr(data)!
                    let len = CFDataGetLength(data)
                    let bpp = cg.bitsPerPixel / 8
                    // Sample a few pixels from the center
                    let midY = cg.height / 2, midX = cg.width / 2
                    let bpr = cg.bytesPerRow
                    var hasContent = false
                    for dy in stride(from: -2, through: 2, by: 1) {
                        let off = (midY + dy) * bpr + midX * bpp
                        if off >= 0 && off + 2 < len {
                            if ptr[off] > 2 || ptr[off+1] > 2 || ptr[off+2] > 2 {
                                hasContent = true; break
                            }
                        }
                    }
                    if hasContent { return cg }
                }
            }
            // Fallback: software decode
            return runFFmpeg(hwaccel: false)
        }.value
    }

    /// Extract both eyes from MV-HEVC using ffmpeg
    /// First tries view_ids 0 + 1. If view_ids 1 fails (common for 10-bit), duplicates left eye.
    /// Uses a short timeout for the right eye to avoid zombie processes.
    private nonisolated func extractMVHEVCFrames(url: URL, time: Double) async -> (CGImage?, CGImage?) {
        print("[MVHEVC-ffmpeg] extracting left eye at t=\(time)")
        let l = await ffmpegExtractFrameSimple(url: url, time: time, preInputArgs: ["-view_ids", "1"])

        // Try right eye with a short 5-second timeout — if it hangs, right eye is nil
        print("[MVHEVC-ffmpeg] trying right eye...")
        let r = await ffmpegExtractFrameSimple(url: url, time: time, preInputArgs: ["-view_ids", "0"], timeout: 5)

        print("[MVHEVC-ffmpeg] L=\(l != nil ? "\(l!.width)x\(l!.height)" : "nil") R=\(r != nil ? "\(r!.width)x\(r!.height)" : "nil")")
        return (l, r)
    }

    /// Simple single-pass ffmpeg frame extraction — runs ffmpeg directly on a detached thread
    private nonisolated func ffmpegExtractFrameSimple(url: URL, time: Double, preInputArgs: [String], scaleCap: Int = 0, timeout: Int = 30) async -> CGImage? {
        let bmpPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame_\(UUID().uuidString).bmp").path
        defer { try? FileManager.default.removeItem(atPath: bmpPath) }

        var args = ["-y"] + preInputArgs + ["-ss", String(format: "%.3f", time), "-i", url.path]
        if scaleCap > 0 {
            args += ["-vf", "scale=w='min(\(scaleCap),iw)':h='min(\(scaleCap),ih)'"]
        }
        args += ["-frames:v", "1", "-update", "1", "-pix_fmt", "rgb24", bmpPath]

        print("[ffmpeg-simple] \(args.joined(separator: " "))")

        let timeoutSec = timeout
        let exitCode: Int32 = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: AIMEViewModel.ffmpegPath!)
                proc.arguments = args
                // Use pipes and drain them to prevent buffer deadlock
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                // Drain pipes asynchronously
                outPipe.fileHandleForReading.readabilityHandler = { _ in }
                errPipe.fileHandleForReading.readabilityHandler = { _ in }
                do { try proc.run() } catch {
                    print("[ffmpeg-simple] launch failed: \(error)")
                    continuation.resume(returning: Int32(-1))
                    return
                }
                let pid = proc.processIdentifier
                print("[ffmpeg-simple] launched pid=\(pid)")

                // Poll for completion with timeout
                let deadline = Date().addingTimeInterval(Double(timeoutSec))
                while proc.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if proc.isRunning {
                    print("[ffmpeg-simple] timeout after \(timeoutSec)s, SIGKILL pid=\(pid)")
                    kill(pid, SIGKILL)
                    Thread.sleep(forTimeInterval: 0.5)
                }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let status = proc.isRunning ? Int32(-9) : proc.terminationStatus
                print("[ffmpeg-simple] pid=\(pid) exit=\(status)")
                continuation.resume(returning: status)
            }
        }

        guard exitCode == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: bmpPath)),
              let nsImage = NSImage(data: data),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("[ffmpeg-simple] exit=\(exitCode) file=\(FileManager.default.fileExists(atPath: bmpPath))")
            return nil
        }
        print("[ffmpeg-simple] decoded \(cg.width)x\(cg.height)")
        return cg
    }

    // (frame extraction now handled by ffmpegExtractFrame)

    // Parsed float helpers reading from the text fields
    private var pFx: Float { Float(fx) ?? 825 }
    private var pFy: Float { Float(fy) ?? 825 }
    private var pK1: Float { Float(k1) ?? 0 }
    private var pK2: Float { Float(k2) ?? 0 }
    private var pK3: Float { Float(k3) ?? 0 }
    private var pK4: Float { Float(k4) ?? 0 }
    private var pLCx: Float { Float(leftCx) ?? 1024 }
    private var pLCy: Float { Float(leftCy) ?? 1024 }
    private var pRCx: Float { Float(rightCx) ?? 1024 }
    private var pRCy: Float { Float(rightCy) ?? 1024 }
    private var pHfov: Float { Float(hfov) ?? 190 }

    /// Hash of all preview-affecting parameters — used by .onChange to trigger rebuilds
    var previewHash: String {
        "\(previewMode)\(showCrosshair)\(showMask)\(rectFOV)\(rectYaw)\(rectPitch)\(fx)\(fy)\(k1)\(k2)\(k3)\(k4)\(leftCx)\(leftCy)\(rightCx)\(rightCy)\(hfov)\(imageWidth)\(imageHeight)\(stereoRotX)\(stereoRotY)\(stereoRotZ)\(maskEdgeWidth)\(maskNumPoints)\(maskPixelRadii ?? [])\(maskAdjustMode)\(selectedMaskPoint)\(maskEdgeTreatment)\(maskMode)"
    }

    /// Rebuild composite — runs synchronously during alignment drag, debounced async otherwise
    func rebuildComposite() {
        if isDraggingAlignment {
            buildComposite()
            return
        }
        compositeDebounceTask?.cancel()
        compositeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled, let self = self else { return }
            self.buildComposite()
        }
    }

    private func buildComposite() {
        guard let rawLeft = self.leftFrame, let rawRight = self.rightFrame else {
            self.cachedComposite = nil; return
        }

        let left: CGImage
        let right: CGImage
        let sRX = self.pStereoX / 2, sRY = self.pStereoY / 2, sRZ = self.pStereoZ / 2
        let hasStereoRot = abs(sRX) > 0.0001 || abs(sRY) > 0.0001 || abs(sRZ) > 0.0001
        let isFisheye = [PreviewMode.sideBySide, .anaglyph, .overlay, .leftOnly, .rightOnly].contains(self.previewMode)
        if hasStereoRot && isFisheye {
            left = self.applyFisheyeRotation(frame: rawLeft, cx: self.pLCx, cy: self.pLCy,
                pitch: -sRX, yaw: -sRY, roll: -sRZ) ?? rawLeft
            right = self.applyFisheyeRotation(frame: rawRight, cx: self.pRCx, cy: self.pRCy,
                pitch: sRX, yaw: sRY, roll: sRZ) ?? rawRight
        } else {
            left = rawLeft; right = rawRight
        }

        let maxDim = 2048
        let rawW = left.width, rawH = left.height
        let scale = rawW > maxDim || rawH > maxDim ? Float(maxDim) / Float(max(rawW, rawH)) : Float(1)
        let ew = Int(Float(rawW) * scale), eh = Int(Float(rawH) * scale)

        var img: NSImage?
        switch self.previewMode {
        case .sideBySide: img = self.compositeSBS(left: left, right: right, ew: ew, eh: eh)
        case .anaglyph:   img = self.compositeAnaglyph(left: left, right: right, ew: ew, eh: eh)
        case .overlay:    img = self.compositeOverlay(left: left, right: right, ew: ew, eh: eh)
        case .leftOnly:   img = self.singleEye(left, cx: self.pLCx, cy: self.pLCy, ew: ew, eh: eh)
        case .rightOnly:  img = self.singleEye(right, cx: self.pRCx, cy: self.pRCy, ew: ew, eh: eh)
        case .rectLeft:   img = self.rectReproject(frame: rawLeft, cx: self.pLCx, cy: self.pLCy, ew: ew, eh: eh, stereoSign: -0.5)
        case .rectRight:  img = self.rectReproject(frame: rawRight, cx: self.pRCx, cy: self.pRCy, ew: ew, eh: eh, stereoSign: 0.5)
        case .rectAnaglyph: img = self.rectAnaglyphComposite(left: rawLeft, right: rawRight, ew: ew, eh: eh)
        }

        self.cachedComposite = img
    }

    /// Compute the pixel offset to shift an image so that cx/cy lands at frame center
    private func imageOffset(cx: Float, cy: Float, ew: Int, eh: Int) -> (CGFloat, CGFloat) {
        let origW = Float(imageWidth) ?? Float(ew)
        let origH = Float(imageHeight) ?? Float(eh)
        let sx = Float(ew) / origW, sy = Float(eh) / origH
        // cx/cy are in image coords (cx from left, cy from top)
        // CGContext has Y=0 at bottom
        // Must match shader behavior: increasing cy moves content UP in headset
        // In CG: increasing cy → image shifts down → offY decreases
        let offX = CGFloat(Float(ew) / 2.0 - cx * sx)
        let offY = CGFloat((Float(eh) - cy * sy) - Float(eh) / 2.0)
        return (offX, offY)
    }

    private func singleEye(_ f: CGImage, cx: Float, cy: Float, ew: Int, eh: Int) -> NSImage {
        let s = NSSize(width: ew, height: eh)
        let img = NSImage(size: s); img.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setFillColor(CGColor.black); ctx.fill(CGRect(origin: .zero, size: s))
        let (ox, oy) = imageOffset(cx: cx, cy: cy, ew: ew, eh: eh)
        ctx.draw(f, in: CGRect(x: ox, y: oy, width: CGFloat(ew), height: CGFloat(eh)))
        let imgCx = (Float(imageWidth) ?? Float(ew)) / 2
        let imgCy = (Float(imageHeight) ?? Float(eh)) / 2
        if showMask && maskMode == .custom { drawMaskAt(ctx: ctx, w: ew, h: eh, eyeCx: imgCx, eyeCy: imgCy) }
        if showCrosshair { drawXhairAt(ctx: ctx, w: ew, h: eh) }
        img.unlockFocus(); return img
    }

    private func compositeSBS(left: CGImage, right: CGImage, ew: Int, eh: Int) -> NSImage {
        let s = NSSize(width: ew * 2, height: eh)
        let img = NSImage(size: s); img.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setFillColor(CGColor.black); ctx.fill(CGRect(origin: .zero, size: s))
        let (lox, loy) = imageOffset(cx: pLCx, cy: pLCy, ew: ew, eh: eh)
        let (rox, roy) = imageOffset(cx: pRCx, cy: pRCy, ew: ew, eh: eh)
        ctx.draw(left, in: CGRect(x: lox, y: loy, width: CGFloat(ew), height: CGFloat(eh)))
        ctx.draw(right, in: CGRect(x: CGFloat(ew) + rox, y: roy, width: CGFloat(ew), height: CGFloat(eh)))
        let imgCx = (Float(imageWidth) ?? Float(ew)) / 2
        let imgCy = (Float(imageHeight) ?? Float(eh)) / 2
        if showMask { drawMaskAt(ctx: ctx, w: ew, h: eh, eyeCx: imgCx, eyeCy: imgCy); drawMaskAt(ctx: ctx, w: ew, h: eh, ox: ew, eyeCx: imgCx, eyeCy: imgCy) }
        if showCrosshair { drawXhairAt(ctx: ctx, w: ew, h: eh); drawXhairAt(ctx: ctx, w: ew, h: eh, ox: ew) }
        img.unlockFocus(); return img
    }

    private func compositeAnaglyph(left: CGImage, right: CGImage, ew: Int, eh: Int) -> NSImage {
        // R from left eye, G+B from right eye (no additive blending — direct channel selection)
        let s = NSSize(width: ew, height: eh)

        let bpr = ew * 4
        var lBuf = [UInt8](repeating: 0, count: bpr * eh)
        var rBuf = [UInt8](repeating: 0, count: bpr * eh)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return NSImage(size: s) }
        let bi = CGImageAlphaInfo.premultipliedLast.rawValue
        let (lox, loy) = imageOffset(cx: pLCx, cy: pLCy, ew: ew, eh: eh)
        let (rox, roy) = imageOffset(cx: pRCx, cy: pRCy, ew: ew, eh: eh)
        if let ctx = CGContext(data: &lBuf, width: ew, height: eh, bitsPerComponent: 8, bytesPerRow: bpr, space: cs, bitmapInfo: bi) {
            ctx.draw(left, in: CGRect(x: lox, y: loy, width: CGFloat(ew), height: CGFloat(eh)))
        }
        if let ctx = CGContext(data: &rBuf, width: ew, height: eh, bitsPerComponent: 8, bytesPerRow: bpr, space: cs, bitmapInfo: bi) {
            ctx.draw(right, in: CGRect(x: rox, y: roy, width: CGFloat(ew), height: CGFloat(eh)))
        }

        // Combine: R from left, G+B from right
        var outBuf = [UInt8](repeating: 0, count: bpr * eh)
        for i in stride(from: 0, to: bpr * eh, by: 4) {
            outBuf[i]     = lBuf[i]     // R from left
            outBuf[i + 1] = rBuf[i + 1] // G from right
            outBuf[i + 2] = rBuf[i + 2] // B from right
            outBuf[i + 3] = 255
        }

        let img = NSImage(size: s); img.lockFocus()
        let gctx = NSGraphicsContext.current!.cgContext
        if let outCtx = CGContext(data: &outBuf, width: ew, height: eh, bitsPerComponent: 8, bytesPerRow: bpr, space: cs, bitmapInfo: bi),
           let cg = outCtx.makeImage() {
            gctx.draw(cg, in: CGRect(origin: .zero, size: s))
        }
        let imgCxA = (Float(imageWidth) ?? Float(ew)) / 2
        let imgCyA = (Float(imageHeight) ?? Float(eh)) / 2
        if showMask && maskMode == .custom { drawMaskAt(ctx: gctx, w: ew, h: eh, eyeCx: imgCxA, eyeCy: imgCyA) }
        if showCrosshair { drawXhairAt(ctx: gctx, w: ew, h: eh) }
        img.unlockFocus(); return img
    }

    private func compositeOverlay(left: CGImage, right: CGImage, ew: Int, eh: Int) -> NSImage {
        let s = NSSize(width: ew, height: eh)
        let img = NSImage(size: s); img.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setFillColor(CGColor.black); ctx.fill(CGRect(origin: .zero, size: s))
        let (lox, loy) = imageOffset(cx: pLCx, cy: pLCy, ew: ew, eh: eh)
        let (rox, roy) = imageOffset(cx: pRCx, cy: pRCy, ew: ew, eh: eh)
        ctx.draw(left, in: CGRect(x: lox, y: loy, width: CGFloat(ew), height: CGFloat(eh)))
        ctx.setAlpha(0.5)
        ctx.draw(right, in: CGRect(x: rox, y: roy, width: CGFloat(ew), height: CGFloat(eh)))
        ctx.setAlpha(1.0)
        let imgCxO = (Float(imageWidth) ?? Float(ew)) / 2
        let imgCyO = (Float(imageHeight) ?? Float(eh)) / 2
        if showMask && maskMode == .custom { drawMaskAt(ctx: ctx, w: ew, h: eh, eyeCx: imgCxO, eyeCy: imgCyO) }
        if showCrosshair { drawXhairAt(ctx: ctx, w: ew, h: eh) }
        img.unlockFocus(); return img
    }

    /// Draw crosshair at fixed frame center (the image shifts around it via cx/cy)
    private func drawXhairAt(ctx: CGContext, w: Int, h: Int, ox: Int = 0) {
        ctx.setStrokeColor(CGColor(red: 0, green: 1, blue: 0, alpha: 0.6))
        ctx.setLineWidth(2)
        let cx = CGFloat(ox) + CGFloat(w) / 2.0
        let cy = CGFloat(h) / 2.0
        // Crosshair lines
        ctx.move(to: CGPoint(x: CGFloat(ox), y: cy)); ctx.addLine(to: CGPoint(x: CGFloat(ox + w), y: cy)); ctx.strokePath()
        ctx.move(to: CGPoint(x: cx, y: 0)); ctx.addLine(to: CGPoint(x: cx, y: CGFloat(h))); ctx.strokePath()
        // Center dot
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: CGRect(x: cx - 15, y: cy - 15, width: 30, height: 30))
        // Image circle
        ctx.setLineWidth(2)
        let r = CGFloat(min(w, h)) / 2.0
        ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    }

    /// Get mask point pixel position in composite space.
    /// radiusScale multiplies the pixel radius (for gradient rings: >1.0 = outside boundary)
    func maskPointToPixel(index: Int, w: Int, h: Int, ox: Int = 0, eyeCx: Float, eyeCy: Float, radiusScale: Float = 1.0) -> CGPoint? {
        let imgW = Float(imageWidth) ?? 2048, imgH = Float(imageHeight) ?? 2048
        let count = Int(maskNumPoints) ?? 64
        let radii = getMaskPixelRadii()
        let scaleX = Float(w) / imgW
        let scaleY = Float(h) / imgH

        let idx = index % count
        let sweepAngle = Float.pi - Float(idx) / Float(count) * 2.0 * .pi
        let pixelR = (idx < radii.count ? radii[idx] : defaultMaskPixelRadius) * radiusScale

        // Pixel position in image space (center = imgW/2, imgH/2)
        let px = imgW / 2.0 + pixelR * cos(sweepAngle)
        let py = imgH / 2.0 + pixelR * sin(sweepAngle)

        // Scale to composite space
        return CGPoint(x: CGFloat(ox) + CGFloat(px * scaleX), y: CGFloat(py * scaleY))
    }

    /// Build a closed CGPath from mask control points using cubic Hermite (Catmull-Rom) interpolation
    private func maskPath(w: Int, h: Int, ox: Int = 0, eyeCx: Float, eyeCy: Float, radiusScale: Float = 1.0) -> CGPath? {
        let n = Int(maskNumPoints) ?? 64
        // Collect all projected points
        var pts: [CGPoint] = []
        for i in 0..<n {
            if let pt = maskPointToPixel(index: i, w: w, h: h, ox: ox, eyeCx: eyeCx, eyeCy: eyeCy, radiusScale: radiusScale) {
                pts.append(pt)
            } else { return nil }
        }
        guard pts.count >= 3 else { return nil }

        let path = CGMutablePath()
        // Catmull-Rom spline (equivalent to cubic Hermite with computed tangents)
        // For a closed curve, wrap around indices
        let segmentsPerEdge = 4  // subdivisions between control points
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n]
            let p1 = pts[i]
            let p2 = pts[(i + 1) % n]
            let p3 = pts[(i + 2) % n]

            for s in 0..<segmentsPerEdge {
                let t = CGFloat(s) / CGFloat(segmentsPerEdge)
                let t2 = t * t, t3 = t2 * t
                // Catmull-Rom basis
                let x = 0.5 * ((2 * p1.x) +
                    (-p0.x + p2.x) * t +
                    (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
                    (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
                let y = 0.5 * ((2 * p1.y) +
                    (-p0.y + p2.y) * t +
                    (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
                    (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)

                let pt = CGPoint(x: x, y: y)
                if i == 0 && s == 0 { path.move(to: pt) }
                else { path.addLine(to: pt) }
            }
        }
        path.closeSubpath()
        return path
    }

    private func drawMaskAt(ctx: CGContext, w: Int, h: Int, ox: Int = 0, eyeCx: Float, eyeCy: Float) {
        let maskPtsV = Int(maskNumPoints) ?? 64
        let edgeW = Float(maskEdgeWidth) ?? 2.5

        // Compute edge width as a radius scale factor
        // edgeWidth is in degrees; convert to fraction of the mask radius in projected space
        let halfFov = (Float(hfov) ?? 190) / 2.0
        let edgeScale = edgeW / halfFov

        let fullRect = CGRect(x: CGFloat(ox), y: 0, width: CGFloat(w), height: CGFloat(h))

        // Render mask alpha to a separate grayscale context, then composite onto main context.
        // This avoids alpha compositing artifacts from overlapping semi-transparent fills.
        let gradientSteps = 16
        let outerScale: Float = 1.0 + edgeScale
        let maxAlpha: CGFloat = 0.85

        let maskW = w
        let maskH = h
        guard let maskCtx = CGContext(data: nil, width: maskW, height: maskH, bitsPerComponent: 8,
                                       bytesPerRow: maskW, space: CGColorSpaceCreateDeviceGray(),
                                       bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }

        // Start with white (fully transparent mask = no darkening)
        maskCtx.setFillColor(gray: 1.0, alpha: 1.0)
        maskCtx.fill(CGRect(x: 0, y: 0, width: maskW, height: maskH))

        // Draw rings from innermost to outermost. Each ring fills outside itself with gray value.
        // Gray 0 = fully dark, gray 1 = fully transparent. We want outside = dark.
        // For each step, fill outside the ring with the target darkness level.
        // Since we draw inner→outer, outer rings overwrite inner ones in the outside region.
        for step in 0...gradientSteps {
            let t = CGFloat(step) / CGFloat(gradientSteps)
            let rScale = 1.0 + edgeScale * Float(step) / Float(gradientSteps)

            let darkness: CGFloat
            if maskEdgeTreatment == "easeInOut" {
                let ss = 3.0 * t * t - 2.0 * t * t * t
                darkness = 1.0 - ss * maxAlpha
            } else {
                darkness = 1.0 - t * maxAlpha
            }

            guard let ring = maskPath(w: w, h: h, ox: 0, eyeCx: eyeCx, eyeCy: eyeCy, radiusScale: rScale) else { continue }
            maskCtx.saveGState()
            let clipPath = CGMutablePath()
            clipPath.addRect(CGRect(x: 0, y: 0, width: maskW, height: maskH))
            clipPath.addPath(ring)
            maskCtx.addPath(clipPath)
            maskCtx.clip(using: .evenOdd)
            maskCtx.setFillColor(gray: darkness, alpha: 1.0)
            maskCtx.fill(CGRect(x: 0, y: 0, width: maskW, height: maskH))
            maskCtx.restoreGState()
        }

        // Everything outside outermost ring = fully dark
        if let outerRing = maskPath(w: w, h: h, ox: 0, eyeCx: eyeCx, eyeCy: eyeCy, radiusScale: outerScale) {
            maskCtx.saveGState()
            let clipPath = CGMutablePath()
            clipPath.addRect(CGRect(x: 0, y: 0, width: maskW, height: maskH))
            clipPath.addPath(outerRing)
            maskCtx.addPath(clipPath)
            maskCtx.clip(using: .evenOdd)
            maskCtx.setFillColor(gray: 1.0 - maxAlpha, alpha: 1.0)
            maskCtx.fill(CGRect(x: 0, y: 0, width: maskW, height: maskH))
            maskCtx.restoreGState()
        }

        // Convert grayscale mask to alpha mask and composite at the correct offset
        if let maskImage = maskCtx.makeImage() {
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            ctx.draw(maskImage, in: CGRect(x: CGFloat(ox), y: 0, width: CGFloat(maskW), height: CGFloat(maskH)))
            ctx.restoreGState()
        }

        // Draw the mask boundary line (the actual control point circle)
        if let boundaryPath = maskPath(w: w, h: h, ox: ox, eyeCx: eyeCx, eyeCy: eyeCy) {
            ctx.setStrokeColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 0.8))
            ctx.setLineWidth(2)
            ctx.addPath(boundaryPath)
            ctx.strokePath()
        }

        // Draw dots at each control point
        let dotSize: CGFloat = maskAdjustMode ? 8 : 3  // bigger dots in adjust mode
        for i in 0..<maskPtsV {
            if let pt = maskPointToPixel(index: i, w: w, h: h, ox: ox, eyeCx: eyeCx, eyeCy: eyeCy) {
                if maskAdjustMode && i == selectedMaskPoint {
                    // Selected point: red, even bigger
                    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1.0))
                    ctx.fillEllipse(in: CGRect(x: pt.x - dotSize * 1.5, y: pt.y - dotSize * 1.5, width: dotSize * 3, height: dotSize * 3))
                } else {
                    ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1.0))
                    ctx.fillEllipse(in: CGRect(x: pt.x - dotSize, y: pt.y - dotSize, width: dotSize * 2, height: dotSize * 2))
                }
            }
        }
    }

    private var pStereoX: Float { (Float(stereoRotX) ?? 0) * .pi / 180 }
    private var pStereoY: Float { (Float(stereoRotY) ?? 0) * .pi / 180 }
    private var pStereoZ: Float { (Float(stereoRotZ) ?? 0) * .pi / 180 }

    // GPU-accelerated rectilinear reprojection
    func rectReproject(frame: CGImage, cx effCx: Float, cy effCy: Float, ew: Int, eh: Int, stereoSign: Float = 0) -> NSImage? {
        return gpuRenderer.rectReproject(
            frame: frame, cx: effCx, cy: effCy,
            fx: pFx, fy: pFy, k1: pK1, k2: pK2, k3: pK3, k4: pK4,
            hfov: pHfov, imageWidth: Float(imageWidth) ?? Float(frame.width),
            imageHeight: Float(imageHeight) ?? Float(frame.height),
            rectFOV: Float(rectFOV), rectYaw: Float(rectYaw), rectPitch: Float(rectPitch),
            stereoPitch: pStereoX * stereoSign, stereoYaw: pStereoY * stereoSign, stereoRoll: pStereoZ * stereoSign,
            showMask: false, maskEdge: 0, maskAngleDeg: 90
        )
    }

    func rectAnaglyphComposite(left: CGImage, right: CGImage, ew: Int, eh: Int) -> NSImage? {
        return gpuRenderer.rectAnaglyph(
            left: left, right: right,
            lCx: pLCx, lCy: pLCy,
            rCx: pRCx, rCy: pRCy,
            fx: pFx, fy: pFy, k1: pK1, k2: pK2, k3: pK3, k4: pK4,
            hfov: pHfov, imageWidth: Float(imageWidth) ?? Float(left.width),
            imageHeight: Float(imageHeight) ?? Float(left.height),
            rectFOV: Float(rectFOV), rectYaw: Float(rectYaw), rectPitch: Float(rectPitch),
            stereoPitch: pStereoX, stereoYaw: pStereoY, stereoRoll: pStereoZ,
            showMask: false, maskEdge: 0, maskAngleDeg: 90
        )
    }

    /// Apply stereo rotation to fisheye image by remapping pixels through KB model
    /// Returns a new CGImage with pixels rotated on the sphere by the given Euler angles
    func applyFisheyeRotation(frame: CGImage, cx: Float, cy: Float, pitch: Float, yaw: Float, roll: Float) -> CGImage? {
        guard abs(pitch) > 0.0001 || abs(yaw) > 0.0001 || abs(roll) > 0.0001 else { return frame }
        return gpuRenderer.fisheyeRotate(
            frame: frame, cx: cx, cy: cy,
            fx: pFx, fy: pFy, k1: pK1, k2: pK2, k3: pK3, k4: pK4,
            imageWidth: Float(imageWidth) ?? Float(frame.width),
            imageHeight: Float(imageHeight) ?? Float(frame.height),
            pitch: pitch, yaw: yaw, roll: roll
        )
    }
}

// MARK: - GPU Renderer (Metal Compute)

class GPURenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let rectPipeline: MTLComputePipelineState
    private let anaglyphPipeline: MTLComputePipelineState
    private let fisheyeRotPipeline: MTLComputePipelineState
    private let ciContext: CIContext

    struct RectParams {
        var outW: UInt32; var outH: UInt32
        var srcW: UInt32; var srcH: UInt32
        var focalOut: Float
        // 3x3 rotation matrix (view rotation + stereo offset), packed as 3 float3 rows
        var rot0: SIMD3<Float>; var rot1: SIMD3<Float>; var rot2: SIMD3<Float>
        var cx: Float; var cy: Float; var fx: Float; var fy: Float
        var k1: Float; var k2: Float; var k3: Float; var k4: Float
        var maskHalf: Float; var maskEdge: Float; var showMask: UInt32
        var pad: UInt32 = 0
    }

    /// Build a 3x3 rotation matrix from Euler angles (XYZ order, radians)
    static func rotationMatrix(pitch: Float, yaw: Float, roll: Float) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let cx = cos(pitch), sx = sin(pitch)
        let cy = cos(yaw), sy = sin(yaw)
        let cz = cos(roll), sz = sin(roll)
        // R = Rz * Ry * Rx
        let r00 = cy * cz;          let r01 = cz * sx * sy - cx * sz; let r02 = sx * sz + cx * cz * sy
        let r10 = cy * sz;          let r11 = cx * cz + sx * sy * sz; let r12 = cx * sy * sz - cz * sx
        let r20 = -sy;              let r21 = cy * sx;                 let r22 = cx * cy
        return (SIMD3<Float>(r00, r01, r02), SIMD3<Float>(r10, r11, r12), SIMD3<Float>(r20, r21, r22))
    }

    init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        ciContext = CIContext(mtlDevice: device)

        let shaderSrc = """
        #include <metal_stdlib>
        using namespace metal;

        struct Params {
            uint outW; uint outH;
            uint srcW; uint srcH;
            float focalOut;
            float3 rot0; float3 rot1; float3 rot2;  // 3x3 rotation matrix rows
            float cx; float cy; float fx; float fy;
            float k1; float k2; float k3; float k4;
            float maskHalf; float maskEdge; uint showMask;
        };

        kernel void rectReproject(
            texture2d<float, access::read> src [[texture(0)]],
            texture2d<float, access::write> dst [[texture(1)]],
            constant Params &p [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= p.outW || gid.y >= p.outH) return;

            float px = (float(gid.x) - float(p.outW) / 2.0) / p.focalOut;
            float py = (float(p.outH - 1 - gid.y) - float(p.outH) / 2.0) / p.focalOut;
            float norm = sqrt(px * px + py * py + 1.0);
            float3 dir = float3(px / norm, py / norm, -1.0 / norm);

            // Apply combined rotation (view yaw/pitch + stereo offset)
            float dx = dot(p.rot0, dir);
            float dy = dot(p.rot1, dir);
            float dz = dot(p.rot2, dir);

            float r3d = sqrt(dx * dx + dy * dy);
            float theta = atan2(r3d, -dz);
            float t2 = theta * theta, t3 = t2 * theta;
            float tD = theta + p.k1 * t3 + p.k2 * t2 * t3 + p.k3 * t2 * t2 * t3 + p.k4 * t2 * t2 * t2 * t3;

            float srcX, srcY;
            if (r3d < 1e-8) { srcX = p.cx; srcY = p.cy; }
            else { srcX = p.fx * tD * (dx / r3d) + p.cx; srcY = p.fy * tD * (dy / r3d) + p.cy; }

            // Flip Y: CGContext draws Y-up, Metal reads Y-down
            srcY = float(p.srcH) - 1.0 - srcY;
            int ix = int(srcX), iy = int(srcY);

            float4 color = float4(0, 0, 0, 1);
            if (ix >= 0 && ix < int(p.srcW) && iy >= 0 && iy < int(p.srcH)) {
                color = src.read(uint2(ix, iy));
                if (p.showMask != 0) {
                    // Gradient mask: fade from full color at maskHalf to black at maskHalf + maskEdge
                    if (theta > p.maskHalf + p.maskEdge) {
                        // Fully outside — dim heavily
                        color.r = min(1.0, color.r * 0.3 + 0.12);
                        color.g *= 0.15; color.b *= 0.15;
                    } else if (theta > p.maskHalf && p.maskEdge > 0.001) {
                        // In the gradient zone
                        float t = (theta - p.maskHalf) / p.maskEdge;
                        float fade = 1.0 - t;
                        color.rgb = mix(float3(min(1.0, color.r * 0.3 + 0.12), color.g * 0.15, color.b * 0.15),
                                       color.rgb, fade);
                    }
                    // Draw boundary line
                    if (abs(theta - p.maskHalf) < 0.005) {
                        color = float4(1.0, 0.4, 0.0, 1.0);
                    }
                }
            } else if (p.showMask != 0 && theta > p.maskHalf) {
                color = float4(0.08, 0, 0, 1);
            }

            dst.write(color, gid);
        }

        kernel void anaglyphComposite(
            texture2d<float, access::read> leftTex [[texture(0)]],
            texture2d<float, access::read> rightTex [[texture(1)]],
            texture2d<float, access::write> dst [[texture(2)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            uint w = dst.get_width(), h = dst.get_height();
            if (gid.x >= w || gid.y >= h) return;
            float4 l = leftTex.read(gid);
            float4 r = rightTex.read(gid);
            dst.write(float4(l.r, r.g, r.b, 1.0), gid);
        }

        // Fisheye rotation: for each output pixel, unproject to sphere, rotate, reproject
        struct FisheyeRotParams {
            uint srcW; uint srcH;
            float3 rot0; float3 rot1; float3 rot2;
            float cx; float cy; float fx; float fy;
            float k1; float k2; float k3; float k4;
        };

        kernel void fisheyeRotate(
            texture2d<float, access::read> src [[texture(0)]],
            texture2d<float, access::write> dst [[texture(1)]],
            constant FisheyeRotParams &p [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= p.srcW || gid.y >= p.srcH) return;

            // Current pixel -> normalized coords
            float ox = (float(gid.x) - p.cx) / p.fx;
            float oy = (float(p.srcH - 1 - gid.y) - p.cy) / p.fy;
            float r_d = sqrt(ox * ox + oy * oy);

            // Invert KB model: find theta from r_d using Newton's method
            float theta = r_d;  // initial guess
            for (int i = 0; i < 20; i++) {
                float t2 = theta * theta, t3 = t2 * theta;
                float f = theta + p.k1 * t3 + p.k2 * t2 * t3 + p.k3 * t2 * t2 * t3 + p.k4 * t2 * t2 * t2 * t3 - r_d;
                float df = 1 + 3 * p.k1 * t2 + 5 * p.k2 * t2 * t2 + 7 * p.k3 * t2 * t2 * t2 + 9 * p.k4 * t2 * t2 * t2 * t2;
                if (abs(df) < 1e-12) break;
                theta -= f / df;
                if (abs(f) < 1e-8) break;
            }

            // Unproject to unit sphere
            float3 dir;
            if (r_d < 1e-8) {
                dir = float3(0, 0, -1);
            } else {
                float s = sin(theta) / r_d;
                dir = float3(ox * s, oy * s, -cos(theta));
            }

            // Apply rotation
            float3 rotDir = float3(dot(p.rot0, dir), dot(p.rot1, dir), dot(p.rot2, dir));

            // Reproject rotated direction back to fisheye pixel
            float r3d = sqrt(rotDir.x * rotDir.x + rotDir.y * rotDir.y);
            float theta2 = atan2(r3d, -rotDir.z);
            float t2 = theta2 * theta2, t3 = t2 * theta2;
            float tD = theta2 + p.k1 * t3 + p.k2 * t2 * t3 + p.k3 * t2 * t2 * t3 + p.k4 * t2 * t2 * t2 * t3;

            float srcX, srcY;
            if (r3d < 1e-8) { srcX = p.cx; srcY = p.cy; }
            else { srcX = p.fx * tD * (rotDir.x / r3d) + p.cx; srcY = p.fy * tD * (rotDir.y / r3d) + p.cy; }

            // Flip Y back
            srcY = float(p.srcH) - 1.0 - srcY;

            int ix = int(srcX), iy = int(srcY);
            float4 color = float4(0, 0, 0, 1);
            if (ix >= 0 && ix < int(p.srcW) && iy >= 0 && iy < int(p.srcH)) {
                color = src.read(uint2(ix, iy));
            }
            dst.write(color, gid);
        }
        """

        let lib = try! device.makeLibrary(source: shaderSrc, options: nil)
        rectPipeline = try! device.makeComputePipelineState(function: lib.makeFunction(name: "rectReproject")!)
        anaglyphPipeline = try! device.makeComputePipelineState(function: lib.makeFunction(name: "anaglyphComposite")!)
        fisheyeRotPipeline = try! device.makeComputePipelineState(function: lib.makeFunction(name: "fisheyeRotate")!)
    }

    private func makeTexture(from image: CGImage) -> MTLTexture? {
        let w = image.width, h = image.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }

        // Draw CGImage into RGBA buffer
        let bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: bpr, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: buf, bytesPerRow: bpr)
        return tex
    }

    private func textureToNSImage(_ tex: MTLTexture) -> NSImage? {
        let w = tex.width, h = tex.height, bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        tex.getBytes(&buf, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: bpr, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    func rectReproject(
        frame: CGImage, cx: Float, cy: Float,
        fx: Float, fy: Float, k1: Float, k2: Float, k3: Float, k4: Float,
        hfov: Float, imageWidth: Float, imageHeight: Float,
        rectFOV: Float, rectYaw: Float, rectPitch: Float,
        stereoPitch: Float = 0, stereoYaw: Float = 0, stereoRoll: Float = 0,
        showMask: Bool, maskEdge: Float = 2.5, maskAngleDeg: Float = 85.0
    ) -> NSImage? {
        let outW = min(Int(frame.width), 2048), outH = min(Int(frame.height), 2048)
        guard let srcTex = makeTexture(from: frame) else { return nil }

        let dstDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: outW, height: outH, mipmapped: false)
        dstDesc.usage = [.shaderWrite, .shaderRead]
        guard let dstTex = device.makeTexture(descriptor: dstDesc) else { return nil }

        let scaleX = Float(frame.width) / imageWidth
        let scaleY = Float(frame.height) / imageHeight
        let fovRad = rectFOV * .pi / 180

        // Combined rotation: view rotation then stereo offset
        // Stereo applied after view so alignment stays consistent when panning
        let (s0, s1, s2) = GPURenderer.rotationMatrix(pitch: stereoPitch, yaw: stereoYaw, roll: stereoRoll)
        let (v0, v1, v2) = GPURenderer.rotationMatrix(pitch: rectPitch * .pi / 180, yaw: rectYaw * .pi / 180, roll: 0)
        // Multiply: stereo * view (view applied first, then stereo)
        func dot3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x*b.x + a.y*b.y + a.z*b.z }
        let vc0 = SIMD3<Float>(v0.x, v1.x, v2.x) // columns of view matrix
        let vc1 = SIMD3<Float>(v0.y, v1.y, v2.y)
        let vc2 = SIMD3<Float>(v0.z, v1.z, v2.z)
        let r0 = SIMD3<Float>(dot3(s0, vc0), dot3(s0, vc1), dot3(s0, vc2))
        let r1 = SIMD3<Float>(dot3(s1, vc0), dot3(s1, vc1), dot3(s1, vc2))
        let r2 = SIMD3<Float>(dot3(s2, vc0), dot3(s2, vc1), dot3(s2, vc2))

        var params = RectParams(
            outW: UInt32(outW), outH: UInt32(outH),
            srcW: UInt32(frame.width), srcH: UInt32(frame.height),
            focalOut: Float(outW / 2) / tan(fovRad / 2),
            rot0: r0, rot1: r1, rot2: r2,
            cx: cx * scaleX, cy: cy * scaleY, fx: fx * scaleX, fy: fy * scaleY,
            k1: k1, k2: k2, k3: k3, k4: k4,
            maskHalf: maskAngleDeg * .pi / 180, maskEdge: maskEdge * .pi / 180, showMask: showMask ? 1 : 0
        )

        guard let cmdBuf = queue.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(rectPipeline)
        enc.setTexture(srcTex, index: 0)
        enc.setTexture(dstTex, index: 1)
        enc.setBytes(&params, length: MemoryLayout<RectParams>.size, index: 0)
        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(width: (outW + 15) / 16, height: (outH + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return textureToNSImage(dstTex)
    }

    func rectAnaglyph(
        left: CGImage, right: CGImage,
        lCx: Float, lCy: Float, rCx: Float, rCy: Float,
        fx: Float, fy: Float, k1: Float, k2: Float, k3: Float, k4: Float,
        hfov: Float, imageWidth: Float, imageHeight: Float,
        rectFOV: Float, rectYaw: Float, rectPitch: Float,
        stereoPitch: Float = 0, stereoYaw: Float = 0, stereoRoll: Float = 0,
        showMask: Bool, maskEdge: Float = 2.5, maskAngleDeg: Float = 85.0
    ) -> NSImage? {
        let outW = min(Int(left.width), 2048), outH = min(Int(left.height), 2048)
        guard let lSrc = makeTexture(from: left), let rSrc = makeTexture(from: right) else { return nil }

        let mkDst = { () -> MTLTexture? in
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: outW, height: outH, mipmapped: false)
            d.usage = [.shaderWrite, .shaderRead]
            return self.device.makeTexture(descriptor: d)
        }
        guard let lDst = mkDst(), let rDst = mkDst(), let anaDst = mkDst() else { return nil }

        let scaleX = Float(left.width) / imageWidth
        let scaleY = Float(left.height) / imageHeight
        let fovRad = rectFOV * .pi / 180

        func makeParams(cx: Float, cy: Float, stereoSign: Float) -> RectParams {
            let (s0, s1, s2) = GPURenderer.rotationMatrix(pitch: stereoPitch * stereoSign, yaw: stereoYaw * stereoSign, roll: stereoRoll * stereoSign)
            let (v0, v1, v2) = GPURenderer.rotationMatrix(pitch: rectPitch * .pi / 180, yaw: rectYaw * .pi / 180, roll: 0)
            // Multiply: stereo * view (view applied first, then stereo)
            func dot3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x*b.x + a.y*b.y + a.z*b.z }
            let vc0 = SIMD3<Float>(v0.x, v1.x, v2.x)
            let vc1 = SIMD3<Float>(v0.y, v1.y, v2.y)
            let vc2 = SIMD3<Float>(v0.z, v1.z, v2.z)
            return RectParams(
                outW: UInt32(outW), outH: UInt32(outH),
                srcW: UInt32(left.width), srcH: UInt32(left.height),
                focalOut: Float(outW / 2) / tan(fovRad / 2),
                rot0: SIMD3<Float>(dot3(s0, vc0), dot3(s0, vc1), dot3(s0, vc2)),
                rot1: SIMD3<Float>(dot3(s1, vc0), dot3(s1, vc1), dot3(s1, vc2)),
                rot2: SIMD3<Float>(dot3(s2, vc0), dot3(s2, vc1), dot3(s2, vc2)),
                cx: cx * scaleX, cy: cy * scaleY, fx: fx * scaleX, fy: fy * scaleY,
                k1: k1, k2: k2, k3: k3, k4: k4,
                maskHalf: maskAngleDeg * .pi / 180, maskEdge: maskEdge * .pi / 180, showMask: showMask ? 1 : 0
            )
        }

        guard let cmdBuf = queue.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else { return nil }

        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(width: (outW + 15) / 16, height: (outH + 15) / 16, depth: 1)

        // Left eye rect (stereoSign = -0.5)
        var lParams = makeParams(cx: lCx, cy: lCy, stereoSign: -0.5)
        enc.setComputePipelineState(rectPipeline)
        enc.setTexture(lSrc, index: 0); enc.setTexture(lDst, index: 1)
        enc.setBytes(&lParams, length: MemoryLayout<RectParams>.size, index: 0)
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)

        // Right eye rect (stereoSign = +0.5)
        var rParams = makeParams(cx: rCx, cy: rCy, stereoSign: 0.5)
        enc.setTexture(rSrc, index: 0); enc.setTexture(rDst, index: 1)
        enc.setBytes(&rParams, length: MemoryLayout<RectParams>.size, index: 0)
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)

        // Anaglyph composite
        enc.setComputePipelineState(anaglyphPipeline)
        enc.setTexture(lDst, index: 0); enc.setTexture(rDst, index: 1); enc.setTexture(anaDst, index: 2)
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)

        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return textureToNSImage(anaDst)
    }

    struct FisheyeRotParams {
        var srcW: UInt32; var srcH: UInt32
        var rot0: SIMD3<Float>; var rot1: SIMD3<Float>; var rot2: SIMD3<Float>
        var cx: Float; var cy: Float; var fx: Float; var fy: Float
        var k1: Float; var k2: Float; var k3: Float; var k4: Float
    }

    func fisheyeRotate(
        frame: CGImage, cx: Float, cy: Float,
        fx: Float, fy: Float, k1: Float, k2: Float, k3: Float, k4: Float,
        imageWidth: Float, imageHeight: Float,
        pitch: Float, yaw: Float, roll: Float
    ) -> CGImage? {
        let w = frame.width, h = frame.height
        guard let srcTex = makeTexture(from: frame) else { return nil }

        let dstDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        dstDesc.usage = [.shaderWrite]
        guard let dstTex = device.makeTexture(descriptor: dstDesc) else { return nil }

        let scaleX = Float(w) / imageWidth
        let scaleY = Float(h) / imageHeight
        let (r0, r1, r2) = GPURenderer.rotationMatrix(pitch: pitch, yaw: yaw, roll: roll)

        var params = FisheyeRotParams(
            srcW: UInt32(w), srcH: UInt32(h),
            rot0: r0, rot1: r1, rot2: r2,
            cx: cx * scaleX, cy: cy * scaleY, fx: fx * scaleX, fy: fy * scaleY,
            k1: k1, k2: k2, k3: k3, k4: k4
        )

        guard let cmdBuf = queue.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(fisheyeRotPipeline)
        enc.setTexture(srcTex, index: 0)
        enc.setTexture(dstTex, index: 1)
        enc.setBytes(&params, length: MemoryLayout<FisheyeRotParams>.size, index: 0)
        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Read back to CGImage
        let bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        dstTex.getBytes(&buf, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: bpr, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return cg
    }
}

// MARK: - Mesh Generation

// MARK: - KB to Mei-Rives Fitting & ILPD Export

enum MeiRivesFitter {
    struct MeiRivesParams {
        var fx: Double, fy: Double, cx: Double, cy: Double
        var xi: Double  // mirror/projection offset
        var k1: Double, k2: Double  // radial distortion
        var p1: Double, p2: Double  // tangential distortion
    }

    /// Project 3D direction through Mei-Rives model to pixel coordinates
    static func meiProject(x: Double, y: Double, z: Double, p: MeiRivesParams) -> (Double, Double) {
        let norm = sqrt(x*x + y*y + z*z)
        let xs = x/norm, ys = y/norm, zs = z/norm
        let denom = zs + p.xi
        guard abs(denom) > 1e-10 else { return (p.cx, p.cy) }
        let uProj = xs / denom, vProj = ys / denom
        let r2 = uProj*uProj + vProj*vProj
        let radial = 1.0 + p.k1 * r2 + p.k2 * r2 * r2
        let uDist = uProj * radial + 2*p.p1*uProj*vProj + p.p2*(r2 + 2*uProj*uProj)
        let vDist = vProj * radial + p.p1*(r2 + 2*vProj*vProj) + 2*p.p2*uProj*vProj
        return (p.fx * uDist + p.cx, p.fy * vDist + p.cy)
    }

    /// Project incidence angle through Kannala-Brandt to pixel coordinates
    static func kbProject(theta: Double, phi: Double,
                          fx: Double, fy: Double, cx: Double, cy: Double,
                          k1: Double, k2: Double, k3: Double, k4: Double) -> (Double, Double) {
        let t2 = theta * theta
        let thetaD = theta * (1.0 + t2 * (k1 + t2 * (k2 + t2 * (k3 + t2 * k4))))
        return (fx * thetaD * cos(phi) + cx, fy * thetaD * sin(phi) + cy)
    }

    /// Result of KB→Mei-Rives fitting, including the calibration limit angle
    struct FitResult {
        var params: MeiRivesParams
        var calibrationLimitRadialAngle: Double  // degrees
        var hfov: Double  // full horizontal FOV in degrees
        var vfov: Double  // full vertical FOV in degrees
    }

    /// Fit Mei-Rives parameters to match a given KB model
    /// Uses Levenberg-Marquardt optimization on a grid of ray directions
    static func fitKBtoMeiRives(
        fx: Double, fy: Double, cx: Double, cy: Double,
        k1: Double, k2: Double, k3: Double, k4: Double,
        imageWidth: Double, imageHeight: Double
    ) -> FitResult {
        // Find theta_max per axis (where projected radius hits image boundary and KB is monotonic)
        func findThetaMax(f: Double, maxR: Double) -> Double {
            var lo = 0.0, hi = Double.pi
            for _ in 0..<100 {
                let mid = 0.5 * (lo + hi)
                let t2 = mid * mid
                let thetaD = mid * (1.0 + t2 * (k1 + t2 * (k2 + t2 * (k3 + t2 * k4))))
                let deriv = 1.0 + t2 * (3*k1 + t2 * (5*k2 + t2 * (7*k3 + t2 * 9*k4)))
                if f * thetaD < maxR && deriv > 0.05 { lo = mid } else { hi = mid }
            }
            return lo
        }

        // Compute max angles for each direction
        let thetaMaxH = findThetaMax(f: fx, maxR: min(cx, imageWidth - cx))
        let thetaMaxV = findThetaMax(f: fy, maxR: min(cy, imageHeight - cy))
        let thetaMax = min(thetaMaxH, thetaMaxV)
        let thetaFit = thetaMax * 0.98

        // Compute actual FOV from KB model
        let fullHFOV = (thetaMaxH * 2.0) * 180.0 / .pi
        let fullVFOV = (thetaMaxV * 2.0) * 180.0 / .pi

        // Estimate xi analytically from projection shape.
        // Pure MR (no distortion): r = f_mr * sin(theta) / (cos(theta) + xi)
        // Ratio at two angles depends only on xi, not f_mr.
        // From KB: ratio = theta_d(a) / theta_d(b)
        // From MR: ratio = [sin(a)*(cos(b)+xi)] / [sin(b)*(cos(a)+xi)]
        // Solve: xi = [sin(a)*cos(b) - R*sin(b)*cos(a)] / [R*sin(b) - sin(a)]
        let thetaA = 0.5236  // ~30 deg
        let thetaB = 1.2217  // ~70 deg
        let t2A = thetaA * thetaA, t2B = thetaB * thetaB
        let tdA = thetaA * (1.0 + t2A * (k1 + t2A * (k2 + t2A * (k3 + t2A * k4))))
        let tdB = thetaB * (1.0 + t2B * (k1 + t2B * (k2 + t2B * (k3 + t2B * k4))))
        let projRatio = tdA / tdB
        let xiNumer = sin(thetaA)*cos(thetaB) - projRatio*sin(thetaB)*cos(thetaA)
        let xiDenom = projRatio*sin(thetaB) - sin(thetaA)
        let xiAnalytical = abs(xiDenom) > 1e-10 ? xiNumer / xiDenom : 2.0
        let xiInit = max(1.0, min(xiAnalytical, 5.0))  // clamp to reasonable range
        let xiMin = xiInit * 0.8  // lower bound during optimization

        // Generate grid of sample points — denser near the edges
        let nTheta = 60, nPhi = 48
        var sampleThetas: [Double] = []
        var samplePhis: [Double] = []
        var targetU: [Double] = []
        var targetV: [Double] = []

        for it in 0..<nTheta {
            let t = Double(it) / Double(nTheta - 1)
            let theta = 0.01 + (thetaFit - 0.01) * (0.3 * t + 0.7 * t * t)
            for ip in 0..<nPhi {
                let phi = 2.0 * .pi * Double(ip) / Double(nPhi)
                sampleThetas.append(theta)
                samplePhis.append(phi)
                let (u, v) = kbProject(theta: theta, phi: phi, fx: fx, fy: fy, cx: cx, cy: cy,
                                       k1: k1, k2: k2, k3: k3, k4: k4)
                targetU.append(u)
                targetV.append(v)
            }
        }

        let n = sampleThetas.count
        // 3D ray directions — camera looks along +Z (standard UCM / ILPD convention)
        var X = [Double](repeating: 0, count: n)
        var Y = [Double](repeating: 0, count: n)
        var Z = [Double](repeating: 0, count: n)
        for i in 0..<n {
            X[i] = sin(sampleThetas[i]) * cos(samplePhis[i])
            Y[i] = sin(sampleThetas[i]) * sin(samplePhis[i])
            Z[i] = cos(sampleThetas[i])  // +Z = optical axis (ILPD convention)
        }

        // Initial: fx_mr = fx_kb * (1 + xi)
        let nParams = 5
        var p = [fx * (1 + xiInit), fy * (1 + xiInit), xiInit, 0.0, 0.0]

        func computeResiduals(_ p: [Double]) -> [Double] {
            let pr = MeiRivesParams(fx: p[0], fy: p[1], cx: cx, cy: cy, xi: p[2], k1: p[3], k2: p[4], p1: 0, p2: 0)
            var res = [Double](repeating: 0, count: 2 * n)
            for i in 0..<n {
                let (u, v) = meiProject(x: X[i], y: Y[i], z: Z[i], p: pr)
                res[i] = u - targetU[i]
                res[n + i] = v - targetV[i]
            }
            return res
        }

        func computeJacobian(_ p: [Double]) -> [[Double]] {
            let delta = 1e-7
            let r0 = computeResiduals(p)
            var J = [[Double]](repeating: [Double](repeating: 0, count: nParams), count: 2 * n)
            for j in 0..<nParams {
                var pj = p; pj[j] += delta
                let rj = computeResiduals(pj)
                for i in 0..<(2 * n) {
                    J[i][j] = (rj[i] - r0[i]) / delta
                }
            }
            return J
        }

        // Levenberg-Marquardt with xi lower-bound constraint
        var lambda = 1e-3
        for _ in 0..<500 {
            let res = computeResiduals(p)
            let J = computeJacobian(p)

            var JtJ = [[Double]](repeating: [Double](repeating: 0, count: nParams), count: nParams)
            var Jtr = [Double](repeating: 0, count: nParams)
            for i in 0..<(2 * n) {
                for a in 0..<nParams {
                    Jtr[a] += J[i][a] * res[i]
                    for b in 0..<nParams {
                        JtJ[a][b] += J[i][a] * J[i][b]
                    }
                }
            }

            for a in 0..<nParams { JtJ[a][a] *= (1 + lambda) }

            var A = JtJ; var b = Jtr.map { -$0 }
            for col in 0..<nParams {
                var maxRow = col; var maxVal = abs(A[col][col])
                for row in (col+1)..<nParams { if abs(A[row][col]) > maxVal { maxVal = abs(A[row][col]); maxRow = row } }
                if maxRow != col { A.swapAt(col, maxRow); b.swapAt(col, maxRow) }
                guard abs(A[col][col]) > 1e-20 else { continue }
                for row in (col+1)..<nParams {
                    let f = A[row][col] / A[col][col]
                    for c in col..<nParams { A[row][c] -= f * A[col][c] }
                    b[row] -= f * b[col]
                }
            }
            var dp = [Double](repeating: 0, count: nParams)
            for i in stride(from: nParams - 1, through: 0, by: -1) {
                dp[i] = b[i]
                for j in (i+1)..<nParams { dp[i] -= A[i][j] * dp[j] }
                dp[i] /= A[i][i]
            }

            var pNew = p; for i in 0..<nParams { pNew[i] += dp[i] }
            // Clamp xi to physically meaningful range (prevents degenerate xi≈1 solutions)
            if pNew[2] < xiMin { pNew[2] = xiMin }

            let resNew = computeResiduals(pNew)
            let costOld = res.reduce(0) { $0 + $1*$1 }
            let costNew = resNew.reduce(0) { $0 + $1*$1 }

            if costNew < costOld {
                p = pNew; lambda *= 0.5
                if costOld - costNew < 1e-14 { break }
            } else {
                lambda *= 10
            }
        }

        let finalParams = MeiRivesParams(fx: p[0], fy: p[1], cx: cx, cy: cy, xi: p[2], k1: p[3], k2: p[4], p1: 0, p2: 0)
        return FitResult(
            params: finalParams,
            calibrationLimitRadialAngle: thetaMax * 180.0 / .pi,
            hfov: fullHFOV,
            vfov: fullVFOV
        )
    }

    /// Generate ILPD JSON string from app parameters
    static func generateILPD(
        cameraID: String, calibrationName: String,
        calibrationUUID: String,
        imageWidth: Int, imageHeight: Int,
        fxL: Double, fyL: Double, cxL: Double, cyL: Double,
        fxR: Double, fyR: Double, cxR: Double, cyR: Double,
        k1: Double, k2: Double, k3: Double, k4: Double,
        stereoRotX: Double, stereoRotY: Double, stereoRotZ: Double,
        baseline: Double,
        maskControlPoints: [[Double]]?,
        maskEdgeWidth: Double,
        hfov: Double, vfov: Double,
        flipLR: Bool = false
    ) -> String {
        // Fit Mei-Rives for left eye
        let fitL = fitKBtoMeiRives(fx: fxL, fy: fyL, cx: cxL, cy: cyL,
                                    k1: k1, k2: k2, k3: k3, k4: k4,
                                    imageWidth: Double(imageWidth), imageHeight: Double(imageHeight))
        let mrL = fitL.params
        // Fit Mei-Rives for right eye
        let fitR = fitKBtoMeiRives(fx: fxR, fy: fyR, cx: cxR, cy: cyR,
                                    k1: k1, k2: k2, k3: k3, k4: k4,
                                    imageWidth: Double(imageWidth), imageHeight: Double(imageHeight))
        let mrR = fitR.params

        // Build quaternion from stereo rotation (half applied to each eye, opposite signs)
        let halfX = stereoRotX * .pi / 720.0
        let halfY = stereoRotY * .pi / 720.0
        let halfZ = stereoRotZ * .pi / 720.0
        func eulerToQuat(rx: Double, ry: Double, rz: Double) -> [Double] {
            let cx = cos(rx), sx = sin(rx), cy = cos(ry), sy = sin(ry), cz = cos(rz), sz = sin(rz)
            return [
                sx*cy*cz + cx*sy*sz,
                cx*sy*cz - sx*cy*sz,
                cx*cy*sz + sx*sy*cz,
                cx*cy*cz - sx*sy*sz
            ]
        }
        let quatL = eulerToQuat(rx: halfX, ry: -halfY, rz: -halfZ)
        let quatR = eulerToQuat(rx: -halfX, ry: halfY, rz: halfZ)

        // Select L/R assignment (flip if needed)
        let leftMR = flipLR ? mrR : mrL
        let rightMR = flipLR ? mrL : mrR
        let leftQuat = flipLR ? quatR : quatL
        let rightQuat = flipLR ? quatL : quatR
        let leftFit = flipLR ? fitR : fitL
        let rightFit = flipLR ? fitL : fitR

        // Load the known working ILPD template
        let appParent = Bundle.main.bundleURL.deletingLastPathComponent().path
        let bundleResources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources").path
        let templatePaths = [
            Bundle.main.path(forResource: "ilpd_template", ofType: "json"),
            "\(bundleResources)/ilpd_template.json",
            "\(appParent)/ilpd_template.json",
            "/Users/siyangqi/Downloads/Aime investigate/ilpd_template.json"
        ].compactMap { $0 }

        // Use template-based approach: start from known working ILPD, replace only essential values
        // If template not found, build from scratch using the reference structure
        func buildFromTemplate() -> String? {
            for path in templatePaths {
                guard let data = FileManager.default.contents(atPath: path),
                      var tmpl = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      var device = tmpl["captureDevice"] as? [String: Any],
                      var views = device["views"] as? [[String: Any]],
                      views.count >= 2 else { continue }

                // Update top-level fields
                tmpl["cameraID"] = cameraID
                tmpl["uuid"] = calibrationUUID

                // Update each view
                for idx in 0..<2 {
                    let mr = idx == 0 ? leftMR : rightMR
                    let quat = idx == 0 ? leftQuat : rightQuat
                    let fit = idx == 0 ? leftFit : rightFit
                    let trans: [Double] = idx == 0 ? [0, 0, 0] : [-baseline * 1000, 0, 0]

                    // Extrinsics
                    if var exts = views[idx]["extrinsics"] as? [[String: Any]] {
                        exts[0]["quat"] = quat
                        exts[0]["translation"] = trans
                        views[idx]["extrinsics"] = exts
                    }

                    // Image size
                    views[idx]["imageSize"] = [imageWidth, imageHeight]

                    // Intrinsics — only replace essential values
                    if var intr = views[idx]["intrinsics"] as? [String: Any] {
                        intr["centerX"] = mr.cx
                        intr["centerY"] = Double(imageHeight) - mr.cy
                        intr["fx"] = mr.fx
                        intr["fy"] = mr.fy
                        intr["distortions"] = [mr.k1, mr.k2, mr.xi, mr.p1, mr.p2]
                        intr["calibrationLimitRadialAngle"] = fit.calibrationLimitRadialAngle
                        views[idx]["intrinsics"] = intr
                    }

                    // Optical data FOV
                    if var opt = views[idx]["opticalData"] as? [String: Any] {
                        opt["Fov"] = ["horizontal": fit.hfov, "vertical": fit.vfov]
                        views[idx]["opticalData"] = opt
                    }
                }

                device["views"] = views
                tmpl["captureDevice"] = device

                if let jsonData = try? JSONSerialization.data(withJSONObject: tmpl, options: [.prettyPrinted, .sortedKeys]),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    return jsonStr
                }
                return nil
            }
            return nil
        }

        if let result = buildFromTemplate() {
            return result
        }

        // Fallback: build JSON from scratch (original approach)
        func formatArr(_ a: [Double], _ fmt: String) -> String {
            a.map { String(format: fmt, $0) }.joined(separator: ", ")
        }

        func viewJSON(desc: String, mr: MeiRivesParams, quat: [Double], translation: [Double],
                      calLimitAngle: Double, viewHFOV: Double, viewVFOV: Double) -> String {
            """
                    {
                        "extrinsics": [{"model": "dualRectification", "quat": [\(formatArr(quat, "%.16g"))], "translation": [\(formatArr(translation, "%.1f"))]}],
                        "imageSize": [\(imageWidth), \(imageHeight)],
                        "intrinsics": {
                            "calibrationLimitRadialAngle": \(String(format: "%.6f", calLimitAngle)),
                            "centerX": \(String(format: "%.6f", mr.cx)),
                            "centerY": \(String(format: "%.6f", Double(imageHeight) - mr.cy)),
                            "distortions": [\(String(format: "%.16g", mr.k1)), \(String(format: "%.16g", mr.k2)), \(String(format: "%.16g", mr.xi)), \(String(format: "%.16g", mr.p1)), \(String(format: "%.16g", mr.p2))],
                            "fx": \(String(format: "%.6f", mr.fx)), "fy": \(String(format: "%.6f", mr.fy)),
                            "imageLimitRadialAngle": -1.0, "model": "radial2ProjectionOffsetTangential2", "skew": 0.0
                        },
                        "lensOcclusionData": {},
                        "maskData": {"FOVHeight": 90, "FOVWidth": 60, "controlPointInterpolation": "cubicHermite", "defaultCalibration": "default", "edgeTreatment": "linear", "edgeWidth": 2.5, "isForVisionOS": true, "leftMapToRight": "standAlone", "maskColor": [1, 1, 1], "maskViewParameters": {"controlPoints": [[-0.9848077, 0, -0.17364822], [0, -0.9848077, -0.17364822], [0.9848077, 0, -0.17364822], [0, 0.9848077, -0.17364822]], "controlPointsOffsets": {}, "viewDescription": "\(desc)"}, "name": "174_fov_circular_32_points"},
                        "opticalData": {"Fov": {"horizontal": \(String(format: "%.4f", viewHFOV)), "vertical": \(String(format: "%.4f", viewVFOV))}, "aperture": 4.0},
                        "processingParameters": {},
                        "viewDescription": "\(desc)"
                    }
            """
        }

        return """
        {
            "ambientCalTemp": 20.0,
            "cameraID": "\(cameraID)",
            "captureDevice": {
                "calStationName": "AIMEGenerator",
                "views": [
        \(viewJSON(desc: "left", mr: leftMR, quat: leftQuat, translation: [0,0,0], calLimitAngle: leftFit.calibrationLimitRadialAngle, viewHFOV: leftFit.hfov, viewVFOV: leftFit.vfov)),
        \(viewJSON(desc: "right", mr: rightMR, quat: rightQuat, translation: [-baseline*1000,0,0], calLimitAngle: rightFit.calibrationLimitRadialAngle, viewHFOV: rightFit.hfov, viewVFOV: rightFit.vfov))
                ]
            },
            "formatVersion": [0, 1, 0],
            "generator": "Apple Immersive Camera Calibration Service",
            "generatorVersion": [1, 18, 0],
            "uuid": "\(calibrationUUID)"
        }
        """
    }
}

// MARK: - Deterministic UUID v5 from name
extension UUID {
    /// Generate a deterministic UUID v5 from a name string using a fixed namespace
    init(uuidFromName name: String) {
        // Use a fixed namespace UUID (DNS namespace from RFC 4122)
        let namespace: [UInt8] = [0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1,
                                   0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8]
        var data = namespace
        data.append(contentsOf: Array(name.utf8))

        // Simple hash (FNV-1a inspired) to fill 16 bytes
        var hash = [UInt8](repeating: 0, count: 16)
        for (i, byte) in data.enumerated() {
            hash[i % 16] ^= byte
            hash[i % 16] &+= byte &* 31
        }
        // Set version 5 and variant bits
        hash[6] = (hash[6] & 0x0F) | 0x50  // version 5
        hash[8] = (hash[8] & 0x3F) | 0x80  // variant 1
        self = UUID(uuid: (hash[0], hash[1], hash[2], hash[3],
                           hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11],
                           hash[12], hash[13], hash[14], hash[15]))
    }
}

enum MeshGen {
    // Kannala-Brandt fisheye model: theta_d = theta + k1*theta^3 + k2*theta^5 + k3*theta^7 + k4*theta^9
    static func generateHemisphereMesh(
        imageWidth: Float, imageHeight: Float,
        fx: Float, fy: Float, cx: Float, cy: Float,
        k1: Float, k2: Float, k3: Float, k4: Float,
        hfov: Float, thetaSteps: Int, phiSteps: Int
    ) -> (vertices: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32]) {
        var vertices: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        let maxPhi = min(hfov / 2.0, 179.0) * Float.pi / 180.0

        for j in 0...phiSteps {
            let phi = Float(j) / Float(phiSteps) * maxPhi

            for i in 0...thetaSteps {
                let theta = Float(i) / Float(thetaSteps) * 2.0 * Float.pi

                let x = sin(phi) * cos(theta)
                let y = sin(phi) * sin(theta)
                let z = -cos(phi)

                let r3d = sqrt(x * x + y * y)
                let t = atan2(r3d, -z)  // incidence angle from optical axis

                // Kannala-Brandt distorted radius
                let t2 = t * t
                let t3 = t2 * t
                let r_d = t + k1 * t3 + k2 * t2 * t3 + k3 * t2 * t2 * t3 + k4 * t2 * t2 * t2 * t3

                var xd: Float, yd: Float
                if r3d < 1e-8 {
                    xd = 0; yd = 0
                } else {
                    xd = r_d * x / r3d
                    yd = r_d * y / r3d
                }

                let u = (fx * xd + cx) / imageWidth
                let v = (fy * yd + cy) / imageHeight

                vertices.append(SIMD3<Float>(x, y, z))
                uvs.append(SIMD2<Float>(u, v))
            }
        }

        for j in 0..<phiSteps {
            for i in 0..<thetaSteps {
                let row0 = UInt32(j * (thetaSteps + 1))
                let row1 = UInt32((j + 1) * (thetaSteps + 1))
                let a = row0 + UInt32(i)
                let b = row0 + UInt32(i + 1)
                let c = row1 + UInt32(i)
                let d = row1 + UInt32(i + 1)
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }

        return (vertices, uvs, indices)
    }

    static func buildFullUSDA(
        leftVerts: [SIMD3<Float>], leftUVs: [SIMD2<Float>], leftIndices: [UInt32],
        rightVerts: [SIMD3<Float>], rightUVs: [SIMD2<Float>], rightIndices: [UInt32]
    ) -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let primName = "_\(uuid)"

        var s = """
        #usda 1.0
        (
            defaultPrim = "\(primName)"
            upAxis = "Y"
        )

        def Xform "\(primName)" (
            assetInfo = {
                string name = "\(primName)"
            }
            kind = "component"
        )
        {
            def Scope "Geom"
            {

        """
        s += buildMeshUSDA(name: "_0_Left", vertices: leftVerts, uvs: leftUVs, indices: leftIndices,
                           materialPath: "/\(primName)/Materials/Default", indent: "        ")
        s += buildMeshUSDA(name: "_0_Right", vertices: rightVerts, uvs: rightUVs, indices: rightIndices,
                           materialPath: "/\(primName)/Materials/Default", indent: "        ")
        s += """
            }
            def Scope "Materials"
            {
                def Material "Default"
                {
                    token outputs:surface.connect = </\(primName)/Materials/Default/surfaceShader.outputs:surface>
                    def Shader "surfaceShader"
                    {
                        uniform token info:id = "UsdPreviewSurface"
                        token outputs:surface
                    }
                }
            }
        }

        """
        return s
    }

    static func buildMeshUSDA(
        name: String, vertices: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32],
        materialPath: String, indent: String
    ) -> String {
        var s = ""
        s += "\(indent)def Mesh \"\(name)\" (\n"
        s += "\(indent)    prepend apiSchemas = [\"MaterialBindingAPI\"]\n"
        s += "\(indent))\n\(indent){\n"

        var minPt = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxPt = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for v in vertices { minPt = min(minPt, v); maxPt = max(maxPt, v) }
        s += "\(indent)    float3[] extent = [(\(minPt.x), \(minPt.y), \(minPt.z)), (\(maxPt.x), \(maxPt.y), \(maxPt.z))]\n"

        let fc = indices.count / 3
        s += "\(indent)    int[] faceVertexCounts = [\(Array(repeating: "3", count: fc).joined(separator: ", "))]\n"
        s += "\(indent)    int[] faceVertexIndices = [\(indices.map { String($0) }.joined(separator: ", "))]\n"
        s += "\(indent)    rel material:binding = <\(materialPath)>\n"
        s += "\(indent)    point3f[] points = [\(vertices.map { "(\($0.x), \($0.y), \($0.z))" }.joined(separator: ", "))]\n"
        s += "\(indent)    float2[] primvars:st = [\(uvs.map { "(\($0.x), \($0.y))" }.joined(separator: ", "))] (\n"
        s += "\(indent)        interpolation = \"vertex\"\n"
        s += "\(indent)    )\n"
        s += "\(indent)    uniform token subdivisionScheme = \"none\"\n"
        s += "\(indent)}\n"
        return s
    }

    /// Generate mask control points.
    /// Each point defines a direction on the unit sphere at a given angular distance from -Z (forward).
    /// The point is placed on a plane at z=zValue, with x,y computed to achieve the desired angular radius.
    /// `radius` controls the angular extent: 1.0 ≈ planeAngle-dependent max, values > 1 push beyond.
    static func makeCircularControlPoints(count: Int, radius: Float, centerY: Float = -0.35, zValue: Float, radii: [Float]? = nil) -> [Point3DFloat] {
        // Start from leftmost point (angle = π) and sweep clockwise, matching Apple's convention
        // radii: per-point radius multipliers (default 1.0 = use uniform radius)
        (0..<count).map { i in
            let angle = Float.pi - Float(i) / Float(count) * 2.0 * .pi
            let r = radius * (radii != nil && i < radii!.count ? radii![i] : 1.0)
            return Point3DFloat(x: r * cos(angle), y: centerY + r * sin(angle), z: zValue)
        }
    }

    /// Generate mask control points using angular specification.
    /// Each point is first computed as a unit sphere direction at `maskAngleDeg` from -Z,
    /// then projected onto the plane at z = -sin(planeAngleDeg).
    /// This works correctly for any plane angle including 0 and negative values.
    static func makeAngularControlPoints(count: Int, maskAngleDeg: Float, centerY: Float = 0.0, planeAngleDeg: Float = 10.0, radii: [Float]? = nil) -> [Point3DFloat] {
        let planeAngle = planeAngleDeg * .pi / 180.0
        let zPlane = -sin(planeAngle)
        let basePhi = maskAngleDeg * .pi / 180.0

        return (0..<count).map { i in
            let sweepAngle = Float.pi - Float(i) / Float(count) * 2.0 * .pi
            let perPointR = (radii != nil && i < radii!.count ? radii![i] : 1.0)

            // Angular distance from -Z for this point (perPointR scales the radius)
            let phi = basePhi * perPointR

            // Unit sphere direction at angle phi from -Z, swept around Z axis
            let dx = sin(phi) * cos(sweepAngle)
            let dy = sin(phi) * sin(sweepAngle)
            let dz = -cos(phi)

            // Project onto plane at z = zPlane
            if abs(dz) > 1e-6 {
                let t = zPlane / dz
                return Point3DFloat(x: t * dx, y: centerY + t * dy, z: zPlane)
            } else {
                let bigR: Float = 10.0
                return Point3DFloat(x: bigR * dx, y: centerY + bigR * dy, z: zPlane)
            }
        }
    }

    static func createUSDZ(from usdcURL: URL) throws -> Data {
        let usdcData = try Data(contentsOf: usdcURL)
        let usdcName = usdcURL.lastPathComponent
        var zip = Data()

        zip.append(contentsOf: [0x50, 0x4B, 0x03, 0x04, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let crc = crc32(usdcData)
        zip.append(contentsOf: withUnsafeBytes(of: crc.littleEndian) { Array($0) })
        let size32 = UInt32(usdcData.count)
        zip.append(contentsOf: withUnsafeBytes(of: size32.littleEndian) { Array($0) })
        zip.append(contentsOf: withUnsafeBytes(of: size32.littleEndian) { Array($0) })
        let nameData = usdcName.data(using: .utf8)!
        let nameLen = UInt16(nameData.count)
        zip.append(contentsOf: withUnsafeBytes(of: nameLen.littleEndian) { Array($0) })

        let headerSize = 30 + nameData.count
        let padding = (64 - (headerSize % 64)) % 64
        zip.append(contentsOf: withUnsafeBytes(of: UInt16(padding).littleEndian) { Array($0) })
        zip.append(nameData)
        zip.append(Data(repeating: 0, count: padding))
        zip.append(usdcData)

        let cdOffset = UInt32(zip.count)
        zip.append(contentsOf: [0x50, 0x4B, 0x01, 0x02, 0x0A, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        zip.append(contentsOf: withUnsafeBytes(of: crc.littleEndian) { Array($0) })
        zip.append(contentsOf: withUnsafeBytes(of: size32.littleEndian) { Array($0) })
        zip.append(contentsOf: withUnsafeBytes(of: size32.littleEndian) { Array($0) })
        zip.append(contentsOf: withUnsafeBytes(of: nameLen.littleEndian) { Array($0) })
        zip.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        zip.append(nameData)
        let cdSize = UInt32(zip.count) - cdOffset

        zip.append(contentsOf: [0x50, 0x4B, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00])
        zip.append(contentsOf: withUnsafeBytes(of: cdSize.littleEndian) { Array($0) })
        zip.append(contentsOf: withUnsafeBytes(of: cdOffset.littleEndian) { Array($0) })
        zip.append(contentsOf: [0x00, 0x00])

        return zip
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xEDB88320 : 0) }
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Content View


struct ContentView: View {
    @StateObject private var vm = AIMEViewModel()
    @State private var showGyroflowImporterLeft = false
    @State private var showAIMEImporter = false
    @State private var showVideoImporter = false
    @State private var showProjectLoad = false
    // (drag state moved to PreviewInteractionOverlay)

    var body: some View {
        HSplitView {
            // Left: Settings form
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                // Title
                VStack(alignment: .leading, spacing: 2) {
                    Text("AIME Generator").font(.title.bold())
                    Text("Apple Immersive Video Lens Profile Builder  —  by Siyang Qi")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Action buttons
                HStack {
                    Button {
                        showProjectLoad = true
                    } label: {
                        Label("Load Project", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .fileImporter(
                        isPresented: $showProjectLoad,
                        allowedContentTypes: [UTType.json],
                        allowsMultipleSelection: false
                    ) { result in
                        if case .success(let urls) = result, let url = urls.first {
                            _ = url.startAccessingSecurityScopedResource()
                            defer { url.stopAccessingSecurityScopedResource() }
                            if let data = try? Data(contentsOf: url),
                               let proj = try? JSONDecoder().decode(AIMEViewModel.ProjectData.self, from: data) {
                                vm.loadProject(proj)
                            }
                        }
                    }
                    Button {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [UTType.json]
                        panel.nameFieldStringValue = "\(vm.cameraID).json"
                        if panel.runModal() == .OK, let url = panel.url {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            if let data = try? encoder.encode(vm.saveProject()) {
                                try? data.write(to: url)
                                vm.statusMessage = "Project saved to \(url.lastPathComponent)"
                            }
                        }
                    } label: {
                        Label("Save Project", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        showGyroflowImporterLeft = true
                    } label: {
                        Label("Import Gyroflow JSON", systemImage: "doc.badge.gearshape")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .fileImporter(
                        isPresented: $showGyroflowImporterLeft,
                        allowedContentTypes: [UTType.json],
                        allowsMultipleSelection: false
                    ) { result in
                        if case .success(let urls) = result, let url = urls.first {
                            _ = url.startAccessingSecurityScopedResource()
                            vm.importGyroflow(url: url, eye: .left)
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                }
                .padding(.bottom, 4)

                if !vm.gyroflowInfo.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(vm.gyroflowInfo)
                            .font(.callout)
                    }
                    .padding(8)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }

                // Camera Identity
                GroupBox("Camera Identity") {
                    LabeledField("Camera ID", text: $vm.cameraID)
                    LabeledField("Calibration Name", text: $vm.calibrationName)
                }

                // Image Dimensions
                GroupBox("Image Dimensions") {
                    HStack(spacing: 16) {
                        LabeledField("Width (px)", text: $vm.imageWidth)
                        LabeledField("Height (px)", text: $vm.imageHeight)
                    }
                }

                // Shared intrinsics & distortion
                GroupBox("Intrinsics & Distortion (shared both eyes)") {
                    HStack(spacing: 16) {
                        LabeledField("fx (focal X)", text: $vm.fx)
                        LabeledField("fy (focal Y)", text: $vm.fy)
                    }
                    Divider()
                    HStack(spacing: 16) {
                        LabeledField("k1", text: $vm.k1)
                        LabeledField("k2", text: $vm.k2)
                    }
                    HStack(spacing: 16) {
                        LabeledField("k3", text: $vm.k3)
                        LabeledField("k4", text: $vm.k4)
                    }
                    Text("Kannala-Brandt: \u{03B8}d = \u{03B8} + k1\u{00B7}\u{03B8}\u{00B3} + k2\u{00B7}\u{03B8}\u{2075} + k3\u{00B7}\u{03B8}\u{2077} + k4\u{00B7}\u{03B8}\u{2079}")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Per-eye principal points
                GroupBox("Per-Eye Calibration") {
                    Text("Principal point + rotational misalignment between cameras.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)

                    // Principal points side by side
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Left Eye (reference)").font(.caption.bold())
                            StepperField("cx", text: $vm.leftCx, step: 0.1)
                            StepperField("cy", text: $vm.leftCy, step: 0.1)
                        }
                        Divider().frame(height: 80)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Right Eye").font(.caption.bold())
                            StepperField("cx", text: $vm.rightCx, step: 0.1)
                            StepperField("cy", text: $vm.rightCy, step: 0.1)
                        }
                    }
                    if let lCx = Float(vm.leftCx), let rCx = Float(vm.rightCx),
                       let lCy = Float(vm.leftCy), let rCy = Float(vm.rightCy) {
                        let dx = rCx - lCx
                        let dy = rCy - lCy
                        if abs(dx) > 0.01 || abs(dy) > 0.01 {
                            Text(String(format: "Offset: \u{0394}cx = %.1f px, \u{0394}cy = %.1f px", dx, dy))
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }

                    Divider()

                    // Stereo rotation offset
                    Text("Stereo rotation offset (degrees) \u{2014} applied as \u{00B1}half to each eye")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 16) {
                        StepperField("Pitch (X)", text: $vm.stereoRotX, step: 0.1)
                        StepperField("Yaw (Y)", text: $vm.stereoRotY, step: 0.1)
                        StepperField("Roll (Z)", text: $vm.stereoRotZ, step: 0.1)
                    }
                    if let rx = Float(vm.stereoRotX), let ry = Float(vm.stereoRotY), let rz = Float(vm.stereoRotZ),
                       (abs(rx) > 0.001 || abs(ry) > 0.001 || abs(rz) > 0.001) {
                        Text(String(format: "Left: %.3f/%.3f/%.3f\u{00B0}  Right: +%.3f/+%.3f/+%.3f\u{00B0}", -rx/2, -ry/2, -rz/2, rx/2, ry/2, rz/2))
                            .font(.caption.monospaced())
                            .foregroundColor(.orange)
                    }
                }

                // Projection Settings
                GroupBox("Projection & Mesh") {
                    HStack(spacing: 16) {
                        LabeledField("H-FOV (\u{00B0})", text: $vm.hfov)
                        LabeledField("Baseline (m)", text: $vm.baseline)
                    }
                    HStack(spacing: 16) {
                        LabeledField("\u{03B8} steps (longitude)", text: $vm.thetaSteps)
                        LabeledField("\u{03C6} steps (latitude)", text: $vm.phiSteps)
                    }
                    LabeledField("Frame Rate (fps)", text: $vm.frameRate)
                }

                // Mask Settings
                GroupBox("Dynamic Mask") {
                    Picker("Mask Mode", selection: $vm.maskMode) {
                        ForEach(AIMEViewModel.MaskMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if vm.maskMode == .offMaxFOV {
                        Text("Transparent image mask — maximum FOV. Works on Vision Pro but may not preview in Immersive Utility.")
                            .font(.caption2).foregroundColor(.secondary)
                    } else if vm.maskMode == .offCompatible {
                        Text("Wide dynamic mask covering ~96° from forward. Compatible with Immersive Utility.")
                            .font(.caption2).foregroundColor(.secondary)
                    }

                    if vm.maskMode == .custom {
                        HStack(spacing: 4) {
                            Text("Size").font(.caption2).frame(width: 28)
                            Button("-") { vm.maskAdjustModeSize(delta: -1) }.font(.caption)
                            Slider(value: Binding(
                                get: { Double(vm.maskSizePercent) },
                                set: { vm.setMaskSizePercent(Float($0)) }
                            ), in: 10...150, step: 1)
                            Button("+") { vm.maskAdjustModeSize(delta: 1) }.font(.caption)
                            TextField("", text: Binding(
                                get: { String(Int(vm.maskSizePercent)) },
                                set: { if let v = Float($0) { vm.setMaskSizePercent(v) } }
                            ))
                            .frame(width: 36)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                            Text("%").font(.caption2)
                        }
                        HStack(spacing: 8) {
                            LabeledField("Edge Width (°)", text: $vm.maskEdgeWidth)
                            LabeledField("Points", text: $vm.maskNumPoints)
                            Picker("Edge", selection: $vm.maskEdgeTreatment) {
                                Text("Linear").tag("linear")
                                Text("Ease In/Out").tag("easeInOut")
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 150)
                        }
                        HStack {
                            Button("Reset Mask") {
                                vm.resetMaskRadii()
                                vm.maskSizePercent = 95
                            }
                            .font(.caption)
                        }

                        // Mask Adjustment Mode
                        Toggle(isOn: $vm.maskAdjustMode) {
                            Text("Mask Adjustment Mode")
                                .font(.headline)
                        }
                        .toggleStyle(.switch)
                        .padding(.top, 4)

                        if vm.maskAdjustMode {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Drag control points in preview to reshape the mask")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Toggle("Mirror Horizontally (Left ↔ Right)", isOn: $vm.maskMirrorH)
                                    .font(.caption)
                                Toggle("Mirror Vertically (Top ↔ Bottom)", isOn: $vm.maskMirrorV)
                                    .font(.caption)
                            }
                            .padding(.leading, 4)
                        }
                    }
                }

                Divider()

                // Status
                HStack {
                    if vm.isGenerating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .padding(.trailing, 4)
                    }
                    Text(vm.statusMessage)
                        .font(.callout)
                        .foregroundColor(vm.statusMessage.contains("Error") ? .red : .secondary)
                        .lineLimit(2)
                    Spacer()
                }

                // Export row 1: AIME + ILPD
                HStack {
                    Button {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [UTType(filenameExtension: "aime") ?? .data]
                        panel.nameFieldStringValue = "\(vm.cameraID).aime"
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            Task {
                                await vm.generateAIME(to: url)
                            }
                        }
                    } label: {
                        Label("Generate .aime", systemImage: "arrow.down.doc.fill")
                            .font(.headline)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(vm.isGenerating)
                    .controlSize(.large)

                    Button {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [UTType(filenameExtension: "ilpd") ?? .data]
                        panel.nameFieldStringValue = "\(vm.cameraID).ilpd"
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            vm.exportILPD(to: url)
                        }
                    } label: {
                        Label("Export .ilpd", systemImage: "doc.text")
                            .font(.headline)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)

                    Spacer()
                }

                // Export row 2: Inject to Video + Flip toggle
                HStack {
                    Button {
                        guard let videoURL = vm.videoURL else { return }
                        let ext = videoURL.pathExtension.isEmpty ? "mov" : videoURL.pathExtension
                        let base = videoURL.deletingPathExtension().lastPathComponent
                        let dir = videoURL.deletingLastPathComponent()
                        // Auto-name: foo.mov → foo_ilpd.mov, avoid overwriting
                        var outputURL = dir.appendingPathComponent("\(base)_ilpd.\(ext)")
                        var counter = 2
                        while FileManager.default.fileExists(atPath: outputURL.path) {
                            outputURL = dir.appendingPathComponent("\(base)_ilpd_\(counter).\(ext)")
                            counter += 1
                        }
                        vm.injectILPDToVideo(outputURL: outputURL)
                    } label: {
                        Label("Inject ILPD to Video", systemImage: "film.stack")
                            .font(.headline)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.large)
                    .disabled(vm.videoURL == nil)

                    Toggle("Flip L/R calibration in ILPD", isOn: $vm.flipILPDCalibration)
                        .font(.caption)
                        .fixedSize()

                    Spacer()
                }
            }
            .padding(20)
            .alert("ILPD Injection", isPresented: $vm.showInjectAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.injectAlertMessage)
            }
        }
        .frame(minWidth: 420, maxWidth: 520)

        // Right: Video preview
        VStack(spacing: 8) {
            // Top bar: mode picker + open video
            HStack {
                Picker("", selection: $vm.previewMode) {
                    ForEach(PreviewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button {
                    showVideoImporter = true
                } label: {
                    Label("Open Video", systemImage: "video.badge.plus")
                }
                .buttonStyle(.bordered)
                .fileImporter(
                    isPresented: $showVideoImporter,
                    allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .data],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        _ = url.startAccessingSecurityScopedResource()
                        vm.loadVideo(url: url)
                    }
                }
            }

            // Preview image
            ZStack {
                Color.black
                if let img = vm.cachedComposite {
                    GeometryReader { geo in
                        let imgSize = img.size
                        let fitScale = min(geo.size.width / imgSize.width, geo.size.height / imgSize.height)
                        let displayW = imgSize.width * fitScale * vm.previewZoom
                        let displayH = imgSize.height * fitScale * vm.previewZoom
                        Image(nsImage: img)
                            .resizable()
                            .frame(width: displayW, height: displayH)
                            .position(
                                x: geo.size.width / 2 + vm.previewPanX,
                                y: geo.size.height / 2 + vm.previewPanY
                            )
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 48))
                            .foregroundColor(.gray)
                        Text("Open a video to preview")
                            .foregroundColor(.gray)
                    }
                }
                if vm.isLoadingFrame {
                    ProgressView("Loading...").background(Color.black.opacity(0.5))
                }
            }
            .clipped()
            .cornerRadius(8)
            .allowsHitTesting(false)
            .overlay(
                PreviewInteractionOverlay(vm: vm)
            )
            .onChange(of: vm.previewHash) { _, _ in vm.rebuildComposite() }
            .onChange(of: vm.swapEyes) { _, _ in
                // Swap cached frames and rebuild composite
                let tmp = vm.leftFrame
                vm.leftFrame = vm.rightFrame
                vm.rightFrame = tmp
                vm.rebuildComposite()
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url = url { DispatchQueue.main.async { vm.loadVideo(url: url) } }
                    }
                }
                return true
            }

            // Timeline
            if vm.videoURL != nil {
                HStack {
                    Text(formatTime(vm.currentTime)).font(.caption.monospaced()).frame(width: 50)
                    Slider(value: $vm.scrubTime, in: 0...max(0.1, vm.duration))
                        .onChange(of: vm.scrubTime) { _, newVal in
                            // Debounce: only extract after user stops dragging
                            vm.scrubDebounceTask?.cancel()
                            vm.scrubDebounceTask = Task {
                                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                                if !Task.isCancelled { await vm.extractFrame(at: newVal) }
                            }
                        }
                    Text(formatTime(vm.duration)).font(.caption.monospaced()).frame(width: 50)
                }
            }

            // Controls row
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    Toggle("Cross", isOn: $vm.showCrosshair).font(.caption)
                    Toggle("Mask", isOn: $vm.showMask).font(.caption)
                }
                Divider().frame(height: 40)
                // Rect controls
                VStack(spacing: 2) {
                    HStack { Text("FOV").font(.caption2); Slider(value: $vm.rectFOV, in: 30...150); Text("\(Int(vm.rectFOV))°").font(.caption2).frame(width: 30) }
                    HStack { Text("Yaw").font(.caption2); Slider(value: $vm.rectYaw, in: -180...180); Text("\(Int(vm.rectYaw))°").font(.caption2).frame(width: 30) }
                    HStack { Text("Pit").font(.caption2); Slider(value: $vm.rectPitch, in: -90...90); Text("\(Int(vm.rectPitch))°").font(.caption2).frame(width: 30) }
                }
                Button("Reset") { vm.rectYaw = 0; vm.rectPitch = 0 }
                    .font(.caption)
                    .buttonStyle(.bordered)
                Divider().frame(height: 40)
                HStack(spacing: 4) {
                    Button("-") { vm.previewZoom = max(0.1, vm.previewZoom / 1.25) }
                        .font(.caption).buttonStyle(.bordered).frame(width: 24)
                    Text("\(Int(vm.previewZoom * 100))%").font(.caption.monospaced()).frame(width: 40)
                    Button("+") { vm.previewZoom = min(20, vm.previewZoom * 1.25) }
                        .font(.caption).buttonStyle(.bordered).frame(width: 24)
                    Button("Fit") { vm.previewZoom = 1; vm.previewPanX = 0; vm.previewPanY = 0 }
                        .font(.caption2).buttonStyle(.bordered)
                }
            }

            if !vm.videoInfo.isEmpty {
                Text(vm.videoInfo).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(12)
        }  // HSplitView
    }

    func formatTime(_ t: Double) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

enum PreviewMode: String, CaseIterable {
    case sideBySide = "Side by Side"
    case anaglyph = "Anaglyph"
    case overlay = "Overlay 50%"
    case leftOnly = "Left Eye"
    case rightOnly = "Right Eye"
    case rectLeft = "Rect Left"
    case rectRight = "Rect Right"
    case rectAnaglyph = "Rect Anaglyph"
}


// MARK: - Preview Interaction (zoom, pan, cx/cy drag)

/// NSViewRepresentable that handles scroll-to-zoom, option+drag pan, and drag to adjust cx/cy
struct PreviewInteractionOverlay: NSViewRepresentable {
    @ObservedObject var vm: AIMEViewModel

    func makeNSView(context: Context) -> InteractionNSView {
        let v = InteractionNSView()
        v.vm = vm
        return v
    }
    func updateNSView(_ nsView: InteractionNSView, context: Context) {
        nsView.vm = vm
    }

    class InteractionNSView: NSView {
        weak var vm: AIMEViewModel?
        private var lastDrag: NSPoint = .zero
        private var dragMode: DragMode = .none
        private var dragMaskIndex: Int = -1
        enum DragMode { case none, pan, alignLeft, alignRight, alignBoth, rectLook, maskPoint }

        override var acceptsFirstResponder: Bool { true }

        /// Zoom toward a point in NSView coords, adjusting pan so that point stays fixed
        private func zoomToward(event: NSEvent, newZoom: CGFloat) {
            guard let vm = vm else { return }
            let clamped = max(0.1, min(20.0, newZoom))
            let s = clamped / vm.previewZoom

            // Cursor in SwiftUI coords (Y-down): convert from NSView (Y-up)
            let nsLoc = convert(event.locationInWindow, from: nil)
            let mx = nsLoc.x                    // same X
            let my = bounds.height - nsLoc.y    // flip Y for SwiftUI

            // Vector from view center to cursor (in SwiftUI coords)
            let dx = mx - bounds.width / 2
            let dy = my - bounds.height / 2

            // The image point under cursor is at offset (dx - panX, dy - panY) from image center.
            // After scaling by s, that point moves to s*(dx - panX) from new image center.
            // We want it to still be at (dx) from view center, so:
            // panX_new = dx - s*(dx - panX) = dx*(1-s) + s*panX
            vm.previewPanX = dx * (1 - s) + s * vm.previewPanX
            vm.previewPanY = dy * (1 - s) + s * vm.previewPanY
            vm.previewZoom = clamped
        }

        override func scrollWheel(with event: NSEvent) {
            guard let vm = vm else { return }

            let isTrackpadScroll = event.momentumPhase != [] || event.phase != []

            if isTrackpadScroll && !event.modifierFlags.contains(.command) {
                // Two-finger scroll = pan (natural direction: content follows fingers)
                vm.previewPanX -= event.scrollingDeltaX
                vm.previewPanY -= event.scrollingDeltaY
            } else {
                // Cmd+scroll or mouse wheel = zoom
                let delta = event.scrollingDeltaY
                if abs(delta) < 0.01 { return }
                let factor = 1.0 + delta * 0.01
                zoomToward(event: event, newZoom: vm.previewZoom * factor)
            }
        }

        override func magnify(with event: NSEvent) {
            guard let vm = vm else { return }
            zoomToward(event: event, newZoom: vm.previewZoom * (1.0 + event.magnification))
        }

        override func mouseDown(with event: NSEvent) {
            guard let vm = vm else { return }
            lastDrag = convert(event.locationInWindow, from: nil)

            let isRect = [.rectLeft, .rectRight, .rectAnaglyph].contains(vm.previewMode)

            // In maskAdjustMode mode, all clicks (except option+drag) go to mask point selection
            if vm.maskAdjustMode && !isRect {
                if event.modifierFlags.contains(.option) {
                    dragMode = .pan
                    NSCursor.closedHand.set()
                    return
                }
                // Find nearest mask point — only when mask adjust mode is on
                if vm.maskAdjustMode, let nearIdx = findNearestMaskPoint(at: lastDrag, threshold: 30) {
                    dragMode = .maskPoint
                    dragMaskIndex = nearIdx
                    vm.selectedMaskPoint = nearIdx
                    vm.isDraggingAlignment = true
                    NSCursor.crosshair.set()
                    vm.rebuildComposite()  // redraw to show selection
                } else {
                    // Deselect
                    vm.selectedMaskPoint = -1
                    dragMode = .pan
                    NSCursor.closedHand.set()
                    vm.rebuildComposite()
                }
                return
            }

            if event.modifierFlags.contains(.option) {
                dragMode = .pan
                NSCursor.closedHand.set()
            } else if isRect {
                dragMode = .rectLook
                vm.isDraggingAlignment = true
            } else {
                // Fisheye alignment drag: determine which eye based on click position
                if event.modifierFlags.contains(.shift) {
                    dragMode = .alignBoth
                } else {
                    // In SBS mode, left half = left eye, right half = right eye
                    // In overlay/anaglyph/single modes, default to right (standard VR alignment)
                    let loc = lastDrag
                    let isSBS = vm.previewMode == .sideBySide
                    if isSBS && loc.x < bounds.midX {
                        dragMode = .alignLeft
                    } else if vm.previewMode == .leftOnly {
                        dragMode = .alignLeft
                    } else {
                        dragMode = .alignRight
                    }
                }
                vm.isDraggingAlignment = true
                NSCursor.closedHand.set()
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let vm = vm else { return }
            let loc = convert(event.locationInWindow, from: nil)
            let dx = loc.x - lastDrag.x
            let dy = loc.y - lastDrag.y
            lastDrag = loc

            switch dragMode {
            case .pan:
                vm.previewPanX += dx
                vm.previewPanY -= dy

            case .rectLook:
                let sens = 0.3 / max(0.5, vm.rectFOV / 90)
                vm.rectYaw -= Double(dx) * sens
                vm.rectPitch += Double(dy) * sens
                vm.rectYaw = max(-180, min(180, vm.rectYaw))
                vm.rectPitch = max(-90, min(90, vm.rectPitch))

            case .alignLeft, .alignRight, .alignBoth:
                // Scale widget pixels to calibration image pixels
                let origW = Float(vm.imageWidth) ?? 1
                // Compute scale from widget to image coords
                guard let img = vm.cachedComposite else { return }
                let imgW = img.size.width
                let imgH = img.size.height
                let fitScale = min(bounds.width / imgW, bounds.height / imgH) * vm.previewZoom
                let pixelScale = Float(origW) / Float(imgW) / Float(fitScale)

                let imgDx = Float(dx) * pixelScale
                let imgDy = Float(dy) * pixelScale  // match shader Y convention

                // Check if shift was pressed/released during drag
                let currentMode: DragMode
                if event.modifierFlags.contains(.shift) {
                    currentMode = .alignBoth
                } else {
                    currentMode = dragMode
                }

                switch currentMode {
                case .alignLeft, .alignBoth:
                    if let cx = Float(vm.leftCx), let cy = Float(vm.leftCy) {
                        vm.leftCx = String(format: "%.1f", cx - imgDx)
                        vm.leftCy = String(format: "%.1f", cy - imgDy)
                    }
                    if currentMode == .alignLeft { break }
                    fallthrough
                case .alignRight:
                    if let cx = Float(vm.rightCx), let cy = Float(vm.rightCy) {
                        vm.rightCx = String(format: "%.1f", cx - imgDx)
                        vm.rightCy = String(format: "%.1f", cy - imgDy)
                    }
                default: break
                }
                vm.rebuildComposite()

            case .maskPoint:
                var radii = vm.getMaskPixelRadii()
                guard dragMaskIndex >= 0, dragMaskIndex < radii.count else { break }
                // Compare distance from image center: before vs after mouse move
                // Farther from center = larger radius multiplier
                let viewCenterX = bounds.width / 2 + vm.previewPanX
                let viewCenterY = bounds.height / 2 - vm.previewPanY

                let prevDist = sqrt((lastDrag.x - dx - viewCenterX) * (lastDrag.x - dx - viewCenterX) + (lastDrag.y - dy - viewCenterY) * (lastDrag.y - dy - viewCenterY))
                let currDist = sqrt((loc.x - viewCenterX) * (loc.x - viewCenterX) + (loc.y - viewCenterY) * (loc.y - viewCenterY))

                let delta = Float(currDist - prevDist)
                guard let img = vm.cachedComposite else { break }
                let imgW = img.size.width
                let fitScale = min(bounds.width / imgW, bounds.height / imgW) * vm.previewZoom
                let sensitivity = Float(2.0 / (imgW * fitScale / 2))

                // Delta is in view pixels. Convert to image pixels.
                let imgW2 = Float(vm.imageWidth) ?? 2048
                let imgH2 = Float(vm.imageHeight) ?? 2048
                let maxR = min(imgW2, imgH2) / 2.0 - 1  // stay within image bounds
                let pixelDelta = delta * Float(imgW2) / Float(imgW * fitScale)
                radii[dragMaskIndex] = max(10, min(maxR, radii[dragMaskIndex] + pixelDelta))
                // Apply mirroring if in mask adjustment mode
                if vm.maskAdjustMode {
                    for mirrorIdx in vm.maskMirrorIndices(for: dragMaskIndex) {
                        if mirrorIdx >= 0 && mirrorIdx < radii.count {
                            radii[mirrorIdx] = max(10, min(maxR, radii[mirrorIdx] + pixelDelta))
                        }
                    }
                }
                vm.maskPixelRadii = radii
                vm.rebuildComposite()

            case .none: break
            }
        }

        /// Find the nearest mask control point within 15px of click position
        private func findNearestMaskPoint(at nsPoint: NSPoint, threshold: CGFloat = 15) -> Int? {
            guard let vm = vm, let img = vm.cachedComposite else { return nil }
            let maskPtsV = Int(vm.maskNumPoints) ?? 64
            let ew = Int(Float(vm.leftFrame?.width ?? 2048))
            let eh = Int(Float(vm.leftFrame?.height ?? 2048))
            let eyeCx = (Float(vm.imageWidth) ?? Float(ew)) / 2
            let eyeCy = (Float(vm.imageHeight) ?? Float(eh)) / 2

            let imgW = img.size.width, imgH = img.size.height
            let fitScale = min(bounds.width / imgW, bounds.height / imgH) * vm.previewZoom
            let viewCenterX = bounds.width / 2 + vm.previewPanX
            let viewCenterY = bounds.height / 2 - vm.previewPanY

            var bestIdx: Int? = nil
            var bestDist: CGFloat = threshold

            for i in 0..<maskPtsV {
                guard let pt = vm.maskPointToPixel(index: i, w: ew, h: eh, eyeCx: eyeCx, eyeCy: eyeCy) else { continue }
                // Convert composite pixel → view coords (NSView Y-up)
                // pt is in CG coords (Y=0 at bottom). NSView also has Y=0 at bottom.
                // But SwiftUI Image flips the NSImage, so CG Y=0 (bottom) appears at NSView bottom.
                let fracX = CGFloat(pt.x) / CGFloat(ew)
                let fracY = CGFloat(pt.y) / CGFloat(eh)
                let viewX = viewCenterX + (fracX - 0.5) * imgW * fitScale
                let viewY = viewCenterY + (fracY - 0.5) * imgH * fitScale  // CG Y=0 at bottom = NSView Y=0 at bottom

                let dist = sqrt((nsPoint.x - viewX) * (nsPoint.x - viewX) + (nsPoint.y - viewY) * (nsPoint.y - viewY))
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = i
                }
            }
            return bestIdx
        }

        override func mouseUp(with event: NSEvent) {
            let wasDraggingAlignment = vm?.isDraggingAlignment ?? false
            dragMode = .none
            NSCursor.arrow.set()
            if wasDraggingAlignment {
                vm?.isDraggingAlignment = false
                vm?.rebuildComposite()
            }
        }

        // (double-click handled via clickCount in mouseDown)

        override func rightMouseDown(with event: NSEvent) {
            guard let vm = vm else { return }
            vm.previewZoom = 1.0
            vm.previewPanX = 0
            vm.previewPanY = 0
        }
    }
}


struct LabeledField: View {
    let label: String
    @Binding var text: String

    init(_ label: String, text: Binding<String>) {
        self.label = label
        self._text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }
}

/// Text field with up/down stepper buttons
struct StepperField: View {
    let label: String
    @Binding var text: String
    var step: Float = 0.1

    init(_ label: String, text: Binding<String>, step: Float = 0.1) {
        self.label = label
        self._text = text
        self.step = step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 2) {
                TextField(label, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 60)
                VStack(spacing: 0) {
                    Button(action: { nudge(step) }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 18, height: 12)
                    }
                    .buttonStyle(.borderless)
                    Button(action: { nudge(-step) }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 18, height: 12)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func nudge(_ delta: Float) {
        if let val = Float(text) {
            text = String(format: "%.3f", val + delta)
        }
    }
}
