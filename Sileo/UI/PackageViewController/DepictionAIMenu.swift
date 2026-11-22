import UIKit

private func aiText(_ key: String) -> String {
    NSLocalizedString("Depiction_AI_" + key, comment: "AI translation menu")
}

@available(iOS 14.0, *)
@MainActor
final class DepictionAIMenu {
    private typealias Provider = DepictionAIProvider.Provider
    private weak var presenter: UIViewController?
    private weak var button: UIBarButtonItem?
    private let onSelectionChanged: () -> Void
    private static let legacyMenus = NSHashTable<DepictionAIMenu>.weakObjects()

    init(presenter: UIViewController, onSelectionChanged: @escaping () -> Void) {
        self.presenter = presenter
        self.onSelectionChanged = onSelectionChanged
    }

    func makeButton() -> UIBarButtonItem {
        if let button = button { return button }
        let item = UIBarButtonItem(image: UIImage(systemName: "sparkles"), menu: makeMenu())
        item.accessibilityLabel = aiText("Title")
        button = item
        if #available(iOS 15.0, *) {} else { Self.legacyMenus.add(self) }
        return item
    }

    private func makeMenu() -> UIMenu {
        let children: UIDeferredMenuElement
        if #available(iOS 15.0, *) {
            children = UIDeferredMenuElement.uncached { [weak self] finish in
                finish(self?.menuEntries() ?? [])
            }
        } else {
            children = UIDeferredMenuElement { [weak self] finish in
                finish(self?.menuEntries() ?? [])
            }
        }
        return UIMenu(title: aiText("Title"), children: [children])
    }

    private func refreshMenus() {
        // Before iOS 15 UIKit caches deferred items, so replace their roots after a write.
        for menu in Self.legacyMenus.allObjects {
            menu.button?.menu = menu.makeMenu()
        }
    }

    private func changed() {
        refreshMenus()
        onSelectionChanged()
    }

    private func menuEntries() -> [UIMenuElement] {
        let selection = DepictionAIProvider.selection
        let current = selection.map {
            String(format: aiText("Current_Model"), $0.provider.name, $0.model)
        } ?? aiText("Current_System")
        let status = UIAction(title: current, attributes: .disabled) { _ in }
        var actions: [UIMenuElement] = [action("Add", icon: "plus") { $0.edit(nil) }]
        if selection != nil {
            actions.append(action("Use_System", icon: "globe") { menu in
                DepictionAIProvider.deactivate()
                menu.changed()
            })
        }
        actions += DepictionAIProvider.providers.map { provider in
            let id = provider.id
            return UIMenu(title: provider.name, children: [
                action("Fetch", icon: "arrow.down.circle") { $0.pick(id, fetch: true) },
                action("Cached", icon: "list.bullet", attributes: provider.models.isEmpty ? .disabled : []) { $0.pick(id, fetch: false) },
                action("Manual", icon: "keyboard") { $0.manual(id) },
                action("Edit", icon: "pencil") { $0.edit(id) },
                action("Remove", icon: "trash", attributes: .destructive) { $0.confirmRemoval(id) }
            ])
        }
        var modelSettings: [UIMenuElement] = [status]
        if let selection = selection { modelSettings.append(thinkingMenu(for: selection)) }
        return [UIMenu(title: "", options: .displayInline, children: modelSettings)] + actions
    }

    private func thinkingMenu(for selection: DepictionAIProvider.Selection) -> UIMenuElement {
        let supported = selection.supportedThinkingEfforts
        guard !supported.isEmpty else {
            return UIAction(title: aiText("Thinking_Unsupported"), attributes: .disabled) { _ in }
        }
        let current = aiText("Thinking_" + selection.thinkingEffort.rawValue)
        let levels = DepictionAIProvider.ThinkingEffort.allCases.map { effort in
            UIAction(title: aiText("Thinking_" + effort.rawValue),
                     attributes: effort == .modelDefault || supported.contains(effort) ? [] : .disabled,
                     state: effort == selection.thinkingEffort ? .on : .off) { [weak self] _ in
                guard effort != selection.thinkingEffort, let self = self else { return }
                if DepictionAIProvider.setThinkingEffort(effort, using: selection) {
                    // This is a preference, not a new model activation or a request to translate.
                    self.refreshMenus()
                } else if let presenter = self.presenter {
                    Self.showError("Thinking_Save_Failed", from: presenter)
                }
            }
        }
        return UIMenu(title: String(format: aiText("Thinking_Current"), current), children: levels)
    }

    private func action(_ key: String, icon: String, attributes: UIMenuElement.Attributes = [],
                        perform: @escaping (DepictionAIMenu) -> Void) -> UIAction {
        UIAction(title: aiText(key), image: UIImage(systemName: icon), attributes: attributes) { [weak self] _ in
            if let self = self { perform(self) }
        }
    }

    private func provider(_ id: UUID) -> Provider? {
        DepictionAIProvider.providers.first { $0.id == id }
    }

    private func showSheet(_ controller: UIViewController) {
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        presenter?.present(navigation, animated: true)
    }

    private func edit(_ id: UUID?) {
        let existing = id.flatMap { provider($0) }
        if id != nil && existing == nil { return }
        let form = DepictionAIProviderForm(provider: existing)
        form.onSave = { [weak self, weak form] name, url, kind, key in
            guard let self = self, let form = form else { return }
            guard let baseURL = DepictionAIProvider.validBaseURL(url),
                  let host = URLComponents(string: baseURL)?.host, !host.isEmpty else {
                Self.showError("Invalid_URL", from: form)
                return
            }
            var updated = Provider(id: UUID(), name: name, baseURL: baseURL, kind: kind, models: [])
            if let id = id {
                guard let latest = self.provider(id) else {
                    Self.showError("Provider_Changed", from: form)
                    return
                }
                // The backend invalidates cached models and consent when the configuration changes.
                updated = latest
            }
            updated.name = name.isEmpty ? host : name
            updated.baseURL = baseURL
            updated.kind = kind
            guard DepictionAIProvider.save(updated, apiKey: key) else {
                Self.showError("Save_Failed", from: form)
                return
            }
            form.dismiss(animated: true) { self.changed() }
        }
        showSheet(form)
    }

    private func pick(_ id: UUID, fetch: Bool) {
        guard let current = provider(id) else { return }
        let picker = DepictionAIModelPicker(style: .insetGrouped)
        picker.title = current.name
        picker.models = current.models
        if let selection = DepictionAIProvider.selection, selection.provider.id == id {
            picker.selectedModel = selection.model
        }
        picker.onPick = { [weak self, weak picker] model in
            guard let picker = picker else { return }
            self?.confirmActivation(id, model: model, from: picker) {
                picker.dismiss(animated: true)
            }
        }
        if fetch {
            picker.onAppear = { [weak self, weak picker] in
                DepictionAIProvider.models(for: current) { result in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.refreshMenus()
                        guard let picker = picker else { return }
                        picker.loading = false
                        switch result {
                        case .success:
                            // The service owns the cache. Do not write back a request-time snapshot.
                            picker.models = self.provider(id)?.models ?? []
                        case .failure(let error):
                            picker.models = self.provider(id)?.models ?? []
                            Self.showError(Self.fetchErrorKey(error), from: picker)
                        }
                    }
                }
            }
            picker.loading = true
        }
        showSheet(picker)
    }

    private static func fetchErrorKey(_ error: Error) -> String {
        guard let failure = error as? DepictionAIProvider.Failure else { return "Fetch_Failed" }
        switch failure {
        case .missingKey: return "Fetch_Missing_Key"
        case .authentication: return "Fetch_Authentication"
        case .rateLimited: return "Fetch_Rate_Limited"
        case .timeout: return "Fetch_Timeout"
        default: return "Fetch_Failed"
        }
    }

    private func manual(_ id: UUID) {
        guard let presenter = presenter, provider(id) != nil else { return }
        let alert = UIAlertController(title: aiText("Model_ID"), message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = aiText("Model_ID")
            configureLiteralField(field)
        }
        alert.addAction(UIAlertAction(title: aiText("Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: aiText("Continue"), style: .default) { [weak self, weak presenter, weak alert] _ in
            guard let presenter = presenter else { return }
            let model = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let next: () -> Void = {
                if model.isEmpty { Self.showError("Empty_Model", from: presenter) }
                else { self?.confirmActivation(id, model: model, from: presenter) }
            }
            Self.afterAlert(alert, perform: next)
        })
        presenter.present(alert, animated: true)
    }

    private func confirmActivation(_ id: UUID, model: String, from source: UIViewController,
                                   didSelect: @escaping () -> Void = {}) {
        guard let current = provider(id), let host = URLComponents(string: current.baseURL)?.host else {
            Self.showError("Provider_Changed", from: source)
            return
        }
        if let selection = DepictionAIProvider.selection, selection.provider.id == id, selection.model == model {
            // Re-selecting the active model repeats the test and reports the answer;
            // the picker stays open behind the progress alert.
            Self.verify(current, model: model, from: source) { [weak source] reply in
                guard let source = source else { return }
                Self.showSuccess(model: model, reply: reply, from: source)
            }
            return
        }
        // Ask the provider first: a model that cannot answer is never offered for consent.
        Self.verify(current, model: model, from: source) { [weak self, weak source] _ in
            guard let self = self, let source = source else { return }
            self.requestConsent(current, host: host, model: model, from: source, didSelect: didSelect)
        }
    }

    private func requestConsent(_ current: Provider, host: String, model: String, from source: UIViewController,
                                didSelect: @escaping () -> Void) {
        let message = String(format: aiText("Consent_Body"), current.name, host, model)
        let alert = UIAlertController(title: aiText("Consent_Title"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: aiText("Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: aiText("Enable"), style: .default) { [weak self, weak source, weak alert] _ in
            Self.afterAlert(alert) {
                guard let self = self, let source = source else { return }
                guard let latest = self.provider(current.id), latest.baseURL == current.baseURL, latest.kind == current.kind else {
                    Self.showError("Provider_Changed", from: source)
                    return
                }
                guard DepictionAIProvider.activate(latest, model: model) else {
                    Self.showError("Activate_Failed", from: source)
                    return
                }
                didSelect()
                self.changed()
            }
        })
        source.present(alert, animated: true)
    }

    private static func verify(_ provider: Provider, model: String, from source: UIViewController,
                               proceed: @escaping (String) -> Void) {
        let progress = UIAlertController(title: aiText("Test_Title"), message: aiText("Test_Body"), preferredStyle: .alert)
        var cancelled = false
        progress.addAction(UIAlertAction(title: aiText("Cancel"), style: .cancel) { _ in cancelled = true })
        source.present(progress, animated: true)
        DepictionAIProvider.test(provider, model: model) { result in
            DispatchQueue.main.async {
                let finish: () -> Void = { [weak source] in
                    guard !cancelled else { return }
                    switch result {
                    case .success(let reply):
                        proceed(reply)
                    case .failure(let error):
                        guard let source = source else { return }
                        showError(error.key, detail: error.detail, from: source)
                    }
                }
                if progress.presentingViewController != nil {
                    progress.dismiss(animated: true, completion: finish)
                } else {
                    finish()
                }
            }
        }
    }

    private func confirmRemoval(_ id: UUID) {
        guard let presenter = presenter, let current = provider(id) else { return }
        let alert = UIAlertController(title: aiText("Remove"),
                                      message: String(format: aiText("Remove_Body"), current.name), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: aiText("Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: aiText("Remove_Confirm"), style: .destructive) { [weak self, weak presenter] _ in
            guard let self = self, let presenter = presenter else { return }
            if DepictionAIProvider.remove(id) { self.changed() }
            else { Self.showError("Remove_Failed", from: presenter) }
        })
        presenter.present(alert, animated: true)
    }

    private static func afterAlert(_ alert: UIAlertController?, perform: @escaping () -> Void) {
        DispatchQueue.main.async { [weak alert] in
            guard let alert = alert, alert.presentingViewController != nil else {
                perform()
                return
            }
            if let coordinator = alert.transitionCoordinator,
               coordinator.animate(alongsideTransition: nil, completion: { _ in perform() }) {
                return
            }
            alert.dismiss(animated: true, completion: perform)
        }
    }

    private static func showError(_ key: String, detail: String? = nil, from source: UIViewController) {
        let text = detail.flatMap { $0.isEmpty ? nil : aiText(key) + "\n\n" + $0 } ?? aiText(key)
        presentAlert(title: aiText("Error_Title"), message: text, from: source)
    }

    private static func showSuccess(model: String, reply: String, from source: UIViewController) {
        let brief = reply.count > 60 ? String(reply.prefix(60)) + "…" : reply
        presentAlert(title: aiText("Test_OK_Title"),
                     message: String(format: aiText("Test_OK_Body"), model, brief), from: source)
    }

    private static func presentAlert(title: String, message: String, from source: UIViewController) {
        let present = { [weak source] in
            guard let source = source, source.viewIfLoaded?.window != nil, !source.isBeingDismissed,
                  source.navigationController?.isBeingDismissed != true, source.presentedViewController == nil else { return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: aiText("OK"), style: .default))
            source.present(alert, animated: true)
        }
        if let alert = source.presentedViewController as? UIAlertController, let coordinator = alert.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in present() }
        } else {
            DispatchQueue.main.async(execute: present)
        }
    }
}

