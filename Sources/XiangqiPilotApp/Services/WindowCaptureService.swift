@preconcurrency import ScreenCaptureKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

actor WindowCaptureService {
    private let output = StreamFrameOutput()
    private let sampleQueue = DispatchQueue(
        label: "com.jacksun.xiangqi-pilot.screen-capture",
        qos: .userInteractive
    )

    private var availableSCWindows: [CGWindowID: SCWindow] = [:]
    private var stream: SCStream?
    private var target: LockedCaptureTarget?

    /// Lists only currently visible windows. The returned descriptor is safe to
    /// keep in UI state; the underlying SCWindow is retained privately and must
    /// be resolved again whenever the list is refreshed.
    func refreshAvailableWindows() async throws -> [CapturableWindow] {
        guard MacPermissionsService.screenRecordingStatus == .granted else {
            throw WindowCaptureError.screenRecordingPermissionMissing
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )

        var cache: [CGWindowID: SCWindow] = [:]
        let ignoredBundleIdentifiers: Set<String> = [
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.WindowManager",
            "com.apple.notificationcenterui",
            "com.apple.dock"
        ]
        let ignoredTitles: Set<String> = ["Menubar", "StatusIndicator", "Dock"]

        let descriptors = content.windows.compactMap { window -> CapturableWindow? in
            guard let application = window.owningApplication,
                  window.frame.width >= 320,
                  window.frame.height >= 220,
                  !ignoredBundleIdentifiers.contains(application.bundleIdentifier),
                  !ignoredTitles.contains(window.title ?? "") else {
                return nil
            }
            cache[window.windowID] = window
            return CapturableWindow(
                windowID: window.windowID,
                ownerPID: application.processID,
                bundleIdentifier: application.bundleIdentifier,
                applicationName: application.applicationName,
                title: window.title ?? "",
                frame: window.frame
            )
        }

        availableSCWindows = cache
        return descriptors.sorted {
            if $0.applicationName == $1.applicationName {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending
        }
    }

    /// Locks one concrete SCWindow and starts exactly one persistent SCStream.
    /// Calling this method for another window first stops the previous stream.
    @discardableResult
    func lockWindow(_ windowID: CGWindowID) async throws -> LockedCaptureTarget {
        guard MacPermissionsService.screenRecordingStatus == .granted else {
            throw WindowCaptureError.screenRecordingPermissionMissing
        }

        if availableSCWindows[windowID] == nil {
            _ = try await refreshAvailableWindows()
        }
        guard let window = availableSCWindows[windowID] else {
            throw WindowCaptureError.windowNotFound(windowID)
        }
        guard let application = window.owningApplication else {
            throw WindowCaptureError.windowHasNoOwningApplication(windowID)
        }
        guard window.frame.width > 1, window.frame.height > 1 else {
            throw WindowCaptureError.invalidWindowSize
        }

        await stopCaptureIgnoringErrors()

        let lockedTarget = LockedCaptureTarget(
            windowID: window.windowID,
            ownerPID: application.processID,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.applicationName,
            title: window.title ?? "",
            frameAtLock: window.frame
        )

        let configuration = SCStreamConfiguration()
        // A 2x backing size preserves Retina detail. Mapping always uses the
        // actual CGImage dimensions, so 1x external displays remain correct.
        configuration.width = min(max(Int(window.frame.width.rounded(.up)) * 2, 2), 8_192)
        configuration.height = min(max(Int(window.frame.height.rounded(.up)) * 2, 2), 8_192)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)

        output.activate(newStream)
        output.resetForNewStream()
        do {
            try await newStream.startCapture()
        } catch {
            output.deactivate(newStream)
            throw error
        }

        stream = newStream
        target = lockedTarget
        return lockedTarget
    }

    /// Refreshes SCWindow metadata and restarts the stream after a material
    /// move/resize. Frame sequence remains monotonic, but any old action token
    /// becomes stale because image geometry and calibration hash must change.
    @discardableResult
    func relockCurrentWindow() async throws -> LockedCaptureTarget {
        guard let target else { throw WindowCaptureError.noLockedWindow }
        let windowID = target.windowID
        _ = try await refreshAvailableWindows()
        return try await lockWindow(windowID)
    }

    func lockedTarget() -> LockedCaptureTarget? {
        target
    }

    func currentLiveWindowGeometry() -> LiveWindowGeometry? {
        guard let target else { return nil }
        return Self.queryLiveWindowGeometry(windowID: target.windowID)
    }

    /// Returns the newest copied CGImage and an atomic set of metadata. The
    /// window geometry is queried at snapshot time so callers can detect a
    /// move/resize before preparing an action.
    func latestFrame() throws -> CapturedFrame {
        guard let target else { throw WindowCaptureError.noLockedWindow }
        // Never expose a cached image after the stream has stopped. It can no
        // longer prove a click precondition even though the pixels look valid.
        if let stopMessage = output.stopMessage {
            throw WindowCaptureError.streamStopped(stopMessage)
        }
        guard let stored = output.storedFrame else {
            throw WindowCaptureError.noFrameAvailable
        }

        return CapturedFrame(
            image: stored.image,
            sequence: stored.sequence,
            presentationTime: stored.presentationTime,
            contentFingerprint: stored.contentFingerprint,
            consecutiveStableFrames: stored.consecutiveStableFrames,
            imageSize: CGSize(width: stored.image.width, height: stored.image.height),
            target: target,
            liveWindowGeometry: Self.queryLiveWindowGeometry(windowID: target.windowID)
        )
    }

    func stopCapture() async throws {
        guard let stream else {
            target = nil
            return
        }
        output.deactivate(stream)
        self.stream = nil
        target = nil
        try await stream.stopCapture()
    }

    private func stopCaptureIgnoringErrors() async {
        guard let stream else {
            target = nil
            return
        }
        output.deactivate(stream)
        self.stream = nil
        target = nil
        try? await stream.stopCapture()
    }

    private static func queryLiveWindowGeometry(windowID: CGWindowID) -> LiveWindowGeometry? {
        guard let rawList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID),
              let list = rawList as? [[String: Any]],
              let info = list.first,
              let ownerNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }

        var frame = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDictionary as CFDictionary, &frame) else {
            return nil
        }

        let onScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        return LiveWindowGeometry(
            windowID: windowID,
            ownerPID: ownerNumber.int32Value,
            frame: frame,
            isOnScreen: onScreen,
            layer: layer
        )
    }
}

