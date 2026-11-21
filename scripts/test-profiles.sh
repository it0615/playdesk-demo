#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/profile-safety
swiftc Sources/AdFreeAndroidLauncher/Profiles.swift Tests/ProfileStoreSafety/main.swift -o .build/profile-safety/tests
.build/profile-safety/tests
