import SwiftUI
import VisionKit

struct EventsView: View {
    @Environment(AppState.self) private var app
    @State private var code = ""
    @State private var codeError: String?
    @State private var detail: Game?
    @State private var scanning = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Provo, Utah")
                    MegaTitle(lines: ["GAME", "NITE"])
                }
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Have a game code?").font(.subheadline.weight(.semibold))
                    HStack(spacing: 10) {
                        TextField("", text: $code, prompt: Text("GN-0000").foregroundStyle(Theme.muted))
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .focused($codeFocused)
                            .fieldStyle(focused: codeFocused)
                            .submitLabel(.go)
                            .onSubmit { Task { await open(code) } }
                        Button("Open") { Task { await open(code) } }
                            .buttonStyle(.ctaCompact)
                            .disabled(code.trimmingCharacters(in: .whitespaces).count < 4)
                    }
                    if let codeError {
                        Text(codeError).font(.footnote).foregroundStyle(Theme.crit)
                    } else {
                        Button {
                            scanning = true
                        } label: {
                            Label("Scan the QR code at the start point", systemImage: "qrcode.viewfinder")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.neon)
                        }
                    }
                }

                if app.games.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No games scheduled yet").font(.headline)
                        Text("When an organizer posts a game night, it shows up here.")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    .panel()
                } else {
                    ForEach(app.games) { game in
                        Button { detail = game } label: { EventCard(game: game) }
                            .buttonStyle(.plain)
                    }
                }

                ComingSoonCard()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
        .refreshable { await app.loadGames() }
        .sheet(item: $detail) { game in
            EventDetailView(game: game)
        }
        .sheet(isPresented: $scanning) {
            QRScannerSheet { scanned in
                scanning = false
                Task { await open(scanned) }
            }
        }
        .onChange(of: app.pendingCode) { _, new in
            guard let new else { return }
            app.pendingCode = nil
            Task { await open(new) }
        }
        .task {
            if let pending = app.pendingCode {
                app.pendingCode = nil
                await open(pending)
            }
        }
    }

    private func open(_ raw: String) async {
        codeError = nil
        codeFocused = false
        if let game = await app.game(withCode: raw) {
            detail = game
            code = ""
        } else {
            codeError = "No game uses that code. Check it with the organizer."
        }
    }
}

struct EventCard: View {
    let game: Game

    private var statusTint: Color {
        switch game.status {
        case .lobby: Theme.ok
        case .preparing, .paused: Theme.warn
        case .active: Theme.neon
        case .terminated: Theme.crit
        default: Theme.muted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SardineBanner()
                .frame(height: 92)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Pill(text: game.status.label, tint: statusTint)
                    Pill(text: "Free")
                }
                Text(game.title)
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("\(game.whenText) · \(game.locationName.isEmpty ? "Location TBA" : game.locationName)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                Text("Sardines · up to \(game.config.capacity) players · 18+")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glowCard()
        .contentShape(Rectangle())
    }
}

/// The neon banner with a school of white fish and one charcoal "sardine" that's hiding.
struct SardineBanner: View {
    var body: some View {
        ZStack {
            FlowGradient(colors: Theme.bannerColors, duration: 9)
            GeometryReader { geo in
                ForEach(0..<9, id: \.self) { i in
                    Image(systemName: "fish.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.4 + Double(i % 3) * 0.2))
                        .rotationEffect(.degrees(i % 2 == 0 ? -6 : 8))
                        .position(x: geo.size.width * (0.08 + Double(i) * 0.1), y: 30 + Double(i % 3) * 16)
                }
                Image(systemName: "fish.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.bg)
                    .rotationEffect(.degrees(-8))
                    .position(x: geo.size.width * 0.84, y: 62)
            }
        }
        .accessibilityHidden(true)
    }
}

struct ComingSoonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Pill(text: "Coming later")
            Text("Saturday Showdown")
                .font(.system(size: 21, weight: .heavy))
            Text("Ticketed individual competition with 1st–3rd place prizes.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        }
        .opacity(0.6)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glowCard(duration: 11, dimmed: true)
    }
}

// MARK: - QR scanning

struct QRScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScanner(onCode: onCode)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.metering.unknown")
                            .font(.system(size: 40))
                            .foregroundStyle(Theme.neon)
                        Text("Scanning isn't available")
                            .font(.headline)
                        Text("Allow camera access for Game Nite in Settings, or type the game code instead.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
                }
            }
            .navigationTitle("Scan game code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let code) = item, let payload = code.payloadStringValue {
                    done = true
                    scanner.stopScanning()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onCode(payload)
                    return
                }
            }
        }
    }
}
