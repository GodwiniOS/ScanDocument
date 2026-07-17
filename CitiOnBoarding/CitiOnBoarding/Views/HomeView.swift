import SwiftUI
import SwiftData
import VisionKit
import UniformTypeIdentifiers
import PhotosUI
import PDFKit

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DocumentSession.importDate, order: .reverse) private var sessions: [DocumentSession]
    
    @State private var isShowingScanner = false
    @State private var isShowingFileImporter = false
    @State private var isShowingPhotosPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    
    // Template learning flow
    @State private var isShowingTemplateImporter = false
    @State private var templateReviewPDF: PDFDocument? = nil
    @State private var isShowingTemplateReview = false
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions) { session in
                    NavigationLink(destination: DocumentReviewWorkspace(session: session)) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(session.matchedTemplate?.name ?? "Session \(session.id.uuidString.prefix(8))")
                                    .font(.headline)
                                
                                if let qStatus = session.qualityStatus, qStatus == "POOR" {
                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                        Text("Rescan Suggested")
                                    }
                                    .font(.caption2)
                                    .bold()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.15))
                                    .foregroundColor(.red)
                                    .cornerRadius(6)
                                }
                            }
                            
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    if let docType = session.documentType {
                                        Text(docType)
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                            .bold()
                                    }
                                    Text(session.importDate.formatted())
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Text(session.status.rawValue.capitalized)
                                    .font(.caption)
                                    .bold()
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(statusColor(for: session.status).opacity(0.15))
                                    .foregroundColor(statusColor(for: session.status))
                                    .cornerRadius(6)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteSessions)
            }
            .navigationTitle("Citi Onboarding")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: {
                            isShowingScanner = true
                        }) {
                            Label("Scan with Camera", systemImage: "camera")
                        }
                        
                        Button(action: {
                            isShowingPhotosPicker = true
                        }) {
                            Label("Select from Photos", systemImage: "photo.on.rectangle")
                        }
                        
                        Button(action: {
                            isShowingFileImporter = true
                        }) {
                            Label("Import PDF or Image", systemImage: "doc.badge.plus")
                        }
                        
                        Divider()
                        
                        Button(action: {
                            isShowingTemplateImporter = true
                        }) {
                            Label("Register Template from PDF", systemImage: "rectangle.3.group.badge.plus")
                        }
                        

                    } label: {
                        Label("Add Document", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isShowingScanner) {
                ScannerView { scan in
                    isShowingScanner = false
                    if let scan = scan {
                        processScan(scan)
                    }
                } didCancelScanning: {
                    isShowingScanner = false
                } didFailWithError: { error in
                    isShowingScanner = false
                    print("Scanner error: \(error.localizedDescription)")
                }
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.pdf, .image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    processImportedFile(url)
                case .failure(let error):
                    print("File import failed: \(error.localizedDescription)")
                }
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
            .photosPicker(
                isPresented: $isShowingPhotosPicker,
                selection: $selectedPhotos,
                maxSelectionCount: 10,
                matching: .images
            )
            .onChange(of: selectedPhotos.count) { oldValue, newValue in
                if newValue > 0 {
                    loadPhotos(selectedPhotos)
                }
            }
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("No Documents")
                        } icon: {
                            Image("AppLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 88, height: 88)
                                .cornerRadius(18)
                                .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
                                .padding(.bottom, 8)
                        }
                    } description: {
                        Text("Scan a form, import a file, or pick from gallery to extract details.")
                    }
                }
            }
        }
    }
    
    private func statusColor(for status: SessionStatus) -> Color {
        switch status {
        case .imported: return .gray
        case .processing: return .blue
        case .needsReview: return .orange
        case .validated: return .green
        case .exported: return .purple
        }
    }
    
    private func processScan(_ scan: VisionKit.VNDocumentCameraScan) {
        var images: [UIImage] = []
        for i in 0..<scan.pageCount {
            images.append(scan.imageOfPage(at: i))
        }
        
        Task {
            do {
                _ = try await DocumentEngine.shared.processScan(images: images, modelContext: modelContext)
            } catch {
                print("Error processing scan: \(error.localizedDescription)")
            }
        }
    }
    
    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        
        Task {
            var images: [UIImage] = []
            for item in items {
                do {
                    if let data = try await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        images.append(image)
                    }
                } catch {
                    print("Failed to load picker image: \(error.localizedDescription)")
                }
            }
            
            if !images.isEmpty {
                do {
                    _ = try await DocumentEngine.shared.processScan(images: images, modelContext: modelContext)
                } catch {
                    print("Error processing photo gallery selection: \(error.localizedDescription)")
                }
            }
            
            // Reset selection picker state on MainActor
            await MainActor.run {
                selectedPhotos = []
            }
        }
    }
    
    private func processImportedFile(_ url: URL) {
        Task {
            do {
                if url.pathExtension.lowercased() == "pdf" {
                    _ = try await DocumentEngine.shared.processPDF(url: url, modelContext: modelContext)
                } else {
                    // Try parsing as image
                    if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                        _ = try await DocumentEngine.shared.processScan(images: [image], modelContext: modelContext)
                    } else {
                        print("Failed to load image from imported URL.")
                    }
                }
            } catch {
                print("Error processing imported file: \(error.localizedDescription)")
            }
        }
    }

    private func deleteSessions(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(sessions[index])
            }
        }
    }
}
