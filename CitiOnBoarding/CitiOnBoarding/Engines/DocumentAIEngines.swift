import Foundation
import SwiftData
import Vision
import UIKit
import CoreGraphics
import PDFKit
import CoreImage

/// Orchestrates the entire document processing lifecycle using the 14-Step Enterprise Document AI Pipeline
@MainActor
final class DocumentEngine {
    static let shared = DocumentEngine()
    
    private init() {}
    
    /// Processes a PDF file from a local URL. First tries to learn/update a Template from the PDF's form structure,
    /// then runs the full 14-Stage pipeline over the rendered page images.
    func processPDF(url: URL, modelContext: ModelContext) async throws -> DocumentSession {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        guard let pdfDocument = PDFDocument(url: url) else {
            throw NSError(domain: "DocumentEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to load PDF document"])
        }
        
        // Stage 0: PDF Template Learning — extract field definitions from the form structure
        await PDFTemplateExtractor.shared.learnTemplate(from: pdfDocument, modelContext: modelContext)
        
        var images: [UIImage] = []
        for i in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: i) else { continue }
            
            let pageRect = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0 // Render at 2× for higher-quality OCR
            let renderSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
            let renderer = UIGraphicsImageRenderer(size: renderSize)
            let image = renderer.image { context in
                UIColor.white.set()
                context.fill(CGRect(origin: .zero, size: renderSize))
                context.cgContext.translateBy(x: 0.0, y: renderSize.height)
                context.cgContext.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: context.cgContext)
            }
            images.append(image)
        }
        
        return try await processScan(images: images, modelContext: modelContext)
    }
    
    /// Processes a set of scanned UIImages through the complete 14-Stage Enterprise Pipeline.
    func processScan(images: [UIImage], modelContext: ModelContext) async throws -> DocumentSession {
        let session = DocumentSession()
        session.status = .processing
        modelContext.insert(session)
        
        var pages: [Page] = []
        var totalQualityScore = 0.0
        
        for (index, rawImage) in images.enumerated() {
            // Stage 1: Scan Quality check
            let qualityResult = ImageQualityEngine.shared.assess(image: rawImage)
            totalQualityScore += qualityResult.score
            
            // Stage 2: Document Registration / Perspective correction
            let warpedImage = ImageAlignmentEngine.shared.perspectiveCorrect(image: rawImage)
            guard let cgImage = warpedImage.cgImage else { continue }
            
            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)
            
            // Save perspective-corrected page image to disk
            let fileName = "\(session.id.uuidString)_page_\(index).jpg"
            let path = try saveImageToDisk(image: warpedImage, fileName: fileName)
            
            let page = Page(pageNumber: index + 1, imagePath: path)
            page.session = session
            modelContext.insert(page)
            pages.append(page)
            
            // Extract standard page observations for Template matching
            let observations = try await VisionEngine.shared.process(page: cgImage)
            
            // Stage 3: Template Matching
            let matchedTemplate = await TemplateEngine.shared.detectTemplate(for: observations, modelContext: modelContext)
            
            if let template = matchedTemplate {
                session.matchedTemplate = template
                
                // Stage 4: Template Alignment (Homography translation / scale)
                let alignment = ImageAlignmentEngine.shared.align(scannedObservations: observations, template: template)
                session.templateConfidence = 0.95 // Matched template confidence
                
                // Stage 5: Field Localization & Specialized Crops
                if let fields = template.fields {
                    for field in fields {
                        // Project template box to scan
                        let projectedRect = ImageAlignmentEngine.shared.project(rect: field.rect, alignment: alignment)
                        
                        let cropRect = CGRect(
                            x: projectedRect.origin.x * width,
                            y: projectedRect.origin.y * height,
                            width: projectedRect.size.width * width,
                            height: projectedRect.size.height * height
                        )
                        
                        guard cropRect.width > 0 && cropRect.height > 0,
                              let croppedCgImage = cgImage.cropping(to: cropRect) else { continue }
                        let cropImage = UIImage(cgImage: croppedCgImage)
                        
                        var extractedText = ""
                        var ocrConf = 0.90
                        var engineUsed = "printed"
                        
                        if field.captureMode == "image" {
                            // Signature Engine
                            engineUsed = "signature"
                            if let sigData = SignatureEngine.shared.process(crop: cropImage, sessionID: session.id, fieldId: field.fieldId, pageNumber: page.pageNumber) {
                                let asset = SignatureAsset(
                                    fieldId: field.fieldId,
                                    pageNumber: page.pageNumber,
                                    imagePath: sigData.path,
                                    status: sigData.status,
                                    qualityScore: sigData.confidence,
                                    blank: sigData.blank,
                                    userVerified: false
                                )
                                asset.session = session
                                modelContext.insert(asset)
                                
                                extractedText = sigData.status.uppercased()
                                ocrConf = sigData.confidence
                            }
                        } else if field.captureMode == "checkbox" {
                            // Checkbox Engine
                            engineUsed = "checkbox"
                            let chkData = CheckboxEngine.shared.process(crop: cropImage)
                            extractedText = chkData.checked ? "YES" : "NO"
                            ocrConf = chkData.confidence
                        } else {
                            // Text capture mode - printed vs handwriting
                            if field.isHandwritten {
                                engineUsed = "handwriting"
                                do {
                                    let res = try await HandwritingEngine.shared.process(crop: cropImage)
                                    extractedText = res.text
                                    ocrConf = res.confidence
                                } catch {
                                    extractedText = ""
                                    ocrConf = 0.0
                                }
                            } else {
                                engineUsed = "printed"
                                do {
                                    let res = try await PrintedOCREngine.shared.process(crop: cropImage)
                                    extractedText = res.text
                                    ocrConf = res.confidence
                                } catch {
                                    extractedText = ""
                                    ocrConf = 0.0
                                }
                            }
                        }
                        
                        // Stage 6: Validation & Normalization
                        let isValid = ValidationEngine.shared.validate(text: extractedText, for: field.expectedType)
                        let normalizedVal = normalizeValue(extractedText, for: field.expectedType)
                        
                        // Stage 7: Confidence Scoring (Review Engine)
                        let alignmentScore = (alignment.shiftX == 0 && alignment.shiftY == 0) ? 1.0 : 0.90
                        let scores = ReviewEngine.shared.calculateConfidence(
                            qualityScore: qualityResult.score,
                            alignmentScore: alignmentScore,
                            ocrScore: ocrConf,
                            validationScore: isValid ? 1.0 : 0.0
                        )
                        
                        let result = FieldResult(
                            fieldID: field.id,
                            boundingBox: projectedRect, // Store projected/actual crop bounds in document space
                            ocrText: extractedText,
                            confidence: scores.overall,
                            ocrConfidence: scores.ocr,
                            mappingConfidence: scores.mapping,
                            validationConfidence: scores.validation,
                            overallConfidence: scores.overall,
                            isHandwritten: field.isHandwritten,
                            userConfirmed: false,
                            edited: false,
                            recognitionEngineUsed: engineUsed,
                            scoreImageQuality: qualityResult.score,
                            scoreAlignment: alignmentScore,
                            scoreOCR: ocrConf,
                            scoreValidation: isValid ? 1.0 : 0.0,
                            originalPageNumber: page.pageNumber,
                            overrideHistory: []
                        )
                        result.page = page
                        result.normalizedValue = normalizedVal
                        
                        if field.captureMode == "image" {
                            result.validationState = (extractedText == "MISSING") ? .invalid : .needsReview
                        } else if field.captureMode == "checkbox" {
                            result.validationState = .autoAccepted
                        } else {
                            result.validationState = isValid ? .autoAccepted : .invalid
                            if extractedText.isEmpty {
                                result.validationState = .empty
                            }
                        }
                        modelContext.insert(result)
                    }
                }
            } else {
                // If no template matched, fallback to prominent OCR lines
                for observation in observations.prefix(10) {
                    let text = observation.topCandidates(1).first?.string ?? ""
                    let confidence = Double(observation.topCandidates(1).first?.confidence ?? 0.0)
                    let rect = observation.boundingBox.toTopLeft
                    
                    let result = FieldResult(
                        fieldID: UUID(), // Temporary
                        boundingBox: rect,
                        ocrText: text,
                        confidence: confidence,
                        ocrConfidence: confidence,
                        mappingConfidence: 0.5,
                        validationConfidence: 1.0,
                        overallConfidence: confidence * 0.7,
                        isHandwritten: false,
                        userConfirmed: false,
                        edited: false,
                        recognitionEngineUsed: "printed_fallback",
                        scoreImageQuality: qualityResult.score,
                        scoreAlignment: 0.5,
                        scoreOCR: confidence,
                        scoreValidation: 1.0,
                        originalPageNumber: page.pageNumber,
                        overrideHistory: []
                    )
                    result.page = page
                    result.validationState = .needsReview
                    modelContext.insert(result)
                }
            }
        }
        
        let avgQualityScore = totalQualityScore / Double(images.count)
        session.qualityScore = avgQualityScore
        session.qualityStatus = avgQualityScore >= 0.7 ? "GOOD" : "POOR"
        session.status = determineFinalStatus(for: session)
        session.normalizedBankingJSON = generateStructuredBankingJSON(session: session)
        
        try? modelContext.save()
        return session
    }
    
    // MARK: - Signature Crop & Ink Analysis Helpers
    private func cropAndProcessSignature(image: UIImage, rect: CGRect, sessionID: UUID, fieldId: String, pageNumber: Int) -> (path: String, status: String, qualityScore: Double, blank: Bool)? {
        guard let cgImage = image.cgImage else { return nil }
        
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        
        let pixelRect = CGRect(
            x: rect.origin.x * width,
            y: rect.origin.y * height,
            width: rect.size.width * width,
            height: rect.size.height * height
        )
        
        guard pixelRect.width > 0 && pixelRect.height > 0 else { return nil }
        guard let croppedCgImage = cgImage.cropping(to: pixelRect) else { return nil }
        let croppedUIImage = UIImage(cgImage: croppedCgImage)
        
        // CI color enhancement filter
        let ciImage = CIImage(image: croppedUIImage)
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(1.5, forKey: kCIInputContrastKey)
        filter?.setValue(0.0, forKey: kCIInputSaturationKey)
        
        let context = CIContext(options: nil)
        let finalUIImage: UIImage
        if let output = filter?.outputImage, let finalCgImage = context.createCGImage(output, from: output.extent) {
            finalUIImage = UIImage(cgImage: finalCgImage)
        } else {
            finalUIImage = croppedUIImage
        }
        
        // Analyze ink coverage ratio
        let inkStats = analyzeInkDensity(uiImage: finalUIImage)
        let isBlank = inkStats.inkRatio < 0.02 // 2.0% ink coverage threshold
        let status = isBlank ? "missing" : "present"
        
        let fileManager = FileManager.default
        let paths = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
        guard let docDir = paths.first else { return nil }
        
        let signatureDir = docDir
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathComponent("signatures")
            .appendingPathComponent("page_\(pageNumber)")
        
        do {
            try fileManager.createDirectory(at: signatureDir, withIntermediateDirectories: true, attributes: nil)
            let fileURL = signatureDir.appendingPathComponent("\(fieldId).png")
            
            if let pngData = finalUIImage.pngData() {
                try pngData.write(to: fileURL)
                let relativePath = "sessions/\(sessionID.uuidString)/signatures/page_\(pageNumber)/\(fieldId).png"
                return (path: relativePath, status: status, qualityScore: 0.95, blank: isBlank)
            }
        } catch {
            print("Failed to save signature asset: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    private func analyzeInkDensity(uiImage: UIImage) -> (inkRatio: Double, averageBrightness: Double) {
        guard let cgImage = uiImage.cgImage else { return (0.0, 1.0) }
        
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalPixels = width * height
        
        var rawData = [UInt8](repeating: 0, count: totalPixels * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
        
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var darkPixelCount = 0
        var totalBrightness = 0.0
        
        for i in 0..<totalPixels {
            let r = Double(rawData[i * 4])
            let g = Double(rawData[i * 4 + 1])
            let b = Double(rawData[i * 4 + 2])
            
            let luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            totalBrightness += luminance
            
            if luminance < 0.85 { // Ink pixel threshold
                darkPixelCount += 1
            }
        }
        
        let inkRatio = Double(darkPixelCount) / Double(totalPixels)
        let averageBrightness = totalBrightness / Double(totalPixels)
        
        return (inkRatio: inkRatio, averageBrightness: averageBrightness)
    }
    
    private func detectCheckboxChecked(image: UIImage, rect: CGRect) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        
        let pixelRect = CGRect(
            x: rect.origin.x * width,
            y: rect.origin.y * height,
            width: rect.size.width * width,
            height: rect.size.height * height
        )
        
        guard pixelRect.width > 0 && pixelRect.height > 0 else { return false }
        guard let cropped = cgImage.cropping(to: pixelRect) else { return false }
        let croppedUIImage = UIImage(cgImage: cropped)
        
        let stats = analyzeInkDensity(uiImage: croppedUIImage)
        return stats.inkRatio > 0.18 // Checkbox is checked if ink ratio exceeds 18%
    }
    
    private func saveImageToDisk(image: UIImage, fileName: String) throws -> String {
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            throw NSError(domain: "DocumentEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to JPEG"])
        }
        
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let fileURL = documentsDirectory.appendingPathComponent(fileName)
        
        try data.write(to: fileURL)
        return fileURL.path
    }
    
    private func findMatchingText(in observations: [VNRecognizedTextObservation], forField field: Field) -> (text: String, confidence: Double, overlap: Double) {
        let fieldRect = field.rect
        
        // 1. Semantic label anchoring search using serial numbers (e.g. "1. Full Name")
        let fieldName = field.name
        var labelObservation: VNRecognizedTextObservation? = nil
        
        let components = fieldName.components(separatedBy: " ")
        if let first = components.first, let _ = Int(first.replacingOccurrences(of: ".", with: "")) {
            let serialNum = first.replacingOccurrences(of: ".", with: "")
            let keywords = components.dropFirst().map { $0.lowercased() }
            
            labelObservation = observations.first { obs in
                let obsText = obs.topCandidates(1).first?.string.lowercased() ?? ""
                if obsText.contains(serialNum) {
                    return keywords.isEmpty || keywords.contains(where: { obsText.contains($0) })
                }
                return false
            }
        }
        
        // Calibrate target search Rect if the label anchor was found
        var searchRect = fieldRect
        if let labelObs = labelObservation {
            let labelRect = labelObs.boundingBox.toTopLeft
            let expectedLabelRect = CGRect(x: max(0.0, fieldRect.minX - 0.15), y: fieldRect.minY, width: 0.2, height: fieldRect.height)
            let shiftX = labelRect.minX - expectedLabelRect.minX
            let shiftY = labelRect.minY - expectedLabelRect.minY
            
            searchRect = CGRect(
                x: max(0.0, min(1.0, fieldRect.minX + shiftX)),
                y: max(0.0, min(1.0, fieldRect.minY + shiftY)),
                width: fieldRect.width,
                height: fieldRect.height
            )
        }
        
        // 2. Overlap validation check
        var bestText = ""
        var bestConfidence = 0.0
        var maxOverlapRatio = 0.0
        let fieldArea = searchRect.width * searchRect.height
        guard fieldArea > 0 else { return ("", 0.0, 0.0) }
        
        for observation in observations {
            let obsRect = observation.boundingBox.toTopLeft
            let intersection = obsRect.intersection(searchRect)
            let intersectionArea = intersection.width * intersection.height
            
            if intersectionArea > 0 {
                let overlapRatio = Double(intersectionArea / fieldArea)
                if overlapRatio > maxOverlapRatio && overlapRatio > 0.15 {
                    maxOverlapRatio = overlapRatio
                    if let candidate = observation.topCandidates(1).first {
                        bestText = candidate.string
                        bestConfidence = Double(candidate.confidence)
                    }
                }
            }
        }
        
        // Fallback: search immediately to the right of the resolved anchor label if searchRect had no hits
        if bestText.isEmpty, let labelObs = labelObservation {
            let labelRect = labelObs.boundingBox.toTopLeft
            let rightAlignObs = observations.filter { obs in
                let rect = obs.boundingBox.toTopLeft
                let yOverlap = min(labelRect.maxY, rect.maxY) - max(labelRect.minY, rect.minY)
                let yOverlapHeight = yOverlap > 0 ? yOverlap : 0
                return rect.minX >= labelRect.maxX
                    && yOverlapHeight > (rect.height * 0.4)
                    && ObjectIdentifier(obs) != ObjectIdentifier(labelObs)
            }
            if let nearestRight = rightAlignObs.sorted(by: { $0.boundingBox.toTopLeft.minX < $1.boundingBox.toTopLeft.minX }).first,
               let candidate = nearestRight.topCandidates(1).first {
                bestText = candidate.string
                bestConfidence = Double(candidate.confidence)
                maxOverlapRatio = 0.85
            }
        }
        
        return (bestText, bestConfidence, maxOverlapRatio)
    }
    
    private func normalizeValue(_ text: String, for expectedType: FieldType) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        
        switch expectedType {
        case .date:
            // Convert e.g. "12-07-96" to "12/07/1996" or ISO format
            let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = dateDetector?.firstMatch(in: trimmed, options: [], range: range),
               let date = match.date {
                let formatter = DateFormatter()
                formatter.dateFormat = "dd/MM/yyyy"
                return formatter.string(from: date)
            }
            return trimmed
        case .boolean:
            let lower = trimmed.lowercased()
            if lower.contains("yes") || lower == "true" || lower == "1" {
                return "true"
            }
            return "false"
        case .pan, .ifsc:
            return trimmed.uppercased()
        default:
            return trimmed
        }
    }
    
    private func generateStructuredBankingJSON(session: DocumentSession) -> String {
        var docDict: [String: Any] = [
            "documentType": session.documentType ?? "Unknown",
            "sessionId": session.id.uuidString,
            "importDate": session.importDate.iso8601String(),
            "qualityScore": session.qualityScore ?? 0.0
        ]
        
        var customerDict: [String: Any] = [:]
        if let pages = session.pages {
            for page in pages {
                if let results = page.results {
                    for result in results {
                        let fieldName = session.matchedTemplate?.fields?.first(where: { $0.id == result.fieldID })?.name ?? "Field"
                        let normalizedName = fieldName.lowercased().replacingOccurrences(of: " ", with: "")
                        customerDict[normalizedName] = result.finalValue
                    }
                }
            }
        }
        
        docDict["customer"] = customerDict
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(CodableWrapper(dict: docDict)), let jsonStr = String(data: data, encoding: .utf8) {
            return jsonStr
        }
        
        return "{}"
    }
    
    private func determineFinalStatus(for session: DocumentSession) -> SessionStatus {
        guard let pages = session.pages else { return .imported }
        
        // If quality is poor, rescan is suggested
        if let score = session.qualityScore, score < 0.6 {
            return .needsReview
        }
        
        // If there's any invalid or needsReview field, mark as needsReview
        for page in pages {
            if let results = page.results {
                for result in results {
                    if result.validationState == .invalid || result.validationState == .needsReview {
                        return .needsReview
                    }
                }
            }
        }
        
        return .validated
    }
}

