import Foundation
import FoundationModels
import Vision
import UIKit
import CoreGraphics

// MARK: - Foundation Models Generable Output Types
// Type-safe structured outputs returned by the on-device LLM.

/// One field in a blank banking form template.
@Generable
struct FMTemplateField {
    @Guide(description: "Unique snake_case field identifier derived from the label, e.g. applicant_name")
    var fieldId: String
    @Guide(description: "Human-readable label as it appears on the form, e.g. 'Full Name:'")
    var label: String
    @Guide(description: "Data type. One of: text, date, phone, email, pan, aadhaar, ifsc, signature, initials, stamp, photo, checkbox, radio, number, currency, multiline, address, barcode, qrCode")
    var dataType: String
    @Guide(description: "True if the applicant must fill this field")
    var required: Bool
    @Guide(description: "True if this field is inside a repeatable section (e.g. Joint Applicant)")
    var repeatable: Bool
    @Guide(description: "For checkbox/radio: all option labels in the same group. Empty otherwise.")
    var groupOptions: [String]
    @Guide(description: "Section or page group name, e.g. 'Customer Profile', 'Mailing Address'")
    var section: String
}

/// Complete semantic template from a blank banking form.
@Generable
struct FMSemanticTemplate {
    @Guide(description: "Full document name, e.g. 'Citi Private Bank Account Opening Form'")
    var documentName: String
    @Guide(description: "Issuing institution")
    var institution: String
    @Guide(description: "All fields found across all pages, in reading order")
    var fields: [FMTemplateField]
    @Guide(description: "Confidence 0.0-1.0 in the overall template understanding")
    var confidence: Double
}

/// Mapping of one scanned region to a template field.
@Generable
struct FMFieldMapping {
    @Guide(description: "Template field ID this region maps to")
    var templateFieldId: String
    @Guide(description: "Value bounding box [x, y, width, height] normalized 0.0-1.0")
    var valueRegion: [Double]
    @Guide(description: "Writing mode: printed, handwritten, or empty")
    var writingMode: String
    @Guide(description: "Mapping confidence 0.0-1.0")
    var confidence: Double
}

/// Full page mapping result.
@Generable
struct FMPageMapping {
    @Guide(description: "All field mappings found on this scanned page")
    var mappings: [FMFieldMapping]
    @Guide(description: "Overall mapping confidence 0.0-1.0")
    var overallConfidence: Double
}

/// Corrected and validated value for one OCR-extracted field.
@Generable
struct FMCorrectedValue {
    @Guide(description: "Semantically corrected value. Names: Title Case. Dates: dd/MM/yyyy. PAN: 10-char uppercase. Phone: digits only. Email: lowercase.")
    var correctedText: String
    @Guide(description: "True if value passes banking domain validation")
    var isValid: Bool
    @Guide(description: "Human-readable validation failure reason. Empty if valid.")
    var validationReason: String
    @Guide(description: "Correction confidence 0.0-1.0")
    var confidence: Double
}

// MARK: - Foundation Models Tools
// Each tool exposes a deterministic Vision/CoreImage engine capability
// so that the language model can orchestrate the pipeline.

/// Tool: Run Vision OCR on a specific normalized field bounding box.
@available(iOS 26, *)
struct ExtractFieldTool: Tool {
    let name = "extractField"
    let description = "Run Vision OCR on a normalized field region [x,y,w,h] and return the extracted text."

    @Generable
    struct Arguments {
        @Guide(description: "Template field ID to extract")
        var fieldId: String
        @Guide(description: "Normalized bounding box [x, y, width, height] 0.0-1.0")
        var boundingBox: [Double]
    }

    var pageImage: UIImage

