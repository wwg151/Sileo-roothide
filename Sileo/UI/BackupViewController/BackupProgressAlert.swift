//
//  BackupProgressAlert.swift
//  Sileo
//
//  The card a backup or restore waits on: what is happening, which package,
//  a bar, how much is left, and Cancel. A card of our own rather than an
//  alert, so every line keeps its distance from the bar.
//

import Foundation
import UIKit

final class BackupProgressAlert: UIViewController {

    /// The controller to present; the card is the alert.
    var alert: UIViewController { self }

    private let card = UIView()
    private let titleLabel = UILabel()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let percentLabel = UILabel()
    private let etaLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let okButton = UIButton(type: .system)

    private let cardTitle: String
    private let firstMessage: String
    private let cancellable: Bool
    private var onCancel: (() -> Void)?

    private var timer: Timer?
    private var startedAt = Date()
    private var fraction: Double = 0
    private var currentName = ""
    private var currentDetail = ""
    private var finished = false
    private var finishedMessage: String?
    /// The last estimate, smoothed so the number walks down instead of jumping.
    private var smoothedRemaining: TimeInterval?

    init(title: String, message: String, cancellable: Bool, onCancel: (() -> Void)?) {
        cardTitle = title
        firstMessage = message
        self.cancellable = cancellable
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        build()
        currentName = firstMessage
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    // MARK: - API

    func update(fraction: Double, message: String, detail: String) {
        self.fraction = max(0, min(1, fraction))
        currentName = message
        currentDetail = detail
        DispatchQueue.main.async {
            self.render()
        }
    }

    func finish(message: String) {
        finished = true
        finishedMessage = message
        timer?.invalidate()
        timer = nil
        DispatchQueue.main.async {
            if self.isViewLoaded {
                self.applyFinished(message)
            }
        }
    }

    private func applyFinished(_ message: String) {
        progressView.isHidden = true
        percentLabel.isHidden = true
        etaLabel.isHidden = true
        cancelButton.isHidden = true
        detailLabel.isHidden = true
        nameLabel.text = message
        okButton.isHidden = false
    }

    // MARK: - Card

    private func build() {
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        titleLabel.text = cardTitle
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2

        nameLabel.text = firstMessage
        nameLabel.font = .preferredFont(forTextStyle: .subheadline)
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle

        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percentLabel.textColor = .secondaryLabel
        percentLabel.textAlignment = .center
        percentLabel.text = "0%"

        etaLabel.font = .preferredFont(forTextStyle: .footnote)
        etaLabel.textColor = .secondaryLabel
        etaLabel.textAlignment = .center
        etaLabel.text = " "

        progressView.progressTintColor = view.tintColor

        for button in [cancelButton, okButton] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.layer.cornerRadius = 10
            button.layer.cornerCurve = .continuous
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        }
        cancelButton.setTitle(String(localizationKey: "Cancel"), for: .normal)
        cancelButton.backgroundColor = .tertiarySystemFill
        cancelButton.setTitleColor(.label, for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.isHidden = !cancellable

        okButton.setTitle(String(localizationKey: "OK"), for: .normal)
        okButton.backgroundColor = view.tintColor
        okButton.setTitleColor(.white, for: .normal)
        okButton.addTarget(self, action: #selector(okTapped), for: .touchUpInside)
        okButton.isHidden = true

        let buttons = UIStackView(arrangedSubviews: [cancelButton, okButton])
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, nameLabel, progressView, percentLabel, detailLabel, etaLabel, buttons
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        stack.setCustomSpacing(18, after: titleLabel)
        stack.setCustomSpacing(10, after: progressView)
        stack.setCustomSpacing(8, after: percentLabel)
        stack.setCustomSpacing(20, after: etaLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 300),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            progressView.heightAnchor.constraint(equalToConstant: 4)
        ])

        if let message = finishedMessage {
            applyFinished(message)
        }
    }

    // MARK: - Estimate

    private func tick() {
        guard !finished else { return }
        DispatchQueue.main.async {
            self.render()
        }
    }

    private func estimatedRemaining() -> TimeInterval? {
        // Too little done to say anything honest yet
        guard fraction > 0.03, fraction < 1 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.5 else { return nil }
        let remaining = elapsed * (1 - fraction) / fraction
        if let previous = smoothedRemaining {
            // Walk towards the new estimate instead of jumping to it
            return previous * 0.6 + remaining * 0.4
        }
        return remaining
    }

    private func render() {
        guard !finished else { return }
        if !currentName.isEmpty {
            nameLabel.text = currentName
        }
        if !currentDetail.isEmpty {
            detailLabel.text = currentDetail
        }
        progressView.setProgress(Float(fraction), animated: true)
        percentLabel.text = "\(Int(fraction * 100))%"
        if let remaining = estimatedRemaining() {
            smoothedRemaining = remaining
            let seconds = max(0, Int(remaining.rounded()))
            etaLabel.text = String(format: String(localizationKey: "Backup_Time_Left"), seconds)
        }
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        timer?.invalidate()
        timer = nil
        onCancel?()
        dismiss(animated: true)
    }

    @objc private func okTapped() {
        dismiss(animated: true)
    }
}
