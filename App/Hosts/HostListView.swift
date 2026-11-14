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
    @State private var showingSettings = false
    @State private var showingRename = false
    @State private var renamingHost: TemporaryHost?
    @State private var renameText = ""
    @State private var pendingDeleteHost: TemporaryHost?
    @State private var showingDeleteConfirm = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("MoonlightVision")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddHost = true
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
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
        .sheet(isPresented: $showingAddHost) {
            AddHostSheet(model: model)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
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

    @ViewBuilder
    private var sidebar: some View {
        if model.hosts.isEmpty {
            ContentUnavailableView {
                Label("No Hosts", systemImage: "desktopcomputer")
            } description: {
                Text("Start Sunshine on a PC on the same network, or add one by address.")
            } actions: {
                Button("Add Host") {
                    showingAddHost = true
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            List(selection: $selection) {
                Section("Hosts") {
                    ForEach(model.hosts, id: \.uuid) { host in
                        HostRow(host: host)
                            .tag(host.uuid)
                            .contextMenu {
                                Button {
                                    model.wakeHost(host)
                                } label: {
                                    Label("Wake PC", systemImage: "power")
                                }
                                .disabled(host.state == .online)

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
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, let host = model.hosts.first(where: { $0.uuid == selection }) {
            HostSessionView(host: host, discovery: model.discoveryManager)
                .id(host.uuid)
        } else {
            ContentUnavailableView {
                Label("Choose a Host", systemImage: "sparkles.tv")
            } description: {
                Text("Select a computer on the left to see its games.")
            }
        }
    }

    private func selectFirstIfNeeded() {
        if selection == nil {
            selection = model.hosts.first?.uuid
        }
    }
}

private struct HostRow: View {
    let host: TemporaryHost

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(host.state == .online ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(host.activeAddress ?? host.address ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if host.pairState != .paired {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AddHostSheet: View {
    @Environment(\.dismiss) private var dismiss

    let model: HostListModel

    @State private var address = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Host Manually")
                .font(.title2.bold())
            Text("Enter the IP address or hostname of a PC running Sunshine.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("192.168.1.10", text: $address)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                Button(isWorking ? String(localized: "Adding…") : String(localized: "Add")) {
                    isWorking = true
                    errorMessage = nil
                    model.addHost(address: address) { message in
                        isWorking = false
                        if let message {
                            errorMessage = message
                        } else {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(36)
        .frame(minWidth: 480)
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
