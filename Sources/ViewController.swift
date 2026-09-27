import UIKit
import PhotosUI

final class ViewController: UIViewController, PHPickerViewControllerDelegate {
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
        pad.onPickBackground = { [weak self] in self?.presentPhotoPicker() }
        server.onFrame = { [weak self] img in self?.pad.showFrame(img) }
        server.onTopFrame = { [weak self] img in self?.pad.showTopFrame(img) }
        server.onStatus = { [weak self] connected in self?.pad.setConnected(connected) }
        server.onStats = { [weak self] stats in self?.pad.showStats(stats) }
        server.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    private func presentPhotoPicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage, let data = image.jpegData(compressionQuality: 0.85) else { return }
            try? data.write(to: Settings.backgroundURL, options: .atomic)
            DispatchQueue.main.async {
                self?.pad.backgroundSettingChanged()   // updates the status label; turn the switch on to show it
            }
        }
    }
}