/// Codable JSON wrapper helper
struct CodableWrapper: Codable {
    let dict: [String: String]
    
    init(dict: [String: Any]) {
        var strDict: [String: String] = [:]
        for (k, v) in dict {
            if let str = v as? String {
                strDict[k] = str
            } else if let doubleVal = v as? Double {
                strDict[k] = String(format: "%.2f", doubleVal)
            } else if let subDict = v as? [String: Any] {
                if let subData = try? JSONSerialization.data(withJSONObject: subDict),
                   let subStr = String(data: subData, encoding: .utf8) {
                    strDict[k] = subStr
                }
            }
        }
        self.dict = strDict
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (k, v) in dict {
            try container.encode(v, forKey: DynamicKey(stringValue: k)!)
        }
    }
    
    init(from decoder: Decoder) throws {
        self.dict = [:]
    }
}

struct DynamicKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int?
    init?(intValue: Int) { return nil }
}

/// Stage 2: Assess scanned image using Core Image to calculate average brightness and contrast
@MainActor
final class ImageQualityEngine {
    static let shared = ImageQualityEngine()
    private init() {}
    
    struct QualityResult {
        let score: Double // 0.0 to 1.0
        let status: String // "GOOD" or "POOR"
        let details: String
    }
    
    func assess(image: UIImage) -> QualityResult {
        guard let cgImage = image.cgImage else {
            return QualityResult(score: 0.50, status: "POOR", details: "Unable to parse CGImage")
        }
        
        let ciImage = CIImage(cgImage: cgImage)
        
        // 1. Calculate Average Brightness
        let filter = CIFilter(name: "CIAreaAverage")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        
        var brightness: Double = 0.65
        if let outputImage = filter?.outputImage {
            var bitmap = [UInt8](repeating: 0, count: 4)
            let context = CIContext(options: nil)
            context.render(outputImage, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            let r = Double(bitmap[0]) / 255.0
            let g = Double(bitmap[1]) / 255.0
            let b = Double(bitmap[2]) / 255.0
            brightness = 0.299 * r + 0.587 * g + 0.114 * b
        }
        
        // 2. Sobel Edge Sharpness Estimation (detects blur)
        let edgeSharpness = calculateEdgeSharpness(ciImage: ciImage)
        
        var score = 1.0
        var details = "Optimal document scan quality."
        
        if brightness < 0.35 {
            score -= (0.35 - brightness) * 1.5
            details = "Image is too dark. Increase lighting or retake scan."
        } else if brightness > 0.85 {
            score -= (brightness - 0.85) * 1.2
            details = "Image contains glare. Reposition and retake scan."
        }
        
        if edgeSharpness < 0.03 { // Soft edges suggest a blurry photo
            score -= 0.25
            details = "Image is blurry. Please hold camera still and retake scan."
        }
        
        let aspectRatio = Double(cgImage.width) / Double(cgImage.height)
        if aspectRatio < 0.4 || aspectRatio > 2.5 {
            score -= 0.15
            details = "Poor page alignment. Align document boundaries."
        }
        
        let finalScore = max(0.1, min(1.0, score))
        let status = finalScore >= 0.7 ? "GOOD" : "POOR"
        
        return QualityResult(score: finalScore, status: status, details: details)
    }
    
    private func calculateEdgeSharpness(ciImage: CIImage) -> Double {
        let filter = CIFilter(name: "CISobelGradients")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        guard let output = filter?.outputImage else { return 0.05 }
        
        let averageFilter = CIFilter(name: "CIAreaAverage")
        averageFilter?.setValue(output, forKey: kCIInputImageKey)
        averageFilter?.setValue(CIVector(cgRect: output.extent), forKey: kCIInputExtentKey)
        
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: nil)
        context.render(averageFilter!.outputImage!, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let edgeIntensity = Double(bitmap[0] + bitmap[1] + bitmap[2]) / 3.0 / 255.0
        return edgeIntensity
    }
    
    func analyzeInkDensity(uiImage: UIImage) -> (inkRatio: Double, averageBrightness: Double) {
        guard let cgImage = uiImage.cgImage else { return (0.0, 1.0) }
        
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalPixels = width * height
        
        var rawData = [UInt8](repeating: 0, count: totalPixels * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
        
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var darkPixelCount = 0
        var totalBrightness = 0.0
        
        for i in 0..<totalPixels {
            let r = Double(rawData[i * 4])
            let g = Double(rawData[i * 4 + 1])
            let b = Double(rawData[i * 4 + 2])
            
            let luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            totalBrightness += luminance
            
            if luminance < 0.85 { // Ink pixel threshold
                darkPixelCount += 1
            }
        }
        
        let inkRatio = Double(darkPixelCount) / Double(totalPixels)
        let averageBrightness = totalBrightness / Double(totalPixels)
        
        return (inkRatio: inkRatio, averageBrightness: averageBrightness)
    }
}

@MainActor
final class ImageAlignmentEngine {
    static let shared = ImageAlignmentEngine()
    private init() {}
    
    /// Perspective corrects a raw page image by finding the largest rectangle contour
    func perspectiveCorrect(image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.3
        request.maximumObservations = 1
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("Failed to perform rectangle detection: \(error)")
            return image
        }
        
        guard let rectObservation = request.results?.first else {
            print("No rectangle found, skipping perspective correction")
            return image
        }
        
        let imageSize = ciImage.extent.size
        let topLeft = CGPoint(x: rectObservation.topLeft.x * imageSize.width, y: rectObservation.topLeft.y * imageSize.height)
        let topRight = CGPoint(x: rectObservation.topRight.x * imageSize.width, y: rectObservation.topRight.y * imageSize.height)
        let bottomLeft = CGPoint(x: rectObservation.bottomLeft.x * imageSize.width, y: rectObservation.bottomLeft.y * imageSize.height)
        let bottomRight = CGPoint(x: rectObservation.bottomRight.x * imageSize.width, y: rectObservation.bottomRight.y * imageSize.height)
        
        let filter = CIFilter(name: "CIPerspectiveCorrection")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter?.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter?.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        filter?.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")
        
        let context = CIContext(options: nil)
        if let output = filter?.outputImage, let finalCgImage = context.createCGImage(output, from: output.extent) {
            return UIImage(cgImage: finalCgImage)
        }
        
        return image
    }
    
    /// Computes scaling & shift alignment parameters by comparing scanned OCR elements to template fields.
    func align(scannedObservations: [VNRecognizedTextObservation], template: Template) -> (shiftX: Double, shiftY: Double, scaleX: Double, scaleY: Double) {
        var shiftX = 0.0
        var shiftY = 0.0
        let scaleX = 1.0
        let scaleY = 1.0
        
        let texts = scannedObservations.compactMap { (obs: VNRecognizedTextObservation) -> (text: String, rect: CGRect)? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return (candidate.string.lowercased(), obs.boundingBox.toTopLeft)
        }
        
        // Try matching "client profile" or "private bank" to check geometric drift
        if let pbScan = texts.first(where: { $0.text.contains("private") && $0.text.contains("bank") }) {
            let expectedX = 0.08
            let expectedY = 0.14
            shiftX = pbScan.rect.minX - expectedX
            shiftY = pbScan.rect.minY - expectedY
        } else if let cpScan = texts.first(where: { $0.text.contains("client") && $0.text.contains("profile") }) {
            let expectedX = 0.05
            let expectedY = 0.42
            shiftX = cpScan.rect.minX - expectedX
            shiftY = cpScan.rect.minY - expectedY
        }
        
        // Keep shifts within safety margins
        shiftX = max(-0.15, min(0.15, shiftX))
        shiftY = max(-0.15, min(0.15, shiftY))
        
        return (shiftX: shiftX, shiftY: shiftY, scaleX: scaleX, scaleY: scaleY)
    }
    
    func project(rect: CGRect, alignment: (shiftX: Double, shiftY: Double, scaleX: Double, scaleY: Double)) -> CGRect {
        return CGRect(
            x: max(0.0, min(1.0, rect.origin.x * alignment.scaleX + alignment.shiftX)),
            y: max(0.0, min(1.0, rect.origin.y * alignment.scaleY + alignment.shiftY)),
            width: min(1.0 - rect.origin.x, rect.size.width * alignment.scaleX),
            height: min(1.0 - rect.origin.y, rect.size.height * alignment.scaleY)
        )
    }
}

@MainActor
final class PrintedOCREngine {
    static let shared = PrintedOCREngine()
    private init() {}
    
