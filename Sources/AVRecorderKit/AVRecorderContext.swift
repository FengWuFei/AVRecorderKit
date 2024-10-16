import Foundation
import SwiftFFmpeg
import Logging

public class AVRecorderContext {
    public enum AVRecorderState: String {
        case recording, interrupt, stop
    }
    
    public var state: AVRecorderState
    
    private var shouldStopReadFrame: Bool
    private var shouldOpenNewFile: Bool
    
    private var inputFmtCtx: AVFormatContext!
    private var outputFmtCtx: AVFormatContext?
    private var outputStreamMapping: [Int]?
    
    private var newOutputFmtCtx: AVFormatContext?
    private var newOutputStreamMapping: [Int]?
    
    private var lastReadFrameTime: Date
    
    public private(set) var inputUrl: String
    public private(set) var outputDirectory: URL
    public private(set) var streamName: String
    
    private var stopCompleteHandler: (() -> Void)?
    private var onExitHandler: (() -> Void)?
    private var onSliceCompleteHandler: (() -> Void)?
    
    private var logger: Logger
            
    public init(inputUrl: String, outputDirectory: URL, streamName: String = UUID().uuidString, logger: Logger = .init(label: "codes.app.avrecoderkit")) {
        self.inputUrl = inputUrl
        self.outputDirectory = outputDirectory
        self.streamName = streamName
        self.logger = logger
        self.state = .stop
        self.shouldOpenNewFile = false
        self.shouldStopReadFrame = false
        self.lastReadFrameTime = .distantFuture
    }
    
    private func startInputFmtCtx() throws {
        inputFmtCtx = AVFormatContext()
        lastReadFrameTime = .init()
        
        // 配置interruptCallback，防止readFrame阻塞
        let unmanagedSelf = Unmanaged.passUnretained(self)
        let unmanagedPtr = unmanagedSelf.toOpaque()
        inputFmtCtx.interruptCallback.opaque = unmanagedPtr
        inputFmtCtx.interruptCallback.callback = { ptr -> Int32 in
            guard let ptr = ptr else { return 1 }
            let `self` = Unmanaged<AVRecorderContext>.fromOpaque(ptr).takeUnretainedValue()
            let interval = Date().timeIntervalSince(self.lastReadFrameTime)
            if interval > 5 {
                switch self.state {
                case .recording:
                    // 关闭输出
                    self.noCatchError(self.streamName) {
                        try self.closeOutputFmtCtx()
                        self.state = .interrupt
                        self.logger.warning(.init(stringLiteral: "\(self.streamName)中断"))
                    }
                case .stop:
                    // 读取输入超时，启动失败
                    return 1
                default:
                    break
                }
            } else {
                if self.state == .interrupt {
                    // 打开输出
                    self.state = .recording
                    self.logger.warning(.init(stringLiteral: "\(self.streamName)恢复"))
                }
            }
            return self.shouldStopReadFrame ? 1 : 0
        }
        
        try inputFmtCtx.openInput(inputUrl)
        try inputFmtCtx.findStreamInfo()
    }
    
    private func createOutputFmtCtx() throws -> (AVFormatContext, [Int]) {
        let outputUrl = try createOutputUrl()
        let outputFmtCtx = try AVFormatContext(format: nil, filename: outputUrl)
        var outputStreamMapping = [Int](repeating: 0, count: inputFmtCtx.streamCount)
        
        var streamIndex = 0
        for i in 0..<inputFmtCtx.streamCount {
            let istream = inputFmtCtx.streams[i]
            let icodecpar = istream.codecParameters
    
            if icodecpar.mediaType != .audio &&
                icodecpar.mediaType != .video &&
                icodecpar.mediaType != .subtitle {
                outputStreamMapping[i] = -1
                continue
            }
    
            outputStreamMapping[i] = streamIndex
            streamIndex += 1
    
            guard let stream = outputFmtCtx.addStream() else {
                fatalError("Failed allocating output stream.")
            }
            stream.codecParameters.copy(from: icodecpar)
            stream.codecParameters.codecTag = 0
        }
            
        if !outputFmtCtx.outputFormat!.flags.contains(.noFile) {
            try outputFmtCtx.openOutput(url: outputUrl, flags: .write)
        }
        try outputFmtCtx.writeHeader()
        
        return (outputFmtCtx, outputStreamMapping)
    }
    
    private func startOutputFmtCtx() throws {
        do {
            let (fmtCtx, streamMapping) = try createOutputFmtCtx()
            outputFmtCtx = fmtCtx
            outputStreamMapping = streamMapping
        } catch {
            outputFmtCtx = nil
            outputStreamMapping = nil
            throw error
        }
    }
    
    private func closeOutputFmtCtx() throws {
        try outputFmtCtx?.writeTrailer()
        outputFmtCtx = nil
        outputStreamMapping = nil
    }
    
