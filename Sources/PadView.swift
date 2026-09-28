import UIKit

/// Draws the maimai touch ring (34 sensors) over the game picture, plus Select/Test/Service/Coin/Card buttons,
/// and turns multi-touch into the sensor/button strings the PC bridge expects.
final class PadView: UIView {
    var onSensors: ((String) -> Void)?
    var onButtons: ((String) -> Void)?
    var onVideoToggle: ((Bool) -> Void)?
    var onVideoSettingsChanged: (() -> Void)?
    var onPickBackground: (() -> Void)?

    private let settings = Settings.shared
    private let click = ClickPlayer()

    // order matches the bridge: select, test, service, coin, card
    private let buttonTitles = ["SELECT", "TEST", "SERVICE", "COIN", "CARD"]

    private var sensorLayers: [CAShapeLayer] = []
    private var sensorPaths: [UIBezierPath] = []
    private var buttonFrames = [CGRect](repeating: .zero, count: 5)
    private var buttonViews: [UILabel] = []
    private let statusLabel = UILabel()
    private let backdrop = CAShapeLayer()

    private let videoLayer = CALayer()
    private let toggleLabel = UILabel()
    private let settingsLabel = UILabel()
    private var toggleFrame = CGRect.zero
    private var settingsFrame = CGRect.zero
    private var videoOn = true
    private var gotFrame = false
    private var pendingFrame: CGImage?
    private let frameLock = NSLock()
    private var frameScheduled = false
    private var panel: SettingsPanel?

    // portrait top-screen strip
    private let topLayer = CALayer()
    private var topFrame = CGRect.zero
    private var gotTopFrame = false
    private var pendingTop: CGImage?
    private let topLock = NSLock()
    private var topScheduled = false
    private var topStripAspect: CGFloat = 0.28   // height/width; starts as a guess, corrected once a real frame arrives

    // custom background
    private let backgroundLayer = CALayer()
    private var backgroundImage: UIImage?

    private var active = Set<UITouch>()
    private var sensorOn = [Bool](repeating: false, count: 34)
    private var buttonOn = [Bool](repeating: false, count: 5)
    private var lastS = ""
    private var lastB = ""
    private var connected = false
    private var lastStats = LinkStats()

    private let offColor = UIColor(red: 0.11, green: 0.13, blue: 0.21, alpha: 1)
    private let offOuter = UIColor(red: 0.13, green: 0.17, blue: 0.29, alpha: 1)
    private let onColor = UIColor(red: 1.0, green: 0.37, blue: 0.66, alpha: 1)
    private let onOuter = UIColor(red: 1.0, green: 0.69, blue: 0.23, alpha: 1)
    private let lineColor = UIColor(red: 0.23, green: 0.26, blue: 0.40, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1)
        isMultipleTouchEnabled = true
        isExclusiveTouch = true
        videoOn = settings.videoOn

        backgroundLayer.contentsGravity = .resizeAspectFill
        backgroundLayer.masksToBounds = true
        layer.addSublayer(backgroundLayer)

        backdrop.fillColor = UIColor(red: 0.06, green: 0.07, blue: 0.13, alpha: 1).cgColor
        backdrop.strokeColor = lineColor.cgColor
        backdrop.lineWidth = 2
        layer.addSublayer(backdrop)

        topLayer.contentsGravity = .resizeAspectFill
        topLayer.masksToBounds = true
        topLayer.isHidden = true
        layer.addSublayer(topLayer)

        videoLayer.contentsGravity = .resize
        videoLayer.masksToBounds = true
        videoLayer.isHidden = true
        layer.addSublayer(videoLayer)

        for i in 0..<34 {
            let sl = CAShapeLayer()
            sl.fillColor = fillColor(index: i, on: false).cgColor
            sl.strokeColor = lineColor.cgColor
            sl.lineWidth = 1.5
            sl.lineJoin = .round
            layer.addSublayer(sl)
            sensorLayers.append(sl)
        }

