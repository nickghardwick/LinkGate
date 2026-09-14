import SwiftUI

struct RoutingSettingsView: View {
    @StateObject private var model: RoutingSettingsModel
    @State private var editingRule: RoutingRule?
    @State private var showingEditor = false

    init(model: RoutingSettingsModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            if model.setupIsIncomplete {
                GroupBox("Set up LinkGate") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LinkGate needs to handle HTTP and HTTPS links to receive them.")
                        defaultBrowserControls
                        Text(detectedBrowsersSummary)
                            .foregroundStyle(.secondary)
                        Text("Launch at Login is recommended, but optional. You can change it below.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("Done") { model.completeSetup() }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            GroupBox("General") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Launch LinkGate at Login", isOn: Binding(
                        get: { model.launchAtLoginStatus == .enabled },
                        set: { model.setLaunchAtLoginEnabled($0) }
                    ))
                    .disabled(!model.canChangeLaunchAtLogin || model.isChangingLaunchAtLogin ||
                              model.launchAtLoginStatus == .unavailable || model.launchAtLoginStatus == .requiresApproval)
                    if !model.canChangeLaunchAtLogin {
                        Text("Launch at Login can only be changed from the installed LinkGate copy.")
                            .foregroundStyle(.secondary)
                    }
                    if model.launchAtLoginStatus == .requiresApproval {
                        Text("Approve LinkGate in Login Items to allow automatic launch.")
                            .foregroundStyle(.secondary)
                        Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
                    } else if model.launchAtLoginStatus == .unavailable {
                        Text("Launch at Login is unavailable for this copy.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            GroupBox("Default browser") {
                defaultBrowserControls
                .padding(.vertical, 2)
            }
            GroupBox("Browsers") {
                if model.detectedBrowsers.isEmpty {
                    Text("No supported browsers found.")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(model.detectedBrowsers) { browser in
                            HStack {
                                Image(nsImage: browser.icon)
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                Text(browser.displayName)
                                Spacer()
                                Toggle("Show in chooser", isOn: Binding(
                                    get: { model.isBrowserEnabled(browser) },
                                    set: { _ = model.setBrowserEnabled($0, for: browser) }
                                ))
                                .labelsHidden()
                                .accessibilityLabel("Show \(browser.displayName) in chooser")
                                .disabled(model.isBrowserEnabled(browser) && !model.canDisableBrowser(browser))
                            }
                        }
                        .onMove { offsets, destination in
                            _ = model.moveBrowsers(from: offsets, to: destination)
                        }
                    }
                    .frame(height: 150)
                    .layoutPriority(1)
                }
            }
            if !model.rules.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.rules, id: \RoutingRule.id) { rule in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(label(for: rule.matchType))
                                    Text(rule.pattern).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(model.browserName(for: rule.browserBundleIdentifier))
                                    .foregroundStyle(model.isBrowserAvailable(rule.browserBundleIdentifier) ? Color.secondary : Color.red)
                                Button("Edit") {
                                    model.clearError()
                                    editingRule = rule
                                    showingEditor = true
                                }
                                .accessibilityLabel("Edit rule for \(rule.pattern)")
                                Button("Delete") {
                                    _ = model.deleteRule(id: rule.id)
                                }
                                .accessibilityLabel("Delete rule for \(rule.pattern)")
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(model.rules.count) * 48, 120))
            }
            HStack {
                Button("Add Rule") {
                    model.clearError()
                    editingRule = nil
                    showingEditor = true
                }
                .accessibilityLabel("Add routing rule")
                Spacer()
                if let errorMessage = model.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            if let storageWarning = model.storageWarning {
                Text(storageWarning).foregroundStyle(.orange)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showingEditor) {
            RoutingRuleEditor(model: model, rule: editingRule, isPresented: $showingEditor)
        }
    }

    private var defaultBrowserControls: some View {
        HStack {
            Text(defaultStatusText)
            Spacer()
            Button("Make/Repair LinkGate Default") { model.requestDefaultBrowser() }
                .disabled(model.isRequestingDefault || model.defaultBrowserStatus.isDefault)
                .accessibilityLabel("Make LinkGate the default browser for HTTP and HTTPS")
        }
    }

    private var detectedBrowsersSummary: String {
        let names = model.detectedBrowsers.map(\.displayName)
        if names.isEmpty { return "No supported browsers detected yet." }
        return "Detected browsers: \(names.joined(separator: ", "))."
    }

    private var defaultStatusText: String {
        if model.defaultBrowserStatus.isDefault {
            return "LinkGate is the default for HTTP and HTTPS."
        }
        if model.defaultBrowserStatus.httpIsDefault {
            return "LinkGate is the default for HTTP only."
        }
        if model.defaultBrowserStatus.httpsIsDefault {
            return "LinkGate is the default for HTTPS only."
        }
        return "LinkGate is not the default browser."
    }

    private func label(for matchType: RoutingRule.MatchType) -> String {
        switch matchType {
        case .exactDomain: "Exact Domain"
        case .domainFamily: "Domain + Subdomains"
        case .urlPrefix: "URL Prefix"
        }
    }
}

private struct RoutingRuleEditor: View {
    @ObservedObject var model: RoutingSettingsModel
    let rule: RoutingRule?
    @Binding var isPresented: Bool
    @State private var matchType: RoutingRule.MatchType
    @State private var pattern: String
    @State private var browserBundleIdentifier: String

    init(model: RoutingSettingsModel, rule: RoutingRule?, isPresented: Binding<Bool>) {
        self.model = model
        self.rule = rule
        _isPresented = isPresented
        _matchType = State(initialValue: rule?.matchType ?? .exactDomain)
        _pattern = State(initialValue: rule?.pattern ?? "")
        _browserBundleIdentifier = State(initialValue: rule?.browserBundleIdentifier ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Type", selection: $matchType) {
                Text("Exact Domain").tag(RoutingRule.MatchType.exactDomain)
                Text("Domain + Subdomains").tag(RoutingRule.MatchType.domainFamily)
                Text("URL Prefix").tag(RoutingRule.MatchType.urlPrefix)
            }
            TextField("Pattern", text: $pattern)
            Picker("Browser", selection: $browserBundleIdentifier) {
                Text("Choose a browser").tag("")
                ForEach(model.browserChoices) { candidate in
                    HStack {
                        Image(nsImage: candidate.icon)
                        Text(candidate.displayName)
                    }
                    .tag(candidate.bundleIdentifier ?? "")
                }
                if !browserBundleIdentifier.isEmpty && !model.isBrowserAvailable(browserBundleIdentifier) {
                    Text("Unavailable browser").tag(browserBundleIdentifier)
                }
            }
            .accessibilityLabel("Browser for routing rule")
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel editing routing rule")
                Button("Save") {
                    if model.saveRule(
                        id: rule?.id,
                        matchType: matchType,
                        pattern: pattern,
                        browserBundleIdentifier: browserBundleIdentifier
                    ) {
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Save routing rule")
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
