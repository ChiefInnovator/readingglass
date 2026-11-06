import Foundation

/// URLSession writes large responses to disk. Only small resume metadata and
/// throttled byte counts enter memory; model weights never become one Data value.
struct ModelDownloader: ModelDownloading {
    func download(url: URL, to destination: URL, expectedBytes: Int64,
                  progress: @escaping @Sendable (Int64) async -> Void) async throws {
        let resumeURL = destination.appendingPathExtension("resume")
        let metadataURL = destination.appendingPathExtension("resume.json")
        var resumeData: Data?
        if let metadata = try? JSONDecoder().decode(ResumeMetadata.self, from: Data(contentsOf: metadataURL)),
           metadata.url == url.absoluteString, metadata.expectedBytes == expectedBytes,
           (try? resumeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 < 1_048_576 }) == true {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               http.expectedContentLength == expectedBytes,
               metadata.matches(http) {
                resumeData = try? Data(contentsOf: resumeURL)
            }
        }
        if resumeData == nil {
            try? FileManager.default.removeItem(at: resumeURL)
            try? FileManager.default.removeItem(at: metadataURL)
        }
        try Task.checkCancellation()
        do {
            try await perform(url: url, destination: destination, expectedBytes: expectedBytes,
                              resumeData: resumeData, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard resumeData != nil else { throw error }
            // URLSession can no longer resume if its temporary partial file was
            // evicted. Restart this file, retaining all other verified files.
            try? FileManager.default.removeItem(at: resumeURL)
            try? FileManager.default.removeItem(at: metadataURL)
            try Task.checkCancellation()
            try await perform(url: url, destination: destination, expectedBytes: expectedBytes,
                              resumeData: nil, progress: progress)
        }
    }

    private func perform(url: URL, destination: URL, expectedBytes: Int64, resumeData: Data?,
                         progress: @escaping @Sendable (Int64) async -> Void) async throws {
        let (counts, continuation) = AsyncStream<Int64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let reporter = Task {
            for await count in counts { await progress(count) }
        }
        let operation = DiskDownload(url: url, destination: destination, expectedBytes: expectedBytes,
                                     resumeData: resumeData) { continuation.yield($0) }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await operation.run()
            } onCancel: {
                operation.cancel()
            }
            continuation.finish()
            await reporter.value
        } catch {
            continuation.finish()
            await reporter.value
            throw error
        }
    }
}

private struct ResumeMetadata: Codable {
    let url: String
    let expectedBytes: Int64
    let etag: String?
    let lastModified: String?

    init(url: URL, expectedBytes: Int64, response: HTTPURLResponse) {
        self.url = url.absoluteString
        self.expectedBytes = expectedBytes
        let candidate = response.value(forHTTPHeaderField: "ETag")
        etag = candidate?.hasPrefix("W/") == false ? candidate : nil
        lastModified = response.value(forHTTPHeaderField: "Last-Modified")
    }

    var hasValidator: Bool { etag != nil || lastModified != nil }

    func matches(_ response: HTTPURLResponse) -> Bool {
        if let etag { return response.value(forHTTPHeaderField: "ETag") == etag }
        if let lastModified { return response.value(forHTTPHeaderField: "Last-Modified") == lastModified }
        return false
    }
}

/// Mutable delegate state is guarded by the lock; delegate callbacks use a
/// serial queue, while cancellation may arrive on any executor.
private final class DiskDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let destination: URL
    private let expectedBytes: Int64
    private let resumeData: Data?
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancellationRequested = false
    private var finished = false
    private var lastProgress = Date.distantPast

    init(url: URL, destination: URL, expectedBytes: Int64, resumeData: Data?,
         progress: @escaping @Sendable (Int64) -> Void) {
        self.url = url
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.resumeData = resumeData
        self.progress = progress
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            let task: URLSessionDownloadTask
            if let resumeData { task = session.downloadTask(withResumeData: resumeData) }
            else { task = session.downloadTask(with: url) }
            let wasCancelled = lock.withLock {
                self.continuation = continuation
                self.session = session
                self.task = task
                return cancellationRequested
            }
            if wasCancelled { cancelTask(task) }
            else { task.resume() }
        }
    }

    func cancel() {
        let activeTask = lock.withLock {
            cancellationRequested = true
            return task
        }
        if let activeTask { cancelTask(activeTask) }
    }

    private func cancelTask(_ task: URLSessionDownloadTask) {
        // Foundation's resume payload retains the partial disk file and issues
        // a validated Range request on retry. Reuse also requires our HEAD check.
        task.cancel { [self] data in
            if let data, data.count < 1_048_576,
               let response = task.response as? HTTPURLResponse {
                let metadata = ResumeMetadata(url: url, expectedBytes: expectedBytes, response: response)
                if metadata.hasValidator {
                    try? data.write(to: destination.appendingPathExtension("resume"), options: .atomic)
                    if let encoded = try? JSONEncoder().encode(metadata) {
                        try? encoded.write(to: destination.appendingPathExtension("resume.json"), options: .atomic)
                    }
                }
            }
            finish(.failure(CancellationError()))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = Date()
        if now.timeIntervalSince(lastProgress) >= 0.1 || totalBytesWritten == expectedBytes {
            lastProgress = now
            progress(min(totalBytesWritten, expectedBytes))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard !lock.withLock({ cancellationRequested }) else { return }
        guard let response = downloadTask.response as? HTTPURLResponse else {
            finish(.failure(ModelInstallError.downloadFailed(NSURLErrorBadServerResponse)))
            return
        }
        guard [200, 206].contains(response.statusCode) else {
            finish(.failure(ModelInstallError.httpStatus(response.statusCode)))
            return
        }
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size.map(Int64.init) == expectedBytes else {
                throw ModelInstallError.invalidFile(destination.lastPathComponent)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            try? FileManager.default.removeItem(at: destination.appendingPathExtension("resume"))
            try? FileManager.default.removeItem(at: destination.appendingPathExtension("resume.json"))
            progress(expectedBytes)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !lock.withLock({ cancellationRequested }) else { return }
        if let error { finish(.failure(ModelInstallError.downloadFailed((error as NSError).code))) }
    }

    private func finish(_ result: Result<Void, Error>) {
        let completion = lock.withLock { () -> (CheckedContinuation<Void, Error>, URLSession?)? in
            guard !finished, let continuation else { return nil }
            finished = true
            self.continuation = nil
            let session = self.session
            self.session = nil
            task = nil
            return (continuation, session)
        }
        guard let completion else { return }
        completion.0.resume(with: result)
        completion.1?.finishTasksAndInvalidate()
    }
}
