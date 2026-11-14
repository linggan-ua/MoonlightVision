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

    var body: some View {
        NavigationStack {
            Group {
                if model.hosts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Searching for hosts…")
                            .font(.headline)
                        Text("Start Sunshine on a PC on the same network.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(40)
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

                            Button(role: .destructive) {
                                model.deleteHost(host)
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
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        model.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
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
    }
}

private struct HostRow: View {
    let host: TemporaryHost

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
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
            Circle()
                .fill(host.state == .online ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            Text(host.pairState == .paired ? "Paired" : "Not Paired")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
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
                Button(isWorking ? "Adding…" : "Add") {
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
