# Camera Stream Emulator for Raspberry Pi 5

This deployment presents **50 camera endpoints**, `cam_01` through `cam_50`, from a single Raspberry Pi 5. It is optimized for the media already in `assets/`: both files are H.264 at 640x480 and 15 fps, so the runtime copies their compressed video and audio packets instead of decoding and re-encoding them.

The design uses only three containers:

- `publisher-rpm-1` continuously loops `assets/RPM_1.mp4` into the internal MediaMTX path `source_01`.
- `publisher-rpm-2` continuously loops `assets/RPM_2.mp4` into the internal MediaMTX path `source_02`.
- `mediamtx` exposes `cam_01` through `cam_50`. Odd-numbered cameras proxy `source_01`; even-numbered cameras proxy `source_02`.

The two FFmpeg publishers use stream copy (`-c copy`). MediaMTX creates the 50 public proxies on demand and remuxes the same compressed streams for its output protocols. There are no per-camera FFmpeg containers, H.264 encoders, scaling or frame-rate filters. The old generated timestamp overlay is intentionally absent because adding it would require video transcoding.

## Requirements

- Raspberry Pi 5 running a 64-bit OS
- Docker Engine with the Docker Compose v2 plugin (`docker compose`)
- A stable LAN address; this deployment uses `192.168.0.55`
- Wired Gigabit Ethernet is recommended for 50 simultaneous viewers
- `ffprobe` for the smoke test and `ffmpeg` for the load test

On Raspberry Pi OS, the test tools are available from the `ffmpeg` package:

```sh
sudo apt-get update
sudo apt-get install -y ffmpeg
```

## Deploy

Connect to the Pi and clone the project if it is not already present:

```sh
ssh tyrone@192.168.0.55
git clone https://github.com/tyronechrisharris/Camera-emulator.git
cd Camera-emulator
```

Copy the target-Pi settings to `.env` to control host binding and WebRTC address advertisement:

```sh
cp .env.example .env
```

For this deployment, `.env` contains:

```dotenv
CAMERA_BIND_IP=192.168.0.55
CAMERA_ADVERTISE_IP=192.168.0.55
```

`CAMERA_BIND_IP` defaults to `0.0.0.0` when it is omitted, which listens on every Pi interface. The supplied `.env.example` instead restricts the published ports to the Pi's `192.168.0.55` LAN interface. With that stricter binding, pass `RTSP_HOST=192.168.0.55` to the test scripts because the ports are not bound to `127.0.0.1`.

`CAMERA_ADVERTISE_IP` defaults to `192.168.0.55`. It must be an address that WebRTC clients can reach; MediaMTX includes it in its ICE candidates. Update it and recreate the containers if the Pi's LAN address changes. This setting does not change the RTSP, RTMP, HLS or SRT URLs.

Validate the resolved configuration, pull the pinned images and start the emulator:

```sh
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
```

## Camera URLs

Replace `cam_01` in any URL below with a zero-padded camera number through `cam_50`. `cam_00`, `cam_51` and unpadded names such as `cam_1` are not defined.

| Protocol | URL | Published port |
| --- | --- | --- |
| RTSP over TCP | `rtsp://192.168.0.55:8554/cam_01` | `8554/tcp` |
| RTMP | `rtmp://192.168.0.55:1935/cam_01` | `1935/tcp` |
| HLS | `http://192.168.0.55:8888/cam_01/index.m3u8` | `8888/tcp` |
| WebRTC player | `http://192.168.0.55:8889/cam_01` | `8889/tcp` plus `8189/udp` for ICE/media |
| WebRTC WHEP | `http://192.168.0.55:8889/cam_01/whep` | `8889/tcp` plus `8189/udp` for ICE/media |
| SRT | `srt://192.168.0.55:8890?streamid=read:cam_01` | `8890/udp` |

The table uses RTSP over TCP, which is also what both test scripts use. MediaMTX permits RTSP media over UDP as well; that mode uses `8554/tcp` for RTSP control plus `8000/udp` and `8001/udp` for RTP and RTCP.

For example, the last camera is `rtsp://192.168.0.55:8554/cam_50`. Camera-to-asset assignment is stable:

- `cam_01`, `cam_03`, ..., `cam_49` use `RPM_1.mp4` through `source_01`.
- `cam_02`, `cam_04`, ..., `cam_50` use `RPM_2.mp4` through `source_02`.

The internal `source_01` and `source_02` paths are implementation details; clients should use the `cam_NN` paths.

## Operate the deployment

Run these commands from the project directory on the Pi.

```sh
# Current state
docker compose ps

# Follow all logs
docker compose logs -f --tail=100

# Follow only the server and two publishers
docker compose logs -f --tail=100 mediamtx publisher-rpm-1 publisher-rpm-2

# Pause the deployment without deleting its containers
docker compose stop

# Resume stopped containers
docker compose start

# Stop and remove the deployment
docker compose down
```

After configuration, image or `.env` changes, apply the new settings with:

