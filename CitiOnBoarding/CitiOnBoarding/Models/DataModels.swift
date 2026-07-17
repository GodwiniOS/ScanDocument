import Foundation
import SwiftData
import CoreGraphics

// MARK: - Transient Model for PDF Template Review UI
/// Temporary struct used to represent a candidate field extracted from a PDF.
/// Passed to the review sheet so the user can edit before saving to SwiftData.
struct TemplateFieldCandidate: Identifiable {
    var id: UUID = UUID()
    var serialNumber: Int
    var name: String
    var expectedType: FieldType
    var isRequired: Bool
    var boundingBox: CGRect
    var inputBox: CGRect? = nil
}

@Model
final class DocumentSession {
    var id: UUID
    var importDate: Date
    var status: SessionStatus
    
    @Relationship(deleteRule: .cascade, inverse: \Page.session)
    var pages: [Page]?
    
    var matchedTemplate: Template?
    var exportRecord: ExportRecord?
    
    @Relationship(deleteRule: .cascade, inverse: \SignatureAsset.session)
    var signatures: [SignatureAsset]?
    
    var documentType: String?
    var qualityScore: Double?
    var qualityStatus: String?
    var templateConfidence: Double?
    var normalizedBankingJSON: String?
    
    init(
        id: UUID = UUID(),
        importDate: Date = Date(),
        status: SessionStatus = .imported,
        documentType: String? = nil,
        qualityScore: Double? = nil,
        qualityStatus: String? = nil,
        templateConfidence: Double? = nil,
        normalizedBankingJSON: String? = nil
    ) {
        self.id = id
        self.importDate = importDate
        self.status = status
        self.documentType = documentType
        self.qualityScore = qualityScore
        self.qualityStatus = qualityStatus
        self.templateConfidence = templateConfidence
        self.normalizedBankingJSON = normalizedBankingJSON
    }
}

enum SessionStatus: String, Codable {
    case imported
    case processing
    case needsReview
    case validated
    case exported
}

@Model
final class Template {
    var id: UUID
    var name: String
    var version: String
    var revision: String
    var effectiveDate: Date
    
    @Relationship(deleteRule: .cascade, inverse: \Field.template)
    var fields: [Field]?
    
    init(id: UUID = UUID(), name: String, version: String, revision: String = "A", effectiveDate: Date = Date()) {
        self.id = id
        self.name = name
        self.version = version
        self.revision = revision
        self.effectiveDate = effectiveDate
    }
}

@Model
final class Page {
    var id: UUID
    var pageNumber: Int
    var imagePath: String // Path to the cached image on disk
    
    var session: DocumentSession?
    
    @Relationship(deleteRule: .cascade, inverse: \FieldResult.page)
    var results: [FieldResult]?
    
    init(id: UUID = UUID(), pageNumber: Int, imagePath: String) {
        self.id = id
        self.pageNumber = pageNumber
        self.imagePath = imagePath
    }
}

@Model
final class Field {
    var id: UUID
    var fieldId: String
    var name: String
    var expectedType: FieldType
    var captureMode: String // "text", "image", "checkbox", "barcode"
    var ocrEnabled: Bool
    
    // Normalized coordinates (0.0 to 1.0)
    var boundingBoxX: Double
    var boundingBoxY: Double
    var boundingBoxWidth: Double
    var boundingBoxHeight: Double
    
    var inputBoxX: Double
    var inputBoxY: Double
    var inputBoxWidth: Double
    var inputBoxHeight: Double
    
    var labelBoxX: Double
    var labelBoxY: Double
    var labelBoxWidth: Double
    var labelBoxHeight: Double
    
    var isRequired: Bool
    var isHandwritten: Bool
    
    var template: Template?
    
    init(id: UUID = UUID(), fieldId: String? = nil, name: String, expectedType: FieldType, boundingBox: CGRect, inputBox: CGRect? = nil, isRequired: Bool = true, isHandwritten: Bool = true) {
        self.id = id
        self.fieldId = fieldId ?? name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ":", with: "")
        self.name = name
        self.expectedType = expectedType
        self.boundingBoxX = boundingBox.minX
        self.boundingBoxY = boundingBox.minY
        self.boundingBoxWidth = boundingBox.width
        self.boundingBoxHeight = boundingBox.height
        
        let actualInputBox = inputBox ?? boundingBox
        self.inputBoxX = actualInputBox.minX
        self.inputBoxY = actualInputBox.minY
        self.inputBoxWidth = actualInputBox.width
        self.inputBoxHeight = actualInputBox.height
        
        self.labelBoxX = max(0, boundingBox.minX - 0.15)
        self.labelBoxY = boundingBox.minY
        self.labelBoxWidth = 0.15
        self.labelBoxHeight = boundingBox.height
        
        self.isRequired = isRequired
        self.isHandwritten = isHandwritten
        
        switch expectedType {
        case .signature, .initials, .stamp, .photo, .image:
            self.captureMode = "image"
            self.ocrEnabled = false
        case .checkbox, .radio:
            self.captureMode = "checkbox"
            self.ocrEnabled = false
        case .barcode, .qrCode:
            self.captureMode = "barcode"
            self.ocrEnabled = true
        default:
            self.captureMode = "text"
            self.ocrEnabled = true
        }
    }
    
    var rect: CGRect {
        CGRect(x: boundingBoxX, y: boundingBoxY, width: boundingBoxWidth, height: boundingBoxHeight)
    }
    
    var inputBoxRect: CGRect {
        CGRect(x: inputBoxX, y: inputBoxY, width: inputBoxWidth, height: inputBoxHeight)
    }
    
    var labelBoxRect: CGRect {
        CGRect(x: labelBoxX, y: labelBoxY, width: labelBoxWidth, height: labelBoxHeight)
    }
}

