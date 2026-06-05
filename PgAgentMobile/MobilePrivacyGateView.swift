import SwiftUI
import LocalAuthentication

struct MobilePrivacyGateView<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var covered = false
    @State private var locked = false
    @State private var authenticating = false
    @State private var lastBackgroundDate: Date?
    @State private var unlockError: String?

    private let lockAfterBackground: TimeInterval = 2 * 60
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .blur(radius: covered || locked ? 18 : 0)
                .saturation(covered || locked ? 0.2 : 1)
                .allowsHitTesting(!covered && !locked)

            if covered && !locked {
                privacyCover
            }

            if locked {
                lockedCover
            }
        }
        .animation(.easeOut(duration: 0.16), value: covered)
        .animation(.easeOut(duration: 0.16), value: locked)
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(newPhase)
        }
    }

    private var privacyCover: some View {
        ZStack {
            Color(.systemBackground)
                .opacity(0.96)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                Text("pgAgent")
                    .font(.title3.weight(.semibold))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("pgAgent protected")
        }
    }

    private var lockedCover: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)

                Text("pgAgent Locked")
                    .font(.title3.weight(.semibold))

                Button {
                    Task { await unlock() }
                } label: {
                    if authenticating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Unlock", systemImage: "faceid")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(authenticating)

                if let unlockError {
                    Text(unlockError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding()
            .frame(maxWidth: 320)
        }
    }

    private func handleScenePhase(_ newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            let shouldLock = lastBackgroundDate.map {
                Date().timeIntervalSince($0) >= lockAfterBackground
            } ?? false

            covered = false
            if shouldLock {
                locked = true
            }
            lastBackgroundDate = nil

        case .inactive:
            covered = true

        case .background:
            covered = true
            lastBackgroundDate = Date()

        @unknown default:
            covered = true
        }
    }

    private func unlock() async {
        authenticating = true
        unlockError = nil
        defer { authenticating = false }

        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Graceful fallback if biometrics / passcode is not configured or supported
            locked = false
            covered = false
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock pgAgent."
            )
            if success {
                locked = false
                covered = false
            } else {
                unlockError = "Authentication failed."
            }
        } catch {
            unlockError = error.localizedDescription
        }
    }
}
