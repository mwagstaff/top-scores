import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private enum Config {
        static let appGroupID = "group.dev.skynolimit.topscores"
        static let sharedURLKey = "fantasy.sharedEntryURL"
        static let sharedUpdatedAtKey = "fantasy.sharedEntryUpdatedAt"
        static let managerEntryIDKey = "fantasy.managerEntryID"
    }

    private let logoButton = UIButton(type: .custom)
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var didProcess = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didProcess else { return }
        didProcess = true

        Task { @MainActor in
            await processIncomingShare()
        }
    }

    private func configureUI() {
        logoButton.translatesAutoresizingMaskIntoConstraints = false
        logoButton.adjustsImageWhenHighlighted = true
        logoButton.clipsToBounds = true
        logoButton.layer.cornerRadius = 16
        logoButton.isEnabled = false
        if let image = appIconImage() {
            logoButton.setImage(image, for: .normal)
            logoButton.imageView?.contentMode = .scaleAspectFill
        } else {
            logoButton.setImage(UIImage(systemName: "soccerball.circle.fill"), for: .normal)
            logoButton.tintColor = .systemBlue
            logoButton.backgroundColor = UIColor.secondarySystemBackground
        }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Saving to Top Scores"
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Checking shared URL..."
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [logoButton, spinner, titleLabel, statusLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            logoButton.widthAnchor.constraint(equalToConstant: 72),
            logoButton.heightAnchor.constraint(equalToConstant: 72),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        ])
    }

    @MainActor
    private func processIncomingShare() async {
        guard let sharedText = await extractSharedText() else {
            finishWithError("No URL found. Share a Fantasy Points page URL.")
            return
        }

        guard let parsedTarget = FantasyShareTargetParser.parse(from: sharedText) else {
            finishWithError("No Fantasy entry or league ID found in shared content.")
            return
        }

        guard let defaults = UserDefaults(suiteName: Config.appGroupID) else {
            finishWithError("Unable to access shared app storage.")
            return
        }

        let existingManagerID = defaults
            .string(forKey: Config.managerEntryIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isLinkingPrimaryManager = existingManagerID.isEmpty

        if case .league = parsedTarget, isLinkingPrimaryManager {
            finishWithError("Link your Fantasy account first by sharing your Points page URL.")
            return
        }

        defaults.set(sharedText, forKey: Config.sharedURLKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Config.sharedUpdatedAtKey)
        defaults.synchronize()

        showSuccessUI(target: parsedTarget, isLinkingPrimaryManager: isLinkingPrimaryManager)
        completeExtension(after: 5.0)
    }

    @MainActor
    private func showSuccessUI(target: FantasyShareTargetParser.Target, isLinkingPrimaryManager: Bool) {
        spinner.stopAnimating()
        switch target {
        case .manager:
            titleLabel.text = isLinkingPrimaryManager
                ? "Fantasy Football account linked"
                : "Fantasy Football rival added"
        case .league:
            titleLabel.text = "Fantasy Football league added"
        }
        statusLabel.textColor = .secondaryLabel
        switch target {
        case .manager:
            statusLabel.text = isLinkingPrimaryManager
                ? "Please return to Top Scores to complete setup"
                : "Please return to Top Scores to view your updated Rivals table"
        case .league:
            statusLabel.text = "Please return to Top Scores to view your updated Leagues section"
        }
    }

    @MainActor
    private func finishWithError(_ message: String) {
        spinner.stopAnimating()
        titleLabel.text = "Unable to save share"
        statusLabel.textColor = .systemRed
        statusLabel.text = message
        completeExtension(after: 1.8)
    }

    private func completeExtension(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func extractSharedText() async -> String? {
        guard let inputItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            return nil
        }

        for item in inputItems {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let sharedURL = await loadItem(provider: provider, typeIdentifier: UTType.url.identifier) {
                    if let url = sharedURL as? URL {
                        return url.absoluteString
                    }
                    if let text = sharedURL as? String {
                        return text
                    }
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let plainText = await loadItem(provider: provider, typeIdentifier: UTType.plainText.identifier) as? String {
                    return plainText
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
                   let text = await loadItem(provider: provider, typeIdentifier: UTType.text.identifier) as? String {
                    return text
                }
            }
        }

        return nil
    }

    private func loadItem(provider: NSItemProvider, typeIdentifier: String) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                continuation.resume(returning: item as? NSSecureCoding)
            }
        }
    }

    private func appIconImage() -> UIImage? {
        UIImage(named: "top-scores-logo")
    }
}

private enum FantasyShareTargetParser {
    enum Target {
        case manager(String)
        case league(String)
    }

    private static let managerURLPattern = #"(?i)(?:https?://)?(?:www\.)?fantasy\.premierleague\.com/entry/(\d+)(?:[/?#]|$)"#
    private static let leagueURLPattern = #"(?i)(?:https?://)?(?:www\.)?fantasy\.premierleague\.com/leagues/(?:classic/)?(\d+)(?:[/?#]|$)"#

    static func parse(from rawText: String) -> Target? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let managerID = trimmed.firstMatch(of: managerURLPattern)?.capturedGroups.first {
            return .manager(managerID)
        }
        if let leagueID = trimmed.firstMatch(of: leagueURLPattern)?.capturedGroups.first {
            return .league(leagueID)
        }
        return nil
    }
}

private extension String {
    func firstMatch(of pattern: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: self) else {
            return nil
        }
        return RegexMatch(capturedGroups: [String(self[captureRange])])
    }
}

private struct RegexMatch {
    let capturedGroups: [String]
}
