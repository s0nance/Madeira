//
//  LauncherView.swift
//  Madeira
//
//  Pick any executable and run it, instead of needing a hardcoded button.
//
//  Every launch target used to be a Button in ContentView with its path
//  written into the closure, so running anything else meant a rebuild --
//  or a disguise. dxchkmsaa-x64.exe was tested by copying it over
//  C:\Program Files\Thumper\THUMPER_win10.exe so the Thumper button would
//  pick it up, which says everything about the affordance. texquad.exe and
//  heap-x64.exe ship in the bundle and had no way to be launched at all.
//
//  This view only DISCOVERS and DESCRIBES. Turning a choice into
//  MADEIRA_EXE/MADEIRA_ARGS/MADEIRA_DESKTOP and calling the Wine sequence
//  stays in ContentView, where that knowledge already lives, so nothing
//  here can get out of step with how the launch path actually works.
//

import SwiftUI

/// What the launcher hands back. Mirrors the env vars the launch path reads;
/// see WineProcessBridge.m's MADEIRA_EXE handling for the path rules.
struct LaunchSpec: Equatable {
    /// Either a bare name ("cube-x64.exe"), which WineProcessBridge resolves
    /// under C:\windows\system32, or a full path ("C:\\Program Files\\...").
    /// That branch is decided by the presence of a backslash or a drive
    /// letter, so a bare name must NOT be turned into a path here.
    var exe: String
    var args: String = ""
    var desktop: Bool = false
    var width: Int = 1024
    var height: Int = 768
}

/// One launchable executable, with enough about it to choose sensibly.
struct LaunchTarget: Identifiable, Hashable {
    enum Origin: String {
        case bundle = "bundle"   // shipped in the app, reached as a bare name
        case prefix = "prefix"   // inside drive_c, reached as a C:\ path
    }
    var id: String { exe }
    /// The string to put in MADEIRA_EXE.
    let exe: String
    /// What to show: the file name, plus its directory for prefix entries.
    let label: String
    let detail: String
    let origin: Origin
    /// PE machine word, so an x86-64 target (the emulated path) is
    /// distinguishable at a glance from a native aarch64 one. This is the
    /// whole point of the project, and a list that hid it would be useless.
    let machine: String
    let isConsole: Bool
    /// ml807: whether this can run here at all, decided from the machine word.
    ///
    /// A 32-bit image cannot: wow64 needs the guest in the low 2GB and iOS
    /// hands out no address space below 4GB, so there is no device, prefix or
    /// setting that makes one work. ntdll refuses it in NtCreateUserProcess
    /// (ml805) and the refusal is correct, but the dialog explorer then puts up
    /// says "Invalid handle" -- explorer and shell32 are prebuilt PE binaries
    /// here, so that string is not reachable without rebuilding them for two
    /// architectures. The useful place to say it is before Wine is involved at
    /// all, in the one list the user actually reads.
    var runnable: Bool { machine != "x86" && machine != "arm32" }
    /// Why not, in the row's own words.
    var unrunnableReason: String {
        machine == "x86" ? "32-bit — iOS has no address space below 4GB"
                         : "32-bit ARM — not an architecture this can emulate"
    }
}

/// Reads the PE header far enough to name the architecture and subsystem.
/// Cheap: one small read, no mapping. Returns nil when the file is not a PE.
private func peInfo(at url: URL) -> (machine: String, console: Bool)? {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? fh.close() }
    guard let head = try? fh.read(upToCount: 0x40), head.count == 0x40,
          head[0] == 0x4d, head[1] == 0x5a else { return nil }   // "MZ"
    let lfanew = head.withUnsafeBytes { $0.load(fromByteOffset: 0x3c, as: UInt32.self) }
    guard lfanew > 0, lfanew < 0x1000 else { return nil }
    try? fh.seek(toOffset: UInt64(lfanew))
    // PE signature (4) + COFF header (20) + optional header up to Subsystem.
    guard let coff = try? fh.read(upToCount: 0x60), coff.count >= 0x5e else { return nil }
    guard coff[0] == 0x50, coff[1] == 0x45 else { return nil }    // "PE"
    let machine = coff.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }
    // Subsystem sits at optional-header offset 68; the optional header starts
    // at signature+20 = 24. 3 = console, 2 = GUI.
    let subsystem = coff.withUnsafeBytes { $0.load(fromByteOffset: 24 + 68, as: UInt16.self) }
    let name: String
    switch machine {
    case 0x8664: name = "x86-64"     // the emulated path, through FEX
    case 0xaa64: name = "arm64"      // native, or ARM64EC — the header alone
                                     // cannot tell those apart, and saying
                                     // "arm64ec" here would be a guess
    case 0x01c0, 0x01c4: name = "arm32"
    case 0x014c: name = "x86"
    default: name = String(format: "0x%04x", machine)
    }
    return (name, subsystem == 3)
}

