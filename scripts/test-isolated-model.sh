#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/isolated-model
swiftc -parse-as-library Sources/AdFreeAndroidLauncher/{AndroidBridge,Profiles,LauncherModel,ContentView,KeyCaptureView}.swift Tests/IsolatedModelSmoke/main.swift -o .build/isolated-model/tests
.build/isolated-model/tests "$@"
