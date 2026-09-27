import AppKit
import AVFoundation
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let icons = root.appendingPathComponent("WakEAS/Assets.xcassets/AppIcon.appiconset")

for size in [16, 32, 64, 128, 256, 512, 1024] {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot draw icon") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let edge = CGFloat(size)
    NSColor(calibratedRed: 0.075, green: 0.065, blue: 0.09, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: edge, height: edge)).fill()
    let background = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: edge, height: edge),
                                  xRadius: edge * 0.22, yRadius: edge * 0.22)
    NSColor(calibratedRed: 0.075, green: 0.065, blue: 0.09, alpha: 1).setFill()
    background.fill()

    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: edge * 0.5, y: edge * 0.82))
    triangle.line(to: NSPoint(x: edge * 0.86, y: edge * 0.19))
    triangle.line(to: NSPoint(x: edge * 0.14, y: edge * 0.19))
    triangle.close()
    triangle.lineJoinStyle = .round
    triangle.lineWidth = edge * 0.055
    NSColor(calibratedRed: 1, green: 0.82, blue: 0.05, alpha: 1).set()
    triangle.fill()
    triangle.stroke()

    NSColor(calibratedRed: 0.08, green: 0.06, blue: 0.08, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: edge * 0.465, y: edge * 0.37,
                                     width: edge * 0.07, height: edge * 0.25),
                 xRadius: edge * 0.035, yRadius: edge * 0.035).fill()
    NSBezierPath(ovalIn: NSRect(x: edge * 0.465, y: edge * 0.28,
                                width: edge * 0.07, height: edge * 0.07)).fill()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot export icon") }
    try png.write(to: icons.appendingPathComponent("icon-\(size).png"))
}

let rate = 44_100.0
let seconds = 4.0
let count = Int(rate * seconds)
guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
      let channels = buffer.floatChannelData else { fatalError("Cannot create alert sound") }
buffer.frameLength = AVAudioFrameCount(count)
for i in 0..<count {
    let time = Double(i) / rate
    let envelope = min(1, min(time, seconds - time) / 0.02)
    let sample = Float((sin(2 * .pi * 853 * time) + sin(2 * .pi * 960 * time)) * 0.25 * envelope)
    for channel in 0..<Int(format.channelCount) { channels[channel][i] = sample }
}
let soundURL = root.appendingPathComponent("WakEAS/AlertNotification.caf")
let file = try AVAudioFile(forWriting: soundURL, settings: format.settings,
                           commonFormat: .pcmFormatFloat32, interleaved: false)
try file.write(from: buffer)
