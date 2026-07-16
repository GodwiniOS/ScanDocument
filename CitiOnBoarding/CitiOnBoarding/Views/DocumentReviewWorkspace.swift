import SwiftUI
import SwiftData

struct DocumentReviewWorkspace: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    var session: DocumentSession
    
    @State private var selectedPage: Page?
    @State private var selectedResult: FieldResult?
    @State private var isShowingExportSheet = false
    @State private var editedValue = ""
    
    // Zoom & Pan state
    @State private var zoomScale: CGFloat = 1.0
    @State private var currentScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var currentOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width > 700
            
            VStack(spacing: 0) {
                if isWide {
                    wideLayout
                } else {
                    compactLayout
                }
            }
        }
        .navigationTitle(session.matchedTemplate?.name ?? "Document Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { isShowingExportSheet = true }) {
                    Label("Export Options", systemImage: "square.and.arrow.up")
                }
            }
        }
        .onAppear {
            selectedPage = session.pages?.sorted(by: { $0.pageNumber < $1.pageNumber }).first
            if let firstResult = selectedPage?.results?.sorted(by: { $0.boundingBoxY < $1.boundingBoxY }).first {
                selectedResult = firstResult
                editedValue = firstResult.finalValue
            }
        }
        .onChange(of: selectedResult) { oldValue, newValue in
            if let newValue = newValue {
                editedValue = newValue.finalValue
            }
        }
        .sheet(isPresented: $isShowingExportSheet) {
            ExportSheetView(session: session)
        }
    }
    
    // MARK: - Wide Layout (iPad / Mac)
    private var wideLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                thumbnailSidebar
                    .frame(width: 140)
                    .background(Color(.systemGroupedBackground))
                
                Divider()
                
                VStack {
                    if let page = selectedPage {
                        canvasView(for: page)
                    } else {
                        ContentUnavailableView("No Page Selected", systemImage: "doc")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                Divider()
                
                fieldInspector
                    .frame(width: 350)
                    .background(Color(.secondarySystemBackground))
            }
            
            Divider()
            
            actionToolbar
        }
    }
    
    // MARK: - Compact Layout (iPhone)
    private var compactLayout: some View {
        VStack(spacing: 0) {
            pageSelectorRow
            
            Divider()
            
            ZStack(alignment: .bottom) {
                VStack {
                    if let page = selectedPage {
                        canvasView(for: page)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("No Page Selected", systemImage: "doc")
                    }
                }
                
                if let result = selectedResult {
                    floatingInspectorCard(for: result)
                }
            }
        }
    }
    
    private var pageSelectorRow: some View {
        HStack {
            Text("Page \(selectedPage?.pageNumber ?? 1) of \(session.pages?.count ?? 1)")
                .font(.subheadline)
                .bold()
            
            Spacer()
            
            // Zoom controls
            HStack(spacing: 8) {
                Button(action: {
                    withAnimation(.spring()) {
                        zoomScale = max(1.0, zoomScale - 0.5)
                        if zoomScale == 1.0 { panOffset = .zero }
                    }
                }) {
                    Image(systemName: "minus.magnifyingglass")
                        .padding(6)
                        .background(Color(.systemGray5))
                        .cornerRadius(6)
                }
                
                Text("\(Int(zoomScale * 100))%")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .frame(width: 38)
                
                Button(action: {
                    withAnimation(.spring()) {
                        zoomScale = min(5.0, zoomScale + 0.5)
                    }
                }) {
                    Image(systemName: "plus.magnifyingglass")
                        .padding(6)
                        .background(Color(.systemGray5))
                        .cornerRadius(6)
                }
            }
            .padding(.trailing, 8)
            
            Menu {
                if let pages = session.pages?.sorted(by: { $0.pageNumber < $1.pageNumber }) {
                    ForEach(pages) { page in
                        Button("Page \(page.pageNumber)") {
                            selectedPage = page
                            // Reset zoom on page switch
                            zoomScale = 1.0
                            panOffset = .zero
                            if let firstRes = page.results?.sorted(by: { $0.boundingBoxY < $1.boundingBoxY }).first {
                                selectedResult = firstRes
                            }
                        }
                    }
                }
            } label: {
                Label("Switch Page", systemImage: "arrow.left.and.right")
                    .font(.caption)
                    .bold()
            }
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }
    
    private func floatingInspectorCard(for result: FieldResult) -> some View {
        let field = session.matchedTemplate?.fields?.first(where: { $0.id == result.fieldID })
        
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(statusColor(for: result.validationState))
                    .frame(width: 8, height: 8)
                
                Text(field?.name ?? "Field")
                    .font(.subheadline)
                    .bold()
                
                Spacer()
                
                Text(validationText(for: result))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 8) {
                if let page = selectedPage, let cropped = cropPreview(imagePath: page.imagePath, rect: result.rect) {
                    Image(uiImage: cropped)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 40)
                        .background(Color.white)
                        .cornerRadius(4)
                        .shadow(radius: 1)
                }
                
                TextField("Edit value", text: $editedValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onChange(of: editedValue) { oldValue, newValue in
                        if newValue != result.finalValue {
                            result.userOverride = newValue
                            result.edited = true
                            result.validationState = .edited
                            let correction = UserCorrection(fieldResultID: result.id, originalValue: result.ocrText, correctedValue: newValue)
                            modelContext.insert(correction)
                            try? modelContext.save()
                        }
                    }
            }
            
            HStack {
                Button(action: selectPreviousField) {
                    Image(systemName: "chevron.left")
                        .bold()
                        .padding(8)
                        .background(Color(.systemGray5))
                        .cornerRadius(6)
                }
                .disabled(selectedResult == nil)
                
                Spacer()
                
                Button(action: acceptField) {
                    Label("Accept", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.green)
                        .cornerRadius(6)
                }
                .disabled(selectedResult == nil)
                
                Button(action: rejectField) {
                    Label("Reject", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red)
                        .cornerRadius(6)
                }
                .disabled(selectedResult == nil)
                
                Spacer()
                
                Button(action: selectNextIssue) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .padding(8)
                        .background(Color(.systemGray5))
                        .cornerRadius(6)
                }
                
                Button(action: selectNextField) {
                    Image(systemName: "chevron.right")
                        .bold()
                        .padding(8)
                        .background(Color(.systemGray5))
                        .cornerRadius(6)
                }
                .disabled(selectedResult == nil)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.15), radius: 5, x: 0, y: -2)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
    
    // MARK: - Left sidebar
    private var thumbnailSidebar: some View {
        VStack(spacing: 0) {
            Text("PAGES")
                .font(.caption2)
                .bold()
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.top, .leading, .bottom], 10)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 16) {
                    if let pages = session.pages?.sorted(by: { $0.pageNumber < $1.pageNumber }) {
                        ForEach(pages) { page in
                            Button(action: {
                                selectedPage = page
                                if let firstRes = page.results?.sorted(by: { $0.boundingBoxY < $1.boundingBoxY }).first {
                                    selectedResult = firstRes
                                } else {
                                    selectedResult = nil
                                }
                            }) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack(alignment: .topTrailing) {
                                        if let uiImage = loadImage(from: page.imagePath) {
                                            Image(uiImage: uiImage)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(height: 100)
                                                .cornerRadius(6)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(selectedPage?.id == page.id ? Color.blue : Color.clear, lineWidth: 3)
                                                )
                                        } else {
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.secondary)
                                                .frame(height: 100)
                                                .overlay(Text("\(page.pageNumber)").foregroundColor(.white))
                                        }
                                        
                                        Circle()
                                            .fill(pageQualityColor(for: page))
                                            .frame(width: 12, height: 12)
                                            .padding(4)
                                    }
                                    
                                    let stats = pageStats(for: page)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Page \(page.pageNumber)")
                                            .font(.caption)
                                            .bold()
                                            .foregroundColor(.primary)
                                        Text("Fields: \(stats.total)")
                                        Text("Needs Rev: \(stats.review)")
                                        Text("Invalid: \(stats.invalid)")
                                    }
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 6)
                        }
                    }
                }
                .padding(.vertical)
            }
        }
    }
    
    // MARK: - Center Canvas View
    private func canvasView(for page: Page) -> some View {
        GeometryReader { canvasGeo in
            ZStack {
                if let uiImage = loadImage(from: page.imagePath) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .overlay(
                            GeometryReader { imageGeo in
                                let imgSize = imageGeo.size
                                
                                if let results = page.results {
                                    ForEach(results) { result in
                                        let rect = rectForField(result, in: imgSize)
                                        
                                        Rectangle()
                                            .stroke(rectStrokeColor(for: result), lineWidth: selectedResult?.id == result.id ? 3 : 2)
                                            .background(
                                                Rectangle()
                                                    .fill(rectStrokeColor(for: result).opacity(selectedResult?.id == result.id ? 0.25 : 0.08))
                                            )
                                            .frame(width: rect.width, height: rect.height)
                                            .position(x: rect.midX, y: rect.midY)
                                            .onTapGesture {
                                                selectedResult = result
                                            }
                                    }
                                }
                            }
                        )
                } else {
                    ProgressView("Loading page image...")
                }
            }
            .scaleEffect(zoomScale * currentScale)
            .offset(x: panOffset.width + currentOffset.width, y: panOffset.height + currentOffset.height)
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            currentScale = value
                        }
                        .onEnded { value in
                            zoomScale = max(1.0, min(zoomScale * value, 5.0))
                            currentScale = 1.0
                        },
                    DragGesture()
                        .onChanged { value in
                            if zoomScale > 1.0 {
                                currentOffset = value.translation
                            }
                        }
                        .onEnded { value in
                            if zoomScale > 1.0 {
                                panOffset.width += value.translation.width
                                panOffset.height += value.translation.height
                                currentOffset = .zero
                            }
                        }
                )
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring()) {
                    if zoomScale > 1.0 {
                        zoomScale = 1.0
                        panOffset = .zero
                    } else {
                        zoomScale = 2.0
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }
    
    private func rectForField(_ result: FieldResult, in size: CGSize) -> CGRect {
        let x = result.boundingBoxX * size.width
        let y = result.boundingBoxY * size.height
        let width = result.boundingBoxWidth * size.width
        let height = result.boundingBoxHeight * size.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
    
    private func rectStrokeColor(for result: FieldResult) -> Color {
        if selectedResult?.id == result.id {
            return .yellow
        }
        
        switch result.validationState {
        case .verified: return .green
        case .autoAccepted: return .blue
        case .needsReview: return .orange
        case .invalid: return .red
        case .empty: return .gray
        case .edited: return .purple
        }
    }
    
    // MARK: - Right Sidebar Field Inspector
    private var fieldInspector: some View {
        VStack(spacing: 0) {
            Text("FIELDS ON PAGE")
                .font(.caption2)
                .bold()
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.top, .leading, .bottom], 10)
            
            Divider()
            
            if let results = selectedPage?.results?.sorted(by: { $0.boundingBoxY < $1.boundingBoxY }) {
                List(selection: $selectedResult) {
                    ForEach(results) { result in
                        let fieldName = session.matchedTemplate?.fields?.first(where: { $0.id == result.fieldID })?.name ?? "Field"
                        
                        HStack {
                            Circle()
                                .fill(statusColor(for: result.validationState))
                                .frame(width: 8, height: 8)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fieldName)
                                    .font(.caption)
                                    .bold()
                                    .foregroundColor(selectedResult?.id == result.id ? .blue : .primary)
                                
                                Text(result.finalValue.isEmpty ? "[Empty]" : result.finalValue)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            Text("\(Int(result.overallConfidence * 100))%")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .tag(result)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedResult = result
                        }
                    }
                }
                .frame(height: 180)
                .listStyle(.plain)
            }
            
            Divider()
            
            ScrollView {
                if let result = selectedResult {
                    let field = session.matchedTemplate?.fields?.first(where: { $0.id == result.fieldID })
                    
                    VStack(alignment: .leading, spacing: 14) {
                        Text(field?.name ?? "Field Details")
                            .font(.headline)
                            .padding(.top, 4)
                        
                        if let page = selectedPage, let cropped = cropPreview(imagePath: page.imagePath, rect: result.rect) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("CROP PREVIEW")
                                    .font(.caption2)
                                    .bold()
                                    .foregroundColor(.secondary)
                                
                                Image(uiImage: cropped)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 70)
                                    .padding(4)
                                    .background(Color.white)
                                    .cornerRadius(6)
                                    .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("EXTRACTED VALUE")
                                .font(.caption2)
                                .bold()
                                .foregroundColor(.secondary)
                            
                            TextField("Input Value", text: $editedValue)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: editedValue) { oldValue, newValue in
                                    if newValue != result.finalValue {
                                        result.userOverride = newValue
                                        result.edited = true
                                        result.validationState = .edited
                                        let correction = UserCorrection(fieldResultID: result.id, originalValue: result.ocrText, correctedValue: newValue)
                                        modelContext.insert(correction)
                                        try? modelContext.save()
                                    }
                                }
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("VALIDATION STATUS")
                                .font(.caption2)
                                .bold()
                                .foregroundColor(.secondary)
                            
                            HStack {
                                Circle()
                                    .fill(statusColor(for: result.validationState))
                                    .frame(width: 8, height: 8)
                                
                                Text(validationText(for: result))
                                    .font(.caption)
                                    .bold()
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            metadataRow(label: "Data Type", value: field?.expectedType.rawValue.capitalized ?? "Text")
                            metadataRow(label: "Requirement", value: (field?.isRequired ?? true) ? "Required" : "Optional")
                            metadataRow(label: "Format", value: expectedFormat(for: field?.expectedType ?? .text))
                            metadataRow(label: "Extraction Source", value: result.isHandwritten ? "Handwritten" : "Printed")
                            metadataRow(label: "Raw OCR Text", value: result.ocrText)
                            metadataRow(label: "Normalized Text", value: result.normalizedValue ?? "N/A")
                        }
                        .padding(8)
                        .background(Color(.systemBackground))
                        .cornerRadius(8)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("CONFIDENCE MATRIX")
                                .font(.caption2)
                                .bold()
                                .foregroundColor(.secondary)
                            
                            confidenceRow(label: "OCR Recognition", score: result.ocrConfidence)
                            confidenceRow(label: "Field Mapping", score: result.mappingConfidence)
                            confidenceRow(label: "Data Validation", score: result.validationConfidence)
                            Divider()
                            confidenceRow(label: "Overall Confidence", score: result.overallConfidence, isBold: true)
                        }
                        .padding(8)
                        .background(Color(.systemBackground))
                        .cornerRadius(8)
                    }
                    .padding()
                } else {
                    ContentUnavailableView("Select a Field", systemImage: "hand.tap", description: Text("Select a field from the list or tap a box on the canvas."))
                        .padding(.top, 40)
                }
            }
            .background(Color(.secondarySystemBackground))
        }
    }
    
    // MARK: - Wide Action Toolbar
    private var actionToolbar: some View {
        HStack(spacing: 12) {
            Button(action: selectPreviousField) {
                Image(systemName: "chevron.left")
                Text("Prev")
            }
            .disabled(selectedResult == nil)
            
            Spacer()
            
            Button(action: acceptField) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Accept")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(selectedResult == nil)
            
            Button(action: rejectField) {
                HStack {
                    Image(systemName: "xmark.circle.fill")
                    Text("Reject")
                }
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)
            .disabled(selectedResult == nil)
            
            Spacer()
            
            Button(action: selectNextIssue) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Next Issue")
                }
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            
            Spacer()
            
            Button(action: selectNextField) {
                Text("Next")
                Image(systemName: "chevron.right")
            }
            .disabled(selectedResult == nil)
        }
        .padding()
        .background(Color(.systemBackground))
    }
    
    // MARK: - Helpers
    private func loadImage(from path: String) -> UIImage? {
        let filename = (path as NSString).lastPathComponent
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let documentsDirectory = paths.first else { return nil }
        let fileURL = documentsDirectory.appendingPathComponent(filename)
        return UIImage(contentsOfFile: fileURL.path)
    }
    
    private func cropPreview(imagePath: String, rect: CGRect) -> UIImage? {
        guard let rawImage = loadImage(from: imagePath),
              let cgImage = rawImage.cgImage else { return nil }
        
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        
        let cropRect = CGRect(
            x: rect.origin.x * width,
            y: rect.origin.y * height,
            width: rect.size.width * width,
            height: rect.size.height * height
        )
        
        guard cropRect.width > 0 && cropRect.height > 0 else { return nil }
        guard let croppedCgImage = cgImage.cropping(to: cropRect) else { return nil }
        return UIImage(cgImage: croppedCgImage)
    }
    
    private func pageStats(for page: Page) -> (total: Int, verified: Int, review: Int, invalid: Int) {
        guard let results = page.results else { return (0, 0, 0, 0) }
        let total = results.count
        let verified = results.filter { $0.validationState == .verified }.count
        let review = results.filter { $0.validationState == .needsReview }.count
        let invalid = results.filter { $0.validationState == .invalid }.count
        return (total, verified, review, invalid)
    }
    
    private func pageQualityColor(for page: Page) -> Color {
        let stats = pageStats(for: page)
        if stats.invalid > 0 {
            return .red
        } else if stats.review > 0 {
            return .orange
        }
        return .green
    }
    
    private func statusColor(for state: ValidationState) -> Color {
        switch state {
        case .verified: return .green
        case .autoAccepted: return .blue
        case .needsReview: return .orange
        case .invalid: return .red
        case .empty: return .gray
        case .edited: return .purple
        }
    }
    
    private func validationText(for result: FieldResult) -> String {
        switch result.validationState {
        case .verified: return "Verified by User"
        case .autoAccepted: return "Automatically Accepted"
        case .needsReview: return "Needs Manual Verification"
        case .invalid: return "Failed Validation Rule Check"
        case .empty: return "No Value Extracted"
        case .edited: return "Corrected by User"
        }
    }
    
    private func expectedFormat(for type: FieldType) -> String {
        switch type {
        case .date: return "DD/MM/YYYY"
        case .phone: return "10 digits"
        case .email: return "RFC Compliant Email"
        case .pan: return "AAAAA9999A"
        case .ifsc: return "AAAA0123456"
        case .aadhaar: return "12 digits"
        case .boolean: return "Yes / No"
        default: return "Alphanumeric"
        }
    }
    
    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .bold()
                .foregroundColor(.primary)
        }
        .padding(.vertical, 2)
    }
    
    private func confidenceRow(label: String, score: Double, isBold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(isBold ? .caption : .caption2)
                .bold(isBold)
                .foregroundColor(isBold ? .primary : .secondary)
            Spacer()
            Text("\(Int(score * 100))%")
                .font(isBold ? .caption : .caption2)
                .bold(isBold)
                .foregroundColor(score >= 0.8 ? .green : (score >= 0.5 ? .orange : .red))
        }
        .padding(.vertical, 1)
    }
    
    // MARK: - Actions
    private func acceptField() {
        guard let result = selectedResult else { return }
        result.userConfirmed = true
        result.validationState = .verified
        try? modelContext.save()
        selectNextField()
    }
    
    private func rejectField() {
        guard let result = selectedResult else { return }
        result.validationState = .invalid
        try? modelContext.save()
        selectNextField()
    }
    
    private func selectNextField() {
        guard let page = selectedPage,
              let results = page.results?.sorted(by: { $0.boundingBoxY < $1.boundingBoxY }) else { return }
        if let currentIndex = results.firstIndex(where: { $0.id == selectedResult?.id }),
           currentIndex + 1 < results.count {
            selectedResult = results[currentIndex + 1]
        }
    }
    
    private func selectPreviousField() {
        guard let page = selectedPage,
              let results = page.results?.sorted(by: { $0.boundingBoxY < $1.boundingBoxY }) else { return }
        if let currentIndex = results.firstIndex(where: { $0.id == selectedResult?.id }),
           currentIndex - 1 >= 0 {
            selectedResult = results[currentIndex - 1]
        }
    }
    
    private func selectNextIssue() {
        guard let pages = session.pages?.sorted(by: { $0.pageNumber < $1.pageNumber }) else { return }
        
        var foundNext = false
        for page in pages {
            guard let results = page.results?.sorted(by: { $0.boundingBoxY < $1.boundingBoxY }) else { continue }
            for result in results {
                if foundNext {
                    if result.validationState == .invalid || result.validationState == .needsReview {
                        selectedPage = page
                        selectedResult = result
                        return
                    }
                }
                
                if result.id == selectedResult?.id {
                    foundNext = true
                }
            }
        }
        
        for page in pages {
            guard let results = page.results?.sorted(by: { $0.boundingBoxY < $1.boundingBoxY }) else { continue }
            for result in results {
                if result.validationState == .invalid || result.validationState == .needsReview {
                    selectedPage = page
                    selectedResult = result
                    return
                }
            }
        }
    }
}

