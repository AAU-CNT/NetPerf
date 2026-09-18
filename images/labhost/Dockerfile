# labhost — the single container image every node in the dumbbell runs.
#
# Frozen decision 7 (CLAUDE.md): one image, all tools baked in, multi-arch so
# it runs on x86 laptops and arm64 Raspberry Pis alike. Keep this list minimal
# and portable — every package here must exist for both amd64 and arm64.
#
#   iperf3          throughput generation + JSON reporting (the measurement)
#   iproute2        `ss` (cwnd/RTT/retrans sampling) and `tc` (shaping, Task 2)
#   tcpdump         packet capture when a student wants to look closer
#   iputils-ping    reachability checks across the bottleneck
#   bwm-ng          quick live bandwidth read per interface
#   procps          `ps`, `sysctl` — inspecting namespaced CC settings
#
# Base: debian:bookworm-slim is an official multi-arch image (linux/amd64 and
# linux/arm64 both published), small, and ships a modern iproute2.
FROM debian:bookworm-slim

# Record the target arch for debugging; set automatically by `docker buildx`.
ARG TARGETPLATFORM
ARG TARGETARCH
LABEL org.opencontainers.image.title="netperf25/labhost" \
      org.opencontainers.image.description="NetPerf25 lab node: iperf3 + ss/tc + tcpdump" \
      org.opencontainers.image.source="https://github.com/"

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      iperf3 \
      iproute2 \
      tcpdump \
      iputils-ping \
      bwm-ng \
      procps \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && echo "built for ${TARGETPLATFORM:-unknown} (${TARGETARCH:-unknown})" > /etc/labhost-build

# Containerlab overrides the command, but keep the container alive if run bare
# (e.g. `docker run netperf25/labhost` for a smoke test).
CMD ["sleep", "infinity"]
