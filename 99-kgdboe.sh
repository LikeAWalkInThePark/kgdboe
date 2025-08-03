#!/bin/sh

# 99-dhcpd.sh - Initramfs script to start DHCPD on configured interface

PREREQ=""

prereqs() {
    echo "$PREREQ"
}

case "$1" in
    prereqs)
        prereqs
        exit 0
        ;;
esac

# Extract interface name from /etc/modprobe.d/kgdboe.conf
IFACE=$(grep -o 'device_name=[^ ,]*' /etc/modprobe.d/kgdboe.conf | cut -d= -f2)

if [ -z "$IFACE" ]; then
    echo "[initramfs] ERROR: Could not determine network interface from /etc/modprobe.d/kgdboe.conf"
    exit 1
fi

echo "[initramfs] Using interface: $IFACE"

# Wait for interface to appear
echo "[initramfs] Waiting for interface $IFACE..."
timeout=10
while [ ! -e /sys/class/net/$IFACE ] && [ "$timeout" -gt 0 ]; do
    sleep 1
    timeout=$((timeout - 1))
done

# Bring the interface up
ip link set $IFACE up

# Wait for carrier (link up)
timeout=10
while [ "$(cat /sys/class/net/$IFACE/carrier 2>/dev/null)" != "1" ] && [ "$timeout" -gt 0 ]; do
    echo "[initramfs] Waiting for carrier on $IFACE..."
    sleep 1
    timeout=$((timeout - 1))
done

# Start DHCP client
echo "[initramfs] Starting dhcpcd on $IFACE..."
/sbin/dhcpcd -q $IFACE

# Wait for IP address to be assigned
timeout=15
while [ "$timeout" -gt 0 ]; do
    IP=$(ip -4 addr show dev $IFACE | awk '/inet / {print $2}' | cut -d/ -f1 | grep -v '^169\.254')
    if [ -n "$IP" ]; then
        echo "[initramfs] IP address assigned to $IFACE: $IP"
        break
    fi
    echo "[initramfs] Waiting for DHCP IP on $IFACE..."
    sleep 1
    timeout=$((timeout - 1))
done

if [ -z "$IP" ]; then
    echo "[initramfs] Failed to obtain IP address on $IFACE."
else
    # Load kgdboe module with kallsyms_lookup_name address
    KSYM_ADDR=$(grep ' T kallsyms_lookup_name' /proc/kallsyms | awk '{print $1}')
    if [ -n "$KSYM_ADDR" ]; then
        echo "[initramfs] Inserting kgdboe module with kallsyms_lookup_name address 0x$KSYM_ADDR"
        insmod /lib/modules/$(uname -r)/extra/kgdboe.ko \
            kallsyms_lookup_name_address=0x$KSYM_ADDR \
            device_name=$IFACE
        echo "[initramfs] kgdboe module loaded."
    else
        echo "[initramfs] Failed to find kallsyms_lookup_name address."
    fi
fi

# Wait for someone to connect to KGDB by monitoring kgdboe module refcount
timeout=60
echo "[initramfs] Waiting for KGDB connection..."
while [ "$timeout" -gt 0 ]; do
    REFCNT=$(cat /sys/module/kgdboe/refcnt 2>/dev/null)
    if [ "$REFCNT" -gt 0 ] 2>/dev/null; then
        echo "[initramfs] KGDB connection established (refcnt=$REFCNT)"
        break
    fi
    sleep 1
    timeout=$((timeout - 1))
done

if [ "$timeout" -le 0 ]; then
    echo "[initramfs] Timeout waiting for KGDB connection."
fi


