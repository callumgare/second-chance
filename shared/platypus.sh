#!/usr/bin/env bash

# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

platypus_build () {
    local platypus_config_template_path="$1"
    local output_dir="$2"
    local root_dir
    root_dir="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
    local platypus_config_built_path
    platypus_config_built_path="$(mktemp -t "second-chance-platypus-config")"

    cp "$platypus_config_template_path" "$platypus_config_built_path"
    sed -i '' "s|\\\$project_root|$root_dir/..|g" "$platypus_config_built_path"
    sed -i '' "s|\\\$debug_mode|${debug_mode:-false}|g" "$platypus_config_built_path"
    
    platypus -P "$platypus_config_built_path" -y "$output_dir"
    rm "$platypus_config_built_path"
}