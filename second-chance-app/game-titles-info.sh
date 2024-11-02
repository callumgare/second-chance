#!/usr/bin/env bash
# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2034
{
secrets_can_kill__game_title="Secrets Can Kill"
secrets_can_kill__disk_count=2
secrets_can_kill__game_engine_to_use='scummvm'

secrets_can_kill_remastered__game_title="Secrets Can Kill Remastered"
secrets_can_kill_remastered__disk_count="1"
secrets_can_kill_remastered__internal_game_exe_path="/Program Files (x86)/Nancy Drew SCK/Secrets.exe"

stay_tuned__game_title="Stay Tuned for Danger"
stay_tuned__disk_count=1
stay_tuned__game_engine_to_use='scummvm'

haunted_mansion__game_title="Message in a Haunted Mansion"
haunted_mansion__disk_count=1
haunted_mansion__game_engine_to_use='scummvm'
haunted_mansion__steam_drm="no"

royal_tower__game_title="Treasure in the Royal Tower"
royal_tower__disk_count=1
royal_tower__game_engine_to_use='scummvm'
royal_tower__steam_drm="no"

final_scene__game_title="The Final Scene"
final_scene__disk_count=1
final_scene__game_engine_to_use='scummvm'

scarlet_hand__game_title="Secret of the Scarlet Hand"
scarlet_hand__disk_count=1
# SucmmVM has support but currently not stable and shows warning when starting
# scarlet_hand__game_engine_to_use='scummvm'
scarlet_hand__use_autoit_for_install='true'
scarlet_hand__internal_game_exe_path='/Nancy Drew/Secret of the Scarlet Hand/Game.exe'

ghost_dogs__game_title="Ghost Dogs of Moon Lake"
ghost_dogs__disk_count=1
ghost_dogs__use_autoit_for_install='true'
ghost_dogs__internal_game_exe_path='/Program Files (x86)/Nancy Drew/Ghost Dogs of Moon Lake/Game.exe'
ghost_dogs__steam_drm="yes-launch-when-steam-running"

haunted_carousel__game_title="The Haunted Carousel"
haunted_carousel__disk_count="1"
haunted_carousel__use_autoit_for_install='true'
haunted_carousel__internal_game_exe_path="/Nancy Drew/The Haunted Carousel/Game.exe"

deception_island__game_title="Danger on Deception Island"
deception_island__disk_count="1"
deception_island__use_autoit_for_install='true'
deception_island__internal_game_exe_path="/Nancy Drew/Danger on Deception Island/Game.exe"

shadow_ranch__game_title="The Secret of Shadow Ranch"
shadow_ranch__disk_count=1
shadow_ranch__use_autoit_for_install='true'
shadow_ranch__internal_game_exe_path='/Nancy Drew/Secret of Shadow Ranch/Game.exe'
shadow_ranch__steam_drm="no"

blackmoor_manor__game_title="Curse of Blackmoor Manor"
blackmoor_manor__disk_count="1"
blackmoor_manor__use_autoit_for_install='true'
blackmoor_manor__steam_drm="yes-launch-when-steam-running"
blackmoor_manor__internal_game_exe_path="/Nancy Drew/The Curse of Blackmoor Manor/Game.exe"

old_clock__game_title="Secret of the Old Clock"
old_clock__disk_count="1"
old_clock__use_autoit_for_install='true'
old_clock__internal_game_exe_path="/Nancy Drew/Secret of the Old Clock/Game.exe"
old_clock__steam_drm="no"

blue_moon__game_title="Last Train to Blue Moon Canyon"
blue_moon__disk_count=2
blue_moon__internal_game_exe_path='/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon/Game.exe'
blue_moon__steam_drm="yes-launch-when-steam-running"

danger_by_design__game_title="Danger by Design"
danger_by_design__disk_count="2"
danger_by_design__internal_game_exe_path="/Program Files (x86)/Nancy Drew/Danger by Design/Game.exe"

kapu_cave__game_title="The Creature of Kapu Cave"
kapu_cave__disk_count="2"
kapu_cave__internal_game_exe_path="/Program Files (x86)/Nancy Drew/The Creature of Kapu Cave/Game.exe"

white_wolf__game_title="The White Wolf of Icicle Creek"
white_wolf__disk_count="2"
white_wolf__internal_game_exe_path="/Program Files (x86)/Nancy Drew/The White Wolf of Icicle Creek/Game.exe"

crystal_skull__game_title="Legend of the Crystal Skull"
crystal_skull__disk_count="2"
crystal_skull__internal_game_exe_path="/Program Files (x86)/Nancy Drew/Legend of the Crystal Skull/Game.exe"

phantom_of_venice__game_title="The Phantom of Venice"
phantom_of_venice__disk_count="2"
phantom_of_venice__internal_game_exe_path="/Program Files (x86)/Nancy Drew/The Phantom of Venice/PhantomOfVenice.exe"

castle_malloy__game_title="The Haunting of Castle Malloy"
castle_malloy__disk_count="2"
castle_malloy__internal_game_exe_path="/Program Files (x86)/Nancy Drew/The Haunting of Castle Malloy/CastleMalloy.exe"

seven_ships__game_title="Ransom of the Seven Ships"
seven_ships__disk_count="2"
seven_ships__internal_game_exe_path="/Program Files (x86)/Nancy Drew/Ransom of the Seven Ships/Ransom.exe"

waverly_academy__game_title="Warnings at Waverly Academy"
waverly_academy__disk_count="2"
waverly_academy__internal_game_exe_path="/Program Files (x86)/Nancy Drew/Warnings at Waverly Academy/Waverly.exe"
waverly_academy__steam_drm="yes-launch-when-steam-running"

trail_of_the_twister__game_title="Trail of the Twister"
trail_of_the_twister__disk_count="2"
trail_of_the_twister__internal_game_exe_path="/Program Files (x86)/Nancy Drew/Trail of the Twister/Twister.exe"

waters_edge__game_title="Shadow at the Water's Edge"
waters_edge__disk_count="2"
waters_edge__internal_game_exe_path="/Program Files (x86)/Nancy Drew/Shadow at the Water's Edge/Shadow.exe"
waters_edge____steam_drm="yes-launch-when-steam-running"

captive_curse__game_title="The Captive Curse"
captive_curse__disk_count="1"
captive_curse__internal_game_exe_path="/Program Files (x86)/Nancy Drew/The Captive Curse/Captive.exe"

alibi_in_ashes__game_title="Alibi in Ashes"
alibi_in_ashes__disk_count="1"
alibi_in_ashes__internal_game_exe_path="/Program Files (x86)/Her Interactive/Nancy Drew Alibi in Ashes/Alibi.exe"

lost_queen__game_title="Tomb of the Lost Queen"
lost_queen__disk_count="1"
lost_queen__internal_game_exe_path="/Program Files (x86)/Her Interactive/Tomb of the Lost Queen/Tomb.exe"

deadly_device__game_title="The Deadly Device"
deadly_device__disk_count="1"
deadly_device__internal_game_exe_path="/Program Files (x86)/Her Interactive/The Deadly Device/DeadlyDevice.exe"

thornton_hall__game_title="Ghost of Thornton Hall"
thornton_hall__disk_count="1"
thornton_hall__internal_game_exe_path="/Program Files (x86)/Her Interactive/Ghost of Thornton Hall/Thornton.exe"
thornton_hall__steam_drm="yes-launch-via-steam-only"

silent_spy__game_title="The Silent Spy"
silent_spy__disk_count="1"
silent_spy__internal_game_exe_path="/Program Files (x86)/Her Interactive/The Silent Spy/Spy.exe"

shattered_medallion__game_title="The Shattered Medallion"
shattered_medallion__disk_count="1"
shattered_medallion__internal_game_exe_path="/Program Files (x86)/Her Interactive/The Shattered Medallion/Medallion.exe"

labyrinth_of_lies__game_title="Labyrinth of Lies"
labyrinth_of_lies__disk_count="1"
labyrinth_of_lies__internal_game_exe_path="/Program Files (x86)/Her Interactive/Labyrinth of Lies/Labyrinth.exe"

sea_of_darkness__game_title="Sea of Darkness"
sea_of_darkness__disk_count="1"
sea_of_darkness__internal_game_exe_path="/Program Files (x86)/Her Interactive/Sea of Darkness/SeaOfDarkness.exe"

unknown__game_title="Other"
unknown__install_instructions=$(cat <<EOF
Accept all default options unless the installer tries to install DirectX. In which case select the option NOT to install DirectX. If asked if you want to play the game after installation, select "No".
EOF
)
}
