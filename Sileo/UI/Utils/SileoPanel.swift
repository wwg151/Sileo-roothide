//
//  SileoPanel.swift
//  Sileo
//
//  A centred panel of Sileo's own: a frosted card over a dimmed screen, with
//  an optional header, a body that really scrolls and an optional footer.
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

/// The body of a panel: a table without separators, which scrolls whenever its
/// rows do not fit. A row is any view, with a fixed height or its own.
final class SileoPanelTable: UITableView, UITableViewDataSource, UITableViewDelegate {

    struct Item {
        let view: UIView
        let height: CGFloat?

        init(_ view: UIView, height: CGFloat? = nil) {
            self.view = view
            self.height = height
        }
    }

    private(set) var items: [Item] = []

    init() {
        super.init(frame: .zero, style: .plain)
        backgroundColor = .clear
        separatorStyle = .none
        showsVerticalScrollIndicator = true
        indicatorStyle = .default
        alwaysBounceVertical = false
        contentInsetAdjustmentBehavior = .never
        keyboardDismissMode = .onDrag
        rowHeight = UITableView.automaticDimension
        estimatedRowHeight = 64
        dataSource = self
        delegate = self
        register(UITableViewCell.self, forCellReuseIdentifier: "Sileo.PanelCell")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setItems(_ items: [Item]) {
        self.items = items
        reloadData()
        invalidateIntrinsicContentSize()
    }

    /// The height every row asks for, once laid out at the given width.
    func contentHeight(for width: CGFloat) -> CGFloat {
        items.reduce(0) { total, item in
            total + (item.height ?? item.view.systemLayoutSizeFitting(
                CGSize(width: width, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = items[indexPath.row]
        guard let height = item.height else { return UITableView.automaticDimension }
        return height
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Sileo.PanelCell", for: indexPath)
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }

        let item = items[indexPath.row]
        let view = item.view
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
            view.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor)
        ])
        return cell
    }
}

class SileoPanelViewController: UIViewController {

    // MARK: - Content

    /// The rows of the body. Add them before the panel is presented.
    let table = SileoPanelTable()

    private(set) var headerView: UIView?
    private(set) var footerView: UIView?
    private var customBody: UIView?

    // MARK: - Chrome

    private let dimView = UIView()
    private let card = UIView()
    private let cardEffect = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let bodyContainer = UIView()
    private let rootStack = UIStackView()

    private var cardWidthConstraint: NSLayoutConstraint!
    private var cardHeightConstraint: NSLayoutConstraint!
    private var cardCenterYConstraint: NSLayoutConstraint!
    private var bodyHeightConstraint: NSLayoutConstraint!

    private let titleText: String?
    private let subtitleText: String?
    private let iconName: String?

    private var hasAppeared = false
    private var isClosing = false

    private static let horizontalInset: CGFloat = 16

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

