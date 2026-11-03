//  main.swift (patch-ntdll)
//  Adds the Rosetta fault fix to Wine's 32-bit ntdll.dll, in place.
//  setup-wine.sh compiles it together with RosettaFaultFix.swift (in
//  SecondChanceKit, where its tests are) and runs it on the engine.
//
//  Usage: patch-ntdll <path-to-i386-windows/ntdll.dll>

import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: patch-ntdll <ntdll.dll>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    let (patched, outcome) = try RosettaFaultFix.patch(Data(contentsOf: url))
    switch outcome {
    case .alreadyPatched:
        FileHandle.standardOutput.write(Data("ntdll.dll already has the Rosetta fault fix\n".utf8))
    case .patched:
        try patched.write(to: url)
        FileHandle.standardOutput.write(Data("Added the Rosetta fault fix to ntdll.dll\n".utf8))
    }
} catch {
    FileHandle.standardError.write(Data("error: patching \(url.path): \(error)\n".utf8))
    exit(1)
}
