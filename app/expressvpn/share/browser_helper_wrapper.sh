#!/bin/bash

script_path=$(realpath "$0")
script_dir=$(dirname "$script_path")

if [[ "$OSTYPE" == "darwin"* ]]; then
    exec_dir="MacOS"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    exec_dir="bin"
fi

browser_helper_path="${script_dir}/../${exec_dir}/browser_helper"

if [ $# -gt 1 ]; then
  # Firefox passes two args, we want the second arg (the extension id)
  # arg1 is path/to/manifest.json
  # arg2 is extension id (which is an email address for firefox)
  extension_id="$2"
else
  # Chrome only passes the extension id as a single arg
  extension_id="$1"
fi

# Inject the brand as an environment variable
QT_VPN_BRAND=expressvpn exec "$browser_helper_path" "$extension_id"
