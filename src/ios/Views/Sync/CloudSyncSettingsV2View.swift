import SwiftUI

/// V2 iCloud Sync settings page. Replaced the retired v1 CloudSyncSettingsView
/// (deleted 10-21 along with its remote-device browsing views). Drives:
/// - Master enable/disable
/// - This device's friendly name
/// - Per-category upload toggles (Chat / SessionFiles / Skills / Providers / Env)
/// - Per-file size cap
/// - Discovered remote devices (read from sync_devices table populated
///   by mergeDevice hydrator on inbound SyncDeviceV2 records)
struct CloudSyncSettingsV2View: View {
    @State private var v2Enabled: Bool = false
    @State private var deviceName: String = ""
    @State private var deviceNameDraft: String = ""
    @State private var showDeviceNameEditor: Bool = false
    @State private var categoriesEnabled: [UploadPolicy.Category: Bool] = [:]
    @State private var maxFileSizeMB: Int = 1
    @State private var remoteDevices: [SyncDevice] = []
    @State private var statusText: String = ""
    @State private var icloudBlockedNotice: String = ""
    // [T-sync-recovery-v1-parity] State for the two repair actions.
    @State private var isResyncing = false
    @State private var isDeletingCloud = false
    @State private var showDeleteCloudStep1 = false
    @State private var deleteCloudResult: String?
    // [T-ios-migration-timer-sessionlist-uaf-crash] 5s refresh cadence is driven by
    // a `.task` async loop (see refreshLoop), NOT a process-lived
    // `Timer.publish(every:5).autoconnect()` + `.onReceive`. A graph-bound Combine
    // publisher's sink is a SwiftUI attribute AttributeGraph re-creates on every body
    // transaction; a tick delivered while it is torn down/rebuilt releases the dangling
    // `SubscriptionView` sink closure → use-after-free (CODESIGNING Invalid Page,
    // TestFlight crash1/crash2, 1.10(43)). Same mechanism 665c15fb fixed in ContentView;
    // that commit converted only the ContentView binding point, leaving this view and
    // SyncMigrationDetailView on the crashing pattern.
    private static let refreshIntervalSeconds: UInt64 = 5

