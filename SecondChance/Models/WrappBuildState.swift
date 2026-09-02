//
//  WrappBuildState.swift
//  SecondChance
//
//  Represents the current state of a wrapp build

import Foundation

/// Represents the current state of a wrapp build
enum WrappBuildState: Equatable {
    case idle
    case selectingWrappSource
    case selectingSource
    case detectingGame(substep: String? = nil, elapsedSeconds: Int? = nil)
    case settingUpWrapp(substep: String? = nil, elapsedSeconds: Int? = nil)
    case copyingInstaller(substep: String? = nil, elapsedSeconds: Int? = nil)
    case installingGame(substep: String? = nil, elapsedSeconds: Int? = nil)
    case configuringWrapp(substep: String? = nil, elapsedSeconds: Int? = nil)
    case savingApp(substep: String? = nil, elapsedSeconds: Int? = nil)
    case completed
    case error(String)
    
    private var baseText: String {
        switch self {
        case .idle:
            return "Ready"
        case .selectingWrappSource:
            return "Select Installation Type"
        case .selectingSource:
            return "Select Source"
        case .detectingGame:
            return "Detecting game title"
        case .settingUpWrapp:
            return "Setting up wrapper"
        case .copyingInstaller:
            return "Copying game installer"
        case .installingGame:
            return "Game installing"
        case .configuringWrapp:
            return "Configuring wrapper"
        case .savingApp:
            return "Saving new app"
        case .completed:
            return "Finished creating game"
        case .error(let message):
            return "Error: \(message)"
        }
    }
    
    var substep: String? {
        switch self {
        case .detectingGame(let substep, _),
             .settingUpWrapp(let substep, _),
             .copyingInstaller(let substep, _),
             .installingGame(let substep, _),
             .configuringWrapp(let substep, _),
             .savingApp(let substep, _):
            return substep
        default:
            return nil
        }
    }
    
    var elapsedSeconds: Int? {
        switch self {
        case .detectingGame(_, let elapsed),
             .settingUpWrapp(_, let elapsed),
             .copyingInstaller(_, let elapsed),
             .installingGame(_, let elapsed),
             .configuringWrapp(_, let elapsed),
             .savingApp(_, let elapsed):
            return elapsed
        default:
            return nil
        }
    }
    
    var displayText: String {
        var text = baseText
        
        // Add substep if available and elapsed time indicates we should show it
        if let substep = substep, elapsedSeconds != nil {
            text += " - \(substep)"
        } else if case .detectingGame = self {
            // Special case: detectingGame shows "..." when no substep
            text += "..."
        }
        
        // Add elapsed time if available (indicates step has run for 5+ seconds)
        if let elapsed = elapsedSeconds, elapsed > 0 {
            text += " (\(elapsed)s)"
        }
        
        return text
    }
    
    var progress: Double? {
        switch self {
        case .idle, .selectingWrappSource, .selectingSource:
            return nil
        case .detectingGame:
            return 0.1
        case .settingUpWrapp:
            return 0.2
        case .copyingInstaller:
            return 0.3
        case .installingGame:
            return 0.5
        case .configuringWrapp:
            return 0.8
        case .savingApp:
            return 0.9
        case .completed:
            return 1.0
        case .error:
            return nil
        }
    }
    
}