        // A dimmed screen only: the card itself is the frosted part.
        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        dimView.alpha = 0
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeTapped)))
        view.addSubview(dimView)

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

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        // the footer may already be in place, so the body goes above it
        rootStack.insertArrangedSubview(bodyContainer, at: headerView == nil ? 0 : 1)

        if let customBody = customBody {
            customBody.translatesAutoresizingMaskIntoConstraints = false
            bodyContainer.addSubview(customBody)
            NSLayoutConstraint.activate([
                customBody.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
                customBody.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
                customBody.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
                customBody.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor)
            ])
        } else {
            table.translatesAutoresizingMaskIntoConstraints = false
            bodyContainer.addSubview(table)
            NSLayoutConstraint.activate([
                table.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor, constant: SileoPanelViewController.horizontalInset),
                table.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor, constant: -SileoPanelViewController.horizontalInset),
                table.topAnchor.constraint(equalTo: bodyContainer.topAnchor, constant: 8),
                table.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor, constant: -8)
            ])
        }

        cardWidthConstraint = card.widthAnchor.constraint(equalToConstant: 320)
        cardHeightConstraint = card.heightAnchor.constraint(equalToConstant: 200)
        cardHeightConstraint.priority = UILayoutPriority(999)
        cardCenterYConstraint = card.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        bodyHeightConstraint = bodyContainer.heightAnchor.constraint(equalToConstant: 120)
        bodyHeightConstraint.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
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

            bodyHeightConstraint
        ])
        cardCenterYConstraint.isActive = true

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification,
                                               object: nil)
    }

    /// Keeps the card clear of the keyboard when a search field is in use.
    @objc private func keyboardChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(frame, from: nil).minY)
        cardCenterYConstraint.constant = -min(overlap / 2, 140)
        UIView.animate(withDuration: 0.25) {
            self.view.layoutIfNeeded()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let width = min(340, view.bounds.width - 40)
        let inner = width - SileoPanelViewController.horizontalInset * 2
        let maxCardHeight = view.bounds.height * 0.78

        var headerHeight: CGFloat = 0
        if let header = headerView {
            headerHeight = header.systemLayoutSizeFitting(
                CGSize(width: width, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height

        }

        var footerHeight: CGFloat = 0
        if let footer = footerView {
            footerHeight = footer.systemLayoutSizeFitting(
                CGSize(width: width, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }

        let wantedBody: CGFloat
        if customBody != nil {
            wantedBody = maxCardHeight - headerHeight - footerHeight
        } else {
            wantedBody = table.contentHeight(for: inner) + 16
        }
        let bodyHeight = max(44, min(wantedBody, maxCardHeight - headerHeight - footerHeight))
        let cardHeight = headerHeight + bodyHeight + footerHeight

        if abs(cardWidthConstraint.constant - width) > 0.5 { cardWidthConstraint.constant = width }
        if abs(cardHeightConstraint.constant - cardHeight) > 0.5 { cardHeightConstraint.constant = cardHeight }
        if abs(bodyHeightConstraint.constant - bodyHeight) > 0.5 { bodyHeightConstraint.constant = bodyHeight }

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
        title.numberOfLines = 2

        let labels = UIStackView(arrangedSubviews: [title])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.axis = .vertical
        labels.spacing = 2
        labels.alignment = .fill

        if let subtitleText = self.subtitleText, !subtitleText.isEmpty {
            let subtitle = UILabel()
            subtitle.text = subtitleText
            subtitle.font = .systemFont(ofSize: 13)
            subtitle.textColor = .secondaryLabel
            subtitle.numberOfLines = 0
            labels.addArrangedSubview(subtitle)
        }
        container.addSubview(labels)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            badge.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            badge.widthAnchor.constraint(equalToConstant: 44),
            badge.heightAnchor.constraint(equalToConstant: 44),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            labels.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            labels.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            labels.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            badge.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16)
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
    }

    /// A body of your own instead of rows, filling the card and scrolling
    /// inside itself. Set it before the panel is presented.
    func setBody(_ view: UIView) {
        customBody = view
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
            self.dimView.alpha = 1
            self.card.transform = .identity
            self.card.alpha = 1
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func close(completion: (() -> Void)? = nil) {
        guard !isClosing else { return }
        isClosing = true
        view.endEditing(true)
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn]) {
            self.dimView.alpha = 0
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
            dimView.alpha = max(0.35, 1 - translation / 260)
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view).y
            if translation > 80 || velocity > 700 {
                close()
            } else {
                UIView.animate(withDuration: 0.3, delay: 0,
                               usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                               options: [.allowUserInteraction]) {
                    self.card.transform = .identity
                    self.dimView.alpha = 1
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

    /// A row of a list: a title, an optional second line, and a mark that
    /// shows the current choice.
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
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        let check = UIImageView(image: UIImage(systemName: selected ? "checkmark.circle.fill" : "circle"))
        check.translatesAutoresizingMaskIntoConstraints = false
        check.tintColor = selected ? .tintColor : .tertiaryLabel
        check.contentMode = .scaleAspectFit
        row.addSubview(check)

        var constraints = [
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            check.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            check.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 22),
            check.heightAnchor.constraint(equalToConstant: 22),
            label.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -12)
        ]

        if let detail = detail, !detail.isEmpty {
            let detailLabel = UILabel()
            detailLabel.text = detail
            detailLabel.font = .systemFont(ofSize: 13)
            detailLabel.textColor = .secondaryLabel
            detailLabel.numberOfLines = 1
            detailLabel.lineBreakMode = .byTruncatingMiddle
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(detailLabel)
            constraints += [
                detailLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -12),
                detailLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
                detailLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)
            ]
        } else {
            constraints += [
                label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    /// A row with a title and a detail on the same line, and no mark.
    static func detailRow(title: String,
                          detail: String?,
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
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        var constraints = [
            row.heightAnchor.constraint(equalToConstant: 52),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ]

        if let detail = detail, !detail.isEmpty {
            let detailLabel = UILabel()
            detailLabel.text = detail
            detailLabel.font = .systemFont(ofSize: 13)
            detailLabel.textColor = .secondaryLabel
            detailLabel.textAlignment = .right
            detailLabel.numberOfLines = 1
            detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(detailLabel)
            constraints += [
                detailLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                detailLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -12)
            ]
        } else {
            constraints.append(label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -16))
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
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 34),
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
    static func capsuleButton(title: String,
                              filled: Bool = true,
                              color: UIColor = .tintColor,
                              handler: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.layer.cornerRadius = 22
        button.layer.cornerCurve = .continuous
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        if filled {
            button.backgroundColor = color
            button.setTitleColor(.white, for: .normal)
            button.setTitleColor(UIColor.white.withAlphaComponent(0.6), for: .disabled)
        } else {
            button.backgroundColor = .clear
            button.setTitleColor(color, for: .normal)
            button.setTitleColor(.tertiaryLabel, for: .disabled)
            button.layer.borderWidth = 0.5
            button.layer.borderColor = color.withAlphaComponent(0.4).cgColor
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
        block.isLayoutMarginsRelativeArrangement = true
        block.layoutMargins = UIEdgeInsets(top: 20, left: 8, bottom: 4, right: 8)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            titleLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -8),
            messageLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 8),
            messageLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -8)
        ])

        panel.table.setItems([SileoPanelTable.Item(block)])

        // 取消 on the left, the answer on the right, both the same width.
        let cancel = capsuleButton(title: String(localizationKey: "Cancel"), filled: false) { [weak panel] in
            panel?.close()
        }
        let accept = capsuleButton(title: confirmTitle,
                                   filled: true,
                                   color: destructive ? .systemRed : .tintColor) { [weak panel] in
            panel?.close { onConfirm() }
        }
        let footer = UIStackView(arrangedSubviews: [cancel, accept])
        footer.axis = .horizontal
        footer.spacing = 10
        footer.distribution = .fillEqually
        panel.setFooter(footer)
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
        block.isLayoutMarginsRelativeArrangement = true
        block.layoutMargins = UIEdgeInsets(top: 20, left: 8, bottom: 4, right: 8)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            titleLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -8),
            messageLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 8),
            messageLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -8)
        ])

        panel.table.setItems([
            SileoPanelTable.Item(block),
            SileoPanelTable.Item(row(title: String(localizationKey: "OK")) { [weak panel] in
                panel?.close()
            })
        ])
        return panel
    }
}