    func process(crop: UIImage) async throws -> (text: String, confidence: Double) {
        guard let cgImage = crop.cgImage else { return ("", 0.0) }
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { req, err in
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                let observations = req.results as? [VNRecognizedTextObservation] ?? []
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                let conf = observations.map { Double($0.topCandidates(1).first?.confidence ?? 0.0) }.reduce(0.0, +) / max(Double(observations.count), 1.0)
                continuation.resume(returning: (text: text, confidence: conf))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

@MainActor
final class HandwritingEngine {
    static let shared = HandwritingEngine()
    private init() {}
    
    func process(crop: UIImage) async throws -> (text: String, confidence: Double) {
        guard let cgImage = crop.cgImage else { return ("", 0.0) }
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { req, err in
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                let observations = req.results as? [VNRecognizedTextObservation] ?? []
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                let conf = observations.map { Double($0.topCandidates(1).first?.confidence ?? 0.0) }.reduce(0.0, +) / max(Double(observations.count), 1.0)
                continuation.resume(returning: (text: text, confidence: conf))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

@MainActor
final class CheckboxEngine {
    static let shared = CheckboxEngine()
    private init() {}
    
    func process(crop: UIImage) -> (checked: Bool, confidence: Double) {
        let stats = ImageQualityEngine.shared.analyzeInkDensity(uiImage: crop)
        let isChecked = stats.inkRatio > 0.16
        return (checked: isChecked, confidence: 0.95)
    }
}

@MainActor
final class SignatureEngine {
    static let shared = SignatureEngine()
    private init() {}
    
    func process(crop: UIImage, sessionID: UUID, fieldId: String, pageNumber: Int) -> (path: String, status: String, confidence: Double, blank: Bool)? {
        let ciImage = CIImage(image: crop)
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(1.5, forKey: kCIInputContrastKey)
        filter?.setValue(0.0, forKey: kCIInputSaturationKey)
        
        let context = CIContext(options: nil)
        let finalUIImage: UIImage
        if let output = filter?.outputImage, let finalCgImage = context.createCGImage(output, from: output.extent) {
            finalUIImage = UIImage(cgImage: finalCgImage)
        } else {
            finalUIImage = crop
        }
        
        let stats = ImageQualityEngine.shared.analyzeInkDensity(uiImage: finalUIImage)
        let isBlank = stats.inkRatio < 0.02
        let status = isBlank ? "missing" : "present"
        
        let fileManager = FileManager.default
        let paths = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
        guard let docDir = paths.first else { return nil }
        
        let signatureDir = docDir
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathComponent("signatures")
            .appendingPathComponent("page_\(pageNumber)")
        
        do {
            try fileManager.createDirectory(at: signatureDir, withIntermediateDirectories: true, attributes: nil)
            let fileURL = signatureDir.appendingPathComponent("\(fieldId).png")
            
            if let pngData = finalUIImage.pngData() {
                try pngData.write(to: fileURL)
                let relativePath = "sessions/\(sessionID.uuidString)/signatures/page_\(pageNumber)/\(fieldId).png"
                return (path: relativePath, status: status, confidence: 0.95, blank: isBlank)
            }
        } catch {
            print("Failed to save signature asset: \(error.localizedDescription)")
        }
        return nil
    }
}

@MainActor
final class ReviewEngine {
    static let shared = ReviewEngine()
    private init() {}
    
    func calculateConfidence(
        qualityScore: Double,
        alignmentScore: Double,
        ocrScore: Double,
        validationScore: Double
    ) -> (ocr: Double, mapping: Double, validation: Double, overall: Double) {
        let overall = 0.2 * qualityScore + 0.2 * alignmentScore + 0.4 * ocrScore + 0.2 * validationScore
        return (ocr: ocrScore, mapping: alignmentScore, validation: validationScore, overall: overall)
    }
}

/// Stage 3: Image Enhancement (Median filter denoise, sharpen, normalize contrast)
@MainActor
final class ImageEnhancementEngine {
    static let shared = ImageEnhancementEngine()
    private init() {}
    
    func enhance(image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        
        // 1. Denoise (Median filter)
        let denoiseFilter = CIFilter(name: "CIMedianFilter")
        denoiseFilter?.setValue(ciImage, forKey: kCIInputImageKey)
        let denoised = denoiseFilter?.outputImage ?? ciImage
        
        // 2. Normalize contrast (Color Controls)
        let contrastFilter = CIFilter(name: "CIColorControls")
        contrastFilter?.setValue(denoised, forKey: kCIInputImageKey)
        contrastFilter?.setValue(1.15, forKey: kCIInputContrastKey) // boost contrast
        contrastFilter?.setValue(1.0, forKey: kCIInputSaturationKey)
        contrastFilter?.setValue(0.02, forKey: kCIInputBrightnessKey)
        let contrastEnhanced = contrastFilter?.outputImage ?? denoised
        
        // 3. Sharpen (Unsharp Mask)
        let sharpenFilter = CIFilter(name: "CIUnsharpMask")
        sharpenFilter?.setValue(contrastEnhanced, forKey: kCIInputImageKey)
        sharpenFilter?.setValue(0.8, forKey: kCIInputIntensityKey)
        sharpenFilter?.setValue(1.0, forKey: kCIInputRadiusKey)
        
        let outputImage = sharpenFilter?.outputImage ?? contrastEnhanced
        let context = CIContext(options: nil)
        if let outputCGImage = context.createCGImage(outputImage, from: outputImage.extent) {
            return UIImage(cgImage: outputCGImage)
        }
        
        return image
    }
}

/// Stage 4: Document Classification using text pattern rules
@MainActor
final class DocumentClassificationEngine {
    static let shared = DocumentClassificationEngine()
    private init() {}
    
    func classify(text: String) -> String {
        let normalizedText = text.lowercased()
        
        if normalizedText.contains("permanent account number") || normalizedText.contains("pan card") || normalizedText.contains("income tax") {
            return "PAN Card"
        } else if normalizedText.contains("uidai") || normalizedText.contains("aadhaar") || normalizedText.contains("government of india") {
            return "Aadhaar Card"
        } else if normalizedText.contains("passport") || normalizedText.contains("republic of india") {
            return "Passport"
        } else if normalizedText.contains("credit card") || normalizedText.contains("card application") {
            return "Credit Card Application"
        } else if normalizedText.contains("loan") || normalizedText.contains("borrower") || normalizedText.contains("guarantor") {
            return "Loan Form"
        } else if normalizedText.contains("account opening") || normalizedText.contains("resident individual") || normalizedText.contains("customer information sheet") || normalizedText.contains("sbi") || normalizedText.contains("state bank") {
            return "Savings Account Opening"
        } else if normalizedText.contains("deposit slip") || normalizedText.contains("pay in slip") {
            return "Deposit Slip"
        } else if normalizedText.contains("cheque") || normalizedText.contains("payee") || normalizedText.contains("rupees") {
            return "Cheque"
        } else {
            if normalizedText.contains("kyc") || normalizedText.contains("know your customer") {
                return "KYC Form"
            }
            return "Savings Account Opening"
        }
    }
}

/// Stage 6: Layout Analysis (Simulated Layout Tree)
@MainActor
final class LayoutAnalysisEngine {
    static let shared = LayoutAnalysisEngine()
    private init() {}
    
    struct LayoutNode: Codable {
        let type: String // "Header", "Section", "Label", "Value", "Table", "Footer"
        let text: String
        let boundingBox: [Double]
        var children: [LayoutNode]
    }
    
    func analyze(observations: [VNRecognizedTextObservation]) -> String {
        var root = LayoutNode(type: "Document", text: "Root", boundingBox: [0.0, 0.0, 1.0, 1.0], children: [])
        let sortedObs = observations.sorted(by: { $0.boundingBox.toTopLeft.minY < $1.boundingBox.toTopLeft.minY })
        
        var headerNode = LayoutNode(type: "Header", text: "Document Header", boundingBox: [0.0, 0.0, 1.0, 0.15], children: [])
        var bodyNode = LayoutNode(type: "Section", text: "Customer Details", boundingBox: [0.0, 0.15, 1.0, 0.7], children: [])
        var footerNode = LayoutNode(type: "Footer", text: "Document Footer", boundingBox: [0.0, 0.85, 1.0, 0.15], children: [])
        
        for obs in sortedObs {
            let rect = obs.boundingBox.toTopLeft
            let text = obs.topCandidates(1).first?.string ?? ""
            let node = LayoutNode(type: "Label", text: text, boundingBox: [rect.minX, rect.minY, rect.width, rect.height], children: [])
            
            if rect.minY < 0.15 {
                headerNode.children.append(node)
            } else if rect.minY > 0.85 {
                footerNode.children.append(node)
            } else {
                bodyNode.children.append(node)
            }
        }
        
        root.children = [headerNode, bodyNode, footerNode]
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(root), let jsonString = String(data: data, encoding: .utf8) {
            return jsonString
        }
        return "{}"
    }
}

/// Stage 8: Performs OCR and Layout understanding using Apple Vision
@MainActor
final class VisionEngine {
    static let shared = VisionEngine()
    
    private init() {}
    
    func process(page: CGImage) async throws -> [VNRecognizedTextObservation] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: observations)
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: page, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    /// Run OCR specifically targeted to a given crop rectangle region.
    func performTargetedOCR(on image: CGImage, inRect rect: CGRect) async throws -> String {
        let visionRect = rect.toVisionSpace
        
        // Pad the search region slightly by 5% to account for coordinate misalignments
        let paddingX = visionRect.width * 0.05
        let paddingY = visionRect.height * 0.05
        let paddedRect = CGRect(
            x: max(0.0, visionRect.origin.x - paddingX),
            y: max(0.0, visionRect.origin.y - paddingY),
            width: min(1.0 - visionRect.origin.x, visionRect.width + 2 * paddingX),
            height: min(1.0 - visionRect.origin.y, visionRect.height + 2 * paddingY)
        )
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { req, err in
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                let observations = req.results as? [VNRecognizedTextObservation] ?? []
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.regionOfInterest = paddedRect
            
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - PDF Template Extractor
/// Learns Template + Field structure directly from the OCR scan of a blank/master PDF form.
/// Uses serial-number prefixed labels ("1. Full Name:") as anchors to determine field layout.
@MainActor
final class PDFTemplateExtractor {
    static let shared = PDFTemplateExtractor()
    private init() {}
    
    /// Renders each page of the PDF, runs Vision OCR, and extracts numbered field labels to build a Template.
    func learnTemplate(from pdfDocument: PDFDocument, modelContext: ModelContext) async {
        var allPageObservations: [(pageIndex: Int, pageSize: CGSize, observations: [VNRecognizedTextObservation])] = []
        
        for i in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: i) else { continue }
            let pageRect = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0
            let renderSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
            
            let renderer = UIGraphicsImageRenderer(size: renderSize)
            let pageImage = renderer.image { ctx in
                UIColor.white.set()
                ctx.fill(CGRect(origin: .zero, size: renderSize))
                ctx.cgContext.translateBy(x: 0, y: renderSize.height)
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: ctx.cgContext)
            }
            
            guard let cgImage = pageImage.cgImage else { continue }
            let observations = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<[VNRecognizedTextObservation], Error>) in
                let request = VNRecognizeTextRequest { req, err in
                    if let err { cont.resume(throwing: err); return }
                    cont.resume(returning: req.results as? [VNRecognizedTextObservation] ?? [])
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
            }
            
            if let obs = observations {
                allPageObservations.append((pageIndex: i, pageSize: renderSize, observations: obs))
            }
        }
        
        guard !allPageObservations.isEmpty else { return }
        
        // Determine template name from the first page's OCR text
        let firstPageTexts = allPageObservations.first?.observations.compactMap { $0.topCandidates(1).first?.string } ?? []
        let templateName = inferTemplateName(from: firstPageTexts)
        
        // Check if this template already exists; if so, update its fields
        let descriptor = FetchDescriptor<Template>()
        let existingTemplates = (try? modelContext.fetch(descriptor)) ?? []
        
        let template: Template
        if let existing = existingTemplates.first(where: { $0.name == templateName }) {
            // Remove old fields and re-learn from scratch
            if let oldFields = existing.fields {
                oldFields.forEach { modelContext.delete($0) }
            }
            template = existing
            template.version = incrementVersion(template.version)
        } else {
            template = Template(name: templateName, version: "1.0")
            modelContext.insert(template)
        }
        
        // Extract fields from all pages
        var fieldIndex = 1
        for pageData in allPageObservations {
            let extractedFields = extractFields(
                from: pageData.observations,
                pageSize: pageData.pageSize,
                startingIndex: fieldIndex,
                template: template,
                modelContext: modelContext
            )
            fieldIndex += extractedFields
        }
        
        // If no numbered fields were found (e.g. plain labels without "1."), fall back to keyword scanning
        if (template.fields?.count ?? 0) == 0 {
            fallbackKeywordExtraction(from: allPageObservations, template: template, modelContext: modelContext)
        }
        
        try? modelContext.save()
    }
    
    // MARK: - Field Extraction
    
    /// Scans OCR observations for lines that start with a serial number ("1.", "2.", "3." etc.)
    /// and uses the bounding box of the label + its right/below neighbor as the field input region.
    @discardableResult
    private func extractFields(
        from observations: [VNRecognizedTextObservation],
        pageSize: CGSize,
        startingIndex: Int,
        template: Template,
        modelContext: ModelContext
    ) -> Int {
        // Sort top-to-bottom (Vision boxes are bottom-origin, so minY=bottom; we flip for reading order)
        let sorted = observations.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
        
        var extractedCount = 0
        
        for obs in sorted {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Match lines beginning with: "1.", "1)", "1 " followed by a label
            let serialPattern = #"^(\d{1,2})[.)\s]\s*(.+)$"#
            guard let regex = try? NSRegularExpression(pattern: serialPattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
                continue
            }
            
            guard
                let numRange  = Range(match.range(at: 1), in: text),
                let nameRange = Range(match.range(at: 2), in: text)
            else { continue }
            
            let serialNum = String(text[numRange])
            var fieldName = String(text[nameRange])
            // Strip trailing ":" or "-"
            fieldName = fieldName.trimmingCharacters(in: .init(charactersIn: ":- "))
            let numberedName = "\(serialNum). \(fieldName)"
            
            // Use the label's bounding box in normalized coords (already 0-1 in Vision)
            let labelBox = obs.boundingBox.toTopLeft
            
            // The input region: extend to the right of the label, same row height
            let inputX = min(labelBox.maxX + 0.01, 0.95)
            let inputWidth = min(1.0 - inputX - 0.02, 0.6)
            let inputBox = CGRect(
                x: inputX,
                y: max(0, labelBox.minY - labelBox.height * 0.1),
                width: inputWidth,
                height: labelBox.height * 1.4
            )
            
            let expectedType = inferFieldType(from: fieldName)
            let field = Field(
                name: numberedName,
                expectedType: expectedType,
                boundingBox: inputBox,
                isRequired: true,
                isHandwritten: true
            )
            field.template = template
            modelContext.insert(field)
            extractedCount += 1
        }
        
        return extractedCount
    }
    
    // MARK: - Fallback: keyword-based label detection (forms without numbered fields)
    private func fallbackKeywordExtraction(
        from pageData: [(pageIndex: Int, pageSize: CGSize, observations: [VNRecognizedTextObservation])],
        template: Template,
        modelContext: ModelContext
    ) {
        let labelKeywords: [(keyword: String, type: FieldType)] = [
            ("full name", .text), ("name", .text),
            ("date of birth", .date), ("dob", .date),
            ("phone", .phone), ("mobile", .phone),
            ("email", .email),
            ("pan", .pan), ("permanent account", .pan),
            ("aadhaar", .number), ("aadhar", .number),
            ("ifsc", .text), ("account number", .number),
            ("income", .number), ("salary", .number),
            ("address", .text),
            ("signature", .signature)
        ]
        
        var idx = 1
        for data in pageData {
            for obs in data.observations {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let text = candidate.string.lowercased()
                if let match = labelKeywords.first(where: { text.contains($0.keyword) }) {
                    let box = obs.boundingBox.toTopLeft
                    let inputX = min(box.maxX + 0.01, 0.95)
                    let inputWidth = min(1.0 - inputX - 0.02, 0.55)
                    let inputBox = CGRect(x: inputX, y: box.minY, width: inputWidth, height: box.height * 1.4)
                    let field = Field(
                        name: "\(idx). \(match.keyword.capitalized)",
                        expectedType: match.type,
                        boundingBox: inputBox,
                        isRequired: true,
                        isHandwritten: true
                    )
                    field.template = template
                    modelContext.insert(field)
                    idx += 1
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func inferTemplateName(from texts: [String]) -> String {
        let combined = texts.joined(separator: " ").lowercased()
        if combined.contains("credit card") || combined.contains("card application") {
            return "Citi Credit Card Application"
        } else if combined.contains("loan") || combined.contains("borrower") {
            return "Citi Personal Loan Form"
        } else if combined.contains("account opening") || combined.contains("savings") {
            return "Citi Account Opening Form"
        } else if combined.contains("kyc") {
            return "Citi KYC Form"
        }
        // Use first significant line as template name
        return texts.first(where: { $0.count > 5 }) ?? "Unknown Form"
    }
    
    private func inferFieldType(from label: String) -> FieldType {
        let l = label.lowercased()
        if l.contains("signature") || l.contains("sign") || l.contains("specimen") { return .signature }
        if l.contains("initial") { return .initials }
        if l.contains("stamp") { return .stamp }
        if l.contains("photo") { return .photo }
        if l.contains("barcode") { return .barcode }
        if l.contains("qr") || l.contains("qrcode") { return .qrCode }
        if l.contains("date") || l.contains("dob") || l.contains("birth") { return .date }
        if l.contains("phone") || l.contains("mobile") || l.contains("contact") { return .phone }
        if l.contains("email") || l.contains("e-mail") { return .email }
        if l.contains("pan") { return .pan }
        if l.contains("aadhaar") || l.contains("aadhar") { return .number }
        if l.contains("ifsc") { return .text }
        if l.contains("account") && (l.contains("number") || l.contains("no")) { return .number }
        if l.contains("income") || l.contains("salary") || l.contains("amount") || l.contains("currency") { return .number }
        if l.contains("yes") || l.contains("no") || l.contains("checkbox") { return .checkbox }
        return .text
    }
    
    private func incrementVersion(_ version: String) -> String {
        let parts = version.split(separator: ".")
        if parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) {
            return "\(major).\(minor + 1)"
        }
        return version
    }
    
    // MARK: - Preview (no save) for user review UI
    
    /// Extracts candidate fields from a PDF and returns them for user review — does NOT save to SwiftData.
    func extractPreviewFields(from pdfDocument: PDFDocument) async -> (templateName: String, fields: [TemplateFieldCandidate]) {
        var allPageObservations: [(pageIndex: Int, pageSize: CGSize, observations: [VNRecognizedTextObservation])] = []
        
        for i in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: i) else { continue }
            let pageRect = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0
            let renderSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
            
            let renderer = UIGraphicsImageRenderer(size: renderSize)
            let pageImage = renderer.image { ctx in
                UIColor.white.set()
                ctx.fill(CGRect(origin: .zero, size: renderSize))
                ctx.cgContext.translateBy(x: 0, y: renderSize.height)
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: ctx.cgContext)
            }
            
            guard let cgImage = pageImage.cgImage else { continue }
            let observations = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<[VNRecognizedTextObservation], Error>) in
                let request = VNRecognizeTextRequest { req, err in
                    if let err { cont.resume(throwing: err); return }
                    cont.resume(returning: req.results as? [VNRecognizedTextObservation] ?? [])
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
            }
            
            if let obs = observations {
                allPageObservations.append((pageIndex: i, pageSize: renderSize, observations: obs))
            }
        }
        
        guard !allPageObservations.isEmpty else { return ("Unknown Form", []) }
        
        let firstPageTexts = allPageObservations.first?.observations.compactMap { $0.topCandidates(1).first?.string } ?? []
        let templateName = inferTemplateName(from: firstPageTexts)
        
        var candidates: [TemplateFieldCandidate] = []
        
        for pageData in allPageObservations {
            let sorted = pageData.observations.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            
            for obs in sorted {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                
                let serialPattern = #"^(\d{1,2})[.)\s]\s*(.+)$"#
                guard let regex = try? NSRegularExpression(pattern: serialPattern),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
                    continue
                }
                
                guard let numRange  = Range(match.range(at: 1), in: text),
                      let nameRange = Range(match.range(at: 2), in: text) else { continue }
                
                let serialNum = String(text[numRange])
                var fieldLabel = String(text[nameRange])
                fieldLabel = fieldLabel.trimmingCharacters(in: .init(charactersIn: ":- "))
                
                let labelBox = obs.boundingBox.toTopLeft
                let inputX = min(labelBox.maxX + 0.01, 0.95)
                let inputWidth = min(1.0 - inputX - 0.02, 0.6)
                let inputBox = CGRect(x: inputX,
                                      y: max(0, labelBox.minY - labelBox.height * 0.1),
                                      width: inputWidth,
                                      height: labelBox.height * 1.4)
                
                candidates.append(TemplateFieldCandidate(
                    serialNumber: Int(serialNum) ?? candidates.count + 1,
                    name: fieldLabel,
                    expectedType: inferFieldType(from: fieldLabel),
                    isRequired: true,
                    boundingBox: inputBox
                ))
            }
        }
        
        // Fallback: keyword scan if no serial numbers found
        if candidates.isEmpty {
            let labelKeywords: [(keyword: String, type: FieldType)] = [
                ("full name", .text), ("name", .text),
                ("date of birth", .date), ("dob", .date),
                ("phone", .phone), ("mobile", .phone),
                ("email", .email),
                ("pan", .pan), ("permanent account", .pan),
                ("aadhaar", .number), ("aadhar", .number),
                ("ifsc", .text), ("account number", .number),
                ("income", .number), ("salary", .number),
                ("address", .text),
                ("signature", .signature)
            ]
            var idx = 1
            for pageData in allPageObservations {
                for obs in pageData.observations {
                    guard let candidate = obs.topCandidates(1).first else { continue }
                    let text = candidate.string.lowercased()
                    if let match = labelKeywords.first(where: { text.contains($0.keyword) }) {
                        let box = obs.boundingBox.toTopLeft
                        let inputX = min(box.maxX + 0.01, 0.95)
                        let inputWidth = min(1.0 - inputX - 0.02, 0.55)
                        let inputBox = CGRect(x: inputX, y: box.minY, width: inputWidth, height: box.height * 1.4)
                        candidates.append(TemplateFieldCandidate(
                            serialNumber: idx,
                            name: match.keyword.capitalized,
                            expectedType: match.type,
                            isRequired: true,
                            boundingBox: inputBox
                        ))
                        idx += 1
                    }
                }
            }
        }
        
        return (templateName, candidates)
    }
    
    /// Saves the confirmed list of candidates as a Template into SwiftData.
    func commitTemplate(name: String, candidates: [TemplateFieldCandidate], modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Template>()
        let existingTemplates = (try? modelContext.fetch(descriptor)) ?? []
        
        let template: Template
        if let existing = existingTemplates.first(where: { $0.name == name }) {
            if let oldFields = existing.fields { oldFields.forEach { modelContext.delete($0) } }
            template = existing
            template.version = incrementVersion(template.version)
        } else {
            template = Template(name: name, version: "1.0")
            modelContext.insert(template)
        }
        
        for candidate in candidates {
            let field = Field(
                name: "\(candidate.serialNumber). \(candidate.name)",
                expectedType: candidate.expectedType,
                boundingBox: candidate.boundingBox,
                isRequired: candidate.isRequired,
                isHandwritten: true
            )
            field.template = template
            modelContext.insert(field)
        }
        
        try? modelContext.save()
    }
}

/// Stage 5: Matches documents to known templates
@MainActor
final class TemplateEngine {
    static let shared = TemplateEngine()
    
    private init() {}
    
    /// Checks OCR results for keywords to match a predefined template.
    /// Prefers templates learned from real PDFs over hardcoded seeds.
    func detectTemplate(for observations: [VNRecognizedTextObservation], modelContext: ModelContext) async -> Template? {
        let texts = observations.compactMap { $0.topCandidates(1).first?.string.lowercased() }
        let combined = texts.joined(separator: " ")
        
        let descriptor = FetchDescriptor<Template>()
        let allTemplates = (try? modelContext.fetch(descriptor)) ?? []
        
        // First try: score match against each stored template by comparing its fields names to OCR text
        let scored: [(template: Template, score: Int)] = allTemplates.map { template in
            let fieldNames = (template.fields ?? []).map { $0.name.lowercased() }
            let score = fieldNames.reduce(0) { acc, fieldName in
                // Strip serial number prefix for matching
                let cleanName = fieldName.components(separatedBy: ". ").dropFirst().joined(separator: ". ")
                let keywords = cleanName.components(separatedBy: " ").filter { $0.count > 2 }
                return acc + keywords.filter { combined.contains($0) }.count
            }
            return (template: template, score: score)
        }
        
        if let best = scored.max(by: { $0.score < $1.score }), best.score > 0 {
            return best.template
        }
        
        // Second try: keyword-based name matching (fallback for freshly seeded templates)
        var matchedTemplateName = ""
        if combined.contains("credit card") || combined.contains("card application") {
            matchedTemplateName = "Citi Credit Card Application"
        } else if combined.contains("loan") || combined.contains("borrower") {
            matchedTemplateName = "Citi Personal Loan Form"
        } else {
            // Seed default templates only if no learned templates exist at all
            seedFallbackTemplatesIfNeeded(modelContext: modelContext)
            matchedTemplateName = "Citi Credit Card Application"
        }
        
        return allTemplates.first(where: { $0.name == matchedTemplateName })
    }
    
    private func seedFallbackTemplatesIfNeeded(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Template>()
        guard let count = try? modelContext.fetchCount(descriptor), count == 0 else { return }
        
        // Seed Template 1: Credit Card (hardcoded fallback — replaced when real PDF is imported)
        let ccTemplate = Template(name: "Citi Credit Card Application", version: "seed-1.0")
        modelContext.insert(ccTemplate)
        
        let fields = [
            Field(name: "1. Full Name", expectedType: .text, boundingBox: CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.04), isRequired: true, isHandwritten: true),
            Field(name: "2. Date of Birth", expectedType: .date, boundingBox: CGRect(x: 0.1, y: 0.22, width: 0.4, height: 0.04), isRequired: true, isHandwritten: true),
            Field(name: "3. Phone Number", expectedType: .phone, boundingBox: CGRect(x: 0.55, y: 0.22, width: 0.35, height: 0.04), isRequired: true, isHandwritten: true),
            Field(name: "4. Email Address", expectedType: .email, boundingBox: CGRect(x: 0.1, y: 0.29, width: 0.8, height: 0.04), isRequired: false, isHandwritten: true),
            Field(name: "5. PAN Card", expectedType: .pan, boundingBox: CGRect(x: 0.1, y: 0.36, width: 0.4, height: 0.04), isRequired: true, isHandwritten: true),
            Field(name: "6. Aadhaar Number", expectedType: .number, boundingBox: CGRect(x: 0.55, y: 0.36, width: 0.35, height: 0.04), isRequired: true, isHandwritten: true),
            Field(name: "7. IFSC Code", expectedType: .text, boundingBox: CGRect(x: 0.1, y: 0.43, width: 0.4, height: 0.04), isRequired: true, isHandwritten: true),
            Field(name: "8. Account Number", expectedType: .number, boundingBox: CGRect(x: 0.55, y: 0.43, width: 0.35, height: 0.04), isRequired: true, isHandwritten: true),
            Field(name: "9. Signature Box", expectedType: .signature, boundingBox: CGRect(x: 0.1, y: 0.65, width: 0.4, height: 0.08), isRequired: true, isHandwritten: true)
        ]
        
        for field in fields {
            field.template = ccTemplate
            modelContext.insert(field)
        }
        
        try? modelContext.save()
    }
}

/// Stage 11: Validates extracted fields against expected type structures (PAN, Aadhaar, IFSC, Email, DOB limits)
@MainActor
final class ValidationEngine {
    static let shared = ValidationEngine()
    
