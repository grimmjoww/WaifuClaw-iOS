import AVFoundation
import SwiftUI
import UIKit

/// Camera QR scanner. Feeds the raw QR string to the pairing confirm screen.
struct QRScannerView: View {
    @EnvironmentObject var appState: AppState
    let manualHost: String?

    @State private var permission: AVAuthorizationStatus = .notDetermined
    @State private var scanned: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch permission {
            case .authorized:
                ScannerCameraView(onFound: { scanned = $0 })
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text("Point at the QR code on your computer")
                        .foregroundStyle(.white)
                        .padding()
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 48)
                }
            case .denied, .restricted:
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.warning)
                    Text("Camera access is off")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("WaifuClaw needs the camera to scan the pairing QR code.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .themePrimaryButton()
                    .padding(.horizontal, 48)
                }
                .padding()
            case .notDetermined:
                ProgressView("Requesting camera access…")
                    .tint(Theme.magenta)
                    .foregroundStyle(Theme.textSecondary)
            @unknown default:
                EmptyView()
            }
        }
        .navigationTitle("Scan QR code")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $scanned) { code in
            PairingConfirmView(qrString: code, manualHost: manualHost)
        }
        .onAppear {
            scanned = nil // clear a previous scan when coming back from Confirm
            permission = AVCaptureDevice.authorizationStatus(for: .video)
            if permission == .notDetermined {
                Task {
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    permission = granted ? .authorized : .denied
                }
            }
        }
    }
}

// navigationDestination(item:) needs an Identifiable wrapper.
extension String: @retroactive Identifiable {
    public var id: String { self }
}

private struct ScannerCameraView: UIViewControllerRepresentable {
    var onFound: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onFound = onFound
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

private final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFound: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var didFire = false

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)

        Task.detached { [weak self] in self?.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.compactMap { $0 as? AVCaptureVideoPreviewLayer }
            .forEach { $0.frame = view.bounds }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didFire,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let string = obj.stringValue
        else { return }
        didFire = true
        session.stopRunning()
        // Haptic tick on successful scan.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onFound?(string)
    }
}
