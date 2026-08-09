//
//  ViewExtensions.swift
//  SecondChance
//
//  SwiftUI view extensions

import SwiftUI

extension View {
    /// Custom cursor modifier
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
