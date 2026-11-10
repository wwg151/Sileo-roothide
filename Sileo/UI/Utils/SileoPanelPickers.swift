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
                   subtitle: current.name,
                   icon: "arrow.triangle.branch")

        for section in sections {
            if sections.count > 1 {
                contentStack.addArrangedSubview(SileoPanelViewController.sectionLabel(section.title))
            }
            for package in section.packages {
                let selected = package.version == current.version
                    && (current.sourceRepo == nil || package.sourceRepo == current.sourceRepo)
                contentStack.addArrangedSubview(SileoPanelViewController.choiceRow(title: package.version,
                                                                                   detail: nil,
                                                                                   selected: selected) { [weak self] in
                    self?.close { onPick(package) }
                })
            }
        }
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

        let label = UILabel()
        label.text = text
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .label
        label.numberOfLines = 0
        contentStack.addArrangedSubview(label)

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
    private let rowsStack = UIStackView()
    private var confirmButton: UIButton?

    init(packages: [Package], onConfirm: @escaping ([Package]) -> Void) {
        self.packages = packages
        self.filtered = packages
        self.onConfirm = onConfirm
        super.init(title: String(localizationKey: "Backup_Select_Packages"),
                   subtitle: String(format: String(localizationKey: "Backup_Select_Count"), packages.count),
                   icon: "checklist")

        contentStack.addArrangedSubview(makeSearchBar())
        contentStack.addArrangedSubview(SileoPanelViewController.spacer(8))

        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.axis = .vertical
        rowsStack.spacing = 0
        contentStack.addArrangedSubview(rowsStack)

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
        container.translatesAutoresizingMaskIntoConstraints = false
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
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)

        container.addSubview(icon)
        container.addSubview(searchField)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 38),
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
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        checks.removeAll()

        for package in filtered {
            let row = SileoPanelRow()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.addAction(UIAction { [weak self] _ in self?.toggle(package) }, for: .touchUpInside)

            let label = UILabel()
            label.text = package.name
            label.font = .systemFont(ofSize: 17)
            label.textColor = .label
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
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
                row.heightAnchor.constraint(equalToConstant: 52),
                label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                version.trailingAnchor.constraint(equalTo: check.leadingAnchor, constant: -10),
                version.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: version.leadingAnchor, constant: -12),
                check.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                check.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                check.widthAnchor.constraint(equalToConstant: 22),
                check.heightAnchor.constraint(equalToConstant: 22)
            ])
            rowsStack.addArrangedSubview(row)
        }
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
        String(format: String(localizationKey: "Backup_Start_Count"), selected.count)
    }

    private func updateFooter() {
        confirmButton?.setTitle(footerTitle(), for: .normal)
        confirmButton?.isEnabled = !selected.isEmpty
    }
}

// MARK: - Removed sources

final class SileoRemovedSourcesPanel: SileoPanelViewController {

    init(items: [RemovedSource], onAdd: @escaping ([RemovedSource]) -> Void) {
        super.init(title: String(localizationKey: "Removed_Sources_Title"),
                   subtitle: String(format: String(localizationKey: "Removed_Sources_Header_Count"), items.count),
                   icon: "clock.arrow.circlepath")

        for item in items {
            contentStack.addArrangedSubview(SileoPanelViewController.choiceRow(title: item.name.isEmpty ? item.url : item.name,
                                                                               detail: item.url,
                                                                               selected: false) { [weak self] in
                self?.close { onAdd([item]) }
            })
        }

        if items.count > 1 {
            let button = SileoPanelViewController.capsuleButton(
                title: String(format: String(localizationKey: "Removed_Sources_Add_Count"), items.count)
            ) { [weak self] in
                self?.close { onAdd(items) }
            }
            setFooter(button)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