private struct StoredCaptureFrame {
    let image: CGImage
    let sequence: UInt64
    let presentationTime: TimeInterval
    let contentFingerprint: UInt64
    let consecutiveStableFrames: Int
}

private final class StreamFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])

    private weak var activeStream: SCStream?
    private var sequence: UInt64 = 0
    private var latest: StoredCaptureFrame?
    private var lastFingerprint: UInt64?
    private var stableFrameCount = 0
    private var latestStopMessage: String?

    var storedFrame: StoredCaptureFrame? {
        lock.withLock { latest }
    }

    var stopMessage: String? {
        lock.withLock { latestStopMessage }
    }

    func activate(_ stream: SCStream) {
        lock.withLock {
            activeStream = stream
            latestStopMessage = nil
        }
    }

    func deactivate(_ stream: SCStream) {
        lock.withLock {
            if activeStream === stream {
                activeStream = nil
            }
        }
    }

    func resetForNewStream() {
        lock.withLock {
            latest = nil
            lastFingerprint = nil
            stableFrameCount = 0
            latestStopMessage = nil
            // Keep `sequence` monotonic across relocks so old frame tokens can
            // never accidentally become current after a stream restart.
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              isActive(stream),
              sampleBuffer.isValid,
              sampleBuffer.dataReadiness == .ready,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = context.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }

        let fingerprint = Self.fingerprint(pixelBuffer)
        let timestamp = sampleBuffer.presentationTimeStamp.seconds
        let presentationTime = timestamp.isFinite ? timestamp : ProcessInfo.processInfo.systemUptime

        lock.withLock {
            guard activeStream === stream else { return }
            sequence &+= 1
            if lastFingerprint == fingerprint {
                stableFrameCount += 1
            } else {
                lastFingerprint = fingerprint
                stableFrameCount = 1
            }
            latest = StoredCaptureFrame(
                image: image,
                sequence: sequence,
                presentationTime: presentationTime,
                contentFingerprint: fingerprint,
                consecutiveStableFrames: stableFrameCount
            )
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock {
            guard activeStream === stream else { return }
            latestStopMessage = error.localizedDescription
            activeStream = nil
        }
    }

    private func isActive(_ stream: SCStream) -> Bool {
        lock.withLock { activeStream === stream }
    }

    /// Quantized sampling is intentionally cheap enough to run for every frame.
    /// It detects stale/changed frames but is not used as a chess-position hash.
    private static func fingerprint(_ pixelBuffer: CVPixelBuffer) -> UInt64 {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return 0
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return 0 }

        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let samplesAcross = min(width, 48)
        let samplesDown = min(height, 48)
        var hash: UInt64 = 14_695_981_039_346_656_037

        for row in 0..<samplesDown {
            let y = min((row * height + height / 2) / samplesDown, height - 1)
            for column in 0..<samplesAcross {
                let x = min((column * width + width / 2) / samplesAcross, width - 1)
                let offset = y * bytesPerRow + x * 4
                // Ignore alpha and remove the bottom three bits to tolerate tiny
                // compositor variations between visually identical frames.
                for channel in 0..<3 {
                    hash ^= UInt64(bytes[offset + channel] & 0xf8)
                    hash &*= 1_099_511_628_211
                }
            }
        }
        return hash
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
