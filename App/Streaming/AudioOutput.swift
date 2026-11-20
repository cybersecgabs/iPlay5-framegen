import AVFoundation
import ChiakiKit

/// Plays chiaki's decoded 48 kHz stereo audio with a short output buffer.
///
/// The source node pulls straight from the C ring buffer in ck_bridge.c, which
/// trims itself back to ~100 ms if playback ever falls behind.
final class AudioOutput {
	private let engine = AVAudioEngine()
	private var source: AVAudioSourceNode?
	private let scratchFrames = 4096
	private let scratch: UnsafeMutablePointer<Int16>

	/// Read from the render thread. Set before start(), cleared after stop().
	private var session: OpaquePointer?
	private var primed = false
	/// ~20 ms of audio before playback starts or resumes after an underrun
	private let primeFrames = 960

	init() {
		scratch = .allocate(capacity: scratchFrames * 2)
	}

	deinit {
		stop()
		scratch.deallocate()
	}

	func start(session: OpaquePointer) {
		self.session = session
		let audioSession = AVAudioSession.sharedInstance()
		do {
			try audioSession.setCategory(.playback, mode: .default, options: [])
			try audioSession.setPreferredSampleRate(48_000)
			try audioSession.setPreferredIOBufferDuration(0.005)
			try audioSession.setActive(true)
		} catch {
			log.error("Audio session: \(error.localizedDescription)")
		}

		guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else { return }
		let node = AVAudioSourceNode(format: format) { [unowned self] isSilence, _, frameCount, bufferList -> OSStatus in
			let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
			guard buffers.count >= 2,
				let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
				let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
			else { return noErr }

			let total = Int(frameCount)
			guard let session = self.session else {
				memset(left, 0, total * 4)
				memset(right, 0, total * 4)
				isSilence.pointee = true
				return noErr
			}
			if !self.primed {
				if ck_session_audio_buffered(session) < self.primeFrames {
					memset(left, 0, total * 4)
					memset(right, 0, total * 4)
					isSilence.pointee = true
					return noErr
				}
				self.primed = true
			}

			var done = 0
			while done < total {
				let chunk = min(total - done, self.scratchFrames)
				let got = ck_session_audio_read(session, self.scratch, chunk)
				for i in 0..<chunk {
					left[done + i] = Float(self.scratch[i * 2]) / 32768
					right[done + i] = Float(self.scratch[i * 2 + 1]) / 32768
				}
				if got < chunk { self.primed = false }
				done += chunk
			}
			return noErr
		}
		source = node
		engine.attach(node)
		engine.connect(node, to: engine.mainMixerNode, format: format)
		do {
			try engine.start()
		} catch {
			log.error("Audio engine: \(error.localizedDescription)")
		}
	}

	func stop() {
		engine.stop()
		if let source {
			engine.detach(source)
		}
		source = nil
		session = nil
		primed = false
	}

	var muted: Bool {
		get { engine.mainMixerNode.outputVolume == 0 }
		set { engine.mainMixerNode.outputVolume = newValue ? 0 : 1 }
	}
}
