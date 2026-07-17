import SwiftUI
import SwiftData
import PDFKit

// MARK: - Template Import Review Sheet
/// Shown after the AI extracts candidate fields from a blank PDF form.
/// User can review/edit each field's name, data type, and optional/required status before saving.
struct TemplateImportReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let pdfDocument: PDFDocument

    @State private var templateName: String = ""
    @State private var candidates: [TemplateFieldCandidate] = []
    @State private var baselineImages: [UIImage] = []
    @State private var isLoading = true
    @State private var showSuccess = false

    private var allFieldsValid: Bool {
        candidates.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    loadingView
                } else if candidates.isEmpty {
                    noFieldsView
                } else {
                    reviewList
                }
            }
            .navigationTitle("Review Template Fields")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.red)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: saveTemplate) {
                        Label("Save", systemImage: "checkmark.circle.fill")
                            .foregroundColor(allFieldsValid ? .blue : .gray)
                    }
                    .disabled(!allFieldsValid || candidates.isEmpty)
                }
            }
        }
        .task { await runExtraction() }
        .overlay(successOverlay)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.blue)
            Text("Analysing PDF structure…")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Extracting field labels using Vision OCR")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var noFieldsView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 56))
                .foregroundColor(.orange)
            Text("No Fields Detected")
                .font(.title2).bold()
            Text("The PDF doesn't contain numbered field labels (e.g. \"1. Full Name:\"). You can add fields manually.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(action: addBlankField) {
                Label("Add Field Manually", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var reviewList: some View {
        List {
            // Template Name
            Section {
                HStack {
                    Image(systemName: "doc.badge.plus")
                        .foregroundColor(.blue)
                    TextField("Template Name", text: $templateName)
                        .font(.headline)
                }
            } header: {
                Text("Template Name")
            } footer: {
                Text("Derived from the document title. Edit if needed.")
                    .font(.caption)
            }

            // Fields
            Section {
                ForEach($candidates) { $candidate in
                    FieldCandidateRow(candidate: $candidate)
                }
                .onDelete { indexSet in
                    candidates.remove(atOffsets: indexSet)
                    for (i, _) in candidates.enumerated() {
                        candidates[i].serialNumber = i + 1
                    }
                }
                .onMove { from, to in
                    candidates.move(fromOffsets: from, toOffset: to)
                    for (i, _) in candidates.enumerated() {
                        candidates[i].serialNumber = i + 1
                    }
                }
            } header: {
                HStack {
                    Text("Extracted Fields (\(candidates.count))")
                    Spacer()
                    Text("DRAG TO REORDER")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } footer: {
                Text("Swipe left to delete. Tap a field to edit name, type, and required status.")
            }

            // Add field
            Section {
                Button(action: addBlankField) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.blue)
                        Text("Add Field")
                            .foregroundColor(.blue)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
    }

    @ViewBuilder
    private var successOverlay: some View {
        if showSuccess {
            ZStack {
                Color.black.opacity(0.4).ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.green)
                    Text("Template Saved!")
                        .font(.title2).bold()
                        .foregroundColor(.white)
                    Text("\(candidates.count) fields registered for \"\(templateName)\"")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .padding(32)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
                .padding()
            }
        }
    }

    // MARK: - Actions

    private func runExtraction() async {
        isLoading = true
        let result = await PDFTemplateExtractor.shared.extractPreviewFields(from: pdfDocument)
        templateName = result.templateName
        candidates = result.fields
        baselineImages = result.baselineImages
        isLoading = false
    }

    private func addBlankField() {
        let num = candidates.count + 1
        candidates.append(TemplateFieldCandidate(
            serialNumber: num,
            name: "Field \(num)",
            expectedType: .text,
            isRequired: true,
            boundingBox: CGRect(x: 0.1, y: Double(num) * 0.07, width: 0.8, height: 0.04)
        ))
    }

    private func saveTemplate() {
        for (i, _) in candidates.enumerated() {
            candidates[i].serialNumber = i + 1
        }
        PDFTemplateExtractor.shared.commitTemplate(
            name: templateName,
            candidates: candidates,
            baselineImages: baselineImages,
            modelContext: modelContext
        )
        withAnimation { showSuccess = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            dismiss()
        }
    }
}

// MARK: - Individual Field Row
struct FieldCandidateRow: View {
    @Binding var candidate: TemplateFieldCandidate

    private let allTypes: [FieldType] = [
        .text, .multiline, .number, .date, .currency, .phone, .email,
        .checkbox, .radio, .dropdown, .table, .image, .signature,
        .initials, .stamp, .photo, .barcode, .qrCode,
        .pan, .aadhaar, .ifsc, .boolean
    ]

    private func typeLabel(_ type: FieldType) -> String {
        switch type {
        case .text:      return "Text"
        case .multiline: return "Multiline"
        case .number:    return "Number"
        case .date:      return "Date"
        case .currency:  return "Currency"
        case .phone:     return "Phone"
        case .email:     return "Email"
        case .checkbox:  return "Checkbox"
        case .radio:     return "Radio"
        case .dropdown:  return "Dropdown"
        case .table:     return "Table"
        case .image:     return "Image"
        case .signature: return "Signature"
        case .initials:  return "Initials"
        case .stamp:     return "Stamp"
        case .photo:     return "Photo"
        case .barcode:   return "Barcode"
        case .qrCode:    return "QR Code"
        case .pan:       return "PAN"
        case .aadhaar:   return "Aadhaar"
        case .ifsc:      return "IFSC"
        case .boolean:   return "Boolean"
        case .multiLine: return "Multi-line"
        }
    }

    private func typeColor(_ type: FieldType) -> Color {
        switch type {
        case .text, .multiline, .multiLine: return .blue
        case .number, .currency: return .orange
        case .date:      return .purple
        case .boolean:   return .teal
        case .signature, .initials: return .pink
        case .stamp, .photo, .image: return .indigo
        case .phone, .email: return .green
        case .pan, .aadhaar, .ifsc: return .red
        case .checkbox, .radio, .dropdown: return .cyan
        case .table:     return .brown
        case .barcode, .qrCode: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(candidate.serialNumber).")
                    .font(.caption)
                    .bold()
                    .foregroundColor(.secondary)
                    .frame(width: 24, alignment: .trailing)
                TextField("Field name", text: $candidate.name)
                    .font(.body)
                    .fontWeight(.semibold)
            }

            HStack(spacing: 12) {
                Menu {
                    ForEach(allTypes, id: \.self) { type in
                        Button(action: { candidate.expectedType = type }) {
                            HStack {
                                Text(typeLabel(type))
                                if candidate.expectedType == type {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "tag.fill")
                            .font(.caption2)
                        Text(typeLabel(candidate.expectedType))
                            .font(.caption)
                            .bold()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(typeColor(candidate.expectedType).opacity(0.12))
                    .foregroundColor(typeColor(candidate.expectedType))
                    .cornerRadius(6)
                }

                Spacer()

                Toggle("", isOn: $candidate.isRequired)
                    .toggleStyle(.switch)
                    .scaleEffect(0.75)
                    .frame(width: 48)

                Text(candidate.isRequired ? "Required" : "Optional")
                    .font(.caption2)
                    .foregroundColor(candidate.isRequired ? .red : .secondary)
                    .frame(width: 56, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }
}
