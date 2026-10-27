# Mac Resource Guard — Empirical Performance Audit

- **Hardware**: Apple M2 (8 logical cores, 8 GB RAM)
- **OS**: macOS 27.0 (26A428)
- **Build Configuration**: Release (`-O -whole-module-optimization`, stripped)

## 1. Memory Footprint (Target: < 40 MB)

```
PS (PID, RSS_KB, %CPU, VSZ_KB):
  PID    RSS  %CPU      VSZ
54839  58624   0.0 489015952

vmmap -summary:
Physical footprint:         17.5M
Physical footprint (peak):  17.7M
unused but dirty shlib __DATA      512K     308K     308K     203K       0K       0K       0K      347 
```

## 2. Idle CPU & Wakeups Over 22s Window (Target: < 0.2% Avg Idle CPU)

```
PID    %CPU   MEM      PURG   IDLEW  THREADS
54839  0.0  18M 0    
54839  0.3  18M- 0    
54839  0.0  18M- 0    
54839  0.0  18M  0    
54839  0.0  18M  0    
54839  0.0  18M  0    
54839  0.5  18M+ 0    
54839  0.0  18M  0    
54839  0.0  18M  0    
54839  0.0  18M- 0    
54839  0.0  18M  0    
54839  0.4  18M+ 0    
```

## 3. Detailed Sampling Under Controlled CPU Load

```
PID    %CPU   MEM      IDLEW  THREADS
55181  0.0  41M 0    
55181  1.8  42M+ 0    
55181  0.0  42M- 0    
```

## 4. Memory Leak Verification (`leaks`)

```
Process 54839: 53742 nodes malloced for 6974 KB
Process 54839: 417 leaks for 20016 total leaked bytes.
```

## 5. Call Graph & Main Thread Responsiveness (`sample`)

```
Call graph:
    1721 Thread_1514288   DispatchQueue_1: com.apple.main-thread  (serial)
    + 1721 start  (in dyld) + 6688  [0x19da9be80]
    +   1721 main  (in MacResourceGuard) + 88  [0x104731568]
    +     1721 -[NSApplication run]  (in AppKit) + 396  [0x1a24db90c]
    +       1721 -[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]  (in AppKit) + 292  [0x1a2d6026c]
    +         1721 -[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]  (in AppKit) + 780  [0x1a2d60748]
    +           1721 _DPSNextEvent  (in AppKit) + 580  [0x1a24e84fc]
    +             1721 _DPSBlockUntilNextEventMatchingListInMode  (in AppKit) + 292  [0x1a282b29c]
    +               1721 _BlockUntilNextEventMatchingListInMode  (in HIToolbox) + 48  [0x1ab4ea380]
    +                 1721 ReceiveNextEventCommon  (in HIToolbox) + 492  [0x1ab36791c]
    +                   1721 RunCurrentEventLoopInMode  (in HIToolbox) + 320  [0x1ab364590]
    +                     1721 _CFRunLoopRunSpecificWithOptions  (in CoreFoundation) + 536  [0x19e00b82c]
```
