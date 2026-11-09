//
//  RemovedSourcesViewController.swift
//  Sileo
//
//  The list of sources that were taken off with a swipe, shown as a sheet so
//  one or several of them can be picked and put back on the list.
//

import UIKit

final class RemovedSourcesViewController: UIViewController {

    /// Called with the records to add back, in the order they are shown.
    var onAdd: (([RemovedSource]) -> Void)?

    private var items: [RemovedSource] = []
    private var selected = Set<Int>()

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let headerView = UIView()
    private let headerTitle = UILabel()
    private let headerDetail = UILabel()
    private let emptyView = UIView()
    private let emptyIcon = UIImageView()
    private let emptyLabel = UILabel()
    private let addButton = UIButton(type: .system)
    private let bottomBar = UIView()

    // MARK: - Life

    init() {
        super.init(nibName: nil, bundle: nil)
        title = String(localizationKey: "Removed_Sources_Title")
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        items = RemovedSourcesStore.shared.items
        view.backgroundColor = .systemGroupedBackground
        build()
        updateSelectionUI()
        updateEmptyState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.navigationBar.prefersLargeTitles = false
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel,
                                                           target: self,
                                                           action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: String(localizationKey: "Select_All"),
                                                            style: .plain,
                                                            target: self,
                                                            action: #selector(toggleSelectAll))
    }

    // MARK: - Layout

    private func build() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.register(RemovedSourceCell.self, forCellReuseIdentifier: "Sileo.RemovedSourceCell")
        tableView.allowsMultipleSelectionDuringEditing = false
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.tableFooterView = UIView()
        view.addSubview(tableView)

        headerTitle.font = .preferredFont(forTextStyle: .footnote)
        headerTitle.textColor = .secondaryLabel
        headerTitle.numberOfLines = 0
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(headerTitle)

        emptyIcon.image = UIImage(systemName: "clock.arrow.circlepath")
        emptyIcon.tintColor = .tertiaryLabel
        emptyIcon.contentMode = .scaleAspectFit
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.text = String(localizationKey: "Removed_Sources_Empty")
        emptyLabel.font = .preferredFont(forTextStyle: .subheadline)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        emptyView.addSubview(emptyIcon)
        emptyView.addSubview(emptyLabel)
        view.addSubview(emptyView)

        bottomBar.backgroundColor = .systemGroupedBackground
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        addButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        addButton.backgroundColor = view.tintColor
        addButton.setTitleColor(.white, for: .normal)
        addButton.layer.cornerRadius = 14
        addButton.layer.cornerCurve = .continuous
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        bottomBar.addSubview(addButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 72),

            addButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 20),
            addButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -20),
            addButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 8),
            addButton.heightAnchor.constraint(equalToConstant: 50),

            emptyView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            emptyView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),

            emptyIcon.topAnchor.constraint(equalTo: emptyView.topAnchor),
            emptyIcon.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            emptyIcon.widthAnchor.constraint(equalToConstant: 44),
            emptyIcon.heightAnchor.constraint(equalToConstant: 44),

            emptyLabel.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 14),
            emptyLabel.leadingAnchor.constraint(equalTo: emptyView.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: emptyView.trailingAnchor),
            emptyLabel.bottomAnchor.constraint(equalTo: emptyView.bottomAnchor)
        ])

        headerDetail.font = .preferredFont(forTextStyle: .caption1)
        headerDetail.textColor = .tertiaryLabel
        headerDetail.numberOfLines = 0
    }

    /// The line above the list, sized to the text it carries.
    private func makeHeader() -> UIView {
        headerView.subviews.forEach { $0.removeFromSuperview() }
        headerTitle.text = String(format: String(localizationKey: "Removed_Sources_Header_Count"), items.count)
        headerView.addSubview(headerTitle)
        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            headerTitle.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
            headerTitle.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 6),
            headerTitle.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -10)
        ])
        let size = headerView.systemLayoutSizeFitting(CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
                                                      withHorizontalFittingPriority: .required,
                                                      verticalFittingPriority: .fittingSizeLevel)
        headerView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: size.height)
        return headerView
    }

    private func updateEmptyState() {
        emptyView.isHidden = !items.isEmpty
        tableView.isHidden = items.isEmpty
        tableView.tableHeaderView = items.isEmpty ? nil : makeHeader()
        bottomBar.isHidden = items.isEmpty
        navigationItem.rightBarButtonItem?.isEnabled = !items.isEmpty
    }

    private func updateSelectionUI() {
        let count = selected.count
        let title = count == 0
            ? String(localizationKey: "Removed_Sources_Add")
            : String(format: String(localizationKey: "Removed_Sources_Add_Count"), count)
        addButton.setTitle(title, for: .normal)
        addButton.isEnabled = count > 0
        addButton.alpha = count > 0 ? 1 : 0.4
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func toggleSelectAll() {
        if selected.count == items.count {
            selected.removeAll()
        } else {
            selected = Set(items.indices)
        }
        tableView.reloadData()
        updateSelectionUI()
    }

    @objc private func addTapped() {
        let picked = selected.sorted().compactMap { items.indices.contains($0) ? items[$0] : nil }
        guard !picked.isEmpty else { return }
        RemovedSourcesStore.shared.forget(picked)
        dismiss(animated: true) { [onAdd] in
            onAdd?(picked)
        }
    }
}

// MARK: - Table

extension RemovedSourcesViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Sileo.RemovedSourceCell", for: indexPath) as? RemovedSourceCell
            ?? RemovedSourceCell(style: .subtitle, reuseIdentifier: "Sileo.RemovedSourceCell")
        let item = items[indexPath.row]
        cell.configure(with: item, selected: selected.contains(indexPath.row))
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if selected.contains(indexPath.row) {
            selected.remove(indexPath.row)
        } else {
            selected.insert(indexPath.row)
        }
        tableView.reloadRows(at: [indexPath], with: .none)
        updateSelectionUI()
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let forget = UIContextualAction(style: .destructive,
                                        title: String(localizationKey: "Removed_Sources_Forget")) { [weak self] _, _, completion in
            guard let self = self else { return }
            RemovedSourcesStore.shared.remove(at: indexPath.row)
            self.items.remove(at: indexPath.row)
            self.selected = Set(self.selected.compactMap { $0 == indexPath.row ? nil : ($0 > indexPath.row ? $0 - 1 : $0) })
            tableView.deleteRows(at: [indexPath], with: .fade)
            self.updateSelectionUI()
            self.updateEmptyState()
            completion(true)
        }
        forget.backgroundColor = .systemRed
        return UISwipeActionsConfiguration(actions: [forget])
    }
}

// MARK: - Cell

final class RemovedSourceCell: UITableViewCell {

    private let checkView = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .secondarySystemGroupedBackground
        accessoryType = .none
        checkView.contentMode = .scaleAspectFit
        checkView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(checkView)
        NSLayoutConstraint.activate([
            checkView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            checkView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 24),
            checkView.heightAnchor.constraint(equalToConstant: 24)
        ])
        textLabel?.numberOfLines = 1
        detailTextLabel?.numberOfLines = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with item: RemovedSource, selected: Bool) {
        textLabel?.text = item.name
        textLabel?.textColor = .label
        detailTextLabel?.text = item.url
        detailTextLabel?.textColor = .secondaryLabel
        checkView.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
        checkView.tintColor = selected ? tintColor : .tertiaryLabel
    }
}
