import { expect, test } from "bun:test";
import { pairedDevices } from "./devices.ts";

const listing = (transportType?: string) => ({
  result: {
    devices: [
      {
        hardwareProperties: { deviceType: "iPhone", udid: "u1" },
        connectionProperties: { pairingState: "paired", ...(transportType ? { transportType } : {}) },
        deviceProperties: { name: "Phone" },
      },
    ],
  },
});

test("an iPhone paired here but connected to another Mac is not reachable", () => {
  expect(pairedDevices(listing(), "iPhone")[0]!.reachable).toBe(false);
});

test("an iPhone on this Mac's Wi-Fi is reachable", () => {
  expect(pairedDevices(listing("localNetwork"), "iPhone")[0]!.reachable).toBe(true);
});
