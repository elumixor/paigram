/**
 * Entitlement keys the main app's TelegramEntitlements (Telegram/BUILD) declares that need an App ID capability
 * in its profile. A profile lacking one fails the build, so `bun run device` reprovisions when any is missing.
 */
export const requiredAppEntitlements = ["com.apple.developer.associated-domains", "com.apple.developer.networking.wifi-info", "com.apple.developer.healthkit"] as const;

/** The required keys a profile's Entitlements lack. */
export function missingEntitlements(granted: Record<string, unknown> | undefined, required: readonly string[] = requiredAppEntitlements): string[] {
  return required.filter((key) => granted?.[key] === undefined);
}
