# Wg-monitor
Linux service to monitor a wg server and save to a different textfile each day all client change ,(client connected , client puclic ip change , client disconnect)

Download and execute the script. Answer the questions asked by the script and it will take care of the rest. For most VPS providers.

```bash
wget https://raw.githubusercontent.com/Brazzo978/Wg-monitor/refs/heads/main/wg-monitor.sh
bash ./wg-monitor.sh
```

Once the service is installed you can re-run the script to show you a menù with the following options : 
1) Print Monitor service status 
2) Restart the monitor status
3) Toggle the monitor service ON/OFF
4) Delete Log older than 30 days
5) Toggle debug mode
6) Remove everything made from the script
7) Exit

Each day the script will create a new text file in the /root/logwg folder , where its gonna log the state change of each client , like that :
[2025-07-29 12:18:07] Nuovo ip remoto per client 10.0.0.2/32: 1.1.1.1:56439
[2025-07-29 12:20:07] Client 10.0.0.2/32 offline (nessun handshake >120s)
[2025-07-29 13:43:22] Nuova connessione per client 10.0.0.3/32 da ip remoto (none)
[2025-07-29 13:49:42] Nuovo ip remoto per client 10.0.0.3/32: 1.1.1.1:44166
[2025-07-29 13:50:02] Nuovo ip remoto per client 10.0.0.3/32: 2.2.2.2:60737
[2025-07-29 13:50:22] Nuovo ip remoto per client 10.0.0.2/32: 1.1.1.1:44225
[2025-07-29 13:50:42] Nuovo ip remoto per client 10.0.0.2/32: 3.3.3.3:23863
[2025-07-29 13:50:52] Nuovo ip remoto per client 10.0.0.2/32: 1.1.1.1:44225
[2025-07-29 13:51:02] Nuovo ip remoto per client 10.0.0.3/32: 2.2.2.2:60738
[2025-07-29 13:53:02] Client 10.0.0.3/32 offline (nessun handshake >120s)
[2025-07-29 13:54:22] Client 10.0.0.2/32 offline (nessun handshake >120s).