        for i in 0..<5 {
            let l = makeButtonLabel(buttonTitles[i])
            addSubview(l)
            buttonViews.append(l)
        }
        for l in [toggleLabel, settingsLabel] {
            styleButtonLabel(l)
            addSubview(l)
        }
        settingsLabel.text = "SETTINGS"
        updateToggleLabel()

        statusLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusLabel.numberOfLines = 0
        statusLabel.isUserInteractionEnabled = false
        addSubview(statusLabel)
        setConnected(false)
        loadBackgroundImage()   // safe now that sensorLayers (used by render(), inside this call) exists
    }

    private func makeButtonLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        styleButtonLabel(l)
        return l
    }

    private func styleButtonLabel(_ l: UILabel) {
        l.textAlignment = .center
        l.textColor = .white
        l.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        l.backgroundColor = UIColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 1)
        l.layer.cornerRadius = 10
        l.layer.borderWidth = 2
        l.layer.borderColor = UIColor(red: 0.2, green: 0.23, blue: 0.36, alpha: 1).cgColor
        l.clipsToBounds = true
        l.isUserInteractionEnabled = false
    }

    // MARK: status / info

    func setConnected(_ c: Bool) {
        connected = c
        if !c {
            if gotFrame {
                gotFrame = false
                videoLayer.isHidden = true
                render()
            }
            if gotTopFrame {
                gotTopFrame = false
                topLayer.isHidden = true
                setNeedsLayout()
            }
        }
        updateStatusText()
    }

    func showStats(_ s: LinkStats) {
        lastStats = s
        updateStatusText()
    }

    // MARK: background photo

    private func loadBackgroundImage() {
        backgroundImage = settings.customBackgroundOn ? UIImage(contentsOfFile: Settings.backgroundURL.path) : nil
        backgroundLayer.contents = backgroundImage?.cgImage
        render()
    }

    /// Called after the user picks (or removes) a photo in Settings, or toggles the feature.
    func backgroundSettingChanged() {
        loadBackgroundImage()
        applySettingsLayout()
        panel?.updateBackgroundStatus()
    }

    // MARK: top-screen strip (portrait)

    /// Called from a background queue with each decoded top-strip frame; only the newest one is drawn.
    func showTopFrame(_ img: CGImage) {
        topLock.lock()
        pendingTop = img
        let schedule = !topScheduled
        topScheduled = true
        topLock.unlock()
        if !schedule { return }
        DispatchQueue.main.async {
            self.topLock.lock()
            let f = self.pendingTop
            self.pendingTop = nil
            self.topScheduled = false
            self.topLock.unlock()
            guard let frame = f else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.topLayer.contents = frame
            self.topLayer.isHidden = false
            CATransaction.commit()
            let aspect = frame.width > 0 ? CGFloat(frame.height) / CGFloat(frame.width) : self.topStripAspect
            if !self.gotTopFrame || abs(aspect - self.topStripAspect) > 0.02 {
                self.gotTopFrame = true
                self.topStripAspect = aspect
                self.setNeedsLayout()
            }
        }
    }

    private func applySettingsLayout() {
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func updateStatusText() {
        var text = connected ? "PC connected" : "Waiting for PC (USB)"
        statusLabel.textColor = connected ? UIColor(red: 0.36, green: 0.88, blue: 0.54, alpha: 1) : UIColor(red: 1, green: 0.42, blue: 0.42, alpha: 1)
        if settings.showReadout && connected {
            let s = lastStats
            let refreshMs = 1000.0 / Double(max(UIScreen.main.maximumFramesPerSecond, 1))
            let estimate = s.pcMs + s.rttMs / 2 + s.decodeMs + refreshMs / 2
            text += String(format: "\nvideo %ld fps  %ld KB/frame  dropped %ld", s.fps, s.frameKB, s.dropped)
            text += String(format: "\nUSB round trip %.1f ms", s.rttMs)
            text += String(format: "\nPC capture+encode %.1f ms  decode %.1f ms", s.pcMs, s.decodeMs)
            if videoOn && s.fps > 0 {
                text += String(format: "\nvideo delay ~%.0f ms (estimate)", estimate)
            }
        }
        statusLabel.text = text
        setNeedsLayout()
    }

    // MARK: video

    private func updateToggleLabel() {
        toggleLabel.text = videoOn ? "VIDEO ON" : "VIDEO OFF"
        toggleLabel.textColor = videoOn ? UIColor(red: 0.02, green: 0.13, blue: 0.17, alpha: 1) : .white
        toggleLabel.backgroundColor = videoOn ? UIColor(red: 0.3, green: 0.88, blue: 1.0, alpha: 1) : UIColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 1)
    }

    /// Called from a background queue with each decoded game frame; only the newest one is drawn.
    func showFrame(_ img: CGImage) {
        frameLock.lock()
        pendingFrame = img
        let schedule = !frameScheduled
        frameScheduled = true
        frameLock.unlock()
        if !schedule { return }
        DispatchQueue.main.async {
            self.frameLock.lock()
            let f = self.pendingFrame
            self.pendingFrame = nil
            self.frameScheduled = false
            self.frameLock.unlock()
            guard let frame = f, self.videoOn else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.videoLayer.contents = frame
            self.videoLayer.isHidden = false
            CATransaction.commit()
            if !self.gotFrame {
                self.gotFrame = true
                self.render()
            }
        }
    }

    private func setVideoOn(_ on: Bool) {
        videoOn = on
        settings.videoOn = on
        if !on {
            gotFrame = false
            videoLayer.isHidden = true
            videoLayer.contents = nil
            gotTopFrame = false
            topLayer.isHidden = true
            topLayer.contents = nil
        }
        updateToggleLabel()
        render()
        updateStatusText()
        setNeedsLayout()
        onVideoToggle?(on)
    }

    // MARK: colours

    // The ring becomes a see-through overlay whenever there is a picture behind it to show: the live game video,
    // or (with video off) a chosen background photo.
    private var overlay: Bool { return (videoOn && gotFrame) || (settings.customBackgroundOn && backgroundImage != nil) }

    private func fillColor(index: Int, on: Bool) -> UIColor {
        let outer = index < 8
        let glow = CGFloat(settings.glowOpacity)
        if on { return (outer ? onOuter : onColor).withAlphaComponent(overlay ? glow : 1) }
        if overlay { return UIColor.clear }
        return outer ? offOuter : offColor
    }

    private func render() {
        let stroke = lineColor.withAlphaComponent(overlay ? CGFloat(settings.outlineOpacity) : 1).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.fillColor = overlay ? UIColor.clear.cgColor : UIColor(red: 0.06, green: 0.07, blue: 0.13, alpha: 1).cgColor
        for i in 0..<34 {
            sensorLayers[i].fillColor = fillColor(index: i, on: sensorOn[i]).cgColor
            sensorLayers[i].strokeColor = stroke
        }
        CATransaction.commit()
        for i in 0..<5 {
            let on = buttonOn[i]
            buttonViews[i].backgroundColor = on ? UIColor(red: 0.3, green: 0.88, blue: 1.0, alpha: 1) : UIColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 1)
            buttonViews[i].textColor = on ? UIColor(red: 0.02, green: 0.13, blue: 0.17, alpha: 1) : .white
        }
    }

    // MARK: settings

    private func openSettings() {
        panel?.removeFromSuperview()
        active.removeAll()
        recompute()
        let p = SettingsPanel(frame: bounds)
        p.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        p.onClose = { [weak self] in
            self?.panel?.removeFromSuperview()
            self?.panel = nil
        }
        p.onChanged = { [weak self] in self?.applySettings() }
        p.onVideoParamsCommitted = { [weak self] in self?.onVideoSettingsChanged?() }
        p.onVideoSwitch = { [weak self] on in self?.setVideoOn(on) }
        p.onTopStripSwitch = { [weak self] _ in self?.applySettingsLayout(); self?.onVideoSettingsChanged?() }
        p.onBackgroundSwitch = { [weak self] _ in self?.backgroundSettingChanged() }
        p.onPickBackground = { [weak self] in self?.onPickBackground?() }
        p.onRemoveBackground = { [weak self] in
            try? FileManager.default.removeItem(at: Settings.backgroundURL)
            self?.backgroundSettingChanged()
        }
        p.onReset = { [weak self] in
            Settings.shared.reset()
            self?.videoOn = Settings.shared.videoOn
            self?.updateToggleLabel()
            self?.loadBackgroundImage()
            self?.applySettings()
            self?.onVideoSettingsChanged?()
            self?.onVideoToggle?(Settings.shared.videoOn)
            self?.openSettings()
        }
        addSubview(p)
        panel = p
    }

    private func applySettings() {
        setNeedsLayout()
        layoutIfNeeded()
        render()
        updateStatusText()
    }

    // MARK: layout

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        CATransaction.commit()

        let safe = bounds.inset(by: safeAreaInsets)
        let portrait = safe.height > safe.width
        let showStrip = portrait && videoOn && settings.topStripOn

        // In portrait with the top strip on, it takes a slice off the top and the ring is centred in what's left;
        // otherwise the ring/picture is as large as fits, centred, with small buttons in the corners.
        var ring: CGRect
        if showStrip {
            let maxRingW = safe.width - 8
            let stripH = maxRingW * topStripAspect
            let available = safe.height - stripH - 16
            let size = min(maxRingW, available) * CGFloat(settings.ringScale)
            let top = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: stripH)
            topFrame = top
            ring = CGRect(x: safe.midX - size / 2, y: top.maxY + 12, width: size, height: size)
        } else {
            let size = (min(safe.width, safe.height) - 8) * CGFloat(settings.ringScale)
            ring = CGRect(x: safe.midX - size / 2, y: safe.midY - size / 2, width: size, height: size)
            topFrame = .zero
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        topLayer.isHidden = !showStrip || !gotTopFrame
        topLayer.frame = topFrame
        CATransaction.commit()
        layoutButtons(in: safe)

        let s = ring.width / 1440
        sensorPaths.removeAll()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.path = UIBezierPath(ovalIn: ring).cgPath
        videoLayer.frame = ring
        videoLayer.cornerRadius = ring.width / 2
        for i in 0..<34 {
            let raw = sensorRaw[i]
            let path = UIBezierPath()
            var k = 0
            while k + 1 < raw.count {
                let p = CGPoint(x: ring.minX + CGFloat(raw[k]) * s, y: ring.minY + CGFloat(raw[k + 1]) * s)
                if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
                k += 2
            }
            path.close()
            sensorPaths.append(path)
            sensorLayers[i].path = path.cgPath
        }
        CATransaction.commit()

        let maxW = max(safe.width - 20, 100)
        let fit = statusLabel.sizeThatFits(CGSize(width: maxW, height: CGFloat.greatestFiniteMagnitude))
        statusLabel.frame = CGRect(x: safe.minX + 10, y: safe.maxY - fit.height - 4, width: fit.width, height: fit.height)
    }

    private func layoutButtons(in safe: CGRect) {
        let w: CGFloat = 96, h: CGFloat = 42, gap: CGFloat = 8, margin: CGFloat = 10
        var left = [0, 3, 4]     // select, coin, card
        var right = [1, 2]       // test, service (+ video toggle and settings below them)
        if settings.leftHanded { swap(&left, &right) }
        let leftX = safe.minX + margin
        let rightX = safe.maxX - margin - w
        func place(_ list: [Int], x: CGFloat) -> Int {
            for (slot, idx) in list.enumerated() {
                let f = CGRect(x: x, y: safe.minY + margin + CGFloat(slot) * (h + gap), width: w, height: h)
                buttonFrames[idx] = f
                buttonViews[idx].frame = f
            }
            return list.count
        }
        let nLeft = place(left, x: leftX)
        let nRight = place(right, x: rightX)
        // the two extra buttons go in whichever column has fewer buttons, below its last one
        let extraX = nRight <= nLeft ? rightX : leftX
        let extraStart = min(nRight, nLeft)
        toggleLabel.frame = CGRect(x: extraX, y: safe.minY + margin + CGFloat(extraStart) * (h + gap), width: w, height: h)
        settingsLabel.frame = CGRect(x: extraX, y: safe.minY + margin + CGFloat(extraStart + 1) * (h + gap), width: w, height: h)
        toggleFrame = toggleLabel.frame.insetBy(dx: -4, dy: -4)
        settingsFrame = settingsLabel.frame.insetBy(dx: -4, dy: -4)
    }

    // MARK: touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            if toggleFrame.contains(p) {
                setVideoOn(!videoOn)
            } else if settingsFrame.contains(p) {
                openSettings()
                return
            } else {
                active.insert(t)
            }
        }
        recompute()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        recompute()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { active.remove(t) }
        recompute()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { active.remove(t) }
        recompute()
    }

    private func sensorIndex(at p: CGPoint) -> Int? {
        for i in 0..<sensorPaths.count where sensorPaths[i].contains(p) {
            return i
        }
        return nil
    }

    /// One finger -> sensors. With sensitivity 0 only the touch point counts; above that the finger is treated as a disc,
    /// so it can cover several inner sensors, but never more than one of the eight ring-button sensors.
    private func markSensors(at p: CGPoint, sensitivity: CGFloat, into s: inout [Bool]) {
        if sensitivity <= 0.01 {
            if let i = sensorIndex(at: p) { s[i] = true }
            return
        }
        let r = sensitivity * 28
        var counts = [Int](repeating: 0, count: 34)
        if let i = sensorIndex(at: p) { counts[i] += 2 }
        for k in 0..<8 {
            let a = CGFloat(k) * CGFloat.pi / 4
            let q = CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r)
            if let i = sensorIndex(at: q) { counts[i] += 1 }
        }
        var best = -1
        var bestCount = 0
        for i in 0..<8 where counts[i] > bestCount {
            best = i
            bestCount = counts[i]
        }
        if best >= 0 { s[best] = true }
        for i in 8..<34 where counts[i] > 0 { s[i] = true }
    }

    private func recompute() {
        var s = [Bool](repeating: false, count: 34)
        var b = [Bool](repeating: false, count: 5)
        let sensitivity = CGFloat(settings.touchSensitivity)
        for t in active {
            let p = t.location(in: self)
            var hitButton = false
            for i in 0..<5 where buttonFrames[i].insetBy(dx: -4, dy: -4).contains(p) {
                b[i] = true
                hitButton = true
            }
            if hitButton { continue }
            markSensors(at: p, sensitivity: sensitivity, into: &s)
        }

        if settings.soundOn {
            var pressed = false
            for i in 0..<8 where s[i] && !sensorOn[i] { pressed = true }
            for i in 0..<5 where b[i] && !buttonOn[i] { pressed = true }
            if pressed { click.click(volume: Float(settings.soundVolume)) }
        }

        sensorOn = s
        buttonOn = b
        render()

        let ss = s.map { $0 ? "1" : "0" }.joined()
        if ss != lastS {
            lastS = ss
            onSensors?(ss)
        }
        let bb = b.map { $0 ? "1" : "0" }.joined()
        if bb != lastB {
            lastB = bb
            onButtons?(bb)
        }
    }
}
