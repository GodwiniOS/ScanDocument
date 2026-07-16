import SwiftUI

struct SettingsView: View {
    @State private var isOfflineMode = true
    @State private var isEncrypted = true
    @State private var isAuditingEnabled = true
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Security & Privacy")) {
                    Toggle(isOn: $isOfflineMode) {
                        VStack(alignment: .leading) {
                            Text("Enforce Offline Processing")
                            Text("Blocks all network outgoing calls")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(true) // Enforced by SDK
                    
                    Toggle(isOn: $isEncrypted) {
                        VStack(alignment: .leading) {
                            Text("Local Storage Encryption")
                            Text("Database files are protected with AES-256")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(true) // Enforced by default
                    
                    Toggle(isOn: $isAuditingEnabled) {
                        VStack(alignment: .leading) {
                            Text("User Correction Audit Log")
                            Text("Saves field modification history")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section(header: Text("Model Version")) {
                    HStack {
                        Text("OCR Model")
                        Spacer()
                        Text("Vision Engine 2026.1")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Layout Model")
                        Spacer()
                        Text("CoreML Template Matcher")
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("Enterprise SDK")) {
                    HStack {
                        Text("SDK Status")
                        Spacer()
                        Text("Active Development Mode")
                            .foregroundColor(.blue)
                    }
                    
                    HStack {
                        Text("Bundle Identifier")
                        Spacer()
                        Text("Citi.CitiOnBoarding")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
