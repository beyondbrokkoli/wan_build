#!/bin/bash
echo "Clearing existing tc rules..."
sudo tc qdisc del dev lo root 2>/dev/null

echo "Applying Asymmetric WAN Chaos..."

# 1. Create root HTB qdisc with r2q 1 to prevent quantum warnings
sudo tc qdisc add dev lo root handle 1: htb default 99 r2q 1

# --- CLASS 10: "Fiber Optic" (Node 0, Port 50000) ---
# Pristine connection. This node will simulate way ahead.
sudo tc class add dev lo parent 1: classid 1:10 htb rate 100mbit
sudo tc qdisc add dev lo parent 1:10 handle 10: netem delay 20ms 5ms loss 0%

# --- CLASS 20: "4G LTE" (Node 1, Port 50001) ---
# Moderate lag. Will experience minor rollbacks.
sudo tc class add dev lo parent 1: classid 1:20 htb rate 10mbit
sudo tc qdisc add dev lo parent 1:20 handle 20: netem delay 150ms 50ms loss 5% reorder 5% 25%

# --- CLASS 30: "Symmetric NAT Chaos" (Nodes 2 & 3, Ports 50002 & 50003) ---
# Severe lag. Dropped 'duplicate' to avoid kernel tree conflicts. 
# 10% loss + 10% reorder + 300ms delay will force 100+ tick deep rollbacks.
sudo tc class add dev lo parent 1: classid 1:30 htb rate 3mbit
sudo tc qdisc add dev lo parent 1:30 handle 30: netem delay 300ms 100ms loss 10% reorder 10% 50%

# --- CLASS 99: Default Fallback ---
sudo tc class add dev lo parent 1: classid 1:99 htb rate 100mbit
sudo tc qdisc add dev lo parent 1:99 handle 99: netem delay 0ms

# 2. Route traffic based on Destination UDP Port (simulating the receiver's network condition)
sudo tc filter add dev lo protocol ip parent 1: prio 1 u32 match ip dport 50000 0xffff flowid 1:10
sudo tc filter add dev lo protocol ip parent 1: prio 1 u32 match ip dport 50001 0xffff flowid 1:20
sudo tc filter add dev lo protocol ip parent 1: prio 1 u32 match ip dport 50002 0xffff flowid 1:30
sudo tc filter add dev lo protocol ip parent 1: prio 1 u32 match ip dport 50003 0xffff flowid 1:30

echo "✅ Asymmetric chaos applied successfully."
echo "   Node 0 (50000): Fiber"
echo "   Node 1 (50001): 4G LTE"
echo "   Nodes 2,3 (50002,50003): Cellular Chaos"
