//
//  TextFile.swift
//  SecondChance
//
//  The text files games and installers leave (INI files, `setup.ini`,
//  `autorun.inf`, installer logs) were written on Windows: in UTF-16 with a
//  byte-order mark, in UTF-8, or in Windows-1252, where a title's ® or an
//  accented name isn't valid UTF-8. Reading them as UTF-8 alone lost such a
//  file whole.

import Foundation

nonisolated enum TextFile {
    /// The file's text, and the encoding it was in (to write it back in);
    /// nil if it can't be read.
    static func read(_ url: URL) -> (text: String, encoding: String.Encoding)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return (text, .utf16)
        }
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8)
        }
        // Every byte is a character in Windows-1252, bar five unassigned
        // ones, which Latin-1 takes instead.
        if let text = String(data: data, encoding: .windowsCP1252) {
            return (text, .windowsCP1252)
        }
        return String(data: data, encoding: .isoLatin1).map { ($0, .isoLatin1) }
    }

    /// Just the text.
    static func text(of url: URL) -> String? {
        read(url)?.text
    }
}
