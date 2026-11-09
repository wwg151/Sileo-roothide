//
//  GlassCardTransition.swift
//  Sileo
//
//  The profile card: it grows out of the avatar, wears a glass background, and
//  can be dragged down and thrown back with the finger's own speed.
//

import UIKit

final class GlassCardTransition: NSObject, UIViewControllerTransitioningDelegate {

    /// The avatar the card grows out of, in window coordinates.
    weak var sourceView: UIView?

    private let presentAnimator = GlassCardAnimator(presenting: true)
    private let dismissAnimator = GlassCardAnimator(presenting: false)
    private lazy var interaction = GlassCardInteraction(transition: self)

    func animationController(forPresented presented: UIViewController,
                             presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        presentAnimator.sourceFrame = sourceView?.superview?.convert(sourceView?.frame ?? .zero, to: nil)
        return presentAnimator
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        dismissAnimator.sourceFrame = sourceView?.superview?.convert(sourceView?.frame ?? .zero, to: nil)
        return dismissAnimator
    }

    func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        interaction.isInteractive ? interaction : nil
    }

    func presentationController(forPresented presented: UIViewController,
                                presenting: UIViewController?,
                                source: UIViewController) -> UIPresentationController? {
        let controller = GlassCardPresentationController(presentedViewController: presented, presenting: presenting)
        controller.interaction = interaction
        interaction.presentation = controller
        return controller
    }
}

// MARK: - Presentation

final class GlassCardPresentationController: UIPresentationController {

    fileprivate var interaction: GlassCardInteraction?
    private let dimming = UIView()
    private let grabber = UIView()
    /// How much of the screen the card covers at the top.
    static let topInset: CGFloat = 10
    static let cornerRadius: CGFloat = 34

    var cardFrame: CGRect {
        let bounds = containerView?.bounds ?? UIScreen.main.bounds
        return CGRect(x: 0, y: Self.topInset, width: bounds.width, height: bounds.height - Self.topInset)
    }

    override var frameOfPresentedViewInContainerView: CGRect { cardFrame }

    override func presentationTransitionWillBegin() {
        guard let containerView = containerView, let presented = presentedView else { return }

        // The settings' own backgrounds step aside so the glass is what is seen.
        if let nav = presentedViewController as? UINavigationController {
            nav.view.backgroundColor = .clear
            nav.navigationBar.setBackgroundImage(UIImage(), for: .default)
            nav.navigationBar.shadowImage = UIImage()
            nav.navigationBar.isTranslucent = true
            for controller in nav.viewControllers {
                controller.view.backgroundColor = .clear
                (controller as? UITableViewController)?.tableView.backgroundColor = .clear
            }
        }

        dimming.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        dimming.frame = containerView.bounds
        dimming.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimming.alpha = 0
        containerView.addSubview(dimming)

        // The card itself is a sheet of glass: the settings' own backgrounds are
        // cleared so it shows through them.
        let glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        glass.frame = presented.bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.isUserInteractionEnabled = false
        presented.insertSubview(glass, at: 0)

        presented.layer.cornerRadius = Self.cornerRadius
        presented.layer.cornerCurve = .continuous
        presented.clipsToBounds = true

        grabber.backgroundColor = UIColor.tertiaryLabel
        grabber.frame = CGRect(x: (containerView.bounds.width - 36) / 2, y: 8, width: 36, height: 5)
        grabber.layer.cornerRadius = 2.5
        grabber.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]
        presented.addSubview(grabber)

        let pan = UIPanGestureRecognizer(target: interaction, action: #selector(GlassCardInteraction.handlePan(_:)))
        presented.addGestureRecognizer(pan)

        presentedViewController.transitionCoordinator?.animate(alongsideTransition: { _ in
            self.dimming.alpha = 1
        })
    }

    override func dismissalTransitionWillBegin() {
        presentedViewController.transitionCoordinator?.animate(alongsideTransition: { _ in
            self.dimming.alpha = 0
        })
    }

