#!/bin/bash
# Called by semantic-release @semantic-release/exec
# Packages the addon into a zip for GitHub Release
VERSION=$1

echo "Packaging MidnightHuntTracker v${VERSION}..."

# Create a temp directory with the addon structure
mkdir -p _build/MidnightHuntTracker

# Copy only addon files (no dev files, no screenshots, no git)
cp Core.lua _build/MidnightHuntTracker/
cp MidnightHuntTracker.toc _build/MidnightHuntTracker/

# Create the zip
cd _build
zip -r ../MidnightHuntTracker.zip MidnightHuntTracker/
cd ..

# Cleanup
rm -rf _build

echo "Created MidnightHuntTracker.zip (v${VERSION})"
ls -la MidnightHuntTracker.zip
