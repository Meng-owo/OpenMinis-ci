import Foundation
import AVFoundation

// MARK: - [T-kelivo-voice 09-10] Static waveform sampling for audio bubbles
//
// kelivo's voice bubbles show a real waveform of the audio file even before
// playback starts (the idle state reads as "this is a voice message", not
// "this is a broken slider"). This sampler extracts a fixed number of RMS
// amplitude buckets from an audio file on a background queue, once per file,
// and hands the result back to the caller. Cheap by design: a 30s clip at
// ~40 buckets is one linear decode pass.

enum AudioWaveformSampler {
    /// Number of amplitude buckets in the sampled waveform.
    static let bucketCount = 40

    /// Extract `bucketCount` normalized (0...1) RMS amplitude buckets.
    /// Returns nil when the file can't be decoded (unsupported/missing).
    nonisolated static func sampleLevels(from url: URL) async -> [Float]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: sampleLevelsSync(from: url))
            }
        }
    }

    nonisolated private static func sampleLevelsSync(from url: URL) -> [Float]? {
        let asset = AVURLAsset(url: url)
        // Synchronous track access is fine here: background queue + local file.
        guard let track = asset.tracks(withMediaType: .audio).first else { return nil }
        let durationSeconds = CMTimeGetSeconds(track.timeRange.duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch { return nil }

        // Decode as interleaved signed Int16 PCM — we only need amplitude.
        // [CI 34468139786] `AVAssetReaderTrackOutput` is non-Optional in this
        // SDK (initialiser is not failable), so a `guard let` binding is a
        // compile error; construct directly and let startReading() catch a bad
        // track instead.
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        reader.add(output)
        guard reader.startReading() else { return nil }

        var buckets = [Float](repeating: 0, count: bucketCount)
        var counts = [Int](repeating: 0, count: bucketCount)

        // Estimate total samples from duration × decoded sample rate. The
        // AVAssetReaderTrackOutput doesn't resample unless asked; we asked for
        // the source format's channel layout, so nominalFrameRate isn't a
        // sample rate. Use the track's estimated rate, falling back to 16k.
        guard let formatDesc = track.formatDescriptions.first,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc as! CMAudioFormatDescription)
        else {
            return sampleLevelsFallback(reader: reader, output: output,
                                        durationSeconds: durationSeconds,
                                        buckets: &buckets, counts: &counts)
        }
        let asbd = asbdPtr.pointee
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 16000
        // totalSamples counts FRAMES, but the loop below walks interleaved
        // Int16 VALUES (channels per frame). Bucket math must use the value
        // count, or a stereo stream exhausts the frame budget at ~half its
        // duration and piles everything else into the last bucket.
        let totalSamples = Int(durationSeconds * sampleRate)
        guard totalSamples > 0 else { return nil }
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let totalValues = totalSamples * channels

        var sampleIndex = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else {
                CMSampleBufferInvalidate(buffer)
                continue
            }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { CMSampleBufferInvalidate(buffer); continue }
            var data = Data(count: length)
            let copied = data.withUnsafeMutableBytes { dst in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0,
                                            dataLength: length,
                                            destination: dst.baseAddress!)
            }
            if copied == noErr {
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let int16Ptr = raw.baseAddress!.assumingMemoryBound(to: Int16.self)
                    let n = raw.count / MemoryLayout<Int16>.size
                    for i in 0..<n {
                        let amp = abs(Float(int16Ptr[i]) / 32768.0)
                        let bucket = min(bucketCount - 1,
                                         sampleIndex * bucketCount / max(1, totalValues))
                        buckets[bucket] += amp
                        counts[bucket] += 1
                        sampleIndex += 1
                    }
                }
            }
            CMSampleBufferInvalidate(buffer)
        }

        return normalize(buckets: buckets, counts: counts)
    }

    /// Path when we couldn't read the ASBD — bucket by chunk position instead
    /// of sample math (divide the decoded stream evenly).
    nonisolated private static func sampleLevelsFallback(
        reader: AVAssetReader, output: AVAssetReaderTrackOutput,
        durationSeconds: Double,
        buckets: inout [Float], counts: inout [Int]
    ) -> [Float]? {
        var chunks: [Data] = []
        while let buffer = output.copyNextSampleBuffer() {
            if let blockBuffer = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(blockBuffer)
                if length > 0 {
                    var data = Data(count: length)
                    let ok = data.withUnsafeMutableBytes { dst in
                        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0,
                                                    dataLength: length,
                                                    destination: dst.baseAddress!)
                    }
                    if ok == noErr { chunks.append(data) }
                }
            }
            CMSampleBufferInvalidate(buffer)
        }
        guard !chunks.isEmpty else { return nil }
        let totalBytes = chunks.reduce(0) { $0 + $1.count }
        // The cursor below counts Int16 VALUES, so the bucket width must be
        // in values too — totalBytes/bucketCount is a BYTE width, twice the
        // value width, which filled only the first ~20 buckets.
        let valuesPerBucket = max(1, totalBytes / MemoryLayout<Int16>.size / bucketCount)
        var cursor = 0
        for chunk in chunks {
            chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let int16Ptr = raw.baseAddress!.assumingMemoryBound(to: Int16.self)
                let n = raw.count / MemoryLayout<Int16>.size
                for i in 0..<n {
                    let bucket = min(bucketCount - 1, cursor / valuesPerBucket)
                    buckets[bucket] += abs(Float(int16Ptr[i]) / 32768.0)
                    counts[bucket] += 1
                    cursor += 1
                }
            }
        }
        return normalize(buckets: buckets, counts: counts)
    }

    nonisolated private static func normalize(buckets: [Float], counts: [Int]) -> [Float] {
        var levels: [Float] = []
        var maxLevel: Float = 0.0001
        for i in 0..<bucketCount {
            let avg = counts[i] > 0 ? buckets[i] / Float(counts[i]) : 0
            levels.append(avg)
            maxLevel = max(maxLevel, avg)
        }
        return levels.map { min(1, $0 / maxLevel) }
    }
}
