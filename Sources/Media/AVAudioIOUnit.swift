import AVFoundation

#if canImport(SwiftPMSupport)
import SwiftPMSupport
#endif

final class AVAudioIOUnit: NSObject, AVIOUnit {
    lazy var codec: AudioCodec = {
        var codec = AudioCodec()
        codec.lockQueue = lockQueue
        return codec
    }()
    let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.AudioIOComponent.lock")
    var isPaused: Bool = false

    var audioEngine: AVAudioEngine?
    var soundTransform: SoundTransform = .init() {
        didSet {
            soundTransform.apply(mixer?.mediaLink.playerNode)
        }
    }
    weak var mixer: AVMixer?

#if os(iOS) || os(macOS)
    var input: AVCaptureDeviceInput? {
        didSet {
            guard let mixer: AVMixer = mixer, oldValue != input else {
                return
            }
            if let oldValue: AVCaptureDeviceInput = oldValue {
                mixer.session.removeInput(oldValue)
            }
            if let input: AVCaptureDeviceInput = input, mixer.session.canAddInput(input) {
                mixer.session.addInput(input)
            }
        }
    }

    private var _output: AVCaptureAudioDataOutput?
    var output: AVCaptureAudioDataOutput! {
        get {
            if _output == nil {
                _output = AVCaptureAudioDataOutput()
            }
            return _output
        }
        set {
            if _output == newValue {
                return
            }
            if let output: AVCaptureAudioDataOutput = _output {
                output.setSampleBufferDelegate(nil, queue: nil)
                mixer?.session.removeOutput(output)
            }
            _output = newValue
        }
    }
#endif

    private var audioFormat: AVAudioFormat?

#if os(iOS) || os(macOS)
    deinit {
        input = nil
        output = nil
    }
#endif

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        mixer?.recorder.appendSampleBuffer(sampleBuffer, mediaType: .audio)
        codec.encodeSampleBuffer(sampleBuffer)
    }

#if os(iOS) || os(macOS)
    func attachAudio(_ audio: AVCaptureDevice?, automaticallyConfiguresApplicationAudioSession: Bool) throws {
        guard let mixer: AVMixer = mixer else {
            return
        }

        mixer.session.beginConfiguration()
        defer {
            mixer.session.commitConfiguration()
        }

        output = nil
        codec.invalidate()

        guard let audio: AVCaptureDevice = audio else {
            input = nil
            return
        }

        input = try AVCaptureDeviceInput(device: audio)
        #if os(iOS)
        mixer.session.automaticallyConfiguresApplicationAudioSession = automaticallyConfiguresApplicationAudioSession
        #endif
        mixer.session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: lockQueue)
    }
#endif

    func registerEffect(_ effect: AudioEffect) -> Bool {
        codec.effects.insert(effect).inserted
    }

    func unregisterEffect(_ effect: AudioEffect) -> Bool {
        codec.effects.remove(effect) != nil
    }

    func startDecoding(_ audioEngine: AVAudioEngine?) {
        self.audioEngine = audioEngine
        if let playerNode = mixer?.mediaLink.playerNode {
            audioEngine?.attach(playerNode)
        }
        codec.delegate = self
        codec.startRunning()
    }

    func stopDecoding() {
        if let playerNode = mixer?.mediaLink.playerNode {
            audioEngine?.detach(playerNode)
        }
        audioEngine = nil
        codec.delegate = nil
        codec.stopRunning()
    }
}

extension AVAudioIOUnit: AVCaptureAudioDataOutputSampleBufferDelegate {
    // MARK: AVCaptureAudioDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !self.isPaused else {
            return
        }
        if discont {
            discont = false
            var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let last = lastAudio
            if last.flags.contains(CMTimeFlags.valid) {
                if timeOffset.flags.contains(CMTimeFlags.valid) {
                    pts = CMTimeSubtract(pts, timeOffset)
                }
                let off = CMTimeSubtract(pts, last)
                if timeOffset.value == 0 {
                    timeOffset = off
                }
                else {
                    timeOffset = CMTimeAdd(timeOffset, off)
                }
            }
            lastVideo.flags = []
            lastAudio.flags = []
        }
        var out:CMSampleBuffer?
        if timeOffset.value > 0 {
            out = adjustTime(sample: sampleBuffer, by: timeOffset)
        }
        else {
            out = sampleBuffer
        }
        var pts = CMSampleBufferGetPresentationTimeStamp(out!)
        let dur = CMSampleBufferGetDuration(out!)
        if (dur.value > 0)
        {
            pts = CMTimeAdd(pts, dur);
        }
        
            lastAudio = pts;
//        print("--->>>> lastAudio\(CMTimeGetSeconds(lastAudio))")
        
        appendSampleBuffer(out!)
    }
}

extension AVAudioIOUnit: AudioCodecDelegate {
    // MARK: AudioConverterDelegate
    func audioCodec(_ codec: AudioCodec, didSet formatDescription: CMFormatDescription?) {
        guard let formatDescription = formatDescription, let audioEngine = audioEngine else {
            return
        }
        #if os(iOS)
        if #available(iOS 9.0, *) {
            audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        } else {
            guard let asbd = formatDescription.streamBasicDescription?.pointee else {
                return
            }
            audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame, interleaved: false)
        }
        #else
            audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        #endif
        nstry({
            if let plyerNode = self.mixer?.mediaLink.playerNode, let audioFormat = self.audioFormat {
                audioEngine.connect(plyerNode, to: audioEngine.mainMixerNode, format: audioFormat)
            }
        }, { exeption in
            logger.warn(exeption)
        })
        do {
            try audioEngine.start()
        } catch {
            logger.warn(error)
        }
    }

    func audioCodec(_ codec: AudioCodec, didOutput sample: UnsafeMutableAudioBufferListPointer, presentationTimeStamp: CMTime) {
        guard !sample.isEmpty, sample[0].mDataByteSize != 0 else {
            return
        }
        guard
            let audioFormat = audioFormat,
            let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: sample[0].mDataByteSize / 4) else {
            return
        }
        buffer.frameLength = buffer.frameCapacity
        let bufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for i in 0..<bufferList.count {
            guard let mData = sample[i].mData else { continue }
            memcpy(bufferList[i].mData, mData, Int(sample[i].mDataByteSize))
            bufferList[i].mDataByteSize = sample[i].mDataByteSize
            bufferList[i].mNumberChannels = 1
        }
        if let mixer = mixer {
            mixer.delegate?.mixer(mixer, didOutput: buffer, presentationTimeStamp: presentationTimeStamp)
        }
        mixer?.mediaLink.enqueueAudio(buffer)
    }
}
