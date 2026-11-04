//
//  OneTimeSignalTests.swift
//  SecondChanceKitTests

import Foundation
import Testing
@testable import ProcessKit
@testable import WindowsFormats
@testable import WrappFormat
@testable import WrappLogging

@Suite("One-time signal")
struct OneTimeSignalTests {
    @Test("A wait returns once it is signalled, from another thread")
    func signalled() async {
        let signal = OneTimeSignal()
        DispatchQueue.global().async { signal.signal() }
        await signal.wait()
        #expect(signal.isSignalled)
    }

    @Test("A wait that starts after the signal returns at once, and a second signal does nothing")
    func alreadySignalled() async {
        let signal = OneTimeSignal()
        signal.signal()
        signal.signal()
        await signal.wait()
        #expect(await signal.wait(timeout: .seconds(10)))
    }

    @Test("A wait with a timeout says when nothing came")
    func timesOut() async {
        let signal = OneTimeSignal()
        #expect(await signal.wait(timeout: .milliseconds(50)) == false)
        #expect(!signal.isSignalled)
    }

    @Test("Every waiter is let through")
    func manyWaiters() async {
        let signal = OneTimeSignal()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { await signal.wait() } }
            group.addTask { signal.signal() }
        }
        #expect(signal.isSignalled)
    }

    @Test("Cancelling a waiting task ends its wait")
    func cancelled() async {
        let signal = OneTimeSignal()
        let waiting = Task { await signal.wait() }
        waiting.cancel()
        await waiting.value
        #expect(!signal.isSignalled)
    }
}
