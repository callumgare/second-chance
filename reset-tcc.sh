#!/bin/bash
# Reset TCC entries for Second Chance and WrappPuppeteer.
# Rebuilds keep the grants (the apps are signed with an Apple Development
# certificate), so this is only needed when they go stale: a changed bundle ID,
# a build signed by a different account, or a prompt showing the wrong app name.
set -e

tccutil reset Accessibility au.gare.callum.SecondChance
tccutil reset ScreenCapture au.gare.callum.SecondChance
tccutil reset Accessibility au.gare.callum.SecondChance.WrappPuppeteer
tccutil reset ScreenCapture au.gare.callum.SecondChance.WrappPuppeteer

echo "Done — TCC entries cleared. Re-run the test and accept the WrappPuppeteer permission prompt."
