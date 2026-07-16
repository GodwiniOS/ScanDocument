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
    
    @Relationship(deleteRule: .cascade, inverse: \Field.template)
    var fields: [Field]?
    
    init(id: UUID = UUID(), name: String, version: String) {
        self.id = id
        self.name = name
        self.version = version
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
    var name: String
    var expectedType: FieldType
    
    // Normalized coordinates (0.0 to 1.0)
    var boundingBoxX: Double
    var boundingBoxY: Double
    var boundingBoxWidth: Double
    var boundingBoxHeight: Double
    
    var isRequired: Bool
    var isHandwritten: Bool
    
    var template: Template?
    
    init(id: UUID = UUID(), name: String, expectedType: FieldType, boundingBox: CGRect, isRequired: Bool = true, isHandwritten: Bool = true) {
        self.id = id
        self.name = name
        self.expectedType = expectedType
        self.boundingBoxX = boundingBox.minX
        self.boundingBoxY = boundingBox.minY
        self.boundingBoxWidth = boundingBox.width
        self.boundingBoxHeight = boundingBox.height
        self.isRequired = isRequired
        self.isHandwritten = isHandwritten
    }
    
    var rect: CGRect {
        CGRect(x: boundingBoxX, y: boundingBoxY, width: boundingBoxWidth, height: boundingBoxHeight)
    }
}

enum FieldType: String, Codable {
    case text
    case multiLine
    case phone
    case email
    case date
    case pan
    case aadhaar
    case ifsc
    case number
    case currency
    case boolean
    case signature
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
        edited: Bool = false
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
