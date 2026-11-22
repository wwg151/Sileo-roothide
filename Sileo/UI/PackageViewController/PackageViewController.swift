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
            packageSizeLabel.font = .systemFont(ofSize: 12)
            packageSizeLabel.textColor = .secondaryLabel
            packageSizeLabel.adjustsFontSizeToFitWidth = true
            packageSizeLabel.minimumScaleFactor = 0.85
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
    private var originalDepiction: [String: Any]?
    private var depictionLoadID = UUID()
    private var translationID = UUID()
    private var isWaitingForNativeDepiction = false
    private var canTranslateDepiction = false
    private var hasAttemptedTranslation = false
    private var renderedTranslationMode = DepictionTranslation.Mode.original
    private var translationModeOverride: DepictionTranslation.Mode?
    private var translationSource: String?
    private var translationTarget = DepictionTranslation.defaultTarget
    private var translationResult: DepictionTranslation.Result?
    private var hasPageTranslationConsent = false
    private struct TranslationPageIdentity: Equatable {
        let identifier: String
        let version: String
        let sourceFile: String?
        let depictionURL: URL?
    }
    private var translationPageIdentity: TranslationPageIdentity?
    private enum TranslationStatus: Equatable {
        case translating, done, failed
    }
    private var translationStatus: TranslationStatus? {
        didSet {
            guard oldValue != translationStatus else { return }
            translationStatusLabel.text = translationStatus.map {
                switch $0 {
                case .translating: return String(localizationKey: "Depiction_Translation_Progress")
                case .done: return String(localizationKey: "Depiction_Translation_Finished")
                case .failed: return String(localizationKey: "Depiction_Translation_Failed_Inline")
                }
            }
            translationStatusRow.isHidden = translationStatus == nil
            if translationStatus == .translating {
                translationSpinner.startAnimating()
            } else {
                translationSpinner.stopAnimating()
            }
            view.setNeedsLayout()
        }
    }
    private let translationSpinner = UIActivityIndicatorView(style: .medium)
    private let translationStatusLabel = UILabel()
    private lazy var translationStatusRow: UIStackView = {
        translationSpinner.hidesWhenStopped = true
        translationStatusLabel.font = .preferredFont(forTextStyle: .footnote)
        translationStatusLabel.adjustsFontForContentSizeCategory = true
        translationStatusLabel.textColor = .secondaryLabel
        translationStatusLabel.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: [translationSpinner, translationStatusLabel])
        row.alignment = .center
        row.spacing = 8
        row.isHidden = true
        return row
    }()

    private var translationMode: DepictionTranslation.Mode {
        translationModeOverride ?? (DepictionTranslation.isEnabled ? .translated : .original)
    }
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

    private var allowNavbarUpdates = false
    private var currentNavBarOpacity = CGFloat(0)
    
    private func parseNativeDepiction(_ data: Data) {
        guard let rawDepict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              renderDepiction(rawDepict, updatingMetadata: true) else { return }
        originalDepiction = rawDepict
        renderedTranslationMode = .original
        invalidateTranslation()
    }

    @discardableResult
    private func renderDepiction(_ rawDepict: [String: Any], updatingMetadata: Bool) -> Bool {
        let oldDepictView = depictionView
        guard let newDepictView = DepictionBaseView.view(dictionary: rawDepict, viewController: self, tintColor: nil, isActionable: false) else {
            return false
        }
        if !updatingMetadata, let oldTabs = oldDepictView as? DepictionTabView,
           let newTabs = newDepictView as? DepictionTabView, newTabs.tabContentViews.indices.contains(oldTabs.activeTab) {
            newTabs.activeTab = oldTabs.activeTab
        }
        
        if updatingMetadata, let rawTintColor = rawDepict["tintColor"] as? String, let tintColor = UIColor(css: rawTintColor) {
            self.depictionFooterView?.tintColor = tintColor
            self.downloadButton.tintColor = tintColor
            self.downloadButton.updateStyle()
            self.navBarDownloadButton?.tintColor = tintColor
            self.navBarDownloadButton?.updateStyle()
        }
        oldDepictView?.delegate = nil
        newDepictView.delegate = self
        
        if let imageURL = rawDepict["headerImage"] as? String {
            if imageURL != headerURL {
                self.headerURL = imageURL
                EvanderNetworking.image(url: imageURL, condition: ({ [weak self] in self?.headerURL == imageURL}), imageView: depictionBackgroundView)
            }
        }
        
        newDepictView.alpha = 0.1
        self.depictionView = newDepictView
        self.contentView.addSubview(newDepictView)
        self.view.setNeedsLayout()
        
        FRUIView.animate(withDuration: 0.25, animations: {
            oldDepictView?.alpha = 0
            newDepictView.alpha = 1
        }, completion: { _ in
            oldDepictView?.removeFromSuperview()
            if updatingMetadata, let minVersion = rawDepict["minVersion"] as? String,
                minVersion.compare(StoreVersion) == .orderedDescending {
                self.versionTooLow()
            }
        })
        return true
    }

    @objc private func translationSettingChanged() {
        translationModeOverride = nil
        hasPageTranslationConsent = false
        invalidateTranslation()
        refreshDepictionTranslation()
    }

    private func cancelTranslationRequest() {
        translationID = UUID()
        translationStatus = nil
        if translationResult == nil { hasAttemptedTranslation = false }
    }

    private func invalidateTranslation() {
        translationResult = nil
        cancelTranslationRequest()
        showOriginalDepiction()
    }

    private func showOriginalDepiction() {
        if renderedTranslationMode != .original, let originalDepiction = originalDepiction,
           renderDepiction(originalDepiction, updatingMetadata: false) {
            renderedTranslationMode = .original
        }
    }

    private func refreshDepictionTranslation() {
        let mode = translationMode
        guard mode != .original, DepictionTranslation.isEnabled || hasPageTranslationConsent else {
            cancelTranslationRequest()
            showOriginalDepiction()
            return
        }
        guard canTranslateDepiction, viewIfLoaded?.window != nil, !isWaitingForNativeDepiction,
              let originalDepiction = originalDepiction else { return }
        if let result = translationResult {
            if renderedTranslationMode != mode {
                let depiction = mode == .compared ? result.compared : result.translated
                guard renderDepiction(depiction, updatingMetadata: false) else {
                    showOriginalDepiction()
                    translationStatus = .failed
                    return
                }
                renderedTranslationMode = mode
            }
            translationStatus = .done
            return
        }
        guard !hasAttemptedTranslation else { return }
        hasAttemptedTranslation = true
        let token = UUID()
        translationID = token
        translationStatus = .translating
        DepictionTranslation.translate(originalDepiction, source: translationSource, target: translationTarget,
                                       isCurrent: { [weak self] in
            guard let self = self else { return false }
            return self.translationID == token && self.canTranslateDepiction &&
                (DepictionTranslation.isEnabled || self.hasPageTranslationConsent)
        }, progress: { [weak self] partial in
            guard let self = self, self.translationID == token, self.canTranslateDepiction,
                  self.translationResult == nil else { return }
            // One tab is done and the rest is still being asked for: draw what is
            // ready instead of leaving the page in its original language.
            self.translationResult = partial
            self.translationStatus = .translating
            self.drawTranslation()
        }, completion: { [weak self] result, _ in
            guard let self = self, self.translationID == token, self.canTranslateDepiction else { return }
            self.translationResult = result
            // A few fragments the engine refuses are left as written; they do not
            // turn a translated page into a failure.
            self.translationStatus = result == nil ? .failed : .done
            if result != nil {
                // A tab may already be on screen from a partial pass; the finished
                // text replaces it even though the mode has not changed.
                self.renderedTranslationMode = .original
                self.refreshDepictionTranslation()
            } else {
                self.showOriginalDepiction()
            }
        })
    }

    /// Draw the current mode's translation, leaving the chosen tab and the
    /// reading position where they are.
    private func drawTranslation() {
        guard let result = translationResult else { return }
        let mode = translationMode
        guard mode != .original else { return }
        let depiction = mode == .compared ? result.compared : result.translated
        let offset = scrollView.contentOffset
        guard renderDepiction(depiction, updatingMetadata: false) else {
            showOriginalDepiction()
            translationStatus = .failed
            return
        }
        renderedTranslationMode = mode
        view.layoutIfNeeded()
        if scrollView.contentOffset != offset { scrollView.setContentOffset(offset, animated: false) }
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
        contentView.addSubview(translationStatusRow)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(PackageViewController.reloadData),
                                               name: PackageListManager.reloadNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(PackageViewController.reloadData),
                                               name: PackageListManager.installChange,
                                               object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(translationSettingChanged),
                                               name: DepictionTranslation.changed, object: nil)
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

        self.reloadData()
        
        if let package=self.package {
            CanisterResolver.shared.ingest(packages: [package])
        }
    }

    @objc func updateSileoColors() {
        packageName.textColor = .sileoLabel
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
        
        depictionLoadID = UUID()
        translationResult = nil
        cancelTranslationRequest()
        originalDepiction = nil
        isWaitingForNativeDepiction = false
        renderedTranslationMode = .original
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

        let pageIdentity = TranslationPageIdentity(identifier: package.package, version: package.version,
                                                   sourceFile: package.sourceFile, depictionURL: package.sileoDepiction)
        if pageIdentity != translationPageIdentity {
            translationPageIdentity = pageIdentity
            hasPageTranslationConsent = false
            translationModeOverride = nil
            translationSource = nil
            translationTarget = DepictionTranslation.defaultTarget
        }

        let installedPackage = PackageListManager.shared.installedPackage(identifier: package.package)
        self.installedPackage = installedPackage

        packageName.text = package.name
        packageAuthor.text = package.author?.name ?? ""
        updatePackageSize(package)

        downloadButton.package = package
        navBarDownloadButton?.package = package
        
        self.updatePaymentInfo()
        
        if let imageURL = package.rawControl["header"] {
            if imageURL != headerURL {
                self.headerURL = imageURL
                EvanderNetworking.image(url: imageURL, size: CGSize(width: depictionBackgroundView.frame.width, height: 200), condition: ({ [weak self] in self?.headerURL == imageURL }), imageView: depictionBackgroundView)
            }
        }
        
        if package.hasIcon(),
            let rawIcon = package.icon {
            EvanderNetworking.image(url: rawIcon, size: packageIconView.frame.size, condition: ({ [weak self] in self?.package?.icon == rawIcon}), imageViews: [packageIconView, packageNavBarIconView], fallback: package.defaultIcon)
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
            originalDepiction = rawDepiction
        }

        if !package.fromStatusFile, let depiction = package.sileoDepiction {
            isWaitingForNativeDepiction = true
            let loadID = depictionLoadID
            let urlRequest = URLManager.urlRequest(depiction)
            EvanderNetworking.request(request: urlRequest, type: Data.self) { [weak self] success, _, _, data in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.depictionLoadID == loadID else { return }
                    self.isWaitingForNativeDepiction = false
                    if success, let data = data { self.parseNativeDepiction(data) }
                    self.refreshDepictionTranslation()
                }
            }
        }

        self.reloadFooter(package: package, installedPackage: installedPackage)
        refreshDepictionTranslation()
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

    // Keep the existing depiction only when the selected package still represents the same content.
    func show(package: Package) {
        guard let current = self.package, current.package == package.package,
              current.version == package.version, current.sourceFile == package.sourceFile,
              current.sileoDepiction == package.sileoDepiction, current.description == package.description,
              !(package.isProvisional ?? false) else {
            self.package = package
            reloadData()
            return
        }
        self.package = package
        updatePackageSize(package)
        installedPackage = PackageListManager.shared.installedPackage(identifier: package.package)
        downloadButton.package = package
        navBarDownloadButton?.package = package
        updatePaymentInfo()
        reloadFooter(package: package, installedPackage: installedPackage)
        view.setNeedsLayout()
        view.layoutIfNeeded()
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
        
        self.statusBarStyle = .default
        
        self.navigationController?.navigationBar._backgroundOpacity = currentNavBarOpacity
        self.navigationController?.navigationBar.tintColor = .white
        allowNavbarUpdates = true
        self.scrollViewDidScroll(self.scrollView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Context-menu previews also call viewDidAppear; only a real detail page owns translation.
        canTranslateDepiction = navigationController.map { $0.topViewController === self }
            ?? (presentingViewController != nil || splitViewController != nil)
        refreshDepictionTranslation()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        canTranslateDepiction = false
        cancelTranslationRequest()
        
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

    override func viewDidLayoutSubviews() {
        NSLog("SileoLog: PackageViewController.viewDidLayoutSubviews")
//        Thread.callStackSymbols.forEach{NSLog("SileoLog: viewDidLayoutSubviews callstack=\($0)")}
        
        super.viewDidLayoutSubviews()

        depictionHeight = depictionView?.depictionHeight(width: self.view.bounds.width) ?? 0

        let width = view.bounds.width
        let headerHeight = packageInfoView.frame.maxY
        let statusWidth = max(0, width - 32)
        var statusHeight: CGFloat = 0
        if translationStatus != nil {
            let spinnerWidth = translationStatus == .translating ? translationSpinner.intrinsicContentSize.width + translationStatusRow.spacing : 0
            let textSize = translationStatusLabel.sizeThatFits(CGSize(width: max(1, statusWidth - spinnerWidth), height: .greatestFiniteMagnitude))
            let rowHeight = max(ceil(textSize.height), translationSpinner.intrinsicContentSize.height)
            translationStatusRow.frame = CGRect(x: 16, y: headerHeight + 6, width: statusWidth, height: rowHeight)
            statusHeight = rowHeight + 12
        }

        let depictionTop = headerHeight + statusHeight
        depictionView?.frame = CGRect(x: 0, y: depictionTop, width: width, height: depictionHeight)

        let footerTop = depictionTop + depictionHeight
        let footerHeight = depictionFooterView?.depictionHeight(width: width) ?? 0
        depictionFooterView?.frame = CGRect(x: 0, y: footerTop, width: width, height: footerHeight)

        let contentHeight = footerTop + footerHeight
        contentView.frame = CGRect(origin: .zero, size: CGSize(width: width, height: contentHeight))
        scrollView.contentSize = CGSize(width: width, height: contentHeight)

        contentViewWidth.constant = scrollView.bounds.width
        contentViewHeight.constant = contentHeight

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

    /// Share and wishlist remain separate from the install button’s actions.
    @available(iOS 14.0, *)
    private func installShareMenu() {
        refreshShareMenu()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(refreshShareMenu),
                                               name: Notification.Name("HideSeparators"),
                                               object: nil)
    }

    @objc private func refreshShareMenu() {
        guard #available(iOS 14.0, *), let shareButton = shareButton else { return }
        shareButton.removeTarget(self, action: #selector(presentShareCard(_:)), for: .touchUpInside)
        let attached = SileoActionMenu.attachMenu(to: shareButton, header: nil) { [weak self] in
            self?.shareMenuActions() ?? []
        }
        if !attached { shareButton.addTarget(self, action: #selector(presentShareCard(_:)), for: .touchUpInside) }
    }

    func translationActionItem() -> SileoActionMenuItem? {
        guard canTranslateDepiction, DepictionTranslation.supportedPlatform, let identity = translationPageIdentity else { return nil }
        return SileoActionMenuItem(title: String(localizationKey: "Depiction_Translation_Menu"),
                                   imageName: "character.bubble") { [weak self] in
            guard let self = self, self.translationPageIdentity == identity else { return }
            self.presentDepictionTranslationOptions()
        }
    }

    private func presentDepictionTranslationOptions() {
        guard canTranslateDepiction, presentedViewController == nil, let identity = translationPageIdentity else { return }
        let panel = SileoPanelViewController(title: String(localizationKey: "Depiction_Translation_Menu"),
                                             icon: "character.bubble")
        var rows = DepictionTranslation.Mode.allCases.map { mode in
            SileoPanelTable.Item(SileoPanelViewController.choiceRow(title: mode.title, detail: nil,
                                                                   selected: mode == renderedTranslationMode) { [weak self, weak panel] in
                panel?.close { [weak self] in
                    guard let self = self, self.translationPageIdentity == identity else { return }
                    self.selectTranslationMode(mode)
                }
            }, height: 52)
        }
        for choosingSource in [true, false] {
            let chosen = choosingSource ? translationSource : translationTarget
            let title = String(localizationKey: choosingSource ? "Depiction_Translation_Source" : "Depiction_Translation_Target")
            let detail = chosen.map(DepictionTranslation.languageName) ?? String(localizationKey: "Depiction_Translation_Detect")
            rows.append(SileoPanelTable.Item(SileoPanelViewController.disclosureRow(title: title, detail: detail) { [weak self, weak panel] in
                panel?.close { [weak self] in
                    guard let self = self, self.translationPageIdentity == identity else { return }
                    self.presentTranslationLanguages(choosingSource: choosingSource, title: title, identity: identity)
                }
            }, height: 52))
        }
        panel.table.setItems(rows)
        panel.present(from: self)
    }

    private func presentTranslationLanguages(choosingSource: Bool, title: String, identity: TranslationPageIdentity) {
        let chosen = choosingSource ? translationSource : translationTarget
        DepictionTranslation.languages(choosingSource: choosingSource, source: translationSource,
                                        target: translationTarget) { [weak self] identifiers in
            guard let self = self, self.canTranslateDepiction, self.translationPageIdentity == identity,
                  self.presentedViewController == nil else { return }
            let panel = SileoPanelViewController(title: title, icon: "character.bubble")
            let selected = chosen.flatMap { value in
                identifiers.first(where: { $0 == value }) ??
                    identifiers.first(where: { DepictionTranslation.matchesLanguage($0, value) })
            }
            let sorted = identifiers.map { ($0, DepictionTranslation.languageName($0)) }.sorted {
                $0.1.localizedStandardCompare($1.1) == .orderedAscending
            }
            func row(_ identifier: String?, _ name: String, selected: Bool) -> SileoPanelTable.Item {
                SileoPanelTable.Item(SileoPanelViewController.choiceRow(title: name, detail: nil,
                                                                       selected: selected) { [weak self, weak panel] in
                    panel?.close { [weak self] in
                        guard let self = self, self.canTranslateDepiction, self.translationPageIdentity == identity else { return }
                        self.selectTranslationLanguage(identifier, choosingSource: choosingSource)
                        self.presentDepictionTranslationOptions()
                    }
                }, height: 52)
            }
            var rows = sorted.map { row($0.0, $0.1, selected: $0.0 == selected) }
            if identifiers.isEmpty {
                rows.append(SileoPanelTable.Item(SileoPanelViewController.sectionLabel(
                    String(localizationKey: "Depiction_Translation_No_Languages")), height: 34))
            }
            if choosingSource {
                rows.insert(row(nil, String(localizationKey: "Depiction_Translation_Detect"), selected: chosen == nil), at: 0)
            }
            panel.table.setItems(rows)
            panel.present(from: self)
        }
    }

    private func selectTranslationMode(_ mode: DepictionTranslation.Mode) {
        guard canTranslateDepiction, viewIfLoaded?.window != nil else { return }
        if mode != .original, !DepictionTranslation.isEnabled, !hasPageTranslationConsent {
            let loadID = depictionLoadID
            presentTranslationConsent { [weak self] in
                guard let self = self, self.depictionLoadID == loadID else { return }
                self.hasPageTranslationConsent = true
                self.translationModeOverride = mode
                self.refreshDepictionTranslation()
            }
            return
        }
        translationModeOverride = mode
        if mode != .original, translationStatus == .failed, translationResult == nil { invalidateTranslation() }
        refreshDepictionTranslation()
    }

    private func selectTranslationLanguage(_ identifier: String?, choosingSource: Bool) {
        if choosingSource {
            guard translationSource != identifier else { return }
            translationSource = identifier
        } else {
            guard let identifier = identifier, translationTarget != identifier else { return }
            translationTarget = identifier
        }
        invalidateTranslation()
        refreshDepictionTranslation()
    }

    private func presentTranslationConsent(onConfirm: @escaping () -> Void) {
        guard presentedViewController == nil, viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(title: String(localizationKey: "Depiction_Translation_Menu"),
                                      message: String(localizationKey: "Depiction_Translation_Consent"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localizationKey: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localizationKey: "OK"), style: .default) { _ in onConfirm() })
        present(alert, animated: true)
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
    
    private func updatePaymentInfo()
    {
        guard let package = self.package, package.commercial, let repo = package.sourceRepo else {
            DispatchQueue.main.async {
                self.downloadButton.paymentInfo = nil
                self.navBarDownloadButton?.paymentInfo = nil
            }
            return
        }

        PaymentManager.shared.getPaymentProvider(for: repo) { error, provider in
            guard error == nil, let provider = provider else {
                return
            }

// we can always request price for packages even if the repo is not logged in
//                guard provider.isAuthenticated else {
//                    return //we have to re-verify its payment status if the repo is not logged in
//                }

            provider.getPackageInfo(forIdentifier: package.package) { error, info in
                guard error == nil, let info=info, info.available else { return }

                self.downloadButton.paymentInfo = info
                self.navBarDownloadButton?.paymentInfo = info
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
