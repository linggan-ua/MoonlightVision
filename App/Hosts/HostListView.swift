//
//  HostListView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI

struct HostListView: View {
    @State private var model = HostListModel()
    @State private var selection: String?
    @State private var showingAddHost = false
    @State private var newHostIp = ""
    @State private var addError: String?
    @State private var showingAddError = false
    @State private var showingRename = false
    @State private var renamingHost: TemporaryHost?
    @State private var renameText = ""
    @State private var pendingDeleteHost: TemporaryHost?
    @State private var showingDeleteConfirm = false

    var body: some View {
        TabView {
            computersTab
                .tabItem {
                    Label("Computers", systemImage: "desktopcomputer")
                }

            SettingsView(showsDoneButton: false)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .task { model.start() }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: model.hosts.map(\.uuid)) { _, ids in
            if let selection, !ids.contains(selection) {
                self.selection = ids.first
            } else if selection == nil {
                selection = ids.first
            }
        }
        .alert("Enter server", isPresented: $showingAddHost) {
            TextField("IP or hostname", text: $newHostIp)
            Button("Add") {
                addHost()
            }
            Button("Cancel", role: .cancel) {
                newHostIp = ""
            }
        } message: {
            Text("Enter the IP address or hostname of a PC running Sunshine.")
        }
        .alert("Unable to add host", isPresented: $showingAddError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addError ?? "")
        }
        .sheet(isPresented: $showingRename) {
            RenameHostSheet(initialName: renameText) { name in
                if let host = renamingHost {
                    model.renameHost(host, to: name)
                }
                renamingHost = nil
            }
        }
        .confirmationDialog(
            "Delete Host?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let host = pendingDeleteHost {
                    model.deleteHost(host)
                }
                pendingDeleteHost = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteHost = nil
            }
        } message: {
            Text("This removes the saved certificate and cached apps for this host.")
        }
    }

    private var computersTab: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Computers")
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAddHost = true
                        } label: {
                            Label("Add Server", systemImage: "plus")
                        }
                    }
                }
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            if model.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No Hosts", systemImage: "desktopcomputer")
                } description: {
                    Text("Start Sunshine on a PC on the same network, or add one by address.")
                } actions: {
                    Button("Add Server") {
                        showingAddHost = true
                    }
                }
            } else {
                List(selection: $selection) {
                    ForEach(model.hosts, id: \.uuid) { host in
                        HostRow(host: host)
                            .tag(host.uuid)
                            .contextMenu {
                                if host.state != .online {
                                    Button {
                                        model.wakeHost(host)
                                    } label: {
                                        Label("Wake PC", systemImage: "sun.horizon")
                                    }
                                    .disabled(host.mac == nil || host.mac == "00:00:00:00:00:00")
                                }

                                Button {
                                    renamingHost = host
                                    renameText = host.name
                                    showingRename = true
                                } label: {
                                    Label("Rename Host", systemImage: "pencil")
                                }

                                Button(role: .destructive) {
                                    pendingDeleteHost = host
                                    showingDeleteConfirm = true
                                } label: {
                                    Label("Delete Host", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }

            Button {
                if model.isDiscovering {
                    model.stop()
                } else {
                    model.start()
                }
            } label: {
                Text(model.isDiscovering ? "Click to stop discovery" : "Click to scan hosts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, let host = model.hosts.first(where: { $0.uuid == selection }) {
            HostSessionView(host: host, discovery: model.discoveryManager)
                .id(host.uuid)
        } else {
            ContentUnavailableView {
                Label("No Host Selected", systemImage: "sparkles.tv")
            } description: {
                Text("Select a computer on the left to see its apps.")
            }
        }
    }

    private func selectFirstIfNeeded() {
        guard selection == nil else { return }
        selection = model.hosts.first(where: { $0.pairState == .paired })?.uuid
            ?? model.hosts.first?.uuid
    }

    private func addHost() {
        let address = newHostIp
        newHostIp = ""
        model.addHost(address: address) { message in
            if let message {
                addError = message
                showingAddError = true
            }
        }
    }
}

private struct HostRow: View {
    let host: TemporaryHost

    private var iconName: String {
        switch host.state {
        case .online:
            return host.pairState == .paired ? "desktopcomputer" : "lock.desktopcomputer"
        case .offline:
            return "desktopcomputer.trianglebadge.exclamationmark"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch host.state {
        case .online:
            return host.pairState == .paired ? .green : .orange
        case .offline:
            return .red
        case .unknown:
            return .gray
        }
    }

    var body: some View {
        Label {
            Text(host.name)
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
        }
        .foregroundStyle(host.state == .online ? .primary : .secondary)
        .opacity(host.state == .online ? 1.0 : 0.6)
    }
}

private struct RenameHostSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialName: String
    let onSave: (String) -> Void

    @State private var name: String

    init(initialName: String, onSave: @escaping (String) -> Void) {
        self.initialName = initialName
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rename Host")
                .font(.title2.bold())
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                Button("Save") {
                    onSave(name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(36)
        .frame(minWidth: 480)
    }
}
