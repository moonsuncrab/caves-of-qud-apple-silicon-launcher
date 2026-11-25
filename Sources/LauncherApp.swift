import AppKit
import Foundation
import SwiftUI

@MainActor
final class LauncherModel: ObservableObject {
    @Published var status = "Ready to prepare the private game copy."
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var copyExistingData = true
    @Published var profileInitialized: Bool
    @Published var existingDataAvailable: Bool
    @Published var steamStatus = "Steam connection will be checked at launch"
    @Published var workshopStatus = "Subscriptions load through Steam"
    @Published var petsStatus = "DLC files will be checked at launch"
    @Published var activity: [String] = []

    private let supportDirectory: URL
    private let defaultDataDirectory: URL
    private var process: Process?
    private var readHandle: FileHandle?
    private var gameLogPoller: Timer?
    private var gameLogOffset: UInt64 = 0
    private var pendingOutput = ""

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportDirectory = appSupport.appendingPathComponent("Caves of Qud Apple Silicon Launcher", isDirectory: true)
        defaultDataDirectory = appSupport.appendingPathComponent("com.FreeholdGames.CavesOfQud", isDirectory: true)
        profileInitialized = FileManager.default.fileExists(
            atPath: supportDirectory.appendingPathComponent("profile-initialized").path
        )
        existingDataAvailable = FileManager.default.fileExists(atPath: defaultDataDirectory.path)
    }

    var logURL: URL {
        supportDirectory.appendingPathComponent("launcher.log")
    }

    var needsProfileChoice: Bool {
        !profileInitialized && existingDataAvailable
    }

    func launch() {
        guard !isRunning else { return }
        guard let helperURL = Bundle.main.url(forResource: "QudLaunchHelper", withExtension: "command") else {
            errorMessage = "The launch helper is missing from this app. Re-download the launcher package."
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        var arguments = [helperURL.path, "--gui"]
        if !profileInitialized {
            arguments.append(copyExistingData ? "--copy-profile" : "--skip-profile-copy")
        } else {
            arguments.append("--skip-profile-copy")
        }
        task.arguments = arguments

        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        task.standardInput = FileHandle.nullDevice
        readHandle = output.fileHandleForReading
        prepareGameLogMonitor()
        readHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.receive(chunk)
            }
        }
        task.terminationHandler = { [weak self] finishedTask in
            let exitCode = finishedTask.terminationStatus
            Task { @MainActor [weak self] in
                self?.finish(exitCode: exitCode)
            }
        }

        errorMessage = nil
        activity.removeAll()
        status = "Checking Steam and preparing the private copy…"
        isRunning = true
        do {
            try task.run()
            process = task
            startGameLogMonitor()
        } catch {
            isRunning = false
            process = nil
            gameLogPoller?.invalidate()
            gameLogPoller = nil
            errorMessage = "Couldn't start the launcher helper: \(error.localizedDescription)"
            status = "Launch failed"
        }
    }

    private func receive(_ text: String) {
        pendingOutput += text
        while let newline = pendingOutput.firstIndex(of: "\n") {
            let line = String(pendingOutput[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            pendingOutput = String(pendingOutput[pendingOutput.index(after: newline)...])
            consume(line)
        }
    }

    private func consume(_ line: String) {
        if line.contains("[Qud Apple Silicon Launcher]") {
            let message = line.components(separatedBy: "[Qud Apple Silicon Launcher]").last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? line
            status = message
            appendActivity(message)
            if message.contains("Pets of Harvest Dawn files are present") {
                petsStatus = "Files found and copied into the private game folder"
            } else if message.contains("Pets of Harvest Dawn files were not found") {
                petsStatus = "Not found in the Steam installation"
            } else if message.contains("Game log confirms Pets of Harvest Dawn entitlement") {
                petsStatus = "Steam confirmed the Pets of Harvest Dawn entitlement"
            } else if message.contains("Game log reports no Pets of Harvest Dawn entitlement") {
                petsStatus = "Steam did not report the Pets of Harvest Dawn entitlement"
            }
            if message.contains("Game log confirms the Steam API connected") {
                steamStatus = "Steam API connected"
            }
            if message.contains("Game log confirms it scanned the private DLC data folder") {
                petsStatus = "Steam entitlement confirmed; private DLC folder scanned"
            }
            if message.contains("Steam must be open") {
                workshopStatus = "Steam Workshop will provide your subscriptions"
            }
        }

        if line.contains("SteamAPI_Init(): Loaded") {
            steamStatus = "Steam API connected"
            appendActivity("Steam API connected.")
        } else if line.contains("INFO - has Pets Pack 1") {
            petsStatus = "Steam confirmed the Pets of Harvest Dawn entitlement"
            appendActivity("Steam confirmed Pets of Harvest Dawn.")
        } else if line.contains("INFO - does not have Pets Pack 1") {
            petsStatus = "Steam did not report the Pets of Harvest Dawn entitlement"
            appendActivity("Steam did not report the Pets of Harvest Dawn entitlement.")
        } else if line.contains("RefreshModDirectory") && line.contains("/CoQ_Data/StreamingAssets/DLC") {
            petsStatus = "Private DLC folder scanned; waiting for Steam entitlement check"
            appendActivity("The game scanned the private DLC data folder.")
        } else if line.contains("Subscribed workshop items:") {
            let count = line.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let value = Int(count) {
                workshopStatus = "Steam reports \(value) subscribed Workshop item(s)"
                appendActivity("Steam reports \(value) subscribed Workshop item(s).")
            }
        }

        if line.contains("ERROR:") {
            appendActivity(line)
        }
    }

    private func prepareGameLogMonitor() {
        let gameLog = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Freehold Games/CavesOfQud/Player.log")
        let size = (try? FileManager.default.attributesOfItem(atPath: gameLog.path)[.size] as? NSNumber)?.uint64Value ?? 0
        gameLogOffset = UInt64(size)
    }

    private func startGameLogMonitor() {
        gameLogPoller?.invalidate()
        gameLogPoller = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollGameLog() }
        }
        pollGameLog()
    }

    private func pollGameLog() {
        let gameLog = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Freehold Games/CavesOfQud/Player.log")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: gameLog.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else { return }
        if fileSize < gameLogOffset { gameLogOffset = 0 }
        guard let handle = try? FileHandle(forReadingFrom: gameLog) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: gameLogOffset)
            let data = try handle.readToEnd() ?? Data()
            gameLogOffset += UInt64(data.count)
            if !data.isEmpty {
                receive(String(decoding: data, as: UTF8.self))
            }
        } catch {
            appendActivity("Couldn't read the live game log: \(error.localizedDescription)")
        }
    }

    private func appendActivity(_ line: String) {
        guard !line.isEmpty else { return }
        activity.append(line)
        if activity.count > 80 {
            activity.removeFirst(activity.count - 80)
        }
    }

    private func finish(exitCode: Int32) {
        gameLogPoller?.invalidate()
        gameLogPoller = nil
        pollGameLog()
        isRunning = false
        process = nil
        readHandle?.readabilityHandler = nil
        readHandle = nil
        profileInitialized = FileManager.default.fileExists(
            atPath: supportDirectory.appendingPathComponent("profile-initialized").path
        )
        if exitCode == 0 {
            status = "Caves of Qud closed. Your normal Steam install is unchanged."
        } else {
            errorMessage = "The launcher stopped with exit code \(exitCode). Open the activity log for details."
            status = "Launch failed"
        }
    }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                compatibilityCard
                statusCards
                profileCard
                launchButton
                activityDisclosure
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 680, minHeight: 420, idealHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text("Caves of Qud")
                    .font(.system(size: 24, weight: .bold))
                Text("Apple Silicon mod launcher")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Private copy", systemImage: "checkmark.shield.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
        }
    }

    private var compatibilityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Verified game build", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                Spacer()
                Text("Steam build 26370970")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("Caves of Qud 1.0.5 · build 2.0.211.57")
                .font(.title3.weight(.semibold))
            Text("The launcher checks the installed Steam build before it makes a private copy. It never patches the game Steam launches normally.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusCards: some View {
        HStack(alignment: .top, spacing: 12) {
            statusCard("Steam", detail: model.steamStatus, icon: "steam")
            statusCard("Workshop", detail: model.workshopStatus, icon: "square.stack.3d.up")
            statusCard("Pets of Harvest Dawn", detail: model.petsStatus, icon: "pawprint")
        }
    }

    private func statusCard(_ title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Separate save profile", systemImage: "externaldrive.fill")
                .font(.headline)
            if model.needsProfileChoice {
                Toggle("Copy my existing saves and settings once", isOn: $model.copyExistingData)
                    .toggleStyle(.checkbox)
                Text("This copies your current data and leaves the Steam files in place. Future saves in the modded profile are separate and will not sync through Steam Cloud.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.profileInitialized {
                Text("Your separate profile is already set up. The launcher keeps it separate from the normal Steam game.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No existing game-data folder was found, so the launcher will start a fresh profile.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var launchButton: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: model.launch) {
                HStack(spacing: 9) {
                    if model.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(model.isRunning ? "Preparing and launching…" : "Prepare and launch modded copy")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isRunning)

            Text(model.status)
                .font(.callout)
                .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var activityDisclosure: some View {
        DisclosureGroup("Activity details") {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if model.activity.isEmpty {
                        Text("The launcher will show Steam, Workshop, DLC, and copy progress here.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.activity.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            .frame(height: 110)
        }
        .font(.subheadline.weight(.medium))
    }

    private var footer: some View {
        HStack {
            Text("Keep Steam open and signed in so Workshop and DLC can connect.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open full log") {
                NSWorkspace.shared.open(model.logURL)
            }
            .buttonStyle(.link)
        }
    }
}

@main
struct QudAppleSiliconLauncherApp: App {
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        WindowGroup {
            LauncherView(model: model)
        }
        .windowResizability(.contentSize)
    }
}
