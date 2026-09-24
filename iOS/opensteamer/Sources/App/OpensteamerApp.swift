import RemoteSessionCore
import SwiftUI

/// Compile-time switch that replaces the production root with a deliberately inert host for
/// install-over-update Keychain validation. Keeping the test host empty prevents normal startup
/// hydration from changing the credentials that the validation target is about to inspect.
enum OpensteamerAppRootMode {
    #if OPENSTEAMER_UPDATE_VALIDATION_HOST
    static let isPhysicalUpdateValidationHost = true
    #else
    static let isPhysicalUpdateValidationHost = false
    #endif
}

/// Application composition root for the iPhone viewer.
///
/// The production path creates each long-lived session owner exactly once and injects those
/// owners through SwiftUI's environment. The validation-host path intentionally skips all of
/// that work so its test bundle can observe persisted state before the app touches it.
@main
struct OpensteamerApp: App {
    #if OPENSTEAMER_UPDATE_VALIDATION_HOST
    // Application-hosted update tests must observe Keychain before production hydration runs.
    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
    }
    #else
    #if DEBUG
    private let debugLaunchRoot: DebugLaunchRoot

    init() {
        debugLaunchRoot = Self.resolveDebugLaunchRoot(
            arguments: ProcessInfo.processInfo.arguments,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            fileManager: .default
        )
    }
    #endif

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            switch debugLaunchRoot {
            case .inert:
                EmptyView()
            case .runtime(let developmentSecondaryInvitation):
                OpensteamerRuntimeRoot(
                    developmentSecondaryInvitation: developmentSecondaryInvitation
                )
            }
            #else
            OpensteamerRuntimeRoot()
            #endif
        }
    }

    #if DEBUG
    /// Resolves the development secret boundary before SwiftUI can construct any normal session,
    /// discovery, audio, Now Playing, or remote-input owner. A malformed or failed development
    /// request stays inert and therefore cannot accidentally fall through to ordinary startup.
    private static func resolveDebugLaunchRoot(
        arguments: [String],
        bundleIdentifier: String?,
        fileManager: FileManager
    ) -> DebugLaunchRoot {
        let request = IPhone15DevelopmentSecondarySecretBoundary.launchRequest(
            arguments: arguments,
            bundleIdentifier: bundleIdentifier
        )
        switch request {
        case .ordinary:
            return .runtime(developmentSecondaryInvitation: nil)
        case .invalidDevelopmentRequest:
            return .inert
        case .cleanup, .viewer:
            guard let documentsDirectory = fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first else {
                return .inert
            }
            let keychainStore = KeychainStore(
                item: KeychainStore.worldwideInvitationCodeItem
            )
            guard let outcome = try? IPhone15DevelopmentSecondarySecretBoundary.perform(
                request: request,
                documentsDirectory: documentsDirectory,
                keychainStore: keychainStore,
                fileManager: fileManager
            ) else {
                return .inert
            }
            switch request {
            case .cleanup:
                return .inert
            case .viewer:
                guard let invitation = outcome.invitation else { return .inert }
                return .runtime(developmentSecondaryInvitation: invitation)
            case .ordinary, .invalidDevelopmentRequest:
                return .inert
            }
        }
    }

    private enum DebugLaunchRoot {
        case inert
        case runtime(developmentSecondaryInvitation: String?)
    }
    #endif
    #endif
}

#if !OPENSTEAMER_UPDATE_VALIDATION_HOST
/// Owns the ordinary iPhone runtime. Keeping every long-lived owner below `OpensteamerApp` lets
/// the DEBUG cleanup root remain truly inert rather than constructing owners behind an empty view.
private struct OpensteamerRuntimeRoot: View {
    @StateObject private var viewModel = StreamSessionViewModel()
    @StateObject private var worldwideViewModel = WorldwideSessionViewModel()
    @StateObject private var worldwideConnection: WorldwideViewerConnectionCoordinator
    private let developmentSecondaryInvitation: String?

    init(developmentSecondaryInvitation: String? = nil) {
        self.developmentSecondaryInvitation = developmentSecondaryInvitation
        let telemetry = LocalConnectionTelemetryJournal.applicationSupport(
            component: "ios-viewer"
        )
        _worldwideConnection = StateObject(
            wrappedValue: WorldwideViewerConnectionCoordinator(
                connectionTelemetry: telemetry
            )
        )
    }

    @ViewBuilder
    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains(
            "--opensteamer-ui-test-fullscreen-viewer"
        ) {
            FullscreenViewerSimulatorFixtureView()
        } else {
            contentView
        }
        #else
        contentView
        #endif
    }

    @ViewBuilder
    private var contentView: some View {
        #if DEBUG
        ContentView()
            .environmentObject(viewModel)
            .environmentObject(worldwideViewModel)
            .environmentObject(worldwideConnection)
            .environment(
                \.iPhone15DevelopmentSecondaryInvitation,
                developmentSecondaryInvitation
            )
        #else
        ContentView()
            .environmentObject(viewModel)
            .environmentObject(worldwideViewModel)
            .environmentObject(worldwideConnection)
        #endif
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
/// Deterministic Simulator-only surface for verifying the production full-screen viewer shell.
/// Release/TestFlight builds compile this route out completely.
private struct FullscreenViewerSimulatorFixtureView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isViewerPresented = true

    var body: some View {
        if isViewerPresented {
            FullscreenViewerLayout {
                ZStack {
                    LinearGradient(
                        colors: [.indigo, .cyan, .mint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.inset.filled")
                            .font(.system(size: 64))
                        Text("Remote Screen")
                            .font(.title.bold())
                    }
                    .foregroundStyle(.white)
                }
                .accessibilityElement()
                .accessibilityLabel("Full-screen remote display")
                .accessibilityIdentifier("fullscreenRemoteScreenSurface")
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase != .active else { return }
                isViewerPresented = false
            }
        } else {
            ZStack {
                ContentUnavailableView(
                    "Viewer Closed",
                    systemImage: "checkmark.circle",
                    description: Text("Returned without visible viewer controls.")
                )

                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel("Viewer dismissed")
                    .accessibilityIdentifier("fullscreenViewerDismissed")
            }
        }
    }
}
#endif
