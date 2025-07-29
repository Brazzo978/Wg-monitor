# Wg-monitor
Linux service to monitor a WireGuard server and save to a different text file
each day when clients change (client connected, client public IP change,
client disconnect).

Download and execute the script. Answer the questions asked by the script and it will take care of the rest. For most VPS providers.

```bash
wget https://raw.githubusercontent.com/Brazzo978/Wg-monitor/refs/heads/main/wg-monitor.sh
bash ./wg-monitor.sh
```

Once the service is installed you can re-run the script to show a menu with the
following options:
1) Print Monitor service status 
2) Restart the monitor status
3) Toggle the monitor service ON/OFF
4) Delete Log older than 30 days
5) Toggle debug mode
6) Remove everything made from the script
7) Exit

Each day the script creates a new text file in `/root/logwg` where it logs state
changes for each client. Example output:
[2025-07-29 12:18:07] New remote IP for client 10.0.0.2/32: 1.1.1.1:56439
[2025-07-29 12:20:07] Client 10.0.0.2/32 offline (no handshake >120s)
[2025-07-29 13:43:22] New connection for client 10.0.0.3/32 from remote IP (none)
[2025-07-29 13:49:42] New remote IP for client 10.0.0.3/32: 1.1.1.1:44166
[2025-07-29 13:50:02] New remote IP for client 10.0.0.3/32: 2.2.2.2:60737
[2025-07-29 13:50:22] New remote IP for client 10.0.0.2/32: 1.1.1.1:44225
[2025-07-29 13:50:42] New remote IP for client 10.0.0.2/32: 3.3.3.3:23863
[2025-07-29 13:50:52] New remote IP for client 10.0.0.2/32: 1.1.1.1:44225
[2025-07-29 13:51:02] New remote IP for client 10.0.0.3/32: 2.2.2.2:60738
[2025-07-29 13:53:02] Client 10.0.0.3/32 offline (no handshake >120s)
[2025-07-29 13:54:22] Client 10.0.0.2/32 offline (no handshake >120s).

