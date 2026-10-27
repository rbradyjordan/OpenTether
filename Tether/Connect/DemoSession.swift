import SwiftUI
import UIKit
import TetherCore

/// A shoot without a camera, for trying the app (and for App Review, which
/// has no camera to plug in): frames "arrive" one by one as if someone were
/// shooting, so rating, looks, compare, client review and export all work.
enum DemoSession {
    static let name = "Demo shoot"
    /// Marks demo sessions (shown as #demo in the session list).
    static let tag = "demo"
    static let frameCount = 8

    /// `pace` is the gap between frames in seconds (0 drops them all at once).
    @MainActor static func start(_ app: AppModel, pace: Double = 1.6) async {
        guard app.shoot == nil else { app.showShoot(); return }
        let shoot = ShootSession(name: name, workflowTag: tag)
        // A listing shot list, with the first frames filed under the kitchen,
        // so the room bar and room naming can be tried without a camera.
        app.store.setRoomList(.listing, for: shoot.id)
        app.store.setSetting("rooms.current.\(shoot.id)", "kitchen")
        guard let connection = try? await ConnectionBuilder.startFTPSession(shoot: shoot, services: app.services) else {
            app.toast = ToastMessage(text: "Couldn't start the demo session.", systemImage: "exclamationmark.triangle")
            return
        }
        app.activate(connection)
        guard let vm = app.shoot else { return }
        for i in 0 ..< frameCount {
            if pace > 0, i > 0 { try? await Task.sleep(nanoseconds: UInt64(pace * 1_000_000_000)) }
            // Stop if the demo was ended or another session took over.
            guard app.shoot === vm else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(String(format: "DEMO_%04d.JPG", i + 1))
            try? frame(i).write(to: url)
            await vm.ingestFTPFile(url, from: "demo")
        }
    }

    /// A simple landscape: sky, sun and layered hills, a different time of
    /// day per frame, so looks and colour matching have something to show.
    static func frame(_ index: Int) -> Data {
        let size = CGSize(width: 2400, height: 1600)
        let t = CGFloat(index) / CGFloat(max(1, frameCount - 1))
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let top = UIColor(hue: 0.60 - 0.05 * t, saturation: 0.55, brightness: 0.95 - 0.35 * t, alpha: 1)
            let horizon = UIColor(hue: 0.08 - 0.03 * t, saturation: 0.35 + 0.45 * t, brightness: 1, alpha: 1)
            let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, horizon.cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height * 0.7), options: [.drawsAfterEndLocation])
            UIColor(hue: 0.11, saturation: 0.25 + 0.5 * t, brightness: 1, alpha: 0.95).setFill()
            let sunY = size.height * (0.25 + 0.3 * t)
            cg.fillEllipse(in: CGRect(x: size.width * (0.3 + 0.4 * t) - 110, y: sunY - 110, width: 220, height: 220))
            for layer in 0 ..< 3 {
                let base = size.height * (0.55 + 0.12 * CGFloat(layer))
                let shade = 0.45 - 0.13 * CGFloat(layer) - 0.15 * t
                UIColor(hue: 0.62 - 0.08 * CGFloat(layer), saturation: 0.35, brightness: max(0.08, shade), alpha: 1).setFill()
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: size.height))
                for x in stride(from: CGFloat(0), through: size.width, by: 40) {
                    let wave = sin((x / size.width) * .pi * CGFloat(2 + layer) + CGFloat(index + layer)) * 90
                        + sin((x / size.width) * .pi * 7 + CGFloat(layer)) * 25
                    path.addLine(to: CGPoint(x: x, y: base + wave))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.close()
                path.fill()
            }
        }
        return image.jpegData(compressionQuality: 0.88) ?? Data()
    }
}
