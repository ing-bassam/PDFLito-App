import AVFoundation
import CoreImage
import CoreMotion
import UIKit
import Vision

/// PDFLito's own document camera. Unlike Apple's scanner it never fires as soon as it sees a page:
/// it waits until the page is fully in view, the phone is held still and the lens has finished
/// focusing. Every photo is checked for sharpness right away; a blurry one is thrown away and retaken.
final class ScannerViewController: UIViewController {
    var onFinish: ([UIImage]) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onAutoCaptureChanged: (Bool) -> Void = { _ in }
    var strictness: Strictness = .normal
    /// Finish right after the first good page (used for "Neu scannen").
    var singlePage = false
    var autoCapture = true

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    // MARK: Capture pipeline

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "de.pdflito.camera.session")
    private let videoQueue = DispatchQueue(label: "de.pdflito.camera.video", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "de.pdflito.camera.processing", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let motion = CMMotionManager()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var device: AVCaptureDevice?
    private var isConfigured = false

    // Only touched on `videoQueue`.
    private var gate = CaptureGate()
    private let liveRequest = VNDetectDocumentSegmentationRequest()
    private var lastDetection: CFTimeInterval = 0
    private var liveQuad: Quad?
    private var quadAtCapture: Quad?
    private var isCapturing = false
    private var captureIsManual = false
    private var autoEnabled = true
    private var isSteady = true
    private var lastLensPosition: Float = -1
    private var lastLensChange: CFTimeInterval = 0
    private var focusingSince: CFTimeInterval?
    private var manualRequestedAt: CFTimeInterval?
    private var consecutiveRejects = 0
    private var lastFocusPoint: CGPoint?
    private var lastShownState: CaptureGate.State?

    // MARK: Interface (main thread)

    private var images: [UIImage] = []
    private var hintOverrideUntil: CFTimeInterval = 0
    private let previewView = UIView()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let quadLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private let hintLabel = PaddedLabel()
    private let shutterButton = UIButton(type: .custom)
    private let doneButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let autoButton = UIButton(type: .system)
    private let torchButton = UIButton(type: .system)
    private let thumbnailButton = UIButton(type: .custom)
    private let countLabel = PaddedLabel()
    private let flashView = UIView()
    private let messageLabel = UILabel()
    private let settingsButton = UIButton(type: .system)

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        autoEnabled = autoCapture
        buildInterface()
        updateControls()
        requestCameraAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = previewView.bounds
        quadLayer.frame = previewView.bounds
        let ring = shutterButton.bounds.insetBy(dx: -7, dy: -7)
        progressLayer.frame = shutterButton.bounds
        progressLayer.path = UIBezierPath(arcCenter: CGPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2,
                                          startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        startRunning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        motion.stopDeviceMotionUpdates()
        sessionQueue.async { [session, device] in
            if let device, device.hasTorch, device.isTorchActive, (try? device.lockForConfiguration()) != nil {
                device.torchMode = .off
                device.unlockForConfiguration()
            }
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    // MARK: - Setup

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureSession()
                        self?.startRunning()
                    } else {
                        self?.showMessage("PDFLito darf die Kamera nicht verwenden. Erlaube den Zugriff in den Einstellungen.",
                                          offerSettings: true)
                    }
                }
            }
        default:
            showMessage("PDFLito darf die Kamera nicht verwenden. Erlaube den Zugriff in den Einstellungen.",
                        offerSettings: true)
        }
    }

    private func configureSession() {
        guard !isConfigured else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            showMessage("Auf diesem Gerät ist keine Kamera verfügbar.", offerSettings: false)
            return
        }
        isConfigured = true
        device = camera
        previewLayer.session = session
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        let session = session, photoOutput = photoOutput, videoOutput = videoOutput
        sessionQueue.async {
            session.beginConfiguration()
            session.sessionPreset = .photo
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            session.commitConfiguration()
            if (try? camera.lockForConfiguration()) != nil {
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                if camera.isSmoothAutoFocusSupported {
                    camera.isSmoothAutoFocusEnabled = false
                }
                camera.unlockForConfiguration()
            }
        }
        torchButton.isHidden = !camera.hasTorch
    }

    private func startRunning() {
        guard isConfigured else { return }
        sessionQueue.async { [session] in
            if !session.isRunning {
                session.startRunning()
            }
        }
        videoQueue.async { [weak self] in
            self?.gate.reset()
            self?.isCapturing = false
        }
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = videoQueue
        motion.startDeviceMotionUpdates(to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            let rotation = data.rotationRate
            let acceleration = data.userAcceleration
            let turning = (rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z).squareRoot()
            let shaking = (acceleration.x * acceleration.x + acceleration.y * acceleration.y
                           + acceleration.z * acceleration.z).squareRoot()
            self.isSteady = turning < 0.22 && shaking < 0.08
        }
    }

    // MARK: - Interface

    private func buildInterface() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.backgroundColor = .black
        view.addSubview(previewView)
        previewLayer.videoGravity = .resizeAspectFill
        previewView.layer.addSublayer(previewLayer)
        quadLayer.fillColor = UIColor.systemYellow.withAlphaComponent(0.15).cgColor
        quadLayer.strokeColor = UIColor.systemYellow.cgColor
        quadLayer.lineWidth = 3
        quadLayer.lineJoin = .round
        previewView.layer.addSublayer(quadLayer)
        previewView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focusTapped(_:))))

        flashView.backgroundColor = .white
        flashView.alpha = 0
        flashView.isUserInteractionEnabled = false
        flashView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(flashView)

        hintLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.textColor = .white
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        hintLabel.layer.cornerRadius = 14
        hintLabel.layer.masksToBounds = true
        hintLabel.text = "Dokument ins Bild halten"
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        configure(cancelButton, title: "Abbrechen", symbol: nil, action: #selector(cancelTapped))
        configure(torchButton, title: nil, symbol: "flashlight.off.fill", action: #selector(torchTapped))
        torchButton.accessibilityLabel = "Taschenlampe"
        configure(autoButton, title: "Auto", symbol: nil, action: #selector(autoTapped))
        configure(doneButton, title: "Fertig", symbol: nil, action: #selector(doneTapped))
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)

        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        shutterButton.backgroundColor = .white
        shutterButton.layer.cornerRadius = 33
        shutterButton.layer.borderColor = UIColor.black.withAlphaComponent(0.25).cgColor
        shutterButton.layer.borderWidth = 2
        shutterButton.accessibilityLabel = "Auslösen"
        shutterButton.addTarget(self, action: #selector(shutterTapped), for: .touchUpInside)
        view.addSubview(shutterButton)
        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.strokeColor = UIColor.systemGreen.cgColor
        progressLayer.lineWidth = 4
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0
        shutterButton.layer.addSublayer(progressLayer)

        thumbnailButton.translatesAutoresizingMaskIntoConstraints = false
        thumbnailButton.imageView?.contentMode = .scaleAspectFill
        thumbnailButton.contentHorizontalAlignment = .fill
        thumbnailButton.contentVerticalAlignment = .fill
        thumbnailButton.layer.cornerRadius = 6
        thumbnailButton.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        thumbnailButton.layer.borderWidth = 1
        thumbnailButton.clipsToBounds = true
        thumbnailButton.isHidden = true
        thumbnailButton.accessibilityLabel = "Erfasste Seiten"
        thumbnailButton.addTarget(self, action: #selector(thumbnailTapped), for: .touchUpInside)
        view.addSubview(thumbnailButton)

        countLabel.font = .preferredFont(forTextStyle: .caption1).bold()
        countLabel.textColor = .white
        countLabel.backgroundColor = .systemBlue
        countLabel.horizontalPadding = 7
        countLabel.verticalPadding = 2
        countLabel.layer.cornerRadius = 10
        countLabel.layer.masksToBounds = true
        countLabel.isHidden = true
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(countLabel)

        messageLabel.textColor = .white
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)
        configure(settingsButton, title: "Einstellungen öffnen", symbol: nil, action: #selector(openSettings))
        settingsButton.isHidden = true

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            flashView.topAnchor.constraint(equalTo: view.topAnchor),
            flashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            flashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            flashView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            cancelButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            cancelButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            autoButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            autoButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            torchButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            torchButton.trailingAnchor.constraint(equalTo: autoButton.leadingAnchor, constant: -10),

            hintLabel.topAnchor.constraint(equalTo: cancelButton.bottomAnchor, constant: 14),
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -16),

            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -24),
            shutterButton.widthAnchor.constraint(equalToConstant: 66),
            shutterButton.heightAnchor.constraint(equalToConstant: 66),

            thumbnailButton.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
            thumbnailButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            thumbnailButton.widthAnchor.constraint(equalToConstant: 46),
            thumbnailButton.heightAnchor.constraint(equalToConstant: 62),
            countLabel.centerXAnchor.constraint(equalTo: thumbnailButton.trailingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: thumbnailButton.topAnchor),

            doneButton.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),

            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32),
            messageLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32),
            settingsButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 16),
            settingsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    private func configure(_ button: UIButton, title: String?, symbol: String?, action: Selector) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)
        button.configuration = configuration
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
        view.addSubview(button)
    }

    private func updateControls() {
        let count = images.count
        doneButton.configuration?.title = count > 0 ? "Fertig (\(count))" : "Fertig"
        doneButton.isEnabled = count > 0
        doneButton.alpha = count > 0 ? 1 : 0.5
        thumbnailButton.isHidden = count == 0
        countLabel.isHidden = count == 0
        countLabel.text = "\(count)"
        thumbnailButton.setImage(images.last, for: .normal)
        autoButton.configuration?.title = autoCapture ? "Auto" : "Manuell"
        autoButton.configuration?.baseBackgroundColor = autoCapture
            ? UIColor.systemGreen.withAlphaComponent(0.85) : UIColor.black.withAlphaComponent(0.55)
        autoButton.accessibilityLabel = autoCapture ? "Automatisch auslösen: ein" : "Automatisch auslösen: aus"
    }

    private func showMessage(_ text: String, offerSettings: Bool) {
        messageLabel.text = text
        messageLabel.isHidden = false
        settingsButton.isHidden = !offerSettings
        hintLabel.isHidden = true
        shutterButton.isEnabled = false
        shutterButton.alpha = 0.4
        autoButton.isHidden = true
        torchButton.isHidden = true
    }

    private func show(_ state: CaptureGate.State, quad: Quad?) {
        var path: CGPath?
        if let quad {
            let points = quad.corners.map { point in
                previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: 1 - point.y, y: 1 - point.x))
            }
            let bezier = UIBezierPath()
            bezier.move(to: points[0])
            points.dropFirst().forEach { bezier.addLine(to: $0) }
            bezier.close()
            path = bezier.cgPath
        }
        var progress = 0.0
        var calm = false
        var text: String
        switch state {
        case .searching: text = "Dokument ins Bild halten"
        case .tooSmall: text = "Näher herangehen"
        case .moving: text = "Ruhig halten …"
        case .focusing: text = "Stelle scharf …"
        case .holding(let value):
            text = "Ruhig halten – gleich wird ausgelöst"
            progress = value
            calm = true
        case .ready:
            text = "Aufnahme …"
            progress = 1
            calm = true
        case .waitingForNextPage:
            text = singlePage ? "Seite erfasst" : "Seite erfasst – nächste Seite auflegen oder „Fertig“ tippen"
        }
        if !autoCapture {
            progress = 0
            switch state {
            case .holding, .ready, .waitingForNextPage: text = "Scharf – jetzt auslösen"
            case .searching: text = "Dokument ins Bild halten und auslösen"
            default: break
            }
        }
        let color = calm ? UIColor.systemGreen : UIColor.systemYellow
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        quadLayer.path = path
        quadLayer.strokeColor = color.cgColor
        quadLayer.fillColor = color.withAlphaComponent(0.15).cgColor
        progressLayer.strokeEnd = CGFloat(progress)
        CATransaction.commit()
        if CACurrentMediaTime() >= hintOverrideUntil, hintLabel.text != text {
            hintLabel.text = text
        }
    }

    private func showTemporaryHint(_ text: String, seconds: CFTimeInterval = 2.2) {
        hintOverrideUntil = CACurrentMediaTime() + seconds
        hintLabel.text = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        guard !images.isEmpty else {
            onCancel()
            return
        }
        let count = images.count
        let alert = UIAlertController(title: count == 1 ? "1 Seite verwerfen?" : "\(count) Seiten verwerfen?",
                                      message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Verwerfen", style: .destructive) { [weak self] _ in self?.onCancel() })
        alert.addAction(UIAlertAction(title: "Weiter scannen", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func doneTapped() {
        guard !images.isEmpty else { return }
        onFinish(images)
    }

    @objc private func autoTapped() {
        autoCapture.toggle()
        onAutoCaptureChanged(autoCapture)
        updateControls()
        let enabled = autoCapture
        videoQueue.async { [weak self] in
            self?.autoEnabled = enabled
            self?.gate.reset()
            self?.lastShownState = nil
        }
        showTemporaryHint(enabled ? "Automatik: löst aus, sobald das Bild scharf und ruhig ist"
                                  : "Manuell: Auslöser tippen", seconds: 1.8)
    }

    @objc private func torchTapped() {
        guard let device, device.hasTorch else { return }
        let turnOn = !device.isTorchActive
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = turnOn ? .on : .off
            device.unlockForConfiguration()
        }
        torchButton.configuration?.image = UIImage(systemName: turnOn ? "flashlight.on.fill" : "flashlight.off.fill")
        torchButton.configuration?.baseForegroundColor = turnOn ? .systemYellow : .white
    }

    @objc private func shutterTapped() {
        videoQueue.async { [weak self] in
            guard let self, !self.isCapturing, self.manualRequestedAt == nil else { return }
            self.manualRequestedAt = CACurrentMediaTime()
        }
    }

    @objc private func thumbnailTapped() {
        guard !images.isEmpty else { return }
        let sheet = UIAlertController(title: "Seite \(images.count)", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Letzte Seite entfernen", style: .destructive) { [weak self] _ in
            guard let self, !self.images.isEmpty else { return }
            self.images.removeLast()
            self.updateControls()
            self.videoQueue.async { self.gate.reset() }
        })
        sheet.addAction(UIAlertAction(title: "Abbrechen", style: .cancel))
        sheet.popoverPresentationController?.sourceView = thumbnailButton
        present(sheet, animated: true)
    }

    @objc private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    @objc private func focusTapped(_ recognizer: UITapGestureRecognizer) {
        let point = previewLayer.captureDevicePointConverted(fromLayerPoint: recognizer.location(in: previewView))
        focus(at: point)
    }

    private func focus(at devicePoint: CGPoint) {
        guard let device else { return }
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: - Live analysis (videoQueue)

    private func analyze(_ pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastDetection >= 0.08 else { return }
        lastDetection = now

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([liveRequest])
        var quad: Quad?
        if let observation = liveRequest.results?.first, observation.confidence >= 0.6 {
            quad = Quad(topLeft: observation.topLeft, topRight: observation.topRight,
                        bottomRight: observation.bottomRight, bottomLeft: observation.bottomLeft)
        }
        liveQuad = quad

        // Point focus and exposure at the page whenever it has moved noticeably.
        if let center = quad?.center {
            let previous = lastFocusPoint ?? CGPoint(x: -1, y: -1)
            if hypot(center.x - previous.x, center.y - previous.y) > 0.12 {
                lastFocusPoint = center
                focus(at: CGPoint(x: 1 - center.y, y: 1 - center.x))
            }
        }

        var focusing = false
        if let device {
            let lens = device.lensPosition
            if abs(lens - lastLensPosition) > 0.01 {
                lastLensPosition = lens
                lastLensChange = now
            }
            focusing = device.isAdjustingFocus || now - lastLensChange < 0.25
        }
        // A lens that keeps hunting must not block the scan forever.
        if focusing {
            let since = focusingSince ?? now
            focusingSince = since
            if now - since > 2.5 { focusing = false }
        } else {
            focusingSince = nil
        }

        guard !isCapturing else { return }
        if let requested = manualRequestedAt {
            if !focusing || now - requested > 1.5 {
                manualRequestedAt = nil
                takePhoto(manual: true)
            }
            return
        }
        let state = gate.update(quad: quad, isSteady: isSteady, isFocusing: focusing, now: now)
        DispatchQueue.main.async { [weak self] in
            self?.show(state, quad: quad)
        }
        if state == .ready, autoEnabled {
            takePhoto(manual: false)
        }
    }

    private func takePhoto(manual: Bool) {
        isCapturing = true
        captureIsManual = manual
        quadAtCapture = liveQuad
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning, self.photoOutput.connection(with: .video) != nil else {
                self.videoQueue.async { self.isCapturing = false }
                return
            }
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            let highest = self.photoOutput.maxPhotoQualityPrioritization
            settings.photoQualityPrioritization = highest.rawValue < AVCapturePhotoOutput.QualityPrioritization.balanced.rawValue
                ? highest : .balanced
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - Photo processing (processingQueue)

    private enum Outcome {
        case page(UIImage)
        case blurry(UIImage)
        case dark
        case failed
    }

    private func process(_ data: Data?, liveQuad: Quad?) -> Outcome {
        guard let data, let raw = CIImage(data: data) else { return .failed }
        // The sensor delivers landscape pixels; the app is portrait only.
        let upright = raw.extent.width > raw.extent.height ? raw.oriented(.right) : raw

        var quad = liveQuad
        let request = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(ciImage: upright, options: [:]).perform([request])
        if let observation = request.results?.first, observation.confidence >= 0.5 {
            let found = Quad(topLeft: observation.topLeft, topRight: observation.topRight,
                             bottomRight: observation.bottomRight, bottomLeft: observation.bottomLeft)
            if found.area >= 0.08 { quad = found }
        }

        var output = upright
        if let quad {
            let extent = upright.extent
            func vector(_ point: CGPoint) -> CIVector {
                CIVector(x: extent.minX + point.x * extent.width, y: extent.minY + point.y * extent.height)
            }
            output = upright.applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": vector(quad.topLeft), "inputTopRight": vector(quad.topRight),
                "inputBottomRight": vector(quad.bottomRight), "inputBottomLeft": vector(quad.bottomLeft),
            ])
        }
        let longSide = max(output.extent.width, output.extent.height)
        guard longSide > 16 else { return .failed }
        if longSide > 2600 {
            let factor = 2600 / longSide
            output = output.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        }
        guard let cgImage = ciContext.createCGImage(output, from: output.extent.integral) else { return .failed }
        let image = UIImage(cgImage: cgImage)

        guard let gray = ImageProcessor.grayscale(cgImage, maxLongSide: QualityChecker.analysisLongSide) else {
            return .page(image)
        }
        if QualityChecker.brightness(of: gray) < QualityChecker.minimumBrightness {
            return .dark
        }
        let limit = QualityChecker.thresholds(for: strictness).minimumSharpness
        if let sharpness = QualityChecker.pageSharpness(of: gray), sharpness < limit {
            return .blurry(image)
        }
        return .page(image)
    }

    private func finish(_ outcome: Outcome) {
        var accepted: UIImage?
        var hint: String?
        switch outcome {
        case .page(let image):
            accepted = image
        case .blurry(let image):
            // Manual shots are accepted on the third try; the review screen still marks them.
            if captureIsManual, consecutiveRejects >= 2 {
                accepted = image
            } else {
                hint = consecutiveRejects >= 1
                    ? "Noch unscharf – mehr Licht oder Taschenlampe einschalten"
                    : "Unscharf – Aufnahme wird wiederholt"
            }
        case .dark:
            hint = "Zu dunkel – mehr Licht oder Taschenlampe einschalten"
        case .failed:
            hint = "Aufnahme fehlgeschlagen – bitte noch einmal"
        }
        consecutiveRejects = accepted == nil ? consecutiveRejects + 1 : 0
        gate.didCapture(quad: quadAtCapture, accepted: accepted != nil, now: CACurrentMediaTime())
        isCapturing = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let accepted {
                self.images.append(accepted)
                self.updateControls()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(notification: .announcement, argument: "Seite \(self.images.count) erfasst")
                if self.singlePage {
                    self.onFinish(self.images)
                }
            } else if let hint {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                self.showTemporaryHint(hint)
            }
        }
    }
}

extension ScannerViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        analyze(pixelBuffer)
    }
}

extension ScannerViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flashView.alpha = 0.7
            UIView.animate(withDuration: 0.25) { self.flashView.alpha = 0 }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        videoQueue.async { [weak self] in
            guard let self else { return }
            let quad = self.quadAtCapture
            self.processingQueue.async {
                let outcome = self.process(data, liveQuad: quad)
                self.videoQueue.async { self.finish(outcome) }
            }
        }
    }
}

/// Label with inner padding, used for the hint pill and the page counter.
final class PaddedLabel: UILabel {
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 8

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: horizontalPadding, dy: verticalPadding))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 2 * horizontalPadding, height: size.height + 2 * verticalPadding)
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
