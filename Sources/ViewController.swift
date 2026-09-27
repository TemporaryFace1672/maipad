import UIKit

final class ViewController: UIViewController {
    private let pad = PadView(frame: .zero)
    private let server = PadServer()

    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { return .all }

    override func loadView() {
        view = pad
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        pad.onSensors = { [weak self] s in self?.server.setSensors(s) }
        pad.onButtons = { [weak self] s in self?.server.setButtons(s) }
        pad.onVideoToggle = { [weak self] on in self?.server.setVideo(on) }
        pad.onVideoSettingsChanged = { [weak self] in self?.server.videoSettingsChanged() }
        server.onFrame = { [weak self] img in self?.pad.showFrame(img) }
        server.onStatus = { [weak self] connected in self?.pad.setConnected(connected) }
        server.onStats = { [weak self] stats in self?.pad.showStats(stats) }
        server.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
}
