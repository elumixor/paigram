import AVFoundation
import PaiPasskeyCore
import SwiftUI
import UIKit
import VisionKit

/// Reads the add-device QR pai's web Settings shows on a device that already has a passkey
/// (Settings › Account › Add another device), so this phone can enrol its own. A typed code works too. A code never
/// enrols by itself: the box's passkey request for it is fetched first (its `user.name` = the account the code is
/// bound to), shown on a confirm screen, and `add` fires only on its Add passkey.
@available(iOS 16.0, *)
struct PaiInviteScannerView: View {
    let close: () -> Void
    let add: (PaiPasskeys.PreparedEnrol) -> Void
    @State private var flow = PaiInviteFlow()
    @State private var prepared: PaiPasskeys.PreparedEnrol?
    @State private var typed = ""
    @State private var hint: String?

    private var preparing: Bool {
        if case .preparing = flow.state { return true }
        return false
    }

    private var confirmingAccount: String? {
        if case let .confirming(account) = flow.state { return account }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PaiQRCamera { text in scanned(text) }
                    .ignoresSafeArea(edges: .horizontal)
                    .overlay {
                        if preparing {
                            ProgressView().controlSize(.large).tint(.white)
                        }
                    }
                VStack(alignment: .leading, spacing: 10) {
                    Text(hint ?? "On your Mac open pai › Settings › Account › Add another device, then point the camera at its QR.")
                        .font(.footnote)
                        .foregroundStyle(hint == nil ? Color.secondary : Color.red)
                    HStack {
                        TextField("Or type the code", text: $typed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                            .onSubmit { submitTyped() }
                        Button("Next") { submitTyped() }
                            .disabled(preparing || typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
            }
            .navigationTitle("Scan code from Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel() } }
            }
            .navigationDestination(isPresented: Binding(get: { confirmingAccount != nil }, set: { if !$0 { back() } })) {
                PaiInviteConfirmView(account: confirmingAccount ?? PaiInviteFlow.fallbackAccount, add: confirm, cancel: cancel)
            }
        }
    }

    private func submitTyped() {
        if let code = PaiPasskeyEnrol.invite(fromScanned: typed, host: PaiPasskeys.relyingParty) {
            review(code)
        } else {
            hint = "That isn't an add-device code: copy it from pai's Add another device, or scan its QR."
        }
    }

    private func scanned(_ text: String) {
        guard case .scanning = flow.state else { return }
        if let code = PaiPasskeyEnrol.invite(fromScanned: text, host: PaiPasskeys.relyingParty) {
            review(code)
        } else {
            hint = "That QR isn't pai's add-device code."
        }
    }

    private func review(_ code: String) {
        guard flow.handle(.scanned(code: code)) else { return }
        hint = nil
        Task { @MainActor in
            do {
                let request = try await PaiPasskeys.prepare(invite: code)
                prepared = request
                if !flow.handle(.prepared(accountName: request.accountName)) { prepared = nil }
            } catch {
                if !(error is CancellationError) { hint = error.localizedDescription }
                flow.handle(.failed)
            }
        }
    }

    private func back() {
        if flow.handle(.back) { prepared = nil }
    }

    private func confirm() {
        guard let request = prepared, flow.handle(.confirm) else { return }
        prepared = nil
        add(request)
    }

    private func cancel() {
        flow.handle(.cancel)
        prepared = nil
        close()
    }
}

/// What adding a passkey from a scanned code would do, shown before anything happens: whose pai, which site, and
/// this phone's name as the box will list it.
@available(iOS 16.0, *)
private struct PaiInviteConfirmView: View {
    let account: String
    let add: () -> Void
    let cancel: () -> Void

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    Text("Add a passkey on this phone?")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section {
                row("Account", account)
                row("Site", PaiPasskeys.relyingParty)
                row("This device", UIDevice.current.name)
            } footer: {
                Text("Add it only if you just opened Add another device in pai on your own Mac. This passkey will unlock pai and approve its changes.")
            }
            Section {
                Button(action: add) {
                    Label("Add passkey", systemImage: "person.badge.key.fill")
                }
                Button("Cancel", role: .cancel, action: cancel)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Add passkey")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 16)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

/// The camera, reading QR codes: VisionKit's scanner where the phone supports it, else AVFoundation's metadata output.
@available(iOS 16.0, *)
private struct PaiQRCamera: UIViewControllerRepresentable {
    let onText: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText) }

    func makeUIViewController(context: Context) -> UIViewController {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.qr])],
                qualityLevel: .balanced,
                isHighlightingEnabled: true
            )
            scanner.delegate = context.coordinator
            DispatchQueue.main.async { try? scanner.startScanning() }
            return scanner
        }
        return PaiMetadataScannerController(onText: { context.coordinator.onText($0) })
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.onText = onText
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        (controller as? DataScannerViewController)?.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onText: (String) -> Void

        init(onText: @escaping (String) -> Void) {
            self.onText = onText
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            report(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            report([item])
        }

        private func report(_ items: [RecognizedItem]) {
            for item in items {
                if case let .barcode(barcode) = item, let text = barcode.payloadStringValue {
                    onText(text)
                    return
                }
            }
        }
    }
}

/// The fallback camera for phones without VisionKit's scanner.
private final class PaiMetadataScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let onText: (String) -> Void
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "pai.qr-scanner")
    private var preview: AVCaptureVideoPreviewLayer?
    private let message = UILabel()

    init(onText: @escaping (String) -> Void) {
        self.onText = onText
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        message.textColor = .white
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .footnote)
        view.addSubview(message)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted { self.configure() } else { self.show("Camera access is off: allow it in Settings, or type the code below.") }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        message.frame = view.bounds.insetBy(dx: 24, dy: 24)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            show("No camera here: type the code below.")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            show("The camera can't read codes: type the code below.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        self.preview = preview
        let session = self.session
        queue.async { session.startRunning() }
    }

    private func show(_ text: String) {
        message.text = text
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        for object in metadataObjects {
            if let code = object as? AVMetadataMachineReadableCodeObject, let text = code.stringValue {
                onText(text)
                return
            }
        }
    }
}
