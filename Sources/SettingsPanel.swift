import UIKit

final class ClosureSlider: UISlider {
    var onChange: ((Float) -> Void)?
    var onCommit: (() -> Void)?
    @objc func changed() { onChange?(value) }
    @objc func committed() { onCommit?() }
}

final class ClosureSwitch: UISwitch {
    var onToggle: ((Bool) -> Void)?
    @objc func toggled() { onToggle?(isOn) }
}

final class ClosureButton: UIButton {
    var onTap: (() -> Void)?
    @objc func tapped() { onTap?() }
}

/// Full-screen settings menu shown on top of the pad. It swallows all touches so nothing leaks through to the sensors.
final class SettingsPanel: UIView {
    var onClose: (() -> Void)?
    var onChanged: (() -> Void)?                 // a setting changed, apply it now
    var onVideoParamsCommitted: (() -> Void)?    // video size / quality / top-strip-width slider released
    var onVideoSwitch: ((Bool) -> Void)?
    var onTopStripSwitch: ((Bool) -> Void)?
    var onBackgroundSwitch: ((Bool) -> Void)?
    var onPickBackground: (() -> Void)?
    var onRemoveBackground: (() -> Void)?
    var onReset: (() -> Void)?

    private let backgroundStatusLabel = UILabel()

    private let s = Settings.shared
    private let card = UIView()
    private let titleLabel = UILabel()
    private let closeButton = ClosureButton(type: .system)
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    private let textColor = UIColor.white
    private let dimColor = UIColor(red: 0.62, green: 0.66, blue: 0.80, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    // swallow touches
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

    private func build() {
        backgroundColor = UIColor.black.withAlphaComponent(0.65)
        isMultipleTouchEnabled = true

        card.backgroundColor = UIColor(red: 0.09, green: 0.11, blue: 0.17, alpha: 1)
        card.layer.cornerRadius = 18
        card.layer.borderWidth = 2
        card.layer.borderColor = UIColor(red: 0.2, green: 0.23, blue: 0.36, alpha: 1).cgColor
        card.clipsToBounds = true
        addSubview(card)

        titleLabel.text = "Settings"
        titleLabel.textColor = textColor
        titleLabel.font = UIFont.systemFont(ofSize: 22, weight: .bold)
        card.addSubview(titleLabel)

        closeButton.setTitle("Close", for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        closeButton.addTarget(closeButton, action: #selector(ClosureButton.tapped), for: .touchUpInside)
        closeButton.onTap = { [weak self] in self?.onClose?() }
        card.addSubview(closeButton)

        card.addSubview(scroll)
        scroll.alwaysBounceVertical = true
        scroll.delaysContentTouches = false
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -40)
        ])

        buildRows()
    }

