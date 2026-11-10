//
//  SileoPanelPickers.swift
//  Sileo
//
//  The lists Sileo shows in its own panel: the versions of a package, a
//  package's control information, the packages a backup should hold, and the
//  sources that were removed.
//

import UIKit

// MARK: - Versions

final class SileoVersionPickerPanel: SileoPanelViewController {

    init(sections: [(title: String, packages: [Package])],
         current: Package,
         onPick: @escaping (Package) -> Void) {
        super.init(title: String(localizationKey: "Package_Select_Version"),
                   subtitle: current.name + " · " + current.version,
                   icon: "arrow.triangle.branch")

        // Exactly one row is the version shown now: the same version can sit in
        // several sources. A page from a source marks its own; an installed
        // package records no source, so the one Sileo would install from now
        // is marked instead — unless this very version is known to have come
        // from a local .deb, in which case nothing is marked.
        var winner: IndexPath?
        let isLocalInstall = PackageListManager.shared.localPackages[current.package]?.version == current.version
        if let currentRepo = current.sourceRepo {
            for (section, entry) in sections.enumerated() {
                for (row, package) in entry.packages.enumerated()
                    where package.version == current.version && package.sourceRepo?.url == currentRepo.url {
                    winner = IndexPath(row: row, section: section)
                    break
                }
                if winner != nil { break }
            }
        } else if !isLocalInstall {
            let canonicalSource = PackageListManager.shared.newestPackage(identifier: current.package)?.sourceRepo?.url
            var firstCandidate: IndexPath?
            for (section, entry) in sections.enumerated() {
                for (row, package) in entry.packages.enumerated() where package.version == current.version {
                    if firstCandidate == nil {
                        firstCandidate = IndexPath(row: row, section: section)
                    }
                    if package.sourceRepo?.url == canonicalSource {
                        winner = IndexPath(row: row, section: section)
                        break
                    }
                }
                if winner != nil { break }
            }
            if winner == nil {
                winner = firstCandidate
            }
        }

        var items: [SileoPanelTable.Item] = []
        // An installed package whose source cannot be told: say so, the way
        // the list opens even when no source offers the package at all.
        if current.sourceRepo == nil && winner == nil {
            items.append(SileoPanelTable.Item(
                SileoPanelViewController.sectionLabel(String(localizationKey: "Version_Current_Local")),
                height: 34
            ))
        }
        for (section, entry) in sections.enumerated() {
            if sections.count > 1 {
                items.append(SileoPanelTable.Item(SileoPanelViewController.sectionLabel(entry.title), height: 34))
            }
            for (row, package) in entry.packages.enumerated() {
                let selected = winner == IndexPath(row: row, section: section)
                let row = SileoPanelViewController.choiceRow(title: package.version,
                                                             detail: nil,
                                                             selected: selected) { [weak self] in
                    self?.close { onPick(package) }
                }
                items.append(SileoPanelTable.Item(row, height: 52))
            }
        }
        table.setItems(items)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Package information

final class SileoPackageInfoPanel: SileoPanelViewController {

    init(package: Package) {
        super.init(title: package.name,
                   subtitle: package.package,
                   icon: "shippingbox.fill")

        var text = ""
        if let data = package.rawData, let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
            text = raw
        } else {
            text = package.rawControl.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
        }
        if let repo = package.sourceRepo {
            text += "\n\nRepository: \(repo.displayName)"
        }
        if let local = package.local_deb {
            text += "\n\nFile: \(local)"
        }

        // A text view of its own: the control file scrolls inside the card
        // instead of being squeezed into rows.
        let textView = UITextView()
        textView.text = text
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 16, right: 12)
        setBody(textView)

        let copy = SileoPanelViewController.capsuleButton(title: String(localizationKey: "Copy_All"),
                                                          filled: false) {}
        copy.addAction(UIAction { [weak copy] _ in
            UIPasteboard.general.string = text
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            copy?.setTitle(String(localizationKey: "Copied"), for: .normal)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                copy?.setTitle(String(localizationKey: "Copy_All"), for: .normal)
            }
        }, for: .touchUpInside)

        let done = SileoPanelViewController.capsuleButton(title: String(localizationKey: "Done")) { [weak self] in
            self?.close()
        }

