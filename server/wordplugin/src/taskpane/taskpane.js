/*
 * Copyright (c) Microsoft Corporation. All rights reserved. Licensed under the MIT license.
 * See LICENSE in the project root for license information.
 */

/* global document, Office, Word, setInterval, clearInterval, WebSocket */

let ws;
const WS_URL = "ws://localhost:8080/ws";

Office.onReady((info) => {
  if (info.host === Office.HostType.Word) {
    document.getElementById("sideload-msg").style.display = "none";
    document.getElementById("app-body").style.display = "flex";
    
    document.getElementById("write-text").onclick = writeText;
    document.getElementById("save-document").onclick = saveDocument;
    document.getElementById("monitor-save").onclick = monitorSave;

    // Connect to WebSocket Server
    connectWebSocket();
  }
});


function connectWebSocket() {
    log(`Connecting to ${WS_URL}...`);
    ws = new WebSocket(WS_URL);

    ws.onopen = () => {
        log("Connected to API Server");
        updateConnectionStatus(true);
    };

    ws.onclose = () => {
        log("Disconnected from API Server");
        updateConnectionStatus(false);
        // Try to reconnect after 5 seconds
        setTimeout(connectWebSocket, 5000);
    };

    ws.onerror = (error) => {
        console.error("WebSocket error:", error);
        log("Connection Error");
    };

    ws.onmessage = async (event) => {
        try {
            const data = JSON.parse(event.data);
            log(`Received command: ${data.action}`);
            
            if (data.action === 'save') {
                await saveDocument(data.id);
            } else if (data.action === 'replace') {
                await replaceDocument(data.payload, data.id);
            }
        } catch (e) {
            log("Error processing message: " + e.message);
        }
    };
}

function updateConnectionStatus(connected) {
    const statusDiv = document.getElementById("connection-status");
    if (statusDiv) {
        statusDiv.innerText = connected ? "API: Connected" : "API: Disconnected";
        statusDiv.style.color = connected ? "green" : "red";
    }
}

function log(message) {
    const logDiv = document.getElementById("status-log");
    const p = document.createElement("p");
    p.innerText = `${new Date().toLocaleTimeString()} - ${message}`;
    p.style.margin = "2px 0";
    p.style.fontSize = "12px";
    logDiv.insertBefore(p, logDiv.firstChild);
}

function errorHandler(error) {
    console.error(error);
    log("Error: " + error.message);
    if (error instanceof OfficeExtension.Error) {
        log("Debug info: " + JSON.stringify(error.debugInfo));
    }
}

export async function writeText() {
  return Word.run(async (context) => {
    const paragraph = context.document.body.insertParagraph("Hello from Word Plugin API!", Word.InsertLocation.end);
    paragraph.font.color = "blue";
    await context.sync();
    log("Text written to document.");
  }).catch(errorHandler);
}

export async function saveDocument() {
  return Word.run(async (context) => {
    context.document.save();
    await context.sync();
    log("Document saved via API.");
  }).catch(errorHandler);
}

export async function replaceDocument(payload, id) {
  return Word.run(async (context) => {
    const { content, type, options } = payload;
    
    // Check path if required
    if (options && options.checkPath) {
       const currentUrl = Office.context.document.url;
       // Normalize paths for comparison
       // Remove file:/// and convert forward slashes to backslashes or vice versa
       let normCurrent = currentUrl ? currentUrl.replace(/^file:\/\/\//, '').replace(/\//g, '\\') : '';
       try { normCurrent = decodeURIComponent(normCurrent); } catch(e) {}
       
       let normTarget = options.checkPath.replace(/\//g, '\\');
       
       // Handle drive letter capitalization differences
       if (normCurrent.toLowerCase() !== normTarget.toLowerCase()) {
          console.log(`Path mismatch. Current: ${normCurrent}, Target: ${normTarget}`);
          log(`Path mismatch. Current: ${normCurrent}, Target: ${normTarget}`);
          if (ws && ws.readyState === WebSocket.OPEN && id) {
             ws.send(JSON.stringify({
                type: 'response',
                id: id,
                status: 'error',
                message: `Document path mismatch. Expected ${normTarget}, got ${normCurrent}`
             }));
          }
          return;
       }
    }

    const body = context.document.body;
    
    if (type === 'html') {
        // use Replace to overwrite existing content
        body.insertHtml(content, Word.InsertLocation.replace);
    } else if (type === 'base64') {
        // use Replace to overwrite existing content, which handles styles better than clear() + insert()
        body.insertFileFromBase64(content, Word.InsertLocation.replace);
    } else {
        // Default text
        // insertParagraph does not support 'Replace', so we clear first
        body.clear();
        body.insertParagraph(content, Word.InsertLocation.start);
    }

    // Handle force options (Direct Formatting Override)
    if (options) {
        if (options.fontName) {
            body.font.name = options.fontName;
            log(`Forced font name: ${options.fontName}`);
        }
        if (options.fontSize) {
            body.font.size = options.fontSize;
            log(`Forced font size: ${options.fontSize}`);
        }
        // Add more style overrides as needed
    }

    await context.sync();
    log("Document content replaced via API.");
    
    if (ws && ws.readyState === WebSocket.OPEN && id) {
       ws.send(JSON.stringify({
          type: 'response',
          id: id,
          status: 'success'
       }));
    }
  }).catch((error) => {
      errorHandler(error);
      if (ws && ws.readyState === WebSocket.OPEN && id) {
         ws.send(JSON.stringify({
            type: 'response',
            id: id,
            status: 'error',
            message: error.message
         }));
      }
  });
}

let monitorInterval;
let lastSavedState = null;

async function checkSaveStatus() {
     await Word.run(async (context) => {
        const doc = context.document;
        doc.load("saved");
        await context.sync();
        
        if (lastSavedState !== doc.saved) {
            lastSavedState = doc.saved;
            log(`Document Saved State: ${doc.saved ? "Saved" : "Unsaved (Dirty)"}`);
        }
    }).catch(errorHandler);
}

export async function monitorSave() {
    const btnLabel = document.getElementById("monitor-save").querySelector(".ms-Button-label");
    
    if (monitorInterval) {
        clearInterval(monitorInterval);
        monitorInterval = null;
        log("Stopped monitoring save status.");
        btnLabel.innerText = "Start Monitoring Save";
        return;
    }

    log("Started monitoring save status...");
    btnLabel.innerText = "Stop Monitoring Save";
    
    // Reset state so we get an initial log
    lastSavedState = null;

    // Check immediately
    checkSaveStatus();

    monitorInterval = setInterval(() => {
        checkSaveStatus();
    }, 2000);
}
