`edge_device_webrtc` fails to forward RTSP media from an HEVC IPC camera (`dolphin-rtsp-server`) in both transport modes:

- TCP interleaved (default): `nabto::TcpRtpClient::run` errors at `tcp_rtp_client.cpp:86` with `CURLE_RECV_ERROR` ("Failure when receiving data from the peer") after PLAY has succeeded.
- UDP (`--rtsp-use-udp`): `RtpClient` starts listening on `42222/udp` but no RTP packet ever arrives. The WebRTC peer connection on both sides goes to `connected`, ICE/DTLS/SRTP come up, and the iOS client (post H.265 enablement) waits indefinitely.

The same camera at the same URL streams fine in three independent clients:

- VLC (remote, over the public IP + NAT-forwarded port 60554) — full live view, 1920x1080 H.265 @ 15 fps.
- `ffprobe -rtsp_transport tcp` (remote) — pulls VPS+SPS+PPS+IDR_W_RADL+19 TRAIL_R frames in the first second, identifies the stream as `hevc (Main), 1920x1080, 15 fps`.
- iOS client over a working WebRTC device (different unit) — fine.

So this is not a camera problem and not a network problem. It's specifically `edge_device_webrtc`'s libcurl-based RTSP path. Sources audited:

- `src/modules/rtsp-client/tcp_rtp_client.cpp`
- `src/modules/rtsp-client/rtsp_client.cpp`
- `src/modules/rtp-client/rtp_client.cpp`
- `src/modules/util/util.cpp` (CurlAsync)

Three real bugs found, plus a couple of diagnostic gaps.

## `rtp_write()` violates libcurl's `CURLOPT_INTERLEAVEFUNCTION` contract (most likely root cause of the TCP-interleaved failure)

`tcp_rtp_client.cpp:115-173` assumes each callback invocation delivers exactly one complete `$<ch><len_be16><payload>` frame:

```cpp
if (((char*)ptr)[0] != '$') {
    NPLOGE << "Received data did not start with $!";
    return len;                                   // silently swallows
}
uint16_t dataLen = ((uint8_t*)ptr)[3] + (((uint8_t*)ptr)[2] << 8);
...
auto packets = self->videoRepacketizer_->handlePacket(
    std::vector<uint8_t>(buf, buf + dataLen));     // walks past the chunk
```

libcurl's contract is "bytes since the last call", not "one frame per call". A single TCP `read()` can give you:

- A partial frame (header without payload, or split mid-payload).
- Multiple frames concatenated.
- A leftover RTSP response chunk followed by an interleaved frame.

When the chunk doesn't start with `$`, the code logs and `return len` — telling libcurl "I consumed all of it" — which permanently desyncs libcurl's RTSP state. The next `curl_easy_perform()` then errors with `CURLE_RECV_ERROR`. That is exactly the failure mode in the device logs.

VLC and ffmpeg are immune because they bring their own RTSP/RTP demuxers and do not use libcurl's interleave callback at all.

Fix outline: keep a `std::vector<uint8_t> recvBuf_` member in `TcpRtpClient`. In `rtp_write()`, append the incoming chunk to `recvBuf_`, then loop: while `recvBuf_.size() >= 4 && recvBuf_[0] == '$'` and the buffer holds `4 + be16(recvBuf_[2..3])` bytes, peel off that frame and erase it from the buffer. Bytes that aren't a frame header should be dropped only via an explicit resync path with a logged warning, never silently. Always return `size*nmemb`.

## PLAY → RECEIVE race window in `RtspClient::performStart`

`rtsp_client.cpp:301-333`:

```cpp
curl_->reinvokeStatus(&res, &status);     // PLAY perform runs here
// ... reset RANGE, resolveStart() ...
if (tcpClient_ != nullptr) {
    tcpClient_->run();                    // RECEIVE loop starts only here
}
```

`dolphin-rtsp-server` (and most embedded RTSP servers) starts pushing interleaved frames immediately after writing the PLAY response — often in the same `send()`. Those bytes land in libcurl's connection buffer during `reinvokeStatus()`. With no `CURLOPT_INTERLEAVEFUNCTION` installed yet, libcurl either drops them or stuffs them into the body buffer. PLAY appears to complete normally, but by the time `TcpRtpClient::run()` issues the first RECEIVE, libcurl's internal state already disagrees with the camera about where the byte stream is.

This bug compounds Bug 1: even with a correctly-buffered `rtp_write`, the first one-to-three frames are still missed because the callback isn't installed when they arrive.

