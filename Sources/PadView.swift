import UIKit

/// Draws the maimai touch ring (34 sensors) plus Select/Test/Service/Coin/Card buttons and turns
/// multi-touch into the sensor/button strings the PC bridge expects.
final class PadView: UIView {
    var onSensors: ((String) -> Void)?
    var onButtons: ((String) -> Void)?

    // order matches the bridge: select, test, service, coin, card
    private let buttonTitles = ["SELECT", "TEST", "SERVICE", "COIN", "CARD"]
    private let buttonOrderOnScreen = [0, 3, 4, 1, 2]

    private var sensorLayers: [CAShapeLayer] = []
    private var sensorPaths: [UIBezierPath] = []
    private var buttonFrames = [CGRect](repeating: .zero, count: 5)
    private var buttonViews: [UILabel] = []
    private let statusLabel = UILabel()
    private let backdrop = CAShapeLayer()

    private var active = Set<UITouch>()
    private var sensorOn = [Bool](repeating: false, count: 34)
    private var buttonOn = [Bool](repeating: false, count: 5)
    private var lastS = ""
    private var lastB = ""
    private var connected = false

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

        backdrop.fillColor = UIColor(red: 0.06, green: 0.07, blue: 0.13, alpha: 1).cgColor
        backdrop.strokeColor = lineColor.cgColor
        backdrop.lineWidth = 2
        layer.addSublayer(backdrop)

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
            let l = UILabel()
            l.text = buttonTitles[i]
            l.textAlignment = .center
            l.textColor = .white
            l.font = UIFont.systemFont(ofSize: 20, weight: .semibold)
            l.backgroundColor = UIColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 1)
            l.layer.cornerRadius = 14
            l.layer.borderWidth = 2
            l.layer.borderColor = UIColor(red: 0.2, green: 0.23, blue: 0.36, alpha: 1).cgColor
            l.clipsToBounds = true
            l.isUserInteractionEnabled = false
            addSubview(l)
            buttonViews.append(l)
        }

        statusLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.isUserInteractionEnabled = false
        addSubview(statusLabel)
        setConnected(false)
    }

    func setConnected(_ c: Bool) {
        connected = c
        statusLabel.text = c ? "PC connected" : "Waiting for PC (USB)"
        statusLabel.textColor = c ? UIColor(red: 0.36, green: 0.88, blue: 0.54, alpha: 1) : UIColor(red: 1, green: 0.42, blue: 0.42, alpha: 1)
    }

    private func fillColor(index: Int, on: Bool) -> UIColor {
        let outer = index < 8
        if on { return outer ? onOuter : onColor }
        return outer ? offOuter : offColor
    }

    // MARK: layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = bounds.inset(by: safeAreaInsets)
        let gap: CGFloat = 12
        var ring = CGRect.zero
        var btnArea = CGRect.zero

        if safe.width >= safe.height {
            let size = min(safe.height - gap, safe.width * 0.68)
            ring = CGRect(x: safe.minX + gap / 2, y: safe.midY - size / 2, width: size, height: size)
            let bx = ring.maxX + gap
            btnArea = CGRect(x: bx, y: safe.minY + gap, width: max(safe.maxX - bx - gap / 2, 60), height: safe.height - gap * 2)
            layoutButtons(in: btnArea, vertical: true)
        } else {
            let size = min(safe.width - gap, safe.height * 0.72)
            ring = CGRect(x: safe.midX - size / 2, y: safe.minY + gap / 2, width: size, height: size)
            let by = ring.maxY + gap
            btnArea = CGRect(x: safe.minX + gap, y: by, width: safe.width - gap * 2, height: max(safe.maxY - by - gap / 2, 60))
            layoutButtons(in: btnArea, vertical: false)
        }

        let s = ring.width / 1440
        sensorPaths.removeAll()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.path = UIBezierPath(ovalIn: ring).cgPath
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

        statusLabel.sizeToFit()
        statusLabel.frame.origin = CGPoint(x: safe.minX + 10, y: safe.minY + 4)
    }

    private func layoutButtons(in area: CGRect, vertical: Bool) {
        let gap: CGFloat = 10
        let n = CGFloat(buttonOrderOnScreen.count)
        for (slot, idx) in buttonOrderOnScreen.enumerated() {
            let f: CGRect
            let sl = CGFloat(slot)
            if vertical {
                let h = (area.height - gap * (n - 1)) / n
                f = CGRect(x: area.minX, y: area.minY + sl * (h + gap), width: area.width, height: h)
            } else {
                let w = (area.width - gap * (n - 1)) / n
                f = CGRect(x: area.minX + sl * (w + gap), y: area.minY, width: w, height: min(area.height, 110))
            }
            buttonFrames[idx] = f
            buttonViews[idx].frame = f
        }
    }

    // MARK: touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { active.insert(t) }
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

    private func recompute() {
        var s = [Bool](repeating: false, count: 34)
        var b = [Bool](repeating: false, count: 5)
        for t in active {
            let p = t.location(in: self)
            var hitButton = false
            for i in 0..<5 where buttonFrames[i].insetBy(dx: -4, dy: -4).contains(p) {
                b[i] = true
                hitButton = true
            }
            if hitButton { continue }
            for i in 0..<sensorPaths.count where sensorPaths[i].contains(p) {
                s[i] = true
                break
            }
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

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<34 {
            sensorLayers[i].fillColor = fillColor(index: i, on: sensorOn[i]).cgColor
        }
        CATransaction.commit()
        for i in 0..<5 {
            let on = buttonOn[i]
            buttonViews[i].backgroundColor = on ? UIColor(red: 0.3, green: 0.88, blue: 1.0, alpha: 1) : UIColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 1)
            buttonViews[i].textColor = on ? UIColor(red: 0.02, green: 0.13, blue: 0.17, alpha: 1) : .white
        }
    }
}
