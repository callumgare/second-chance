//
//  Data+LittleEndian.swift
//  WindowsFormats
//
//  Reading the little-endian integers Windows file formats are made of
//  (WindowsExecutable, MSISummary), bounds-checked: nil past the end, never
//  a crash.

import Foundation

extension Data {
    /// From a zero-based offset, whatever the data's own start index.
    nonisolated public func u8(at offset: Int) -> Int? {
        guard offset >= 0, offset < count else { return nil }
        return Int(self[startIndex + offset])
    }

    nonisolated public func u16(at offset: Int) -> Int? {
        guard let low = u8(at: offset), let high = u8(at: offset + 1) else { return nil }
        return low | high << 8
    }

    nonisolated public func u32(at offset: Int) -> Int? {
        guard let low = u16(at: offset), let high = u16(at: offset + 2) else { return nil }
        return low | high << 16
    }
}
