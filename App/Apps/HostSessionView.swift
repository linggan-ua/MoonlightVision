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
        VStack(spacing: 0) {
            HostHeader(host: model.host, runningAppID: model.runningAppID)
            content
        }
        .task { await model.start() }
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
            StatusPanel(
                title: "Connecting to \(model.hostName)…",
                systemImage: "antenna.radiowaves.left.and.right"
            )
        case .pairing(let pin):
            PairingView(hostName: model.hostName, pin: pin)
        case .loadingApps:
            StatusPanel(title: "Loading apps…", systemImage: "square.grid.2x2")
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
            ContentUnavailableView {
                Label("Connection Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry", action: model.retry)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct HostHeader: View {
    let host: TemporaryHost
    let runningAppID: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(host.name)
                    .font(.title2.bold())
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Circle()
                        .fill(host.state == .online ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(host.activeAddress ?? host.address ?? "—")
                    Text(host.pairState == .paired ? String(localized: "Paired") : String(localized: "Not Paired"))
                    if runningAppID != nil {
                        Text("Running")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.25), in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}

private struct StatusPanel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PairingView: View {
    let hostName: String
    let pin: String

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
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
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            ProgressView()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 20)]

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Apps")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 2)
            .padding(.bottom, 4)

            Group {
                if apps.isEmpty {
                    ContentUnavailableView {
                        Label("No apps available", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Add apps in Sunshine on your PC, then refresh.")
                    } actions: {
                        Button("Refresh", action: onRefresh)
                            .buttonStyle(.borderedProminent)
                    }
                } else if filteredApps.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
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
                        .padding(.horizontal, 28)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                    }
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
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    ZStack(alignment: .topTrailing) {
                        ZStack {
                            LinearGradient(
                                colors: [Color(white: 0.16), Color(white: 0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            if let boxArt {
                                Image(uiImage: boxArt)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                Image(systemName: "app.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                        VStack(alignment: .trailing, spacing: 6) {
                            if isRunning {
                                Text("Running")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.green.opacity(0.9), in: Capsule())
                            }
                            if app.hdrSupported {
                                Text("HDR")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                        }
                        .padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                .id(boxArtToken)

            Text(app.name ?? String(localized: "Unknown App"))
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
        .contentShape(.rect)
        .contextMenu {
            Button(app.hidden ? String(localized: "Show App") : String(localized: "Hide App"), action: onToggleHidden)
        }
    }
}
