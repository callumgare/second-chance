#!/bin/bash
# Reset TCC entries for Second Chance and GamePuppeteer.
# Run this after each rebuild if the TCC prompt shows the wrong app name.
set -e

tccutil reset Accessibility au.gare.callum.SecondChance
tccutil reset ScreenCapture au.gare.callum.SecondChance
tccutil reset Accessibility au.gare.callum.SecondChance.GamePuppeteer
tccutil reset ScreenCapture au.gare.callum.SecondChance.GamePuppeteer

echo "Done — TCC entries cleared. Re-run the test and accept the GamePuppeteer permission prompt."
