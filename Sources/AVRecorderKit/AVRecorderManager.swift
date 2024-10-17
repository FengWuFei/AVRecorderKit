import Foundation

public final class AVRecordManager: @unchecked Sendable  {
    public var storage: [String: AVRecorderContext] = [:]
    private var workeQueue: DispatchQueue
    private var lock: NSLock
    
    public enum StartState {
        case success
        case fail(Error)
    }
    
    public init() {
        self.workeQueue = DispatchQueue(label: ".com.ly.AVRecorder.workQueue", attributes: .concurrent)
        self.lock = NSLock()
    }
    
    public func get(_ key: String) -> AVRecorderContext?{
        lock.withLock {
            storage[key]
        }
    }
    
    public func set(key: String, value: AVRecorderContext) {
        lock.withLock {
            storage[key] = value
        }
    }
    
    public func remove(key: String) {
        _ = lock.withLock {
            storage.removeValue(forKey: key)
        }
    }
    
    public func startStreamRecoderWith(inputUrl: String, outputDirectory: URL, streamName: String, completeHandler: @escaping (StartState) -> Void) {
        if let rCtx = get(streamName) {
            if rCtx.state == .stop {
                let workItem = DispatchWorkItem(qos: .default) {
                    do {
                        let successHandler = {
                            completeHandler(.success)
                        }
                        try rCtx.start(successHandler)
                    } catch {
                        completeHandler(.fail(error))
                    }
                }
                workeQueue.async(execute: workItem)
            } else {
                completeHandler(.success)
            }
        } else {
            let rCtx = AVRecorderContext(inputUrl: inputUrl, outputDirectory: outputDirectory, streamName: streamName)
            // 退出从storage中清除
            rCtx.onExit { [weak self] in
                _ = self?.lock.withLock {
                    self?.storage.removeValue(forKey: streamName)
                }                
            }
            let workItem = DispatchWorkItem(qos: .default) {
                do {
                    let successHandler = { [weak self] in
                        // 成功启动加入storage
                        self?.set(key: streamName, value: rCtx)
                        completeHandler(.success)
                    }
                    try rCtx.start(successHandler)
                } catch {
                    completeHandler(.fail(error))
                }
            }
            workeQueue.async(execute: workItem)
        }
    }
    
    public func stopStreamRecoderWith(streamName: String, completeHandler: @escaping () -> Void) {
        guard let rCtx = get(streamName) else {
            completeHandler()
            return
        }
        rCtx.stop(completeHandler)
    }
}