enum LauncherScan {
    /// Executables shipped in the app. These are reached as BARE NAMES,
    /// because the prefix symlinks the bundle's PE directories into
    /// C:\windows\system32 -- which is also why a bundle entry and a prefix
    /// entry can name the same file and both be correct.
    static func bundleTargets() -> [LaunchTarget] {
        guard let res = Bundle.main.resourceURL else { return [] }
        var out: [LaunchTarget] = []
        for dir in ["arm64ec-windows", "aarch64-windows"] {
            let d = res.appendingPathComponent(dir)
            let items = (try? FileManager.default.contentsOfDirectory(
                at: d, includingPropertiesForKeys: nil)) ?? []
            for u in items where u.pathExtension.lowercased() == "exe" {
                let info = peInfo(at: u)
                out.append(LaunchTarget(exe: u.lastPathComponent,
                                        label: u.lastPathComponent,
                                        detail: dir,
                                        origin: .bundle,
                                        machine: info?.machine ?? "?",
                                        isConsole: info?.console ?? false))
            }
        }
        // Same name in both PE directories resolves to one system32 entry, so
        // showing it twice would offer a choice that does not exist.
        var seen = Set<String>()
        return out.filter { seen.insert($0.exe).inserted }
    }

    /// Executables inside the prefix, as C:\ paths.
    ///
    /// Depth- and count-capped on purpose: a real game directory holds
    /// thousands of files, and an uncapped recursive scan on the main actor
    /// would stall the UI for seconds on exactly the prefixes people care
    /// about. Runs off the main thread; see `load`.
    static func prefixTargets(maxDepth: Int = 6, limit: Int = 400,
                              knownBundleNames: Set<String> = []) -> [LaunchTarget] {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return [] }
        // resolvingSymlinksInPath on BOTH sides, and a component-wise relative
        // path below rather than string surgery. FileManager hands back
        // /var/mobile/... while enumeration yields /private/var/mobile/...,
        // and /var is a symlink to /private/var. Trimming "root.path + /" as a
        // substring then matched in the MIDDLE of the child path and left the
        // leading /private in place, producing
        // C:\\privatewindows\sysx64\dxchkmsaa-x64.exe -- which Wine duly
        // failed to open, with exit code 0xc0000135.
        let root = docs.appendingPathComponent("wine/drive_c").resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let rootDepth = root.pathComponents.count

        var out: [LaunchTarget] = []
        var queue: [(URL, Int)] = [(root, 0)]
        while !queue.isEmpty, out.count < limit {
            let (dir, depth) = queue.removeFirst()
            if depth > maxDepth { continue }
            let items = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for u in items {
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    // These are walls of symlinks to the bundle's PE
                    // directories, already listed as bare names: sysx64 for
                    // x86-64 and sysaa64 for aarch64, beside the usual
                    // system32. Descending would bury the interesting entries
                    // under ~130 duplicates. The list is a cheap first cut
                    // only -- the real de-duplication is by FILE NAME below,
                    // which survives these directories being renamed again.
                    let lower = u.lastPathComponent.lowercased()
                    if ["system32", "syswow64", "sysx64", "sysaa64"].contains(lower) { continue }
                    queue.append((u, depth + 1))
                } else if u.pathExtension.lowercased() == "exe", out.count < limit {
                    // Already offered as a bare name by bundleTargets(), and
                    // the bare form is the one the launch path resolves in
                    // system32, so listing the prefix copy would be a choice
                    // between two spellings of the same thing.
                    if knownBundleNames.contains(u.lastPathComponent) { continue }
                    let rel = u.resolvingSymlinksInPath().pathComponents
                        .dropFirst(rootDepth).joined(separator: "\\")
                    guard !rel.isEmpty else { continue }
                    let info = peInfo(at: u)
                    out.append(LaunchTarget(
                        exe: "C:\\" + rel,
                        label: u.lastPathComponent,
                        detail: (rel.replacingOccurrences(of: "\\", with: "/") as NSString)
                            .deletingLastPathComponent,
                        origin: .prefix,
                        machine: info?.machine ?? "?",
                        isConsole: info?.console ?? false))
                }
            }
        }
        return out
    }
}

