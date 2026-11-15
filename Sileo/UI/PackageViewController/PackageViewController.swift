//
//  PackageViewController.swift
//  Sileo
//
//  Created by CoolStar on 8/31/19.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import Foundation
import SafariServices
import MessageUI
import Evander
import os.log

class PackageViewController: SileoViewController, PackageQueueButtonDataProvider,
    UIScrollViewDelegate, DepictionViewDelegate, MFMailComposeViewControllerDelegate, PackageActions {
    public var package: Package?
    public var depictionHeight = CGFloat(0)

    public var isPresentedModally = false

    private weak var weakNavController: UINavigationController?

    @IBOutlet private var scrollView: UIScrollView!
    @IBOutlet private var contentView: UIView!

    @IBOutlet private var packageName: UILabel!
    @IBOutlet private var packageAuthor: UILabel!
    private let packageSizeLabel = UILabel()

    private func updatePackageSize(_ package: Package) {
        if packageSizeLabel.superview == nil, let stack = packageAuthor.superview as? UIStackView {
            packageSizeLabel.font = .preferredFont(forTextStyle: .caption1)
            packageSizeLabel.textColor = .secondaryLabel
            packageSizeLabel.numberOfLines = 0
            packageSizeLabel.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(packageSizeLabel)
        }
        let bytes: Int64
        let title: String
        if let size = package.size, let downloadBytes = Int64(size), downloadBytes > 0 {
            bytes = downloadBytes
            title = String(localizationKey: "Package_Download_Size")
        } else if let installedSize = package.installedSize, installedSize > 0,
                  Int64(installedSize) <= Int64.max / 1024 {
            bytes = Int64(installedSize) * 1024
            title = String(localizationKey: "Package_Installed_Size")
        } else {
            packageSizeLabel.isHidden = true
            return
        }
        packageSizeLabel.text = title + " · "
            + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        packageSizeLabel.isHidden = false
    }

    @IBOutlet private var packageIconView: PackageIconView!

    @IBOutlet private var downloadButton: PackageQueueButton!
    private var navBarDownloadButton: PackageQueueButton?
    private var packageNavBarIconView: PackageIconView?
    private var shareButton: UIButton?

    private var navBarShareButtonItem: UIBarButtonItem?
    private var navBarDownloadButtonItem: UIBarButtonItem?

    private var depictionView: DepictionBaseView?
    private var depictionFooterView: DepictionBaseView?

    private var paymentProvider = ""
    private var price = ""
    private var purchased = false
    private var available = false
    private var headerURL: String?

    private var installedPackage: Package?

    @IBOutlet private var depictionHeaderView: UIView!
    @IBOutlet private var depictionBackgroundShadow: UIImageView!
    @IBOutlet private var depictionBackgroundView: UIImageView!
    @IBOutlet private var packageInfoView: UIStackView!

    @IBOutlet private var depictionHeaderImageViewHeight: NSLayoutConstraint!
    @IBOutlet private var contentViewHeight: NSLayoutConstraint!
    @IBOutlet private var contentViewWidth: NSLayoutConstraint!
//    @IBOutlet private var downloadButtonWidth: NSLayoutConstraint!

    // Each reload owns its asynchronous results, including same-ID versions from different repositories.
    private var contentGeneration = UUID()
    private var showcaseReady = false
    private let summaryCard = UIView()
    private let summaryLabel = UILabel()
    private let summaryHeading = UILabel()
    private let detailsCard = UIView()
    private let managementCard = UIView()
    private let controlsCard = UIView()
    private let controlsHeading = UILabel()
    private let ignoreLabel = UILabel()
    private let ignoreHint = UILabel()
    private let ignoreSwitch = UISwitch()
    private let infoButton = UIButton(type: .system)
    private let uninstallButton = UIButton(type: .system)
    private let actionDock = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let versionButton = UIButton(type: .system)
    private let downloadOnlyButton = UIButton(type: .system)
    private let showcaseTaskButton = UIButton(type: .system)
    private var showcaseTaskVisible = false

    /// Called on each task update by the shared host, including when visibility is unchanged.
    func updateShowcaseTaskVisibility(_ visible: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateShowcaseTaskVisibility(visible) }
            return
        }
        let previousVisible = showcaseTaskVisible
        let previousTitle = showcaseTaskButton.title(for: .normal)
        showcaseTaskVisible = visible
        showcaseTaskButton.isHidden = !visible
        if visible {
            let task = DownloadManager.shared.viewController.taskPresentation
            let title = String(localizationKey: "Showcase_All_Tasks")
            let status = [task.title, task.detail].filter { !$0.isEmpty }.joined(separator: " · ")
            showcaseTaskButton.setTitle(title + "\n" + status, for: .normal)
            showcaseTaskButton.accessibilityLabel = title
            showcaseTaskButton.accessibilityValue = status
            showcaseTaskButton.setTitleColor(task.failed ? .systemRed : .label, for: .normal)
        }
        if isViewLoaded,
           previousVisible != visible || previousTitle != showcaseTaskButton.title(for: .normal) {
            view.setNeedsLayout()
        }
    }

    @objc private func openShowcaseTasks() {
        TabBarController.singleton?.presentPopupController()
    }
    private var headerObservation: NSKeyValueObservation?
    private var positionedShowcaseAtTop = false

    private var showcaseHeaderSize: CGSize {
        let width = max(280, min(720, view.bounds.width - 40))
        return CGSize(width: width, height: min(320, width * 0.68))
    }

    // Integration point for the shared queue/tab-bar host. This is additional obstruction
    // above the controller's safe area, not the tab bar's full height.
    var showcaseBottomObstruction: CGFloat = 0 {
        didSet {
            if oldValue != showcaseBottomObstruction, isViewLoaded { view.setNeedsLayout() }
        }
    }

    private func configureShowcase() {
        // Reuse the nib outlets, but remove its banner-first positioning constraints.
        NSLayoutConstraint.deactivate(contentView.constraints.filter {
            $0 !== contentViewHeight && $0 !== contentViewWidth
        })
        depictionHeaderImageViewHeight.isActive = false
        packageInfoView.removeArrangedSubview(downloadButton)
        actionDock.contentView.addSubview(downloadButton)
        downloadButton.translatesAutoresizingMaskIntoConstraints = true
        downloadButton.selectsVersionBeforeInstalling = true
        downloadButton.onPackageSelectedForInstallation = { [weak self] selected in
            self?.show(package: selected)
        }
        downloadButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        downloadButton.titleLabel?.adjustsFontForContentSizeCategory = true
        downloadButton.titleLabel?.numberOfLines = 0
        packageInfoView.translatesAutoresizingMaskIntoConstraints = true
        depictionHeaderView.translatesAutoresizingMaskIntoConstraints = true
        depictionBackgroundView.translatesAutoresizingMaskIntoConstraints = true
        depictionBackgroundShadow.isHidden = true
        depictionBackgroundView.image = nil
        depictionBackgroundView.contentMode = .scaleAspectFill
        depictionHeaderView.clipsToBounds = true
        depictionHeaderView.layer.cornerRadius = 24
        packageInfoView.isLayoutMarginsRelativeArrangement = false
        packageInfoView.spacing = 16
        packageInfoView.alignment = .top
        packageName.font = UIFontMetrics(forTextStyle: .title1).scaledFont(for: .systemFont(ofSize: 28, weight: .bold))
        packageName.numberOfLines = 0
        packageName.adjustsFontForContentSizeCategory = true
        packageAuthor.font = .preferredFont(forTextStyle: .subheadline)
        packageAuthor.numberOfLines = 0
        packageAuthor.adjustsFontForContentSizeCategory = true
        packageAuthor.textColor = .secondaryLabel
        packageIconView.layer.cornerRadius = 18
        packageIconView.backgroundColor = .clear
        for constraint in packageIconView.constraints where constraint.firstAttribute == .height {
            constraint.constant = 72
        }
        for card in [summaryCard, detailsCard, managementCard, controlsCard] {
            card.backgroundColor = .secondarySystemGroupedBackground
            card.layer.cornerRadius = 24
            contentView.addSubview(card)
        }
        summaryHeading.text = String(localizationKey: "Showcase_About")
        summaryHeading.font = .preferredFont(forTextStyle: .headline)
        summaryLabel.font = .preferredFont(forTextStyle: .body)
        for label in [summaryHeading, summaryLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .label
            summaryCard.addSubview(label)
        }
        controlsHeading.text = String(localizationKey: "Showcase_Management")
        ignoreLabel.text = String(localizationKey: "Package_Hold_Enable_Action")
        ignoreHint.text = String(localizationKey: "Showcase_Ignore_Hint")
        for label in [controlsHeading, ignoreLabel, ignoreHint] {
            label.font = .preferredFont(forTextStyle: label === ignoreHint ? .caption1 : .headline)
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.textColor = label === ignoreHint ? .secondaryLabel : .label
            controlsCard.addSubview(label)
        }
        ignoreSwitch.accessibilityLabel = ignoreLabel.text
        ignoreSwitch.accessibilityHint = ignoreHint.text
        ignoreSwitch.addTarget(self, action: #selector(changeShowcaseIgnore), for: .valueChanged)
        controlsCard.addSubview(ignoreSwitch)
        infoButton.setTitle(String(localizationKey: "Package_View_Info") + "  ›", for: .normal)
        infoButton.contentHorizontalAlignment = .leading
        infoButton.addTarget(self, action: #selector(openShowcaseInfo), for: .touchUpInside)
        controlsCard.addSubview(infoButton)
        uninstallButton.setTitle(String(localizationKey: "Package_Uninstall_Action"), for: .normal)
        uninstallButton.setTitleColor(.systemRed, for: .normal)
        uninstallButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.1)
        uninstallButton.addTarget(self, action: #selector(uninstallShowcase), for: .touchUpInside)
        actionDock.contentView.addSubview(uninstallButton)
        for button in [infoButton, uninstallButton] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
        }
        for name in [PackageListManager.stateChange, PackageListManager.prefsNotification, DownloadManager.lockStateChangeNotification, PackageQueueButton.actionPerformedNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshShowcaseControls), name: name, object: nil)
        }
        actionDock.layer.cornerRadius = 26
        actionDock.clipsToBounds = true
        view.addSubview(actionDock)
        versionButton.contentHorizontalAlignment = .leading
        versionButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        versionButton.titleLabel?.adjustsFontForContentSizeCategory = true
        versionButton.titleLabel?.numberOfLines = 0
        versionButton.setImage(UIImage(systemName: "chevron.up.chevron.down"), for: .normal)
        versionButton.addTarget(self, action: #selector(selectShowcaseVersion), for: .touchUpInside)
        downloadOnlyButton.setImage(UIImage(systemName: "arrow.down.to.line"), for: .normal)
        downloadOnlyButton.accessibilityLabel = String(localizationKey: "Showcase_Download_Only")
        downloadOnlyButton.isEnabled = true
        downloadOnlyButton.addTarget(self, action: #selector(downloadShowcasePackage), for: .touchUpInside)
        actionDock.contentView.addSubview(versionButton)
        actionDock.contentView.addSubview(downloadOnlyButton)
        showcaseTaskButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        showcaseTaskButton.titleLabel?.adjustsFontForContentSizeCategory = true
        showcaseTaskButton.titleLabel?.numberOfLines = 3
        showcaseTaskButton.titleLabel?.lineBreakMode = .byTruncatingTail
        showcaseTaskButton.contentHorizontalAlignment = .leading
        showcaseTaskButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        showcaseTaskButton.backgroundColor = .secondarySystemGroupedBackground
        showcaseTaskButton.layer.cornerRadius = 18
        showcaseTaskButton.addTarget(self, action: #selector(openShowcaseTasks), for: .touchUpInside)
        view.addSubview(showcaseTaskButton)
        updateShowcaseTaskVisibility(showcaseTaskVisible)
        headerObservation = depictionBackgroundView.observe(\.image, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.view.setNeedsLayout() }
        }
        showcaseReady = true
        updateSileoColors()
    }

    @objc private func changeShowcaseIgnore() {
        downloadButton.setShowcaseUpdatesIgnored(ignoreSwitch.isOn)
        refreshShowcaseControls()
    }

    @objc private func openShowcaseInfo() { downloadButton.showShowcasePackageInfo() }
    @objc private func uninstallShowcase() { downloadButton.uninstallShowcasePackage() }

    @objc private func refreshShowcaseControls() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshShowcaseControls() }
            return
        }
        guard showcaseReady, let package = package else { return }
        let busy = DownloadManager.shared.queueRunning || DownloadManager.shared.find(package: package) != .none
        let provisional = package.isProvisional ?? false
        uninstallButton.isHidden = busy || PackageListManager.shared.installedPackage(identifier: package.package) == nil
        ignoreSwitch.isOn = downloadButton.ignoresShowcaseUpdates
        ignoreSwitch.isEnabled = !busy && !provisional
        infoButton.isEnabled = !provisional
        versionButton.isEnabled = !busy && !provisional
        downloadOnlyButton.isEnabled = !provisional
        downloadButton.updateInfo()
        view.setNeedsLayout()
    }

    @objc private func selectShowcaseVersion() {
        downloadButton.selectPackageVersion { [weak self] selected in
            self?.show(package: selected)
        }
    }

    @objc private func downloadShowcasePackage() {
        guard let package = package else { return }
        if package.local_deb == nil && (package.fromStatusFile || package.filename == nil || package.sourceRepo == nil) {
            downloadButton.selectPackageVersion { [weak self] selected in
                guard let self = self else { return }
                self.show(package: selected)
                self.downloadButton.downloadDeb(selected)
            }
        } else {
            downloadButton.downloadDeb(package)
        }
    }

    private func updateShowcase(_ package: Package) {
        summaryLabel.text = package.description ?? String(localizationKey: "Package_No_Description_Available")
        let source = package.sourceRepo.map { RepoManager.shared.getUniqueName(repo: $0) }
        versionButton.setTitle([package.version, source].compactMap { $0 }.joined(separator: " · "), for: .normal)
        versionButton.accessibilityLabel = String(localizationKey: "Package_Choose_Version")
        versionButton.accessibilityValue = versionButton.title(for: .normal)
        view.setNeedsLayout()
    }

    private var allowNavbarUpdates = false
    private var currentNavBarOpacity = CGFloat(0)
    
    private func parseNativeDepiction(_ data: Data, host: String, generation: UUID, failureCallback: (() -> Void)?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.parseNativeDepiction(data, host: host, generation: generation, failureCallback: failureCallback)
            }
            return
        }
        guard generation == contentGeneration else { return }
        guard let rawJSON = try? JSONSerialization.jsonObject(with: data, options: []),
              let rawDepict = rawJSON as? [String: Any]
        else {
            failureCallback?()
            return
        }
        
        if let rawTintColor = rawDepict["tintColor"] as? String, let tintColor = UIColor(css: rawTintColor) {
            self.depictionFooterView?.tintColor = tintColor
            self.downloadButton.tintColor = tintColor
            self.downloadButton.updateStyle()
            self.navBarDownloadButton?.tintColor = tintColor
            self.navBarDownloadButton?.updateStyle()
        }
        
        let oldDepictView = self.depictionView
        guard let newDepictView = DepictionBaseView.view(dictionary: rawDepict, viewController: self, tintColor: nil, isActionable: false) else {
            return
        }
        
        oldDepictView?.delegate = nil
        newDepictView.delegate = self
        
        if let imageURL = rawDepict["headerImage"] as? String {
            if imageURL != headerURL {
                self.headerURL = imageURL
                EvanderNetworking.image(url: imageURL, size: showcaseHeaderSize, condition: ({ [weak self] in self?.headerURL == imageURL && self?.contentGeneration == generation}), imageView: depictionBackgroundView)
            }
        }
        
        newDepictView.alpha = 0.1
        self.depictionView = newDepictView
        self.contentView.addSubview(newDepictView)
        self.view.setNeedsLayout()
        
        FRUIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25, animations: {
            oldDepictView?.alpha = 0
            newDepictView.alpha = 1
        }, completion: { [weak self] _ in
            oldDepictView?.removeFromSuperview()
            guard let self = self, self.contentGeneration == generation else { return }
            if let minVersion = rawDepict["minVersion"] as? String,
                minVersion.compare(StoreVersion) == .orderedDescending {
                self.versionTooLow()
            }
        })
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        weakNavController = self.navigationController
        
        weak var weakSelf = self
        NotificationCenter.default.addObserver(weakSelf as Any,
                                               selector: #selector(updateSileoColors),
                                               name: SileoThemeManager.sileoChangedThemeNotification,
                                               object: nil)
        
        packageName.textColor = .sileoLabel
        let collapsed = splitViewController?.isCollapsed ?? false
        let navController = collapsed ? (splitViewController?.viewControllers[0] as? UINavigationController) : self.navigationController
        navController?.setNavigationBarHidden(true, animated: true)

        self.navigationItem.largeTitleDisplayMode = .never
        scrollView.delegate = self
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(PackageViewController.reloadData),
                                               name: PackageListManager.reloadNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(PackageViewController.reloadData),
                                               name: PackageListManager.installChange,
                                               object: nil)

        packageIconView.layer.cornerRadius = 15

        self.extendedLayoutIncludesOpaqueBars = true
        self.edgesForExtendedLayout = [.top, .bottom]

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: self.tabBarController?.tabBar.bounds.height ?? 0, right: 0)

        allowNavbarUpdates = true
        depictionHeaderImageViewHeight.constant = 200
        self.navigationController?.navigationBar._backgroundOpacity = 0
        self.navigationController?.navigationBar.tintColor = .white
        self.statusBarStyle = .lightContent
        
        self.navigationController?.navigationBar.isTranslucent = true
        
        downloadButton.viewControllerForPresentation = self
        
        let navBarDownloadButton = PackageQueueButton()
        navBarDownloadButton.viewControllerForPresentation = self
        self.navBarDownloadButton = navBarDownloadButton

        let shareButton = UIButton(type: .custom)
        shareButton.setImage(UIImage(named: "More"), for: .normal)
        if #available(iOS 14.0, *) {
            // A tap opens the system's own menu (see installShareMenu).
        } else {
            shareButton.addTarget(self, action: #selector(PackageViewController.sharePackage), for: .touchUpInside)
        }
        shareButton.accessibilityIgnoresInvertColors = true
        self.shareButton = shareButton
        if #available(iOS 14.0, *) {
            installShareMenu()
        }

        navBarDownloadButton.alpha = 0

        navBarDownloadButtonItem = UIBarButtonItem(customView: navBarDownloadButton)
        let navBarShareButtonItem = UIBarButtonItem(customView: shareButton)
        self.navBarShareButtonItem = navBarShareButtonItem

        self.navigationItem.rightBarButtonItems = [navBarShareButtonItem]

        let packageNavBarIconViewController = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 50, height: 32)))

        let packageNavBarIconView = PackageIconView(frame: CGRect(origin: .zero, size: CGSize(width: 32, height: 32)))
        packageNavBarIconView.center = packageNavBarIconViewController.center
        packageNavBarIconView.alpha = 0
        self.packageNavBarIconView = packageNavBarIconView

        packageNavBarIconViewController.addSubview(packageNavBarIconView)
        self.navigationItem.titleView = packageNavBarIconViewController

        if self.isPresentedModally {
            self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: String(localizationKey: "Done"),
                                                                    style: .done,
                                                                    target: self,
                                                                    action: #selector(PackageViewController.dismissImmediately))
            
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(PackageViewController.dismissImmediately),
                                                   name: PackageQueueButton.actionPerformedNotification,
                                                   object: nil)
            
            downloadButton.NoAnimation = true
            navBarDownloadButton.NoAnimation = true
        }

        configureShowcase()
        self.reloadData()
        
        if let package=self.package {
            CanisterResolver.shared.ingest(packages: [package])
        }
    }

    @objc func updateSileoColors() {
        packageName.textColor = .sileoLabel
        guard showcaseReady else { return }
        view.backgroundColor = .systemGroupedBackground
        contentView.backgroundColor = .systemGroupedBackground
        for card in [summaryCard, detailsCard, managementCard, controlsCard] {
            card.backgroundColor = .secondarySystemGroupedBackground
        }
        actionDock.layer.borderWidth = 0.5
        actionDock.layer.borderColor = UIColor.separator.withAlphaComponent(0.25).cgColor
    }
    
    private var savedProvisional: Package?
    
    @objc func reloadData() {
        NSLog("SileoLog: PackageViewController.reloadData")
        guard Thread.current.isMainThread else {
            DispatchQueue.main.async {
                self.reloadData()
            }
            return
        }
        
        defer {
            self.view.layoutIfNeeded()
        }
        
        contentGeneration = UUID()
        let generation = contentGeneration
        headerURL = nil
        depictionBackgroundView.image = nil
        downloadButton.tintColor = view.tintColor
        navBarDownloadButton?.tintColor = view.tintColor
        downloadButton.updateStyle()
        navBarDownloadButton?.updateStyle()
        depictionView?.delegate = nil
        depictionView?.removeFromSuperview()
        depictionView = nil
        
        if let package=package, let source=package.source, package.isProvisional ?? false {
            if let repo = RepoManager.shared.repo(with: source.uri, suite: source.suite, components: source.component?.components(separatedBy: .whitespaces) )
            {
                if let newPackage = PackageListManager.shared.newestPackage(identifier: package.package, repoContext: repo) {
                    self.savedProvisional = self.package
                    self.package = newPackage
                }
            }
        }
        
        if let package=package, package.fromStatusFile {
            if let newInstalled = PackageListManager.shared.installedPackage(identifier: package.package) {
                self.package = newInstalled
            }
        }

        guard var package = self.package else {
            return
        }
        
        if let backup = self.savedProvisional, package.sourceRepo==nil {
            package = backup
            self.package = backup
            self.savedProvisional = nil
        }

        let installedPackage = PackageListManager.shared.installedPackage(identifier: package.package)
        self.installedPackage = installedPackage

        packageName.text = package.name
        packageAuthor.text = package.author?.name ?? ""
        updatePackageSize(package)
        updateShowcase(package)

        downloadButton.package = package
        refreshShowcaseControls()
        navBarDownloadButton?.package = package
        
        self.updatePaymentInfo()
        
        if let imageURL = package.rawControl["header"] {
            if imageURL != headerURL {
                self.headerURL = imageURL
                EvanderNetworking.image(url: imageURL, size: showcaseHeaderSize, condition: ({ [weak self] in self?.headerURL == imageURL && self?.contentGeneration == generation }), imageView: depictionBackgroundView)
            }
        }
        
        if package.hasIcon(),
            let rawIcon = package.icon {
            EvanderNetworking.image(url: rawIcon, size: packageIconView.frame.size, condition: ({ [weak self] in self?.package?.icon == rawIcon && self?.contentGeneration == generation}), imageViews: [packageIconView, packageNavBarIconView], fallback: package.defaultIcon)
        } else {
            packageNavBarIconView?.image = package.defaultIcon
            packageIconView.image = package.defaultIcon
        }

        var rawDescription: [[String: Any]] = [
            [
                "class": "DepictionMarkdownView",
                "markdown": package.description ?? String(localizationKey: "Package_No_Description_Available"),
                "useSpacing": true
            ]
        ]

        if package.sileoDepiction == nil,
            let legacyDepiction = package.legacyDepiction {
            rawDescription.append([
                "class": "DepictionTableButtonView",
                "title": String(localizationKey: "View_Depiction"),
                "action": legacyDepiction.absoluteString
            ] as [String: Any])
        }

        let rawDepiction = package.sourceRepo==nil ? [
            "class": "DepictionStackView",
            "views": [
                [
                    "class": "DepictionHeaderView",
                    "title": String(localizationKey: "Package_Details_Tab"),
                    "useBoldText" : true,
//                    "fontSize" : 17
                ],
                ["class": "DepictionSeparatorView"],
            ] + rawDescription
        ] : [
            "class": "DepictionTabView",
            "tabs": [
                [
                    "tabname": String(localizationKey: "Package_Details_Tab"),
                    "class": "DepictionStackView",
                    "views": rawDescription
                ], [
                    "tabname": String(localizationKey: "Package_Changelog_Tab"),
                    "class": "DepictionStackView",
                    "views": [[
                        "class": "DepictionMarkdownView",
                        "markdown": String(localizationKey: "Package_Changelogs_Unavailable"),
                        "useSpacing": true
                    ]]
                ]
            ]
        ] as [String: Any]

        if let depictionView = DepictionBaseView.view(dictionary: rawDepiction, viewController: self, tintColor: nil, isActionable: false) {
            depictionView.delegate = self
            contentView.addSubview(depictionView)
            self.depictionView = depictionView
        }

        if !package.fromStatusFile,
            let depiction = package.sileoDepiction {
            let urlRequest = URLManager.urlRequest(depiction)
            EvanderNetworking.request(request: urlRequest, type: Data.self) { [weak self] success, _, _, data in
                guard success,
                      let data = data,
                      let `self` = self else { return }
                if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    PackageSearchIndex.shared.capture(json, for: package)
                }
                self.parseNativeDepiction(data, host: depiction.host ?? "", generation: generation, failureCallback: nil)
            }
        }

        self.reloadFooter(package: package, installedPackage: installedPackage)
    }

    private func reloadFooter(package: Package, installedPackage: Package?) {
        var footerViews = [[String: Any]]()
        if let installedPackage = installedPackage {
            footerViews.append(contentsOf: [
                [
                    "class": "DepictionSeparatorView"
                ],
                [
                    "class": "DepictionHeaderView",
                    "title": String(localizationKey: "Installed_Package_Header")
                ],
                [
                    "class": "DepictionTableTextView",
                    "title": String(localizationKey: "Version"),
                    "text": installedPackage.version
                ],
                [
                    "class": "DepictionTableButtonView",
                    "title": String(localizationKey: "Show_Package_Contents_Button"),
                    "action": "showInstalledContents"
                ],
                [
                    "class": "DepictionSeparatorView"
                ]
            ])
        }
        
        if let repo = package.sourceRepo {
            footerViews.insert([
                "class": "DepictionSeparatorView"
            ], at: 0)
            footerViews.insert([
                "class": "DepictionHeaderView",
                "title": String(localizationKey: "Repo")
            ], at: 1)
            footerViews.insert([
                "class": "DepictionTableButtonView",
                "title": RepoManager.shared.getUniqueName(repo: repo),
                "action": "showRepoContext",
                "context": repo as Any,
                "_repo": repo.url?.absoluteString as Any
            ], at: 2)
        }
        else if package.fromStatusFile {
            
            var repoPackages: [Package] = []
            for repo in RepoManager.shared.repoList {
                if let repoPackage = repo.newestPackage(identifier: package.package, ignoreArch: true) {
                    repoPackages.append(repoPackage)
                }
            }
            
            repoPackages = PackageListManager.shared.sortPackages(packages: repoPackages, search: nil)
            
            if repoPackages.count > 0
            {
                footerViews.insert([
                    "class": "DepictionSeparatorView"
                ], at: 0)
                footerViews.insert([
                    "class": "DepictionHeaderView",
                    "title": String(localizationKey: "Repo")
                ], at: 1)
                
                var viewIndex = 2
                for package in repoPackages {
                    guard let repo = package.sourceRepo else {
                        continue
                    }
                    footerViews.insert([
                        "class": "DepictionTableTextButtonView",
                        "title": repo.displayName,
                        "text": package.version,
                        "action": "showPackage",
                        "context": package as Any,
                    ], at: viewIndex++)
                }
            }
        }
        else if let source=package.source, package.isProvisional ?? false {
            var url: String

            if source.suite == "./" {
                url = source.uri.absoluteString
            } else if let component = source.component {
                url = source.uri.appendingPathComponent("dists").appendingPathComponent(source.suite).appendingPathComponent(component).absoluteString
            } else {
                url = "Invalid"
            }
                
            footerViews.insert([
                "class": "DepictionSeparatorView"
            ], at: 0)
            footerViews.insert([
                "class": "DepictionHeaderView",
                "title": String(localizationKey: "Repo")
            ], at: 1)
            footerViews.insert([
                "class": "DepictionSubheaderView",
                "useBoldText": true,
                "title": url
            ], at: 2)
        }
        
        footerViews.append([
            "class": "DepictionSubheaderView",
            "alignment": 1,
            "useBottomMargin": false,
            "title": package.fromStatusFile ? "\(package.package)" : "\(package.package) (\(package.version))"
        ])
        
        if let architecture = package.architecture, !architecture.isEmpty {
            footerViews.append([
                "class": "DepictionSubheaderView",
                "alignment": 1,
                "useMargins": false,
                "title": String(format: String(localizationKey: "Package_Architecture"), architecture)
            ])
        }
        
        let footerDict = [
            "class": "DepictionStackView",
            "views": footerViews
        ] as [String: Any]

        
        depictionFooterView?.removeFromSuperview()
        depictionFooterView = nil
        
        if let depictionFooterView = DepictionBaseView.view(dictionary: footerDict, viewController: self, tintColor: nil, isActionable: false) {
            depictionFooterView.delegate = self
            self.depictionFooterView = depictionFooterView
            contentView.addSubview(depictionFooterView)
        }

    }

    // Source and version are part of content identity, not only the package identifier.
    func show(package: Package) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.show(package: package) }
            return
        }
        self.package = package
        loadViewIfNeeded()
        reloadData()
    }

    func versionTooLow() {
        let alertController = UIAlertController(title: String(localizationKey: "Sileo_Update_Required.Title", type: .error),
                                                message: String(localizationKey: "Featured_Requires_Sileo_Update", type: .error),
                                                preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: String(localizationKey: "OK"), style: .cancel, handler: { _ in
            self.dismiss(animated: true, completion: nil)
        }))
        self.present(alertController, animated: true, completion: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        TabBarController.singleton?.setShowcaseHost(self, active: true)
        
        self.statusBarStyle = .default
        
        self.navigationController?.navigationBar._backgroundOpacity = currentNavBarOpacity
        self.navigationController?.navigationBar.tintColor = .white
        allowNavbarUpdates = true
        self.scrollViewDidScroll(self.scrollView)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        TabBarController.singleton?.setShowcaseHost(self, active: false)
        
        let collapsed = splitViewController?.isCollapsed ?? false
        let navController = collapsed ? (splitViewController?.viewControllers[0] as? UINavigationController) : weakNavController
        
        allowNavbarUpdates = false
        currentNavBarOpacity = navController?.navigationBar._backgroundOpacity ?? 1
        
        FRUIView.animate(withDuration: 0.8) {
            navController?.navigationBar.tintColor = UINavigationBar.appearance().tintColor
            navController?.navigationBar._backgroundOpacity = 1
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if showcaseReady {
            guard allowNavbarUpdates else { return }
            navigationController?.setNavigationBarHidden(false, animated: false)
            navigationController?.navigationBar._backgroundOpacity = 1
            navigationController?.navigationBar.tintColor = view.tintColor
            shareButton?.alpha = 1
            packageNavBarIconView?.alpha = scrollView.contentOffset.y > 90 ? 1 : 0
            if let item = navBarShareButtonItem { navigationItem.rightBarButtonItems = [item] }
            statusBarStyle = .default
            return
        }
        // do header view scaling magic
        let headerBounds = depictionHeaderView.bounds
        var aspectRatio = headerBounds.width / headerBounds.height
        if headerBounds.height == 0 {
            aspectRatio = 0
        }

        var offset = scrollView.contentOffset.y
        if offset > 0 {
            offset = 0
        }

        var headerBackgroundFrame = CGRect.zero
        headerBackgroundFrame.size.height = headerBounds.height - offset
        headerBackgroundFrame.size.width = headerBackgroundFrame.height * aspectRatio
        headerBackgroundFrame.origin.x = (headerBounds.width - headerBackgroundFrame.width)/2
        headerBackgroundFrame.origin.y = headerBounds.height - headerBackgroundFrame.height

        depictionBackgroundView.frame = headerBackgroundFrame
        depictionBackgroundShadow.frame = headerBackgroundFrame

        // doing the magic on the nav bar "GET" button and package icon
        let downloadButtonPos = downloadButton.convert(downloadButton.bounds, to: scrollView)
        let container = CGRect(origin: CGPoint(x: scrollView.contentOffset.x,
                                               y: scrollView.contentOffset.y + 106 - UIApplication.shared.statusBarFrame.height),
                               size: scrollView.frame.size)
        // TLDR: magic starts when scrolling out the lower half of the button so we don't have duplicated button too early
        var navBarAlphaOffset = scrollView.contentOffset.y * 1.75 / depictionHeaderImageViewHeight.constant
        if depictionHeaderImageViewHeight.constant == 0 {
            navBarAlphaOffset = 0
        }

        if navBarAlphaOffset > 1 {
            navBarAlphaOffset = 1
        } else if navBarAlphaOffset < 0 {
            navBarAlphaOffset = 0
        }

        FRUIView.animate(withDuration: 0.3) {
            self.shareButton?.alpha = 1 - navBarAlphaOffset

            if (self.shareButton?.alpha ?? 0) > 0 {
                self.packageNavBarIconView?.alpha = 0
            } else {
                self.packageNavBarIconView?.alpha = downloadButtonPos.intersects(container) ? 0 : 1
            }
            self.navBarDownloadButton?.customAlpha = self.packageNavBarIconView?.alpha ?? 0

            if let navBarDownloadButtonItem = self.navBarDownloadButtonItem,
                let navBarShareButtonItem = self.navBarShareButtonItem {
                if (self.shareButton?.alpha ?? 0) > 0 {
                    self.navigationItem.rightBarButtonItems = [navBarShareButtonItem]
                } else {
                    self.navigationItem.rightBarButtonItems = [navBarDownloadButtonItem]
                }
            }
        }

        scrollView.scrollIndicatorInsets.top = max(headerBounds.maxY - scrollView.contentOffset.y, self.view.safeAreaInsets.top)

        guard allowNavbarUpdates else {
            return
        }
        
        let collapsed = splitViewController?.isCollapsed ?? false
        let navController = collapsed ? (splitViewController?.viewControllers[0] as? UINavigationController) : self.navigationController
        navController?.setNavigationBarHidden(false, animated: true)
        if navBarAlphaOffset < 1 {
            var tintColor = UINavigationBar.appearance().tintColor
            if let color = self.depictionView?.tintColor {
                tintColor = color
            }
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            tintColor?.getRed(&red, green: &green, blue: &blue, alpha: nil)

            if UIAccessibility.isInvertColorsEnabled {
                red -= red * (1.0 - navBarAlphaOffset)
                green -= green * (1.0 - navBarAlphaOffset)
                blue -= blue * (1.0 - navBarAlphaOffset)
            } else {
                red += (1.0 - red) * (1.0 - navBarAlphaOffset)
                green += (1.0 - green) * (1.0 - navBarAlphaOffset)
                blue += (1.0 - blue) * (1.0 - navBarAlphaOffset)
            }
            tintColor = UIColor(red: red, green: green, blue: blue, alpha: 1)

            navController?.navigationBar.tintColor = tintColor
            navController?.navigationBar._backgroundOpacity = navBarAlphaOffset
            if navBarAlphaOffset < 0.75 {
                self.statusBarStyle = .lightContent
            } else {
                self.statusBarStyle = .default
            }
        } else {
            navController?.navigationBar.tintColor = UINavigationBar.appearance().tintColor
            if let tintColor = self.depictionView?.tintColor {
                navController?.navigationBar.tintColor = tintColor
            }
            navController?.navigationBar._backgroundOpacity = 1
            self.statusBarStyle = .default
        }
        self.setNeedsStatusBarAppearanceUpdate()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if showcaseReady { return }
        // for those wondering about the magic numbers and what's going on here:
        // This is the spring effect on scrolling (aka step to start or step to after header
        // 113 = header imageView height - nav bar height and 56 is simply for setitng the step boundary, aka halfway
        // if you don't like this, we can implement the variables from above, instead, but imo it's a waste of time
        let scrollViewOffset = scrollView.contentOffset.y + UIApplication.shared.statusBarFrame.height
        
        if scrollViewOffset < 66 {
            scrollView.setContentOffset(.zero, animated: true)
        } else if scrollViewOffset > 66 && scrollViewOffset < 133 {
            scrollView.setContentOffset(CGPoint(x: 0, y: 156 - UIApplication.shared.statusBarFrame.height), animated: true)
        }
    }

    func subviewHeightChanged() {
        NSLog("SileoLog: PackageViewController.subviewHeightChanged")
        self.view.setNeedsLayout()
        self.view.layoutIfNeeded()
    }

    private func layoutShowcase() {
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        let horizontalSafe = max(view.safeAreaInsets.left, view.safeAreaInsets.right)
        let bodyWidth = max(1, min(720, width - 40 - horizontalSafe * 2))
        let x = (width - bodyWidth) / 2
        let accessible = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        packageInfoView.axis = accessible ? .vertical : .horizontal
        packageInfoView.alignment = accessible ? .leading : .top
        var y: CGFloat = 20
        let identityHeight = packageInfoView.systemLayoutSizeFitting(
            CGSize(width: bodyWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        packageInfoView.frame = CGRect(x: x, y: y, width: bodyWidth, height: max(72, identityHeight))
        y = packageInfoView.frame.maxY + 24
        let hasHeader = depictionBackgroundView.image != nil
        depictionHeaderView.isHidden = !hasHeader
        if hasHeader {
            depictionHeaderView.frame = CGRect(x: x, y: y, width: bodyWidth, height: min(320, bodyWidth * 0.68))
            depictionBackgroundView.frame = depictionHeaderView.bounds
            y = depictionHeaderView.frame.maxY + 24
        }
        let textWidth = max(1, bodyWidth - 40)
        let headingHeight = summaryHeading.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let summaryHeight = summaryLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        summaryHeading.frame = CGRect(x: 20, y: 20, width: textWidth, height: headingHeight)
        summaryLabel.frame = CGRect(x: 20, y: 32 + headingHeight, width: textWidth, height: summaryHeight)
        summaryCard.frame = CGRect(x: x, y: y, width: bodyWidth, height: 52 + headingHeight + summaryHeight)
        y = summaryCard.frame.maxY + 24
        // The native depiction owns its original tabs, changelog parser, links and actions.
        // Only its surrounding presentation changes here.
        depictionHeight = depictionView?.depictionHeight(width: bodyWidth) ?? 0
        detailsCard.frame = CGRect(x: x, y: y, width: bodyWidth, height: depictionHeight + 16)
        detailsCard.isHidden = depictionView == nil
        depictionView?.frame = CGRect(x: x, y: y + 8, width: bodyWidth, height: depictionHeight)
        if let depictionView = depictionView { contentView.bringSubviewToFront(depictionView) }
        y = detailsCard.frame.maxY + 24
        let footerHeight = depictionFooterView?.depictionHeight(width: bodyWidth) ?? 0
        managementCard.frame = CGRect(x: x, y: y, width: bodyWidth, height: footerHeight + 16)
        managementCard.isHidden = depictionFooterView == nil
        depictionFooterView?.frame = CGRect(x: x, y: y + 8, width: bodyWidth, height: footerHeight)
        if let footer = depictionFooterView { contentView.bringSubviewToFront(footer) }
        y = managementCard.frame.maxY + 24
        let controlsWidth = max(1, bodyWidth - 40)
        let headingH = controlsHeading.sizeThatFits(CGSize(width: controlsWidth, height: .greatestFiniteMagnitude)).height
        controlsHeading.frame = CGRect(x: 20, y: 20, width: controlsWidth, height: headingH)
        let switchSize = ignoreSwitch.sizeThatFits(.zero)
        let labelWidth = max(1, controlsWidth - switchSize.width - 16)
        let ignoreH = ignoreLabel.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height
        let hintH = ignoreHint.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height
        let rowY = controlsHeading.frame.maxY + 16
        ignoreLabel.frame = CGRect(x: 20, y: rowY, width: labelWidth, height: ignoreH)
        ignoreHint.frame = CGRect(x: 20, y: ignoreLabel.frame.maxY + 6, width: labelWidth, height: hintH)
        let rowH = max(44, ignoreH + 6 + hintH)
        ignoreSwitch.frame = CGRect(x: bodyWidth - 20 - switchSize.width, y: rowY + (rowH - switchSize.height) / 2, width: switchSize.width, height: switchSize.height)
        let infoH = max(52, infoButton.sizeThatFits(CGSize(width: controlsWidth, height: .greatestFiniteMagnitude)).height + 16)
        infoButton.frame = CGRect(x: 20, y: rowY + rowH + 12, width: controlsWidth, height: infoH)
        controlsCard.frame = CGRect(x: x, y: y, width: bodyWidth, height: infoButton.frame.maxY + 12)
        y = controlsCard.frame.maxY + 24
        contentViewWidth.constant = width
        contentViewHeight.constant = y
        scrollView.contentSize = CGSize(width: width, height: y)

        let dockWidth = max(1, min(720, width - 24 - horizontalSafe * 2))
        let actualVersionWidth = max(44, dockWidth - 84)
        let actualVersionHeight = max(44, versionButton.sizeThatFits(CGSize(width: actualVersionWidth, height: .greatestFiniteMagnitude)).height)
        let uninstallWidth = uninstallButton.isHidden ? 0 : min((dockWidth - 32) * 0.38, max(76, uninstallButton.intrinsicContentSize.width + 24))
        let primaryWidth = dockWidth - 24 - (uninstallButton.isHidden ? 0 : uninstallWidth + 8)
        let primaryHeight = max(50, max(downloadButton.sizeThatFits(CGSize(width: primaryWidth, height: .greatestFiniteMagnitude)).height + 12,
                                       uninstallButton.isHidden ? 0 : uninstallButton.sizeThatFits(CGSize(width: uninstallWidth, height: .greatestFiniteMagnitude)).height + 12))
        let dockHeight = actualVersionHeight + primaryHeight + 32
        let bottom = view.safeAreaInsets.bottom + max(0, showcaseBottomObstruction) + 8
        actionDock.frame = CGRect(x: (width - dockWidth) / 2,
                                  y: view.bounds.height - bottom - dockHeight,
                                  width: dockWidth, height: dockHeight)
        versionButton.frame = CGRect(x: 16, y: 12, width: actualVersionWidth, height: actualVersionHeight)
        downloadOnlyButton.frame = CGRect(x: dockWidth - 60, y: 12, width: 44, height: actualVersionHeight)
        uninstallButton.frame = CGRect(x: 12, y: actualVersionHeight + 20, width: uninstallWidth, height: primaryHeight)
        uninstallButton.layer.cornerRadius = min(22, primaryHeight / 2)
        downloadButton.frame = CGRect(x: dockWidth - primaryWidth - 12, y: actualVersionHeight + 20, width: primaryWidth, height: primaryHeight)
        let taskHeight = showcaseTaskVisible
            ? max(44, showcaseTaskButton.sizeThatFits(CGSize(width: dockWidth, height: .greatestFiniteMagnitude)).height) : 0
        let taskSpace = showcaseTaskVisible ? taskHeight + 8 : 0
        showcaseTaskButton.frame = CGRect(x: actionDock.frame.minX,
                                          y: actionDock.frame.minY - taskSpace,
                                          width: dockWidth, height: taskHeight)
        scrollView.contentInset = UIEdgeInsets(top: view.safeAreaInsets.top, left: 0,
                                              bottom: bottom + dockHeight + taskSpace + 20, right: 0)
        scrollView.scrollIndicatorInsets = scrollView.contentInset
        if !positionedShowcaseAtTop, view.window != nil {
            positionedShowcaseAtTop = true
            scrollView.contentOffset = CGPoint(x: 0, y: -scrollView.contentInset.top)
        }
        view.bringSubviewToFront(actionDock)
        view.bringSubviewToFront(showcaseTaskButton)
        TabBarController.singleton?.refreshShowcaseObstruction()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if showcaseReady { updateSileoColors(); view.setNeedsLayout() }
    }

    override func viewDidLayoutSubviews() {
        NSLog("SileoLog: PackageViewController.viewDidLayoutSubviews")
//        Thread.callStackSymbols.forEach{NSLog("SileoLog: viewDidLayoutSubviews callstack=\($0)")}
        
        super.viewDidLayoutSubviews()
        if showcaseReady {
            layoutShowcase()
            return
        }

        depictionHeight = depictionView?.depictionHeight(width: self.view.bounds.width) ?? 0

        let headerHeight = packageInfoView.frame.maxY

        depictionView?.frame = CGRect(x: 0, y: headerHeight, width: self.view.bounds.width, height: depictionHeight)

        let footerHeight = depictionFooterView?.depictionHeight(width: self.view.bounds.width) ?? 0
        depictionFooterView?.frame = CGRect(x: 0, y: headerHeight + depictionHeight, width: self.view.bounds.width, height: footerHeight)

        contentView.frame = CGRect(origin: .zero, size: CGSize(width: self.view.bounds.width, height: headerHeight + depictionHeight + footerHeight))
        scrollView.contentSize = CGSize(width: self.view.bounds.width, height: headerHeight + depictionHeight + footerHeight)

        contentViewWidth.constant = scrollView.bounds.width
        contentViewHeight.constant = headerHeight + depictionHeight + footerHeight

        self.view.updateConstraintsIfNeeded()

        scrollView.contentSize = CGSize(width: scrollView.contentSize.width, height: contentViewHeight.constant)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
            self.scrollViewDidScroll(self.scrollView)
        }
    }

    @objc func sharePackage(_ sender: Any?) {
        guard let package = self.package,
            let shareButton = self.shareButton else {
            return
        }

        let sharePopup = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let shareAction = UIAlertAction(title: String(localizationKey: "Package_Share_Action"), style: .default) { _ in
            var packageString = "\(package.name ?? package.package) - \(URLManager.url(package: package.package))"
            if let repo = package.sourceRepo {
                packageString += " - from \(repo.url?.absoluteString ?? repo.rawURL)"
            }
            let activityViewController = UIActivityViewController(activityItems: [packageString], applicationActivities: nil)
            activityViewController.popoverPresentationController?.sourceView = shareButton
            self.present(activityViewController, animated: true, completion: nil)
        }
        sharePopup.addAction(shareAction)

        if let author = package.author {
            if let name = author.name {
                let moreByDeveloper = UIAlertAction(title: String(localizationKey: "Package_Developer_Find_Action"), style: .default) { _ in
                    let packagesListController = PackageListViewController(nibName: "PackageListViewController", bundle: nil)
                    packagesListController.packagesLoadIdentifier = "author:\(name)"
                    packagesListController.title = String(format: String(localizationKey: "Packages_By_Author"),
                                                          author.name ?? "")
                    self.navigationController?.pushViewController(packagesListController, animated: true)
                }
                sharePopup.addAction(moreByDeveloper)
            }

            if let email = author.email {
                let packageSupport = UIAlertAction(title: String(localizationKey: "Package_Support_Action"), style: .default) { _ in
                    func unavailable() {
                        let alertController = UIAlertController(title: String(localizationKey: "Email_Unavailable.Title", type: .error),
                                                                message: String(localizationKey: "Email_Unavailable.Body", type: .error),
                                                                preferredStyle: .alert)
                        alertController.addAction(UIAlertAction(title: String(localizationKey: "OK"), style: .cancel, handler: nil))
                        self.present(alertController, animated: true, completion: nil)
                    }
                    guard let subject = "Sileo/APT(M): \(package.name ?? package.package)".addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
                          let email = email.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
                          let url = URL(string: "mailto:\(email)?subject=\(subject)") else {
                        return unavailable()
                    }
                    UIApplication.shared.open(url) { success in
                        if !success {
                            unavailable()
                        }
                    }
                }
                sharePopup.addAction(packageSupport)
            }
        }

        if let installedPackage = installedPackage, let package = self.package {
            let ignoreUpdatesText = installedPackage.wantInfo == .hold ?
                String(localizationKey: "Package_Hold_Disable_Action") : String(localizationKey: "Package_Hold_Enable_Action")
            let ignoreUpdates = UIAlertAction(title: ignoreUpdatesText, style: .default) { _ in
                do {
                    if installedPackage.wantInfo == .hold {
#if !targetEnvironment(simulator) && !TARGET_SIMULATOR
                        try DpkgWrapper.ignoreUpdates(false, package: package.package)
                        installedPackage.wantInfo = .install
#endif
                    } else {
#if !targetEnvironment(simulator) && !TARGET_SIMULATOR
                        try DpkgWrapper.ignoreUpdates(true, package: package.package)
                        installedPackage.wantInfo = .hold
#endif
                    }
                    NotificationCenter.default.post(Notification(name: PackageListManager.prefsNotification))
                } catch {
                    sharePopup.dismiss(animated: true) {
                        let alertController = UIAlertController(title: String(localizationKey: "Unknown", type: .error), message: "\(error)", preferredStyle: .alert)
                        alertController.addAction(UIAlertAction(title: String(localizationKey: "OK"), style: .cancel, handler: { _ in
                            self.dismiss(animated: true, completion: nil)
                        }))
                        self.present(alertController, animated: true, completion: nil)
                    }
                }
            }
            sharePopup.addAction(ignoreUpdates)
        }

        let wishListText = WishListManager.shared.isPackageInWishList(package.package) ?
            String(localizationKey: "Package_Wishlist_Remove") : String(localizationKey: "Package_Wishlist_Add")
        let wishlist = UIAlertAction(title: wishListText, style: .default) { _ in
            if WishListManager.shared.isPackageInWishList(package.package) {
                WishListManager.shared.removePackageFromWishList(package.package)
            } else {
                _ = WishListManager.shared.addPackageToWishList(package.package)
            }
        }
        sharePopup.addAction(wishlist)

        let cancelAction = UIAlertAction(title: String(localizationKey: "Cancel"), style: .cancel, handler: nil)
        sharePopup.addAction(cancelAction)

        if UIDevice.current.userInterfaceIdiom == .pad {
            sharePopup.popoverPresentationController?.sourceView = shareButton
        }
        if let tintColor = depictionView?.tintColor {
            sharePopup.view.tintColor = tintColor
        }
        self.present(sharePopup, animated: true)
    }

    /// The "…" opens the package's actions: the system's menu beside the button
    /// when hairlines are wanted, Sileo's own card when they are hidden. What it
    /// holds is worked out when it opens, never on every change of state.
    private func installShareMenu() {
        guard let shareButton = shareButton else { return }
        refreshShareMenu()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(refreshShareMenu),
                                               name: Notification.Name("HideSeparators"),
                                               object: nil)
    }

    @objc private func refreshShareMenu() {
        guard let shareButton = shareButton else { return }
        shareButton.removeTarget(self, action: #selector(presentShareCard(_:)), for: .touchUpInside)
        let attached = SileoActionMenu.attachMenu(to: shareButton, header: nil) { [weak self] in
            self?.shareMenuActions() ?? []
        }
        if !attached {
            shareButton.addTarget(self, action: #selector(presentShareCard(_:)), for: .touchUpInside)
        }
    }

    @objc private func presentShareCard(_ sender: UIButton) {
        guard let package = self.package else { return }
        SileoActionMenu.present(header: nil,
                                items: shareMenuActions(),
                                from: self,
                                source: sender,
                                sourceFrame: sender.convert(sender.bounds, to: nil))
    }

    private func shareMenuActions() -> [SileoActionMenuItem] {
        guard let package = self.package else { return [] }
        var actions: [SileoActionMenuItem] = [
            SileoActionMenuItem(title: String(localizationKey: "Package_Share_Action"),
                                imageName: "square.and.arrow.up") { [weak self] in
                self?.sharePackageLink()
            }
        ]

        if let name = package.author?.name {
            actions.append(SileoActionMenuItem(title: String(localizationKey: "Package_Developer_Find_Action"),
                                               imageName: "person.crop.circle") { [weak self] in
                self?.showPackagesByAuthor(name)
            })
        }

        if let email = package.author?.email {
            actions.append(SileoActionMenuItem(title: String(localizationKey: "Package_Support_Action"),
                                               imageName: "envelope") { [weak self] in
                self?.openSupportEmail(email)
            })
        }

        if let installedPackage = installedPackage {
            let title = installedPackage.wantInfo == .hold ?
                String(localizationKey: "Package_Hold_Disable_Action") : String(localizationKey: "Package_Hold_Enable_Action")
            actions.append(SileoActionMenuItem(title: title,
                                               imageName: "pause.circle") { [weak self] in
                self?.toggleIgnoringUpdates()
            })
        }

        let wishListText = WishListManager.shared.isPackageInWishList(package.package) ?
            String(localizationKey: "Package_Wishlist_Remove") : String(localizationKey: "Package_Wishlist_Add")
        actions.append(SileoActionMenuItem(title: wishListText,
                                           imageName: "heart") { [weak self] in
            self?.toggleWishList()
        })

        return actions
    }

    private func sharePackageLink() {
        guard let package = self.package else { return }
        var packageString = "\(package.name ?? package.package) - \(URLManager.url(package: package.package))"
        if let repo = package.sourceRepo {
            packageString += " - from \(repo.url?.absoluteString ?? repo.rawURL)"
        }
        let activityViewController = UIActivityViewController(activityItems: [packageString], applicationActivities: nil)
        if let shareButton = shareButton {
            activityViewController.popoverPresentationController?.sourceView = shareButton
            activityViewController.popoverPresentationController?.sourceRect = shareButton.bounds
        }
        self.present(activityViewController, animated: true, completion: nil)
    }

    private func showPackagesByAuthor(_ name: String) {
        let packagesListController = PackageListViewController(nibName: "PackageListViewController", bundle: nil)
        packagesListController.packagesLoadIdentifier = "author:\(name)"
        packagesListController.title = String(format: String(localizationKey: "Packages_By_Author"), name)
        self.navigationController?.pushViewController(packagesListController, animated: true)
    }

    private func openSupportEmail(_ email: String) {
        func unavailable() {
            let alertController = UIAlertController(title: String(localizationKey: "Email_Unavailable.Title", type: .error),
                                                    message: String(localizationKey: "Email_Unavailable.Body", type: .error),
                                                    preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: String(localizationKey: "OK"), style: .cancel, handler: nil))
            self.present(alertController, animated: true, completion: nil)
        }
        guard let package = self.package,
              let subject = "Sileo/APT(M): \(package.name ?? package.package)".addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
              let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
              let url = URL(string: "mailto:\(encodedEmail)?subject=\(subject)") else {
            return unavailable()
        }
        UIApplication.shared.open(url) { success in
            if !success {
                unavailable()
            }
        }
    }

    private func toggleIgnoringUpdates() {
        guard let installedPackage = installedPackage, let package = self.package else { return }
        do {
            if installedPackage.wantInfo == .hold {
#if !targetEnvironment(simulator) && !TARGET_SIMULATOR
                try DpkgWrapper.ignoreUpdates(false, package: package.package)
                installedPackage.wantInfo = .install
#endif
            } else {
#if !targetEnvironment(simulator) && !TARGET_SIMULATOR
                try DpkgWrapper.ignoreUpdates(true, package: package.package)
                installedPackage.wantInfo = .hold
#endif
            }
            NotificationCenter.default.post(Notification(name: PackageListManager.prefsNotification))
        } catch {
            let alertController = UIAlertController(title: String(localizationKey: "Unknown", type: .error),
                                                    message: "\(error)",
                                                    preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: String(localizationKey: "OK"), style: .cancel, handler: nil))
            self.present(alertController, animated: true, completion: nil)
        }
    }

    private func toggleWishList() {
        guard let package = self.package else { return }
        if WishListManager.shared.isPackageInWishList(package.package) {
            WishListManager.shared.removePackageFromWishList(package.package)
        } else {
            _ = WishListManager.shared.addPackageToWishList(package.package)
        }
    }

    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        // Check the result or perform other tasks.

        // Dismiss the mail compose view controller.
        self.dismiss(animated: true, completion: nil)
    }

    @objc func dismissImmediately() {
        // Dismiss this view controller.
        self.dismiss(animated: true, completion: nil)
    }
    
    private func updatePaymentInfo() {
        let generation = contentGeneration
        downloadButton.paymentInfo = nil
        navBarDownloadButton?.paymentInfo = nil
        guard let package = package, package.commercial, let repo = package.sourceRepo else { return }
        PaymentManager.shared.getPaymentProvider(for: repo) { [weak self] error, provider in
            guard error == nil, let provider = provider else { return }
            provider.getPackageInfo(forIdentifier: package.package) { [weak self] error, info in
                guard error == nil, let info = info, info.available else { return }
                DispatchQueue.main.async {
                    guard let self = self, self.contentGeneration == generation else { return }
                    self.downloadButton.paymentInfo = info
                    self.navBarDownloadButton?.paymentInfo = info
                    self.view.setNeedsLayout()
                }
            }
        }
    }
    
    override var previewActionItems: [UIPreviewActionItem] {
        downloadButton.actionItems().map({ $0.previewAction() })
    }
    
    @available (iOS 13.0, *)
    func actions() -> [UIAction] {
        _ = self.view
        return downloadButton.actionItems().map({ $0.action() })
    }

    /// The same actions for Sileo's own card, which has no separators.
    func cardActions() -> [SileoActionMenuItem] {
        _ = self.view
        return downloadButton.actionItems().map { item in
            SileoActionMenuItem(title: item.title,
                                image: item.image,
                                destructive: item.style == .destructive,
                                handler: item.handler)
        }
    }

    func configureVersionSelectionNavigationController(_ navigationController: UINavigationController?) {
        // the outlets only exist once the view has loaded
        loadViewIfNeeded()
        downloadButton?.versionSelectionNavigationController = navigationController
        navBarDownloadButton?.versionSelectionNavigationController = navigationController
    }
}
