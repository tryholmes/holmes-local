import SwiftUI
import Observation

enum SearchState {
    case idle
    case listening
    case processing
    case results
}

@Observable
@MainActor
class SearchViewModel {
    var searchText: String = ""
    var state: SearchState = .idle
    var isListening: Bool { VoiceInputController.shared.isListening }
    var partialTranscript: String { VoiceInputController.shared.partialTranscript }
    var suggestions: [String] = []
    var showResponse: Bool = false
    var responseText: String = ""
    var responseSubtitle: String = ""

    init() {
        setupDefaultSuggestions()
    }
    
    private func setupDefaultSuggestions() {
        suggestions = [
            "Organize my downloads folder",
            "Rename screenshots from today",
            "Find large files on desktop",
            "Create a new folder structure"
        ]
    }
    
    func submitSearch() {
        guard !searchText.isEmpty else { return }
        
        state = .processing
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                self.showResponse = true
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.state = .results
                self.responseSubtitle = "Processing your request..."
                self.responseText = ""
            }
        }
    }
    
    func goBackToSearch() {
        showResponse = false
        state = .idle
        responseText = ""
        responseSubtitle = ""
    }
    
    func reset() {
        searchText = ""
        state = .idle
        showResponse = false
        responseText = ""
        responseSubtitle = ""
    }
}
