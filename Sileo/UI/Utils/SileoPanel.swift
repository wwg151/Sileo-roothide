//
//  SileoPanel.swift
//  Sileo
//
//  A centred panel of Sileo's own: a frosted card over a dimmed and blurred
//  screen, with an optional header, a scrolling body and an optional footer.
//  Rows carry no separators; the card follows the system's light and dark
//  appearance.
//

import UIKit

/// A row that lights up while a finger is on it.
final class SileoPanelRow: UIControl {

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted
                ? UIColor.label.withAlphaComponent(0.08)
                : .clear
        }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }
}

class SileoPanelViewController: UIViewController {

    // MARK: - Content

    /// Rows and other views go here, top to bottom.
    let contentStack = UIStackView()
    private(set) var headerView: UIView?
    private(set) var footerView: UIView?

    // MARK: - Chrome

    private let dimBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let dimTint = UIView()
    private let card = UIView()
    private let cardEffect = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let scroll = UIScrollView()
    private let rootStack = UIStackView()
    private let fadeMask = CAGradientLayer()

    private var cardWidthConstraint: NSLayoutConstraint!
    private var cardHeightConstraint: NSLayoutConstraint!
    private var scrollHeightConstraint: NSLayoutConstraint!
    private var contentWidthConstraint: NSLayoutConstraint!

    private let titleText: String?
    private let subtitleText: String?
    private let iconName: String?

    private var hasAppeared = false
    private var isClosing = false

