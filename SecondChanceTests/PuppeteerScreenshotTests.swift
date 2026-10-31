//
//  PuppeteerScreenshotTests.swift
//  SecondChanceTests
//
//  The integration test attaches the screenshots WrappPuppeteer logs when a
//  run goes wrong, found by their 📸 lines.

import Testing
@testable import SecondChance

@Suite("WrappPuppeteer's screenshots")
struct PuppeteerScreenshotTests {
    @Test("Each 📸 line's path is found, and nothing else")
    func findsPaths() {
        let log = """
        10:51:57.314  error  WrappPuppeteer/NancyDrewQuitScenario  ❌ No Exit button or logo found within 300s
        10:51:57.367  notice  WrappPuppeteer/NancyDrewQuitScenario  📸 Game window: /tmp/exit-not-found-window-1793490717.png
        10:51:57.503  notice  WrappPuppeteer/NancyDrewQuitScenario  📸 Full screen screenshot: /tmp/exit-not-found-screen-1793490717.png
        10:51:57.503  notice  WrappPuppeteer/WindowFinder  📋 Current windows on screen: /tmp/not-a-screenshot.png
        """
        #expect(AppPuppetRunner.screenshotPaths(in: log) == [
            "/tmp/exit-not-found-window-1793490717.png",
            "/tmp/exit-not-found-screen-1793490717.png",
        ])
    }

    @Test("A log without screenshots has none")
    func none() {
        #expect(AppPuppetRunner.screenshotPaths(in: "10:51:57.503  notice  WrappPuppeteer/main  run_succeeded").isEmpty)
    }
}
