# Workload image for both target and neighbour containers.
#
# Pinned to a specific Debian point release so the stress-ng version is
# stable across the whole run set. An unpinned base would let a mid study
# apt update change the workload underneath the measurements.

FROM debian:bookworm-20250520-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends stress-ng procps \
 && rm -rf /var/lib/apt/lists/*

# Record the exact version into the image so it lands in the results
# provenance rather than living only in someone's shell history.
RUN stress-ng --version > /stress-ng-version.txt

ENTRYPOINT ["stress-ng"]
