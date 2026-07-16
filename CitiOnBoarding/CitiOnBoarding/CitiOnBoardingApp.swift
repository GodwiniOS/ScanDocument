import SwiftUI
import SwiftData

@main
struct CitiOnBoardingApp: App {
    var container: ModelContainer
    
    init() {
        do {
            let schema = Schema([
                DocumentSession.self,
                Template.self,
                Page.self,
                Field.self,
                FieldResult.self,
                UserCorrection.self,
                ExportRecord.self
            ])
            let config = ModelConfiguration(schema: schema)
            container = try ModelContainer(for: schema, configurations: config)
            
            // Seed templates immediately
            seedTemplates()
        } catch {
            fatalError("Failed to configure SwiftData ModelContainer: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
    
    @MainActor
    private func seedTemplates() {
        let context = container.mainContext
        let descriptor = FetchDescriptor<Template>()
        if let count = try? context.fetchCount(descriptor), count == 0 {
            // Seed Template 1: Credit Card
            let ccTemplate = Template(name: "Citi Credit Card Application", version: "1.0")
            context.insert(ccTemplate)
            
            let fields = [
                Field(name: "Full Name", expectedType: .text, boundingBox: CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.04), isRequired: true, isHandwritten: true),
                Field(name: "Date of Birth", expectedType: .date, boundingBox: CGRect(x: 0.1, y: 0.22, width: 0.4, height: 0.04), isRequired: true, isHandwritten: true),
                Field(name: "Phone Number", expectedType: .phone, boundingBox: CGRect(x: 0.55, y: 0.22, width: 0.35, height: 0.04), isRequired: true, isHandwritten: true),
                Field(name: "Email Address", expectedType: .email, boundingBox: CGRect(x: 0.1, y: 0.29, width: 0.8, height: 0.04), isRequired: false, isHandwritten: true),
                Field(name: "PAN Card", expectedType: .pan, boundingBox: CGRect(x: 0.1, y: 0.36, width: 0.4, height: 0.04), isRequired: true, isHandwritten: true),
                Field(name: "Aadhaar Number", expectedType: .aadhaar, boundingBox: CGRect(x: 0.55, y: 0.36, width: 0.35, height: 0.04), isRequired: true, isHandwritten: true),
                Field(name: "IFSC Code", expectedType: .ifsc, boundingBox: CGRect(x: 0.1, y: 0.43, width: 0.4, height: 0.04), isRequired: true, isHandwritten: true),
                Field(name: "Account Number", expectedType: .number, boundingBox: CGRect(x: 0.55, y: 0.43, width: 0.35, height: 0.04), isRequired: true, isHandwritten: true),
                Field(name: "Signature Box", expectedType: .signature, boundingBox: CGRect(x: 0.1, y: 0.65, width: 0.4, height: 0.08), isRequired: true, isHandwritten: true)
            ]
            
            for field in fields {
                field.template = ccTemplate
                context.insert(field)
            }
            
            // Seed Template 2: Loan Form
            let loanTemplate = Template(name: "Citi Personal Loan Form", version: "1.0")
            context.insert(loanTemplate)
            
            let loanFields = [
                Field(name: "Borrower Name", expectedType: .text, boundingBox: CGRect(x: 0.1, y: 0.25, width: 0.8, height: 0.05), isRequired: true, isHandwritten: true),
                Field(name: "Loan Amount Requested", expectedType: .currency, boundingBox: CGRect(x: 0.1, y: 0.35, width: 0.8, height: 0.05), isRequired: true, isHandwritten: true)
            ]
            
            for field in loanFields {
                field.template = loanTemplate
                context.insert(field)
            }
            
            try? context.save()
        }
    }
}
