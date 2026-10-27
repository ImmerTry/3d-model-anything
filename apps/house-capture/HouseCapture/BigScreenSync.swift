import AVFoundation
import SwiftUI
import UIKit

/// Sync the current house to the big screen: scan the QR code the big screen
/// shows, then upload the house share zip to the upload endpoint encoded in it.
///
/// The QR content is the upload page URL from the big screen system, e.g.
/// `http://<screen>/upload?session=<code>`. The API endpoint is derived from it
/// by replacing the `/upload` path with `/api/upload`, keeping the session
/// query. The payload reuses the existing whole-house share zip
/// (`FolderZipper.zip`), so the big screen system receives the same bundle the
/// user already shares via AirDrop: manifest + PLY meshes + photos.
struct BigScreenSyncView: View {
  let house: HouseProject
  @Environment(\.dismiss) private var dismiss
  @State private var phase: Phase = .scanning
  @State private var denied = false
  @State private var task: Task<Void, Never>?

  enum Phase {
    case scanning
    case packing
    case uploading(Double)
    case done
    case failed(String)
  }

  var body: some View {
    NavigationStack {
      Group {
        switch phase {
        case .scanning:
          VStack(spacing: 16) {
            QRScannerView(onFound: handleQR, onDenied: { denied = true })
              .frame(maxWidth: .infinity, maxHeight: 420)
              .clipShape(RoundedRectangle(cornerRadius: 16))
            if denied {
              Text("Camera access is off. Enable Camera for 3D Model Anything in Settings, then try scanning again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
              Text("Point the camera at the QR code on the big screen")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Button("Cancel") { dismiss() }.buttonStyle(.bordered)
          }
          .padding()
        case .packing:
          VStack(spacing: 12) {
            ProgressView()
            Text("Packing…").font(.subheadline)
          }
        case .uploading(let p):
          VStack(spacing: 12) {
            ProgressView(value: p)
            Text(String(format: NSLocalizedString("Uploading… %lld%%", comment: ""), Int(p * 100)))
              .font(.subheadline)
            Button("Cancel") { task?.cancel(); dismiss() }.buttonStyle(.bordered)
          }
          .padding()
        case .done:
          VStack(spacing: 12) {
            Label("Sync complete", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
            Text("The big screen is loading the new model.").font(.subheadline).foregroundStyle(.secondary)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
          }
          .padding()
        case .failed(let message):
          VStack(spacing: 12) {
            Label("Sync failed", systemImage: "exclamationmark.triangle.fill").font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            Button("Scan again") { phase = .scanning }.buttonStyle(.borderedProminent)
            Button("Cancel") { dismiss() }.buttonStyle(.bordered)
          }
          .padding()
        }
      }
      .navigationTitle("Scan the big screen QR code")
      .navigationBarTitleDisplayMode(.inline)
      .onDisappear { task?.cancel() }
    }
  }

  private func handleQR(_ string: String) {
    guard case .scanning = phase else { return }
    let endpoint: URL
    do {
      endpoint = try BigScreenSyncAPI.apiEndpoint(from: string)
    } catch {
      phase = .failed(error.localizedDescription)
      return
    }
    phase = .packing
    task = Task {
      do {
        let zip = try await Task.detached(priority: .userInitiated) {
          try FolderZipper.zip(house.url, name: house.name)
        }.value
        defer { try? FileManager.default.removeItem(at: zip) }
        await MainActor.run { phase = .uploading(0) }
        try await BigScreenSyncAPI.upload(file: zip, to: endpoint) { p in
          Task { @MainActor in phase = .uploading(p) }
        }
        await MainActor.run { phase = .done }
      } catch {
        if Task.isCancelled {
          await MainActor.run { phase = .scanning }
        } else {
          await MainActor.run { phase = .failed(error.localizedDescription) }
        }
      }
    }
  }
}

enum BigScreenSyncError: LocalizedError {
  case invalidQR
  case packing(Error)
  case network(Error)
  case server(Int)

  var errorDescription: String? {
    switch self {
    case .invalidQR:
      NSLocalizedString("This QR code is not a big screen upload code.", comment: "")
    case .packing(let e), .network(let e):
      e.localizedDescription
    case .server(let code):
      "Upload failed (HTTP \(code))"
    }
  }
}

/// The big screen upload contract: QR page URL in, API endpoint + upload out.
enum BigScreenSyncAPI {
  /// Derives the POST endpoint from the QR string. The QR holds the upload
  /// page URL (`…/upload?session=…`); the API lives at `…/api/upload` with
  /// the same session query.
  static func apiEndpoint(from qrString: String) throws -> URL {
    guard let pageURL = URL(string: qrString),
          var comps = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
          let session = comps.queryItems?.first(where: { $0.name == "session" })?.value,
          !session.isEmpty else {
      throw BigScreenSyncError.invalidQR
    }
    let path = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
    if path == "/upload" {
      comps.path = "/api/upload"
    } else if path.hasSuffix("/api/upload") {
      // already an API URL: use as-is
    } else {
      throw BigScreenSyncError.invalidQR
    }
    guard let url = comps.url else { throw BigScreenSyncError.invalidQR }
    return url
  }

  /// Multipart POST of `file` to `endpoint`, with progress 0…1.
  static func upload(file: URL, to endpoint: URL, onProgress: @escaping (Double) -> Void) async throws {
    let boundary = "Boundary-\(UUID().uuidString)"
    let bodyFile = try multipartFile(file: file, boundary: boundary)
    defer { try? FileManager.default.removeItem(at: bodyFile) }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let delegate = UploadDelegate(onProgress: onProgress)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (_, response) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
      delegate.completion = { result in cont.resume(with: result) }
      session.uploadTask(with: request, fromFile: bodyFile).resume()
    }
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw BigScreenSyncError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
  }

  /// Builds the multipart body as a temp file so large house zips are streamed
  /// from disk instead of being held in memory twice.
  private static func multipartFile(file: URL, boundary: String) throws -> URL {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".upload")
    FileManager.default.createFile(atPath: tmp.path, contents: nil)
    let out = try FileHandle(forWritingTo: tmp)
    defer { try? out.close() }
    var head = Data()
    head.append("--\(boundary)\r\n".data(using: .utf8)!)
    head.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\n".data(using: .utf8)!)
    head.append("Content-Type: application/zip\r\n\r\n".data(using: .utf8)!)
    try out.write(contentsOf: head)
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
      try out.write(contentsOf: chunk)
    }
    try out.write(contentsOf: "\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    return tmp
  }

  private final class UploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var onProgress: (Double) -> Void
    var data = Data()
    var completion: ((Result<(Data, URLResponse), Error>) -> Void)?

    init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
      guard totalBytesExpectedToSend > 0 else { return }
      let p = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
      DispatchQueue.main.async { self.onProgress(p) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      if let error {
        completion?(.failure(error))
      } else if let response = task.response {
        completion?(.success((data, response)))
      } else {
        completion?(.failure(URLError(.unknown)))
      }
    }
  }
}