    init(title: String? = nil, subtitle: String? = nil, icon: String? = nil) {
        self.titleText = title
        self.subtitleText = subtitle
        self.iconName = icon
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimBlur.translatesAutoresizingMaskIntoConstraints = false
        dimBlur.alpha = 0
        view.addSubview(dimBlur)

        dimTint.translatesAutoresizingMaskIntoConstraints = false
        dimTint.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        dimTint.alpha = 0
        dimTint.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeTapped)))
        view.addSubview(dimTint)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.22
        card.layer.shadowRadius = 30
        card.layer.shadowOffset = CGSize(width: 0, height: 12)
        view.addSubview(card)
        card.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))

        cardEffect.translatesAutoresizingMaskIntoConstraints = false
        cardEffect.layer.cornerRadius = 20
        cardEffect.layer.cornerCurve = .continuous
        cardEffect.clipsToBounds = true
        cardEffect.layer.borderWidth = 0.5
        cardEffect.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        card.addSubview(cardEffect)

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .vertical
        rootStack.spacing = 0
        cardEffect.contentView.addSubview(rootStack)

        if let header = makeHeader() {
            headerView = header
            rootStack.insertArrangedSubview(header, at: 0)
        }

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        // the footer may already be in place, so the body goes above it
        rootStack.insertArrangedSubview(scroll, at: headerView == nil ? 0 : 1)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 0
        scroll.addSubview(contentStack)

        cardWidthConstraint = card.widthAnchor.constraint(equalToConstant: 320)
        cardHeightConstraint = card.heightAnchor.constraint(equalToConstant: 200)
        cardHeightConstraint.priority = UILayoutPriority(999)
        scrollHeightConstraint = scroll.heightAnchor.constraint(equalToConstant: 120)
        scrollHeightConstraint.priority = UILayoutPriority(999)
        contentWidthConstraint = contentStack.widthAnchor.constraint(equalToConstant: 288)

        NSLayoutConstraint.activate([
            dimBlur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimBlur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimBlur.topAnchor.constraint(equalTo: view.topAnchor),
            dimBlur.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            dimTint.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimTint.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimTint.topAnchor.constraint(equalTo: view.topAnchor),
            dimTint.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cardWidthConstraint,
            cardHeightConstraint,

            cardEffect.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            cardEffect.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            cardEffect.topAnchor.constraint(equalTo: card.topAnchor),
            cardEffect.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            rootStack.leadingAnchor.constraint(equalTo: cardEffect.contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: cardEffect.contentView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: cardEffect.contentView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: cardEffect.contentView.bottomAnchor),

            scrollHeightConstraint,

            contentStack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            contentWidthConstraint
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let width = min(340, view.bounds.width - 40)
        let inner = width - 32
        if abs(contentWidthConstraint.constant - inner) > 0.5 {
            contentWidthConstraint.constant = inner
        }

        let contentHeight = contentStack.systemLayoutSizeFitting(CGSize(width: inner, height: 0),
                                                                 withHorizontalFittingPriority: .required,
                                                                 verticalFittingPriority: .fittingSizeLevel).height + 24
        let headerHeight: CGFloat = headerView == nil ? 0 : 76
        let footerHeight: CGFloat = footerView.map {
            $0.systemLayoutSizeFitting(CGSize(width: inner, height: 0),
                                       withHorizontalFittingPriority: .required,
                                       verticalFittingPriority: .fittingSizeLevel).height
        } ?? 0

        let maxHeight = view.bounds.height * 0.72
        let cardHeight = min(headerHeight + contentHeight + footerHeight, maxHeight)
        let scrollHeight = max(0, cardHeight - headerHeight - footerHeight)

        if abs(cardWidthConstraint.constant - width) > 0.5 { cardWidthConstraint.constant = width }
        if abs(cardHeightConstraint.constant - cardHeight) > 0.5 { cardHeightConstraint.constant = cardHeight }
        if abs(scrollHeightConstraint.constant - scrollHeight) > 0.5 { scrollHeightConstraint.constant = scrollHeight }

        // The edges of a list that scrolls fade out instead of a separator.
        if contentHeight > scrollHeight + 0.5, scrollHeight > 0 {
            fadeMask.frame = CGRect(x: 0, y: 0, width: width, height: scrollHeight)
            fadeMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor,
                               UIColor.black.cgColor, UIColor.clear.cgColor]
            fadeMask.locations = [0, 0.035, 0.965, 1]
            fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
            fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
            scroll.layer.mask = fadeMask
        } else {
            scroll.layer.mask = nil
        }

        card.layer.shadowPath = UIBezierPath(roundedRect: card.bounds, cornerRadius: 20).cgPath
    }

    // MARK: - Header and footer

    private func makeHeader() -> UIView? {
        guard let titleText = self.titleText, !titleText.isEmpty else { return nil }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.backgroundColor = .tertiarySystemFill
        badge.layer.cornerRadius = 12
        badge.layer.cornerCurve = .continuous
        container.addSubview(badge)

        let icon = UIImageView(image: UIImage(systemName: iconName ?? "square.stack.3d.up.fill"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .label
        icon.contentMode = .scaleAspectFit
        badge.addSubview(icon)

        let title = UILabel()
        title.text = titleText
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .label
        title.numberOfLines = 1
        title.lineBreakMode = .byTruncatingMiddle

        let labels = UIStackView(arrangedSubviews: [title])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.axis = .vertical
        labels.spacing = 2
        labels.alignment = .leading

        if let subtitleText = self.subtitleText, !subtitleText.isEmpty {
            let subtitle = UILabel()
            subtitle.text = subtitleText
            subtitle.font = .systemFont(ofSize: 13)
            subtitle.textColor = .secondaryLabel
            subtitle.numberOfLines = 2
            labels.addArrangedSubview(subtitle)
        }
        container.addSubview(labels)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 76),
            badge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            badge.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 44),
            badge.heightAnchor.constraint(equalToConstant: 44),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            labels.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            labels.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    /// A button or a row of buttons under the body, inside the same card.
    func setFooter(_ view: UIView?) {
        footerView?.removeFromSuperview()
        footerView = nil
        guard let view = view else { return }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        footerView = container
        rootStack.addArrangedSubview(container)
        view.setNeedsLayout()
    }

    // MARK: - Presentation

    func present(from host: UIViewController) {
        host.present(self, animated: false) { [weak self] in
            self?.animateIn()
        }
    }

    private func animateIn() {
        guard !hasAppeared else { return }
        hasAppeared = true
        card.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        card.alpha = 0
        UIView.animate(withDuration: 0.34, delay: 0,
                       usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .curveEaseOut]) {
            self.dimBlur.alpha = 1
            self.dimTint.alpha = 1
            self.card.transform = .identity
            self.card.alpha = 1
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func close(completion: (() -> Void)? = nil) {
        guard !isClosing else { return }
        isClosing = true
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn]) {
            self.dimBlur.alpha = 0
            self.dimTint.alpha = 0
            self.card.alpha = 0
            self.card.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        } completion: { _ in
            self.dismiss(animated: false) {
                completion?()
            }
        }
    }

    @objc private func closeTapped() {
        close()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = max(0, gesture.translation(in: view).y)
        switch gesture.state {
        case .changed:
            card.transform = CGAffineTransform(translationX: 0, y: translation)
            let fade = max(0.35, 1 - translation / 260)
            dimBlur.alpha = fade
            dimTint.alpha = fade
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view).y
            if translation > 80 || velocity > 700 {
                close()
            } else {
                UIView.animate(withDuration: 0.3, delay: 0,
                               usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                               options: [.allowUserInteraction]) {
                    self.card.transform = .identity
                    self.dimBlur.alpha = 1
                    self.dimTint.alpha = 1
                }
            }
        default:
            break
        }
    }
}

// MARK: - Rows and buttons

extension SileoPanelViewController {

    /// A plain action row: the title on the left, the icon at the right edge.
    static func row(title: String,
                    iconName: String? = nil,
                    destructive: Bool = false,
                    enabled: Bool = true,
                    handler: @escaping () -> Void) -> SileoPanelRow {
        let row = SileoPanelRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.isEnabled = enabled
        row.addAction(UIAction { _ in handler() }, for: .touchUpInside)

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 17)
        label.textColor = enabled ? (destructive ? .systemRed : .label) : .tertiaryLabel
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        var constraints = [
            row.heightAnchor.constraint(equalToConstant: 48),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ]

