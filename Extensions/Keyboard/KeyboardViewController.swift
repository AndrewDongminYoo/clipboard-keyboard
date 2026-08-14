import Combine
import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardRootView>?
    private var model: KeyboardViewModel?
    private var protectedDataObserver: AnyCancellable?

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = KeyboardViewModel { [weak self] text in
            self?.textDocumentProxy.insertText(text)
        }
        self.model = model
        protectedDataObserver = NotificationCenter.default
            .publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)
            .sink { [weak model] _ in
                MainActor.assumeIsolated {
                    model?.protectedDataWillBecomeUnavailable()
                }
            }
        let hostingController = UIHostingController(rootView: KeyboardRootView(model: model))
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostingController.didMove(toParent: self)
        self.hostingController = hostingController
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        model?.load()
    }
}