/// Camera QR scanner: a plain view controller wrapped for SwiftUI.
struct QRScannerView: UIViewControllerRepresentable {
  var onFound: (String) -> Void
  var onDenied: () -> Void

  func makeUIViewController(context: Context) -> QRScannerController {
    let controller = QRScannerController()
    controller.onFound = onFound
    controller.onDenied = onDenied
    return controller
  }

  func updateUIViewController(_ controller: QRScannerController, context: Context) {
    controller.onFound = onFound
    controller.onDenied = onDenied
  }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  var onFound: ((String) -> Void)?
  var onDenied: (() -> Void)?
  private let session = AVCaptureSession()
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var found = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      setup()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          if granted { self?.setup() } else { self?.deny() }
        }
      }
    default:
      deny()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = view.bounds
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if session.isRunning { session.stopRunning() }
  }

  private func deny() {
    DispatchQueue.main.async { self.onDenied?() }
  }

  private func setup() {
    guard let device = AVCaptureDevice.default(for: .video),
          let input = try? AVCaptureDeviceInput(device: device),
          session.canAddInput(input) else { deny(); return }
    session.addInput(input)
    let output = AVCaptureMetadataOutput()
    guard session.canAddOutput(output) else { deny(); return }
    session.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: .main)
    output.metadataObjectTypes = [.qr]
    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.videoGravity = .resizeAspectFill
    layer.frame = view.bounds
    view.layer.addSublayer(layer)
    previewLayer = layer
    DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
  }

  func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
    guard !found,
          let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
          let string = obj.stringValue else { return }
    found = true
    session.stopRunning()
    onFound?(string)
  }
}
