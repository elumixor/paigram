/** Devices from `xcrun devicectl list devices --json-output`, picked without touching the machine. */

export interface Device {
  readonly name: string;
  readonly udid: string;
  /** Connected to this Mac right now, by cable or on the network. A device paired here but next to another Mac is not. */
  readonly reachable: boolean;
}

/** Paired devices of a type (`iPhone`, `appleWatch`), the reachable ones first. */
export function pairedDevices(listing: any, type: string): Device[] {
  return listing.result.devices
    .filter((d: any) => d.hardwareProperties.deviceType === type && d.connectionProperties.pairingState === "paired")
    .map((d: any) => ({ name: d.deviceProperties.name, udid: d.hardwareProperties.udid, reachable: d.connectionProperties.transportType != null }))
    .sort((a: Device, b: Device) => Number(b.reachable) - Number(a.reachable));
}

export function matches(device: Device, wanted: string | undefined): boolean {
  return !wanted || device.name === wanted || device.udid === wanted;
}