    func call(arguments: Arguments) async throws -> String {
        guard arguments.boundingBox.count == 4,
              let cgImage = pageImage.cgImage else {
            return "ocr:empty"
        }
        let b = arguments.boundingBox
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let rect = CGRect(x: b[0]*w, y: b[1]*h, width: b[2]*w, height: b[3]*h)
        guard rect.width > 2, rect.height > 2,
              let cropped = cgImage.cropping(to: rect) else {
            return "ocr:empty"
        }
        let text = try await runVisionOCR(cgImage: cropped)
        return "ocr:\(text.isEmpty ? "empty" : text)"
    }

    private func runVisionOCR(cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let req = VNRecognizeTextRequest { r, err in
                guard !resumed else { return }
                resumed = true
                if let err = err { continuation.resume(throwing: err); return }
                let text = (r.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                continuation.resume(returning: text)
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([req]) }
            catch { if !resumed { resumed = true; continuation.resume(throwing: error) } }
        }
    }
}

/// Tool: Detect whether a signature or ink is present in a bounding box region.
@available(iOS 26, *)
struct DetectSignatureTool: Tool {
    let name = "detectSignature"
    let description = "Detect whether a signature or handwritten ink is present in a region. Returns 'present' or 'missing'."

    @Generable
    struct Arguments {
        @Guide(description: "Template field ID")
        var fieldId: String
        @Guide(description: "Normalized bounding box [x, y, width, height] 0.0-1.0")
        var boundingBox: [Double]
    }

    var pageImage: UIImage

    func call(arguments: Arguments) async throws -> String {
        guard arguments.boundingBox.count == 4,
              let cgImage = pageImage.cgImage else {
            return "signature:missing"
        }
        let b = arguments.boundingBox
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let rect = CGRect(x: b[0]*w, y: b[1]*h, width: b[2]*w, height: b[3]*h)
        guard rect.width > 2, rect.height > 2,
              let cropped = cgImage.cropping(to: rect) else {
            return "signature:missing"
        }
        let inkRatio = computeInkRatio(cgImage: cropped)
        return "signature:\(inkRatio > 0.02 ? "present" : "missing")"
    }

    // Ink density without MainActor dependency
    private func computeInkRatio(cgImage: CGImage) -> Double {
        let w = cgImage.width, h = cgImage.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var dark = 0
        for i in 0..<(w * h) {
            let r = pixels[i*4], g = pixels[i*4+1], b = pixels[i*4+2]
            if Int(r) + Int(g) + Int(b) < 384 { dark += 1 }
        }
        return Double(dark) / Double(w * h)
    }
}

/// Tool: Detect whether a checkbox or radio button is checked.
@available(iOS 26, *)
struct CheckCheckboxTool: Tool {
    let name = "checkCheckbox"
    let description = "Detect whether a checkbox or radio button region is marked. Returns 'YES' or 'NO'."

    @Generable
    struct Arguments {
        @Guide(description: "Template field ID")
        var fieldId: String
        @Guide(description: "Normalized bounding box [x, y, width, height] 0.0-1.0")
        var boundingBox: [Double]
    }

    var pageImage: UIImage

    func call(arguments: Arguments) async throws -> String {
        guard arguments.boundingBox.count == 4,
              let cgImage = pageImage.cgImage else {
            return "checkbox:NO"
        }
        let b = arguments.boundingBox
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let rect = CGRect(x: b[0]*w, y: b[1]*h, width: b[2]*w, height: b[3]*h)
        guard rect.width > 2, rect.height > 2,
              let cropped = cgImage.cropping(to: rect) else {
            return "checkbox:NO"
        }
        let inkRatio = computeInkRatio(cgImage: cropped)
        return "checkbox:\(inkRatio > 0.16 ? "YES" : "NO")"
    }

    private func computeInkRatio(cgImage: CGImage) -> Double {
        let w = cgImage.width, h = cgImage.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var dark = 0
        for i in 0..<(w * h) {
            let r = pixels[i*4], g = pixels[i*4+1], b = pixels[i*4+2]
            if Int(r) + Int(g) + Int(b) < 384 { dark += 1 }
        }
        return Double(dark) / Double(w * h)
    }
}

