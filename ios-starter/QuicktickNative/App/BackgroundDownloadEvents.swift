import UIKit
import AVFAudio

@MainActor
enum BackgroundDownloadEvents {
    static var handlers: [String: () -> Void] = [:]
    static func complete(_ identifier: String) { handlers.removeValue(forKey: identifier)?() }
}

@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("Playback audio session unavailable:", error.localizedDescription) }
        NotificationCenter.default.addObserver(self, selector: #selector(sceneWillDeactivate(_:)),
            name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification, object: nil)
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundDownloadEvents.handlers[identifier] = completionHandler
    }

    // Scene notifications fire synchronously before UIKit captures the
    // app-switcher snapshot. They cover SwiftUI windows and presented sheets.
    // UIApplication callbacks remain as a fallback for lifecycle transitions
    // that do not dispatch a scene-specific notification.
    func applicationWillResignActive(_ application: UIApplication) {
        QuicktickAppSwitcherPrivacy.coverAll()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        QuicktickAppSwitcherPrivacy.coverAll()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        QuicktickAppSwitcherPrivacy.revealAll()
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        QuicktickAppSwitcherPrivacy.cover(notification.object as? UIWindowScene)
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        QuicktickAppSwitcherPrivacy.reveal(notification.object as? UIWindowScene)
    }
}


/// An independent, high-level UIKit window covers every foreground scene
/// before its app-switcher thumbnail is captured. This must not rely solely
/// on a SwiftUI scenePhase view update: that update can arrive too late for
/// a snapshot while media or a modal sheet is on screen.
@MainActor
enum QuicktickAppSwitcherPrivacy {
    private static var covers: [ObjectIdentifier: UIWindow] = [:]

    static func coverAll() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            cover(scene)
        }
    }

    static func cover(_ scene: UIWindowScene?) {
        guard let scene else { return }
        let key = ObjectIdentifier(scene)
        guard covers[key] == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.rootViewController = QuicktickPrivacyCoverController()
        window.isHidden = false
        window.rootViewController?.view.layoutIfNeeded()
        covers[key] = window
        CATransaction.flush()
    }

    static func reveal(_ scene: UIWindowScene?) {
        guard let scene, let window = covers.removeValue(forKey: ObjectIdentifier(scene)) else { return }
        window.isHidden = true
        window.rootViewController = nil
    }

    static func revealAll() {
        for window in covers.values {
            window.isHidden = true
            window.rootViewController = nil
        }
        covers.removeAll()
    }
}

/// Blur plus an almost-opaque tint: even recognizable media shapes are hidden,
/// while the real QuickTick app icon (when available) and wordmark remain.
@MainActor
private final class QuicktickPrivacyCoverController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.accessibilityIdentifier = "quicktick-app-switcher-privacy"

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(blur)

        let dim = UIView()
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.86)
        dim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dim)

        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer.cornerRadius = 26
        badge.layer.masksToBounds = true
        badge.backgroundColor = UIColor(red: 0.39, green: 0.25, blue: 0.88, alpha: 1)

        if let icon = Self.appIcon() {
            let image = UIImageView(image: icon)
            image.contentMode = .scaleAspectFill
            image.translatesAutoresizingMaskIntoConstraints = false
            badge.addSubview(image)
            NSLayoutConstraint.activate([
                image.topAnchor.constraint(equalTo: badge.topAnchor),
                image.bottomAnchor.constraint(equalTo: badge.bottomAnchor),
                image.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
                image.trailingAnchor.constraint(equalTo: badge.trailingAnchor)
            ])
        } else {
            let monogram = UILabel()
            monogram.text = "Q"
            monogram.textColor = .white
            monogram.font = .systemFont(ofSize: 59, weight: .heavy)
            monogram.translatesAutoresizingMaskIntoConstraints = false
            badge.addSubview(monogram)
            NSLayoutConstraint.activate([
                monogram.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                monogram.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
            ])
        }

        let wordmark = UILabel()
        wordmark.text = "QuickTick"
        wordmark.font = .systemFont(ofSize: 34, weight: .bold)
        wordmark.textColor = .white
        wordmark.textAlignment = .center
        wordmark.accessibilityIdentifier = "quicktick-privacy-logo"

        let subtitle = UILabel()
        subtitle.text = "Private preview"
        subtitle.font = .systemFont(ofSize: 14, weight: .medium)
        subtitle.textColor = UIColor.white.withAlphaComponent(0.62)
        subtitle.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [badge, wordmark, subtitle])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(10, after: wordmark)
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: view.topAnchor),
            blur.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dim.topAnchor.constraint(equalTo: view.topAnchor),
            dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 106),
            badge.heightAnchor.constraint(equalToConstant: 106)
        ])
    }

    private static func appIcon() -> UIImage? {
        if let image = UIImage(named: "AppIcon") { return image }
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String] ?? []
        return files.reversed().compactMap { UIImage(named: $0) }.first
    }
}
