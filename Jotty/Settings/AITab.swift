import SwiftUI

struct AITab: View {
    @State private var availability: AIAvailability = .unavailable(reason: "checking…")
    @State private var selectedProvider: String = "apple-fm"

    var body: some View {
        Form {
            Section(header: Text("Provider")) {
                Picker("AI provider", selection: $selectedProvider) {
                    Text("Apple Foundation Models (on-device)").tag("apple-fm")
                    // Phase 4 placeholder entries are intentionally absent —
                    // dropdown is a seam, not a teaser.
                }
                .pickerStyle(.menu)
            }

            Section(header: Text("Availability")) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(pillColor)
                        .frame(width: 10, height: 10)
                    Text(pillText).font(.system(size: 13))
                }
                if case .unavailable(let reason) = availability {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            Section(header: Text("Privacy")) {
                Text("Apple Foundation Models runs entirely on this Mac. No capture text leaves the device.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 480, height: 320)
        .onAppear { availability = AIAvailability.current() }
    }

    private var pillColor: Color {
        switch availability {
        case .available: return .green
        case .downloading: return .yellow
        case .unavailable: return .red
        }
    }

    private var pillText: String {
        switch availability {
        case .available: return "Available"
        case .downloading: return "Downloading…"
        case .unavailable: return "Unavailable"
        }
    }
}