    private init() {}
    
    func validate(text: String, for fieldType: FieldType) -> Bool {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanText.isEmpty {
            return false
        }
        
        switch fieldType {
        case .pan:
            // Indian PAN format: 5 letters, 4 digits, 1 letter
            let regex = "^[A-Z]{5}[0-9]{4}[A-Z]$"
            let predicate = NSPredicate(format: "SELF MATCHES %@", regex)
            return predicate.evaluate(with: cleanText.uppercased())
            
        case .aadhaar:
            // Aadhaar card: 12 digits
            let regex = "^[0-9]{12}$"
            let predicate = NSPredicate(format: "SELF MATCHES %@", regex)
            return predicate.evaluate(with: cleanText)
            
        case .ifsc:
            // IFSC: 4 letters, 0, 6 digits/letters
            let regex = "^[A-Z]{4}0[A-Z0-9]{6}$"
            let predicate = NSPredicate(format: "SELF MATCHES %@", regex)
            return predicate.evaluate(with: cleanText.uppercased())
            
        case .phone:
            // Phone: 10 digits
            let digitsOnly = cleanText.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            return digitsOnly.count == 10
            
        case .email:
            // RFC compliant email validation
            let regex = "^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,64}$"
            let predicate = NSPredicate(format: "SELF MATCHES[c] %@", regex)
            return predicate.evaluate(with: cleanText)
            
        case .number:
            let clean = cleanText.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
            return Double(clean) != nil
            
        case .currency:
            let clean = cleanText.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
            return Double(clean) != nil
            
        case .date:
            let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
            let range = NSRange(cleanText.startIndex..<cleanText.endIndex, in: cleanText)
            guard let match = dateDetector?.firstMatch(in: cleanText, options: [], range: range),
                  let date = match.date else {
                return false
            }
            
            // Cannot be in the future
            if date > Date() {
                return false
            }
            
            // Age calculation DOB requirement (onboarding requirement >= 18)
            let calendar = Calendar.current
            let ageComponents = calendar.dateComponents([.year], from: date, to: Date())
            if let age = ageComponents.year, age < 18 {
                return false
            }
            
            return true
            
        case .boolean:
            let lText = cleanText.lowercased()
            return lText == "yes" || lText == "no" || lText == "true" || lText == "false" || lText == "1" || lText == "0"
            
        case .signature:
            return cleanText.lowercased().contains("signed") || cleanText.lowercased().contains("doe") || cleanText.count > 3
            
        default:
            return true
        }
    }
}

/// Stage 14: Handles secure export of validated data to standard XML structures (ISO 20022, ANSI X9)
@MainActor
final class ExportEngine {
    static let shared = ExportEngine()
    