struct LauncherView: View {
    /// Called with the chosen spec. The caller owns the env vars and the
    /// Wine sequence; this view never touches either.
    let onLaunch: (LaunchSpec) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var targets: [LaunchTarget] = []
    @State private var scanning = true
    @State private var query = ""
    @State private var selected: LaunchTarget?
    @State private var args = ""
    @State private var desktop = false
    @State private var deskW = "1024"
    @State private var deskH = "768"

    /// Last few launches, so re-running one is a tap. Args and desktop mode
    /// are remembered with the path: an executable that needs -dx11 or a
    /// virtual desktop needs them every time, and retyping them was half the
    /// friction the hardcoded buttons existed to avoid.
    @AppStorage("madeira.launcher.recent") private var recentJSON = "[]"

    private var filtered: [LaunchTarget] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return targets }
        return targets.filter {
            $0.label.lowercased().contains(q) || $0.detail.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !recent.isEmpty && query.isEmpty {
                    Section("Recent") {
                        ForEach(recent, id: \.exe) { spec in
                            Button { launch(spec) } label: { recentRow(spec) }
                        }
                    }
                }
                Section(scanning ? "Scanning…" : "\(filtered.count) executable(s)") {
                    if scanning {
                        HStack { ProgressView(); Text("Reading the prefix").foregroundStyle(.secondary) }
                    }
                    ForEach(filtered) { t in
                        HStack(spacing: 0) {
                            // One tap launches. Most of these are test
                            // binaries with no arguments, and the first
                            // version made every launch cost three taps
                            // through a second, NESTED sheet -- a shape that
                            // is easy to leave by the wrong exit, which is
                            // the likeliest reason a launch was reported as
                            // done with no launcher: line in the log.
                            Button { launch(spec(for: t)) } label: {
                                targetRow(t).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // ml807: an entry that cannot run is not tappable.
                            // Letting it through only reaches ntdll's refusal
                            // and then a dialog from a prebuilt explorer that
                            // says "Invalid handle" -- the row already says the
                            // real reason, so the tap has nothing to add.
                            .disabled(!t.runnable)
                            Button { choose(t) } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 10)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Arguments and desktop for \(t.label)")
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Name or folder")
            .navigationTitle("Run a program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            // Pushed, not presented. A sheet on top of a sheet is what made
            // "choose" and "launch" easy to confuse.
            .navigationDestination(item: $selected) { t in optionsSheet(for: t) }
        }
        .task {
            // Off the main actor: the prefix walk touches the filesystem and a
            // populated drive_c makes it slow enough to be visible.
            let found = await Task.detached(priority: .userInitiated) {
                let bundle = LauncherScan.bundleTargets()
                let names = Set(bundle.map(\.exe))
                return bundle + LauncherScan.prefixTargets(knownBundleNames: names)
            }.value
            targets = found.sorted {
                $0.origin == $1.origin ? $0.label.lowercased() < $1.label.lowercased()
                                       : $0.origin == .prefix
            }
            scanning = false
        }
    }

    private func targetRow(_ t: LaunchTarget) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.label).font(.subheadline)
                    .foregroundStyle(t.runnable ? .primary : .secondary)
                // ml807: the reason replaces the path for an entry that cannot
                // run. The path is only useful to someone about to launch it.
                Text(t.runnable ? (t.detail.isEmpty ? t.origin.rawValue : t.detail)
                                : t.unrunnableReason)
                    .font(.caption2)
                    .foregroundStyle(t.runnable ? Color.secondary : Color.orange)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text(t.machine)
                .font(.caption2.monospaced())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(!t.runnable ? Color.orange.opacity(0.18)
                                                       : t.machine == "x86-64" ? Color.orange.opacity(0.25)
                                                                               : Color.secondary.opacity(0.15)))
            if t.isConsole {
                Image(systemName: "text.alignleft").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func recentRow(_ s: LaunchSpec) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((s.exe as NSString).lastPathComponent).font(.subheadline)
            Text([s.args.isEmpty ? nil : s.args,
                  s.desktop ? "desktop \(s.width)x\(s.height)" : nil]
                    .compactMap { $0 }.joined(separator: "  ·  "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func optionsSheet(for t: LaunchTarget) -> some View {
        Group {
            Form {
                Section("Executable") {
                    Text(t.exe).font(.caption.monospaced()).textSelection(.enabled)
                    LabeledContent("Architecture", value: t.machine)
                    LabeledContent("Subsystem", value: t.isConsole ? "console" : "GUI")
                    if t.isConsole {
                        Text("Console output goes to the log, not to a window.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Section("Arguments") {
                    TextField("none", text: $args)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    Text("Space-separated, at most 16 tokens.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("Virtual desktop") {
                    Toggle("Run under a desktop", isOn: $desktop)
                    if desktop {
                        HStack {
                            TextField("width", text: $deskW).keyboardType(.numberPad)
                            Text("×").foregroundStyle(.secondary)
                            TextField("height", text: $deskH).keyboardType(.numberPad)
                        }
                        Text("Needed by anything expecting a window manager.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Launch") {
                        launch(LaunchSpec(exe: t.exe, args: args, desktop: desktop,
                                          width: Int(deskW) ?? 1024,
                                          height: Int(deskH) ?? 768))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle(t.label)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// What a one-tap launch uses: whatever this executable was last run
    /// with, so a program needing -dx11 keeps it, and nothing otherwise.
    private func spec(for t: LaunchTarget) -> LaunchSpec {
        recent.first { $0.exe == t.exe } ?? LaunchSpec(exe: t.exe)
    }

    private func choose(_ t: LaunchTarget) {
        // Prefill from the last run of this same executable, if any.
        if let prev = recent.first(where: { $0.exe == t.exe }) {
            args = prev.args; desktop = prev.desktop
            deskW = String(prev.width); deskH = String(prev.height)
        } else {
            args = ""; desktop = false; deskW = "1024"; deskH = "768"
        }
        selected = t
    }

    private func launch(_ spec: LaunchSpec) {
        remember(spec)
        selected = nil
        dismiss()
        onLaunch(spec)
    }

    // MARK: recent list, stored as JSON in UserDefaults

    private var recent: [LaunchSpec] {
        (try? JSONDecoder().decode([StoredSpec].self,
                                   from: Data(recentJSON.utf8)))?.map(\.spec) ?? []
    }

    private func remember(_ spec: LaunchSpec) {
        var list = recent.filter { $0.exe != spec.exe }
        list.insert(spec, at: 0)
        list = Array(list.prefix(8))
        if let d = try? JSONEncoder().encode(list.map(StoredSpec.init)) {
            recentJSON = String(decoding: d, as: UTF8.self)
        }
    }

    /// LaunchSpec is deliberately not Codable itself: the stored shape is a
    /// persistence detail and should be free to lag behind the runtime type.
    private struct StoredSpec: Codable {
        var exe: String, args: String, desktop: Bool, width: Int, height: Int
        init(_ s: LaunchSpec) {
            exe = s.exe; args = s.args; desktop = s.desktop
            width = s.width; height = s.height
        }
        var spec: LaunchSpec {
            LaunchSpec(exe: exe, args: args, desktop: desktop, width: width, height: height)
        }
    }
}

extension LaunchTarget: Equatable {
    static func == (a: LaunchTarget, b: LaunchTarget) -> Bool { a.exe == b.exe }
}
