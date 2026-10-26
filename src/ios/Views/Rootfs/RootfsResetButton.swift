//
//  RootfsResetButton.swift
//  MinisApp
//
//  Quick reset button component for easy integration
//

import SwiftUI

/// Quick reset button that can be embedded anywhere in the UI
struct RootfsResetButton: View {
    enum Style {
        case compact  // Small icon button
        case normal   // Regular button
        case prominent // Large styled button
    }

    let style: Style
    let showBackupOption: Bool
    @State private var showResetAlert = false
    @State private var showBackupAlert = false
    @State private var isProcessing = false
    @State private var statusMessage: String?

    init(style: Style = .normal, showBackupOption: Bool = true) {
        self.style = style
        self.showBackupOption = showBackupOption
    }

    var body: some View {
        Group {
            switch style {
            case .compact:
                compactButton
            case .normal:
                normalButton
            case .prominent:
                prominentButton
            }
        }
        .disabled(isProcessing)
        // [K-3] Two `.alert` modifiers on one view means iOS only honours one
        // of them; whichever was declared last won. "Reset & Backup" could be
        // dead depending on order. One alert, branch on which flag is set.
        .alert(alertTitle,
               isPresented: Binding(
                   get: { showResetAlert || showBackupAlert },
                   set: { presented in
                       guard !presented else { return }
                       showResetAlert = false
                       showBackupAlert = false
                   }
               )) {
            Button("Cancel", role: .cancel) {
                showResetAlert = false
                showBackupAlert = false
            }
            if showBackupAlert {
                Button("Reset & Backup", role: .destructive) {
                    showBackupAlert = false
                    performReset(keepBackup: true)
                }
            } else {
                Button("Reset", role: .destructive) {
                    showResetAlert = false
                    performReset(keepBackup: false)
                }
            }
        } message: {
            if showBackupAlert {
                Text("This will backup /root directory before resetting. You can restore it later.")
            } else {
                Text("This will delete the entire rootfs. All data will be lost. The app will need to restart.")
            }
        }
    }

    /// [K-3b] A ternary of two string literals collapses to `String` at the
    /// call site, which picks the verbatim `alert` overload and skips the
    /// string table entirely. Typing the branches as `LocalizedStringKey`
    /// keeps both keys localizable.
    private var alertTitle: LocalizedStringKey {
        showBackupAlert ? "Reset with Backup?" : "Reset Rootfs?"
    }

    private var compactButton: some View {
        Menu {
            Button(action: { DispatchQueue.main.async { showResetAlert = true } }) {
                Label("Reset All", systemImage: "trash")
            }

            if showBackupOption {
                Button(action: { DispatchQueue.main.async { showBackupAlert = true } }) {
                    Label("Reset & Backup", systemImage: "archivebox")
                }
            }
        } label: {
            Image(systemName: "arrow.clockwise.circle")
                .imageScale(.large)
                .foregroundColor(.red)
        }
    }

    private var normalButton: some View {
        Menu {
            Button(action: { DispatchQueue.main.async { showResetAlert = true } }) {
                Label("Reset All", systemImage: "trash")
            }

            if showBackupOption {
                Button(action: { DispatchQueue.main.async { showBackupAlert = true } }) {
                    Label("Reset & Backup", systemImage: "archivebox")
                }
            }
        } label: {
            Label("Reset Rootfs", systemImage: "arrow.clockwise")
                .foregroundColor(.red)
        }
    }

    private var prominentButton: some View {
        VStack(spacing: 12) {
            Button(action: { DispatchQueue.main.async { showResetAlert = true } }) {
                Label("Reset Rootfs", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(MinisTheme.destructive)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }

            if showBackupOption {
                Button(action: { DispatchQueue.main.async { showBackupAlert = true } }) {
                    Label("Reset & Backup", systemImage: "archivebox")
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(MinisTheme.warning)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }

            if isProcessing {
                HStack {
                    ProgressView()
                    Text(statusMessage ?? "Processing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func performReset(keepBackup: Bool) {
        isProcessing = true
        statusMessage = keepBackup ? "Backing up and resetting..." : "Resetting rootfs..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let backup = try RootfsManager.shared.reset(keepUserData: keepBackup)

                DispatchQueue.main.async {
                    self.isProcessing = false

                    if keepBackup, let backup = backup {
                        self.statusMessage = "✅ Reset complete. Backup at: \(backup.lastPathComponent)"
                    } else {
                        self.statusMessage = "✅ Reset complete. Restart app to reinstall."
                    }

                    // Clear message after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        self.statusMessage = nil
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.statusMessage = "❌ Error: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// Quick access reset toolbar item
struct RootfsResetToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            RootfsResetButton(style: .compact)
        }
    }
}

// MARK: - Usage Examples

/*

 // Example 1: Add to toolbar
 .toolbar {
     RootfsResetToolbarItem()
 }

 // Example 2: Compact icon button
 RootfsResetButton(style: .compact)

 // Example 3: Normal button
 RootfsResetButton(style: .normal)

 // Example 4: Prominent styled buttons
 RootfsResetButton(style: .prominent)

 // Example 5: Reset only (no backup option)
 RootfsResetButton(style: .normal, showBackupOption: false)

 // Example 6: In a Form/List
 Section("Danger Zone") {
     RootfsResetButton(style: .normal)
 }

 // Example 7: Custom layout
 VStack {
     Text("System Management")
         .font(.headline)
     RootfsResetButton(style: .prominent)
 }

 */

#Preview("Compact") {
    NavigationStack {
        VStack {
            RootfsResetButton(style: .compact)
        }
        .navigationTitle("Compact Style")
    }
}

#Preview("Normal") {
    NavigationStack {
        List {
            Section("Actions") {
                RootfsResetButton(style: .normal)
            }
        }
        .navigationTitle("Normal Style")
    }
}

#Preview("Prominent") {
    NavigationStack {
        VStack(spacing: 20) {
            Text("Rootfs Management")
                .font(.title)
                .fontWeight(.bold)

            RootfsResetButton(style: .prominent)
        }
        .padding()
        .navigationTitle("Prominent Style")
    }
}
