//
//  GameQuitCheck+RoutineErrors.swift
//  Shared
//
//  Generated from Modules/wine/routine-errors.yaml and
//  Modules/steam/routine-errors.yaml by `sc generate`. Don't edit it:
//  change the modules' data and run that again. A test fails when this
//  file isn't what the data makes.

nonisolated extension GameQuitCheck {
    /// Wine's err: lines that say nothing is wrong (the wine module's).
    static let routineErrors = [
        // this Wine has no Vulkan, and carries on without it
        ":err:vulkan:",
        // a note that a 32-bit game runs in wow64 mode
        ":err:environ:init_peb",
        // a USB device that isn't a game controller
        ":err:hid:",
        // network sign-in, unused
        ":err:winediag:ntlm_check_version",
        // network sign-in, unused
        ":err:ntlm:",
        // network sign-in, unused
        ":err:kerberos:",
        // Wine's desktop restoring the saved mode as it starts, refused on a 120
        // Hz display (the emulated modes are 60 Hz). A game asking for its own
        // mode names the display instead.
        "NtUserChangeDisplaySettings Changing (null) display settings",
        // A game's music played through Windows' media stack, stopped as the
        // game quits: Iji logs it on every quit from its own menu.
        ":err:quartz:send_buffer Failed to get a sample",
        // Wine 10's DirectMusic synthesiser stopping as it should, as a game
        // quits: it logs this on every stop (Iji, from its own menu).
        ":err:dmsynth:synth_sink_render_thread WaitForMultipleObjects returned 0",
        // The synthesiser falling behind for a moment: a click in the sound, not
        // a failure.
        ":err:dmsynth:synth_sink_write_data Underrun detected",
    ]

    /// What Steam logs as it starts, as well, for a game launched through it (the steam module's).
    static let routineSteamErrors = [
        // Windows notification and pen APIs Wine lacks
        ":err:combase:RoGetActivationFactory",
        // COM classes Steam asks for that Wine lacks
        ":err:ole:",
        // Steam's graphics probe, which needs a DLL it doesn't ship
        "gldriverquery.exe",
    ]
}
