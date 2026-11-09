//
//  TabBarController.swift
//  Sileo
//
//  Created by CoolStar on 4/20/20.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import Foundation
import LNPopupController
import ObjectiveC

/// Key for the frame the queue bar's title had after we moved it.
private var popupTitleShiftKey: UInt8 = 0

class TabBarController: UITabBarController, UITabBarControllerDelegate, LNPopupPresentationDelegate {
    static var singleton: TabBarController?
    private var downloadsController: UINavigationController?
    private(set) public var popupIsPresented = false
    private var popupLock = DispatchSemaphore(value: 1)
    private var shouldSelectIndex = -1
    private static let lastSelectedTabKey = "LastSelectedTab"
    private var fuckedUpSources = false
//    private let ipadModeMinWidth = CGFloat(752) //debug
    private let ipadModeMinWidth = CGFloat(768)
    
    private var popupQueueLock = DispatchSemaphore(value: 1)
    private static let popupQueueContext = 50
    private static let popupQueueKey = DispatchSpecificKey<Int>()
    private static let popupQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "Sileo.PopupQueue", qos: .userInitiated)
        queue.setSpecific(key: popupQueueKey, value: popupQueueContext)
        return queue
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        delegate = self
        TabBarController.singleton = self
        popupPresentationDelegate = self
        
        let savedTab = UserDefaults.standard.integer(forKey: TabBarController.lastSelectedTabKey)
        if let count = viewControllers?.count, savedTab > 0, savedTab < count {
            selectedIndex = savedTab
        }
        
        downloadsController = UINavigationController(rootViewController: DownloadManager.shared.viewController)
        downloadsController?.isNavigationBarHidden = true
        downloadsController?.popupItem.title = ""
        downloadsController?.popupItem.subtitle = ""
        
        weak var weakSelf = self
        NotificationCenter.default.addObserver(weakSelf as Any,
                                               selector: #selector(updateSileoColors),
                                               name: SileoThemeManager.sileoChangedThemeNotification,
                                               object: nil)
        updateSileoColors()
        (self.tabBar as? TabBar)?.onLayout = { [weak self] in self?.applyFloatingStyle() }
        // Install the saved item metrics before the first layout so the bar never has to resize on launch
        applyFloatingStyle()
        TabBarController.installPopupBarLayoutHook()
        popupBar.popupOpenGestureRecognizer.addTarget(self, action: #selector(popupBarTapped))
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(floatingTabBarChanged),
                                               name: Notification.Name("FloatingTabBar"),
                                               object: nil)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.tabBar.layoutIfNeeded()
        applyFloatingStyle()
        
        self.updatePopup()
    }
    
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        shouldSelectIndex = tabBarController.selectedIndex
        return true
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        // Run after the tab bar relayout, otherwise the system may rebuild the icon view and drop the animation
        DispatchQueue.main.async { [weak self] in self?.animateSelectedIcon() }
        saveSelectedTab()
        if shouldSelectIndex == tabBarController.selectedIndex {
            if let splitViewController = viewController as? UISplitViewController {
                if let navController = splitViewController.viewControllers[0] as? UINavigationController {
                    navController.popToRootViewController(animated: true)
                }
            }
        }
        if tabBarController.selectedIndex == 4 && shouldSelectIndex == 4 {
            if let navController = tabBarController.viewControllers?[4] as? SileoNavigationController,
               let packageList = navController.viewControllers[0] as? PackageListViewController {
                packageList.searchController.searchBar.becomeFirstResponder()
            }
        }
        if tabBarController.selectedIndex == 3 && shouldSelectIndex == 3 {
            if let navController = tabBarController.viewControllers?[3] as? SileoNavigationController,
               let packageList = navController.viewControllers[0] as? PackageListViewController,
               let collectionView = packageList.collectionView {
                let yVal = -1 * collectionView.adjustedContentInset.top
                collectionView.setContentOffset(CGPoint(x: 0, y: yVal), animated: true)
            }
        }
        if tabBarController.selectedIndex ==  2 && !fuckedUpSources {
            if let sourcesSVC = tabBarController.viewControllers?[2] as? UISplitViewController,
               let sourcesNaVC = sourcesSVC.viewControllers[0] as? SileoNavigationController {
                if sourcesNaVC.presentedViewController == nil {
                    sourcesNaVC.popToRootViewController(animated: false)
                }
            }
            fuckedUpSources = true
        }
        if viewController as? SileoNavigationController != nil { return }
        if viewController as? SourcesSplitViewController != nil { return }
        fatalError("View Controller mismatch")
    }
    
    // Selection can also change in code (URLs, shortcuts), so this is also called when the app goes to the background
    func saveSelectedTab() {
        UserDefaults.standard.set(selectedIndex, forKey: TabBarController.lastSelectedTabKey)
    }

    func presentPopup() {
        presentPopup(completion: nil)
    }
    
    func presentPopup(animated:Bool = true, completion: (() -> Void)?) {
        NSLog("SileoLog: TabBarController.presentPopup \(popupIsPresented), \(downloadsController), \(completion)")

        guard let downloadsController = downloadsController, !popupIsPresented else {
            if let completion = completion {
                completion()
            }
            return
        }
        
        popupLock.wait()
        defer {
            popupLock.signal()
        }
        
        popupIsPresented = true
        self.popupContentView.popupCloseButtonAutomaticallyUnobstructsTopBars = false
        self.popupBar.toolbar.tag = WHITE_BLUR_TAG
        self.popupBar.barStyle = .prominent
        
        self.updateSileoColors()
        
        self.popupBar.toolbar.setBackgroundImage(nil, forToolbarPosition: .any, barMetrics: .default)
        self.popupBar.tabBarHeight = floatingPopupTabBarHeight
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.popupBar.isInlineWithTabBar = true
            self.popupBar.tabBarHeight += 1
        }
        self.popupBar.progressViewStyle = .bottom
        self.popupInteractionStyle = .drag
                
        TabBarController.popupQueue.async {
            self.popupQueueLock.wait()
            DispatchQueue.main.async {
                self.presentPopupBar(withContentViewController: downloadsController, animated: animated) {
                    self.popupBar.alpha = 1
                    self.popupBar.isHidden = false
                    self.popupBarHiddenAt = nil
                    TabBarController.popupIsOpen = false
                    self.applyFloatingStyle()
                    completion?()
                    self.popupQueueLock.signal()
                }
            }
        }
        
        self.updateSileoColors()
    }
    
    func dismissPopup() {
        dismissPopup(completion: nil)
    }
    
    func dismissPopup(animated:Bool = true, completion: (() -> Void)?) {
        NSLog("SileoLog: TabBarController.dismissPopup \(popupIsPresented) \(completion)")

        guard popupIsPresented else {
            if let completion = completion {
                completion()
            }
            return
        }
        
        popupLock.wait()
        defer {
            popupLock.signal()
        }
        
        popupIsPresented = false
            
        TabBarController.popupQueue.async {
            self.popupQueueLock.wait()
            DispatchQueue.main.async {
                self.dismissPopupBar(animated: animated) {
                    self.popupBar.alpha = 1
                    self.popupBar.isHidden = false
                    self.popupBarHiddenAt = nil
                    TabBarController.popupIsOpen = false
                    self.applyFloatingStyle()
                    completion?()
                    self.popupQueueLock.signal()
                }
            }
        }
    }
    
    func presentPopupController() {
        self.presentPopupController(completion: nil)
    }
    
    func presentPopupController(completion: (() -> Void)?) {
        NSLog("SileoLog: TabBarController.presentPopupController \(completion)")

        guard popupIsPresented else {
            if let completion = completion {
                completion()
            }
            return
        }
        
        popupLock.wait()
        defer {
            popupLock.signal()
        }
        
        self.openPopup(animated: true, completion: completion)
    }
    
    func dismissPopupController() {
        self.dismissPopupController(completion: nil)
    }
    
    func dismissPopupController(completion: (() -> Void)?) {
        NSLog("SileoLog: TabBarController.dismissPopupController \(completion)")

        guard popupIsPresented else {
            completion?()
            return
        }
        
        popupLock.wait()
        defer {
            popupLock.signal()
        }
        
        // The window closes onto the bar, so the bar has to be there while it
        // lands; without it the window keeps its last frame at the bottom.
        TabBarController.popupIsOpen = false
        popupBar.isHidden = false
        popupBarHiddenAt = nil
        tabBar.alpha = 1
        applyFloatingStyle()

        self.closePopup(animated: true, completion: {
            // The chevron at the top of the window closes it through here, and
            // the bar has to come back with it.
            TabBarController.popupIsOpen = false
            self.popupBar.isHidden = false
            self.popupBarHiddenAt = nil
            self.applyFloatingStyle()
            self.schedulePopupBarRefresh()
            completion?()
        })
    }
    
    func updatePopup() {
        updatePopup(completion: nil)
    }
    
    func updatePopup(animated:Bool = true, completion: (() -> Void)? = nil, bypass: Bool = false) {
        func hideRegardless() {
            if UIDevice.current.userInterfaceIdiom == .pad && self.view.frame.width >= ipadModeMinWidth {
                downloadsController?.popupItem.title = String(localizationKey: "Queued_Package_Status")
                downloadsController?.popupItem.subtitle = String(format: String(localizationKey: "Package_Queue_Count"), 0)
                self.dismissPopupController()
                self.presentPopup(animated: animated, completion: completion)
            } else {
                self.dismissPopup(animated: animated, completion: completion)
            }
        }
//we should never dismiss the popup if the queue is not empty (will cause TabBar to never display anymore)
//        if bypass {
//            hideRegardless()
//            return
//        }
        
        let manager = DownloadManager.shared
        NSLog("SileoLog: updatePopup(\(completion),\(bypass)) : \(self.view.frame.width) : queueRunning=\(manager.queueRunning) aptRunning=\(manager.aptRunning)  aptFinished=\(manager.aptFinished) operationCount=\(manager.operationCount()) downloading=\(manager.downloadingPackages()) ready=\(manager.readyPackages()) installing=\(manager.installingPackages()) uninstalling=\(manager.uninstallingPackages()) verifyComplete=\(manager.verifyComplete())")
//        Thread.callStackSymbols.forEach{NSLog("SileoLog: updatePopup callstack=\($0)")}
        
        if manager.operationCount() == 0 {
            assert(manager.queueRunning == false)
            
            //requires async due the deadlock: dismissPopupController->(LNPopupController)->viewDidLayoutSubviews->updatePopup->dismissPopup on iphone mode on ipad
            DispatchQueue.main.async {
                hideRegardless()
            }
        }
        else if !manager.queueRunning {
            downloadsController?.popupItem.title = String(localizationKey: "Queued_Package_Status")
            downloadsController?.popupItem.subtitle = String(format: String(localizationKey: "Package_Queue_Count"), manager.operationCount())
            downloadsController?.popupItem.progress = 0
            self.presentPopup(completion: completion)
        }
        else if manager.aptFinished {
            downloadsController?.popupItem.title = String(localizationKey: "Done")
            downloadsController?.popupItem.subtitle = String(format: String(localizationKey: "Package_Queue_Count"), manager.operationCount())
            downloadsController?.popupItem.progress = 0
            self.presentPopup(completion: completion)
        }
        else if manager.aptRunning {
            if manager.installingPackages() > 0 {
                downloadsController?.popupItem.title = String(localizationKey: "Installing_Package_Status")
                downloadsController?.popupItem.subtitle = String(format: String(localizationKey: "Package_Queue_Count"), manager.installingPackages())
                downloadsController?.popupItem.progress = 0
                self.presentPopup(completion: completion)
            } else if manager.uninstallingPackages() > 0 {
                downloadsController?.popupItem.title = String(localizationKey: "Removal_Queued_Package_Status")
                downloadsController?.popupItem.subtitle = String(format: String(localizationKey: "Package_Queue_Count"), manager.uninstallingPackages())
                downloadsController?.popupItem.progress = 0
                self.presentPopup(completion: completion)
            }
        }
        else {
            if manager.downloadingPackages() > 0 {
                downloadsController?.popupItem.title = String(localizationKey: "Downloading_Package_Status")
                downloadsController?.popupItem.subtitle = String(format: String(localizationKey: "Package_Queue_Count"), manager.downloadingPackages())
                downloadsController?.popupItem.progress = 0
                self.presentPopup(completion: completion)
            } else if manager.verifyComplete() {
                downloadsController?.popupItem.title = String(localizationKey: "Ready_Status")
                downloadsController?.popupItem.subtitle = String(format: String(localizationKey: "Package_Queue_Count"), manager.operationCount())
                downloadsController?.popupItem.progress = 0
                self.presentPopup(completion: completion)
            }
        }
    }
    
    override var bottomDockingViewForPopupBar: UIView? {
        self.tabBar
    }
    
    override var defaultFrameForBottomDockingView: CGRect {
        NSLog("SileoLog: TabBarController.defaultFrameForBottomDockingView")
        var tabBarFrame = self.tabBar.frame
        tabBarFrame.origin.y = self.view.bounds.height - tabBarFrame.height
        if UIDevice.current.userInterfaceIdiom == .pad {
            tabBarFrame.origin.x = 0
            tabBarFrame.size.width = self.view.bounds.width
            if tabBarFrame.width >= ipadModeMinWidth {
                tabBarFrame.size.width -= 320
            }
        }
        return tabBarFrame
    }
    
    private var floatingInset: CGFloat { 10 }

    /// How far the floating tab bar keeps its first item from the capsule's
    /// edge. The queue bar's title is placed the same distance in, so the two
    /// line up whatever the bar's own margins happen to be. The measurement is
    /// kept, so the first queue bar of a launch is already in place instead of
    /// settling once the tab bar has laid out.
    private var floatingContentInset: CGFloat {
        if floatingSettled, let container = floatingBackground, container.frame.width > 0,
           let first = buttonsSortedByX().first {
            let firstX = first.convert(first.bounds, to: tabBar).minX
            let measured = firstX - container.frame.minX
            if measured > 10, measured < 60 {
                UserDefaults.standard.set(Double(measured), forKey: floatingContentInsetKey)
                return measured
            }
        }
        let saved = UserDefaults.standard.double(forKey: floatingContentInsetKey)
        return saved > 0 ? CGFloat(saved) : 20
    }
    private let floatingContentInsetKey = "FloatingTabBarContentInset"
    private var floatingPopupTabBarHeight: CGFloat {
        // Popup bottom edge should touch the capsule's top edge
        if isFloatingEnabled, let container = floatingBackground, !container.isHidden, container.frame.height > 0 {
            return max(self.tabBar.frame.height, self.tabBar.bounds.height - container.frame.minY)
        }
        return self.tabBar.frame.height
    }

    /// The capsule reaches above the tab bar, into the queue bar that sits on
    /// it. The queue bar is lifted until its bottom edge meets the capsule's
    /// top edge, measured in window coordinates so no guess is involved.
    ///
    /// The queue bar lays its title a few points from its leading edge, which
    /// reads as cramped once the bar is a capsule. Its title view is moved
    /// right, and narrowed by the same amount, after every one of the bar's
    /// layout passes. The move is made without animation, so the text is
    /// already in place when the bar appears.
    static func applyFloatingPopupContentInset(to bar: LNPopupBar) {
        guard !TabBarController.popupIsOpen else { return }
        guard UIDevice.current.userInterfaceIdiom == .phone,
              UserDefaults.standard.bool(forKey: "FloatingTabBar", fallback: false) else {
            return
        }
        guard let inner = bar.toolbar.superview else { return }
        // The bar is full width now, so the title starts one capsule margin
        // plus the tab bar's own item margin in.
        let capsuleInset = TabBarController.singleton?.floatingInset ?? 10
        let contentInset = TabBarController.singleton?.floatingContentInset ?? 20
        let target = capsuleInset + contentInset
        let toolbar = bar.toolbar
        for sub in inner.subviews {
            if sub === toolbar { continue }
            let name = String(describing: type(of: sub))
            if name.contains("Image") || name.contains("Effect") || name.contains("Background") {
                continue
            }
            let applied = objc_getAssociatedObject(sub, &popupTitleShiftKey) as? NSValue
            if let applied = applied, applied.cgRectValue.equalTo(sub.frame) {
                continue
            }
            var frame = sub.frame
            let delta = target - frame.minX
            guard delta > 0.5, frame.width > target + 40 else { continue }
            frame.origin.x = target
            frame.size.width -= delta
            UIView.performWithoutAnimation {
                sub.frame = frame
            }
            objc_setAssociatedObject(sub, &popupTitleShiftKey, NSValue(cgRect: frame), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    private static var popupBarLayoutHooked = false
    /// When the bar was hidden for the open window, so a close that never
    /// reported itself can still give it back.
    private var popupBarHiddenAt: Date?
    /// The open window's own material, put aside while it covers the screen.

    /// True while the queue is open as a window.
    static var popupIsOpen = false
    /// Our own capsule over the bar's material, so the bar itself keeps the
    /// framework's full-width frame.
    private var popupCapsuleView: UIVisualEffectView?
    private var popupHiddenMaterialViews: [UIView] = []

    /// The queue bar lays its content out itself, so the inset above has to
    /// run right after each of those passes.
    static func installPopupBarLayoutHook() {
        guard !popupBarLayoutHooked else { return }
        popupBarLayoutHooked = true
        guard let original = class_getInstanceMethod(LNPopupBar.self, #selector(UIView.layoutSubviews)),
              let inherited = class_getInstanceMethod(UIView.self, #selector(UIView.layoutSubviews)),
              method_getImplementation(original) != method_getImplementation(inherited),
              let replacement = class_getInstanceMethod(LNPopupBar.self, #selector(LNPopupBar.sileo_layoutSubviews)) else {
            return
        }
        method_exchangeImplementations(original, replacement)
    }

    /// The queue bar keeps the framework's full-width frame — the open window
    /// is measured from it — and takes its capsule from a view of our own laid
    /// over the bar's material.
    private func applyFloatingPopupShape() {
        guard popupIsPresented else { return }
        let collapsed = !TabBarController.popupIsOpen
        let bar = popupBar
        guard bar.bounds.height > 0, bar.bounds.height < view.bounds.height * 0.5 else { return }
        if isFloatingEnabled, collapsed, let container = floatingBackground, !container.isHidden {
            applyPopupCapsule()
        } else {
            removePopupCapsule()
        }
    }

    private func applyPopupCapsule() {
        let bar = popupBar
        if popupCapsuleView == nil {
            let capsule = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
            capsule.isUserInteractionEnabled = false
            capsule.clipsToBounds = true
            bar.insertSubview(capsule, at: 0)
            popupCapsuleView = capsule
            // The bar's own full-width material and its hairlines step aside
            // while we draw the capsule.
            func hideMaterial(in view: UIView) {
                for sub in view.subviews {
                    if sub === capsule { continue }
                    let name = String(describing: type(of: sub))
                    if sub is UIVisualEffectView || name.contains("Shadow") {
                        popupHiddenMaterialViews.append(sub)
                        sub.isHidden = true
                    } else {
                        hideMaterial(in: sub)
                    }
                }
            }
            hideMaterial(in: bar)
        }
        guard let capsule = popupCapsuleView else { return }
        let frame = bar.bounds.insetBy(dx: floatingInset, dy: 0)
        if capsule.frame != frame {
            capsule.frame = frame
        }
        let radius = bar.bounds.height / 2
        if abs(capsule.layer.cornerRadius - radius) > 0.5 {
            capsule.layer.cornerRadius = radius
            capsule.layer.cornerCurve = .continuous
        }
    }

    /// The bar as the framework lays it out: full width, its own material.
    private func resetFloatingPopupShape() {
        removePopupCapsule()
    }

    private func removePopupCapsule() {
        guard popupCapsuleView != nil || !popupHiddenMaterialViews.isEmpty else { return }
        popupCapsuleView?.removeFromSuperview()
        popupCapsuleView = nil
        for view in popupHiddenMaterialViews {
            view.isHidden = false
        }
        popupHiddenMaterialViews.removeAll()
    }

    private func updateFloatingPopupOffset() {
        func reset() {
            if self.popupBar.transform != .identity {
                self.popupBar.transform = .identity
            }
        }
        guard popupIsPresented else { return }
        if popupPresentationState == .open {
            TabBarController.popupIsOpen = true
        }
        guard isFloatingEnabled else {
            reset()
            resetFloatingPopupShape()
            return
        }
        // While the queue is open as a window the bar belongs to the framework:
        // moving it here is what used to leave a strip of it on screen.
        guard !TabBarController.popupIsOpen else {
            reset()
            resetFloatingPopupShape()
            return
        }
        guard let container = floatingBackground, !container.isHidden,
              popupBar.bounds.height > 0,
              popupBar.bounds.height < view.bounds.height * 0.5 else {
            reset()
            return
        }
        applyFloatingPopupShape()
        // Measure without the shift applied, or repeated passes would stack it
        popupBar.transform = .identity
        let capsuleTop = container.convert(CGPoint.zero, to: nil).y
        let barBottom = popupBar.convert(CGPoint(x: 0, y: popupBar.bounds.height), to: nil).y
        let shift = max(0, barBottom - capsuleTop)
        popupBar.transform = CGAffineTransform(translationX: 0, y: -shift)
    }
    private var floatingRetryCount = 0
    private var floatingBackground: UIView?
    private var floatingAppearance: UITabBarAppearance?
    private var floatingItemWidth: CGFloat = 0
    private var floatingRefreshPending = false
    private var floatingSettled = false
    private var floatingTrusted = false
    private var floatingTrustedReselected = false
    private let floatingItemWidthKey = "FloatingTabBarCalibratedItemWidth"
    private let floatingBarWidthKey = "FloatingTabBarCalibratedBarWidth"
    private var floatingReferenceWidth: CGFloat {
        self.tabBar.bounds.width > 0 ? self.tabBar.bounds.width : self.view.bounds.width
    }

    private func revealFloatingTabBar(save: Bool = true) {
        floatingSettled = true
        if save, floatingItemWidth > 0 {
            UserDefaults.standard.set(Double(floatingItemWidth), forKey: floatingItemWidthKey)
            UserDefaults.standard.set(Double(floatingReferenceWidth), forKey: floatingBarWidthKey)
        }
        // The window covers the tab bar; it must not fade back in over it.
        guard !TabBarController.popupIsOpen else { return }
        guard self.tabBar.alpha < 1 else { return }
        UIView.animate(withDuration: 0.2) { self.tabBar.alpha = 1 }
    }
    private var originalStandardAppearance: UITabBarAppearance?
    private var originalScrollEdgeAppearance: UITabBarAppearance?

    private var isFloatingEnabled: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && UserDefaults.standard.bool(forKey: "FloatingTabBar", fallback: false)
    }

    @objc private func floatingTabBarChanged() {
        if popupIsPresented {
            self.popupBar.tabBarHeight = floatingPopupTabBarHeight
        }
        self.view.setNeedsLayout()
        self.view.layoutIfNeeded()
    }

    // Icon image view of a tab button, ignoring badge views (items with badges nest their views differently)
    private func iconImageView(in view: UIView) -> UIImageView? {
        var best: UIImageView?
        func walk(_ v: UIView) {
            for sub in v.subviews {
                if String(describing: type(of: sub)).contains("Badge") { continue }
                if let imageView = sub as? UIImageView, imageView.bounds.width > 12 {
                    if best == nil || imageView.bounds.width * imageView.bounds.height > best!.bounds.width * best!.bounds.height {
                        best = imageView
                    }
                }
                walk(sub)
            }
        }
        walk(view)
        return best
    }

    private func buttonsSortedByX() -> [UIView] {
        var result: [UIView] = []
        func walk(_ v: UIView) {
            for sub in v.subviews {
                if String(describing: type(of: sub)).contains("TabBarButton") { result.append(sub) } else { walk(sub) }
            }
        }
        walk(self.tabBar)
        return result.sorted { $0.frame.midX < $1.frame.midX }
    }

    private func animateSelectedIcon() {
        guard isFloatingEnabled else { return }
        let buttons = buttonsSortedByX()
        let index = self.selectedIndex
        guard index < buttons.count, let icon = iconImageView(in: buttons[index]) else { return }
        playIconAnimation(for: index, on: icon)
    }

    // Per-tab icon animations: featured, changes, sources, packages, search
    private func playIconAnimation(for index: Int, on icon: UIView) {
        let layer = icon.layer
        layer.removeAllAnimations()
        func keyframes(_ keyPath: String, _ values: [CGFloat], _ duration: CFTimeInterval) {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.duration = duration
            animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(values.count - 1, 1))
            layer.add(animation, forKey: keyPath)
        }
        switch index {
        case 0: // star: spin and pop
            keyframes("transform.rotation.z", [0, CGFloat.pi * 2], 0.6)
            keyframes("transform.scale", [1, 1.3, 1], 0.6)
        case 1: // changes: wiggle
            keyframes("transform.rotation.z", [0, -0.35, 0.3, -0.2, 0.1, 0], 0.55)
        case 2: // globe: roll around
            keyframes("transform.rotation.z", [0, CGFloat.pi * 2], 0.7)
        case 3: // packages: drop and bounce
            keyframes("transform.translation.y", [-14, 4, -5, 0], 0.55)
            keyframes("transform.scale", [0.85, 1.1, 1], 0.55)
        case 4: // search: sweep like looking around
            keyframes("transform.rotation.z", [0, -0.5, 0.5, -0.25, 0], 0.6)
            keyframes("transform.scale", [1, 1.2, 1], 0.6)
        default:
            keyframes("transform.scale", [1, 1.25, 1], 0.4)
        }
    }

    private func applyFloatingStyle() {
        guard isFloatingEnabled else {
            if let container = floatingBackground {
                container.removeFromSuperview()
                floatingBackground = nil
                floatingAppearance = nil
                floatingItemWidth = 0
                floatingRefreshPending = false
                floatingSettled = false
                floatingTrusted = false
                floatingTrustedReselected = false
                UserDefaults.standard.removeObject(forKey: floatingItemWidthKey)
                UserDefaults.standard.removeObject(forKey: floatingBarWidthKey)
                self.tabBar.alpha = 1
                self.tabBar._blurEnabled = true
                self.tabBar.standardAppearance = originalStandardAppearance ?? UITabBarAppearance()
                self.tabBar.scrollEdgeAppearance = originalScrollEdgeAppearance
                self.tabBar.itemWidth = 0
                self.tabBar.itemSpacing = 0
                self.popupBar.transform = .identity
                applyFloatingPopupShape()
            }
            return
        }
        if floatingBackground == nil {
            originalStandardAppearance = self.tabBar.standardAppearance
            originalScrollEdgeAppearance = self.tabBar.scrollEdgeAppearance
            let appearance = UITabBarAppearance()
            appearance.configureWithTransparentBackground()
            self.tabBar.standardAppearance = appearance
            self.tabBar.scrollEdgeAppearance = appearance
            floatingAppearance = appearance
            var cached = CGFloat(UserDefaults.standard.double(forKey: floatingItemWidthKey))
            let cachedBarWidth = CGFloat(UserDefaults.standard.double(forKey: floatingBarWidthKey))
            // A calibration only holds for the bar width it was measured at
            if floatingReferenceWidth > 0, abs(cachedBarWidth - floatingReferenceWidth) > 1 { cached = 0 }
            if cached > 0 {
                floatingTrusted = true
                // Reuse the saved calibration so the bar appears in its final layout immediately
                floatingItemWidth = cached
                appearance.stackedItemPositioning = .centered
                appearance.stackedItemWidth = cached
                appearance.stackedItemSpacing = 0
                self.tabBar.standardAppearance = appearance
                self.tabBar.scrollEdgeAppearance = appearance
                floatingSettled = true
            } else {
                // Hide until item metrics have been corrected, to avoid a visible shrink
                floatingSettled = false
                self.tabBar.alpha = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    if let self = self, self.isFloatingEnabled { self.revealFloatingTabBar(save: false) }
                }
            }

            let container = UIView()
            container.isUserInteractionEnabled = false
            container.layer.shadowColor = UIColor.black.cgColor
            container.layer.shadowOpacity = 0.2
            container.layer.shadowRadius = 10
            container.layer.shadowOffset = CGSize(width: 0, height: 4)
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
            blur.tag = 1
            blur.clipsToBounds = true
            blur.layer.cornerCurve = .continuous
            container.addSubview(blur)
            self.tabBar.insertSubview(container, at: 0)
            floatingBackground = container
        }
        guard let container = floatingBackground, let blur = container.viewWithTag(1) else { return }
        let barHeight: CGFloat = 78
        // Center the capsule on the visible icon+label row so top/bottom spacing is equal
        var rowMids: [CGFloat] = []
        var colMids: [CGFloat] = []
        func collect(_ view: UIView) {
            for sub in view.subviews {
                if String(describing: type(of: sub)).contains("TabBarButton") {
                    let content = sub.subviews.filter { $0 is UIImageView || $0 is UILabel || String(describing: type(of: $0)).contains("ImageView") }
                    let union = content.reduce(CGRect.null) { $0.union($1.frame) }
                    let rect = union.isNull ? sub.bounds : union
                    rowMids.append(self.tabBar.convert(rect, from: sub).midY)
                    colMids.append(self.tabBar.convert(sub.bounds, from: sub).midX)
                } else {
                    collect(sub)
                }
            }
        }
        collect(self.tabBar)
        guard !rowMids.isEmpty else {
            // Buttons are not laid out yet (cold launch); hide the capsule and retry shortly
            container.isHidden = true
            if floatingRetryCount < 20 {
                floatingRetryCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.applyFloatingStyle() }
            }
            return
        }
        floatingRetryCount = 0
        container.isHidden = TabBarController.popupIsOpen
        let itemMidY = rowMids.reduce(0, +) / CGFloat(rowMids.count)
        let frame = CGRect(x: floatingInset, y: itemMidY - barHeight / 2, width: self.tabBar.bounds.width - floatingInset * 2, height: barHeight)
        container.frame = frame
        if popupIsPresented, self.popupBar.tabBarHeight != floatingPopupTabBarHeight {
            self.popupBar.tabBarHeight = floatingPopupTabBarHeight
        }
        updateFloatingPopupOffset()
        blur.frame = container.bounds
        blur.layer.cornerRadius = barHeight / 2
        container.layer.shadowPath = UIBezierPath(roundedRect: container.bounds, cornerRadius: barHeight / 2).cgPath
        self.tabBar.sendSubviewToBack(container)

        // The system adds its own padding between items, so measure the real pitch
        // and correct itemWidth until five items evenly fill the capsule with a small side margin
        let count = CGFloat(max(self.tabBar.items?.count ?? 1, 1))
        let spacing: CGFloat = 0
        let sideMargin: CGFloat = 20
        let targetPitch = (frame.width - sideMargin * 2) / count
        // Skip correction while a previous change has not been laid out yet, otherwise it would overshoot
        guard !floatingRefreshPending else { return }
        var itemWidth = floatingItemWidth > 0 ? floatingItemWidth : targetPitch.rounded(.down)
        let sortedMids = colMids.sorted()
        if sortedMids.count >= 2, let first = sortedMids.first, let last = sortedMids.last {
            let actualPitch = (last - first) / CGFloat(sortedMids.count - 1)
            if abs(actualPitch - targetPitch) <= 1 {
                floatingTrusted = false
                revealFloatingTabBar()
            } else if floatingTrusted && !floatingTrustedReselected {
                // The saved width is right; the system just has not re-read it yet, so only relayout once
                floatingTrustedReselected = true
                reselectToRefreshItemMetrics()
                return
            } else {
                floatingTrusted = false
                itemWidth = max(20, (itemWidth + targetPitch - actualPitch).rounded(.down))
            }
        }
        // On iOS 13+ the legacy itemWidth/itemSpacing/itemPositioning are overridden by the
        // appearance's stacked* values, so they must be set on the appearance itself
        if let appearance = floatingAppearance, floatingItemWidth != itemWidth || appearance.stackedItemPositioning != .centered {
            floatingItemWidth = itemWidth
            appearance.stackedItemPositioning = .centered
            appearance.stackedItemWidth = itemWidth
            appearance.stackedItemSpacing = spacing
            self.tabBar.standardAppearance = appearance
            self.tabBar.scrollEdgeAppearance = appearance
            // UITabBar only re-reads stacked item metrics on a selection change, so re-select the current tab (tabBar.selectedItem must not be touched directly)
            reselectToRefreshItemMetrics()
        }
    }

    private func reselectToRefreshItemMetrics() {
        floatingRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.selectedIndex = self.selectedIndex
            self.tabBar.setNeedsLayout()
            self.tabBar.layoutIfNeeded()
            self.floatingRefreshPending = false
            self.tabBar.setNeedsLayout()
        }
    }

    override var insetsForBottomDockingView: UIEdgeInsets {
        if UIDevice.current.userInterfaceIdiom == .pad {
            if self.view.bounds.width < ipadModeMinWidth {
                return .zero
            }
            return UIEdgeInsets(top: self.tabBar.frame.height, left: self.view.bounds.width - 320, bottom: 0, right: 0)
        }
        return .zero
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        updateSileoColors()
    }
    
    @objc func updateSileoColors() {
        if UIColor.isDarkModeEnabled {
            self.popupBar.systemBarStyle = .black
            self.popupBar.toolbar.barStyle = .black
        } else {
            self.popupBar.systemBarStyle = .default
            self.popupBar.toolbar.barStyle = .default
        }
    }
    
    // MARK: - Queue state

    /// The bar is tapped to open the queue: hide it right away.
    @objc private func popupBarTapped() {
        guard popupBar.popupOpenGestureRecognizer.state == .began else { return }
        TabBarController.popupIsOpen = true
        popupBar.isHidden = true
        popupBarHiddenAt = Date()
        resetFloatingPopupShape()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            if self.popupPresentationState != .open {
                TabBarController.popupIsOpen = false
                self.popupBar.isHidden = false
                self.popupBarHiddenAt = nil
            }
        }
    }

    @objc func popupPresentationController(_ popupPresentationController: UIViewController,
                                           willOpenPopupWithContentController popupContentController: UIViewController,
                                           animated: Bool) {
        // The capsule belongs to the collapsed bar; the open window must not
        // keep its inset frame or its rounding. The bar itself is hidden for
        // the duration, or it shows above the window as it is pushed up.
        TabBarController.popupIsOpen = true
        popupBar.isHidden = true
        popupBarHiddenAt = Date()
        resetFloatingPopupShape()
    }

    @objc func popupPresentationController(_ popupPresentationController: UIViewController,
                                           didOpenPopupWithContentController popupContentController: UIViewController,
                                           animated: Bool) {
        // Once the window covers the screen the bar has no business showing:
        // whatever the opening animation did with it, it goes now.
        TabBarController.popupIsOpen = true
        popupBar.isHidden = true
        popupBarHiddenAt = Date()
        resetFloatingPopupShape()
    }

    @objc func popupPresentationController(_ popupPresentationController: UIViewController,
                                           willClosePopupWithContentController popupContentController: UIViewController,
                                           animated: Bool) {
        // Same reason as the chevron: the window lands on the bar.
        TabBarController.popupIsOpen = false
        popupBar.isHidden = false
        popupBarHiddenAt = nil
        tabBar.alpha = 1
        applyFloatingStyle()
    }

    @objc func popupPresentationController(_ popupPresentationController: UIViewController,
                                           didClosePopupWithContentController popupContentController: UIViewController,
                                           animated: Bool) {
        TabBarController.popupIsOpen = false
        popupBar.isHidden = false
        popupBarHiddenAt = nil
        applyFloatingStyle()
        schedulePopupBarRefresh()
    }

    /// The popup state the framework reports does not change on every route
    /// into the window, so the window is measured instead: an open one fills
    /// the screen, a closed one has no height. The queue bar and the tab bar
    /// step aside while it is open, and come back when it closes.
    private func updatePopupOpenState() {
        let open = popupIsPresented && popupContentView.bounds.height > view.bounds.height * 0.5
        guard open != TabBarController.popupIsOpen else { return }
        TabBarController.popupIsOpen = open
        popupBar.isHidden = open
        tabBar.alpha = open ? 0 : 1
        if open {
            popupBarHiddenAt = Date()
            removePopupCapsule()
        } else {
            popupBarHiddenAt = nil
            revealFloatingTabBar()
            schedulePopupBarRefresh()
        }
    }

    /// The window and the bar are laid out again once the closing animation is
    /// over: both are measured while their frames are still moving, which is
    /// why the window's controls and the bar's capsule were left behind.
    private func schedulePopupBarRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self = self, self.popupIsPresented, !TabBarController.popupIsOpen else { return }
            self.popupContentView.setNeedsLayout()
            self.popupContentView.layoutIfNeeded()
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
            self.popupBar.isHidden = false
            self.popupBar.setNeedsLayout()
            self.popupBar.layoutIfNeeded()
            self.applyFloatingStyle()
            self.applyFloatingPopupShape()
            TabBarController.applyFloatingPopupContentInset(to: self.popupBar)
        }
    }

    override func viewDidLayoutSubviews() {
        NSLog("SileoLog: TabBarController.viewDidLayoutSubviews")
        super.viewDidLayoutSubviews()
        
        self.tabBar.itemPositioning = .centered
        updatePopupOpenState()
        applyFloatingStyle()
        applyFloatingPopupShape()
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.updatePopup(animated: false)
        }
    }
    
    public func displayError(_ string: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.displayError(string)
            }
            return
        }
        let alertController = UIAlertController(title: String(localizationKey: "Unknown", type: .error), message: string, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: String(localizationKey: "OK"), style: .default))
        self.present(alertController, animated: true, completion: nil)
    }
}

extension LNPopupBar {
    /// Exchanged with the bar's own layoutSubviews, so it runs right after the
    /// bar has placed its content.
    @objc func sileo_layoutSubviews() {
        sileo_layoutSubviews()
        TabBarController.applyFloatingPopupContentInset(to: self)
    }
}

