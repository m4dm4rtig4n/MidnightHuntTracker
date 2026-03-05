#!/bin/bash
# Called by semantic-release @semantic-release/exec
# Updates version in .toc and Core.lua
VERSION=$1

echo "Updating version to ${VERSION}..."

# Update .toc file
sed -i "s/^## Version: .*/## Version: ${VERSION}/" MidnightHuntTracker.toc

# Update Core.lua version message
sed -i "s/Midnight Hunt Tracker v[0-9.]* charge/Midnight Hunt Tracker v${VERSION} charge/" Core.lua
sed -i "s/Midnight Hunt Tracker v[0-9.]* :/Midnight Hunt Tracker v${VERSION} :/" Core.lua

# Update package.json version
sed -i "s/\"version\": \".*\"/\"version\": \"${VERSION}\"/" package.json

echo "Version updated to ${VERSION} in .toc, Core.lua and package.json"
