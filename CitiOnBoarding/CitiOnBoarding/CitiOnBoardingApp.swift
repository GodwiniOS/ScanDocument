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
                ExportRecord.self,
                SignatureAsset.self
            ])
            let config = ModelConfiguration(schema: schema)
            container = try ModelContainer(for: schema, configurations: config)
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
}