private func configureLiteralField(_ field: UITextField) {
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    field.spellCheckingType = .no
    field.smartQuotesType = .no
    field.smartDashesType = .no
    field.smartInsertDeleteType = .no
}

@available(iOS 14.0, *)
private final class DepictionAIProviderForm: UITableViewController {
    typealias Kind = DepictionAIProvider.ProtocolKind
    var onSave: ((String, String, Kind, String?) -> Void)?
    private let editingProvider: Bool
    private var kind: Kind
    private var clearsKey = false
    private let nameField = UITextField()
    private let urlField = UITextField()
    private let keyField = UITextField()
    private let visibilityButton = UIButton(type: .system)

    init(provider: DepictionAIProvider.Provider?) {
        editingProvider = provider != nil
        kind = provider?.kind ?? .openAI
        super.init(style: .insetGrouped)
        title = aiText(editingProvider ? "Edit_Title" : "Add_Title")
        nameField.text = provider?.name
        nameField.placeholder = aiText("Name_Placeholder")
        urlField.text = provider?.baseURL
        urlField.placeholder = "https://api.example.com/v1"
        urlField.keyboardType = .URL
        keyField.placeholder = aiText(editingProvider ? "Key_Keep" : "Key_Placeholder")
        keyField.isSecureTextEntry = true
        configureLiteralField(urlField)
        configureLiteralField(keyField)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
        tableView.keyboardDismissMode = .interactive
        visibilityButton.setTitle(aiText("Show"), for: .normal)
        visibilityButton.addTarget(self, action: #selector(toggleVisibility), for: .touchUpInside)
        visibilityButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        for field in [nameField, urlField, keyField] {
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.clearButtonMode = .whileEditing
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { editingProvider ? 2 : 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 4 : 1 }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            let note = aiText("Key_Storage") + "\n\n" + aiText("Form_Consent")
            return Kind.allCases.map { $0.title }.joined(separator: " / ") + "\n" + note
        }
        return aiText("Clear_Key_Help")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1 {
            let cell = UITableViewCell()
            cell.textLabel?.text = aiText("Clear_Key")
            cell.textLabel?.numberOfLines = 0
            let toggle = UISwitch()
            toggle.isOn = clearsKey
            toggle.accessibilityLabel = aiText("Clear_Key")
            toggle.addTarget(self, action: #selector(setClearsKey(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
            return cell
        }
        switch indexPath.row {
        case 0: return fieldCell("Name", field: nameField)
        case 1:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = aiText("Protocol")
            cell.detailTextLabel?.text = kind.title
            cell.accessoryType = .disclosureIndicator
            return cell
        case 2: return fieldCell("URL", field: urlField)
        default: return fieldCell("Key", field: keyField, trailing: visibilityButton)
        }
    }

    private func fieldCell(_ key: String, field: UITextField, trailing: UIView? = nil) -> UITableViewCell {
        let cell = UITableViewCell()
        cell.selectionStyle = .none
        let label = UILabel()
        label.text = aiText(key)
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.accessibilityLabel = label.text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let input = UIStackView(arrangedSubviews: [field] + (trailing.map { [$0] } ?? []))
        input.alignment = .center
        input.spacing = 8
        let stack = UIStackView(arrangedSubviews: [label, input])
        stack.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: margins.topAnchor),
            stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        ])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.section == 0, indexPath.row == 1 else { return }
        tableView.deselectRow(at: indexPath, animated: true)
        view.endEditing(true)
        let alert = UIAlertController(title: aiText("Protocol"), message: nil, preferredStyle: .actionSheet)
        for option in Kind.allCases {
            alert.addAction(UIAlertAction(title: option.title, style: .default) { [weak self] _ in
                self?.kind = option
                self?.tableView.reloadRows(at: [indexPath], with: .none)
            })
        }
        alert.addAction(UIAlertAction(title: aiText("Cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
        if let cell = tableView.cellForRow(at: indexPath) {
            alert.popoverPresentationController?.sourceRect = cell.bounds
        }
        present(alert, animated: true)
    }

    @objc private func setClearsKey(_ sender: UISwitch) {
        clearsKey = sender.isOn
        if clearsKey {
            keyField.text = nil
            keyField.isSecureTextEntry = true
            visibilityButton.setTitle(aiText("Show"), for: .normal)
        }
        keyField.isEnabled = !clearsKey
        visibilityButton.isEnabled = !clearsKey
        keyField.placeholder = aiText(clearsKey ? "Clear_Key" : "Key_Keep")
    }

    @objc private func toggleVisibility() {
        let entered = keyField.text
        keyField.isSecureTextEntry.toggle()
        // Preserve only the text entered in this form, never reveal the saved credential.
        keyField.text = entered
        visibilityButton.setTitle(aiText(keyField.isSecureTextEntry ? "Show" : "Hide"), for: .normal)
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func save() {
        view.endEditing(true)
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = (urlField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (keyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        onSave?(name, url, kind, clearsKey ? "" : (key.isEmpty ? nil : key))
    }
}

@available(iOS 14.0, *)
private final class DepictionAIModelPicker: UITableViewController, UISearchResultsUpdating {
    var onPick: ((String) -> Void)?
    var onAppear: (() -> Void)?
    var selectedModel: String?
    var models: [String] = [] { didSet { reloadModels() } }
    var loading = false { didSet { reloadModels() } }
    private let search = UISearchController(searchResultsController: nil)
    private var visibleModels: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.placeholder = aiText("Search")
        configureLiteralField(search.searchBar.searchTextField)
        definesPresentationContext = true
        reloadModels()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let start = onAppear
        onAppear = nil
        start?()
    }

    func updateSearchResults(for searchController: UISearchController) { reloadModels() }

    private func reloadModels() {
        guard isViewLoaded else { return }
        let query = (search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        visibleModels = query.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(query) }
        if loading {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.accessibilityLabel = aiText("Loading")
            spinner.isAccessibilityElement = true
            spinner.startAnimating()
            tableView.backgroundView = spinner
        } else if visibleModels.isEmpty {
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .body)
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            label.text = aiText(query.isEmpty ? "Empty_List" : "No_Results")
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        loading ? 0 : visibleModels.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Model") ?? UITableViewCell(style: .default, reuseIdentifier: "Model")
        let model = visibleModels[indexPath.row]
        cell.textLabel?.text = model
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.accessoryType = model == selectedModel ? .checkmark : .none
        cell.accessibilityTraits = model == selectedModel ? [.button, .selected] : .button
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let model = visibleModels[indexPath.row]
        search.searchBar.resignFirstResponder()
        onPick?(model)
    }

    @objc private func close() { dismiss(animated: true) }
}
