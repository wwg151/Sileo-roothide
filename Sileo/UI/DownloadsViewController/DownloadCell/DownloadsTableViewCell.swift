//
//  DownloadsTableViewCell.swift
//  Sileo
//
//  Created by CoolStar on 7/27/19.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import UIKit
import Evander

class DownloadsTableViewCell: BaseSubtitleTableViewCell {
    /// The controller uses 88pt for normal rows and recommendedHeight for errors.
    static let preferredRowHeight: CGFloat = 88

    private let cardView = UIView()
    private let nameLabel = UILabel()
    private let versionLabel = UILabel()
    private let statusLabel = UILabel()
    private let activityTrack = UIView()
    private let activityFill = UIView()
    private let percentageLabel = UILabel()
    private var activityProgress: CGFloat = 0
    private var hasError = false
    private var isFirstInGroup = true
    private var isLastInGroup = true

    /// Call for each configured row, including after a group's rows change.
    public func configureGroupPosition(isFirst: Bool, isLast: Bool) {
        isFirstInGroup = isFirst
        isLastInGroup = isLast
        setNeedsLayout()
    }

    public var package: Package? {
        didSet {
            title = package?.name ?? package?.package
            nameLabel.text = title
            updateVersion()
            if let url = package?.icon {
                icon = EvanderNetworking.image(url: url, size: CGSize(width: 44, height: 44)) { [weak self] image in
                    DispatchQueue.main.async {
                        guard let self = self, url == self.package?.icon else { return }
                        self.icon = image
                    }
                } ?? package?.defaultIcon
            } else {
                icon = package?.defaultIcon
            }
            setNeedsLayout()
        }
    }

    public var isDependency = false {
        didSet { updateVersion() }
    }

    public var action: DownloadsTableViewController.Action? {
        didSet {
            // An old Action must not keep updating a recycled cell.
            if oldValue !== action, oldValue?.cell === self {
                oldValue?.cell = nil
            }
            action?.cell = self
            updateStatus()
        }
    }

    public var download: Download? {
        didSet { updateStatus() }
    }

    public var errorDescription: String? {
        didSet { updateStatus() }
    }

    var searchPackageKeyword: String? {
        didSet { updateStatus() }
    }

    public let retryButton = UIButton(type: .system)
    public let findDepButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // Never drive BaseSubtitleTableViewCell.progress: its indicator owns
        // separate constraints and a percentage label outside the bar's bounds.
        progressView.isHidden = true
        progressView.showsPercentage = false
        textLabel?.isHidden = true
        detailTextLabel?.isHidden = true

        cardView.isUserInteractionEnabled = false
        cardView.layer.cornerRadius = 16
        cardView.layer.cornerCurve = .continuous
        contentView.insertSubview(cardView, at: 0)
        iconView.layer.cornerCurve = .continuous
        iconView.clipsToBounds = true

        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        activityTrack.layer.cornerRadius = 1.5
        activityTrack.clipsToBounds = true
        activityFill.layer.cornerRadius = 1.5
        activityTrack.addSubview(activityFill)
        percentageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        percentageLabel.textAlignment = .right
        [nameLabel, versionLabel, statusLabel, activityTrack, percentageLabel, retryButton, findDepButton].forEach {
            contentView.addSubview($0)
        }

