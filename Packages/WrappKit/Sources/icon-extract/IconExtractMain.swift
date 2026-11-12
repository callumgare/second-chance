//
//  IconExtractMain.swift
//  icon-extract
//
//  icon-extract <input> --out <folder> [options]
//
//  Every image in a program, its installer, its disc or its wrapp, written
//  as <sha256>.png with records.jsonl beside them, and the crawl's progress
//  as JSON lines on stdout (docs/program-images.md has both schemas). Logs
//  go to stderr.

import Foundation
import Logging
import ProgramImages

@main
struct IconExtractMain {
    static let usage = """
    usage: icon-extract <input> --out <folder> [options]

      <input>               an installer, a disc image, an installed program's folder or a wrapp
      --out <folder>        where <sha256>.png and records.jsonl go
      --work <folder>       where tools unpack to (default: a temporary folder, removed after)
      --max-depth <n>       containers deep to go (default 8)
      --budget-mb <n>       most tools may unpack, in MB (default: 4 × the input, at least 2048)
      --tool-timeout <s>    seconds a tool may run (default 120; discs 600)
      --no-tools            read only what Swift reads natively
      --no-carve            don't look for images by their signatures
      --no-video            don't take frames from videos
      --filters <file>      a filter table in place of the shipped one
      --verbose             log debug lines to stderr
    """

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let verbose = arguments.contains("--verbose")
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = verbose ? .debug : .notice
            return handler
        }
        arguments.removeAll { $0 == "--verbose" }

        var input: URL?
        var output: URL?
        var options = ExtractionOptions(outputDirectory: URL(fileURLWithPath: "."))
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data((message + "\n\n" + usage + "\n").utf8))
            exit(2)
        }
        var index = 0
        func value() -> String {
            index += 1
            guard index < arguments.count else { fail("\(arguments[index - 1]) needs a value") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--out": output = URL(fileURLWithPath: value())
            case "--work": options.workDirectory = URL(fileURLWithPath: value())
            case "--max-depth": options.maxDepth = Int(value()) ?? options.maxDepth
            case "--budget-mb": options.byteBudget = (Int(value()) ?? 2048) << 20
            case "--tool-timeout": options.toolTimeout = TimeInterval(value()) ?? options.toolTimeout
            case "--no-tools": options.useTools = false
            case "--no-carve": options.carve = false
            case "--no-video": options.videoFrames = false
            case "--filters":
                do {
                    options.filter = try PathFilter(contentsOf: URL(fileURLWithPath: value()))
                } catch {
                    fail("Couldn't read the filter table: \(error)")
                }
            case "-h", "--help":
                FileHandle.standardOutput.write(Data((usage + "\n").utf8))
                exit(0)
            default:
                if argument.hasPrefix("-") || input != nil { fail("Unexpected \(argument)") }
                input = URL(fileURLWithPath: argument)
            }
            index += 1
        }
        guard let input, let output else { fail("Both an input and --out are needed") }
        options.outputDirectory = output

        let lines = LineWriter()
        do {
            _ = try await ProgramImageExtractor.extract(input, options: options) { event in
                lines.write(event.jsonLine)
            }
        } catch {
            FileHandle.standardError.write(Data("icon-extract: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

/// Whole lines to stdout, one at a time.
nonisolated final class LineWriter: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
