//
//  SileoActionMenu.swift
//  Sileo
//
//  A card of Sileo's own for a button's choices: one list, no separators, and
//  colours that follow the system's light and dark appearance.
//

import UIKit

struct SileoActionMenuItem {
    let title: String
    let imageName: String?
    let destructive: Bool
    let enabled: Bool
    let handler: () -> Void

    init(title: String,
         imageName: String? = nil,
         destructive: Bool = false,
         enabled: Bool = true,
         handler: @escaping () -> Void) {
        self.title = title
        self.imageName = imageName
        self.destructive = destructive
        self.enabled = enabled
        self.handler = handler
    }
}

final class SileoActionMenu: UIViewController {

    private let header: String?
    private let items: [SileoActionMenuItem]
    private let sourceFrame: CGRect?

    private let dimView = UIView()
    private let card = UIView()
    private let stack = UIStackView()

    private static let rowHeight: CGFloat = 44
    private static let cardWidth: CGFloat = 264
    private static let cornerRadius: CGFloat = 14

    init(header: String?, items: [SileoActionMenuItem], sourceFrame: CGRect? = nil) {
        self.header = header
        self.items = items
        self.sourceFrame = sourceFrame
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
        card.layer.cornerRadius = SileoActionMenu.cornerRadius
        card.layer.cornerCurve = .continuous
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.18
        card.layer.shadowRadius = 24
        card.layer.shadowOffset = CGSize(width: 0, height: 8)
        card.clipsToBounds = false
        view.addSubview(card)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        card.addSubview(stack)

        if let header = header, !header.isEmpty {
            stack.addArrangedSubview(makeHeader(header))
        }
        for (index, item) in items.enumerated() {
            stack.addArrangedSubview(makeRow(item, index: index))
        }

        NSLayoutConstraint.activate([
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCard()
    }

    /// The card sits under the control it was opened from when there is room,
    /// and is kept on screen otherwise.
    private func layoutCard() {
        let insets = view.safeAreaInsets
        let width = min(SileoActionMenu.cardWidth, view.bounds.width - 32)
        let height = stack.systemLayoutSizeFitting(CGSize(width: width, height: 0),
                                                   withHorizontalFittingPriority: .required,
                                                   verticalFittingPriority: .fittingSizeLevel).height
        var origin = CGPoint(x: (view.bounds.width - width) / 2,
                             y: (view.bounds.height - height) / 2)
        if let frame = sourceFrame, !frame.isEmpty {
            let maxX = view.bounds.width - width - 16
            let x = min(max(16, frame.maxX - width), max(16, maxX))
            let below = frame.maxY + 8
            let y = below + height + insets.bottom + 16 <= view.bounds.height
                ? below
                : frame.minY - height - 8
            origin = CGPoint(x: x, y: max(insets.top + 16, y))
        }
        card.frame = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        card.layer.shadowPath = UIBezierPath(roundedRect: card.bounds,
                                             cornerRadius: SileoActionMenu.cornerRadius).cgPath
    }

    private func makeHeader(_ text: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        let container = UIView()
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])
        return container
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
        if let name = item.imageName {
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
            row.heightAnchor.constraint(equalToConstant: SileoActionMenu.rowHeight),
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
        row.addAction(UIAction { [weak row] _ in
            UIView.animate(withDuration: 0.12) { row?.backgroundColor = .clear }
        }, for: .touchUpOutside)
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

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }
}
