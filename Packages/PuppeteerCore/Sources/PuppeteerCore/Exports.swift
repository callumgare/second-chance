//
//  Exports.swift
//  PuppeteerCore
//
//  The picture matching WrappPuppeteer drives games with lives in a package
//  of its own (Packages/PictureMatching), so `sc` can use it without this
//  package's dependencies; re-exported, so importing PuppeteerCore still
//  brings `ImageFingerprint`, `TemplateMatcher` and `TextRecognizer`.

@_exported import PictureMatching
// The control sockets' requests and replies (Packages/PuppetProtocol), shared
// with sc the same way.
@_exported import PuppetProtocol
