import Testing
import Logging
@testable import SecondChance

@Suite("Subprocess line classifier")
struct SubprocessLineClassifierTests {

    @Test("Lines pick their level from what they say", arguments: [
        // Wine debug classes, with and without the pid:tid prefix.
        ("0124:err:module:import_dll Loading library Ndui.dll failed (error c000007b).", Logger.Level.error),
        ("00d8:err:winediag:nodrv_CreateWindow Application tried to create a window, but no driver could be loaded.", .error),
        ("err:ntdll:something went wrong", .error),
        ("0024:fixme:ntdll:NtQuerySystemInformation info_class SYSTEM_PERFORMANCE_INFORMATION", .debug),
        ("0024:warn:seh:dispatch_exception", .debug),
        // The one err: line every healthy launch prints.
        ("014c:err:environ:init_peb starting L\"C:\\\\Secrets.exe\" in experimental wow64 mode", .debug),
        // Crashes and start failures.
        ("wine: Unhandled page fault on read access to 00000000 at address 0040120A", .critical),
        ("ShellExecuteEx failed: Environment variable not found.", .error),
        ("Application could not be started, or no application associated with the specified file.", .error),
        // Routine chatter.
        ("msync: bootstrapped mach port on wine-ff307da-msync.", .debug),
        ("[mvk-info] MoltenVK version 1.4.1, supporting Vulkan version 1.4.334.", .debug),
        ("\tVK_KHR_16bit_storage v1", .debug),
        ("[mvk-warn] VK_ERROR_FEATURE_NOT_PRESENT", .warning),
        ("[mvk-error] Could not create device", .error),
        // ScummVM.
        ("WARNING: Could not find theme 'scummremastered' falling back to builtin!", .warning),
        ("ERROR: Could not open file", .error),
        ("WARNING: Game data not found!", .error),
        ("WARNING: ScummVM could not find any game in /x/disk-combined", .error),
        // The in-process helpers name their own level.
        ("second-chance-helper[CursorLock] notice: armed in Game.exe", .notice),
        ("second-chance-helper[NativeFullscreen] warning: no eligible window after 90s; staying windowed", .warning),
        ("second-chance-helper[NativeFullscreen] error: could not start watcher thread", .error),
    ])
    func classifies(line: String, expected: Logger.Level) {
        #expect(SubprocessLineClassifier.level(for: line, fallback: .notice) == expected)
    }

    @Test("Anything unrecognised gets the stream's fallback")
    func fallsBack() {
        #expect(SubprocessLineClassifier.level(for: "reg: The operation completed successfully", fallback: .notice) == .notice)
        #expect(SubprocessLineClassifier.level(for: "something on stderr", fallback: .warning) == .warning)
        // A time of day is not a Wine debug class.
        #expect(SubprocessLineClassifier.level(for: "12:30:01 err happened", fallback: .notice) == .notice)
    }

    @Test("MSI log lines worth reading stand out from per-file chatter")
    func msiLog() {
        #expect(InstallerLogStreamer.notableLevel(of: "File: s12.cif, Directory: dir1, Size: 2048", format: .msi) == nil)
        #expect(InstallerLogStreamer.notableLevel(of: "Action ended 12:01:02: InstallFiles. Return value 3.", format: .msi) == .error)
        #expect(InstallerLogStreamer.notableLevel(of: "Error 1335. The cabinet file is corrupt.", format: .msi) == .error)
        #expect(InstallerLogStreamer.notableLevel(of: "MSI (s) (1C:20) [12:01:02:003]: Product: Nancy Drew -- Installation completed successfully.", format: .msi) == .notice)
    }

    @Test("Inno Setup log lines worth reading stand out from per-file chatter")
    func innoLog() {
        #expect(InstallerLogStreamer.notableLevel(
            of: "2026-10-16 20:27:06.623   Dest filename: C:\\Program Files (x86)\\Nancy Drew SCK\\Video\\CWH51_CNV.bik", format: .inno) == nil)
        #expect(InstallerLogStreamer.notableLevel(of: "2026-10-16 20:25:22.993   Installation process succeeded.", format: .inno) == .notice)
        #expect(InstallerLogStreamer.notableLevel(of: "2026-10-16 20:25:22.993   Exception message:", format: .inno) == .error)
    }
}
