import Foundation

/// Debug-only logging for the voice capture → transcription pipeline.
/// All messages share the `[Voice]` prefix for easy grep. Routed through
/// AppLogger (NSLog-backed, captured by LoggingManager) per project convention;
/// compiled out of release builds.
enum VoiceLog {
    #if DEBUG
    private static let logger = AppLogger(category: "Voice")
    #endif

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        logger.info("[Voice] \(message())")
        #endif
    }

    /// [B09-S06 2026-10-22] The three "why did nothing play" events, kept in
    /// Release too. Every TTS support case was "no sound, nothing in the log":
    /// VoiceLog is compiled out of release, and only the final failure used
    /// logger.error. These are the ones worth a permanent record.
    private static let releaseLogger = AppLogger(category: "Voice")

    static func problem(_ message: @autoclosure () -> String) {
        releaseLogger.error("[Voice] \(message())")
    }
}