        retryButton.setImage(UIImage(named: "Refresh")?.withRenderingMode(.alwaysTemplate)
                             ?? UIImage(systemName: "arrow.clockwise"), for: .normal)
        retryButton.accessibilityLabel = String(localizationKey: "Retry")
        retryButton.addTarget(self, action: #selector(retryDownload), for: .touchUpInside)
        findDepButton.setImage(UIImage(systemName: "magnifyingglass"), for: .normal)
        findDepButton.accessibilityLabel = String(localizationKey: "Search_Page")
        findDepButton.addTarget(self, action: #selector(findDepPackage), for: .touchUpInside)
        nameLabel.isAccessibilityElement = false
        versionLabel.isAccessibilityElement = false
        statusLabel.isAccessibilityElement = false
        // Keep buttons (and UIKit's editing controls) separately reachable.
        cardView.isAccessibilityElement = true
        iconView.isAccessibilityElement = false
        updateStatus()
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configureGroupPosition(isFirst: true, isLast: true)
        action = nil
        isDependency = false
        download = nil
        errorDescription = nil
        searchPackageKeyword = nil
        package = nil
        title = nil
        subtitle = nil
        icon = nil
        nameLabel.text = nil
        versionLabel.text = nil
        statusLabel.text = nil
        cardView.accessibilityLabel = nil
        activityProgress = 0
        activityTrack.isHidden = true
        retryButton.isHidden = true
        findDepButton.isHidden = true
    }

    private func updateVersion() {
        guard let package = package, package.version != "-1" else {
            versionLabel.text = nil
            return
        }
        if let installed = PackageListManager.shared.installedPackage(identifier: package.package),
           installed.version != package.version {
            versionLabel.text = "\(installed.version) → \(package.version)"
        } else {
            versionLabel.text = package.version
        }
        if isDependency {
            versionLabel.text = (versionLabel.text ?? "") + " · " + String(localizationKey: "Task_Dependency")
        }
        setNeedsLayout()
    }

    private var queuedStatus: String {
        let queued = String(localizationKey: "Queued_Package_Status")
        guard let repoName = package?.sourceRepo?.repoName, !repoName.isEmpty else { return queued }
        return "\(queued) · \(repoName)"
    }

    public func updateStatus() {
        retryButton.isHidden = true
        findDepButton.isHidden = true
        hasError = false
        activityTrack.isHidden = true
        activityProgress = 0
        var status = queuedStatus

        if let error = errorDescription, !error.isEmpty {
            hasError = true
            status = String(localizationKey: error)
            findDepButton.isHidden = searchPackageKeyword?.isEmpty != false
        } else if let action = action {
            status = action.status ?? String(localizationKey: "Ready_Status")
            activityProgress = clampedProgress(action.progress)
            activityTrack.isHidden = false
        } else if let download = download {
            // A failure must win over a stale conversion/download message.
            if let failure = download.failureReason, !failure.isEmpty {
                hasError = true
                status = String(format: String(localizationKey: "Error_Indicator", type: .error), failure)
                retryButton.isHidden = false
            } else if download.success && download.progress == 1 {
                activityProgress = 1
                activityTrack.isHidden = false
                status = String(localizationKey: "Task_Downloaded")
            } else if download.started || download.message != nil {
                activityProgress = download.presentationProgress ?? 0
                activityTrack.isHidden = download.presentationProgress == nil
                if let message = download.message, !message.isEmpty {
                    status = message
                } else if download.totalBytesWritten > 0 {
                    let written = ByteCountFormatter.string(fromByteCount: download.totalBytesWritten, countStyle: .file)
                    if download.presentationExpectedBytes <= 0 {
                        status = written + " …"
                    } else {
                        status = String(format: String(localizationKey: "Download_Progress"), written,
                                        ByteCountFormatter.string(fromByteCount: download.presentationExpectedBytes, countStyle: .file))
                    }
                } else {
                    status = String(localizationKey: "Download_Starting")
                }
            }
        }

        percentageLabel.isHidden = activityTrack.isHidden
        percentageLabel.text = "\(Int(activityProgress * 100))%"
        subtitle = status // Preserve the original public subtitle contract.
        statusLabel.text = status
        statusLabel.numberOfLines = hasError ? 0 : 1
        statusLabel.lineBreakMode = hasError ? .byWordWrapping : .byTruncatingTail
        cardView.accessibilityLabel = [nameLabel.text, versionLabel.text, status]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        updateColors()
        setNeedsLayout()
    }

    private func clampedProgress(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, min(1, value)) : 0
    }

    override func updateSileoColors() {
        super.updateSileoColors()
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        cardView.backgroundColor = .secondarySystemGroupedBackground
        nameLabel.textColor = .sileoLabel
        versionLabel.textColor = .secondaryLabel
        statusLabel.textColor = hasError ? .systemRed : (activityTrack.isHidden ? .secondaryLabel : SileoThemeManager.shared.tintColor)
        percentageLabel.textColor = .secondaryLabel
        activityTrack.backgroundColor = .tertiarySystemFill
        activityFill.backgroundColor = SileoThemeManager.shared.tintColor
        retryButton.tintColor = SileoThemeManager.shared.tintColor
        findDepButton.tintColor = SileoThemeManager.shared.tintColor
    }

