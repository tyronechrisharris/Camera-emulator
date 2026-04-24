# Camera Stream Emulator

This project provides a simple camera stream emulator using Docker Compose, MediaMTX, and FFmpeg.

## What it does

The emulator creates a local media streaming server (using [MediaMTX](https://github.com/bluenviron/mediamtx)) and simulates IP cameras by continually looping video files from the `assets/` directory using FFmpeg.

These emulated camera streams are pushed to the MediaMTX server via RTSP, making them available over various protocols such as RTSP, RTMP, HLS, and WebRTC. The video streams are also overlaid with a high-resolution, real-time timestamp to simulate live camera footage and assist with latency testing or synchronization checks.

## Scalability: Emulating 100 Camera Streams

The emulator is designed to be easily extensible. While the default `docker-compose.yml` provides a few example cameras, the architecture allows you to scale up and create **100 emulated camera streams** (or more).

To do this, you simply need to expand the `docker-compose.yml` file to include additional `camera-XX` services, each pointing to their respective asset files and publishing to a unique path on the MediaMTX server (e.g., `rtsp://mediamtx:8554/cam_01` to `rtsp://mediamtx:8554/cam_100`). Keep in mind that running a large number of concurrent FFmpeg encoding streams will require adequate CPU and memory resources on the host machine.

## How to run

1. Ensure you have Docker and Docker Compose installed.
2. Place your source video files in the `assets/` directory (e.g., `RPM_1.mp4`, `RPM_2.mp4`).
3. Run `docker-compose up -d` to start the MediaMTX server and the emulated cameras.
4. Access the streams using a media player like VLC or integrate them into your application (e.g., `rtsp://localhost:8554/cam_01`).
