//
//  ProgressTracker.swift
//  SecondChance
//
//  Tracks elapsed time for long-running operations

import Foundation

/// Tracks elapsed time for an operation and provides periodic updates
actor ProgressTracker {
    private var startTime: Date?
    private var timerTask: Task<Void, Never>?
    private var updateHandler: ((Int) -> Void)?
    
    /// Start tracking elapsed time
    /// - Parameters:
    ///   - updateInterval: How often to call the update handler (in seconds)
    ///   - updateHandler: Closure called periodically with elapsed seconds
    func start(updateInterval: TimeInterval = 5.0, updateHandler: @escaping (Int) -> Void) {
        startTime = Date()
        self.updateHandler = updateHandler
        
        // Cancel any existing timer
        timerTask?.cancel()
        
        // Start new timer task
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(updateInterval * 1_000_000_000))
                
                guard !Task.isCancelled, let startTime = self.startTime else { break }
                
                let elapsed = Int(Date().timeIntervalSince(startTime))
                updateHandler(elapsed)
            }
        }
    }
    
    /// Stop tracking and return total elapsed time
    /// - Returns: Total elapsed seconds
    func stop() -> Int {
        timerTask?.cancel()
        timerTask = nil
        updateHandler = nil
        
        guard let startTime = startTime else { return 0 }
        let elapsed = Int(Date().timeIntervalSince(startTime))
        self.startTime = nil
        
        return elapsed
    }
    
    /// Get current elapsed time without stopping
    func currentElapsed() -> Int {
        guard let startTime = startTime else { return 0 }
        return Int(Date().timeIntervalSince(startTime))
    }
}
