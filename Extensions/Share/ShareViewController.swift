import Combine
import SwiftUI
import UIKit

@MainActor
func observeShareProtectedDataWillBecomeUnavailable(
    notificationCenter: NotificationCenter = .default,
    handler: @escaping @MainActor () -> Void
) -> AnyCancellable {
    notificationCenter.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)
        .sink { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
}

@MainActor
final class ShareViewController: UIViewController {
    private var model: ShareViewModel?
    private var timeoutTask: Task<Void, Never>?
    private var protectedDataObserver: AnyCancellable?
    private var didFinish = false

    override func viewDidLoad() {
        super.viewDidLoad()
        do {
            let model = try ShareViewModel(writer: ShareInboxWriter.live())
            self.model = model
            protectedDataObserver = observeShareProtectedDataWillBecomeUnavailable { [weak self] in
                self?.cancelRequest()
            }
            install(model: model)
            let inputItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            let providers = Self.providers(from: inputItems)
            Task { await model.open(providers: providers) }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.expireRequest() }
            }
        } catch {
            cancelRequest()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !didFinish {
            expireRequest()
        }
    }

    static func providers(from items: [NSExtensionItem]) -> [NSItemProvider] {
        items.flatMap { $0.attachments ?? [] }
    }

    private func install(model: ShareViewModel) {
        let content = ShareExtensionView(
            model: model,
            pin: { [weak self] in await self?.pin() },
            cancel: { [weak self] in self?.cancelRequest() }
        )
        let host = UIHostingController(rootView: content)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func pin() async {
        guard let model else { return }
        do {
            try await model.pin()
            guard model.completion == .queuedForContainingApp else { return }
            didFinish = true
            timeoutTask?.cancel()
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        } catch is CancellationError {
            guard !didFinish else { return }
            cancelRequest()
        } catch {
            guard model.state != .writeFailed else { return }
            cancelRequest()
        }
    }

    private func expireRequest() {
        guard !didFinish else { return }
        model?.expire()
        cancelRequest()
    }

    private func cancelRequest() {
        guard !didFinish else { return }
        didFinish = true
        timeoutTask?.cancel()
        model?.cancel()
        let error = NSError(domain: "ClipboardKeyboardShare", code: NSUserCancelledError)
        extensionContext?.cancelRequest(withError: error)
    }
}

private struct ShareExtensionView: View {
    @ObservedObject var model: ShareViewModel
    let pin: () async -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    switch model.state {
                    case .idle, .loading:
                        ProgressView("Loading shared item…")
                    case .ready:
                        Text(model.preview).lineLimit(8)
                    case .writing:
                        ProgressView("Saving shared item…")
                    case .writeFailed:
                        Text("Unable to save this item. Try again or cancel.")
                    case .rejected:
                        Text("Share exactly one text or web URL item.")
                    case .cancelled:
                        Text("Cancelled")
                    case .failed:
                        Text("Unable to prepare this item.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                HStack {
                    Button("Cancel", action: cancel)
                    Spacer()
                    Button(model.state == .writeFailed ? "Retry" : "Pin") { Task { await pin() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.state != .ready && model.state != .writeFailed)
                }
            }
            .padding()
            .navigationTitle("Pin to Clipboard Keyboard")
        }
    }
}

extension NSItemProvider: ShareItemProviding {
    var canLoadStringObject: Bool {
        canLoadObject(ofClass: NSString.self)
    }

    var canLoadURLObject: Bool {
        canLoadObject(ofClass: NSURL.self)
    }

    func loadStringObject(forTypeIdentifier _: String) async throws -> String {
        let provider = ShareSendableItemProvider(self)
        return try await ShareProviderObjectLoadOperation<String>().load { completion in
            provider.value.loadObject(ofClass: NSString.self) { object, error in
                completion((object as? NSString).map(String.init), error)
            }
        }
    }

    func loadURLObject(forTypeIdentifier _: String) async throws -> URL {
        let provider = ShareSendableItemProvider(self)
        return try await ShareProviderObjectLoadOperation<URL>().load { completion in
            provider.value.loadObject(ofClass: NSURL.self) { object, error in
                completion((object as? NSURL).map { $0 as URL }, error)
            }
        }
    }
}

private final class ShareSendableItemProvider: @unchecked Sendable {
    let value: NSItemProvider

    init(_ value: NSItemProvider) {
        self.value = value
    }
}

final class ShareProviderObjectLoadOperation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var progress: Progress?
    private var isSettled = false
    private var wasCancelled = false

    func load(
        start: @escaping @Sendable (@escaping @Sendable (Value?, Error?) -> Void) -> Progress
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard install(continuation) else { return }
                let progress = start { [weak self] value, error in
                    self?.finish(value: value, error: error)
                }
                install(progress)
            }
        } onCancel: {
            cancel()
        }
    }

    private func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let shouldInstall = lock.withLock {
            guard !isSettled else { return false }
            self.continuation = continuation
            return true
        }
        if !shouldInstall {
            continuation.resume(throwing: CancellationError())
        }
        return shouldInstall
    }

    private func install(_ progress: Progress) {
        let shouldCancel = lock.withLock {
            guard !isSettled else { return wasCancelled }
            self.progress = progress
            return false
        }
        if shouldCancel {
            progress.cancel()
        }
    }

    private func finish(value: Value?, error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            guard !isSettled else { return nil }
            isSettled = true
            let continuation = self.continuation
            self.continuation = nil
            progress = nil
            return continuation
        }
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else if let value {
            continuation.resume(returning: value)
        } else {
            continuation.resume(throwing: CocoaError(.fileReadUnknown))
        }
    }

    private func cancel() {
        let settlement = lock.withLock { () -> (CheckedContinuation<Value, Error>?, Progress?) in
            guard !isSettled else { return (nil, nil) }
            isSettled = true
            wasCancelled = true
            let continuation = self.continuation
            let progress = self.progress
            self.continuation = nil
            self.progress = nil
            return (continuation, progress)
        }
        settlement.1?.cancel()
        settlement.0?.resume(throwing: CancellationError())
    }
}
