//
//  HostListView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI

struct HostListView: View {
    @State private var model = HostListModel()
    @State private var showingAddHost = false
    @State private var showingSettings = false
    @State private var showingRename = false
    @State private var renamingHost: TemporaryHost?
    @State private var renameText = ""
    @State private var pendingDeleteHost: TemporaryHost?
    @State private var showingDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if model.hosts.isEmpty {
                    emptyState
                } else {
                    List(model.hosts, id: \.uuid) { host in
                        NavigationLink {
                            HostSessionView(host: host, discovery: model.discoveryManager)
                        } label: {
                            HostRow(host: host)
                        }
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
            .navigationTitle("MoonlightVision")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingAddHost = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Host")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        model.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .task { model.start() }
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            ProgressView()
            Image(systemName: "desktopcomputer")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Searching for hosts…")
                .font(.headline)
            Text("Start Sunshine on a PC on the same network.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Host") {
                showingAddHost = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(48)
    }
}

private struct HostRow: View {
    let host: TemporaryHost

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(host.name)
                    .font(.headline)
                if let address = host.activeAddress ?? host.address {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(host.state == .online ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)

                Text(host.pairState == .paired ? String(localized: "Paired") : String(localized: "Not Paired"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .padding(.vertical, 6)
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