        if let iconName = iconName {
            let image = UIImageView(image: UIImage(systemName: iconName))
            image.translatesAutoresizingMaskIntoConstraints = false
            image.tintColor = label.textColor
            image.contentMode = .scaleAspectFit
            row.addSubview(image)
            constraints += [
                image.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                image.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 22),
                image.heightAnchor.constraint(equalToConstant: 22),
                label.trailingAnchor.constraint(lessThanOrEqualTo: image.leadingAnchor, constant: -12)
            ]
        } else {
            constraints.append(label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -16))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    /// A row of a list: a title, an optional detail at the right, and a mark
    /// that shows the current choice.
    static func choiceRow(title: String,
                          detail: String?,
                          selected: Bool,
                          handler: @escaping () -> Void) -> SileoPanelRow {
        let row = SileoPanelRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addAction(UIAction { _ in handler() }, for: .touchUpInside)

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 17)
        label.textColor = .label
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        let check = UIImageView(image: UIImage(systemName: selected ? "checkmark.circle.fill" : "circle"))
        check.translatesAutoresizingMaskIntoConstraints = false
        check.tintColor = selected ? .tintColor : .tertiaryLabel
        check.contentMode = .scaleAspectFit
        row.addSubview(check)

        var constraints = [
            row.heightAnchor.constraint(equalToConstant: 52),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            check.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            check.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 22),
            check.heightAnchor.constraint(equalToConstant: 22)
        ]

        if let detail = detail, !detail.isEmpty {
            let detailLabel = UILabel()
            detailLabel.text = detail
            detailLabel.font = .systemFont(ofSize: 13)
            detailLabel.textColor = .secondaryLabel
            detailLabel.textAlignment = .right
            detailLabel.numberOfLines = 1
            detailLabel.lineBreakMode = .byTruncatingMiddle
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(detailLabel)
            constraints += [
                detailLabel.trailingAnchor.constraint(equalTo: check.leadingAnchor, constant: -10),
                detailLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
                label.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -12)
            ]
        } else {
            constraints.append(label.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -12))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    /// A small heading that groups rows, with no line under it.
    static func sectionLabel(_ text: String) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 32),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])
        return container
    }

    static func spacer(_ height: CGFloat) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    /// A capsule button for the footer.
    static func capsuleButton(title: String, filled: Bool = true, handler: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.layer.cornerRadius = 22
        button.layer.cornerCurve = .continuous
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.setTitleColor(.tintColor, for: .normal)
        button.setTitleColor(.tertiaryLabel, for: .disabled)
        if filled {
            button.backgroundColor = UIColor.tintColor.withAlphaComponent(0.16)
        } else {
            button.backgroundColor = .clear
            button.layer.borderWidth = 0.5
            button.layer.borderColor = UIColor.tintColor.withAlphaComponent(0.4).cgColor
        }
        button.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        return button
    }

    // MARK: - Ready-made panels

    /// A question with a red answer, in place of the system's alert.
    static func confirm(title: String,
                        message: String,
                        confirmTitle: String,
                        destructive: Bool = true,
                        onConfirm: @escaping () -> Void) -> SileoPanelViewController {
        let panel = SileoPanelViewController()

        let icon = UIImageView(image: UIImage(systemName: destructive
            ? "exclamationmark.triangle.fill"
            : "questionmark.circle.fill"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = destructive ? .systemRed : .tintColor
        icon.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let block = UIStackView(arrangedSubviews: [icon, titleLabel, messageLabel])
        block.translatesAutoresizingMaskIntoConstraints = false
        block.axis = .vertical
        block.spacing = 8
        block.alignment = .center
        panel.contentStack.addArrangedSubview(block)
        panel.contentStack.addArrangedSubview(spacer(12))

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            titleLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor)
        ])

        panel.contentStack.addArrangedSubview(row(title: confirmTitle, destructive: destructive) { [weak panel] in
            panel?.close { onConfirm() }
        })
        panel.contentStack.addArrangedSubview(row(title: String(localizationKey: "Cancel")) { [weak panel] in
            panel?.close()
        })
        return panel
    }

    /// A note with one way out, in place of the system's alert.
    static func message(title: String, message: String) -> SileoPanelViewController {
        let panel = SileoPanelViewController()

        let icon = UIImageView(image: UIImage(systemName: "info.circle.fill"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .tintColor
        icon.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let block = UIStackView(arrangedSubviews: [icon, titleLabel, messageLabel])
        block.translatesAutoresizingMaskIntoConstraints = false
        block.axis = .vertical
        block.spacing = 8
        block.alignment = .center
        panel.contentStack.addArrangedSubview(block)
        panel.contentStack.addArrangedSubview(spacer(12))

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            titleLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor)
        ])

        panel.contentStack.addArrangedSubview(row(title: String(localizationKey: "OK")) { [weak panel] in
            panel?.close()
        })
        return panel
    }
}
