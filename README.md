# MacSpy

MacSpy is a native macOS accessibility inspector inspired by the system-object
inspection workflow of Spy++. It provides a Mac-specific view of processes,
threads, windows, accessibility elements, and public Accessibility events.

## Features

- Desktop-rooted system window browser
- Process, thread, window, and accessibility-element relationships
- Continuous pointer inspection with an on-screen highlight
- Floating live parameter panel for the element under the pointer
- Accessibility attribute and supported-action inspector
- Apple API trace showing the public APIs invoked by MacSpy
- AXObserver event timeline for supported target notifications
- Process and PID search
- Direct Accessibility settings onboarding

## Requirements

- macOS 13 or later
- Xcode with the macOS SDK
- Accessibility permission for inspecting other applications

On first launch, enable MacSpy in:

`System Settings → Privacy & Security → Accessibility`

## Build

Open `MacSpy.xcodeproj`, select the **MacSpy** scheme and **My Mac**, then run
the application with `Command-R`.

For a Release build:

```bash
xcodebuild \
  -project MacSpy.xcodeproj \
  -scheme MacSpy \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

## Platform limitations

macOS does not expose Win32-style `HWND`, `WNDPROC`, or cross-process `WM_*`
message logging. MacSpy displays information available through public macOS
APIs, including Quartz Window Services, `libproc`, Accessibility, and
`AXObserver`. The API trace represents APIs called by MacSpy while inspecting a
target; it does not claim to reveal private function calls made inside another
application.
