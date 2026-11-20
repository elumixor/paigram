import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import ConvertOpusToAAC
import LocalAudioTranscription

/// Transcribes a voice message on the device (no Premium) and stores the result as the message's
/// `AudioTranscriptionMessageAttribute`, so the bubble shows it and re-opening is instant.
/// Downloads the voice first if needed. `forcedLocale` skips language detection.
public func paiTranscribeVoiceMessage(context: AccountContext, message: EngineRawMessage, forcedLocale: String?) -> Signal<Never, NoError> {
    guard let file = message.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile else {
        return .complete()
    }
    let messageId = message.id
    var previousText = ""
    for attribute in message.attributes {
        if let attribute = attribute as? AudioTranscriptionMessageAttribute {
            previousText = attribute.text
        }
    }
    let appLanguageCode = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
    let preferredLocales = voiceTranscriptionLocaleOrder(appLanguageCode: appLanguageCode)

    let markPending = context.engine.messages.storeLocallyTranscribedAudio(messageId: messageId, text: previousText, isFinal: false, error: nil)

    let fetch = messageMediaFileInteractiveFetched(context: context, message: message, file: file, userInitiated: true)
    |> ignoreValues
    let completeData = context.engine.resources.data(id: EngineMediaResource.Id(file.resource.id))
    |> filter { $0.isComplete }
    |> take(1)

    let transcription: Signal<LocallyTranscribedAudio?, NoError> = Signal<EngineMediaResource.ResourceData, NoError> { subscriber in
        let fetchDisposable = fetch.startStrict()
        let dataDisposable = completeData.startStrict(next: { data in
            subscriber.putNext(data)
        }, completed: {
            subscriber.putCompletion()
        })
        return ActionDisposable {
            fetchDisposable.dispose()
            dataDisposable.dispose()
        }
    }
    |> mapToSignal { data -> Signal<String?, NoError> in
        return convertOpusToAAC(sourcePath: data.path, allocateTempFile: {
            return EngineTempBox.shared.tempFile(fileName: "audio.m4a").path
        })
    }
    |> mapToSignal { path -> Signal<LocallyTranscribedAudio?, NoError> in
        guard let path else {
            return .single(nil)
        }
        return transcribeVoiceAudio(path: path, preferredLocales: preferredLocales, forcedLocale: forcedLocale)
    }

    return markPending
    |> then(transcription
        |> mapToSignal { result -> Signal<Never, NoError> in
            if let result, !result.text.isEmpty {
                return context.engine.messages.storeLocallyTranscribedAudio(messageId: messageId, text: result.text, isFinal: true, error: nil)
            } else {
                return context.engine.messages.storeLocallyTranscribedAudio(messageId: messageId, text: previousText, isFinal: true, error: previousText.isEmpty ? .generic : nil)
            }
        }
    )
}
