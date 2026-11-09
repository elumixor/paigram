import Foundation
import Postbox

/// Paigram 0.3.x kept the box's messages in message namespace 8 and the email and WhatsApp states under preference
/// keys 51 and 52; upstream 13.2 took all three. Runs once, before anything reads the new keys (the email key stays
/// unset until then): each state moves to its key while the old one still decodes as it, its change log starting
/// over, and every box chat is emptied down to a hole in `Namespaces.Message.Box`, so it is fetched again as it is scrolled.
func migrateLegacyBoxStorage(transaction: Transaction) {
    if transaction.getPreferencesEntry(key: PreferencesKeys.emailState) != nil {
        return
    }
    let legacyEmailKey = PreferencesKeys.legacyBoxState(51)
    let legacyWhatsAppKey = PreferencesKeys.legacyBoxState(52)
    
    var emailState = EmailState.empty
    if var legacy = transaction.getPreferencesEntry(key: legacyEmailKey)?.get(EmailState.self) {
        legacy.seq = 0
        legacy.sending = []
        legacy.textVersion = EmailState.currentTextVersion
        emailState = legacy
        transaction.setPreferencesEntry(key: legacyEmailKey, value: nil)
    }
    if var legacy = transaction.getPreferencesEntry(key: legacyWhatsAppKey)?.get(WhatsAppState.self) {
        legacy.seq = 0
        legacy.sending = []
        transaction.setPreferencesEntry(key: PreferencesKeys.whatsAppState, value: PreferencesEntry(legacy))
        transaction.setPreferencesEntry(key: legacyWhatsAppKey, value: nil)
    }
    
    var peerIds = Set(transaction.chatListGetAllPeerIds().filter(\.isBridged))
    peerIds.formUnion(emailState.contacts.map { emailPeerId(contactId: $0.id) })
    for peerId in peerIds {
        transaction.clearHistory(peerId, threadId: nil, minTimestamp: nil, maxTimestamp: nil, namespaces: .just([Namespaces.Message.legacyBox]), forEachMedia: nil)
        refillBoxChat(transaction: transaction, peerId: peerId)
    }
    transaction.setPreferencesEntry(key: PreferencesKeys.emailState, value: PreferencesEntry(emailState))
}