    private func createOutputUrl() throws -> String {
        let directory = outputDirectory.appendingPathComponent("\(Date().dayStr)").appendingPathComponent(streamName)
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: directory.path)
        if !exists {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        let outputUrl = directory.appendingPathComponent("\(Date().dayStr)_\(streamName)_\(Date().string(with: "HH-mm"))_\(UUID().uuidString)")
            .appendingPathExtension("ts")
            .path
        return outputUrl
    }
    
    private func openNewOutputFmtCtx() throws {
        let (fmtCtx, streamMapping) = try createOutputFmtCtx()
        newOutputFmtCtx = fmtCtx
        newOutputStreamMapping = streamMapping
    }
    
    private func writeToOutput(with pkt: AVPacket) throws {
        guard let ofmtCtx = outputFmtCtx, let streamMapping = outputStreamMapping else {
            try startOutputFmtCtx()
            return
        }
                
        let istream = inputFmtCtx.streams[pkt.streamIndex]
        let ostreamIndex = streamMapping[pkt.streamIndex]
        
        if ostreamIndex < 0 {
            return
        }
    
        pkt.streamIndex = ostreamIndex
        let ostream = ofmtCtx.streams[ostreamIndex]
    
        // copy packet
        pkt.pts = AVMath.rescale(pkt.pts, istream.timebase, ostream.timebase, rounding: AVRounding.nearInf, passMinMax: true)
        pkt.dts = AVMath.rescale(pkt.dts, istream.timebase, ostream.timebase, rounding: AVRounding.nearInf, passMinMax: true)
        pkt.duration = AVMath.rescale(pkt.duration, istream.timebase, ostream.timebase)
        pkt.position = -1
        
        do {
            try ofmtCtx.interleavedWriteFrame(pkt)
        } catch {
            self.logger.error(.init(stringLiteral: "\(streamName)文件写入错误: \(error)"))
            // 新开文件重新收录
            try closeOutputFmtCtx()
        }
    }
    
    private func noCatchError(_ tag: String, line: UInt = #line, file: String = #file, closure: () throws -> Void ) {
        do {
            try closure()
        } catch {
            logger.error(.init(stringLiteral: "\(tag) \(error)"), file: file, line: line)
        }
    }
    
    public func start(_ completeHandler: () -> Void) throws {
        guard state == .stop else { return }
        shouldStopReadFrame = false
        
        try startInputFmtCtx()
        try startOutputFmtCtx()
        
        state = .recording
        
        logger.notice(.init(stringLiteral: "\(streamName) Start Recording"))
        
        completeHandler()
        
        let pkt = AVPacket()
        while true {
            // 释放内存
            defer { pkt.unref() }
            do {
                lastReadFrameTime = .init()
                try inputFmtCtx.readFrame(into: pkt)
                // 判断是否开始新的切片
                if self.shouldOpenNewFile {
                    if let newFmtCtx = newOutputFmtCtx,
                       let newMapping = newOutputStreamMapping
                    {
                        noCatchError(self.streamName) {
                            try self.closeOutputFmtCtx()
                        }
                        
                        self.outputFmtCtx = newFmtCtx
                        self.outputStreamMapping = newMapping
                        
                        self.newOutputFmtCtx = nil
                        self.newOutputStreamMapping = nil
                        
                        self.onSliceCompleteHandler?()
                        self.onSliceCompleteHandler = nil
                        
                        self.shouldOpenNewFile = false
                    } else {
                        noCatchError(self.streamName) {
                            try self.openNewOutputFmtCtx()
                        }
                    }
                }
                
                // 写入数据包
                noCatchError(self.streamName) {
                    try self.writeToOutput(with: pkt)
                }
            } catch {
                logger.error(.init(stringLiteral: "\(streamName) exit: \(error)"))
                break
            }
        }
        
        // Clear input & output
        try closeOutputFmtCtx()
        inputFmtCtx = nil
        state = .stop
        
        onExitHandler?()

        logger.warning(.init(stringLiteral: "\(streamName) Stop Recording"))

        stopCompleteHandler?()
        stopCompleteHandler = nil
    }
    
    public func stop(_ completeHandler: @escaping () -> Void) {
        if state == .stop {
            completeHandler()
        } else {
            stopCompleteHandler = completeHandler
            shouldStopReadFrame = true
        }
    }
    
    public func slice(completeHandler: @escaping () -> Void) {
        onSliceCompleteHandler = completeHandler
        noCatchError(streamName) {
            try openNewOutputFmtCtx()
        }
        shouldOpenNewFile = true
    }
    
    public func onExit(_ closure: @escaping () -> Void) {
        onExitHandler = closure
    }
}

extension Date {
    func string(with format: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = format
        dateFormatter.timeZone = TimeZone.init(secondsFromGMT: +3600*8)
        return dateFormatter.string(from: self)
    }
    
    var dayStr: String {
        return string(with: "yyyy-MM-dd")
    }
}