        let footer = UIStackView(arrangedSubviews: [copy, done])
        footer.axis = .horizontal
        footer.spacing = 10
        footer.distribution = .fillEqually
        setFooter(footer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Packages to back up

final class SileoBackupPickerPanel: SileoPanelViewController {

    private let packages: [Package]
    private let onConfirm: ([Package]) -> Void
    private var selected: Set<String> = []
    private var filtered: [Package] = []
    private var checks: [String: UIImageView] = [:]

    private let searchField = UITextField()
    private let listTable = SileoPanelTable()
    private var confirmButton: UIButton?
    private var selectAllButton: UIButton?

    init(packages: [Package], onConfirm: @escaping ([Package]) -> Void) {
        self.packages = packages
        self.filtered = packages
        self.onConfirm = onConfirm
        super.init(title: String(localizationKey: "Backup_Select_Packages"),
                   subtitle: String(format: String(localizationKey: "Backup_Select_Count"), packages.count),
                   icon: "checklist")

        // the search field stays put while the list under it scrolls
        let body = UIView()
        body.translatesAutoresizingMaskIntoConstraints = false

        let searchBar = makeSearchBar()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        listTable.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(searchBar)
        body.addSubview(listTable)
        NSLayoutConstraint.activate([
            searchBar.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            searchBar.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            searchBar.topAnchor.constraint(equalTo: body.topAnchor, constant: 4),
            searchBar.heightAnchor.constraint(equalToConstant: 38),

            listTable.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            listTable.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            listTable.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 8),
            listTable.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
        setBody(body)

        let selectAll = SileoPanelViewController.headerButton(title: String(localizationKey: "Backup_Select_All")) { [weak self] in
            self?.toggleSelectAll()
        }
        selectAllButton = selectAll
        headerAccessory = selectAll

        let button = SileoPanelViewController.capsuleButton(title: footerTitle()) { [weak self] in
            guard let self = self, !self.selected.isEmpty else { return }
            let chosen = self.packages.filter { self.selected.contains($0.package) }
            self.close { self.onConfirm(chosen) }
        }
        confirmButton = button
        setFooter(button)

        rebuildRows()
        updateFooter()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeSearchBar() -> UIView {
        let container = UIView()
        container.backgroundColor = .tertiarySystemFill
        container.layer.cornerRadius = 12
        container.layer.cornerCurve = .continuous

        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = .systemFont(ofSize: 15)
        searchField.textColor = .label
        searchField.attributedPlaceholder = NSAttributedString(
            string: String(localizationKey: "Search_Page"),
            attributes: [.foregroundColor: UIColor.secondaryLabel]
        )
        searchField.clearButtonMode = .whileEditing
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.returnKeyType = .done
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)

        container.addSubview(icon)
        container.addSubview(searchField)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            searchField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: container.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    @objc private func searchChanged() {
        let text = (searchField.text ?? "").lowercased()
        filtered = text.isEmpty
            ? packages
            : packages.filter {
                $0.name.lowercased().contains(text) || $0.package.lowercased().contains(text)
            }
        rebuildRows()
    }

    private func rebuildRows() {
        checks.removeAll()
        let items = filtered.map { package -> SileoPanelTable.Item in
            SileoPanelTable.Item(makeRow(for: package))
        }
        listTable.setItems(items)
    }

    private func makeRow(for package: Package) -> UIView {
        let row = SileoPanelRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addAction(UIAction { [weak self] _ in self?.toggle(package) }, for: .touchUpInside)

        let label = UILabel()
        label.text = package.name
        label.font = .systemFont(ofSize: 17)
        label.textColor = .label
        label.numberOfLines = 0
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let version = UILabel()
        version.text = package.version
        version.font = .systemFont(ofSize: 13)
        version.textColor = .secondaryLabel
        version.translatesAutoresizingMaskIntoConstraints = false

        let check = UIImageView()
        check.translatesAutoresizingMaskIntoConstraints = false
        check.contentMode = .scaleAspectFit
        checks[package.package] = check
        update(check: check, selected: selected.contains(package.package))

        row.addSubview(label)
        row.addSubview(version)
        row.addSubview(check)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -12),
            version.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            version.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            version.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -12),
            version.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
            check.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            check.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 22),
            check.heightAnchor.constraint(equalToConstant: 22)
        ])
        return row
    }

    private func update(check: UIImageView, selected: Bool) {
        check.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
        check.tintColor = selected ? .tintColor : .tertiaryLabel
    }

    private func toggle(_ package: Package) {
        if selected.contains(package.package) {
            selected.remove(package.package)
        } else {
            selected.insert(package.package)
        }
        if let check = checks[package.package] {
            update(check: check, selected: selected.contains(package.package))
        }
        UISelectionFeedbackGenerator().selectionChanged()
        updateFooter()
    }

    private func footerTitle() -> String {
        String(localizationKey: "Backup_Start") + " (\(selected.count))"
    }

    private func updateFooter() {
        confirmButton?.setTitle(footerTitle(), for: .normal)
        confirmButton?.isEnabled = !selected.isEmpty

        let allSelected = !filtered.isEmpty && filtered.allSatisfy { selected.contains($0.package) }
        selectAllButton?.setTitle(String(localizationKey: allSelected ? "Backup_Deselect_All" : "Backup_Select_All"),
                                  for: .normal)
    }

    private func toggleSelectAll() {
        let allSelected = !filtered.isEmpty && filtered.allSatisfy { selected.contains($0.package) }
        for package in filtered {
            if allSelected {
                selected.remove(package.package)
            } else {
                selected.insert(package.package)
            }
        }
        for (identifier, check) in checks {
            update(check: check, selected: selected.contains(identifier))
        }
        UISelectionFeedbackGenerator().selectionChanged()
        updateFooter()
    }
}

