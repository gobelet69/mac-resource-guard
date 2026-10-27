# Mac Resource Guard — Empirical Performance Audit

- **Hardware**: Apple M2 (8 logical cores, 8 GB RAM)
- **OS**: macOS 27.0 (26A428)
- **Build Configuration**: Release (`-O -whole-module-optimization`, stripped)

## 1. Memory Footprint (Target: < 40 MB)

```
PS (PID, RSS_KB, %CPU, VSZ_KB):
  PID    RSS  %CPU      VSZ
59221  58384   3.0 489012144

vmmap -summary:
Physical footprint:         17.6M
Physical footprint (peak):  17.7M
unused but dirty shlib __DATA      512K     345K     345K     167K       0K       0K       0K      347 
```

## 2. Idle CPU & Wakeups Over 22s Window (Target: < 0.2% Avg Idle CPU)

```
PID    %CPU   MEM      PURG   IDLEW  THREADS
59221  0.0  18M 0    
59221  0.6  18M+ 0    
59221  0.0  18M  0    
59221  0.0  18M  0    
59221  0.0  18M  0    
59221  0.0  18M  0    
59221  0.7  18M+ 0    
59221  0.0  18M  0    
59221  0.0  18M  0    
59221  0.0  18M- 0    
59221  0.0  18M  0    
59221  0.9  18M+ 0    
```

## 3. Detailed Sampling Under Controlled CPU Load

```
PID    %CPU   MEM      IDLEW  THREADS
59587  0.0  38M 0    
59587  1.7  39M+ 0    
59587  0.0  38M- 0    
```

## 4. Memory Leak Verification (`leaks`)

```
Process 59221: 53209 nodes malloced for 6954 KB
Process 59221: 417 leaks for 20016 total leaked bytes.
```

## 5. Call Graph & Main Thread Responsiveness (`sample`)

```
Call graph:
    1699 Thread_1536713   DispatchQueue_1: com.apple.main-thread  (serial)
    + 1699 start  (in dyld) + 6688  [0x19da9be80]
    +   1699 main  (in MacResourceGuard) + 88  [0x102d795d0]  main.swift:6
    +     1699 -[NSApplication run]  (in AppKit) + 396  [0x1a24db90c]
    +       1699 -[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]  (in AppKit) + 292  [0x1a2d6026c]
    +         1699 -[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]  (in AppKit) + 780  [0x1a2d60748]
    +           1699 _DPSNextEvent  (in AppKit) + 580  [0x1a24e84fc]
    +             1699 _DPSBlockUntilNextEventMatchingListInMode  (in AppKit) + 292  [0x1a282b29c]
    +               1699 _BlockUntilNextEventMatchingListInMode  (in HIToolbox) + 48  [0x1ab4ea380]
    +                 1699 ReceiveNextEventCommon  (in HIToolbox) + 492  [0x1ab36791c]
    +                   1699 RunCurrentEventLoopInMode  (in HIToolbox) + 320  [0x1ab364590]
    +                     1699 _CFRunLoopRunSpecificWithOptions  (in CoreFoundation) + 536  [0x19e00b82c]
```
