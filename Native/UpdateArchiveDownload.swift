import Foundation
import SlateTermCore

/// This download never starts an installer or changes the app bundle.
@MainActor
final class UpdateArchiveDownload: NSObject, URLSessionDownloadDelegate {
    nonisolated let directory: URL
    nonisolated let expectedLength: UInt64
    nonisolated let progress: @Sendable (UInt64) -> Void
    nonisolated let completion: @Sendable (Result<URL, Error>) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    init(expectedLength: UInt64, progress: @escaping @Sendable (UInt64) -> Void,
         completion: @escaping @Sendable (Result<URL, Error>) -> Void) throws {
        self.expectedLength = expectedLength
        self.progress = progress
        self.completion = completion
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-update-" + UUID().uuidString, isDirectory: true)
        super.init()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func start(_ url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        task = session.downloadTask(with: request)
        task?.resume()
    }

    func cleanup() {
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
        task = nil
        try? FileManager.default.removeItem(at: directory)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        completionHandler(url?.scheme?.lowercased() == "https" && url?.user == nil && url?.password == nil ? request : nil)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten >= 0, UInt64(totalBytesWritten) <= expectedLength,
              UInt64(totalBytesWritten) <= UpdateArchiveVerifier.maxArchiveBytes else {
            downloadTask.cancel()
            completion(.failure(RPCFailure(code: APIError.unavailable, message: "The update exceeded its signed size.")))
            return
        }
        progress(UInt64(totalBytesWritten))
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme?.lowercased() == "https" else {
                throw RPCFailure(code: APIError.unavailable, message: "The server did not return a secure update download.")
            }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard size >= 0, UInt64(size) == expectedLength else {
                throw RPCFailure(code: APIError.unavailable, message: "The download did not match its signed size.")
            }
            let destination = directory.appendingPathComponent("archive")
            try FileManager.default.moveItem(at: location, to: destination)
            completion(.success(destination))
        } catch { completion(.failure(error)) }
        session.finishTasksAndInvalidate()
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { completion(.failure(error)) }
    }
}