    /// Width is the cell's contentView width, after UIKit's editing indentation.
    static func recommendedHeight(forError error: String, contentWidth: CGFloat, hasButton: Bool) -> CGFloat {
        guard !error.isEmpty else { return preferredRowHeight }
        // Match the expanded error frame: 24pt leading, 20pt trailing,
        // and the optional 44pt action button reserved by layoutSubviews.
        let textWidth = max(1, contentWidth - 24 - 20 - (hasButton ? 44 : 0))
        let textHeight = error.boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: UIFont.systemFont(ofSize: 12)], context: nil).height
        return max(preferredRowHeight, ceil(72 + textHeight))
    }

    func recommendedHeight(for contentWidth: CGFloat) -> CGFloat {
        Self.recommendedHeight(forError: hasError ? (statusLabel.text ?? "") : "",
                               contentWidth: contentWidth,
                               hasButton: !retryButton.isHidden || !findDepButton.isHidden)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Base layout is deliberately allowed to run for UITableView's editing
        // layout, then all our frames use the resulting contentView bounds.
        progressView.isHidden = true
        textLabel?.isHidden = true
        detailTextLabel?.isHidden = true
        let width = contentView.bounds.width
        let height = contentView.bounds.height
        let compact = height < Self.preferredRowHeight - 1
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        statusLabel.numberOfLines = hasError && !compact ? 0 : 1
        statusLabel.lineBreakMode = hasError && !compact ? .byWordWrapping : .byTruncatingTail
        func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rtl ? width - x - w : x, y: y, width: max(0, w), height: max(0, h))
        }
        // Adjacent backgrounds meet exactly; only the group's outer corners
        // are rounded. Keep horizontal insets inside UIKit's editing bounds.
        cardView.frame = CGRect(x: 8, y: 0, width: max(0, width - 16), height: max(0, height))
        var corners: CACornerMask = []
        if isFirstInGroup {
            corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner])
        }
        if isLastInGroup {
            corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
        }
        cardView.layer.maskedCorners = corners
        cardView.layer.cornerRadius = corners.isEmpty ? 0 : 16
        iconView.frame = frame(20, compact ? (height - 44) / 2 : 14, 44, 44)
        iconView.backgroundColor = .tertiarySystemFill
        let buttonVisible = !retryButton.isHidden || !findDepButton.isHidden
        let end: CGFloat = width - 20 - (buttonVisible ? 44 : 0)
        let textX: CGFloat = 78
        let textWidth = max(0, end - textX)
        let alignment: NSTextAlignment = rtl ? .right : .left
        nameLabel.textAlignment = alignment
        versionLabel.textAlignment = alignment
        statusLabel.textAlignment = alignment
        retryButton.frame = frame(width - 60, (height - 44) / 2, 44, 44)
        findDepButton.frame = retryButton.frame
        nameLabel.frame = frame(textX, compact ? 6 : 13, textWidth, 20)
        versionLabel.isHidden = compact && hasError
        if compact {
            if hasError {
                statusLabel.frame = frame(textX, 27, textWidth, max(0, height - 31))
            } else {
                let versionWidth = min(textWidth * 0.42, versionLabel.sizeThatFits(CGSize(width: textWidth, height: 18)).width)
                // Leave a dedicated line above the bar for its moving label.
                let metadataY: CGFloat = activityTrack.isHidden ? 29 : 25
                let metadataHeight: CGFloat = activityTrack.isHidden ? 17 : 14
                versionLabel.frame = frame(textX, metadataY, versionWidth, metadataHeight)
                let gap: CGFloat = versionWidth > 0 ? 8 : 0
                statusLabel.frame = frame(textX + versionWidth + gap, metadataY, textWidth - versionWidth - gap, metadataHeight)
            }
        } else {
            versionLabel.frame = frame(textX, 39, textWidth, 17)
            if hasError {
                statusLabel.frame = frame(24, 62, max(0, end - 24), max(0, height - 72))
            } else {
                // Reserve a bounded trailing column so long names and status
                // strings truncate independently instead of overlapping.
                let statusWidth = min(textWidth * 0.44, statusLabel.sizeThatFits(CGSize(width: textWidth, height: 20)).width)
                let gap: CGFloat = statusWidth > 0 ? 10 : 0
                nameLabel.frame = frame(textX, 13, textWidth - statusWidth - gap, 20)
                statusLabel.frame = frame(end - statusWidth, 15, statusWidth, 18)
                statusLabel.textAlignment = rtl ? .left : .right
            }
        }
        activityTrack.frame = frame(textX, height - (compact ? 6 : 12), textWidth, 3)
        let fillWidth = activityTrack.bounds.width * activityProgress
        activityFill.frame = CGRect(x: 0, y: 0, width: fillWidth, height: 3)
        let labelWidth = min(textWidth, 38)
        let labelX = max(0, min(textWidth - labelWidth, fillWidth - labelWidth / 2))
        percentageLabel.textAlignment = .center
        percentageLabel.frame = CGRect(x: activityTrack.frame.minX + labelX,
                                       y: activityTrack.frame.minY - 18, width: labelWidth, height: 16)
    }

    @objc public func retryDownload() {
        guard !retryButton.isHidden, let package = package else { return }
        download = nil
        DownloadManager.shared.retryDownload(package: package.package)
    }

    @objc public func findDepPackage() {
        guard !findDepButton.isHidden,
              let keyword = searchPackageKeyword, !keyword.isEmpty,
              let tabBarController = TabBarController.singleton,
              let controllers = tabBarController.viewControllers, controllers.indices.contains(4),
              let searchPackageNVC = controllers[4] as? SileoNavigationController,
              let searchPackageVC = searchPackageNVC.viewControllers.first as? PackageListViewController else {
            return
        }
        searchPackageVC.searchController.searchBar.text = keyword
        tabBarController.selectedViewController = searchPackageNVC
        searchPackageNVC.popToRootViewController(animated: true)
        tabBarController.closePopup(animated: true)
    }
}
