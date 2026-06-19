# CarPlay Live Activity Setup

## Overview

Speedy surfaces live speed information in CarPlay using a **Live Activity** (ActivityKit),
not a dedicated CarPlay app. As of **iOS 18.4 / iOS 26**, the system automatically forwards an
app's running Live Activity to the **CarPlay dashboard / home screen** — no special CarPlay
entitlement and no per-car setup is required. The Live Activity also appears on the iPhone
lock screen and in the Dynamic Island.

The Live Activity shows current speed, the (posted or estimated) speed limit, road name, and
status indicators (signal type, battery level, altitude, speeding/online state), updating about
once per second while driving.

## How it works

- A single `ActivityConfiguration` is registered for `SpeedyWidgetAttributes`
  (see `SpeedyWidget/SpeedyWidgetLiveActivity.swift`). Registering a second configuration for the
  same attributes type is what caused earlier rendering issues — the duplicate was removed.
- On **iOS 18.4+**, the system automatically forwards this single Live Activity to the CarPlay
  dashboard using its standard layout (`StandardLockScreenView`). No extra setup or entitlement
  is required.
- Updates are pushed via `Activity.update()` from `LocationManager` (1-second foreground timer,
  plus updates driven by location callbacks so it keeps updating while driving in the
  background). `WidgetCenter` timeline reloads do **not** drive the Live Activity.

### Future enhancement: CarPlay-tuned `.small` layout
iOS 18.0 adds `.supplementalActivityFamilies([.small])` plus the `\.activityFamily` environment
value, which would let the Live Activity render a layout specifically sized for the small CarPlay
slot. It is intentionally **not** wired up yet: applying it changes the configuration's opaque
type, and `WidgetBundleBuilder` lacks `buildEither`/`#unavailable`, so it can't be version-gated
without either a duplicate configuration or dropping the Live Activity on iOS 17.x (the app's
current deployment floor). Once the deployment target moves to iOS 18.0, add the modifier to the
single configuration and branch the content view on `activityFamily == .small`.

## Enabling it

### In the app
1. Open Speedy → Settings.
2. Enable Live Activities.
3. Start driving (or use a simulated route). The Live Activity starts automatically when the
   app is in the foreground and live activities are enabled.

### In CarPlay (iOS 18.4+ / iOS 26)
- No setup is required — a running Live Activity appears on the CarPlay dashboard automatically.
- Live Activities in CarPlay can be turned off system-wide in the car's CarPlay settings if the
  driver prefers a simpler interface.

## Requirements

- iOS 16.1+ for the Live Activity (lock screen + Dynamic Island).
- iOS 18.4+ for automatic display on the CarPlay dashboard.
- Location permissions enabled; network connectivity for posted speed-limit data.

## Display details

- **Main display**: current speed and speed limit in large, easy-to-read numbers. An estimated
  (statutory-default) limit is shown with a `~` prefix and an "EST. LIMIT" label.
- **Status**: signal type (2G/3G/4G/5G/GPS), battery level (color-coded), altitude, and a
  speeding/safe indicator.
- **Background**: dynamic color — red/orange when speeding, blue/cyan when within the limit.
- **Units**: respects the Imperial (mph) / Metric (kph) setting; altitude switches between feet
  and meters accordingly.

## Troubleshooting

### Live Activity not showing
1. Confirm Live Activities are enabled in the app's Settings.
2. Confirm Live Activities are allowed for Speedy in iOS Settings → Speedy.
3. Ensure location permission is granted and the app has been foregrounded at least once
   (Live Activities can only be *started* from the foreground).

### Not appearing on CarPlay
1. Requires iOS 18.4 or later.
2. Confirm the Live Activity is visible on the iPhone first (lock screen / Dynamic Island).
3. Check that Live Activities are not disabled in the car's CarPlay settings.

### Missing or stale data
- **Speed limit**: needs network connectivity and accurate location; otherwise an estimated
  limit may be shown.
- **Battery**: ensure battery monitoring is available (not reported in some simulators).
- **Signal**: simulators may not report a real cellular type.

## Privacy

The Live Activity only displays data already collected by the app, stores no additional personal
information, respects iOS privacy settings, and can be disabled at any time.
