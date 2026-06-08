# Beépíthető klasszikus Windows hibamodulok

## Prioritás 1

1. PendingRebootInspector
   - Registry pending reboot kulcsok és CBS pending állapotok részletes vizsgálata.

2. UpdateErrorClassifier
   - Windows Update hibakódok osztályozása: 0x800f081f, 0x800f0831, 0x80070422, 0x80071A91, 0x80244007.

3. DiskAndReservedStorageHealth
   - Szabad hely, reserved storage, chkdsk javaslat, WinSxS méret.

4. NetworkProxyWsusHealth
   - Proxy, WinHTTP proxy, WSUS policy, scan endpoint elérhetőség.

5. TimeCryptoCatalogHealth
   - Időszinkron, cryptsvc, catroot2, tanúsítvány/catalógus tünetek.

## Prioritás 2

6. BITSQueueInspector
   - Beragadt BITS queue és letöltési feladatok.

7. DriverBlockerInspector
   - SetupAPI.dev.log és Kernel-PnP események alapján driver blokkolók.

8. WMIRepositoryHealth
   - WMI/CIM lekérdezési hibák és repository állapot.

9. WinREAndRecoveryHealth
   - reagentc /info, WinRE állapot, recovery partíció.

10. EventLogChannelHealth
    - Hiányzó vagy tiltott event log csatornák.
