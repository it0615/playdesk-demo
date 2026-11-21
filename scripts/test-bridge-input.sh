#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/bridge-input
swiftc Sources/AdFreeAndroidLauncher/AndroidBridge.swift Tests/BridgeInputSafety/main.swift -o .build/bridge-input/tests
.build/bridge-input/tests