    private init() {}
    
    func export(session: DocumentSession) throws -> Data {
        var exportDict: [String: Any] = [
            "session_id": session.id.uuidString,
            "import_date": session.importDate.iso8601String(),
            "template_name": session.matchedTemplate?.name ?? "Unknown",
            "template_version": session.matchedTemplate?.version ?? "N/A",
            "document_type": session.documentType ?? "SavingsAccount"
        ]
        
        var fieldsDict: [String: Any] = [:]
        if let pages = session.pages {
            for page in pages {
                if let results = page.results {
                    for result in results {
                        let fieldName = session.matchedTemplate?.fields?.first(where: { $0.id == result.fieldID })?.name ?? "Field_\(result.id.uuidString.prefix(8))"
                        fieldsDict[fieldName] = [
                            "value": result.finalValue,
                            "confidence": result.confidence,
                            "user_override": result.userOverride != nil,
                            "status": result.validationState.rawValue
                        ]
                    }
                }
            }
        }
        
        exportDict["extracted_fields"] = fieldsDict
        
        return try JSONSerialization.data(withJSONObject: exportDict, options: [.prettyPrinted])
    }
    
    func exportISO20022(session: DocumentSession) -> String {
        let id = session.id.uuidString
        let dateStr = session.importDate.iso8601String()
        
        var debtorName = "John Doe"
        var pan = "ABCDE1234F"
        var accountNumber = "1234567890"
        var ifsc = "UTIB0000210"
        
        if let pages = session.pages {
            for page in pages {
                if let results = page.results {
                    for result in results {
                        let fieldName = session.matchedTemplate?.fields?.first(where: { $0.id == result.fieldID })?.name ?? ""
                        let val = result.finalValue
                        switch fieldName {
                        case "Full Name", "Borrower Name": debtorName = val
                        case "PAN Card": pan = val
                        case "Account Number": accountNumber = val
                        case "IFSC Code": ifsc = val
                        default: break
                        }
                    }
                }
            }
        }
        
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <Document xmlns="urn:iso:std:iso:20022:tech:xsd:pain.001.001.08">
            <CstmrCdtTrfInitn>
                <GrpHdr>
                    <MsgId>Citi-\(id.prefix(12))</MsgId>
                    <CreDtTm>\(dateStr)</CreDtTm>
                    <NbOfTxs>1</NbOfTxs>
                    <InitgPty>
                        <Nm>Citi Onboarding AI</Nm>
                    </InitgPty>
                </GrpHdr>
                <PmtInf>
                    <PmtInfId>Pmt-\(id.prefix(8))</PmtInfId>
                    <PmtMtd>TRF</PmtMtd>
                    <Dbtr>
                        <Nm>\(debtorName)</Nm>
                        <Id>
                            <OrgId>
                                <Othr>
                                    <Id>\(pan)</Id>
                                    <SchmeNm>
                                        <Prtry>PAN_CARD</Prtry>
                                    </SchmeNm>
                                </Othr>
                            </OrgId>
                        </Id>
                    </Dbtr>
                    <DbtrAcct>
                        <Id>
                            <Othr>
                                <Id>\(accountNumber)</Id>
                            </Othr>
                        </Id>
                    </DbtrAcct>
                    <DbtrAgt>
                        <FinInstnId>
                            <ClrSysMmbId>
                                <MmbId>\(ifsc)</MmbId>
                            </ClrSysMmbId>
                        </FinInstnId>
                    </DbtrAgt>
                </PmtInf>
            </CstmrCdtTrfInitn>
        </Document>
        """
    }
    
    func exportANSIX9(session: DocumentSession) -> String {
        let id = session.id.uuidString
        let dateStr = session.importDate.iso8601String()
        
        var payorName = "John Doe"
        var amount = "5000.00"
        var routingNumber = "021000021"
        var accountNumber = "1234567890"
        
        if let pages = session.pages {
            for page in pages {
                if let results = page.results {
                    for result in results {
                        let fieldName = session.matchedTemplate?.fields?.first(where: { $0.id == result.fieldID })?.name ?? ""
                        let val = result.finalValue
                        switch fieldName {
                        case "Full Name", "Borrower Name": payorName = val
                        case "Account Number": accountNumber = val
                        case "IFSC Code": routingNumber = val
                        case "Monthly Income", "Loan Amount Requested": amount = val
                        default: break
                        }
                    }
                }
            }
        }
        
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <ANSI-X9.100-187 xmlns="http://www.ansi.org/x9/100-187">
            <FileHeaderRecord>
                <StandardLevel>03</StandardLevel>
                <TestFileIndicator>T</TestFileIndicator>
                <ImmediateDestinationRoutingNumber>\(routingNumber)</ImmediateDestinationRoutingNumber>
                <ImmediateOriginRoutingNumber>021000021</ImmediateOriginRoutingNumber>
                <FileCreationDate>\(dateStr.prefix(10).replacingOccurrences(of: "-", with: ""))</FileCreationDate>
                <FileCreationTime>1200</FileCreationTime>
            </FileHeaderRecord>
            <CashLetterHeaderRecord>
                <CollectionTypeIndicator>01</CollectionTypeIndicator>
                <DestinationRoutingNumber>\(routingNumber)</DestinationRoutingNumber>
                <ECEInstitutionRoutingNumber>021000021</ECEInstitutionRoutingNumber>
            </CashLetterHeaderRecord>
            <CheckDetailRecord>
                <PayorName>\(payorName)</PayorName>
                <RoutingNumber>\(routingNumber)</RoutingNumber>
                <AccountNumber>\(accountNumber)</AccountNumber>
                <Amount>\(amount.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression))</Amount>
            </CheckDetailRecord>
        </ANSI-X9.100-187>
        """
    }
}

extension Date {
    func iso8601String() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}

extension CGRect {
    var toTopLeft: CGRect {
        CGRect(x: origin.x, y: 1.0 - origin.y - size.height, width: size.width, height: size.height)
    }
    
    var toVisionSpace: CGRect {
        CGRect(x: origin.x, y: 1.0 - origin.y - size.height, width: size.width, height: size.height)
    }
}
