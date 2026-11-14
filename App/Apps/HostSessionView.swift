//
//  HostSessionView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI
import UIKit

struct HostSessionView: View {
    @Environment(\.openWindow) private var openWindow

    @State private var model: HostSessionModel
    @State private var pendingApp: TemporaryApp?
    @State private var showQuitConfirm = false
    @State private var actionError: String?

    init(host: TemporaryHost, discovery: DiscoveryManager?) {
        _model = State(initialValue: HostSessionModel(host: host, discovery: discovery))
    }

    var body: some View {
        content
            .task { await model.start() }
            .navigationTitle(model.hostName)
        .confirmationDialog(
            "Another app is running",
            isPresented: $showQuitConfirm,
            titleVisibility: .visible
        ) {
            Button("Quit Running App and Start", role: .destructive) {
                startAfterQuitting()
            }
            Button("Cancel", role: .cancel) {
                pendingApp = nil
            }
        } message: {
            Text("Close the app that is currently running on the host, then start this one.")
        }
        .alert("Could Not Start", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                actionError = nil
            }
        } message: {
            Text(actionError ?? "")
        }
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
            AppsView(
                apps: model.displayedApps,
                hostName: model.hostName,
                runningAppID: model.runningAppID,
                boxArtToken: model.boxArtToken,
                showHiddenApps: model.showHiddenApps,
                onLaunch: requestLaunch,
                onToggleShowHidden: { model.showHiddenApps.toggle() },
                onToggleAppHidden: { model.toggleHidden($0) },
                onRefresh: { Task { await model.refreshApps() } }
            )
        case .failed(let message):
            FailureView(message: message) {
                model.retry()
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )
    }

    private func requestLaunch(_ app: TemporaryApp) {
        if let running = model.runningAppID, running != app.id {
            pendingApp = app
            showQuitConfirm = true
        } else {
            startStream(app)
        }
    }

    private func startAfterQuitting() {
        guard let app = pendingApp else { return }
        pendingApp = nil
        Task {
            let quit = await model.quitCurrentApp()
            if quit {
                startStream(app)
            } else {
                actionError = String(localized: "The host is still running another app. Quit it on the PC or try again.")
            }
        }
    }

    private func startStream(_ app: TemporaryApp) {
        // One stream at a time: bring the existing stream window forward rather
        // than replacing a live session mid-connection.
        guard StreamPresentation.shared.session == nil else {
            openWindow(id: "stream")
            return
        }
        StreamPresentation.shared.session = StreamSessionModel(host: model.host, app: app)
        openWindow(id: "stream")
    }
}

private struct StatusView: View {
    let title: LocalizedStringKey
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
    let runningAppID: String?
    let boxArtToken: Int
    let showHiddenApps: Bool
    let onLaunch: (TemporaryApp) -> Void
    let onToggleShowHidden: () -> Void
    let onToggleAppHidden: (TemporaryApp) -> Void
    let onRefresh: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 24)]

    @State private var searchText = ""

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
            } else if filteredApps.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No apps match your search.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(48)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(filteredApps, id: \.id) { app in
                            Button {
                                onLaunch(app)
                            } label: {
                                AppCard(
                                    app: app,
                                    isRunning: app.id == runningAppID,
                                    boxArtToken: boxArtToken,
                                    onToggleHidden: { onToggleAppHidden(app) }
                                )
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.lift)
                        }
                    }
                    .padding(32)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search apps")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button(action: onToggleShowHidden) {
                    Label(
                        showHiddenApps ? String(localized: "Hide Hidden Apps") : String(localized: "Show Hidden Apps"),
                        systemImage: showHiddenApps ? "eye.slash" : "eye"
                    )
                }
            }
        }
    }

    private var filteredApps: [TemporaryApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter { ($0.name ?? "").localizedCaseInsensitiveContains(query) }
    }
}

private struct AppCard: View {
    let app: TemporaryApp
    let isRunning: Bool
    let boxArtToken: Int
    let onToggleHidden: () -> Void

    private var boxArt: UIImage? {
        let path: String = AppAssetManager.boxArtPath(for: app)
        return UIImage(contentsOfFile: path)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary)
                if let boxArt {
                    Image(uiImage: boxArt)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .id(boxArtToken)

            Text(app.name ?? String(localized: "Unknown App"))
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 6) {
                if isRunning {
                    Text("Running")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.25), in: Capsule())
                }
                if app.hdrSupported {
                    Text("HDR")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .contextMenu {
            Button(app.hidden ? String(localized: "Show App") : String(localized: "Hide App"), action: onToggleHidden)
        }
    }
}
