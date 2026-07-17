import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

struct TemplatesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Template.name) private var templates: [Template]
    
    @State private var editingField: Field?
    @State private var showAddSheet = false
    @State private var isShowingTemplateImporter = false
    @State private var templateReviewPDF: PDFDocument? = nil
    @State private var isShowingTemplateReview = false
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(templates) { template in
                    DisclosureGroup {
                        if let fields = template.fields?.sorted(by: { $0.boundingBoxY > $1.boundingBoxY }) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(fields) { field in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(field.name)
                                                .font(.subheadline)
                                                .fontWeight(.semibold)
                                            Text("Region: (\(String(format: "%.2f", field.boundingBoxX)), \(String(format: "%.2f", field.boundingBoxY))) [w: \(String(format: "%.2f", field.boundingBoxWidth)), h: \(String(format: "%.2f", field.boundingBoxHeight))]")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        
                                        Text(field.expectedType.rawValue.uppercased())
                                            .font(.caption2)
                                            .bold()
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.1))
                                            .foregroundColor(.blue)
                                            .cornerRadius(4)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        editingField = field
                                    }
                                    
                                    if field.id != fields.last?.id {
                                        Divider()
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        } else {
                            Text("No fields defined for this template.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(template.name)
                                    .font(.headline)
                                Spacer()
                                if template.version.hasPrefix("seed") {
                                    Text("SEED")
                                        .font(.caption2)
                                        .bold()
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.15))
                                        .foregroundColor(.orange)
                                        .cornerRadius(4)
                                }
                            }
                            
                            HStack {
                                Text("Version \(template.version)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                Text("\(template.fields?.count ?? 0) Fields")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(6)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete(perform: deleteTemplates)
            }
            .navigationTitle("Template Manager")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { showAddSheet = true }) {
                            Label("Create Blank Template", systemImage: "square.and.pencil")
                        }
                        Button(action: { isShowingTemplateImporter = true }) {
                            Label("Import Template from PDF", systemImage: "rectangle.3.group.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .overlay {
                if templates.isEmpty {
                    ContentUnavailableView(
                        "No Templates",
                        systemImage: "square.stack.3d.up.dottedline",
                        description: Text("Tap + to create a blank template or import from a PDF form.")
                    )
                }
            }
            .sheet(item: $editingField) { field in
                FieldEditSheet(field: field)
            }
            .sheet(isPresented: $showAddSheet) {
                BlankTemplateCreatorSheet()
            }
            .fileImporter(
                isPresented: $isShowingTemplateImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    url.startAccessingSecurityScopedResource()
                    if let pdf = PDFDocument(url: url) {
                        templateReviewPDF = pdf
                        isShowingTemplateReview = true
                    }
                    url.stopAccessingSecurityScopedResource()
                }
            }
            .sheet(isPresented: $isShowingTemplateReview) {
                if let pdf = templateReviewPDF {
                    TemplateImportReviewView(pdfDocument: pdf)
                }
            }
        }
    }
    
    private func deleteTemplates(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(templates[index])
            }
        }
    }
}

// MARK: - Blank Template Creator Sheet
struct BlankTemplateCreatorSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var templateName: String = ""
    @State private var candidates: [TemplateFieldCandidate] = []
    @State private var showSuccess = false
    
    private var canSave: Bool {
        !templateName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !candidates.isEmpty &&
        candidates.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                            .foregroundColor(.blue)
                        TextField("e.g. Citi Credit Card Form", text: $templateName)
                            .font(.headline)
                    }
                } header: {
                    Text("Template Name")
                }
                
                Section {
                    ForEach($candidates) { $candidate in
                        FieldCandidateRow(candidate: $candidate)
                    }
                    .onDelete { indexSet in
                        candidates.remove(atOffsets: indexSet)
                        renumber()
                    }
                    .onMove { from, to in
                        candidates.move(fromOffsets: from, toOffset: to)
                        renumber()
                    }
                } header: {
                    HStack {
                        Text("Fields (\(candidates.count))")
                        Spacer()
                        Text("DRAG TO REORDER")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    if candidates.isEmpty {
                        Text("Tap \"Add Field\" to define what data this form captures.")
                    }
                }
                
                Section {
                    Button(action: addField) {
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
            .navigationTitle("New Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.red)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: save) {
                        Label("Save", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(!canSave)
                }
            }
        }
        .overlay(successOverlay)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
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
                    Text("\(candidates.count) fields saved for \"\(templateName)\"")
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
    
    private func addField() {
        let num = candidates.count + 1
        candidates.append(TemplateFieldCandidate(
            serialNumber: num,
            name: "",
            expectedType: .text,
            isRequired: true,
            boundingBox: CGRect(x: 0.1, y: Double(num) * 0.07, width: 0.8, height: 0.04)
        ))
    }
    
    private func renumber() {
        for (i, _) in candidates.enumerated() {
            candidates[i].serialNumber = i + 1
        }
    }
    
    private func save() {
        renumber()
        PDFTemplateExtractor.shared.commitTemplate(
            name: templateName.trimmingCharacters(in: .whitespaces),
            candidates: candidates,
            modelContext: modelContext
        )
        withAnimation { showSuccess = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { dismiss() }
    }
}

// MARK: - Field Edit Sheet (existing field from template)
struct FieldEditSheet: View {
    @Bindable var field: Field
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Field Information") {
                    TextField("Field Name", text: $field.name)
                        .font(.body)
                }
                
                Section("Expected Extraction Data Type") {
                    Picker("Data Type", selection: $field.expectedType) {
                        Text("Text").tag(FieldType.text)
                        Text("Multiline").tag(FieldType.multiline)
                        Text("Number").tag(FieldType.number)
                        Text("Boolean").tag(FieldType.boolean)
                        Text("Date").tag(FieldType.date)
                        Text("Signature").tag(FieldType.signature)
                        Text("Initials").tag(FieldType.initials)
                        Text("Stamp").tag(FieldType.stamp)
                        Text("Photo").tag(FieldType.photo)
                        Text("Barcode").tag(FieldType.barcode)
                        Text("QR Code").tag(FieldType.qrCode)
                        Text("Phone").tag(FieldType.phone)
                        Text("Email").tag(FieldType.email)
                        Text("PAN").tag(FieldType.pan)
                        Text("Aadhaar").tag(FieldType.aadhaar)
                        Text("IFSC").tag(FieldType.ifsc)
                        Text("Currency").tag(FieldType.currency)
                        Text("Radio").tag(FieldType.radio)
                        Text("Dropdown").tag(FieldType.dropdown)
                        Text("Table").tag(FieldType.table)
                        Text("Image").tag(FieldType.image)
                    }
                    .pickerStyle(.inline)
                }
                
                Section("Validation") {
                    Toggle("Required Field", isOn: $field.isRequired)
                }
            }
            .navigationTitle("Edit Field Schema")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        try? modelContext.save()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}
