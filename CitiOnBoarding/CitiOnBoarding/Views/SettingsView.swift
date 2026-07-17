import SwiftUI

struct SettingsView: View {
    @AppStorage("aiProviderType") private var aiProviderType = "apple"
    @AppStorage("geminiApiKey") private var geminiApiKey = ""
    @AppStorage("geminiRegion") private var geminiRegion = "us-central1"
    @AppStorage("geminiTemperature") private var geminiTemperature = 0.2
    @AppStorage("geminiPromptProfile") private var geminiPromptProfile = "Banking Forms"
    
    @State private var isEncrypted = true
    @State private var isAuditingEnabled = true
    
    @State private var isValidating = false
    @State private var validationMessage = ""
    
    private let regions = ["us-central1", "us-east4", "europe-west1", "europe-west3", "asia-northeast1"]
    private let promptProfiles = ["Banking Forms", "Medical Records", "Legal Contracts", "Generic OCR"]
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .center, spacing: 8) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .cornerRadius(18)
                            .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                            .padding(.top, 8)
                        
                        Text("Citi Onboarding")
                            .font(.headline)
                            .bold()
                        
                        Text("Secure Online/Offline Document AI")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity)
                }
                
                Section(header: Text("AI Provider Selection")) {
                    Picker("AI Provider", selection: $aiProviderType) {
                        Text("Apple On-Device").tag("apple")
                        Text("Gemini API").tag("gemini")
                    }
                    .pickerStyle(.menu)
                    
                    if aiProviderType == "apple" {
                        Text("Uses local Vision OCR + native CoreML heuristic spelling and pattern recovery rules. 100% offline.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Connects securely to a multimodal Gemini API to reason about document layouts, checkboxes, and handwriting semantically.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if aiProviderType == "gemini" {
                    Section(header: Text("Gemini Configuration")) {
                        SecureField("Gemini API Key", text: $geminiApiKey)
                            .textInputAutocapitalization(.none)
                            .autocorrectionDisabled()
                        
                        HStack {
                            Button(action: {
                                Task {
                                    await validateConnection()
                                }
                            }) {
                                if isValidating {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Text("Validate Connection")
                                        .bold()
                                }
                            }
                            .disabled(isValidating || geminiApiKey.isEmpty)
                            
                            Spacer()
                            
                            if !validationMessage.isEmpty {
                                Text(validationMessage)
                                    .font(.caption)
                            }
                        }
                        
                        Picker("Region", selection: $geminiRegion) {
                            ForEach(regions, id: \.self) { reg in
                                Text(reg).tag(reg)
                            }
                        }
                        
                        Picker("Prompt Profile", selection: $geminiPromptProfile) {
                            ForEach(promptProfiles, id: \.self) { profile in
                                Text(profile).tag(profile)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Temperature")
                                Spacer()
                                Text(String(format: "%.1f", geminiTemperature))
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $geminiTemperature, in: 0.0...1.0, step: 0.1)
                        }
                    }
                }
                
                Section(header: Text("Security & Privacy")) {
                    Toggle(isOn: Binding(
                        get: { aiProviderType == "apple" },
                        set: { _ in }
                    )) {
                        VStack(alignment: .leading) {
                            Text("Enforce Offline Processing")
                            Text(aiProviderType == "apple" ? "Blocks all network outgoing calls" : "Online API model active")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(true) // Enforced by engine mode
                    
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
                        Text(aiProviderType == "apple" ? "Vision Engine 2026.1" : "Gemini 2.5 Flash")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Layout Model")
                        Spacer()
                        Text(aiProviderType == "apple" ? "CoreML Template Matcher" : "Gemini Layout Analyzer")
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
    
    private func validateConnection() async {
        isValidating = true
        validationMessage = ""
        do {
            guard !geminiApiKey.isEmpty else {
                validationMessage = "❌ API Key is empty"
                isValidating = false
                return
            }
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(geminiApiKey)")!
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                validationMessage = "🟢 Valid Connection"
            } else {
                validationMessage = "❌ Invalid API Key"
            }
        } catch {
            validationMessage = "❌ Network Error: \(error.localizedDescription)"
        }
        isValidating = false
    }
}