```sh
docker compose up -d --force-recreate
```

All three services use `restart: unless-stopped`. If Docker starts at boot, an unexpected process failure or Pi reboot brings the deployment back automatically:

```sh
sudo systemctl enable --now docker
```

A deployment that was deliberately stopped with `docker compose stop`, or removed with `docker compose down`, should not be treated as reboot-persistent. Run `docker compose start` or `docker compose up -d` respectively. After a reboot, allow up to 60 seconds for Docker, MediaMTX and both publishers to settle, then run the smoke test.

## Verify all 50 cameras

Run the scripts from the project root. With the supplied `.env` binding, this command checks every endpoint over RTSP/TCP from the Pi or another LAN machine:

```sh
RTSP_HOST=192.168.0.55 ./scripts/smoke-test.sh
```

It verifies that `cam_01` through `cam_50` each report H.264 video at 640x480 and 15 fps plus AAC audio. If `CAMERA_BIND_IP` is omitted or set to `0.0.0.0`, an on-Pi test can instead use the scripts' default `127.0.0.1` host:

```sh
./scripts/smoke-test.sh
```

Smoke-test settings can be overridden when diagnosing a slow or remote host:

```sh
RTSP_HOST=192.168.0.55 \
RTSP_PORT=8554 \
SMOKE_TIMEOUT_SECONDS=30 \
SMOKE_PARALLELISM=10 \
./scripts/smoke-test.sh
```

## Run the 75-second load test

The load test opens one RTSP/TCP stream-copy reader for each of the 50 cameras. Its default duration is 75 seconds, long enough to cross the loop boundary of both source files:

```sh
RTSP_HOST=192.168.0.55 ./scripts/load-test.sh
```

Run that command from a separate LAN machine when the test should include real network egress. The explicit `75` below is equivalent to the default duration:

```sh
RTSP_HOST=192.168.0.55 ./scripts/load-test.sh 75
```

The optional positional argument is the duration in seconds. It overrides `LOAD_TEST_DURATION_SECONDS`. Other available settings are:

```sh
RTSP_HOST=192.168.0.55 \
RTSP_PORT=8554 \
LOAD_TEST_DURATION_SECONDS=75 \
LOAD_TEST_IO_TIMEOUT_SECONDS=10 \
LOAD_TEST_LOG_DIR=./load-test-logs \
./scripts/load-test.sh
```

The test retains one diagnostic log per camera as `cam_NN.log` in `LOAD_TEST_LOG_DIR` and exits unsuccessfully if a reader fails. For a longer soak, use a larger positional duration, for example `./scripts/load-test.sh 600`.

While it runs, inspect the Pi separately:

```sh
docker stats --no-stream
vcgencmd get_throttled
docker compose ps
```

`get_throttled=0x0` means the Pi has not reported present or historical under-voltage or thermal throttling since boot. Investigate power, cooling or network issues if readers fail or containers restart.

## Performance model and join latency

This design performs file demuxing twice, packet copying in two publishers, and proxy/fan-out work in MediaMTX. It performs **zero video encodes**. Fifty idle public paths do not consume the resources of 50 FFmpeg processes; their on-demand proxies become active when clients read them.

With one viewer on each camera, the two source bitrates repeated 25 times each produce approximately **48.3 Mbit/s of media payload** leaving the Pi, before RTSP/RTP/TCP overhead. MediaMTX also moves comparable traffic through the loopback interface while the 50 aliases are active. Extra viewers add roughly the selected asset's bitrate per viewer, so capacity should be validated for the actual number of clients. The workload is primarily network I/O and packet handling rather than H.264 encoding, which is why it fits the Pi 5 substantially better than 50 transcoding containers.

The supplied files have long H.264 GOPs. Their longest measured gaps between IDR frames are about 12.3 seconds for `RPM_1.mp4` and 16.7 seconds for `RPM_2.mp4`. A newly connected decoder may therefore wait roughly **12-17 seconds** for its first independently decodable frame even though the RTSP session is already connected. This is expected, not a stalled camera. Reducing that delay requires assets encoded once with a shorter keyframe interval or runtime transcoding; runtime transcoding is deliberately excluded from this Pi-optimized setup.

The compressed timestamps are also preserved across each file loop. FFmpeg clients that remux a stream can report non-monotonic DTS warnings at that seam. The 50-reader wall-clock test crosses both assets' loop boundaries without connection loss or MediaMTX errors, but a downstream recorder that requires a perfectly continuous mux timeline may need the assets prepared once with a continuous timestamp/GOP layout.

## Security and LAN scope

This configuration is intended for a trusted LAN. It does not configure authentication, TLS or per-camera authorization, and the published ports allow any reachable client to consume streams. Do not expose them directly to the public internet or configure router port forwarding. Prefer binding `CAMERA_BIND_IP` to the Pi's LAN address, restrict access with the host/network firewall, and use a VPN or authenticated reverse proxy when access is needed from outside the LAN.
