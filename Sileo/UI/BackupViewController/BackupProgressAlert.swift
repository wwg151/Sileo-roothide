//
//  BackupProgressAlert.swift
//  Sileo
//
//  The card a backup or restore waits on: what is happening, a bar and Cancel.
//

import Foundation
import UIKit

final class BackupProgressAlert {

    let alert: UIAlertController
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let percentLabel = UILabel()

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
    }

    func update(fraction: Double, message: String, detail: String) {
        let value = max(0, min(1, fraction))
        DispatchQueue.main.async {
            self.alert.message = "\n\(message)\n\(detail)\n"
            self.progressView.setProgress(Float(value), animated: true)
            self.percentLabel.text = "\(Int(value * 100))%"
        }
    }

    func finish(message: String) {
        DispatchQueue.main.async {
            self.progressView.isHidden = true
            self.percentLabel.isHidden = true
            self.alert.message = message
            self.alert.addAction(UIAlertAction(title: String(localizationKey: "OK"), style: .default))
        }
    }
}
