#!/usr/bin/env bash
set -e

echo "1. Installing dependencies..."
sudo apt update && sudo apt install -y build-essential linux-headers-$(uname -r) wget tar

echo "2. Preparing Root FS..."
mkdir -p rootfs-base
wget -nc https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-minirootfs-3.20.3-x86_64.tar.gz -O alpine.tar.gz
tar -xzf alpine.tar.gz -C rootfs-base
cp -a rootfs-base rootfs-alpha
cp -a rootfs-base rootfs-beta

echo "3. Building project..."
make -C src all

echo "4. Running Smoke Check..."
make -C src ci
./src/engine 2>&1 | grep -q "Usage:" && echo "Smoke Check Passed!" || (echo "Smoke Check Failed!"; exit 1)

echo "Done! System ready."
