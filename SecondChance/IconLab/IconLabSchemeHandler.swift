//
//  IconLabSchemeHandler.swift
//  SecondChance
//
//  Answers the Icon Lab page's `iconlab://` requests, its files and its API
//  alike, by calling `IconLabAPI.handle` (no server on a port: decision 2
//  of the Icon Lab plan). The API answers off the main actor; WebKit is
//  told on the main one, and only while the page still wants the answer.

import Foundation
import IconLabAPI
import Logging
import WebKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab")

final class IconLabSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "iconlab"
    /// The page's address.
    static let home = URL(string: "iconlab://app/")

    private let api: IconLabAPI
    /// The tasks WebKit hasn't stopped; a stopped one must hear nothing more.
    private var live: Set<ObjectIdentifier> = []

    init(api: IconLabAPI) {
        self.api = api
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        live.insert(id)
        let request = urlSchemeTask.request
        guard let url = request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            live.remove(id)
            return
        }
        let method = request.httpMethod ?? "GET"
        let headers = request.allHTTPHeaderFields ?? [:]
        let body = request.httpBody
        let stream = body == nil ? request.httpBodyStream.map(BodyStream.init) : nil
        let api = api
        Task {
            let data = if let body { body } else if let stream { await Self.read(stream) } else { Data() }
            let answer = await api.handle(APIRequest(method: method, url: url, headers: headers, body: data))
            await respond(answer, to: urlSchemeTask, url: url)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        live.remove(ObjectIdentifier(urlSchemeTask))
    }

    /// Sends the answer: its head, then its body, a file's in pieces read off the main actor.
    private func respond(_ answer: APIResponse, to task: any WKURLSchemeTask, url: URL) async {
        let id = ObjectIdentifier(task)
        guard live.contains(id) else { return }
        var headers = answer.headers
        // WebKit wants the length for a file it's given in pieces; it works it out for data
        if case .file(let file) = answer.body, let size = Self.size(of: file) { headers["Content-Length"] = String(size) }
        guard let head = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            live.remove(id)
            return
        }
        task.didReceive(head)
        switch answer.body {
        case .empty:
            break
        case .data(let data):
            task.didReceive(data)
        case .file(let file):
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: file) } catch {
                logger.error("Couldn't open \(file.path) for the page: \(error)")
                task.didFailWithError(error)
                live.remove(id)
                return
            }
            defer { try? handle.close() }
            while live.contains(id) {
                let piece = await Self.readPiece(handle)
                guard let piece, !piece.isEmpty, live.contains(id) else { break }
                task.didReceive(piece)
            }
        }
        guard live.contains(id) else { return }
        task.didFinish()
        live.remove(id)
    }

    nonisolated private static func size(of file: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
    }

    /// Up to 256 KB of `handle`, read off the main actor; nil at the end, or when it can't be read.
    @concurrent
    nonisolated private static func readPiece(_ handle: FileHandle) async -> Data? {
        do { return try handle.read(upToCount: 256 * 1024) } catch {
            logger.error("Couldn't read a file for the page: \(error)")
            return nil
        }
    }

    /// A request body WebKit gave as a stream, carried off the main actor to be
    /// read. Only this request's task ever touches it.
    private nonisolated struct BodyStream: @unchecked Sendable {
        let stream: InputStream
    }

    /// A request body WebKit gave as a stream.
    @concurrent
    nonisolated private static func read(_ body: BodyStream) async -> Data {
        let stream = body.stream
        var data = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