// MARK: - Writing Mode Enum
enum WritingMode: String {
    case printed, handwritten, empty
}

// MARK: - FoundationModelError
enum FoundationModelError: LocalizedError {
    case modelUnavailable
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Apple Intelligence unavailable on this device. Using offline heuristics."
        case .generationFailed(let reason):
            return "Foundation Model generation failed: \(reason)"
        }
    }
}

// MARK: - Foundation Model Engine
// Vision = Eyes. Foundation Models = Brain.
// Three purpose-built sessions cover the full document pipeline.

@available(iOS 26, *)
@MainActor
final class FoundationModelEngine {
    static let shared = FoundationModelEngine()
    private init() {}

    private let model = SystemLanguageModel.default

    /// True when Apple Intelligence is available on this device.
    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    // MARK: Session 1 — Template Understanding (blank form)
    /// Vision extracts raw text. FM understands the entire document semantic structure.
    func understandTemplate(pageTexts: [(page: Int, lines: [String])]) async throws -> FMSemanticTemplate {
        guard isAvailable else { throw FoundationModelError.modelUnavailable }

        let formattedText = pageTexts.map { pd -> String in
            "=== PAGE \(pd.page + 1) ===\n" + pd.lines.prefix(120).joined(separator: "\n")
        }.joined(separator: "\n\n")

        let session = LanguageModelSession(
            model: model,
            instructions: """
            You are an enterprise banking Document AI engine performing template understanding.
            You receive Vision OCR text extracted from a BLANK banking form template.
            
            Your task: UNDERSTAND the document structure. Do NOT extract applicant values.
            Identify:
            - Document name and issuing institution
            - All fillable field labels (those followed by colons, blank lines, or underscores)
            - Expected data type for each field
            - Required vs optional status
            - Checkbox and radio button groups
            - Repeatable applicant sections (e.g. Joint Applicant)
            - Signature, initials, and stamp areas
            - Table structures (beneficiaries, nominees, etc.)
            
            Only include genuine fillable input areas.
            Ignore printed instructions, legal paragraphs, watermarks, and body text.
            Return a complete, exhaustive field inventory.
            """
        )

        let response = try await session.respond(
            to: "Understand this blank banking form and return its complete semantic field structure:\n\n\(formattedText)",
            generating: FMSemanticTemplate.self
        )
        return response.content
    }

    // MARK: Session 2 — Field Mapping (scanned filled form)
    /// FM uses the template JSON + Vision OCR to map applicant values to template fields,
    /// calling Vision tools as needed for specific regions.
    func mapFieldsToTemplate(
        templateJSON: String,
        pageOCRLines: [(text: String, box: CGRect)],
        pageImage: UIImage
    ) async throws -> FMPageMapping {
        guard isAvailable else { throw FoundationModelError.modelUnavailable }

        let ocrFormatted = pageOCRLines.prefix(200).enumerated().map { i, item -> String in
            let b = item.box
            return "[\(i)] \"\(item.text)\" [\(String(format: "%.3f", b.minX)),\(String(format: "%.3f", b.minY)),\(String(format: "%.3f", b.width)),\(String(format: "%.3f", b.height))]"
        }.joined(separator: "\n")

        let tools: [any Tool] = [
            ExtractFieldTool(pageImage: pageImage),
            DetectSignatureTool(pageImage: pageImage),
            CheckCheckboxTool(pageImage: pageImage)
        ]

        let session = LanguageModelSession(
            model: model,
            tools: tools,
            instructions: """
            You are an enterprise banking Document AI performing field mapping.
            You have a registered template (blank form structure) and Vision OCR observations
            from a scanned, applicant-filled form page.
            
            For each template field:
            1. Find the value the applicant wrote or printed near that field label
            2. Use extractField() for text/date/phone/email/PAN fields to get precise OCR
            3. Use detectSignature() for signature, initials, stamp fields
            4. Use checkCheckbox() for checkbox and radio button fields
            5. Identify writing mode: handwritten, printed, or empty
            6. Return normalized bounding box of the VALUE region (not the label)
            
            CRITICAL RULES:
            - Ignore printed form instructions, legal paragraphs, headers, watermarks, logos
            - Only extract USER-ENTERED content
            - Do NOT invent or guess values not visible in the scan
            - If a field has no user entry, mark writingMode as empty
            """
        )

        let response = try await session.respond(
            to: """
            REGISTERED TEMPLATE:
            \(templateJSON)
            
            VISION OCR OBSERVATIONS (scanned filled page):
            \(ocrFormatted)
            
            Map every template field to its user-entered value in this scanned page.
            """,
            generating: FMPageMapping.self
        )
        return response.content
    }