    override func containerViewDidLayoutSubviews() {
        super.containerViewDidLayoutSubviews()
        dimming.frame = containerView?.bounds ?? .zero
    }
}

// MARK: - Animator

final class GlassCardAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let presenting: Bool
    /// The avatar's frame, in window coordinates.
    var sourceFrame: CGRect?

    init(presenting: Bool) {
        self.presenting = presenting
    }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        presenting ? 0.46 : 0.38
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let container = context.containerView

        if presenting {
            guard let to = context.view(forKey: .to), let from = context.view(forKey: .from) else {
                context.completeTransition(false)
                return
            }
            container.addSubview(to)
            to.frame = context.finalFrame(for: context.viewController(forKey: .to)!)
            to.layoutIfNeeded()

            // Where the card starts: the avatar, on screen.
            let start = sourceFrame ?? CGRect(x: to.frame.midX - 20, y: to.frame.midY - 20, width: 40, height: 40)
            let scale = max(0.06, start.width / to.bounds.width)
            let deltaX = start.midX - to.frame.midX
            let deltaY = start.midY - to.frame.midY
            to.transform = CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: deltaX / scale, y: deltaY / scale))
            to.alpha = 0
            to.layer.cornerRadius = 20

            // The page behind steps back a little, for depth.
            from.layer.cornerRadius = 0
            from.transform = .identity

            let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), dampingRatio: 0.86) {
                to.transform = .identity
                to.alpha = 1
                to.layer.cornerRadius = GlassCardPresentationController.cornerRadius
                from.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
                from.layer.cornerRadius = 14
            }
            animator.addCompletion { _ in
                from.transform = .identity
                from.layer.cornerRadius = 0
                context.completeTransition(!context.transitionWasCancelled)
            }
            animator.startAnimation()
        } else {
            guard let from = context.view(forKey: .from), let to = context.view(forKey: .to) else {
                context.completeTransition(false)
                return
            }
            container.insertSubview(to, belowSubview: from)

            let start = sourceFrame ?? CGRect(x: from.frame.midX - 20, y: from.frame.midY - 20, width: 40, height: 40)
            let scale = max(0.06, start.width / from.bounds.width)
            let deltaX = start.midX - from.frame.midX
            let deltaY = start.midY - from.frame.midY
            let target = CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: deltaX / scale, y: deltaY / scale))

            to.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            to.layer.cornerRadius = 14

            let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), dampingRatio: 0.9) {
                from.transform = target
                from.alpha = 0
                from.layer.cornerRadius = 20
                to.transform = .identity
                to.layer.cornerRadius = 0
            }
            animator.addCompletion { _ in
                from.transform = .identity
                from.alpha = 1
                to.transform = .identity
                to.layer.cornerRadius = 0
                context.completeTransition(!context.transitionWasCancelled)
            }
            animator.startAnimation()
        }
    }
}

// MARK: - Interactive dismissal

final class GlassCardInteraction: UIPercentDrivenInteractiveTransition {

    fileprivate weak var presentation: GlassCardPresentationController?
    private weak var transition: GlassCardTransition?
    private var pan: UIPanGestureRecognizer?

    fileprivate var isInteractive = false

    init(transition: GlassCardTransition) {
        self.transition = transition
        super.init()
        wantsInteractiveStart = false
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let translation = gesture.translation(in: view).y
        let velocity = gesture.velocity(in: view).y
        let height = max(1, view.bounds.height)

        switch gesture.state {
        case .began:
            isInteractive = true
            pan = gesture
            view.window?.rootViewController?.dismiss(animated: true)
        case .changed:
            // Only downward drags close it; the card follows the finger.
            let progress = max(0, min(1, translation / (height * 0.7)))
            update(progress)
        case .ended, .cancelled:
            let progress = max(0, min(1, translation / (height * 0.7)))
            // Thrown down, or dragged far enough: it goes. Otherwise it springs back.
            if velocity > 800 || progress > 0.32 {
                finish()
            } else {
                cancel()
            }
            isInteractive = false
            pan = nil
        default:
            break
        }
    }
}