// MARK: - Removed sources

final class SileoRemovedSourcesPanel: SileoPanelViewController {

    private let items: [RemovedSource]
    private let onAdd: ([RemovedSource]) -> Void
    private var selected: Set<String> = []
    private var checks: [String: UIImageView] = [:]
    private var confirmButton: UIButton?
    private var selectAllButton: UIButton?

    init(items: [RemovedSource], onAdd: @escaping ([RemovedSource]) -> Void) {
        self.items = items
        self.onAdd = onAdd
        super.init(title: String(localizationKey: "Removed_Sources_Title"),
                   subtitle: String(format: String(localizationKey: "Removed_Sources_Header_Count"), items.count),
                   icon: "clock.arrow.circlepath")

        table.setItems(items.map { item in
            SileoPanelTable.Item(makeRow(for: item))
        })

        let selectAll = SileoPanelViewController.headerButton(title: String(localizationKey: "Backup_Select_All")) { [weak self] in
            self?.toggleSelectAll()
        }
        selectAllButton = selectAll
        headerAccessory = selectAll

        let button = SileoPanelViewController.capsuleButton(title: footerTitle()) { [weak self] in
            guard let self = self, !self.selected.isEmpty else { return }
            let chosen = self.items.filter { self.selected.contains($0.url) }
            self.close { self.onAdd(chosen) }
        }
        confirmButton = button
        setFooter(button)
        updateFooter()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeRow(for item: RemovedSource) -> UIView {
        let row = SileoPanelRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addAction(UIAction { [weak self] _ in self?.toggle(item) }, for: .touchUpInside)

        let label = UILabel()
        label.text = item.name.isEmpty ? item.url : item.name
        label.font = .systemFont(ofSize: 17)
        label.textColor = .label
        label.numberOfLines = 0
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let url = UILabel()
        url.text = item.url
        url.font = .systemFont(ofSize: 13)
        url.textColor = .secondaryLabel
        url.numberOfLines = 1
        url.lineBreakMode = .byTruncatingMiddle
        url.translatesAutoresizingMaskIntoConstraints = false

        let check = UIImageView()
        check.translatesAutoresizingMaskIntoConstraints = false
        check.contentMode = .scaleAspectFit
        checks[item.url] = check
        update(check: check, selected: selected.contains(item.url))

        row.addSubview(label)
        row.addSubview(url)
        row.addSubview(check)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -12),
            url.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            url.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            url.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -12),
            url.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
            check.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            check.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 22),
            check.heightAnchor.constraint(equalToConstant: 22)
        ])
        return row
    }

    private func update(check: UIImageView, selected: Bool) {
        check.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
        check.tintColor = selected ? .tintColor : .tertiaryLabel
    }

    private func toggle(_ item: RemovedSource) {
        if selected.contains(item.url) {
            selected.remove(item.url)
        } else {
            selected.insert(item.url)
        }
        if let check = checks[item.url] {
            update(check: check, selected: selected.contains(item.url))
        }
        UISelectionFeedbackGenerator().selectionChanged()
        updateFooter()
    }

    private func footerTitle() -> String {
        String(format: String(localizationKey: "Removed_Sources_Add_Count"), selected.count)
    }

    private func updateFooter() {
        confirmButton?.setTitle(footerTitle(), for: .normal)
        confirmButton?.isEnabled = !selected.isEmpty

        let allSelected = !items.isEmpty && items.allSatisfy { selected.contains($0.url) }
        selectAllButton?.setTitle(String(localizationKey: allSelected ? "Backup_Deselect_All" : "Backup_Select_All"),
                                  for: .normal)
    }

    private func toggleSelectAll() {
        let allSelected = !items.isEmpty && items.allSatisfy { selected.contains($0.url) }
        for item in items {
            if allSelected {
                selected.remove(item.url)
            } else {
                selected.insert(item.url)
            }
        }
        for (identifier, check) in checks {
            update(check: check, selected: selected.contains(identifier))
        }
        UISelectionFeedbackGenerator().selectionChanged()
        updateFooter()
    }
}
