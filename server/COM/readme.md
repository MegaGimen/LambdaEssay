# WordCOM Server

This is a C++ implementation of the Word Plugin helper, replacing the legacy `taskpane.js` logic with a native COM-based solution.

## Features

- **Protocol Compatibility**: Fully compatible with `server.dart` WebSocket protocol.
- **Word Automation**: Uses COM (OLE Automation) to control Microsoft Word.
- **Functionality**:
    - `save`: Saves the active document.
    - `replace`: Replaces the active document content (supports Text, HTML, Base64 Docx).
    - `event: saved`: Monitors the document for save events and notifies the server.
    - `checkPath`: Verifies the document path before replacement.

## Build

Requires `g++` (MinGW-w64).

```bash
g++ main.cpp -o WordCOM.exe -lwinhttp -lole32 -loleaut32 -luuid -lcrypt32 -static-libgcc -static-libstdc++
```

## Usage

1. Ensure `server.dart` is running on `localhost:8080`.
2. Ensure Microsoft Word is running and a document is open.
3. Run `WordCOM.exe`.

The program will:
1. Connect to the running Word instance.
2. Connect to the WebSocket server at `ws://localhost:8080/ws`.
3. Listen for commands and monitor save events.

## Architecture

- **Main Thread**: Handles COM interactions (Word is single-threaded/STA) and processes the task queue.
- **WebSocket Thread**: Listens for incoming WebSocket messages and pushes them to the task queue.
- **COM**: Uses `IDispatch` and `Invoke` for late-binding automation, ensuring compatibility across Word versions.
- **WinHTTP**: Uses Windows native HTTP/WebSocket API.

