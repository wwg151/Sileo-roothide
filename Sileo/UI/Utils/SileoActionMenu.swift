//
//  SileoActionMenu.swift
//  Sileo
//
//  A menu of our own, for the two places a system UIMenu is not enough: no
//  separators between the rows, and a highlight pill that slides from one row
//  to the next instead of jumping.
//

import UIKit

struct SileoActionMenuItem {
    let title: String
    let image: UIImage?
    let destructive: Bool
    let handler: () -> Void

    init(title: String, image: UIImage?, destructive: Bool, handler: @escaping () -> Void) {
        self.title = title
        self.image = image
        self.destructive = destructive
        self.handler = handler
    }

    init(title: String, imageName: String?, destructive: Bool, handler: @escaping () -> Void) {
        self.init(title: title,
                  image: imageName.flatMap { UIImage(systemName: $0) },
                  destructive: destructive,
                  handler: handler)
    }
}

final class SileoActionMenu: UIViewController {

    private let header: String?
    private let items: [SileoActionMenuItem]
    /// The bar button the menu drops from, in window coordinates.
    private let sourceFrame: CGRect?

    private let card = UIView()
    private let rowsStack = UIStackView()
    private var rowViews: [SileoActionMenuRow] = []
    private let pill = UIView()
    private var highlighted: Int?
    private var cardTop: NSLayoutConstraint?
    private var cardLeading: NSLayoutConstraint?

    init(header: String?, items: [SileoActionMenuItem], sourceFrame: CGRect?) {
        self.header = header
        self.items = items
        self.sourceFrame = sourceFrame
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        build()
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        positionCard()
        if highlighted == nil, let first = rowViews.indices.first {
            pill.frame = rowViews[first].frame.insetBy(dx: 4, dy: 3)
            pill.layer.cornerRadius = 12
            pill.isHidden = true
        }
    }

    // MARK: - Build

    private func build() {
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.18
        card.layer.shadowRadius = 22
        card.layer.shadowOffset = CGSize(width: 0, height: 10)
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        rowsStack.axis = .vertical
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rowsStack)

        pill.backgroundColor = selectionColor()
        pill.isUserInteractionEnabled = false
        pill.isHidden = true
        rowsStack.insertSubview(pill, at: 0)

        var arranged: [UIView] = []
        if let header = header, !header.isEmpty {
            let label = UILabel()
            label.text = header
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabel
            let wrapper = UIView()
            label.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 20),
                label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -20),
                label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 14),
                label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -6)
            ])
            arranged.append(wrapper)
        }

        for (index, item) in items.enumerated() {
            let row = SileoActionMenuRow(item: item)
            row.onHighlight = { [weak self] inside in
                self?.highlight(index, active: inside)
            }
            row.onTap = { [weak self] in
                self?.perform(index)
            }
            rowViews.append(row)
            arranged.append(row)
        }

        for row in arranged {
            rowsStack.addArrangedSubview(row)
        }

        let top = card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60)
        let leading = card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16)
        cardTop = top
        cardLeading = leading
        NSLayoutConstraint.activate([
            leading,
            top,
            card.widthAnchor.constraint(equalToConstant: 300),
            rowsStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6)
        ])
    }

    private func positionCard() {
        guard let source = sourceFrame else { return }
        view.layoutIfNeeded()
        let size = card.systemLayoutSizeFitting(CGSize(width: 300, height: UIView.layoutFittingCompressedSize.height))
        var originY = source.maxY + 8
        let maxY = view.bounds.height - view.safeAreaInsets.bottom - size.height - 12
        originY = min(originY, max(maxY, 60))
        let originX = min(max(16, source.midX - 150), view.bounds.width - 16 - 300)
        cardTop?.constant = originY - view.safeAreaInsets.top
        cardLeading?.constant = originX
    }

    private func selectionColor() -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor.white.withAlphaComponent(0.12)
        }
        return UIColor.secondarySystemFill
    }

    // MARK: - Highlight

    private func highlight(_ index: Int, active: Bool) {
        guard rowViews.indices.contains(index) else { return }
        if !active {
            if highlighted == index {
                highlighted = nil
            }
            return
        }
        guard highlighted != index else { return }
        highlighted = index
        pill.isHidden = false
        pill.backgroundColor = selectionColor()
        let target = rowViews[index].frame.insetBy(dx: 4, dy: 3)
        UIView.animate(withDuration: 0.22,
                       delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState]) {
            self.pill.frame = target
            self.pill.layer.cornerRadius = 12
        }
    }

    // MARK: - Actions

    @objc private func backgroundTapped(_ recognizer: UITapGestureRecognizer) {
        // A tap on a row is the row's business, not a dismissal.
        if card.frame.contains(recognizer.location(in: view)) { return }
        dismiss(animated: true)
    }

    private func perform(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let handler = items[index].handler
        dismiss(animated: true) {
            handler()
        }
    }
}

// MARK: - Row

final class SileoActionMenuRow: UIControl {

    var onHighlight: ((Bool) -> Void)?
    var onTap: (() -> Void)?

    init(item: SileoActionMenuItem) {
        super.init(frame: .zero)
        let title = UILabel()
        title.text = item.title
        title.font = .preferredFont(forTextStyle: .body)
        title.textColor = item.destructive ? .systemRed : .label
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        let icon = UIImageView()
        icon.image = item.image
        icon.tintColor = item.destructive ? .systemRed : .label
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 54),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            title.trailingAnchor.constraint(lessThanOrEqualTo: icon.leadingAnchor, constant: -12)
        ])

        addTarget(self, action: #selector(touchDown), for: [.touchDown, .touchDragEnter])
        addTarget(self, action: #selector(touchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func touchDown() {
        onHighlight?(true)
    }

    @objc private func touchUp() {
        onHighlight?(false)
    }

    @objc private func tapped() {
        onTap?()
    }
}
