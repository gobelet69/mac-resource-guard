# Mac Resource Guard — Empirical Performance Audit

- **Hardware**: Apple M2 (8 logical cores, 8 GB RAM)
- **OS**: macOS 27.0 (26A428)
- **Build Configuration**: Release (`-O -whole-module-optimization`, stripped)

## 1. Memory Footprint (Target: < 40 MB)

```
PS (PID, RSS_KB, %CPU, VSZ_KB):
  PID    RSS  %CPU      VSZ
91444  55120   0.0 489019648

vmmap -summary:
Physical footprint:         19.9M
Physical footprint (peak):  20.1M
unused but dirty shlib __DATA      512K     332K     332K     180K       0K       0K       0K      347 
```

## 2. Idle CPU & Wakeups Over 22s Window (Target: < 0.2% Avg Idle CPU)

```
PID    %CPU   MEM      PURG   IDLEW  THREADS
91444  0.0  20M 0    
91444  0.7  20M- 0    
91444  0.0  20M- 0    
91444  0.0  20M  0    
91444  0.0  20M  0    
91444  0.0  20M  0    
91444  0.6  20M+ 0    
91444  0.0  20M  0    
91444  0.0  20M  0    
91444  0.0  20M- 0    
91444  0.0  20M  0    
91444  0.7  20M  0    
```

## 3. Detailed Sampling Under Controlled CPU Load

```
PID    %CPU   MEM      IDLEW  THREADS
91465  0.0  44M 0    
91465  1.9  45M+ 0    
91465  1.3  44M- 0    
```

## 4. Memory Leak Verification (`leaks`)

```
Process 91444: 48309 nodes malloced for 6629 KB
Process 91444: 417 leaks for 20016 total leaked bytes.
```

## 5. Call Graph & Main Thread Responsiveness (`sample`)

```
Call graph:
    1696 Thread_152641668   DispatchQueue_1: com.apple.main-thread  (serial)
    + 1696 start  (in dyld) + 6688  [0x19e95fe80]
    +   1696 main  (in MacResourceGuard) + 88  [0x100c69568]  main.swift:6
    +     1696 -[NSApplication run]  (in AppKit) + 396  [0x1a339f90c]
    +       1696 -[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]  (in AppKit) + 292  [0x1a3c2426c]
    +         1696 -[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]  (in AppKit) + 780  [0x1a3c24748]
    +           1696 _DPSNextEvent  (in AppKit) + 580  [0x1a33ac4fc]
    +             1696 _DPSBlockUntilNextEventMatchingListInMode  (in AppKit) + 292  [0x1a36ef29c]
    +               1696 _BlockUntilNextEventMatchingListInMode  (in HIToolbox) + 48  [0x1ac3ae380]
    +                 1696 ReceiveNextEventCommon  (in HIToolbox) + 492  [0x1ac22b91c]
    +                   1696 RunCurrentEventLoopInMode  (in HIToolbox) + 320  [0x1ac228590]
    +                     1696 _CFRunLoopRunSpecificWithOptions  (in CoreFoundation) + 536  [0x19eecf82c]
```
