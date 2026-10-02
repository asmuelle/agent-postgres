import SwiftUI
import LocalAuthentication

/// One window's privacy: a cover while the window isn't in front (so the
/// app switcher never shows data), and the app-wide lock (`MobileAppLock`)
/// with its Face ID / passcode unlock.
struct MobilePrivacyGateView<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var covered = false
    @State private var authenticating = false
    @State private var unlockError: String?

    private let lock = MobileAppLock.shared
    private let content: Content

    private var locked: Bool { lock.isLocked }

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

    /// Covers this window while it isn't in front. Locking is app-wide and
    /// driven by PgAgentMobileApp, not by any one window.
    private func handleScenePhase(_ newPhase: ScenePhase) {
        covered = newPhase != .active
    }

    private func unlock() async {
        authenticating = true
        unlockError = nil
        defer { authenticating = false }

        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Graceful fallback if biometrics / passcode is not configured or supported
            lock.unlock()
            covered = false
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock pgAgent."
            )
            if success {
                lock.unlock()
                covered = false
            } else {
                unlockError = "Authentication failed."
            }
        } catch {
            unlockError = error.localizedDescription
        }
    }
}