// MARK: - Export Sheet Dashboard Tabbed View
struct ExportSheetView: View {
    var session: DocumentSession
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFormat = 0
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Format", selection: $selectedFormat) {
                    Text("Summary").tag(0)
                    Text("JSON").tag(1)
                    Text("ISO 20022").tag(2)
                    Text("ANSI X9").tag(3)
                }
                .pickerStyle(.segmented)
                .padding()
                
                Divider()
                
                TabView(selection: $selectedFormat) {
                    summaryTab
                        .tag(0)
                    
                    payloadTab(text: jsonPayload)
                        .tag(1)
                    
                    payloadTab(text: isoPayload)
                        .tag(2)
                    
                    payloadTab(text: ansiPayload)
                        .tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("Document Export Center")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var summaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Final Document Summary")
                    .font(.title3)
                    .bold()
                
                let stats = documentStats
                
                VStack(spacing: 12) {
                    summaryRow(label: "Document Classification", value: session.documentType ?? "Savings Account Opening")
                    summaryRow(label: "Total Pages", value: "\(session.pages?.count ?? 0)")
                    summaryRow(label: "Overall Accuracy Score", value: String(format: "%.1f%%", (session.qualityScore ?? 0.98) * 100))
                    summaryRow(label: "Required Fields Status", value: "\(stats.requiredVerified) / \(stats.requiredCount) Verified")
                    summaryRow(label: "Automatically Accepted", value: "\(stats.autoAccepted)")
                    summaryRow(label: "User Corrected", value: "\(stats.userCorrected)")
                    summaryRow(label: "Validation State", value: stats.isReady ? "Ready for Export ✔" : "Needs Human Review ⚠")
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("PROVENANCE AUDIT TRAIL")
                        .font(.caption2)
                        .bold()
                        .foregroundColor(.secondary)
                    
                    Text("Every extracted field is tracked with absolute provenance. Coordinates map dynamically to standard page structures using top-left coordinate grids. Export files adhere strictly to ISO 20022 pain.001.001.08 credit transfer guidelines and ANSI X9.100-187 payment standards.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineSpacing(4)
                }
                .padding()
                .background(Color(.systemGroupedBackground))
                .cornerRadius(8)
            }
            .padding()
        }
    }
    
    private func payloadTab(text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground))
    }
    
    private func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .bold()
        }
        .font(.subheadline)
    }
    
    private var jsonPayload: String {
        if let data = try? ExportEngine.shared.export(session: session),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
    
    private var isoPayload: String {
        return ExportEngine.shared.exportISO20022(session: session)
    }
    
    private var ansiPayload: String {
        return ExportEngine.shared.exportANSIX9(session: session)
    }
    
    private var documentStats: (requiredCount: Int, requiredVerified: Int, autoAccepted: Int, userCorrected: Int, isReady: Bool) {
        var reqCount = 0
        var reqVer = 0
        var autoAcc = 0
        var userCorr = 0
        var ready = true
        
        if let pages = session.pages {
            for page in pages {
                if let results = page.results {
                    for result in results {
                        let field = session.matchedTemplate?.fields?.first(where: { $0.id == result.fieldID })
                        let isRequired = field?.isRequired ?? true
                        
                        if isRequired {
                            reqCount += 1
                            if result.validationState == .verified || result.validationState == .autoAccepted {
                                reqVer += 1
                            } else {
                                ready = false
                            }
                        }
                        
                        if result.validationState == .autoAccepted {
                            autoAcc += 1
                        } else if result.validationState == .edited {
                            userCorr += 1
                        }
                        
                        if result.validationState == .invalid {
                            ready = false
                        }
                    }
                }
            }
        }
        
        return (reqCount, reqVer, autoAcc, userCorr, ready)
    }
}
