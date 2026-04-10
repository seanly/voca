import AppKit
import QuartzCore

/// Minimal floating overlay card for voice input feedback.
/// Light card style: status label → text → auto-inject on completion.
final class OverlayPanel: NSPanel {
    // MARK: - UI Elements
    private let waveformView = WaveformView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let textLabel = NSTextField(labelWithString: "")
    private let spinnerView = NSProgressIndicator()

    // Callback: auto-inject text when done
    var onAutoInject: ((String) -> Void)?

    // MARK: - State
    private var currentText = ""
    private var autoInjectTimer: Timer?
    private var isDragging = false
    private var dragOffset = CGPoint.zero

    // MARK: - Layout
    private let panelWidth: CGFloat = 380
    private let hPad: CGFloat = 18
    private let vPad: CGFloat = 14
    private let cornerRadius: CGFloat = 14

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Init

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 72),
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

        setupViews()
    }

    private func setupViews() {
        let cv = contentView!
        cv.wantsLayer = true

        // Shadow host
        let shadowHost = NSView(frame: cv.bounds)
        shadowHost.autoresizingMask = [.width, .height]
        shadowHost.wantsLayer = true
        shadowHost.layer?.shadowColor = NSColor.black.withAlphaComponent(0.12).cgColor
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -3)
        shadowHost.layer?.shadowRadius = 20
        shadowHost.layer?.shadowOpacity = 1
        cv.addSubview(shadowHost)

        // Light vibrancy card
        let effect = NSVisualEffectView(frame: cv.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        shadowHost.addSubview(effect)

        // Subtle border
        let borderView = NSView(frame: cv.bounds)
        borderView.autoresizingMask = [.width, .height]
        borderView.wantsLayer = true
        borderView.layer?.cornerRadius = cornerRadius
        borderView.layer?.borderWidth = 0.5
        borderView.layer?.borderColor = NSColor.black.withAlphaComponent(0.06).cgColor
        effect.addSubview(borderView)

        // Container
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: effect.topAnchor, constant: vPad),
            container.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: hPad),
            container.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -hPad),
            container.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -vPad),
        ])

        // Status row: icon/waveform + label + spinner
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .centerY
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusRow)

        waveformView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            waveformView.widthAnchor.constraint(equalToConstant: 32),
            waveformView.heightAnchor.constraint(equalToConstant: 20),
        ])
        statusRow.addArrangedSubview(waveformView)

        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.imageScaling = .scaleProportionallyDown
        NSLayoutConstraint.activate([
            statusIcon.widthAnchor.constraint(equalToConstant: 18),
            statusIcon.heightAnchor.constraint(equalToConstant: 18),
        ])
        statusIcon.isHidden = true
        statusRow.addArrangedSubview(statusIcon)

        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        statusRow.addArrangedSubview(statusLabel)

        spinnerView.style = .spinning
        spinnerView.controlSize = .small
        spinnerView.translatesAutoresizingMaskIntoConstraints = false
        spinnerView.isHidden = true
        statusRow.addArrangedSubview(spinnerView)

        // Text
        textLabel.font = .systemFont(ofSize: 14, weight: .regular)
        textLabel.textColor = .labelColor
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.maximumNumberOfLines = 4
        textLabel.preferredMaxLayoutWidth = panelWidth - hPad * 2
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(textLabel)

        NSLayoutConstraint.activate([
            statusRow.topAnchor.constraint(equalTo: container.topAnchor),
            statusRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusRow.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),

            textLabel.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 8),
            textLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Public API

    /// Show the recording state with waveform.
    func showRecording() {
        autoInjectTimer?.invalidate()
        currentText = ""

        statusLabel.stringValue = "LISTENING"
        textLabel.stringValue = "Listening..."
        textLabel.textColor = .secondaryLabelColor

        waveformView.isHidden = false
        waveformView.isAnimating = true
        statusIcon.isHidden = true
        spinnerView.isHidden = true
        spinnerView.stopAnimation(nil)

        showAtPosition()
    }

    /// Update the partial transcription text during recording.
    func updatePartialText(_ text: String) {
        currentText = text
        textLabel.stringValue = text
        textLabel.textColor = .labelColor
        resizeToFit()
    }

    /// Update the audio level for waveform animation.
    func updateAudioLevel(_ level: Float) {
        waveformView.setLevel(CGFloat(level))
    }

    /// Show the "refining" state.
    func showRefining() {
        statusLabel.stringValue = "REFINING"
        waveformView.isAnimating = false
        waveformView.isHidden = true
        spinnerView.isHidden = false
        spinnerView.startAnimation(nil)
    }

    /// Show refined result, then auto-inject.
    func showResult(raw: String, refined: String, wasRefined: Bool) {
        currentText = refined

        statusLabel.stringValue = wasRefined ? "REFINED" : "DONE"
        textLabel.stringValue = refined
        textLabel.textColor = .labelColor

        waveformView.isHidden = true
        waveformView.isAnimating = false
        spinnerView.isHidden = true
        spinnerView.stopAnimation(nil)

        // Show green checkmark
        statusIcon.isHidden = false
        let checkImage = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")!
        statusIcon.image = checkImage
        statusIcon.contentTintColor = .systemGreen

        resizeToFit()

        // Auto-inject after 1.5 seconds
        autoInjectTimer?.invalidate()
        autoInjectTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.onAutoInject?(self.currentText)
        }
    }

    /// Show error state briefly.
    func showError() {
        statusIcon.isHidden = false
        statusIcon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Error")
        statusIcon.contentTintColor = .systemRed
        waveformView.isHidden = true
        waveformView.isAnimating = false
        spinnerView.isHidden = true
        spinnerView.stopAnimation(nil)
    }

    /// Dismiss the overlay.
    func dismiss() {
        autoInjectTimer?.invalidate()
        waveformView.isAnimating = false

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }

    // MARK: - Dragging

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragOffset = CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let screenLocation = NSEvent.mouseLocation
        let newOrigin = CGPoint(
            x: screenLocation.x - dragOffset.x,
            y: screenLocation.y - dragOffset.y
        )
        setFrameOrigin(newOrigin)
        Settings.shared.overlayPosition = newOrigin
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    // MARK: - Private

    private func showAtPosition() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame

        let x: CGFloat
        let y: CGFloat
        if let saved = Settings.shared.overlayPosition {
            x = saved.x
            y = saved.y
        } else {
            x = area.midX - panelWidth / 2
            y = area.minY + 60
        }

        let height: CGFloat = 72
        setFrame(NSRect(x: x, y: y, width: panelWidth, height: height), display: true)
        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            animator().alphaValue = 1
        }
    }

    private func resizeToFit() {
        // Calculate text height
        let maxTextWidth = panelWidth - hPad * 2
        let textHeight = textLabel.attributedStringValue.boundingRect(
            with: NSSize(width: maxTextWidth, height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        let statusHeight: CGFloat = 20
        let totalHeight = vPad + statusHeight + 8 + max(textHeight, 18) + vPad

        let newFrame = NSRect(x: frame.origin.x, y: frame.origin.y, width: panelWidth, height: max(totalHeight, 72))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            animator().setFrame(newFrame, display: true)
        }
    }
}

// MARK: - Audio-driven waveform bars

final class WaveformView: NSView {
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
            bar.backgroundColor = NSColor.controlAccentColor.cgColor
            bar.cornerRadius = 2
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
        let factor = level > smoothedLevel ? CGFloat(0.4) : CGFloat(0.15)
        smoothedLevel += (level - smoothedLevel) * factor

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        applyBars(level: smoothedLevel)
        CATransaction.commit()
    }

    private func applyBars(level: CGFloat) {
        let barWidth: CGFloat = 3
        let barGap: CGFloat = 2.5
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
