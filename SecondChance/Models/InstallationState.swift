//
//  InstallationState.swift
//  SecondChance
//
//  Represents the current state of a game installation

import Foundation

/// Represents the current state of a game installation process
enum InstallationState: Equatable {
    case idle
    case selectingInstallationType
    case selectingSource
    case detectingGame(substep: String? = nil, elapsedSeconds: Int? = nil)
    case settingUpWrapper(substep: String? = nil, elapsedSeconds: Int? = nil)
    case copyingInstaller(substep: String? = nil, elapsedSeconds: Int? = nil)
    case installingGame(substep: String? = nil, elapsedSeconds: Int? = nil)
    case configuringWrapper(substep: String? = nil, elapsedSeconds: Int? = nil)
    case savingApp(substep: String? = nil, elapsedSeconds: Int? = nil)
    case completed
    case error(String)
    
    private var baseText: String {
        switch self {
        case .idle:
            return "Ready"
        case .selectingInstallationType:
            return "Select Installation Type"
        case .selectingSource:
            return "Select Source"
        case .detectingGame:
            return "Detecting game title"
        case .settingUpWrapper:
            return "Setting up wrapper"
        case .copyingInstaller:
            return "Copying game installer"
        case .installingGame:
            return "Game installing"
        case .configuringWrapper:
            return "Configuring wrapper"
        case .savingApp:
            return "Saving new app"
        case .completed:
            return "Finished creating game"
        case .error(let message):
            return "Error: \(message)"
        }
    }
    
    private var substep: String? {
        switch self {
        case .detectingGame(let substep, _),
             .settingUpWrapper(let substep, _),
             .copyingInstaller(let substep, _),
             .installingGame(let substep, _),
             .configuringWrapper(let substep, _),
             .savingApp(let substep, _):
            return substep
        default:
            return nil
        }
    }
    
    private var elapsedSeconds: Int? {
        switch self {
        case .detectingGame(_, let elapsed),
             .settingUpWrapper(_, let elapsed),
             .copyingInstaller(_, let elapsed),
             .installingGame(_, let elapsed),
             .configuringWrapper(_, let elapsed),
             .savingApp(_, let elapsed):
            return elapsed
        default:
            return nil
        }
    }
    
    var displayText: String {
        var text = baseText
        
        // Add substep and elapsed time if >= 5 seconds
        if let elapsed = elapsedSeconds, elapsed >= 5 {
            if let substep = substep {
                text += " - \(substep)"
            }
            // Round to nearest 5 seconds for display
            let roundedElapsed = (elapsed / 5) * 5
            text += " (\(roundedElapsed)s elapsed)"
        } else if case .detectingGame = self {
            // Special case: detectingGame shows "..." when < 5 seconds
            text += "..."
        }
        
        return text
    }
    
    var progress: Double? {
        switch self {
        case .idle, .selectingInstallationType, .selectingSource:
            return nil
        case .detectingGame:
            return 0.1
        case .settingUpWrapper:
            return 0.2
        case .copyingInstaller:
            return 0.3
        case .installingGame:
            return 0.5
        case .configuringWrapper:
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
