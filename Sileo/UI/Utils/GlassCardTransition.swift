//
//  GlassCardTransition.swift
//  Sileo
//
//  The profile card: it grows out of the avatar into the sheet, over a glass
//  background. The sheet itself is the system's, so dragging it down keeps the
//  finger-following, velocity-matched dismissal it already has.
//

import UIKit

final class GlassCardTransition: NSObject, UIViewControllerTransitioningDelegate {

    /// The avatar the card grows out of, in window coordinates.
    weak var sourceView: UIView?

    private lazy var presentAnimator = GlassCardAnimator(presenting: true)
    private lazy var dismissAnimator = GlassCardAnimator(presenting: false)

    private func avatarFrame() -> CGRect? {
        guard let sourceView = sourceView, let superview = sourceView.superview else { return nil }
        return superview.convert(sourceView.frame, to: nil)
    }

    func animationController(forPresented presented: UIViewController,
                             presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        presentAnimator.sourceFrame = avatarFrame()
        return presentAnimator
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        dismissAnimator.sourceFrame = avatarFrame()
        return dismissAnimator
    }

    /// The settings' own backgrounds step aside so the glass shows through.
    static func makeGlass(in controller: UIViewController) {
        controller.view.backgroundColor = .clear
        if let nav = controller as? UINavigationController {
            nav.view.backgroundColor = .clear
            nav.navigationBar.setBackgroundImage(UIImage(), for: .default)
            nav.navigationBar.shadowImage = UIImage()
            nav.navigationBar.isTranslucent = true
            for child in nav.viewControllers {
                child.view.backgroundColor = .clear
                (child as? UITableViewController)?.tableView.backgroundColor = .clear
            }
        }
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
        presenting ? 0.46 : 0.36
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let container = context.containerView

        if presenting {
            guard let to = context.view(forKey: .to) else {
                context.completeTransition(false)
                return
            }
            container.addSubview(to)
            to.frame = context.finalFrame(for: context.viewController(forKey: .to)!)
            to.layoutIfNeeded()

            // The card is a sheet of glass behind the settings.
            let glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
            glass.frame = to.bounds
            glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            glass.isUserInteractionEnabled = false
            to.insertSubview(glass, at: 0)
            to.clipsToBounds = true

            let start = sourceFrame ?? CGRect(x: to.frame.midX - 20, y: to.frame.midY - 20, width: 40, height: 40)
            let scale = max(0.05, start.width / max(1, to.bounds.width))
            let deltaX = start.midX - to.frame.midX
            let deltaY = start.midY - to.frame.midY
            to.transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: deltaX / scale, y: deltaY / scale))
            to.alpha = 0

            let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), dampingRatio: 0.86) {
                to.transform = .identity
                to.alpha = 1
            }
            animator.addCompletion { _ in
                to.transform = .identity
                to.alpha = 1
                context.completeTransition(!context.transitionWasCancelled)
            }
            animator.startAnimation()
        } else {
            guard let from = context.view(forKey: .from) else {
                context.completeTransition(false)
                return
            }
            let start = sourceFrame ?? CGRect(x: from.frame.midX - 20, y: from.frame.midY - 20, width: 40, height: 40)
            let scale = max(0.05, start.width / max(1, from.bounds.width))
            let deltaX = start.midX - from.frame.midX
            let deltaY = start.midY - from.frame.midY
            let target = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: deltaX / scale, y: deltaY / scale))

            let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), dampingRatio: 0.9) {
                from.transform = target
                from.alpha = 0
            }
            animator.addCompletion { _ in
                from.transform = .identity
                from.alpha = 1
                context.completeTransition(!context.transitionWasCancelled)
            }
            animator.startAnimation()
        }
    }
}
