//
//  WrappBuildStrategy.swift
//  SecondChance
//
//  The contract every per-source wrapp builder conforms to, so the ViewModel
//  and CLIBuilder can invoke any source uniformly.
//

import Foundation

/// Builds a wrapp from one installation source (disk, Her download, Steam).
///
/// Each conformer owns its build flow end-to-end — including cleanup of the
/// resources it creates (mounted ISOs, temp wrapps) on both success and error
/// paths — and is the single entry point for that source.
protocol WrappBuildStrategy {
    /// Run the complete build for this source.
    ///
    /// - Parameter input: unified user/env I/O (paths, output location,
    ///   confirmations, callbacks).
    /// - Returns: the final saved wrapp path.
    func build(input: WrappBuildInput) async throws -> URL
}
