import SwiftUI
import AVFoundation

// Uncomment after adding firebase-ios-sdk and GoogleService-Info.plist:
// import FirebaseCore

@main
struct SecurityCamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// MARK: - Root

/// Manages top-level mode selection. Each mode is presented as a full-screen cover
/// so the mode picker is always the base and dismissing either cover returns here.
/// On first launch, the onboarding walkthrough is shown instead.
struct RootView: View {
    @StateObject private var settings = SettingsModel()
    @State private var showCamera = false
    @State private var showViewer = false
    @State private var showLive   = false
    @State private var showIPCam  = false

    /// Set to true after the user completes (or dismisses) the onboarding flow.
    /// Persisted across launches so the walkthrough only shows once.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    /// Persisted so that if iOS kills the app in background while recording,
    /// the next launch goes straight back to the camera screen and starts
    /// recording automatically — no mode-selection tap required.
    @AppStorage("wasInCameraMode") private var wasInCameraMode = false

    var body: some View {
        ModeSelectionView(
            settings: settings,
            onCameraTapped: { showCamera = true },
            onViewerTapped: { showViewer = true },
            onLiveTapped:   { showLive   = true },
            onIPCamTapped:  { showIPCam  = true }
        )
        .fullScreenCover(isPresented: $showCamera) {
            ContentView(settings: settings)
        }
        .fullScreenCover(isPresented: $showViewer) {
            VideoBrowserView(settings: settings)
        }
        .fullScreenCover(isPresented: $showLive) {
            LiveStreamView()
        }
        .fullScreenCover(isPresented: $showIPCam) {
            MultiCamDashboardView(settings: settings)
        }
        // Onboarding — shown on first launch only.
        // interactiveDismissDisabled prevents accidental swipe-down.
        .fullScreenCover(
            isPresented: Binding(
                get:  { !hasCompletedOnboarding },
                set:  { isShowing in if !isShowing { hasCompletedOnboarding = true } }
            )
        ) {
            OnboardingView(settings: settings) {
                hasCompletedOnboarding = true
            }
            .interactiveDismissDisabled(true)
        }
        .onAppear {
            // If the app was killed mid-session, jump straight back to the
            // camera without forcing the user through mode selection.
            if hasCompletedOnboarding && wasInCameraMode {
                showCamera = true
            }
        }
        .onChange(of: showCamera) { newValue in
            wasInCameraMode = newValue
        }
    }
}

// MARK: - App delegate

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Uncomment after Firebase setup:
        // FirebaseApp.configure()
        return true
    }
}
