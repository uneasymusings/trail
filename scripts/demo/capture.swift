// Records a region of the main display to a movie, without the mouse pointer.
//   swift scripts/demo/capture.swift <x> <y> <width> <height> <seconds> <out.mov>
// Coordinates are points from the top-left of the main display. Uses ScreenCaptureKit, so the
// terminal running it needs Screen Recording permission.
import AVFoundation
import Foundation
import ScreenCaptureKit

let args = CommandLine.arguments.dropFirst().map { $0 }
guard args.count == 6, let x = Double(args[0]), let y = Double(args[1]), let width = Double(args[2]),
      let height = Double(args[3]), let seconds = Double(args[4]) else {
    print("usage: capture.swift x y width height seconds out.mov")
    exit(2)
}
let output = URL(fileURLWithPath: args[5])
try? FileManager.default.removeItem(at: output)

final class Recorder: NSObject, SCRecordingOutputDelegate {
    let rect: CGRect
    let output: URL
    var stream: SCStream?
    let finished = DispatchSemaphore(value: 0)

    init(rect: CGRect, output: URL) {
        self.rect = rect
        self.output = output
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { CGDisplayIsMain($0.displayID) != 0 }) ?? content.displays.first else {
            throw NSError(domain: "capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        config.sourceRect = rect
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.capturesAudio = false

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = output
        recording.outputFileType = .mov
        let recordingOutput = SCRecordingOutput(configuration: recording, delegate: self)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addRecordingOutput(recordingOutput)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finished.signal() }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        print("capture failed: \(error.localizedDescription)")
        finished.signal()
    }
}

let recorder = Recorder(rect: CGRect(x: x, y: y, width: width, height: height), output: output)
Task {
    do {
        try await recorder.start()
        try await Task.sleep(for: .seconds(seconds))
        await recorder.stop()
    } catch {
        print("capture failed: \(error.localizedDescription)")
        exit(1)
    }
}
DispatchQueue.global().async {
    recorder.finished.wait()
    exit(0)
}
RunLoop.main.run()
