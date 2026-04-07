import AppKit
import QuartzCore

final class OverlayPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let waveformView = WaveformView()
    private var borderView: NSView!
    private var stackCenterYConstraint: NSLayoutConstraint?

    private let capsuleHeight: CGFloat = 56
    private let hPad: CGFloat = 24
    private let waveSize: CGFloat = 44
    private let gap: CGFloat = 14
    private let minWidth: CGFloat = 160
    private let maxWidth: CGFloat = 560

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        let cv = contentView!
        cv.wantsLayer = true

        // Shadow host
        let shadowHost = NSView(frame: cv.bounds)
        shadowHost.autoresizingMask = [.width, .height]
        shadowHost.wantsLayer = true
        shadowHost.layer?.shadowColor = NSColor.black.withAlphaComponent(0.45).cgColor
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -2)
        shadowHost.layer?.shadowRadius = 16
        shadowHost.layer?.shadowOpacity = 1
        cv.addSubview(shadowHost)

        // Vibrancy capsule
        let effect = NSVisualEffectView(frame: cv.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.appearance = NSAppearance(named: .darkAqua)
        shadowHost.addSubview(effect)

        // Subtle inner border for depth
        borderView = NSView(frame: cv.bounds)
        borderView.autoresizingMask = [.width, .height]
        borderView.wantsLayer = true
        borderView.layer?.cornerRadius = 16
        borderView.layer?.borderWidth = 0.5
        borderView.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        effect.addSubview(borderView)

        // Layout: waveform + label
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = gap
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        waveformView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(waveformView)

        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(label)

        NSLayoutConstraint.activate([
            waveformView.widthAnchor.constraint(equalToConstant: waveSize),
            waveformView.heightAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: hPad),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -hPad),
        ])
        
        stackCenterYConstraint = stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        stackCenterYConstraint?.isActive = true
    }

    // MARK: - Public

    func show(text: String = "Listening...") {
        label.stringValue = text
        waveformView.isAnimating = true
        resetBorder()

        // Reset stack position to center
        stackCenterYConstraint?.constant = 0

        let w = idealWidth(for: text)
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let x = area.midX - w / 2
        let y = area.minY + 56

        setFrame(NSRect(x: x, y: y - 14, width: w, height: capsuleHeight), display: true)
        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.175, 0.885, 0.32, 1.1)
            animator().alphaValue = 1
            animator().setFrame(
                NSRect(x: x, y: y, width: w, height: capsuleHeight), display: true)
        }
    }

    func updateText(_ text: String) {
        label.stringValue = text

        let w = idealWidth(for: text)
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let x = area.midX - w / 2
        let newFrame = NSRect(x: x, y: frame.origin.y, width: w, height: capsuleHeight)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
            ctx.allowsImplicitAnimation = true
            animator().setFrame(newFrame, display: true)
        }
    }

    func updateAudioLevel(_ level: Float) {
        waveformView.setLevel(CGFloat(level))
    }

    func showRefining() {
        waveformView.isAnimating = false
        updateText("Refining...")
    }

    /// Flash the border red to indicate LLM refinement failed
    func showError() {
        waveformView.isAnimating = false
        borderView.layer?.borderWidth = 2
        borderView.layer?.borderColor = NSColor.systemRed.cgColor
    }

    private func resetBorder() {
        borderView.layer?.borderWidth = 0.5
        borderView.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
    }

    func dismiss() {
        waveformView.isAnimating = false
        resetBorder()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
            animator().setFrame(
                NSRect(
                    x: frame.origin.x + frame.width * 0.02,
                    y: frame.origin.y - 8,
                    width: frame.width * 0.96,
                    height: capsuleHeight),
                display: true)
        }, completionHandler: {
            self.orderOut(nil)
        })
    }

    // MARK: - Sizing

    private func idealWidth(for text: String) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: label.font!]
        let textW = ceil((text as NSString).size(withAttributes: attrs).width)
        let total = hPad + waveSize + gap + textW + hPad
        return min(max(total, minWidth), maxWidth)
    }
}

// MARK: - Audio-driven waveform bars

private final class WaveformView: NSView {
    private let barCount = 5
    private var barLayers: [CALayer] = []
    var isAnimating = false

    private let barWeights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private var smoothedLevel: CGFloat = 0
    private let minBarFraction: CGFloat = 0.15

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    private func setupBars() {
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            bar.cornerRadius = 2.5
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    override func layout() {
        super.layout()
        applyBars(level: smoothedLevel)
    }

    func setLevel(_ level: CGFloat) {
        guard isAnimating else { return }
        let attack: CGFloat = 0.4
        let release: CGFloat = 0.15
        let factor = level > smoothedLevel ? attack : release
        smoothedLevel += (level - smoothedLevel) * factor

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        applyBars(level: smoothedLevel)
        CATransaction.commit()
    }

    private func applyBars(level: CGFloat) {
        let barWidth: CGFloat = 4.5
        let barGap: CGFloat = 3.5
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let startX = (bounds.width - totalWidth) / 2

        for (i, bar) in barLayers.enumerated() {
            let weight = barWeights[i]
            let fraction = minBarFraction + (1 - minBarFraction) * level * weight
            let jitter = CGFloat.random(in: -0.04...0.04)
            let h = bounds.height * min(max(fraction + jitter, minBarFraction), 1.0)
            let x = startX + CGFloat(i) * (barWidth + barGap)
            let y = (bounds.height - h) / 2
            bar.frame = CGRect(x: x, y: y, width: barWidth, height: h)
        }
    }
}
