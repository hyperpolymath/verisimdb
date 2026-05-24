# SPDX-License-Identifier: MPL-2.0
# ClusterFuzzLite build environment for VeriSimDB
FROM gcr.io/oss-fuzz-base/base-builder-rust

COPY . $SRC/verisimdb
WORKDIR $SRC/verisimdb
COPY .clusterfuzzlite/build.sh $SRC/build.sh