enum FieldType: String, Codable {
    case text
    case multiline
    case number
    case date
    case currency
    case phone
    case email
    case checkbox
    case radio
    case dropdown
    case table
    case image
    case signature      // Capture image only
    case initials       // Capture image only
    case stamp          // Capture image only
    case photo          // Capture image only
    case barcode
    case qrCode
    
    // Legacy / Compatibility cases
    case pan
    case aadhaar
    case ifsc
    case boolean
    case multiLine
}

@Model
final class FieldResult {
    var id: UUID
    var fieldID: UUID // References the Field in the Template
    
    var boundingBoxX: Double
    var boundingBoxY: Double
    var boundingBoxWidth: Double
    var boundingBoxHeight: Double
    
    var ocrText: String
    var normalizedValue: String?
    var confidence: Double
    
    var ocrConfidence: Double
    var mappingConfidence: Double
    var validationConfidence: Double
    var overallConfidence: Double
    var isHandwritten: Bool
    var userConfirmed: Bool
    var edited: Bool
    
    var userOverride: String?
    var validationState: ValidationState
    
    var page: Page?
    
    // Lineage & Audit
    var recognitionEngineUsed: String
    var scoreImageQuality: Double
    var scoreAlignment: Double
    var scoreOCR: Double
    var scoreValidation: Double
    var originalPageNumber: Int
    var overrideHistory: [String]
    
    init(
        id: UUID = UUID(),
        fieldID: UUID,
        boundingBox: CGRect,
        ocrText: String,
        confidence: Double = 1.0,
        ocrConfidence: Double = 1.0,
        mappingConfidence: Double = 1.0,
        validationConfidence: Double = 1.0,
        overallConfidence: Double = 1.0,
        isHandwritten: Bool = true,
        userConfirmed: Bool = false,
        edited: Bool = false,
        recognitionEngineUsed: String = "printed",
        scoreImageQuality: Double = 1.0,
        scoreAlignment: Double = 1.0,
        scoreOCR: Double = 1.0,
        scoreValidation: Double = 1.0,
        originalPageNumber: Int = 1,
        overrideHistory: [String] = []
    ) {
        self.id = id
        self.fieldID = fieldID
        self.boundingBoxX = boundingBox.minX
        self.boundingBoxY = boundingBox.minY
        self.boundingBoxWidth = boundingBox.width
        self.boundingBoxHeight = boundingBox.height
        self.ocrText = ocrText
        self.confidence = confidence
        self.ocrConfidence = ocrConfidence
        self.mappingConfidence = mappingConfidence
        self.validationConfidence = validationConfidence
        self.overallConfidence = overallConfidence
        self.isHandwritten = isHandwritten
        self.userConfirmed = userConfirmed
        self.edited = edited
        self.validationState = .unvalidated
        
        self.recognitionEngineUsed = recognitionEngineUsed
        self.scoreImageQuality = scoreImageQuality
        self.scoreAlignment = scoreAlignment
        self.scoreOCR = scoreOCR
        self.scoreValidation = scoreValidation
        self.originalPageNumber = originalPageNumber
        self.overrideHistory = overrideHistory
    }
    
    var rect: CGRect {
        CGRect(x: boundingBoxX, y: boundingBoxY, width: boundingBoxWidth, height: boundingBoxHeight)
    }
    
    var finalValue: String {
        return userOverride ?? normalizedValue ?? ocrText
    }
}

enum ValidationState: String, Codable {
    case verified       // 🟢 Verified: User confirmed
    case autoAccepted   // 🔵 Auto Accepted: High confidence, not manually reviewed
    case needsReview    // 🟡 Needs Review: Medium confidence
    case invalid        // 🔴 Invalid: Failed validation
    case empty          // ⚪ Empty: No value detected
    case edited         // 🟣 Edited: User modified the value
    
    // Legacy support
    static let unvalidated = ValidationState.needsReview
    static let approved = ValidationState.verified
    static let rejected = ValidationState.invalid
    static let corrected = ValidationState.edited
}

@Model
final class UserCorrection {
    var id: UUID
    var fieldResultID: UUID
    var originalValue: String
    var correctedValue: String
    var timestamp: Date
    
    init(id: UUID = UUID(), fieldResultID: UUID, originalValue: String, correctedValue: String, timestamp: Date = Date()) {
        self.id = id
        self.fieldResultID = fieldResultID
        self.originalValue = originalValue
        self.correctedValue = correctedValue
        self.timestamp = timestamp
    }
}

@Model
final class ExportRecord {
    var id: UUID
    var exportDate: Date
    var destination: String
    var payloadHash: String
    
    init(id: UUID = UUID(), exportDate: Date = Date(), destination: String, payloadHash: String) {
        self.id = id
        self.exportDate = exportDate
        self.destination = destination
        self.payloadHash = payloadHash
    }
}

// MARK: - Signature Asset Model
@Model
final class SignatureAsset {
    var id: UUID
    var fieldId: String
    var pageNumber: Int
    var imagePath: String // Path to cropped signature image file on disk
    var status: String    // "present" or "missing"
    var qualityScore: Double
    var blank: Bool
    var userVerified: Bool
    
    var session: DocumentSession?
    
    init(id: UUID = UUID(), fieldId: String, pageNumber: Int, imagePath: String, status: String = "present", qualityScore: Double = 1.0, blank: Bool = false, userVerified: Bool = false) {
        self.id = id
        self.fieldId = fieldId
        self.pageNumber = pageNumber
        self.imagePath = imagePath
        self.status = status
        self.qualityScore = qualityScore
        self.blank = blank
        self.userVerified = userVerified
    }
}
