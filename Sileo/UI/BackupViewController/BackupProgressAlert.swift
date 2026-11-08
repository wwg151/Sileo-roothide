//
//  BackupProgressAlert.swift
//  Sileo
//
//  The card a backup or restore waits on: what is happening, a bar, how long
//  is left, and Cancel.
//

import Foundation
import UIKit

final class BackupProgressAlert {

    let alert: UIAlertController
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let percentLabel = UILabel()

    private var timer: Timer?
    private var startedAt = Date()
    private var fraction: Double = 0
    private var currentMessage = ""
    private var currentDetail = ""
    private var finished = false
    /// The last estimate, smoothed so the number walks down instead of jumping.
    private var smoothedRemaining: TimeInterval?

    init(title: String, message: String, cancellable: Bool, onCancel: (() -> Void)?) {
        alert = UIAlertController(title: title, message: message + "\n\n", preferredStyle: .alert)
        if cancellable {
            alert.addAction(UIAlertAction(title: String(localizationKey: "Cancel"), style: .cancel) { _ in
                onCancel?()
            })
        }

        progressView.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percentLabel.textAlignment = .left
        percentLabel.textColor = .secondaryLabel
        percentLabel.text = "0%"
        alert.view.addSubview(progressView)
        alert.view.addSubview(percentLabel)
        NSLayoutConstraint.activate([
            progressView.leadingAnchor.constraint(equalTo: alert.view.leadingAnchor, constant: 24),
            progressView.trailingAnchor.constraint(equalTo: alert.view.trailingAnchor, constant: -24),
            progressView.bottomAnchor.constraint(equalTo: alert.view.bottomAnchor, constant: -64),
            percentLabel.leadingAnchor.constraint(equalTo: progressView.leadingAnchor),
            percentLabel.bottomAnchor.constraint(equalTo: progressView.topAnchor, constant: -4)
        ])

        currentMessage = message
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    deinit {
        timer?.invalidate()
    }

    func update(fraction: Double, message: String, detail: String) {
        self.fraction = max(0, min(1, fraction))
        currentMessage = message
        currentDetail = detail
        DispatchQueue.main.async {
            self.render()
        }
    }

    func finish(message: String) {
        finished = true
        timer?.invalidate()
        timer = nil
        DispatchQueue.main.async {
            self.progressView.isHidden = true
            self.percentLabel.isHidden = true
            self.alert.message = message
            self.alert.addAction(UIAlertAction(title: String(localizationKey: "OK"), style: .default))
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
        var text = "\n\(currentMessage)\n\(currentDetail)\n"
        if let remaining = estimatedRemaining() {
            smoothedRemaining = remaining
            let seconds = max(0, Int(remaining.rounded()))
            text += String(format: String(localizationKey: "Backup_Time_Left"), seconds)
        }
        alert.message = text
        progressView.setProgress(Float(fraction), animated: true)
        percentLabel.text = "\(Int(fraction * 100))%"
    }
}
