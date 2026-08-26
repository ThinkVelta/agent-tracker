import AppKit
import SwiftUI

/// The `--render-preview` harness: rasterizes a chosen view to a PNG and exits,
/// so the UI can be inspected — and the README's images regenerated — without
/// clicking a menu bar.
///
/// Lives outside `AppDelegate` because it is a build-time tool rather than app
/// behaviour, and because it grows a branch every time a new picture is needed.
@MainActor
enum RenderPreview {
    /// Whether this process is a preview render rather than the real app.
    ///
    /// Exists so machine-specific state cannot leak into the committed docs
    /// images: the Accessibility banner reads `AXIsProcessTrusted()`, which for
    /// a freshly built binary depends on which terminal launched it and that
    /// machine's TCC grants — so the same fixture rendered on two machines
    /// would disagree about a warning no synthetic session ever caused.
    nonisolated static let isActive = CommandLine.arguments.contains("--render-preview")

    /// Debug utility:
    /// `AgentTracker --render-preview out.png [--filter needsYou] [--appearance dark]
    ///  [--view onboarding]`
    /// renders the dropdown (or the onboarding window) with live data to a PNG
    /// and exits — lets the UI be inspected/iterated without clicking the menu
    /// bar. Returns true when preview mode is active (the status item is
    /// skipped).
    ///
    /// Caveat worth knowing before trusting a preview: `ImageRenderer` does not
    /// rasterize AppKit-backed views, so `TextField` renders as a coloured
    /// placeholder bar and any `NSVisualEffectView` material is simply absent.
    /// Those need a real popover screenshot.
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--render-preview"),
            arguments.count > flagIndex + 1
        else { return false }
        let path = arguments[flagIndex + 1]
        var darkMode = false
        if let appearanceIndex = arguments.firstIndex(of: "--appearance") {
            // A typo silently rendering light mode would send someone hunting
            // for a dark-mode bug in a light-mode screenshot.
            let value =
                arguments.count > appearanceIndex + 1
                ? arguments[appearanceIndex + 1].lowercased() : ""
            switch value {
            case "dark": darkMode = true
            case "light": darkMode = false
            default:
                FileHandle.standardError.write(
                    Data("[preview] --appearance expects light or dark\n".utf8))
                exit(2)
            }
        }
        let appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        var view = "popover"
        if let viewIndex = arguments.firstIndex(of: "--view"), arguments.count > viewIndex + 1 {
            view = arguments[viewIndex + 1]
        }
        Task {
            let content = await Self.previewContent(
                named: view, arguments: arguments, darkMode: darkMode)
            let renderer = ImageRenderer(
                content:
                    content
                    .environment(\.colorScheme, darkMode ? .dark : .light)
                    // The real window's background is the system's; here there
                    // is none, so dark-mode text would render white on
                    // transparency and flatten to white-on-white. Hard-coded
                    // rather than semantic because dynamic NSColors do not
                    // resolve to the dark variant inside ImageRenderer.
                    .background(darkMode ? Color(white: 0.145) : Color(white: 0.98))
            )
            renderer.scale = 2
            var rendered: (data: Data, size: NSSize)?
            // Dynamic colors resolve against the current *drawing* appearance,
            // which ImageRenderer does not inherit from NSApp on its own.
            appearance?.performAsCurrentDrawingAppearance {
                if let image = renderer.nsImage,
                    let tiff = image.tiffRepresentation,
                    let rep = NSBitmapImageRep(data: tiff),
                    let png = rep.representation(using: .png, properties: [:])
                {
                    rendered = (png, image.size)
                }
            }
            // `try?` here used to swallow the write error and then log "wrote",
            // so a render into an unwritable path reported success and exited 0
            // — which let the docs-image script leave a stale PNG in place and
            // still go green.
            guard let rendered else {
                FileHandle.standardError.write(Data("[preview] render failed\n".utf8))
                exit(1)
            }
            do {
                try rendered.data.write(to: URL(fileURLWithPath: path))
            } catch {
                FileHandle.standardError.write(
                    Data("[preview] could not write \(path): \(error)\n".utf8))
                exit(1)
            }
            let size = "\(Int(rendered.size.width))x\(Int(rendered.size.height))"
            DebugLog.log("[preview] wrote \(path) (\(size) pt)")
            NSApp.terminate(nil)
        }
        return true
    }

    /// Builds the view a `--render-preview --view <name>` run should rasterize.
    /// Split out of `runRenderPreviewIfRequested` because every new preview
    /// added a branch there, and the function had grown past the complexity the
    /// linter allows.
    private static func previewContent(
        named view: String, arguments: [String], darkMode: Bool
    ) async -> AnyView {
        let content: AnyView
        switch view {
        case "onboarding":
            content = AnyView(OnboardingView())
        case "settings":
            content = AnyView(SettingsPreviewStack())
        case "shell":
            content = AnyView(BackgroundShellPanelPreviewStack())
        case "icons":
            content = AnyView(Image(nsImage: IconPreview.composite(darkMode: darkMode)))
        case "architecture":
            content = AnyView(ArchitecturePreview.diagram())
        case "menubar":
            // Just the status item, at whatever the loaded sessions add up
            // to — so the README's menu bar strip and its dropdown agree
            // about how many of each colour there are. A fixed sleep would
            // make that agreement a race: wait for the count to be both
            // non-zero and unchanged across two ticks, so a slow load
            // cannot be captured half-finished.
            let store = SessionStore()
            var settled = SessionCounts()
            for tick in 0..<40 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let current = store.counts
                // Equality settles it, including at zero — a genuinely
                // empty state is a legitimate thing to render. But not on
                // the first tick: a store that has not finished loading
                // also reads as zero, and the two are indistinguishable
                // from here. One tick of floor separates them.
                if tick > 0, current == settled { break }
                settled = current
            }
            content = AnyView(
                Image(nsImage: StatusIconRenderer.render(for: store.counts).image))
        case "popover":
            let store = SessionStore()
            if let filterIndex = arguments.firstIndex(of: "--filter"),
                arguments.count > filterIndex + 1,
                let state = SessionState(rawValue: arguments[filterIndex + 1])
            {
                store.selectedFilter = state
            }
            // Safe to write: under --render-preview the preferences live in an
            // isolated suite (see `AppDefaults`), so this cannot reach the
            // settings of whoever is regenerating the images.
            //
            // A bad value exits rather than falling back, like `--view` and
            // `--appearance`. Silently rendering the default would put the
            // wrong picture in the README and report success doing it, which is
            // the one failure this whole script is written to avoid.
            if let index = arguments.firstIndex(of: "--grouping") {
                let value = arguments.count > index + 1 ? arguments[index + 1] : ""
                guard let grouping = SessionSections.Grouping(rawValue: value) else {
                    FileHandle.standardError.write(
                        Data("[preview] --grouping expects state or project\n".utf8))
                    exit(2)
                }
                Preferences.shared.grouping = grouping
            }
            // The store reads its state files synchronously in `init`, so a
            // populated directory is already loaded here. One short wait
            // remains for the empty case, where a fixture may still be landing.
            for _ in 0..<4 where store.sessions.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            content = AnyView(MenuContentView(store: store))
        default:
            FileHandle.standardError.write(
                Data(
                    ("[preview] --view expects popover, onboarding, settings, editor, "
                        + "shell, icons, menubar or architecture\n").utf8))
            exit(2)
        }
        return content
    }
}
