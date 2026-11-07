//
//  BackupPackagesViewController.swift
//  Sileo
//
//  Picks which installed third-party packages a backup should contain.
//

import Foundation
import UIKit

final class BackupPackagesViewController: UITableViewController {

    private let packages: [Package]
    private var selectedPackages: Set<String> = []
    var onConfirm: (([Package]) -> Void)?

    init(packages: [Package]) {
        self.packages = packages
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localizationKey: "Backup_Select_Packages")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.allowsMultipleSelection = true

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localizationKey: "Backup_Select_All"),
            style: .plain,
            target: self,
            action: #selector(toggleSelectAll)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localizationKey: "Backup_Start"),
            style: .done,
            target: self,
            action: #selector(confirmSelection)
        )
        updateConfirmButton()
    }

    private func updateConfirmButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !selectedPackages.isEmpty
    }

    @objc private func toggleSelectAll() {
        if selectedPackages.count == packages.count {
            selectedPackages.removeAll()
            for indexPath in tableView.indexPathsForSelectedRows ?? [] {
                tableView.deselectRow(at: indexPath, animated: true)
            }
        } else {
            selectedPackages = Set(packages.map { $0.package })
            for row in 0..<packages.count {
                tableView.selectRow(at: IndexPath(row: row, section: 0), animated: true, scrollPosition: .none)
            }
        }
        updateConfirmButton()
    }

    @objc private func confirmSelection() {
        let chosen = packages.filter { selectedPackages.contains($0.package) }
        dismiss(animated: true) {
            self.onConfirm?(chosen)
        }
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        packages.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let package = packages[indexPath.row]
        cell.textLabel?.text = package.name
        cell.detailTextLabel?.text = package.package
        cell.accessoryType = selectedPackages.contains(package.package) ? .checkmark : .none
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let package = packages[indexPath.row]
        selectedPackages.insert(package.package)
        tableView.cellForRow(at: indexPath)?.accessoryType = .checkmark
        updateConfirmButton()
    }

    override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        let package = packages[indexPath.row]
        selectedPackages.remove(package.package)
        tableView.cellForRow(at: indexPath)?.accessoryType = .none
        updateConfirmButton()
    }
}