    // MARK: Session 3 — Normalize + Correct + Validate
    /// Given raw Vision OCR text for one field, FM corrects OCR errors and validates.
    func correctAndValidate(
        rawText: String,
        fieldId: String,
        fieldLabel: String,
        dataType: String,
        sectionContext: String = ""
    ) async throws -> FMCorrectedValue {
        guard isAvailable else { throw FoundationModelError.modelUnavailable }

        let session = LanguageModelSession(
            model: model,
            instructions: """
            You are a banking OCR correction and validation engine.
            Correct common Vision OCR errors using field context:
            - 0/O confusion: names and text fields use O; account numbers and codes use 0
            - 1/l/I: text fields use l; numeric codes use 1
            - 5/S: use context
            - Date → normalize to dd/MM/yyyy
            - PAN → exactly AAAAA9999A format
            - Phone → digits only, 10 digits for India/Singapore
            - Email → lowercase, fix common domain typos (gmai.com → gmail.com)
            - Names → Title Case
            - Currency → digits with 2 decimal places
            
            Banking validation rules:
            - DOB must not be in the future, applicant age must be >= 18
            - PAN: exactly 10 chars, format AAAAA9999A
            - Phone: 10 digits
            - Email: must contain @ and valid domain
            - Empty or unreadable → return empty correctedText, isValid = false
            """
        )

        let contextSuffix = sectionContext.isEmpty ? "" : ", Section: \(sectionContext)"
        let response = try await session.respond(
            to: """
            Field: \(fieldLabel) (ID: \(fieldId), Type: \(dataType)\(contextSuffix))
            Raw OCR text: "\(rawText)"
            
            Correct OCR errors, normalize format, and validate this banking field value.
            """,
            generating: FMCorrectedValue.self
        )
        return response.content
    }

    // MARK: Document Name Inference
    func inferDocumentName(from firstPageLines: [String]) async throws -> String {
        guard isAvailable else { throw FoundationModelError.modelUnavailable }
        let text = firstPageLines.prefix(30).joined(separator: " ")
        let session = LanguageModelSession(model: model)
        let response = try await session.respond(
            to: "What is the official name of this banking document? Reply with only the document name.\n\n\(text)"
        )
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Writing Mode Detection
    func detectWritingMode(rawText: String, visionConfidence: Double, fieldLabel: String) async throws -> WritingMode {
        guard isAvailable else {
            if rawText.isEmpty { return .empty }
            return visionConfidence < 0.65 ? .handwritten : .printed
        }
        let session = LanguageModelSession(
            model: model,
            instructions: "Classify banking form field content as: handwritten, printed, or empty. Reply with exactly one word."
        )
        let response = try await session.respond(
            to: "Field '\(fieldLabel)': \"\(rawText)\". OCR confidence: \(String(format: "%.2f", visionConfidence)). Is this handwritten, printed, or empty?"
        )
        let lower = response.content.lowercased()
        if lower.contains("handwritten") { return .handwritten }
        if lower.contains("empty") || rawText.isEmpty { return .empty }
        return .printed
    }
}
