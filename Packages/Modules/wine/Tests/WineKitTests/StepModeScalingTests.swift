import Foundation
import Testing
@testable import WineExecutor

struct StepModeScalingTests {
    @Test("A step that sets a display mode arms mode scaling in its program, by the .exe's name")
    func armed() {
        let options = ["wine.display-mode": "800x600x8"]
        #expect(WineExecutor.modeScalingVariables(program: "D:/Webmaster.exe", options: options, environment: [:])
                == ["EMULATED_MODE_SCALING_EXE": "Webmaster.exe"])
        #expect(WineExecutor.modeScalingVariables(program: #"C:\Setup\Setup.exe"#, options: options, environment: [:])
                == ["EMULATED_MODE_SCALING_EXE": "Setup.exe"])
    }

    @Test("Without a display mode, or with SECOND_CHANCE_MODE_SCALING=0, it isn't armed")
    func unarmed() {
        #expect(WineExecutor.modeScalingVariables(program: "D:/Webmaster.exe", options: [:], environment: [:]).isEmpty)
        #expect(WineExecutor.modeScalingVariables(program: "D:/Webmaster.exe", options: ["wine.display-mode": "800x600"],
                                                  environment: ["SECOND_CHANCE_MODE_SCALING": "0"]).isEmpty)
    }
}