Fix outline: install `CURLOPT_INTERLEAVEFUNCTION` and `CURLOPT_INTERLEAVEDATA` before the PLAY `curl_easy_perform`, not after. `TcpRtpClient::run()` should then only issue subsequent `CURL_RTSPREQ_RECEIVE` performs.

## RTCP RR write uses host-byte-order length and bypasses libcurl

`tcp_rtp_client.cpp:90-108` + line 167:

```cpp
uint16_t* p = (uint16_t*)&self->rtcpWriteBuf_[2];
*p = rr->header.lengthInBytes();                  // host order written to wire
self->sendRtcp_ = true;
...
uint16_t len = *(uint16_t*)(rtcpWriteBuf_+2)+4;   // also host order
auto ret = write(sockfd, rtcpWriteBuf_, len);     // bypasses libcurl
```

Two stacked problems:

- The interleaved-frame length at `rtcpWriteBuf_[2..3]` is the network-byte-order length per RFC 2326 §10.12. `rr->header.lengthInBytes()` returns host order on little-endian ARM, so the on-wire length is byte-swapped. Receiving servers see a corrupted frame and may drop the connection.
- `write(sockfd, ...)` directly on the libcurl-owned socket between `curl_easy_perform()` calls bypasses libcurl's connection state machine and its output buffer. On TLS connections this is undefined behaviour; on plain TCP it's still racy with whatever libcurl's about to send.

Fix outline: `htons()` (or equivalent) on the length before writing into `rtcpWriteBuf_[2..3]` and before computing `len`. Replace `write()` with `curl_easy_send()`, or queue the RTCP into a state that the next `CURL_RTSPREQ_RECEIVE` cycle naturally drains. Confirm `rr->header.lengthInBytes()` byte order in libdatachannel.

## No RTSP session keepalive after PLAY (long-tail, not the immediate symptom)

`Session: 0x1911d38;timeout=65` in the SETUP response means the server kills the session after 65 s of silence. The codebase doesn't appear to schedule periodic `OPTIONS` or `GET_PARAMETER` keepalives. Not the cause of the immediate failure (which fires within seconds), but it will silently kill long-running streams.

Fix outline: schedule a `CURL_RTSPREQ_OPTIONS` (or `GET_PARAMETER`) keepalive at `timeout/2` parsed from the SETUP response's `Session:` header.

## Missing diagnostic logging in the UDP path

`rtp_client.cpp:141-202` is correct in shape — binds `0.0.0.0:42222`, `recvfrom` in a loop. But there's no log line on first packet received, no log of the `Transport:` header echoed back by the camera in SETUP, and no `getsockname()` confirmation. That's why the UDP failure is silent.

Suggested additions:

- In `RtspClient::performSetupReq`, log the full `Transport:` response header, including any `source=…` / `destination=…` fields the camera may inject.
- In `RtpClient::rtpVideoRunner`, log the source address+port of the first received packet, then every Nth thereafter. If zero packets ever arrive, that confirms the camera isn't sending (vs. our parser dropping them).

## Reproduction

- Device: HEVC IPC camera at `114.34.238.86` (NATed), camera firmware runs `dolphin-rtsp-server`, RTSP at port forwarded to `60554`.
- `edge_device_webrtc` invocation (TCP interleaved, default): fails at PLAY+RECEIVE within ~30 s with `Failed to perform RTSP RECEIVE request with: Failure when receiving data from the peer` at `tcp_rtp_client.cpp:86`.
- Same invocation with `--rtsp-use-udp`: SETUP/PLAY succeed, `RtpClient::start` listens on `42222/udp`, zero RTP packets ever arrive at the device.
- Same RTSP URL via `ffprobe -hide_banner -loglevel debug -rtsp_transport tcp 'rtsp://admin:123456@114.34.238.86:60554/live/main'` succeeds, decoding VPS+SPS+PPS+IDR_W_RADL+TRAIL_R within the first second.
- VLC, same URL, also fine.

Logs from both `edge_device_webrtc` runs (TCP-interleaved and UDP) and from the ffprobe run are available; attach to the ticket.

## Suggested order of work

1. Fix Bug 1 (`rtp_write` buffering). Highest-impact, smallest diff.
2. Fix Bug 2 (install INTERLEAVEFUNCTION before PLAY). Required for Bug 1's fix to actually catch the first frames.
3. Fix Bug 3 (RTCP byte order + path). Once Bug 1/2 are correct, Bug 3 becomes user-visible if RTCP-aware servers exist in the customer base.
4. Add the UDP-side diagnostic logs. Cheap, helps the next case.
5. Add the RTSP keepalive scheduler. Easy, prevents the next long-tail report.
