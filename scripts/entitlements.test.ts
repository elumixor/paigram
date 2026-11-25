import { expect, test } from "bun:test";
import { missingEntitlements } from "./entitlements.ts";

test("a profile without associated domains needs reprovisioning", () => {
  expect(missingEntitlements({ "com.apple.developer.networking.wifi-info": true, "com.apple.developer.healthkit": true })).toEqual(["com.apple.developer.associated-domains"]);
});

test("a profile with every required entitlement is current", () => {
  expect(missingEntitlements({ "com.apple.developer.networking.wifi-info": true, "com.apple.developer.associated-domains": "*", "com.apple.developer.healthkit": true })).toEqual([]);
});

test("a missing profile lacks everything", () => {
  expect(missingEntitlements(undefined).length).toBe(3);
});

test("a profile from before HealthKit needs reprovisioning", () => {
  expect(missingEntitlements({ "com.apple.developer.networking.wifi-info": true, "com.apple.developer.associated-domains": "*" })).toEqual(["com.apple.developer.healthkit"]);
});
