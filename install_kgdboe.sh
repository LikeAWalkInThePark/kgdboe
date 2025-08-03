#!/bin/bash

set -euo pipefail

# Get current kernel version
kernel_version=$(uname -r)
extra_dir="/lib/modules/${kernel_version}/extra"

# Ensure the extra module directory exists
if [ ! -d "$extra_dir" ]; then
    sudo mkdir -p "$extra_dir"
fi

# Copy the kgdboe kernel module
sudo cp kgdboe.ko "$extra_dir"
sudo depmod -a

# Prompt user to select a network interface
interfaces=( /sys/class/net/* )
interface_names=()

for iface in "${interfaces[@]}"; do
    iface_name=$(basename "$iface")
    # Skip loopback interface
    if [[ "$iface_name" != "lo" ]]; then
        interface_names+=( "$iface_name" )
    fi
done

PS3='Which Network Interface will be used for debugging: '

select opt in "${interface_names[@]}"; do
    if [[ -n "$opt" ]]; then
        break
    fi
    echo "Invalid option, try again."
done

echo "Selected interface: $opt"

# Get the driver name for the selected interface
driver_link="/sys/class/net/${opt}/device/driver"
if [ -L "$driver_link" ]; then
    driver_name=$(basename "$(readlink "$driver_link")")
else
    echo "Could not determine driver for interface $opt"
    exit 1
fi

# Add kgdboe and the interface's driver to initramfs-tools/modules if not already present
modules_file="/etc/initramfs-tools/modules"

if ! grep -qxF 'kgdboe' "$modules_file"; then
    echo 'kgdboe' | sudo tee -a "$modules_file" > /dev/null
fi

if ! grep -qxF "$driver_name" "$modules_file"; then
    echo "$driver_name" | sudo tee -a "$modules_file" > /dev/null
fi

# Save the selected interface name for use in initramfs
conf_file="/etc/modprobe.d/kgdboe.conf"

if [ ! -f "$conf_file" ]; then
    echo "[INFO] Creating $conf_file"
    echo "options kgdboe device_name=$opt" | sudo tee "$conf_file" > /dev/null
else
    # Update or replace device_name in the existing file
    if grep -q 'device_name=' "$conf_file"; then
        sudo sed -i "s/device_name=.*/device_name=$opt/" "$conf_file"
    else
        echo "options kgdboe device_name=$opt" | sudo tee -a "$conf_file" > /dev/null
    fi
fi

# Copy the initramfs bottom script
init_bottom_dir="/etc/initramfs-tools/scripts/init-bottom"
init_script="99-kgdboe.sh"
source_script_path="$(dirname "$0")/$init_script"
target_script_path="$init_bottom_dir/$init_script"

if [ ! -f "$source_script_path" ]; then
    echo "❌ ERROR: Cannot find $init_script in $(dirname "$0")"
    exit 1
fi

echo "Copying $init_script to $init_bottom_dir..."
sudo mkdir -p "$init_bottom_dir"
sudo cp "$source_script_path" "$target_script_path"
sudo chmod +x "$target_script_path"
echo "✅ Copied and set executable: $target_script_path"

# Update initramfs
echo "Updating initramfs..."
sudo update-initramfs -u

echo "✅ kgdboe module and driver '$driver_name' added to initramfs."
echo "✅ Interface '$opt' saved to $conf_file."
echo "✅ Initramfs hook script installed at $target_script_path"

