import SwiftUI
import AppKit

/// The "Connect Whoop" guided flow, shown in a real window (not the menu-bar popover) so it
/// stays open while the user copies values into Whoop's site and goes through the browser login.
struct ConnectView: View {
    @ObservedObject var auth: WhoopAuth
    let onClose: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var copiedText: String?
    @State private var prefilled = false

    private var pal: Pal { Pal(scheme: scheme) }
    private let createAppURL = "https://developer-dashboard.whoop.com/apps/create"
    private let whoopGuideURL = "https://developer.whoop.com/docs/developing/getting-started"
    private let redirectURI = "http://localhost:8973/callback"
    private let privacyURL = "https://github.com/Mahir-Isikli/whoopbar/blob/main/PRIVACY.md"

    var body: some View {
        ZStack {
            pal.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect Whoop").font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("Recovery, Sleep, Strain & HRV — kept on this Mac.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                if auth.isConnected { connectedBanner }

                step(1, "Create your Whoop app") {
                    Button { NSWorkspace.shared.open(URL(string: createAppURL)!) } label: {
                        Label("Open Whoop Developer", systemImage: "arrow.up.forward")
                            .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 3)
                    }.buttonStyle(.borderedProminent).tint(Metric.recovery.tint)
                    row("Name", "anything")
                    row("Logo", "skip")
                    row("Contacts", "your email")
                    row("Privacy", privacyURL, copyable: true)
                    row("Redirect", redirectURI, copyable: true)
                    row("Scopes", "recovery, sleep, cycles, workout, profile")
                    Text("then Create.").font(.system(size: 11)).foregroundStyle(.secondary)
                }

                step(2, "Paste your keys") {
                    pasteField("Client ID", text: $clientId)
                    pasteField("Client Secret", text: $clientSecret, secure: true)
                }

                Button { auth.connect(clientId: clientId, clientSecret: clientSecret) } label: {
                    Text(connectLabel).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(Metric.recovery.tint)
                .disabled(clientId.isEmpty || clientSecret.isEmpty || auth.status == .connecting || auth.status == .syncing)

                status

                Link("New to this? Read Whoop's setup guide", destination: URL(string: whoopGuideURL)!)
                    .font(.system(size: 10)).tint(.secondary).frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(20)
        }
        .frame(width: 380)
        // Reopened from the footer key, the saved keys are prefilled so you can verify or edit them.
        .onAppear {
            guard !prefilled else { return }
            prefilled = true
            if clientId.isEmpty { clientId = Secrets.get("clientId") ?? "" }
            if clientSecret.isEmpty { clientSecret = Secrets.get("clientSecret") ?? "" }
        }
        // Close only on a fresh transition into connected — not when reopened while already connected.
        .onChange(of: auth.status) { old, s in if s == .connected && old != .connected { onClose() } }
    }

    /// Shown when WhoopBar already holds working credentials: confirms the link and offers a way out.
    private var connectedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(Metric.recovery.tint)
            Text("Connected to Whoop").font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Disconnect") { auth.disconnect() }
                .font(.system(size: 11)).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(pal.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(pal.hairline, lineWidth: 1))
    }

    private var connectLabel: String {
        switch auth.status {
        case .connecting: return "Waiting for login…"
        case .syncing: return "Fetching…"
        case .connected: return "Reconnect"
        default: return "Connect"
        }
    }

    @ViewBuilder private var status: some View {
        switch auth.status {
        case .connecting:
            row(spinner: "Approve the login in your browser, then come back here.")
        case .syncing:
            row(spinner: "Fetching your Whoop data…")
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(Color(red: 0.9, green: 0.42, blue: 0.4))
        default:
            EmptyView()
        }
    }

    private func row(spinner text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func step<C: View>(_ num: Int, _ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Text("\(num)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Circle().fill(Metric.recovery.tint))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 8) { content() }.padding(.leading, 29)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(pal.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(pal.hairline, lineWidth: 1))
        .shadow(color: pal.shadow, radius: 4, y: 1)
    }

    private func row(_ label: String, _ value: String, copyable: Bool = false) -> some View {
        HStack(alignment: copyable ? .center : .top, spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold)).frame(width: 62, alignment: .leading)
            if copyable {
                HStack(spacing: 6) {
                    Text(value).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    copyButton(value)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(pal.pillRest).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text(value).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copyButton(_ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
            copiedText = value
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copiedText == value { copiedText = nil } }
        } label: {
            Image(systemName: copiedText == value ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain).foregroundStyle(copiedText == value ? Metric.recovery.tint : Color.secondary)
    }

    private func pasteField(_ placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        // Sanitize on the binding so Cmd+V, typing, and the Paste button all yield a valid value:
        // WHOOP's dashboard copies the UUID with fancy dashes + a trailing newline, which the
        // OAuth call rejects. cleanCredential normalizes those.
        let cleaned = Binding(get: { text.wrappedValue },
                              set: { text.wrappedValue = cleanCredential($0) })
        return HStack(spacing: 6) {
            Group {
                if secure { SecureField(placeholder, text: cleaned) } else { TextField(placeholder, text: cleaned) }
            }
            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
            Button { text.wrappedValue = cleanCredential(NSPasteboard.general.string(forType: .string) ?? "") } label: {
                Image(systemName: "doc.on.clipboard").font(.system(size: 11))
            }.buttonStyle(.bordered).controlSize(.small).help("Paste")
        }
    }
}
