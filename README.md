# Edge WebRTC iOS Demo (Decentralized IAM)

SwiftUI demo app showing how to stream WebRTC video from a Nabto Edge device using
decentralized IAM (pairing-string based, no central auth).

This is the SwiftUI / decentral counterpart to the older
[`edge-ios-webrtc`](https://github.com/nabto/edge-ios-webrtc) demo (UIKit, AWS Cognito).

## Features

- Add a device by pasting a **pairing string** (`p=...,d=...,pwd=...,sct=...`) or filling
  individual fields.
- Discover devices on the local network via **mDNS**.
- IAM pairing modes: `LocalInitial`, `LocalOpen`, `PasswordOpen`, `PasswordInvite`
  (auto-selected from what the device advertises).
- Persists bookmarks across launches; private key stored in Keychain.
- WebRTC video playback (and remote audio) using `NabtoEdgeClientWebRTC`.
- Editable list of tracks to request from the device (default `frontdoor-video`,
  `frontdoor-audio`).

## Requirements

- Xcode 26.x, iOS 17 deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to (re)generate the `.xcodeproj`

## Build

```sh
brew install xcodegen        # one-time
xcodegen                     # regenerates EdgeWebRTCDemo.xcodeproj
open EdgeWebRTCDemo.xcodeproj
```

Then build & run for an iPhone simulator or physical device.

## SDK dependencies

Resolved via Swift Package Manager (see `project.yml`):

| Package | Version |
|---------|---------|
| `nabto/edge-client-swift` (`NabtoEdgeClient`) | `>=4.0.2` |
| `nabto/edge-iamutil-swift` (`NabtoEdgeIamUtil`) | `>=2.0.1` |
| `nabto/edge-client-swift-webrtc` (`NabtoEdgeClientWebRTC`) | `update_edge_client_swift_4` branch |