    var body: some View {
        Form {
            Section {
                if !ICloudSharedZoneTransport.hasCloneICloudEntitlement() {
                    // [T-icloud-resign-silent-toggle] The guard inside the
                    // setter below only fires after the user tries the switch,
                    // so the first thing they saw was a switch that refused to
                    // move and a note that appeared out of nowhere. Say it
                    // before they touch anything: there is no build of this
                    // app on this device that can sync.
                    VStack(alignment: .leading, spacing: 6) {
                        Label("iCloud Sync isn't available in this build",
                              systemImage: "exclamationmark.icloud")
                            .font(.footnote.weight(.medium))
                        Text("This copy was re-signed, so it can't reach the app's iCloud container. Syncing works only in a build signed with the original iCloud entitlement. Everything else works normally, and your data stays on this device.")
                            .font(.caption)
                            .foregroundStyle(MinisTheme.secondaryText)
                    }
                } else {
                    Toggle(isOn: Binding(
                        get: { v2Enabled },
                        set: { newValue in
                            if #available(iOS 17.0, *) {
                                // [T-icloud-resign-entitlement-crash] Re-signed
                                // builds may lack the iCloud container entitlement;
                                // enabling sync would NSException on the first
                                // CKContainer and then again on every launch.
                                // Refuse up front instead of probing-and-crashing.
                                if newValue, !ICloudSharedZoneTransport.hasCloneICloudEntitlement() {
                                    v2Enabled = false
                                    icloudBlockedNotice = "iCloud sync is unavailable on this re-signed build — its signature has no CloudKit container entitlement."
                                    return
                                }
                                icloudBlockedNotice = ""
                                SyncV2Bootstrap.setEnabled(newValue)
                            }
                            v2Enabled = newValue
                        }
                    )) {
                        Text("Enable iCloud Sync")
                    }
                }
                if !icloudBlockedNotice.isEmpty {
                    Text(icloudBlockedNotice)
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                }
                if !statusText.isEmpty {
                    NavigationLink {
                        SyncMigrationDetailView()
                    } label: {
                        LabeledContent("Status") {
                            Text(statusText).foregroundStyle(MinisTheme.secondaryText)
                        }
                    }
                }
            } footer: {
                Text("Uses this clone's own iCloud container, not the official 嘟嘟 one. If CloudKit is unavailable, sync turns itself off so the app still opens.")
                    .font(.caption)
            }

            if v2Enabled {
                Section {
                    Button {
                        deviceNameDraft = deviceName
                        showDeviceNameEditor = true
                    } label: {
                        LabeledContent("Name") {
                            HStack(spacing: 6) {
                                Text(deviceName).foregroundStyle(MinisTheme.secondaryText)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Upload (This Device)")
                } footer: {
                    Text("This device name is broadcast to your other devices in the iCloud Sync zone.")
                        .font(.caption)
                }

                Section {
                    ForEach(UploadPolicy.Category.allCases, id: \.self) { cat in
                        Toggle(isOn: Binding(
                            get: { categoriesEnabled[cat] ?? true },
                            set: { newVal in
                                UploadPolicy.setEnabled(cat, newVal)
                                categoriesEnabled[cat] = newVal
                                Task { await markDeviceDirty() }
                            }
                        )) {
                            HStack(spacing: 12) {
                                Image(systemName: iconName(for: cat))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppearanceStudio.shared.color(.primaryText))
                                    .frame(width: 28, height: 28)
                                    .background(AppearanceStudio.shared.color(.surface), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppearanceStudio.shared.color(.border).opacity(0.4), lineWidth: 0.6))
                                Text(LocalizedStringKey(cat.displayName))
                            }
                        }
                    }
                    if categoriesEnabled[.sessionFiles] ?? true {
                        Picker(selection: $maxFileSizeMB) {
                            Text("256 KB").tag(0)
                            Text("1 MB").tag(1)
                            Text("4 MB").tag(4)
                            Text("16 MB").tag(16)
                            Text("64 MB").tag(64)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.zipper")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppearanceStudio.shared.color(.primaryText))
                                    .frame(width: 28, height: 28)
                                    .background(AppearanceStudio.shared.color(.surface), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppearanceStudio.shared.color(.border).opacity(0.4), lineWidth: 0.6))
                                Text("Max Per-File Size")
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: maxFileSizeMB) { newValue in
                            UploadPolicy.maxFileSizeBytes = newValue == 0 ? 256 * 1024 : newValue * 1024 * 1024
                        }
                    }
                } footer: {
                    Text("Choose which data this device pushes to iCloud. API keys and secrets sync through your iCloud account (base64-encoded, not end-to-end encrypted).")
                        .font(.caption)
                }

                Section {
                    if remoteDevices.isEmpty {
                        Text("No other devices found yet. Devices appear here once they enable iCloud Sync.")
                            .font(.caption)
                            .foregroundStyle(MinisTheme.secondaryText)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(remoteDevices, id: \.id) { d in
                            // [T-device-sync-policy] The download switch lives
                            // on the row itself: a separate section would make
                            // the reader match names across two lists. Turning
                            // it off stops records written by THAT device from
                            // landing here; it does not stop this device from
                            // uploading, and it is not a delete.
                            Toggle(isOn: Binding(
                                get: { DeviceSyncPolicy.isEnabled(d.id) },
                                set: { newValue in
                                    DeviceSyncPolicy.setEnabled(d.id, newValue)
                                    // Turning a device back ON must catch up on
                                    // what was skipped while it was off. The
                                    // incremental change token has already
                                    // moved past those records, so they will
                                    // never be re-delivered on their own —
                                    // without this the switch would silently
                                    // leave a permanent hole.
                                    if newValue, #available(iOS 17.0, *) {
                                        Task { await SyncCore.shared.fullFetchAndReconcile(trigger: .manual) }
                                    }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(d.deviceName).font(.body)
                                        Spacer()
                                        Text(relativeDate(d.lastSeen)).font(.caption2).foregroundStyle(MinisTheme.secondaryText)
                                    }
                                    if !d.uploadTypes.isEmpty {
                                        Text(uploadTypesSummary(d.uploadTypes))
                                            .font(.caption)
                                            .foregroundStyle(MinisTheme.secondaryText)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Other Devices")
                } footer: {
                    Text("Devices that are signed in to the same iCloud account and have sync enabled. Last seen reflects the most recent push from that device.")
                        .font(.caption)
                    // [remote-device-label] 会话不再按设备分区浏览 —— 同步来的会话
                    // 直接进会话列表，行尾标设备名。这里只说清去哪找。
                    Text("Sessions from those devices show up in your session list, labelled with the device name.")
                        .font(.caption)
                }

                // [T-sync-recovery-v1-parity] The two escape hatches that only
                // the retired v1 page had. They live below the ordinary
                // controls because they are repair actions, not settings.
                Section {
                    Button {
                        Task { await runForceResync() }
                    } label: {
                        HStack {
                            Text("Force Full Resync")
                            if isResyncing {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(isResyncing || isDeletingCloud)
                } header: {
                    Text("Sync Problems")
                } footer: {
                    Text("Re-uploads everything on this device and re-downloads everything from iCloud. Nothing is deleted on either side. Use it when another device is missing changes you can see here.")
                        .font(.caption)
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteCloudStep1 = true
                    } label: {
                        HStack {
                            Text("Delete iCloud Data")
                            if isDeletingCloud {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(isResyncing || isDeletingCloud)
                } header: {
                    Text("Danger Zone")
                } footer: {
                    Text("Permanently erases everything this app has stored in your iCloud account, then re-uploads this device's copy. Chat history on this device is not affected.")
                        .font(.caption)
                }
            }
        }
        .navigationTitle("iCloud Sync")
#if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        // [T-ios-migration-timer-sessionlist-uaf-crash] `.task` async refresh loop
        // replaces the old `.task { await refresh() }` + `.onReceive(timer)` pair, so
        // there is no graph-bound Combine sink to be released mid-transaction (the crash
        // that pattern caused — see refreshIntervalSeconds). SwiftUI cancels this Task
        // on teardown.
        .task { await refreshLoop() }
        // Two-step confirmation for the destructive action: the first dialog
        // spells out what is lost, the second is the one that actually runs it.
        .confirmationDialog("Delete all iCloud data?",
                            isPresented: $showDeleteCloudStep1,
                            titleVisibility: .visible) {
            Button("Continue", role: .destructive) {
                Task { await runDeleteCloudData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases every record this app has in your iCloud account, on all your devices, and then re-uploads this device's copy. Chat history stored on this device is not affected. Other devices will re-download from this one.")
        }
        .alert("iCloud Data", isPresented: Binding(
            get: { deleteCloudResult != nil },
            set: { if !$0 { deleteCloudResult = nil } }
        )) {
            Button("OK", role: .cancel) { deleteCloudResult = nil }
        } message: {
            Text(deleteCloudResult ?? "")
        }
        .alert("Device Name", isPresented: $showDeviceNameEditor) {
            TextField("Device name", text: $deviceNameDraft)
            Button("Save") {
                let trimmed = deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    UploadPolicy.customDeviceName = nil
                    deviceName = DeviceIdentity.deviceName
                } else {
                    UploadPolicy.customDeviceName = trimmed
                    deviceName = trimmed
                }
                Task { await markDeviceDirty() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Friendly name shown to your other 嘟嘟 devices.")
        }
        .settingsPage()
    }

    /// [T-ios-migration-timer-sessionlist-uaf-crash] Self-cancelling 5s refresh loop
    /// driven by `.task`, replacing the graph-bound `Timer.publish().autoconnect()` +
    /// `.onReceive` that AttributeGraph could tear down mid-transaction (UAF). SwiftUI
    /// cancels this Task on teardown, so no dangling subscription survives. Refreshes
    /// once immediately (mirroring the old `.task { await refresh() }`) then every 5s;
    /// skips the refresh while backgrounded and resumes on the next foreground tick.
    @MainActor
    private func refreshLoop() async {
        await refresh()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.refreshIntervalSeconds * 1_000_000_000)
            } catch {
                return  // cancelled during sleep
            }
            let backgrounded: Bool
            if #available(iOS 17.0, *) {
                backgrounded = SyncCore.shared.isAppInBackground
            } else {
                backgrounded = false
            }
            if !backgrounded {
                await refresh()
            }
        }
    }

    /// [T-sync-recovery-v1-parity] The two repair actions, ported from the
    /// retired v1 page. Both are gated on the engine actually running — with
    /// sync off there is nothing to resync and nothing to delete.
    @MainActor
    private func runForceResync() async {
        guard #available(iOS 17.0, *) else { return }
        isResyncing = true
        defer { isResyncing = false }
        await SyncRecovery.forceFullResync()
        MinisToast.show(AppLocalized("Resync started — this can take a minute."),
                        systemImage: "arrow.triangle.2.circlepath")
    }

    @MainActor
    private func runDeleteCloudData() async {
        guard #available(iOS 17.0, *) else { return }
        isDeletingCloud = true
        defer { isDeletingCloud = false }
        do {
            let result = try await SyncRecovery.deleteAllCloudData()
            deleteCloudResult = result.failedZones == 0
                ? String(format: AppLocalized("Deleted %d iCloud zone(s) and re-uploaded this device's data."), result.deletedZones)
                : String(format: AppLocalized("Deleted %1$d zone(s); %2$d could not be deleted. Try again in a moment."), result.deletedZones, result.failedZones)
        } catch {
            deleteCloudResult = String(format: AppLocalized("Couldn't delete iCloud data: %@"), error.localizedDescription)
        }
    }

    @MainActor
    private func refresh() async {
        if #available(iOS 17.0, *) {
            v2Enabled = SyncV2Bootstrap.isEnabled
        }
        deviceName = UploadPolicy.customDeviceName ?? DeviceIdentity.deviceName
        for cat in UploadPolicy.Category.allCases {
            categoriesEnabled[cat] = UploadPolicy.isEnabled(cat)
        }
        let bytes = UploadPolicy.maxFileSizeBytes
        maxFileSizeMB = bytes < 1024 * 1024 ? 0 : Int((Double(bytes) / (1024 * 1024)).rounded())
        let me = DeviceIdentity.deviceId
        let all = await ChatStore.shared.listSyncDevices()
        remoteDevices = all.filter { $0.id != me }.sorted { $0.lastSeen > $1.lastSeen }
        if #available(iOS 17.0, *), v2Enabled {
            statusText = SyncCore.shared.isRunning ? "Running" : "Starting"
        } else {
            statusText = "Off"
        }
    }

    /// Whenever the user changes their upload preferences or device
    /// name, re-broadcast our SyncDeviceV2 record so peers learn about
    /// the new state.
    private func markDeviceDirty() async {
        await ChatStore.shared.markDirty(
            recordType: "SyncDeviceV2",
            recordId: DeviceIdentity.deviceId
        )
        if #available(iOS 17.0, *) {
            SyncCore.shared.scheduleSend(delay: 1)
        }
    }

    private func iconName(for cat: UploadPolicy.Category) -> String {
        switch cat {
        case .chatSessions: return "bubble.left.and.bubble.right.fill"
        case .sessionFiles: return "doc.fill"
        case .skills:       return "puzzlepiece.fill"
        case .providers:    return "link"
        case .envVars:      return "rectangle.stack.fill"
        case .memory:       return "brain.head.profile"
        case .subAgents:    return "person.2.fill"   // [batch1/W1C-02]
        case .soul:         return "sparkles"        // [batch6/W1C-03]
        case .mcpServers:   return "server.rack"     // [batch6/W1C-03]
        }
    }

    private func iconColor(for cat: UploadPolicy.Category) -> Color {
        switch cat {
        case .chatSessions: return .blue
        case .sessionFiles: return .indigo
        case .skills:       return .orange
        case .providers:    return .teal
        case .envVars:      return .green
        case .memory:       return .pink
        case .subAgents:    return .purple   // [batch1/W1C-02]
        case .soul:         return .mint     // [batch6/W1C-03]
        case .mcpServers:   return .gray     // [batch6/W1C-03]
        }
    }

    private func uploadTypesSummary(_ csv: [String]) -> String {
        guard !csv.isEmpty else { return AppLocalized("No categories enabled") }
        return csv.joined(separator: " · ")
    }

    private func relativeDate(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return AppLocalized("Just now") }
        let mins = secs / 60
        if mins < 60 { return AppLocalized("\(mins) min ago") }
        let hrs = mins / 60
        if hrs < 24 { return AppLocalized("\(hrs) hr ago") }
        let days = hrs / 24
        return AppLocalized("\(days) day ago")
    }
}