    private func buildRows() {
        section("Video")
        switchRow("Show game picture", s.videoOn) { [weak self] on in self?.onVideoSwitch?(on) }
        sliderRow("Picture size", min: 480, max: 1080, step: 40, value: Float(s.videoSize),
                  format: { "\(Int($0)) px" }, commitsVideo: true) { [weak self] v in self?.s.videoSize = Int(v) }
        sliderRow("Picture quality", min: 40, max: 90, step: 5, value: Float(s.videoQuality),
                  format: { "\(Int($0))" }, commitsVideo: true) { [weak self] v in self?.s.videoQuality = Int(v) }

        section("Overlay")
        sliderRow("Sensor outline opacity", min: 0, max: 1, step: 0.05, value: Float(s.outlineOpacity),
                  format: { "\(Int(($0 * 100).rounded()))%" }, commitsVideo: false) { [weak self] v in self?.s.outlineOpacity = Double(v); self?.onChanged?() }
        sliderRow("Touch glow opacity", min: 0, max: 1, step: 0.05, value: Float(s.glowOpacity),
                  format: { "\(Int(($0 * 100).rounded()))%" }, commitsVideo: false) { [weak self] v in self?.s.glowOpacity = Double(v); self?.onChanged?() }
        sliderRow("Ring size", min: 0.6, max: 1, step: 0.02, value: Float(s.ringScale),
                  format: { "\(Int(($0 * 100).rounded()))%" }, commitsVideo: false) { [weak self] v in self?.s.ringScale = Double(v); self?.onChanged?() }
        switchRow("Left-handed button layout", s.leftHanded) { [weak self] on in self?.s.leftHanded = on; self?.onChanged?() }

        section("Touch")
        sliderRow("Touch sensitivity (finger size)", min: 0, max: 1, step: 0.05, value: Float(s.touchSensitivity),
                  format: { "\(Int(($0 * 100).rounded()))%" }, commitsVideo: false) { [weak self] v in self?.s.touchSensitivity = Double(v); self?.onChanged?() }

        section("Sound")
        switchRow("Tap sound on this iPad", s.soundOn) { [weak self] on in self?.s.soundOn = on; self?.onChanged?() }
        sliderRow("Tap sound volume", min: 0, max: 1, step: 0.05, value: Float(s.soundVolume),
                  format: { "\(Int(($0 * 100).rounded()))%" }, commitsVideo: false) { [weak self] v in self?.s.soundVolume = Double(v); self?.onChanged?() }

        section("Portrait top screen")
        switchRow("Show top screen strip (portrait only)", s.topStripOn) { [weak self] on in
            self?.s.topStripOn = on
            self?.onChanged?()
            self?.onTopStripSwitch?(on)
        }
        sliderRow("Top strip width", min: 400, max: 1080, step: 40, value: Float(s.topStripWidth),
                  format: { "\(Int($0)) px" }, commitsVideo: true) { [weak self] v in self?.s.topStripWidth = Int(v) }

        section("Background")
        switchRow("Custom background photo", s.customBackgroundOn) { [weak self] on in
            self?.s.customBackgroundOn = on
            self?.onChanged?()
            self?.onBackgroundSwitch?(on)
        }
        backgroundStatusLabel.textColor = dimColor
        backgroundStatusLabel.font = UIFont.systemFont(ofSize: 14)
        updateBackgroundStatus()
        stack.addArrangedSubview(backgroundStatusLabel)

        let choose = ClosureButton(type: .system)
        choose.setTitle("Choose photo\u{2026}", for: .normal)
        choose.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        choose.addTarget(choose, action: #selector(ClosureButton.tapped), for: .touchUpInside)
        choose.onTap = { [weak self] in self?.onPickBackground?() }
        choose.heightAnchor.constraint(equalToConstant: 40).isActive = true
        stack.addArrangedSubview(choose)

        let remove = ClosureButton(type: .system)
        remove.setTitle("Remove photo", for: .normal)
        remove.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        remove.setTitleColor(dimColor, for: .normal)
        remove.addTarget(remove, action: #selector(ClosureButton.tapped), for: .touchUpInside)
        remove.onTap = { [weak self] in self?.onRemoveBackground?(); self?.updateBackgroundStatus() }
        remove.heightAnchor.constraint(equalToConstant: 32).isActive = true
        stack.addArrangedSubview(remove)

        section("Info")
        switchRow("Show latency / connection readout", s.showReadout) { [weak self] on in self?.s.showReadout = on; self?.onChanged?() }

        let reset = ClosureButton(type: .system)
        reset.setTitle("Reset all settings", for: .normal)
        reset.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        reset.setTitleColor(UIColor(red: 1, green: 0.42, blue: 0.42, alpha: 1), for: .normal)
        reset.addTarget(reset, action: #selector(ClosureButton.tapped), for: .touchUpInside)
        reset.onTap = { [weak self] in self?.onReset?() }
        reset.heightAnchor.constraint(equalToConstant: 44).isActive = true
        stack.addArrangedSubview(reset)
    }

    func updateBackgroundStatus() {
        backgroundStatusLabel.text = s.hasBackgroundFile ? "Photo set" : "No photo chosen yet"
    }

    private func section(_ text: String) {
        let l = UILabel()
        l.text = text.uppercased()
        l.textColor = dimColor
        l.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        stack.addArrangedSubview(l)
    }

    private func switchRow(_ title: String, _ value: Bool, _ apply: @escaping (Bool) -> Void) {
        let l = UILabel()
        l.text = title
        l.textColor = textColor
        l.font = UIFont.systemFont(ofSize: 17)
        l.numberOfLines = 0
        let sw = ClosureSwitch()
        sw.isOn = value
        sw.onToggle = apply
        sw.addTarget(sw, action: #selector(ClosureSwitch.toggled), for: .valueChanged)
        sw.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [l, sw])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        stack.addArrangedSubview(row)
    }

    private func sliderRow(_ title: String, min lo: Float, max hi: Float, step: Float, value: Float,
                           format: @escaping (Float) -> String, commitsVideo: Bool, apply: @escaping (Float) -> Void) {
        let l = UILabel()
        l.text = title
        l.textColor = textColor
        l.font = UIFont.systemFont(ofSize: 17)
        let v = UILabel()
        v.text = format(value)
        v.textColor = dimColor
        v.font = UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        v.textAlignment = .right
        v.setContentHuggingPriority(.required, for: .horizontal)
        let top = UIStackView(arrangedSubviews: [l, v])
        top.axis = .horizontal

        let sl = ClosureSlider()
        sl.minimumValue = lo
        sl.maximumValue = hi
        sl.value = value
        sl.onChange = { [weak sl] raw in
            let snapped = (raw / step).rounded() * step
            sl?.value = snapped
            v.text = format(snapped)
            apply(snapped)
        }
        if commitsVideo {
            sl.onCommit = { [weak self] in self?.onVideoParamsCommitted?() }
            sl.addTarget(sl, action: #selector(ClosureSlider.committed), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        sl.addTarget(sl, action: #selector(ClosureSlider.changed), for: .valueChanged)

        let block = UIStackView(arrangedSubviews: [top, sl])
        block.axis = .vertical
        block.spacing = 6
        stack.addArrangedSubview(block)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = min(bounds.width - 32, 560)
        let h = min(bounds.height - 32, 780)
        card.frame = CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        titleLabel.frame = CGRect(x: 20, y: 12, width: w - 140, height: 36)
        closeButton.frame = CGRect(x: w - 100, y: 10, width: 84, height: 40)
        scroll.frame = CGRect(x: 0, y: 58, width: w, height: h - 58)
    }
}
