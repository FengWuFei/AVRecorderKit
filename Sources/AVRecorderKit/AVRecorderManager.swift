import Foundation
import class NIOConcurrencyHelpers.Lock
import NIO

public class AVRecordManager {
    public var storage: [String: AVRecorderContext] = [:]
    private var workeQueue: DispatchQueue
    private var lock: Lock
    
    
    public enum StartState {
        case success
        case fail(Error)
    }
    
    public init() {
        self.workeQueue = DispatchQueue(label: ".com.ly.AVRecorder.workQueue", attributes: .concurrent)
        self.lock = Lock()
    }
    
    public func get(_ key: String) -> AVRecorderContext?{
        lock.withLock {
            storage[key]
        }
    }
    
    public func set(key: String, value: AVRecorderContext) {
        lock.withLockVoid {
            storage[key] = value
        }
    }
    
    public func remove(key: String) {
        lock.withLockVoid {
            storage.removeValue(forKey: key)
        }
    }
    
    public func startStreamRecoderWith(inputUrl: String, outputDirectory: URL, streamName: String, completeHandler: @escaping (StartState) -> Void) {
        if let rCtx = get(streamName) {
            if rCtx.state == .stop {
                workeQueue.async {
                    do {
                        let successHandler = {
                            completeHandler(.success)
                        }
                        try rCtx.start(successHandler)
                    } catch {
                        completeHandler(.fail(error))
                    }
                }
            } else {
                completeHandler(.success)
            }
        } else {
            let rCtx = AVRecorderContext(inputUrl: inputUrl, outputDirectory: outputDirectory, streamName: streamName)
            // 退出从storage中清除
            rCtx.onExit { [weak self] in
                self?.lock.withLockVoid {
                    self?.storage.removeValue(forKey: streamName)
                }                
            }
            workeQueue.async {
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
