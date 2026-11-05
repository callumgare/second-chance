import ArgumentParser
import Foundation

/// Run by `session add` in the console user's GUI session, where macOS can
/// ask to allow exporting the signing key: prints the development identities
/// as base64 JSON (`SigningIdentity.Exported`).
struct SessionExportSigningCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-signing-identities",
        abstract: "Print this user's development signing identities for session add (run in the GUI session).",
        shouldDisplay: false
    )

    @Option var passphrase: String

    func run() async throws {
        let found = SigningIdentity.development()
        guard !found.isEmpty else { throw ExitCode(3) }
        let exported = SigningIdentity.Exported(p12: try SigningIdentity.export(found, passphrase: passphrase),
                                                intermediates: SigningIdentity.intermediates(found))
        FileHandle.standardOutput.write(Data(try JSONEncoder().encode(exported).base64EncodedString().utf8))
    }
}
