//
//  SileoPreviewMenu.swift
//  Sileo
//
//  The long-press sheet for a package row, built out of Sileo's own parts:
//  the package page as the live preview on top, and the actions as rows of the
//  card beneath it, with no separators and colours that follow the system's
//  light and dark appearance. A tap on the preview opens the page.
//

import UIKit

final class SileoPreviewMenu: UIViewController {

    private let pageController: UIViewController?
    private let items: [SileoActionMenuItem]
    private let commit: (() -> Void)?

    private let dimView = UIView()
    private let card = UIView()
    private let previewPane = UIView()
    private let rowsStack = UIStackView()

    private var cardWidthConstraint: NSLayoutConstraint!
    private var cardLeadingConstraint: NSLayoutConstraint!
    private var cardTopConstraint: NSLayoutConstraint!
    private var previewHeightConstraint: NSLayoutConstraint?

    private static let rowHeight: CGFloat = 44
    private static let cornerRadius: CGFloat = 14

    init(page: UIViewController?,
         items: [SileoActionMenuItem],
         commit: (() -> Void)? = nil) {
        self.pageController = page
        self.items = items
        self.commit = commit
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissSelf)))
        view.addSubview(dimView)

        card.translatesAutoresizingMaskIntoConstraints = false
        // White on a light appearance, black on a dark one, and the text follows.
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = SileoPreviewMenu.cornerRadius
        card.layer.cornerCurve = .continuous
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.18
        card.layer.shadowRadius = 24
        card.layer.shadowOffset = CGSize(width: 0, height: 8)
        card.clipsToBounds = false
        view.addSubview(card)

        if let page = pageController {
            previewPane.translatesAutoresizingMaskIntoConstraints = false
            // the page's own content stops at the pane, so only its top shows
            previewPane.clipsToBounds = true
            previewPane.backgroundColor = .systemBackground
            card.addSubview(previewPane)

            page.willMove(toParent: self)
            page.view.translatesAutoresizingMaskIntoConstraints = false
            previewPane.addSubview(page.view)
            page.didMove(toParent: self)
            NSLayoutConstraint.activate([
                previewPane.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                previewPane.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                previewPane.topAnchor.constraint(equalTo: card.topAnchor),

                page.view.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
                page.view.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
                page.view.topAnchor.constraint(equalTo: previewPane.topAnchor),
                page.view.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor)
            ])

            let heightConstraint = previewPane.heightAnchor.constraint(equalToConstant: 0)
            previewHeightConstraint = heightConstraint

            // the pane eats every touch of the page; a tap is the commit that
            // opens the page full height, the way the system preview does
            let commitPane = UIControl()
            commitPane.translatesAutoresizingMaskIntoConstraints = false
            commitPane.addTarget(self, action: #selector(commitTapped), for: .touchUpInside)
            previewPane.addSubview(commitPane)
            NSLayoutConstraint.activate([
                commitPane.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
                commitPane.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
                commitPane.topAnchor.constraint(equalTo: previewPane.topAnchor),
                commitPane.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor),
                heightConstraint
            ])
        }

        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.axis = .vertical
        rowsStack.spacing = 0
        rowsStack.alignment = .fill
        rowsStack.distribution = .fill
        card.addSubview(rowsStack)

        for (index, item) in items.enumerated() {
            rowsStack.addArrangedSubview(makeRow(item, index: index))
        }

        cardWidthConstraint = card.widthAnchor.constraint(equalToConstant: 360)
        cardLeadingConstraint = card.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        cardTopConstraint = card.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            cardWidthConstraint, cardLeadingConstraint, cardTopConstraint,

            rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: pageController == nil
                ? card.topAnchor
                : previewPane.bottomAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.bottomAnchor.constraint(greaterThanOrEqualTo: rowsStack.bottomAnchor)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCard()
    }

    /// The card is centred: a preview window with the rows under it, in the
    /// shape the system gave that gesture, minus the separators.
    private func layoutCard() {
        let width = min(360, view.bounds.width - 48)
        if pageController != nil {
            let height = min(view.bounds.height * 0.4, 320)
            previewHeightConstraint?.constant = height
        }

        let rowsHeight = rowsStack.systemLayoutSizeFitting(CGSize(width: width, height: 0),
                                                           withHorizontalFittingPriority: .required,
                                                           verticalFittingPriority: .fittingSizeLevel).height
        let cardHeight = (pageController == nil ? 0 : (previewHeightConstraint?.constant ?? 0)) + rowsHeight

        let x = (view.bounds.width - width) / 2
        let y = max(view.safeAreaInsets.top + 8, (view.bounds.height - cardHeight) / 2)

        if abs(cardWidthConstraint.constant - width) > 0.5 { cardWidthConstraint.constant = width }
        if abs(cardLeadingConstraint.constant - x) > 0.5 { cardLeadingConstraint.constant = x }
        if abs(cardTopConstraint.constant - y) > 0.5 { cardTopConstraint.constant = y }
        card.layer.shadowPath = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: cardHeight),
                                             cornerRadius: SileoPreviewMenu.cornerRadius).cgPath
    }

    private func makeRow(_ item: SileoActionMenuItem, index: Int) -> UIView {
        let row = UIControl()
        row.tag = index
        row.isEnabled = item.enabled
        row.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)

        let label = UILabel()
        label.text = item.title
        label.font = .systemFont(ofSize: 17)
        label.textColor = item.enabled ? (item.destructive ? .systemRed : .label) : .tertiaryLabel

        let imageView = UIImageView()
        if let image = item.image {
            imageView.image = image.withRenderingMode(.alwaysTemplate)
        } else if let name = item.imageName {
            imageView.image = UIImage(systemName: name)
        }
        imageView.tintColor = label.textColor
        imageView.contentMode = .scaleAspectFit

        for sub in [label, imageView] as [UIView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            sub.isUserInteractionEnabled = false
            row.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: SileoPreviewMenu.rowHeight),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            imageView.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            imageView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 22),
            imageView.heightAnchor.constraint(equalToConstant: 22),
            label.trailingAnchor.constraint(lessThanOrEqualTo: imageView.leadingAnchor, constant: -12)
        ])

        // A highlight while the finger is down, the same in both appearances.
        row.addAction(UIAction { [weak row] _ in
            UIView.animate(withDuration: 0.12) { row?.backgroundColor = .clear }
        }, for: .touchUpInside)
        row.addAction(UIAction { [weak row] _ in
            UIView.animate(withDuration: 0.12) { row?.backgroundColor = .clear }
        }, for: .touchCancel)
        let highlight = UILongPressGestureRecognizer(target: self, action: #selector(rowPressed(_:)))
        highlight.minimumPressDuration = 0
        highlight.cancelsTouchesInView = false
        row.addGestureRecognizer(highlight)

        return row
    }

    @objc private func rowPressed(_ gesture: UILongPressGestureRecognizer) {
        guard let row = gesture.view else { return }
        let active = gesture.state == .began || gesture.state == .changed
        UIView.animate(withDuration: 0.12) {
            row.backgroundColor = active ? UIColor.label.withAlphaComponent(0.08) : .clear
        }
    }

    @objc private func rowTapped(_ sender: UIControl) {
        guard items.indices.contains(sender.tag) else { return }
        let item = items[sender.tag]
        guard item.enabled else { return }
        dismiss(animated: true) {
            item.handler()
        }
    }

    @objc private func commitTapped() {
        guard let page = self.pageController else { return }
        dismiss(animated: true) { [weak self] in
            page.willMove(toParent: nil)
            page.view.removeFromSuperview()
            page.removeFromParent()
            self?.commit?()
        }
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }
}
