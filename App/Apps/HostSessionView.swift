//
//  HostSessionView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI

struct HostSessionView: View {
    @State private var model: HostSessionModel
    @State private var streamModel: StreamSessionModel?

    init(host: TemporaryHost, discovery: DiscoveryManager?) {
        _model = State(initialValue: HostSessionModel(host: host, discovery: discovery))
    }

    var body: some View {
        Group {
            if let streamModel {
                StreamWindowView(model: streamModel) {
                    self.streamModel = nil
                }
            } else {
                content
            }
        }
        .task { await model.start() }
        .navigationTitle(model.hostName)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checking:
            StatusView(
                title: "Connecting to \(model.hostName)…",
                systemImage: "antenna.radiowaves.left.and.right"
            )
        case .pairing(let pin):
            PairingView(hostName: model.hostName, pin: pin)
        case .loadingApps:
            StatusView(title: "Loading apps…", systemImage: "square.grid.2x2")
        case .ready:
            AppsView(apps: model.apps, hostName: model.hostName) { app in
                streamModel = StreamSessionModel(host: model.host, app: app)
            } onRefresh: {
                Task { await model.refreshApps() }
            }
        case .failed(let message):
            FailureView(message: message) {
                model.retry()
            }
        }
    }
}

private struct StatusView: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding(48)
    }
}

private struct PairingView: View {
    let hostName: String
    let pin: String

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Pair with \(hostName)")
                .font(.title2.bold())
            Text("Enter this PIN in Sunshine on your PC to accept the pairing request.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text(pin)
                .font(.system(size: 64, weight: .semibold, design: .monospaced))
                .tracking(10)
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            ProgressView()
        }
        .padding(48)
    }
}

private struct FailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
            Text("Connection Failed")
                .font(.title2.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(48)
    }
}

private struct AppsView: View {
    let apps: [TemporaryApp]
    let hostName: String
    let onLaunch: (TemporaryApp) -> Void
    let onRefresh: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 24)]

    var body: some View {
        Group {
            if apps.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("No apps available")
                        .font(.headline)
                    Text("Add apps in Sunshine on your PC, then refresh.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(48)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(apps, id: \.id) { app in
                            Button {
                                onLaunch(app)
                            } label: {
                                AppCard(app: app)
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.lift)
                        }
                    }
                    .padding(32)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

private struct AppCard: View {
    let app: TemporaryApp

    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.quaternary)
                .frame(height: 120)
                .overlay {
                    Image(systemName: "app.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                }

            Text(app.name ?? "Unknown App")
                .font(.headline)
                .lineLimit(1)

            if app.hdrSupported {
                Text("HDR")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
