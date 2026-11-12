//
//  HostListView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI

struct HostListView: View {
    @State private var model = HostListModel()

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
                        HostRow(host: host)
                    }
                }
            }
            .navigationTitle("MoonlightVision")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        model.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
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
        }
        .padding(8)
    }
}
