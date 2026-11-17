import Foundation
import TDShim

/// Per-voice-note data the bubble + playback controller consume. Built from
/// a `MessageVoiceNote` plus the latest `files[fileId]` snapshot for the voice
/// file. Identifiable by `voiceFileId`.
struct VoiceNoteVisual: Identifiable, Equatable, Hashable {
    var id: Int { voiceFileId }
    let voiceFileId: Int
    /// Seconds, from `VoiceNote.duration` (sender-defined; may be approximate).
    let duration: Int
    /// `VoiceNote.mimeType`; typically `audio/ogg`.
    let mimeType: String
    /// Telegram's 5-bit packed waveform; may be empty.
    let waveform: Data
    /// Caption text (formatting ignored, matching photo/video bubbles).
    let caption: String
    /// Filesystem path of the voice file once downloaded; nil otherwise.
    let localPath: String?
    /// TDLib's `VoiceNote.speechRecognitionResult`; nil until someone asked
    /// for (or the server produced) a transcription.
    var transcription: VoiceTranscription? = nil
}

/// Projection of TDLib's `SpeechRecognitionResult` for the bubble.
enum VoiceTranscription: Equatable, Hashable {
    /// Recognition in progress; `partialText` may be empty.
    case pending(partialText: String)
    case text(String)
    case failed(String)

    init(_ result: SpeechRecognitionResult) {
        switch result {
        case .speechRecognitionResultPending(let r): self = .pending(partialText: r.partialText)
        case .speechRecognitionResultText(let r):    self = .text(r.text)
        case .speechRecognitionResultError(let r):   self = .failed(transcriptionErrorText(r.error.message))
        }
    }
}

/// User-facing text for a speech-recognition error message from TDLib.
func transcriptionErrorText(_ message: String) -> String {
    switch message {
    case "MSG_VOICE_TOO_LONG": return "Too long to transcribe"
    case "PREMIUM_ACCOUNT_REQUIRED": return "Transcription needs Premium"
    default: return "Couldn't transcribe"
    }
}

extension VoiceNoteVisual {
    /// Builds a visual for a locally-recorded draft (already on disk) for the
    /// record-sheet review screen. `voiceFileId` is a negative sentinel so it
    /// never collides with a real TDLib file id, and `localPath` points straight
    /// at the temp file so playback skips any download path.
    static func draft(fileURL: URL, duration: Int, waveform: Data) -> VoiceNoteVisual {
        VoiceNoteVisual(
            voiceFileId: -1,
            duration: duration,
            mimeType: "audio/ogg",
            waveform: waveform,
            caption: "",
            localPath: fileURL.path
        )
    }
}
